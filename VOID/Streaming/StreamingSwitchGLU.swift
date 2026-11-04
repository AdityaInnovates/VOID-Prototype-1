import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Where the loader hands the store to the layers it builds.
final class StreamingContext: @unchecked Sendable {
    static let shared = StreamingContext()
    var store: ExpertStore?
}

/// Expert streaming, part 2: a drop-in for the library's `SwitchGLU`.
///
/// It has no expert weights of its own. For each call it (1) reads which experts the router picked
/// (this is the per-layer sync), (2) gets them from the store (cache or disk), (3) stacks just those
/// few experts and runs the same gathered quantized matmuls as the stock layer on the stack.
final class StreamingSwitchGLU: SwitchGLU {
    private let streamLayer: Int
    private let store: ExpertStore
    private let hidden: Int
    private let moeInner: Int

    init(layer: Int, store: ExpertStore, hidden: Int, moeInner: Int) {
        self.streamLayer = layer
        self.store = store
        self.hidden = hidden
        self.moeInner = moeInner
        // Tiny placeholder weights so the module tree stays valid; the real ones live on disk.
        super.init(inputDims: 128, hiddenDims: 128, numExperts: 1)
    }

    private func quant(_ weightPart: Int, inDim: Int) -> (bits: Int, groupSize: Int) {
        let w = store.meta.parts[weightPart].shape      // [out, inWords]
        let s = store.meta.parts[weightPart + 1].shape  // [out, inGroups]
        return (w[1] * 32 / inDim, inDim / s[1])
    }

    override func callAsFunction(_ x: MLXArray, _ indices: MLXArray) -> MLXArray {
        let tokens = max(1, indices.size / max(1, indices.dim(-1)))
        let t0 = CFAbsoluteTimeGetCurrent()

        // 1. which experts did the router pick? (forces everything before this layer to finish)
        let flat = indices.asType(.int32).flattened().asArray(Int32.self)
        var seen = Set<Int>()
        var need = [Int]()
        for v in flat where seen.insert(Int(v)).inserted { need.append(Int(v)) }
        need.sort()
        let t1 = CFAbsoluteTimeGetCurrent()

        // 2. get the experts: a prompt (many experts) is stacked straight from disk buffers;
        //    decoding uses the layer's pool of slots and renumbers the indices to slot numbers
        let parts: [MLXArray]
        var table = [UInt32](repeating: 0, count: store.meta.numExperts)
        if tokens > 1 && need.count > store.capacity {
            parts = store.fetchStacked(layer: streamLayer, experts: need, tokens: tokens)
            for (i, e) in need.enumerated() { table[e] = UInt32(i) }
        } else {
            let pooled = store.fetchPool(layer: streamLayer, experts: need, tokens: tokens)
            parts = pooled.parts
            for (e, slot) in pooled.slots { table[e] = UInt32(slot) }
        }
        let remapped = MLXArray(table)[indices]
        let t2 = CFAbsoluteTimeGetCurrent()

        let (bitsGU, gsGU) = quant(0, inDim: hidden)
        let (bitsD, gsD) = quant(6, inDim: moeInner)

        // 3. the same math as SwitchGLU
        var xe = MLX.expandedDimensions(x, axes: [-2, -3])
        let doSort = indices.size >= 64
        var idx = remapped
        var inverseOrder = MLXArray()
        if doSort {
            (xe, idx, inverseOrder) = gatherSort(x: xe, indices: remapped)
        }

        func project(_ input: MLXArray, _ base: Int, _ bits: Int, _ gs: Int) -> MLXArray {
            MLX.gatherQuantizedMM(
                input, parts[base], scales: parts[base + 1], biases: parts[base + 2],
                rhsIndices: idx, transpose: true, groupSize: gs, bits: bits, mode: .affine,
                sortedIndices: doSort)
        }

        let up = project(xe, 3, bitsGU, gsGU)
        let gate = project(xe, 0, bitsGU, gsGU)
        let activated = compiledSiluProduct(gate, up)
        var out = project(activated, 6, bitsD, gsD)

        if doSort {
            out = scatterUnsort(x: out, invOrder: inverseOrder, shape: indices.shape)
        }
        let result = MLX.squeezed(out, axis: -2)
        if tokens == 1 {
            // profiling: wait for the expert math so its time is counted (the next layer needs it anyway)
            eval(result)
            let t3 = CFAbsoluteTimeGetCurrent()
            store.addProfile(sync: t1 - t0, fetch: t2 - t1, compute: t3 - t2)
        }
        return result
    }
}
