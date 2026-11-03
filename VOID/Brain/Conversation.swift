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
    private let state: AppState
    private let reflex: MLXBrain
    private var deep: MLXBrain

    // Ears and voice.
    let signal: OrbSignal
    private let transcriber = Transcriber()
    private let voice: VoiceInput
    private let speech: SpeechOutput
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
        self.reflex = MLXBrain(
            name: "reflex",
            configuration: Models.reflex,
            instructions: Persona.reflex,
            parameters: GenerateParameters(maxTokens: 40, temperature: 0.4),
            keepHistory: false
        )
        self.deep = Conversation.makeDeep(.normal)
    }

    private static func makeDeep(_ mode: BrainMode) -> MLXBrain {
        MLXBrain(
            name: "deep",
            configuration: Models.deep(mode),
            instructions: Persona.deep,
            parameters: GenerateParameters(maxTokens: 360, temperature: 0.7, topP: 0.9),
            keepHistory: true
        )
    }

    // MARK: - Lifecycle

    /// Loads everything at launch: both brains, then the ears (Parakeet), then the voice.
    /// The first run downloads about 3 GB of models; after that VOID works offline.
    func warmUp() {
        state.phase = .loading
        state.statusLine = "Loading models (first run downloads ~3 GB)…"
        Task {
            do {
                try await ensureLoaded(reflex, range: 0...0.2)
                try await ensureLoaded(deep, range: 0.2...0.65)
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
            if speech.isSpeaking { speech.duck(true) }
            if currentTask == nil { state.phase = .listening }
        case .falseStart:
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

    func newConversation() {
        cancel()
        recent.removeAll()
        state.messages.removeAll()
        let brain = deep
        Task { await brain.resetHistory() }
        show("Fresh start.")
        scheduleCaptionHide()
    }

    func setMode(_ mode: BrainMode) {
        guard mode != state.mode else { return }
        cancel()
        state.mode = mode
        let old = deep
        deep = Conversation.makeDeep(mode)
        let newBrain = deep
        state.phase = .loading
        state.loadProgress = 0.3
        state.statusLine = mode == .focus ? "Switching to focus mode (4B)…" : "Switching to normal mode (2B)…"
        Task {
            // Same VOID, same memory: carry the conversation over to the new brain.
            await newBrain.restore(await old.historySnapshot())
            await old.unload()
            do {
                try await ensureLoaded(newBrain, range: 0.3...1)
                state.phase = .idle
                setReadyStatus()
            } catch {
                state.phase = .idle
                state.statusLine = "Couldn't load the deep brain: \(error.localizedDescription)"
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
            say(reply)
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
        if parser.kind == .wait && !parser.body.isEmpty {
            lead = parser.body
        } else {
            lead = Persona.cannedLead()
            show(lead)
        }
        say(lead)

        state.thinkingDepth = 2
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
                for sentence in chunker.feed(visible) { say(sentence) }
            }
            if !Task.isCancelled, let rest = chunker.flush() { say(rest) }
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
        let brainMetrics = "\(reflexLabel) · \(firstLabel) · ≈\(Int(rate)) tok/s"
        updateMetrics(message.id, metrics: brainMetrics)
        state.thinkingDepth = 0
        await finishSpeaking()
        if Task.isCancelled { return }
        if let stats = speech.turnStats {
            updateMetrics(message.id, metrics: brainMetrics + " · " + stats)
        }
        finishTurn()
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
        let deepName = state.mode == .focus ? "4B" : "2B"
        let ears = state.earsReady ? "ears" : "no ears"
        let voiceName = state.activeVoice?.label ?? "system voice"
        state.statusLine = lowMemory
            ? "Low memory · reflex only"
            : "Ready · reflex 0.8B + deep \(deepName) · \(ears) · \(voiceName)"
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
