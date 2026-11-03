import Foundation

/// The live loudness of whatever is being heard or spoken, shared between the audio
/// threads (which write it) and the orb (which reads it every frame).
/// It keeps a short history so the orb's grid can ripple outward from the equator.
final class OrbSignal: @unchecked Sendable {
    static let historyCount = 40

    private let lock = NSLock()
    private var current: Float = 0
    private var history = [Float](repeating: 0, count: OrbSignal.historyCount)
    private var lastPush: TimeInterval = 0

    /// Called from audio threads. `rms` is the raw RMS of a buffer (0...1).
    func push(rms: Float) {
        // Gentle companding so quiet speech still moves the orb.
        let shaped = min(1, pow(max(0, rms) * 7.0, 0.65))
        let now = Date.timeIntervalSinceReferenceDate
        lock.lock()
        defer { lock.unlock() }
        // Fast attack, slower release: reads as a smooth swell instead of flicker.
        current = shaped > current ? current + (shaped - current) * 0.6 : current + (shaped - current) * 0.18
        // Shift history at ~30 steps per second, whatever the buffer size is.
        if now - lastPush >= 1.0 / 30.0 {
            lastPush = now
            history.removeLast()
            history.insert(current, at: 0)
        }
    }

    /// Lets the level fall back to silence (called each frame by the orb when nothing is pushing).
    func decay() {
        let now = Date.timeIntervalSinceReferenceDate
        lock.lock()
        defer { lock.unlock() }
        if now - lastPush >= 1.0 / 30.0 {
            lastPush = now
            current *= 0.88
            history.removeLast()
            history.insert(current, at: 0)
        }
    }

    func snapshot() -> (level: Float, history: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        return (current, history)
    }
}
