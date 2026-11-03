import AVFoundation
import Foundation

/// Records the microphone as 16 kHz mono Float, which is what Parakeet wants.
/// It also feeds the orb's level signal, and can notice when you stop talking.
final class VoiceInput: @unchecked Sendable {
    enum Failure: Error { case denied, noInput }

    private let engine = AVAudioEngine()
    private let signal: OrbSignal
    private let lock = NSLock()
    private var samples: [Float] = []
    private var running = false

    // Silence detection (only used by tap-to-talk).
    private var heardSpeech = false
    private var silentSince: TimeInterval?
    private var startedAt: TimeInterval = 0
    private var onSilence: (@Sendable () -> Void)?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    init(signal: OrbSignal) {
        self.signal = signal
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Starts recording. If `autoStop` is given, it fires once after speech was heard
    /// and then about 1.1 s of quiet followed (or after 20 s at most).
    func start(autoStop: (@Sendable () -> Void)? = nil) throws {
        lock.lock()
        if running { lock.unlock(); return }
        samples.removeAll(keepingCapacity: true)
        heardSpeech = false
        silentSince = nil
        startedAt = Date.timeIntervalSinceReferenceDate
        onSilence = autoStop
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw Failure.noInput }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { throw Failure.noInput }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer, converter: converter)
        }
        engine.prepare()
        try engine.start()

        lock.lock()
        running = true
        lock.unlock()
    }

    /// Stops recording and returns everything captured as 16 kHz mono samples.
    @discardableResult
    func stop() -> [Float] {
        lock.lock()
        let wasRunning = running
        running = false
        onSilence = nil
        lock.unlock()

        if wasRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        lock.lock()
        let out = samples
        samples.removeAll(keepingCapacity: false)
        lock.unlock()
        return out
    }

    private func process(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0] else { return }
        let count = Int(out.frameLength)
        guard count > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))

        var sum: Float = 0
        for v in chunk { sum += v * v }
        let rms = (sum / Float(count)).squareRoot()
        signal.push(rms: rms)

        var fire: (@Sendable () -> Void)?
        lock.lock()
        samples.append(contentsOf: chunk)
        if onSilence != nil {
            let now = Date.timeIntervalSinceReferenceDate
            if rms > 0.012 {
                heardSpeech = true
                silentSince = nil
            } else if silentSince == nil {
                silentSince = now
            }
            let quietFor = silentSince.map { now - $0 } ?? 0
            if (heardSpeech && quietFor > 1.1) || now - startedAt > 20 {
                fire = onSilence
                onSilence = nil
            }
        }
        lock.unlock()
        fire?()
    }
}
