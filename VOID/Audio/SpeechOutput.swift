import AVFoundation
import FluidAudio
import Foundation

/// VOID's voice. Text goes in a sentence at a time; a neural voice turns each into audio
/// and it plays straight away while the next sentence is being made.
///
/// - Expressive: Chatterbox Nano (Resemble AI, 110M, MIT). Natural, emotional, and can
///   perform [chuckle], [laugh], [sigh] and [gasp]. About 0.7 GB.
/// - Fast: Kokoro-82M. Very quick and clean, less emotional. About 0.3 GB.
/// Only one is loaded at a time. If neither loads, the built-in macOS voice is used.
@MainActor
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate {
    let signal: OrbSignal

    private var kokoro: KokoroAneManager?
    private var chatterbox: ChatterboxNanoManager?
    private(set) var active: VoiceEngine?

    /// VOID's own output engine, or the hands-free engine (so echo cancellation can
    /// subtract VOID's voice from the mic).
    private let ownEngine: AVAudioEngine
    private var engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private var rampOnStart = false
    private var ducked = false
    private var engineConfigured = false
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false
    )!

    private var queue: [String] = []
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var pendingBuffers = 0

    // Timing for the transcript, so slow or gappy speech can be measured.
    private var turnStart: Date?
    private var firstAudioMs: Int?
    private var synthSeconds = 0.0
    private var audioSeconds = 0.0

    private let fallback = AVSpeechSynthesizer()
    private var fallbackPending = 0
    private var fallbackLevelTask: Task<Void, Never>?

    init(signal: OrbSignal) {
        self.signal = signal
        let own = AVAudioEngine()
        self.ownEngine = own
        self.engine = own
        super.init()
        fallback.delegate = self
    }

    var isLoaded: Bool { active != nil }

    var isSpeaking: Bool {
        !queue.isEmpty || worker != nil || pendingBuffers > 0 || fallbackPending > 0
    }

    // MARK: - Loading

    /// Loads the preferred voice (downloading it on first use) and warms it up.
    /// Falls back to the other neural voice, then to the system voice. Returns what loaded.
    @discardableResult
    func load(_ preferred: VoiceEngine, progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> VoiceEngine? {
        if active == preferred { return active }
        stop()
        let order: [VoiceEngine] = preferred == .expressive ? [.expressive, .fast] : [.fast, .expressive]
        for choice in order {
            if await loadEngine(choice, progress: progress) {
                active = choice
                // Keep only one voice in memory.
                if choice == .expressive { kokoro = nil } else { chatterbox = nil }
                return choice
            }
        }
        active = nil
        return nil
    }

    private func loadEngine(_ choice: VoiceEngine, progress: @escaping @Sendable (Double) -> Void) async -> Bool {
        do {
            switch choice {
            case .expressive:
                if chatterbox == nil {
                    let manager = ChatterboxNanoManager()
                    try await manager.initialize(progressHandler: { p in progress(p.fractionCompleted) })
                    // One silent warm-up so the first real sentence isn't slow.
                    _ = try? await manager.synthesize(text: "Hi.")
                    chatterbox = manager
                }
            case .fast:
                if kokoro == nil {
                    let manager = KokoroAneManager(variant: .english)
                    try await manager.initialize()
                    _ = try? await manager.synthesizeDetailed(text: "Ready.")
                    kokoro = manager
                }
            }
            return true
        } catch {
            NSLog("VOID voice \(choice.rawValue) failed to load: \(String(describing: error))")
            return false
        }
    }

    // MARK: - Speaking

    func enqueue(_ raw: String) {
        var text = Self.sanitize(raw)
        if active != .expressive { text = SpokenText.stripVoiceTags(text) }
        guard !text.isEmpty else { return }
        // Chatterbox makes at most ~10 s of audio per call, so split very long sentences.
        queue.append(contentsOf: Self.split(text, maxLength: 200))
        pump()
    }

    /// Breaks text longer than `maxLength` at commas, then at spaces.
    private static func split(_ text: String, maxLength: Int) -> [String] {
        guard text.count > maxLength else { return [text] }
        var pieces: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if candidate.count > maxLength, !current.isEmpty {
                pieces.append(current)
                current = String(word)
            } else {
                current = candidate
                if current.hasSuffix(","), current.count > maxLength / 2 {
                    pieces.append(current)
                    current = ""
                }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Call when a new reply starts: warms up the audio output and resets the timing.
    func beginTurn() {
        turnStart = Date()
        firstAudioMs = nil
        synthSeconds = 0
        audioSeconds = 0
        try? configureEngine()
    }

    /// e.g. "voice: first audio 820 ms · 3.1× realtime".
    var turnStats: String? {
        guard let firstAudioMs, audioSeconds > 0 else { return nil }
        let speed = audioSeconds / max(synthSeconds, 0.001)
        return "voice: first audio \(firstAudioMs) ms · \(String(format: "%.1f", speed))× realtime"
    }

    /// Returns when everything queued has been spoken (or `stop()` was called).
    func finish() async {
        while isSpeaking {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(60))
        }
    }

    /// Plays through `shared` (the hands-free engine), or back through VOID's own engine.
    func route(to shared: AVAudioEngine?) {
        stop()
        if engineConfigured {
            player.removeTap(onBus: 0)
            engine.disconnectNodeOutput(player)
            engine.detach(player)
            engineConfigured = false
        }
        if engine === ownEngine, ownEngine.isRunning { ownEngine.stop() }
        engine = shared ?? ownEngine
        // Echo cancellation needs ~200 ms to lock on; fading in avoids VOID hearing itself.
        rampOnStart = shared != nil
        if shared != nil { attachPlayer() }
    }

    /// Lowers VOID's voice while it checks whether you're really talking.
    func duck(_ on: Bool) {
        ducked = on
        player.volume = on ? 0.25 : 1.0
    }

    /// Cuts VOID off immediately.
    func stop() {
        ducked = false
        player.volume = 1.0
        generation += 1
        queue.removeAll()
        worker?.cancel()
        worker = nil
        pendingBuffers = 0
        if engineConfigured { player.stop() }
        fallback.stopSpeaking(at: .immediate)
        fallbackPending = 0
        fallbackLevelTask?.cancel()
        fallbackLevelTask = nil
    }

    private func pump() {
        guard worker == nil else { return }
        let gen = generation
        worker = Task { [weak self] in
            while true {
                guard let self, !Task.isCancelled, !self.queue.isEmpty else { break }
                let text = self.takeNextChunk()
                await self.speakOne(text, generation: gen)
            }
            self?.workerFinished(generation: gen)
        }
    }

    /// Takes the next sentence, plus any more that are already waiting (up to ~180
    /// characters). Each Chatterbox call has a fixed start-up cost, so when speech falls
    /// behind the text, fewer, longer calls catch up instead of leaving gaps.
    private func takeNextChunk() -> String {
        var text = queue.removeFirst()
        while let next = queue.first, text.count + next.count + 1 <= 180 {
            text += " " + next
            queue.removeFirst()
        }
        return text
    }

    private func workerFinished(generation gen: Int) {
        if gen == generation { worker = nil }
    }

    private func speakOne(_ text: String, generation gen: Int) async {
        do {
            let started = Date()
            if let raw = try await synthesize(text) {
                guard gen == generation, !Task.isCancelled, !raw.isEmpty else { return }
                synthSeconds += Date().timeIntervalSince(started)
                let ending = text.last.map { ".!?…".contains($0) } ?? false
                let samples = Self.tighten(raw, pauseAfter: ending ? 0.14 : 0.05)
                audioSeconds += Double(samples.count) / 24_000
                if firstAudioMs == nil, let turnStart {
                    firstAudioMs = Int(Date().timeIntervalSince(turnStart) * 1000)
                }
                try schedule(samples, generation: gen)
                return
            }
        } catch {
            // Fall through to the system voice for this sentence.
        }
        guard gen == generation, !Task.isCancelled else { return }
        speakWithSystemVoice(SpokenText.stripVoiceTags(text))
    }

    /// Cuts the silence the model leaves at the start and end of each clip, then adds one
    /// short, consistent pause, so sentences flow like natural speech instead of
    /// stop-start. Tiny fades stop clicks at the cut points.
    private static func tighten(_ samples: [Float], pauseAfter: Double) -> [Float] {
        let rate = 24_000.0
        var peak: Float = 0
        for v in samples { peak = max(peak, abs(v)) }
        guard peak > 0 else { return samples }
        let threshold = max(Float(0.004), peak * 0.02)
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold }) else { return samples }
        let start = max(0, first - Int(0.03 * rate))
        let end = min(samples.count - 1, last + Int(0.06 * rate))
        var out = Array(samples[start...end])
        let fade = min(Int(0.005 * rate), out.count / 2)
        if fade > 0 {
            for i in 0..<fade {
                let g = Float(i) / Float(fade)
                out[i] *= g
                out[out.count - 1 - i] *= g
            }
        }
        out.append(contentsOf: [Float](repeating: 0, count: Int(pauseAfter * rate)))
        return out
    }

    /// 24 kHz mono samples from the active neural voice, or nil if none is loaded.
    private func synthesize(_ text: String) async throws -> [Float]? {
        switch active {
        case .expressive:
            guard let chatterbox else { return nil }
            return try await chatterbox.synthesize(text: text).samples
        case .fast:
            guard let kokoro else { return nil }
            return try await kokoro.synthesizeDetailed(text: text).samples
        case nil:
            return nil
        }
    }

    // MARK: - Kokoro playback

    private func configureEngine() throws {
        attachPlayer()
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func attachPlayer() {
        if !engineConfigured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            let signal = self.signal
            player.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                guard let channel = buffer.floatChannelData?[0] else { return }
                let count = Int(buffer.frameLength)
                guard count > 0 else { return }
                var sum: Float = 0
                for i in 0..<count { sum += channel[i] * channel[i] }
                signal.push(rms: (sum / Float(count)).squareRoot())
            }
            engineConfigured = true
        }
    }

    private func schedule(_ samples: [Float], generation gen: Int) throws {
        try configureEngine()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        pendingBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1)
            }
        }
        if !player.isPlaying {
            if rampOnStart && !ducked {
                player.volume = 0.15
                Task { @MainActor [weak self] in
                    for step in 1...6 {
                        try? await Task.sleep(for: .milliseconds(35))
                        guard let self, !self.ducked else { return }
                        self.player.volume = min(1, 0.15 + Float(step) * 0.15)
                    }
                }
            }
            player.play()
        }
    }

    // MARK: - System voice fallback

    private func speakWithSystemVoice(_ text: String) {
        fallbackPending += 1
        fallback.speak(AVSpeechUtterance(string: text))
        if fallbackLevelTask == nil {
            let signal = self.signal
            fallbackLevelTask = Task { [weak self] in
                // The system voice gives no audio tap, so the orb gets a soft speech-like wobble.
                var t: Float = 0
                while !Task.isCancelled {
                    guard let self, self.fallbackPending > 0 else { break }
                    t += 0.11
                    let wobble = 0.035 + 0.03 * abs(sin(t * 2.3) * sin(t * 0.9 + 1))
                    signal.push(rms: wobble)
                    try? await Task.sleep(for: .milliseconds(33))
                }
                self?.fallbackLevelTask = nil
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.fallbackPending = max(0, self.fallbackPending - 1)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.fallbackPending = max(0, self.fallbackPending - 1)
        }
    }

    // MARK: - Text

    /// Removes markdown and symbols that sound wrong when read aloud.
    private static func sanitize(_ text: String) -> String {
        var s = text
        for symbol in ["**", "__", "`", "#", "*", "•"] {
            s = s.replacingOccurrences(of: symbol, with: "")
        }
        s = s.replacingOccurrences(of: "\n", with: " ")
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
