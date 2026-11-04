import Foundation
import MLXLMCommon

/// Runs one conversation with VOID's two brains.
///
/// Each turn: the reflex brain speaks first (the whole reply for small talk, or just the
/// opening words). If the ask needs real work, the deep brain is handed those exact words
/// as the start of its own reply and keeps talking, so it sounds like one voice. Both share
/// one memory of the conversation. They run one after another, so they never fight over
/// the GPU or memory.
@MainActor
final class Conversation {
    let state: AppState
    private var reflex: MLXBrain
    let toolIndex = ToolIndex()
    private var toolNote: String?
    private var deep: MLXBrain

    // Ears and voice.
    let signal: OrbSignal
    private let transcriber = Transcriber()
    private let voice: VoiceInput
    private let speech: SpeechOutput
    /// Plays and controls YouTube Music in Chrome.
    let music: MusicController
    private var listening = false
    private var starting = false
    private var stopRequested = false
    private var listenTask: Task<Void, Never>?
    private var phaseTask: Task<Void, Never>?

    // Hands-free conversation.
    private var handsFree: HandsFreeListener?
    /// What you said before you interrupted VOID's thinking; joined to your next words.
    private var mergeText: String?
    private var lastUserText: String?
    /// Set when this Mac can't start echo cancellation, so we don't retry every time.
    private var echoCancelUnavailable = false

    private var currentTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var captionToken = 0
    /// What the model answered the last time it was asked about music, shown in the transcript.
    private var routerNote: String?

    /// The last few exchanges, given to the reflex as context.
    private var recent: [(user: String, void: String)] = []
    private var lowMemory = false

    /// The deep brain sleeps after this long without use, to free ~1.6 GB.
    private let idleUnloadAfter: Duration = .seconds(600)

    init(state: AppState, signal: OrbSignal) {
        self.state = state
        self.signal = signal
        self.voice = VoiceInput(signal: signal)
        self.speech = SpeechOutput(signal: signal)
        self.speech.setPace(SpeakingPace.saved.rate)
        self.music = MusicController(state: state)
        self.reflex = Conversation.makeReflex(ReflexChoice.saved)
        self.deep = Conversation.makeDeep(state.mode)
    }

    private static func makeReflex(_ choice: ReflexChoice) -> MLXBrain {
        MLXBrain(
            name: "reflex",
            configuration: Models.reflexModel(choice),
            instructions: Persona.reflex,
            parameters: GenerateParameters(maxTokens: 80, temperature: 0.5),
            keepHistory: false
        )
    }

    private static func makeDeep(_ mode: BrainMode) -> MLXBrain {
        MLXBrain(
            name: "deep",
            configuration: Models.deep(mode),
            instructions: Persona.deep,
            parameters: GenerateParameters(maxTokens: 360, temperature: 0.7, topP: 0.9),
            keepHistory: true,
            streamExperts: mode == .moeStream
        )
    }

    // MARK: - Lifecycle

    /// Loads everything at launch: both brains, then the ears (Parakeet), then the voice.
    /// The first run downloads about 3 GB of models; after that VOID works offline.
    func warmUp() {
        music.start()
        Task { await toolIndex.build() }
        state.phase = .loading
        state.statusLine = "Loading models (first run downloads ~3 GB)…"
        Task {
            do {
                do {
                    try await ensureLoaded(reflex, range: 0...0.2)
                } catch where state.reflexChoice != .qwen {
                    revertReflexToDefault()
                    try await ensureLoaded(reflex, range: 0...0.2)
                }
                do {
                    try await ensureLoaded(deep, range: 0.2...0.65)
                } catch where state.mode != .normal {
                    revertDeepToDefault()
                    try await ensureLoaded(deep, range: 0.2...0.65)
                }
            } catch {
                state.phase = .idle
                state.statusLine = "Couldn't load models: \(error.localizedDescription)"
                show("I couldn't load my brain. Check your internet for the first download, then restart me.")
                scheduleCaptionHide()
                return
            }

            state.statusLine = "Loading ears (speech recognition)…"
            do {
                try await transcriber.load { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.state.loadProgress = 0.65 + fraction * 0.2
                    }
                }
                state.earsReady = true
            } catch {
                state.earsReady = false
                state.statusLine = "Speech recognition unavailable: \(String(describing: error))"
            }

            state.statusLine = "Loading voice (first run downloads it)…"
            state.loadProgress = 0.85
            let loaded = await speech.load(state.voiceEngine) { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.state.loadProgress = 0.85 + fraction * 0.15
                }
            }
            state.activeVoice = loaded
            state.voiceReady = loaded != nil
            StreamLog.write("voice: asked for \(state.voiceEngine.rawValue), loaded \(loaded?.rawValue ?? "NONE (system voice)")")

            state.loadProgress = 1
            state.phase = .idle
            setReadyStatus()
            resetIdleTimer()
        }
    }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        cancel()
        lastUserText = text
        state.messages.append(ChatMessage(role: .user, text: text, source: .user))
        resetIdleTimer()
        currentTask = Task { [weak self] in
            await self?.runTurn(text)
        }
    }

    /// Stops whatever VOID is saying or thinking.
    func cancel() {
        speech.stop()
        handsFree?.setOutputActive(false)
        phaseTask?.cancel()
        phaseTask = nil
        if listening { abortListening() }
        listenTask?.cancel()
        listenTask = nil
        guard let task = currentTask else {
            if state.phase != .loading { state.phase = restingPhase }
            return
        }
        task.cancel()
        currentTask = nil
        state.thinkingDepth = 0
        state.deepWorking = false
        state.phase = restingPhase
        state.captionVisible = false
    }

    /// Where the orb rests between turns: listening in hands-free mode, idle otherwise.
    private var restingPhase: OrbPhase { state.handsFree ? .listening : .idle }

    // MARK: - Hands-free conversation

    func toggleHandsFree() {
        if state.handsFree { stopHandsFree() } else { startHandsFree() }
    }

    /// Always listening: just talk, pause, and VOID answers. Talk over it to interrupt.
    func startHandsFree() {
        guard !state.handsFree, handsFree == nil, state.phase != .loading else { return }
        guard state.earsReady else {
            show("My ears aren't ready yet. Give me a moment.")
            scheduleCaptionHide()
            return
        }
        cancel()
        state.caption = "Starting hands-free…"
        state.captionVisible = true
        Task { [weak self] in
            guard let self else { return }
            guard await VoiceInput.requestPermission() else {
                self.show("I can't hear you. Allow VOID in System Settings → Privacy & Security → Microphone.")
                self.scheduleCaptionHide()
                return
            }
            // Try with echo cancellation (so you can interrupt), retry once, then fall back to
            // plain listening. Some Macs on macOS 27 can't start Apple's voice processing for
            // their mic + speaker pair (error -10875); remember that for this session.
            let attempts: [Bool] = self.echoCancelUnavailable ? [false] : [true, true, false]
            var started: HandsFreeListener?
            var lastError: Error?
            for (index, echoCancel) in attempts.enumerated() {
                let listener = HandsFreeListener(signal: self.signal, transcriber: self.transcriber)
                do {
                    try await listener.loadVAD()
                    let engine = try listener.prepare(echoCancel: echoCancel) { [weak self] event in
                        Task { @MainActor [weak self] in self?.handle(event) }
                    }
                    // VOID's voice only moves onto this engine when echo cancelling is on,
                    // so the canceller knows what to remove.
                    if listener.echoCancelling { self.speech.route(to: engine) }
                    try listener.start()
                    started = listener
                    break
                } catch {
                    lastError = error
                    listener.stop()
                    self.speech.route(to: nil)
                    if echoCancel && index == 1 { self.echoCancelUnavailable = true }
                    if echoCancel { try? await Task.sleep(for: .milliseconds(300)) }
                }
            }

            guard let listener = started else {
                self.show("I couldn't start hands-free mode: \(lastError?.localizedDescription ?? "unknown error")")
                self.scheduleCaptionHide()
                return
            }
            self.handsFree = listener
            self.state.handsFree = true
            self.state.echoCancelling = listener.echoCancelling
            self.state.phase = .listening
            self.setReadyStatus()
            self.show(listener.echoCancelling
                ? "I'm listening. Just talk, and interrupt me any time."
                : "I'm listening. Just talk. I'll stop listening while I answer.")
            self.scheduleCaptionHide()
        }
    }

    func stopHandsFree() {
        guard let listener = handsFree else { return }
        handsFree = nil
        state.handsFree = false
        mergeText = nil
        cancel()
        listener.stop()
        speech.route(to: nil)
        state.phase = .idle
        setReadyStatus()
        show("Hands-free off.")
        scheduleCaptionHide()
    }

    private func handle(_ event: HandsFreeListener.Event) {
        guard state.handsFree else { return }
        switch event {
        case .speechStarted:
            music.userTalking = true
            if speech.isSpeaking { speech.duck(true) }
            if currentTask == nil { state.phase = .listening }
        case .falseStart:
            music.userTalking = false
            speech.duck(false)
        case .speechConfirmed:
            // Barge-in: you're talking, so VOID stops.
            if currentTask != nil || speech.isSpeaking {
                // If VOID hadn't started speaking yet, you were still mid-thought:
                // keep what you said and join it to what comes next.
                if currentTask != nil, speech.turnStats == nil, let last = lastUserText {
                    mergeText = last
                    if let index = state.messages.lastIndex(where: { $0.role == .user && $0.text == last }) {
                        state.messages.remove(at: index)
                    }
                }
                cancel()
            }
            speech.duck(false)
            state.phase = .listening
            state.caption = "Listening…"
            state.captionVisible = true
        case .utterance(let samples, let partial):
            music.userTalking = false
            speech.duck(false)
            listenTask?.cancel()
            listenTask = Task { [weak self] in
                guard let self else { return }
                self.state.phase = .thinking
                var text = partial ?? ""
                if text.isEmpty {
                    text = (try? await self.transcriber.transcribe(samples)) ?? ""
                }
                if Task.isCancelled { return }
                let heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.music.noteVoice(heard, samples: samples)
                guard heard.count > 1 else {
                    self.state.phase = self.restingPhase
                    self.state.captionVisible = false
                    return
                }
                let full = self.mergeText.map { $0 + " " + heard } ?? heard
                self.mergeText = nil
                self.state.caption = "“\(full)”"
                self.state.captionVisible = true
                self.send(full)
            }
        }
    }

    // MARK: - Voice in

    var isListening: Bool { listening }

    /// Starts recording. `hold` = true for push-to-talk (release ends it); otherwise it
    /// ends by itself after you stop talking.
    func startListening(hold: Bool) {
        // Hands-free mode is already listening.
        guard !state.handsFree else { return }
        guard !listening, state.phase != .loading else { return }
        cancel()
        guard state.earsReady else {
            show("Loading my ears…")
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.transcriber.load { _ in }
                    self.state.earsReady = true
                    self.setReadyStatus()
                    self.show("Ears ready. Try again.")
                } catch {
                    let detail = String(describing: error)
                    self.state.statusLine = "Speech recognition unavailable: \(detail)"
                    self.show("My ears failed to load: \(String(detail.prefix(140)))")
                }
                self.scheduleCaptionHide()
            }
            return
        }
        starting = true
        stopRequested = false
        Task { [weak self] in
            guard let self else { return }
            guard await VoiceInput.requestPermission() else {
                self.starting = false
                self.show("I can't hear you. Allow VOID in System Settings → Privacy & Security → Microphone.")
                self.scheduleCaptionHide()
                return
            }
            do {
                self.listening = true
                self.state.phase = .listening
                self.state.caption = "Listening…"
                self.state.captionVisible = true
                var autoStop: (@Sendable () -> Void)?
                if !hold {
                    autoStop = { [weak self] in
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated { self?.finishListening() }
                        }
                    }
                }
                try self.voice.start(autoStop: autoStop)
                self.starting = false
                // The key may have been released while the permission prompt was open.
                if self.stopRequested {
                    self.stopRequested = false
                    self.finishListening()
                }
            } catch {
                self.starting = false
                self.listening = false
                self.state.phase = .idle
                self.show("I couldn't open the microphone.")
                self.scheduleCaptionHide()
            }
        }
    }

    /// Tap-to-talk: tap once to start, tap again to send.
    func toggleListening() {
        if state.handsFree { stopHandsFree(); return }
        if listening { finishListening() } else { startListening(hold: false) }
    }

    /// Stops recording and turns the audio into a message.
    func finishListening() {
        guard listening else {
            if starting { stopRequested = true }
            return
        }
        listening = false
        let samples = voice.stop()
        state.phase = .thinking
        state.caption = "…"
        listenTask = Task { [weak self] in
            guard let self else { return }
            // Under ~0.3 s is a mis-tap, not speech.
            guard samples.count > 4_800 else {
                self.state.phase = .idle
                self.state.captionVisible = false
                return
            }
            let text = (try? await self.transcriber.transcribe(samples)) ?? ""
            if Task.isCancelled { return }
            guard !text.isEmpty else {
                self.state.phase = .idle
                self.show("I didn't catch that.")
                self.state.phase = .idle
                self.scheduleCaptionHide()
                return
            }
            self.state.caption = "“\(text)”"
            self.send(text)
        }
    }

    private func abortListening() {
        listening = false
        _ = voice.stop()
    }

    var isBusy: Bool { currentTask != nil || listening }
    /// A message is being worked on (not merely the microphone being open).
    var isWorking: Bool { currentTask != nil }

    func newConversation() {
        cancel()
        recent.removeAll()
        state.messages.removeAll()
        let brain = deep
        Task { await brain.resetHistory() }
        show("Fresh start.")
        scheduleCaptionHide()
    }

    private func revertDeepToDefault() {
        state.mode = .normal
        UserDefaults.standard.set(BrainMode.normal.rawValue, forKey: "deepBrain")
        deep = Conversation.makeDeep(.normal)
    }

    private func revertReflexToDefault() {
        state.reflexChoice = .qwen
        UserDefaults.standard.set(ReflexChoice.qwen.rawValue, forKey: "reflexModel")
        reflex = Conversation.makeReflex(.qwen)
    }

    func setPace(_ pace: SpeakingPace) {
        state.pace = pace
        UserDefaults.standard.set(pace.rawValue, forKey: "speakingPace")
        speech.setPace(pace.rate)
    }

    func setReflex(_ choice: ReflexChoice) {
        guard choice != state.reflexChoice else { return }
        cancel()
        state.reflexChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: "reflexModel")
        let old = reflex
        reflex = Conversation.makeReflex(choice)
        let fresh = reflex
        state.phase = .loading
        state.loadProgress = 0.1
        state.statusLine = "Switching reflex to \(choice.label)…"
        Task {
            await old.unload()
            do {
                try await ensureLoaded(fresh, range: 0...0.3)
                state.phase = .idle
                setReadyStatus()
            } catch {
                let failed = state.reflexChoice
                let reason = String(describing: error)
                revertReflexToDefault()
                try? await ensureLoaded(reflex, range: 0...0.3)
                state.phase = .idle
                setReadyStatus()
                state.statusLine = "\(failed.label) wouldn't load, so I went back to \(state.reflexChoice.label). \(reason)"
            }
        }
    }

    func setMode(_ mode: BrainMode) {
        guard mode != state.mode else { return }
        cancel()
        state.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "deepBrain")
        let old = deep
        deep = Conversation.makeDeep(mode)
        let newBrain = deep
        state.phase = .loading
        state.loadProgress = 0.3
        state.statusLine = "Switching deep brain to \(mode.short)…"
        Task {
            // Same VOID, same memory: carry the conversation over to the new brain.
            await newBrain.restore(await old.historySnapshot())
            await old.unload()
            do {
                try await ensureLoaded(newBrain, range: 0.3...1)
                state.phase = .idle
                setReadyStatus()
            } catch {
                // Go back to the proven default so VOID keeps working.
                let failed = state.mode
                let reason = String(describing: error)
                revertDeepToDefault()
                let fallback = deep
                await fallback.restore(await newBrain.historySnapshot())
                try? await ensureLoaded(fallback, range: 0.3...1)
                state.phase = .idle
                setReadyStatus()
                state.statusLine = "\(failed.short) wouldn't load, so I went back to \(state.mode.short). \(reason)"
            }
        }
    }

    /// Switches between the expressive (Chatterbox) and fast (Kokoro) voices.
    func setVoice(_ engine: VoiceEngine) {
        guard engine != state.voiceEngine || state.activeVoice != engine else { return }
        cancel()
        state.voiceEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: "voiceEngine")
        state.statusLine = "Loading \(engine.label)…"
        Task {
            let loaded = await speech.load(engine)
            state.activeVoice = loaded
            state.voiceReady = loaded != nil
            setReadyStatus()
            if state.speakReplies {
                say(loaded == .expressive ? "Okay. How do I sound now?" : "Okay, switched voices.")
            }
        }
    }

    func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        if event.contains(.critical) {
            lowMemory = true
            state.lowMemory = true
            state.statusLine = "Memory is critical. Deep brain asleep; reflex only."
            let brain = deep
            Task { await brain.unload() }
        } else if event.contains(.warning) {
            state.statusLine = "Memory is tight. Consider closing a heavy app."
        } else if event.contains(.normal) {
            lowMemory = false
            state.lowMemory = false
            setReadyStatus()
        }
    }

    // MARK: - One turn

    private func runTurn(_ text: String) async {
        defer {
            if !Task.isCancelled { currentTask = nil }
        }
        let started = Date()
        state.phase = .thinking
        state.thinkingDepth = 1
        if state.speakReplies { speech.beginTurn() }
        startPhaseWatcher()

        // Music commands go straight to the music hands, no brains needed.
        music.noteUserText(text)
        routerNote = nil
        toolNote = nil
        var musicReply = await PhoneController.shared.handle(text)
        if musicReply == nil { musicReply = await music.handle(text) }
        if musicReply == nil, music.routerEligible, !Self.mentionsPhone(text), let intent = await routeMusic(text) {
            if Task.isCancelled { return }
            musicReply = await music.run(intent)
        }
        // Anything else that sounds like a phone or Mac control: search the tool index.
        if musicReply == nil {
            musicReply = await routeTools(text)
        }
        if Task.isCancelled { return }
        CommandLog.record(text: text, route: musicReply != nil ? (toolNote ?? routerNote ?? "rules") : "chat")
        if let reply = musicReply {
            show(reply)
            state.messages.append(ChatMessage(role: .void, text: reply, source: .system,
                                              metrics: "music \(Self.ms(since: started)) ms" + (routerNote.map { " · " + $0 } ?? "") + (toolNote.map { " · " + $0 } ?? "")))
            remember(user: text, void: reply)
            await deep.remember(user: text, reply: reply)
            if Task.isCancelled { return }
            say(reply)
            await finishSpeaking()
            if Task.isCancelled { return }
            finishTurn()
            return
        }

        let canUseDeep = !lowMemory
        let forceDeep = canUseDeep && Router.mustGoDeep(text)

        // 1. Reflex brain reacts.
        var parser = ReflexParser()
        var reflexMs: Int?
        do {
            try await ensureLoaded(reflex, range: 0...0.3)
            let prompt = Persona.reflexPrompt(user: text, recent: recentSummary())
            for try await chunk in reflex.stream(prompt) {
                if Task.isCancelled { return }
                if reflexMs == nil { reflexMs = Self.ms(since: started) }
                parser.feed(chunk)
                let showLive = parser.kind == .wait || (parser.kind == .answer && !forceDeep)
                if showLive && !parser.body.isEmpty {
                    show(parser.body)
                }
                if parser.kind == .unknown || parser.lineComplete { break }
            }
        } catch {
            if Task.isCancelled { return }
            // A failed reflex isn't fatal: the deep brain can still answer.
        }
        if Task.isCancelled { return }

        let reflexLabel = "reflex \(reflexMs.map { "\($0) ms" } ?? "–")"
            + (reflex.prefill.label.map { " (prompt \($0))" } ?? "")
        let reflexAnswered = parser.kind == .answer && !forceDeep && !parser.body.isEmpty

        // 2a. Small talk, or no deep brain available: the reflex's line is the answer.
        if reflexAnswered || !canUseDeep {
            let reply: String
            if reflexAnswered {
                reply = parser.body
            } else if parser.kind == .answer && !parser.body.isEmpty {
                reply = parser.body
            } else {
                reply = Persona.lowMemoryReply
                show(reply)
            }
            let replyMessage = ChatMessage(role: .void, text: reply, source: .reflex, metrics: reflexLabel)
            state.messages.append(replyMessage)
            // The deep brain remembers this too: it's all one VOID.
            await deep.remember(user: text, reply: reply)
            remember(user: text, void: reply)
            sayInPieces(reply)
            await finishSpeaking()
            if Task.isCancelled { return }
            if let stats = speech.turnStats {
                updateMetrics(replyMessage.id, metrics: "\(reflexLabel) · \(stats)")
            }
            finishTurn()
            return
        }

        // 2b. Real work: speak the reflex's opening now, then the deep brain carries on
        //     from those exact words, as one reply in one voice.
        let lead: String
        if parser.kind == .wait && !parser.body.isEmpty
            && !Persona.isGenericLead(parser.body, user: text) {
            lead = parser.body
        } else {
            // The reflex gave nothing, or a stock phrase like "Good question".
            lead = Persona.contextualLead(for: text)
            show(lead)
        }
        sayInPieces(lead)

        state.thinkingDepth = 2
        state.deepWorking = true
        let deepBrain = deep
        let message = ChatMessage(role: .void, text: lead, source: .deep, metrics: reflexLabel)
        state.messages.append(message)

        var answer = ""
        var firstTokenMs: Int?
        var chunks = 0
        var generationStart = Date()
        do {
            if !(await deepBrain.isLoaded) {
                show(lead + " …")
            }
            try await ensureLoaded(deepBrain, range: 0.3...1)
            generationStart = Date()

            var filter = SpokenStreamFilter()
            var chunker = SentenceChunker()
            for try await chunk in deepBrain.stream(text, prefix: lead) {
                if Task.isCancelled { break }
                chunks += 1
                if firstTokenMs == nil { firstTokenMs = Self.ms(since: started) }
                let visible = filter.feed(chunk)
                guard !visible.isEmpty else { continue }
                answer += visible
                let full = Self.join(lead, answer)
                show(full)
                updateMessage(message.id, text: full)
                for sentence in chunker.feed(visible) {
                    if state.deepWorking {
                        // The real answer starts here: the orb resolves from thinking to speaking.
                        state.deepWorking = false
                        state.handoff &+= 1
                    }
                    say(sentence)
                }
            }
            if !Task.isCancelled, let rest = chunker.flush() {
                if state.deepWorking {
                    state.deepWorking = false
                    state.handoff &+= 1
                }
                say(rest)
            }
        } catch {
            if !Task.isCancelled {
                let note = "Something went wrong in my head: \(error.localizedDescription)"
                show(note)
                say("Sorry, something went wrong in my head.")
                updateMessage(message.id, text: Self.join(lead, note))
            }
        }

        // Remember what was actually said, even if Aditya cut VOID off.
        let spoken = Self.join(lead, answer)
        await deepBrain.remember(user: text, reply: spoken)
        remember(user: text, void: spoken)
        if Task.isCancelled { return }

        let seconds = max(0.001, Date().timeIntervalSince(generationStart))
        let rate = Double(chunks) / seconds
        let firstLabel = firstTokenMs.map { "deep first word \($0) ms" } ?? "no deep output"
        let deepPrompt = deepBrain.prefill.label.map { " (prompt \($0))" } ?? ""
        let brainMetrics = "\(reflexLabel) · \(firstLabel)\(deepPrompt) · ≈\(Int(rate)) tok/s"
        updateMetrics(message.id, metrics: brainMetrics)
        state.thinkingDepth = 0
        state.deepWorking = false
        await finishSpeaking()
        if Task.isCancelled { return }
        if let stats = speech.turnStats {
            updateMetrics(message.id, metrics: brainMetrics + " · " + stats)
        }
        finishTurn()
    }

    /// Messages about the phone, notifications or texts never go to the music router.
    static func mentionsPhone(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["notification", "notifs", "message", "text ", "texts", "sms", "phone", "whatsapp", "call ", "alert",
            "bluetooth", "wifi", "wi-fi", "brightness", "my mac", "the mac", "mac's", "airplane"]
            .contains(where: { lower.contains($0) }) { return true }
        return false
    }

    /// Finds the few tools that fit this message, then asks the small model to pick one and
    /// fill in its arguments. Chatting never reaches the model: the search score has to clear
    /// a threshold first. The score shows in the transcript so the threshold can be tuned.
    private func routeTools(_ text: String) async -> String? {
        if let overview = Self.capabilityAnswer(text) { return overview }
        // Search first (cheap). Only load the model if something matched well enough to need it.
        guard let plan = await planTool(text), let call = plan.call else { return nil }
        return await PhoneController.shared.execute(call.spec, call.args, said: text)
    }

    /// "open watsapp": an app or site name follows "open", which is evidence enough for mac.open.
    static func opensSomething(_ text: String) -> Bool {
        let words = MusicIntent.normalizeCommand(text).split(separator: " ").map(String.init)
        guard words.count >= 2, words[0] == "open" else { return false }
        return !["up", "the", "a", "an", "my", "your", "it", "this", "that", "door", "window"].contains(words[1])
    }

    /// "what is bluetooth", "how does wifi work", "my phone is so slow": talk, never a tool call.
    static func isInformational(_ text: String) -> Bool {
        let t = MusicIntent.normalizeCommand(text)
        let always = ["how does ", "how do ", "how to ", "why ", "explain ", "define ", "should i ", "is a ", "is an ",
                      "tell me about ", "what does ", "what's the difference", "whats the difference",
                      "what is the difference", "who ", "tell me a ", "tell me something"]
        if always.contains(where: { t.hasPrefix($0) }) { return true }
        if ["what is ", "what's ", "whats ", "what are "].contains(where: { t.hasPrefix($0) }) {
            let personal = [" my ", "battery", "volume", "brightness", "clipboard", "notification", "message", "status",
                            "playing", "apps", "number", "up with"]
            if !personal.contains(where: { t.contains($0) }) { return true }
        }
        for subject in ["my phone ", "my mac ", "my laptop ", "my computer "] {
            for verb in ["is ", "was ", "has ", "keeps ", "feels ", "seems "] where t.hasPrefix(subject + verb) { return true }
        }
        // Hinglish questions: "bluetooth kya hota hai", "kaise kaam karta hai".
        let words = Set(t.split(separator: " ").map(String.init))
        if !words.isDisjoint(with: ["kya", "kyun", "kyu", "kaise", "kab"]) { return true }
        return false
    }

    /// What the tool search and planner decided for a message, without running anything.
    struct ToolPlan {
        var candidates: [ToolIndex.Match]
        var topScore: Double
        var call: ToolPlanner.Call?
        var raw: String
    }

    /// Searches the tool index, and if something fits well enough asks the small model to pick one.
    /// `runModel: false` stops after the search, for fast offline checks.
    func planTool(_ text: String, runModel: Bool = true) async -> ToolPlan? {
        // Questions and remarks are chat, not commands.
        if Self.isInformational(text) {
            toolNote = "tools: informational question"
            return ToolPlan(candidates: [], topScore: 0, call: nil, raw: "")
        }
        // "on my mac" only searches Mac tools; "on my phone" only phone tools.
        let lower = text.lowercased()
        let macWords = ["mac", "macbook", "laptop", "computer"].contains { lower.contains($0) }
        let phoneWords = ["phone", "mobile", "fone"].contains { lower.contains($0) }
        var targets: Set<ToolSpec.Target>? = macWords && !phoneWords ? [.mac] : (phoneWords && !macWords ? [.phone] : nil)
        // "open safari" with no device named means this Mac.
        if targets == nil, MusicIntent.normalizeCommand(text).hasPrefix("open ") { targets = [.mac] }

        let found = await toolIndex.search(text, limit: 6, targets: targets)
        // A tool needs real evidence: a shared action word, or a very close meaning.
        let candidates = found.filter { m in
            (m.score >= ToolIndex.threshold && m.evidence >= 1) || m.score >= 0.9
                || (m.spec.id == "mac.open" && m.score >= 0.6 && Self.opensSomething(text))
                || (m.evidence >= 2 && m.score >= 0.45)
        }.prefix(4).map { $0 }
        guard let top = candidates.first else {
            if let best = found.first {
                toolNote = "tools: none (best \(best.spec.id) \(String(format: "%.2f", best.score)))"
                return ToolPlan(candidates: [], topScore: 0, call: nil,
                                raw: "best \(best.spec.id) \(String(format: "%.2f", best.score)), evidence \(best.evidence)")
            }
            return nil
        }
        // A bare verb ("call") with nothing to act on isn't a command yet.
        if MusicIntent.normalizeCommand(text).split(separator: " ").count == 1, !top.spec.args.isEmpty {
            toolNote = "tools: needs more words"
            return ToolPlan(candidates: [], topScore: 0, call: nil, raw: "needs more words")
        }
        toolNote = "tools: \(top.spec.id) \(String(format: "%.2f", top.score))"
        var plan = ToolPlan(candidates: candidates, topScore: top.score, call: nil, raw: "")
        guard runModel else { return plan }
        do { try await ensureLoaded(reflex, range: 0...0.3) } catch { return plan }

        let prompt = ToolPlanner.prompt(user: text, recent: recentSummary(), candidates: candidates)
        var answer = ""
        do {
            let stream = reflex.stream(
                prompt, system: ToolPlanner.system,
                settings: GenerateParameters(maxTokens: 90, temperature: 0))
            for try await chunk in stream {
                if Task.isCancelled { return plan }
                answer += chunk
                if answer.contains("\n") && answer.count > 4 { break }
            }
        } catch {
            return plan
        }
        plan.raw = answer
        // The search already found a tool the message has real words for. The model can pick a
        // different one among the candidates; "none" only wins when the match was weak.
        var chosen = ToolPlanner.parse(answer, candidates: candidates)
        if chosen == nil {
            let saidNone = answer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("NONE")
            if saidNone && top.score < 0.7 && top.evidence < 2 { return plan }
            chosen = ToolPlanner.Call(spec: top.spec, args: [:])
        }
        guard let picked = chosen else { return plan }
        let call = ToolPlanner.Call(
            spec: picked.spec, args: ToolPlanner.fillArgs(picked.spec, said: text, args: picked.args))
        toolNote = (toolNote ?? "") + " → " + call.spec.id
        plan.call = call
        return plan
    }

    /// "What can you do on my phone / with android / on my mac?" answered from the registry.
    private static func capabilityAnswer(_ text: String) -> String? {
        let lower = text.lowercased()
        let asks = ["what can you do", "what all can you do", "what controls", "what powers", "what can you control",
                    "which controls", "what are your abilities", "what can you access", "control my phone",
                    "control the phone", "control your phone", "control android", "access my phone",
                    "access the phone", "do you have access", "can you use my phone", "control my mac",
                    "control the mac", "what tools", "which tools", "what do you have access"].contains { lower.contains($0) }
        guard asks else { return nil }
        if lower.contains("phone") || lower.contains("android") {
            return "On your phone I can " + ToolRegistry.overview(.phone) + "."
        }
        if lower.contains("mac") || lower.contains("computer") {
            return "On your Mac I can " + ToolRegistry.overview(.mac) + "."
        }
        return nil
    }

    /// While music is in play, asks the small model whether this message is about the music
    /// and which action it means. It sees the last few messages and the song playing.
    /// Returns nil for anything that isn't a clear music request.
    func routeMusic(_ text: String) async -> MusicIntent? {
        // Never wait for the model to load just for this; the normal reply path handles it.
        guard await reflex.isLoaded else { return nil }
        // Only messages that talk about music, songs or playback ever reach the model.
        guard MusicIntent.musicish(text), !Self.isInformational(text) else { return nil }
        let prompt = Persona.musicRouterPrompt(user: text, recent: recentSummary(), nowPlaying: music.currentSong)
        var answer = ""
        do {
            let stream = reflex.stream(
                prompt, system: Persona.musicRouter,
                settings: GenerateParameters(maxTokens: 24, temperature: 0))
            for try await chunk in stream {
                if Task.isCancelled { return nil }
                answer += chunk
                if answer.contains("\n") && answer.count > 3 { break }
            }
        } catch {
            return nil
        }
        let line = answer.split(whereSeparator: \.isNewline).first.map(String.init) ?? answer
        routerNote = "router: \(line.trimmingCharacters(in: .whitespaces))"
        return MusicIntent.fromRouter(answer, message: text)
    }

    /// Speaks a multi-sentence opener piece by piece, so the first words start quickly
    /// instead of waiting for the whole opener to be voiced in one go.
    private func sayInPieces(_ text: String) {
        var chunker = SentenceChunker()
        var pieces = chunker.feed(text)
        if let rest = chunker.flush() { pieces.append(rest) }
        for piece in pieces { say(piece) }
    }

    /// Joins the opening and the continuation into one natural sentence flow.
    private static func join(_ lead: String, _ rest: String) -> String {
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return lead }
        return lead + " " + tail
    }

    // MARK: - Helpers

    private func ensureLoaded(_ brain: MLXBrain, range: ClosedRange<Double>) async throws {
        if await brain.isLoaded { return }
        try await brain.load { fraction in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                self.state.loadProgress = value
            }
        }
    }

    /// Puts words under the orb and makes it pulse like it's speaking.
    private func show(_ text: String) {
        captionToken += 1
        state.caption = SpokenText.tail(SpokenText.stripVoiceTags(text), max: 170)
        state.captionVisible = true
        if !state.speakReplies, currentTask != nil {
            // Silent mode: the orb still "speaks" while words appear.
            signal.push(rms: 0.07)
            state.phase = .speaking
        }
    }

    // MARK: - Voice out

    private func say(_ text: String) {
        guard state.speakReplies else { return }
        speech.enqueue(text)
    }

    private func finishSpeaking() async {
        guard state.speakReplies else { return }
        await speech.finish()
    }

    /// While a turn runs, the orb shows "thinking" until audio is actually playing.
    private func startPhaseWatcher() {
        phaseTask?.cancel()
        guard state.speakReplies else { return }
        phaseTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let talking = self.speech.isSpeaking
                self.handsFree?.setOutputActive(talking)
                if self.currentTask != nil, !self.listening {
                    self.state.phase = talking ? .speaking : .thinking
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func finishTurn() {
        state.thinkingDepth = 0
        state.deepWorking = false
        phaseTask?.cancel()
        phaseTask = nil
        handsFree?.setOutputActive(false)
        currentTask = nil
        state.phase = restingPhase
        setReadyStatus()
        scheduleCaptionHide()
        resetIdleTimer()
    }

    /// Fades the caption once there has been time to read it.
    private func scheduleCaptionHide() {
        let token = captionToken
        let words = state.caption.split(separator: " ").count
        let delay = max(3.0, Double(words) / 3.0)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.captionToken == token,
                  self.state.phase == .idle || (self.state.handsFree && self.state.phase == .listening)
            else { return }
            self.state.captionVisible = false
        }
    }

    private func resetIdleTimer() {
        idleTask?.cancel()
        let delay = idleUnloadAfter
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            let brain = self.deep
            await brain.unload()
            self.state.statusLine = "Deep brain sleeping to save memory. It wakes when you ask something."
        }
    }

    private func setReadyStatus() {
        let deepName = state.mode.short
        let ears = state.earsReady ? "ears" : "no ears"
        let voiceName = state.activeVoice?.label ?? "system voice"
        state.statusLine = lowMemory
            ? "Low memory · reflex only"
            : "Ready · reflex \(state.reflexChoice.label) + deep \(deepName) · \(ears) · \(voiceName)"
                + (state.handsFree ? " · hands-free" + (state.echoCancelling ? "" : " (no echo cancel)") : "")
    }

    private func updateMessage(_ id: UUID, text: String) {
        guard let index = state.messages.firstIndex(where: { $0.id == id }) else { return }
        state.messages[index].text = text
    }

    private func updateMetrics(_ id: UUID, metrics: String) {
        guard let index = state.messages.firstIndex(where: { $0.id == id }) else { return }
        state.messages[index].metrics = metrics
    }

    private func remember(user: String, void: String) {
        recent.append((user: user, void: void))
        if recent.count > 3 { recent.removeFirst(recent.count - 3) }
    }

    private func recentSummary() -> String {
        let text = recent.map { "Aditya: \($0.user)\nVOID: \($0.void)" }.joined(separator: "\n")
        return String(text.suffix(600))
    }

    private static func ms(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}
