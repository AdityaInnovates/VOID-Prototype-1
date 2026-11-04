import Foundation
import MLX

/// Expert streaming, part 3: one-time conversion of an LFM2 MoE checkpoint.
///
/// Reads the original safetensors lazily (one tensor at a time in memory) and writes, into `destination`:
///   - model.safetensors: everything except the experts, plus tiny placeholders for the expert tensors
///   - experts.bin / experts.json: the experts, one fixed-size record per (layer, expert)
///   - config.json (model_type changed to "lfm2_moe_stream") and links to the tokenizer files
enum ExpertConverter {
    enum ConvertError: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            if case .unsupported(let s) = self { return "Expert streaming: \(s)" }
            return nil
        }
    }

    static let projections = ["gate_proj", "up_proj", "down_proj"]
    static let kinds = ["weight", "scales", "biases"]

    static func isPrepared(_ destination: URL) -> Bool {
        let fm = FileManager.default
        return ["experts.json", "experts.bin", "model.safetensors", "config.json"].allSatisfy {
            fm.fileExists(atPath: destination.appendingPathComponent($0).path)
        }
    }

    static func prepare(source: URL, destination: URL, progress: @escaping (String) -> Void) throws {
        if isPrepared(destination) { return }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // --- config
        let cfgData = try Data(contentsOf: source.appendingPathComponent("config.json"))
        guard var cfg = try JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
            let hidden = (cfg["hidden_size"] as? NSNumber)?.intValue,
            let moeInner = (cfg["moe_intermediate_size"] as? NSNumber)?.intValue,
            let numExperts = (cfg["num_experts"] as? NSNumber)?.intValue
        else { throw ConvertError.unsupported("config.json lacks the LFM2 MoE fields") }

        // --- read tensors (lazy), keep non-experts, collect experts per layer
        let files = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw ConvertError.unsupported("no safetensors files found") }

        var resident = [String: MLXArray]()
        var expertTensors = [Int: [String: MLXArray]]()   // layer -> "gate_proj.weight" -> stacked tensor
        for (i, file) in files.enumerated() {
            progress("Reading \(file.lastPathComponent) (\(i + 1)/\(files.count))")
            let (arrays, _) = try loadArraysAndMetadata(url: file, stream: .cpu)
            var keep = [MLXArray]()
            for (key, arr) in arrays {
                if key.contains(".experts.") {
                    throw ConvertError.unsupported("this checkpoint stores experts one by one; use a pre-stacked mlx-community build")
                }
                if key.contains(".switch_mlp.") {
                    let comps = key.split(separator: ".").map(String.init)
                    guard let li = comps.firstIndex(of: "layers"), li + 1 < comps.count,
                        let layer = Int(comps[li + 1]), comps.count >= 2
                    else { throw ConvertError.unsupported("cannot read layer number from \(key)") }
                    let part = comps[comps.count - 2] + "." + comps[comps.count - 1]
                    expertTensors[layer, default: [:]][part] = arr
                } else {
                    resident[key] = arr
                    keep.append(arr)
                }
            }
            eval(keep)
        }

        let layers = expertTensors.keys.sorted()
        guard !layers.isEmpty else { throw ConvertError.unsupported("no switch_mlp tensors found") }
        let partNames = projections.flatMap { p in kinds.map { "\(p).\($0)" } }
        for l in layers {
            for n in partNames where expertTensors[l]?[n] == nil {
                throw ConvertError.unsupported("layer \(l) is missing \(n) (only affine-quantized builds are supported)")
            }
        }

        // --- per-expert layout from layer 0
        var parts = [ExpertPartMeta]()
        var offset = 0
        let first = expertTensors[layers[0]]!
        for n in partNames {
            let t = first[n]!
            guard t.dim(0) == numExperts else { throw ConvertError.unsupported("\(n) has \(t.dim(0)) experts, config says \(numExperts)") }
            let name = streamDTypeName(t.dtype)
            guard name != "unsupported" else { throw ConvertError.unsupported("dtype \(t.dtype) in \(n)") }
            let bytes = t.nbytes / numExperts
            parts.append(ExpertPartMeta(
                name: n, shape: Array(t.shape.dropFirst()), dtype: name, offset: offset, bytes: bytes))
            offset += bytes
        }
        let recordBytes = ((offset + 16383) / 16384) * 16384
        let meta = ExpertStoreMeta(numExperts: numExperts, layers: layers, recordBytes: recordBytes, parts: parts)

        // --- write experts.bin (layer-major, expert-minor)
        let binURL = destination.appendingPathComponent("experts.bin")
        fm.createFile(atPath: binURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: binURL)
        defer { try? handle.close() }
        for (li, layer) in layers.enumerated() {
            progress("Writing experts, layer \(li + 1)/\(layers.count)")
            let tensors = partNames.map { expertTensors[layer]![$0]! }
            eval(tensors)
            for e in 0 ..< numExperts {
                var record = Data(capacity: recordBytes)
                for (pi, t) in tensors.enumerated() {
                    let d = t[e].asData(access: .copy).data
                    guard d.count == parts[pi].bytes else { throw ConvertError.unsupported("size mismatch in layer \(layer)") }
                    record.append(d)
                }
                record.append(Data(count: recordBytes - record.count))
                try handle.write(contentsOf: record)
            }
            expertTensors[layer] = nil   // free this layer's tensors
        }
        try JSONEncoder().encode(meta).write(to: destination.appendingPathComponent("experts.json"))

        // --- placeholders so the stock module tree loads (quantized tiny experts, shape [1,128,128])
        for layer in layers {
            for (pi, proj) in projections.enumerated() {
                let inDim = proj == "down_proj" ? moeInner : hidden
                let w = parts[pi * 3].shape      // [out, inWords]
                let s = parts[pi * 3 + 1].shape  // [out, inGroups]
                let bits = w[1] * 32 / inDim
                let gs = inDim / s[1]
                let (wq, sc, bi) = MLX.quantized(
                    MLXArray.zeros([1, 128, 128]), groupSize: gs, bits: bits, mode: .affine)
                let prefix = "model.layers.\(layer).feed_forward.switch_mlp.\(proj)"
                resident["\(prefix).weight"] = wq
                resident["\(prefix).scales"] = sc
                resident["\(prefix).biases"] = bi
            }
        }
        progress("Saving the non-expert weights")
        try save(arrays: resident, metadata: ["format": "mlx"], url: destination.appendingPathComponent("model.safetensors"))

        cfg["model_type"] = "lfm2_moe_stream"
        try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted])
            .write(to: destination.appendingPathComponent("config.json"))

        // --- tokenizer & friends
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let name = item.lastPathComponent
            if name == "config.json" || name == "model.safetensors.index.json" || item.pathExtension == "safetensors" { continue }
            let dest = destination.appendingPathComponent(name)
            try? fm.removeItem(at: dest)
            try fm.createSymbolicLink(at: dest, withDestinationURL: item.resolvingSymlinksInPath())
        }
        StreamLog.write("converted \(layers.count) layers, record \(recordBytes / 1024) KB, experts.bin ~\(layers.count * numExperts * recordBytes / 1_048_576) MB")
    }
}
