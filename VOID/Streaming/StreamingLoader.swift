import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXNN
import Tokenizers

/// Expert streaming, part 4: loads an LFM2 MoE brain with its experts left on disk.
enum StreamingLoader {
    static let modelType = "lfm2_moe_stream"
    private static var registered = false

    static var slots: Int {
        let v = UserDefaults.standard.integer(forKey: "streamSlots")
        return v > 0 ? v : 10
    }
    static var noCache: Bool { UserDefaults.standard.bool(forKey: "streamNoCache") }

    private static func register() async {
        if registered { return }
        registered = true
        await LLMTypeRegistry.shared.registerModelType(modelType) { data in
            let cfg = try JSONDecoder.json5().decode(LFM2MoEConfiguration.self, from: data)
            let model = LFM2MoEModel(cfg)
            guard let store = StreamingContext.shared.store else {
                throw ExpertConverter.ConvertError.unsupported("expert store is not open")
            }
            // Replace each MoE block's switch_mlp one block at a time (a sparse whole-model update
            // fails because the first decoder layers are dense).
            var swapped = 0
            for (path, block) in model.namedModules() {
                guard case .value(let child)? = block.children()["switch_mlp"], child is SwitchGLU else { continue }
                let comps = path.split(separator: ".").map(String.init)
                guard let li = comps.firstIndex(of: "layers"), li + 1 < comps.count,
                    let layer = Int(comps[li + 1])
                else { continue }
                let streaming = StreamingSwitchGLU(
                    layer: layer, store: store, hidden: cfg.hiddenSize, moeInner: cfg.moeIntermediateSize)
                block.update(modules: ModuleChildren(values: ["switch_mlp": .value(streaming)]))
                swapped += 1
            }
            let updates = Array(repeating: 0, count: swapped)
            StreamLog.write("swapped \(updates.count) expert layers for streaming layers")
            return model
        }
    }

    static func loadContainer(
        configuration: ModelConfiguration,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ModelContainer {
        // 1. the original checkpoint (downloaded once, normally already there)
        let downloader = #hubDownloader()
        let source = try await downloader.download(
            id: configuration.name, revision: nil,
            matching: ["*.safetensors", "*.json", "*.jinja", "*.txt", "*.model"],
            useLatest: false,
            progressHandler: { p in progress(p.fractionCompleted * 0.4) })

        // 2. one-time conversion (a few minutes, about 5 GB of disk)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let destination = support.appendingPathComponent(
            "VOID/Streaming/" + configuration.name.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
        if !ExpertConverter.isPrepared(destination) {
            StreamLog.write("converting \(configuration.name) from \(source.path)")
            try await Task.detached(priority: .userInitiated) {
                try ExpertConverter.prepare(source: source, destination: destination) { msg in
                    StreamLog.write(msg)
                }
            }.value
        }
        progress(0.7)

        // 3. open the expert file and load everything else
        let store = try ExpertStore(directory: destination, capacity: slots, noCache: noCache)
        StreamingContext.shared.store = store
        await register()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: destination, using: #huggingFaceTokenizerLoader())
        // the library only knows this brain's end-of-turn marker by name
        let extra = configuration.extraEOSTokens
        await container.update { $0.configuration.extraEOSTokens.formUnion(extra) }
        progress(1.0)
        StreamLog.write("loaded; process memory after load: \(Memory.activeMemory / 1_048_576) MB active")
        return container
    }
}
