import FluidAudio
import Foundation

/// Speech to text with Parakeet TDT 0.6B v3, running on the Neural Engine via FluidAudio.
actor Transcriber {
    private var manager: AsrManager?

    var isLoaded: Bool { manager != nil }

    /// Downloads (first run only) and loads the model.
    func load(progress: @escaping @Sendable (Double) -> Void) async throws {
        if manager != nil { return }
        let models = try await AsrModels.downloadAndLoad(
            version: .v3,
            progressHandler: { p in progress(p.fractionCompleted) }
        )
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        manager = asr
    }

    /// `samples` must be 16 kHz mono Float.
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { return "" }
        // The model needs at least a second of audio; pad short clips with silence.
        var audio = samples
        let minimum = 16_000 + 1_600
        if audio.count < minimum {
            audio.append(contentsOf: [Float](repeating: 0, count: minimum - audio.count))
        }
        var state = TdtDecoderState.make()
        let result = try await manager.transcribe(audio, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() {
        manager = nil
    }
}
