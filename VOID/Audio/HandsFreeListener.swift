import AVFoundation
import FluidAudio
import Foundation

/// Always-on listening for hands-free conversation, the way ChatGPT's voice mode works.
///
/// - **Voice activity detection:** Silero VAD (on the Neural Engine) scores every 256 ms of
///   audio for "is this a human voice", combined with a loudness gate that learns the room's
///   background noise level, so fans, typing and music don't count as talking.
/// - **Pre-roll:** the last ~0.5 s before speech is detected is kept, so the first word
///   isn't clipped.
/// - **Smart endpointing:** when you pause, it peeks at what you've said so far. If it sounds
///   finished it replies after ~0.5 s of silence; if it ends mid-thought ("and", "so", "um",
///   a comma) it waits ~1.5 s.
/// - **Echo cancellation:** macOS voice processing removes VOID's own voice from the mic,
///   so you can interrupt it (barge-in). VOID's playback runs through the same engine so the
///   canceller can hear what to remove. Without it, the mic is ignored while VOID talks.
/// - **Barge-in with false-start protection:** a first blip of speech only ducks VOID's
///   voice; it's cut off once ~0.5 s of real speech confirms you're talking.
final class HandsFreeListener: @unchecked Sendable {
    enum Event: Sendable {
        /// Maybe speech: duck VOID's voice.
        case speechStarted
        /// Definitely speech: stop VOID (barge-in).
        case speechConfirmed
        /// It was just a noise: restore VOID's voice.
        case falseStart
        /// A finished turn: 16 kHz samples, plus the transcript if it was already made.
        case utterance([Float], String?)
    }

    private static let chunk = VadManager.chunkSize          // 4096 samples = 256 ms at 16 kHz
    private static let chunkSeconds = Double(VadManager.chunkSize) / 16_000

    private let signal: OrbSignal
    private let transcriber: Transcriber
    private var vad: VadManager?

    private(set) var engine: AVAudioEngine?
    private(set) var echoCancelling = false

    private let lock = NSLock()
    private var outputActive = false
    private var pending: [Float] = []
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var worker: Task<Void, Never>?
    private var onEvent: (@Sendable (Event) -> Void)?

    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    init(signal: OrbSignal, transcriber: Transcriber) {
        self.signal = signal
        self.transcriber = transcriber
    }

    /// Downloads (first time, ~2 MB) and loads Silero VAD.
    func loadVAD() async throws {
        if vad == nil {
            vad = try await VadManager(config: VadConfig(defaultThreshold: 0.5))
        }
    }

    /// Tells the listener whether VOID is talking right now (raises the bar for barge-in).
    func setOutputActive(_ active: Bool) {
        lock.lock(); outputActive = active; lock.unlock()
    }

    private var isOutputActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return outputActive
    }

    /// Builds the audio engine (mic with echo cancellation) without starting it, so VOID's
    /// voice player can be attached to the same engine first. Call `start()` after.
    ///
    /// On some Macs (macOS 27, certain mic + speaker pairs) Apple's voice processing can't
    /// initialise and `start()` fails with -10875. The caller then retries with
    /// `echoCancel: false`: plain listening, with the mic ignored while VOID talks.
    func prepare(echoCancel: Bool, onEvent: @escaping @Sendable (Event) -> Void) throws -> AVAudioEngine {
        self.onEvent = onEvent
        let engine = AVAudioEngine()
        let input = engine.inputNode

        echoCancelling = false
        if echoCancel {
            do {
                try input.setVoiceProcessingEnabled(true)
                echoCancelling = true
                // Don't silence the user's other audio (music, videos) while VOID listens.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                NSLog("VOID: echo cancellation unavailable: \(String(describing: error))")
            }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let mono = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: target)
        else { throw VoiceInput.Failure.noInput }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.process(buffer, mono: mono, converter: converter)
        }
        self.engine = engine
        return engine
    }

    func start() throws {
        guard let engine, let vad else { throw VoiceInput.Failure.noInput }
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        lock.lock(); self.continuation = continuation; pending.removeAll(); lock.unlock()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("VOID: hands-free engine failed to start (echo cancel \(echoCancelling)): \(String(describing: error))")
            stop()
            throw error
        }
        worker = Task { [weak self] in
            await self?.detect(stream, vad: vad)
        }
    }

    func stop() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        onEvent = nil
        lock.unlock()
        worker?.cancel()
        worker = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }

    // MARK: - Audio thread

    private func process(_ buffer: AVAudioPCMBuffer, mono: AVAudioFormat, converter: AVAudioConverter) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let source = buffer.floatChannelData?[0],
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(frames)),
              let dest = monoBuffer.floatChannelData?[0] else { return }
        // Voice processing can hand over several channels; the first is the cleaned mic.
        let stride = buffer.stride
        for i in 0..<frames { dest[i] = source[i * stride] }
        monoBuffer.frameLength = AVAudioFrameCount(frames)

        let ratio = target.sampleRate / mono.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return monoBuffer
        }
        guard error == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))

        lock.lock()
        pending.append(contentsOf: samples)
        var chunks: [[Float]] = []
        while pending.count >= Self.chunk {
            chunks.append(Array(pending.prefix(Self.chunk)))
            pending.removeFirst(Self.chunk)
        }
        let continuation = self.continuation
        lock.unlock()
        for chunk in chunks { continuation?.yield(chunk) }
    }

    // MARK: - Turn detection

    private func emit(_ event: Event) {
        lock.lock(); let handler = onEvent; lock.unlock()
        handler?(event)
    }

    private func detect(_ stream: AsyncStream<[Float]>, vad: VadManager) async {
        var vadState = await vad.makeStreamState()
        var noiseFloor: Float = 0.003
        var floorReady = false

        var preroll: [[Float]] = []
        var inSpeech = false
        var speechChunks = 0
        var silenceChunks = 0
        var utterance: [Float] = []
        var partial: String?
        var hangover = 0.5
        let maxSamples = 16_000 * 30

        func reset() {
            inSpeech = false
            speechChunks = 0
            silenceChunks = 0
            utterance = []
            partial = nil
            hangover = 0.5
        }

        for await chunk in stream {
            if Task.isCancelled { break }

            var sum: Float = 0
            for v in chunk { sum += v * v }
            let rms = (sum / Float(chunk.count)).squareRoot()

            let probability: Float
            do {
                let result = try await vad.processStreamingChunk(chunk, state: vadState)
                vadState = result.state
                probability = result.probability
            } catch {
                continue
            }

            let voiceOut = isOutputActive
            // No echo cancellation: don't listen while VOID talks, or it would hear itself.
            if voiceOut && !echoCancelling {
                if inSpeech { emit(.falseStart) }
                reset()
                preroll.removeAll()
                continue
            }

            // While VOID talks, demand clearer, louder speech before treating it as you.
            let needed: Float = voiceOut ? 0.85 : 0.6
            let gate: Float = voiceOut ? 3.0 : 2.0
            let isSpeech = probability >= needed && rms > max(noiseFloor * gate, 0.003)

            // Learn the room's background level from the quiet moments.
            if !inSpeech && !isSpeech {
                noiseFloor = floorReady ? noiseFloor * 0.9 + rms * 0.1 : rms
                floorReady = true
            }
            if !voiceOut { signal.push(rms: rms) }

            if !inSpeech {
                if isSpeech {
                    reset()
                    inSpeech = true
                    speechChunks = 1
                    utterance = preroll.flatMap { $0 } + chunk
                    emit(.speechStarted)
                } else {
                    preroll.append(chunk)
                    if preroll.count > 2 { preroll.removeFirst() }
                }
                continue
            }

            utterance += chunk
            if isSpeech {
                speechChunks += 1
                silenceChunks = 0
                partial = nil
                if speechChunks == 2 { emit(.speechConfirmed) }
            } else {
                silenceChunks += 1
                // A single blip followed by quiet: a cough, a click, a door.
                if speechChunks < 2 && silenceChunks >= 2 {
                    emit(.falseStart)
                    reset()
                    preroll.removeAll()
                    continue
                }
                // First pause: check whether the sentence sounds finished.
                if silenceChunks == 1 && speechChunks >= 2 {
                    let text = (try? await transcriber.transcribe(utterance)) ?? ""
                    partial = text
                    hangover = Self.soundsUnfinished(text) ? 1.5 : 0.5
                }
            }

            let silentFor = Double(silenceChunks) * Self.chunkSeconds
            if speechChunks >= 2 && (silentFor >= hangover || utterance.count >= maxSamples) {
                emit(.utterance(utterance, silenceChunks > 0 ? partial : nil))
                reset()
                preroll.removeAll()
            }
        }
    }

    /// True if the words so far look like the speaker is mid-thought.
    static func soundsUnfinished(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix(",") || trimmed.hasSuffix("...") || trimmed.hasSuffix("…") || trimmed.hasSuffix("-") {
            return true
        }
        let lastWord = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .last.map { String($0).trimmingCharacters(in: .punctuationCharacters) } ?? ""
        let connectors: Set<String> = [
            "and", "but", "or", "so", "because", "cause", "the", "a", "an", "to", "of", "with", "for",
            "um", "uh", "erm", "hmm", "like", "my", "your", "is", "are", "was", "if", "then", "that",
            "which", "what", "in", "on", "at", "about", "maybe", "also", "how", "why", "when", "where",
            "i", "we", "you", "it's", "i'm", "and,", "actually", "basically",
        ]
        return connectors.contains(lastWord)
    }
}
