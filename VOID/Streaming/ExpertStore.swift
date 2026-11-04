import Foundation
import MLX

/// Expert streaming, part 1: the on-disk expert file and the per-layer cache.
///
/// `experts.bin` holds one fixed-size record per (layer, expert): all nine tensors
/// (gate/up/down x weight/scales/biases) back to back, padded to 16 KB. A record is read with
/// parallel `pread`s; a small LRU per layer keeps the most recently used experts as MLXArrays.

struct ExpertPartMeta: Codable {
    var name: String      // e.g. "gate_proj.weight"
    var shape: [Int]      // per-expert shape
    var dtype: String
    var offset: Int       // inside the record
    var bytes: Int
}

struct ExpertStoreMeta: Codable {
    var numExperts: Int
    var layers: [Int]     // decoder layer indices that hold experts, in file order
    var recordBytes: Int
    var parts: [ExpertPartMeta]   // 9 parts, order: gate w/s/b, up w/s/b, down w/s/b
}

func streamDType(_ name: String) -> DType? {
    switch name {
    case "uint32": return .uint32
    case "bfloat16": return .bfloat16
    case "float16": return .float16
    case "float32": return .float32
    case "uint8": return .uint8
    default: return nil
    }
}

func streamDTypeName(_ d: DType) -> String {
    switch d {
    case .uint32: return "uint32"
    case .bfloat16: return "bfloat16"
    case .float16: return "float16"
    case .float32: return "float32"
    case .uint8: return "uint8"
    default: return "unsupported"
    }
}

/// Where the streaming experiment writes its numbers (read it and send it to me).
enum StreamLog {
    static var url: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("VOID/Streaming", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stream.log")
    }()
    private static let lock = NSLock()
    static func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        let data = Data("\(stamp) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

final class ExpertStore: @unchecked Sendable {
    struct Expert { let parts: [MLXArray] }

    let meta: ExpertStoreMeta
    let capacity: Int
    private let fd: Int32
    private let layerOrdinal: [Int: Int]
    private var caches: [[Int: Expert]]
    private var order: [[Int]]          // per layer, least recently used first
    private let lock = NSLock()

    // stats
    private var hits = 0, misses = 0, bytesRead = 0
    private var readSeconds = 0.0, buildSeconds = 0.0
    private var calls = 0

    // phase timing (decode vs prompt processing)
    private var lastStart: CFAbsoluteTime?
    private var lastTokens = 0
    private var decodeSteps = 0, prefillTokens = 0
    private var decodeSeconds = 0.0, prefillSeconds = 0.0
    private var prefillReadBytes = 0, decodeReadBytes = 0
    private var syncSec = 0.0, fetchSec = 0.0, computeSec = 0.0
    private var decodeReadSec = 0.0, decodeCopySec = 0.0

    /// One layer's fixed-size pool: nine stacked tensors with `capacity` expert slots, updated in place.
    final class Pool {
        var parts: [MLXArray] = []
        /// Raw memory behind each pool tensor. Unified memory: the CPU copies a missing expert straight
        /// into its slot, no MLX operation needed. Safe because every layer syncs on the router's
        /// choice first, so no earlier GPU work is still reading the pool.
        var pointers: [UnsafeMutableRawPointer] = []
        var slotOf: [Int: Int] = [:]
        var expertAt: [Int]            // expert held by each slot, -1 when empty
        var lru: [Int]                 // slots, least recently used first
        init(capacity: Int) {
            expertAt = Array(repeating: -1, count: capacity)
            lru = Array(0 ..< capacity)
        }
    }
    private var pools: [Pool?] = []

    /// Split each record into this many parallel reads.
    private let splits = 2

    init(directory: URL, capacity: Int, noCache: Bool) throws {
        let data = try Data(contentsOf: directory.appendingPathComponent("experts.json"))
        meta = try JSONDecoder().decode(ExpertStoreMeta.self, from: data)
        self.capacity = capacity
        var map = [Int: Int]()
        for (i, l) in meta.layers.enumerated() { map[l] = i }
        layerOrdinal = map
        pools = Array(repeating: nil, count: meta.layers.count)
        caches = Array(repeating: [:], count: meta.layers.count)
        order = Array(repeating: [], count: meta.layers.count)
        let path = directory.appendingPathComponent("experts.bin").path
        fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        if noCache { _ = fcntl(fd, F_NOCACHE, 1) }
        StreamLog.write("store open: \(meta.layers.count) layers x \(meta.numExperts) experts, record \(meta.recordBytes / 1024) KB, slots/layer \(capacity), noCache \(noCache)")
    }

    deinit { close(fd) }

    var cachedMB: Double {
        Double(caches.reduce(0) { $0 + $1.count } * meta.recordBytes) / 1_048_576
    }

    /// Called by the first expert layer of every forward pass; times prompt processing and decoding.
    private func markForward(tokens: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        if let prev = lastStart {
            let dt = now - prev
            if lastTokens > 1 {
                prefillSeconds += dt; prefillTokens += lastTokens
                StreamLog.write(String(format: "prompt of %d tokens took %.2fs (%.0f tok/s); read so far %.0f MB",
                    lastTokens, dt, Double(lastTokens) / dt, Double(bytesRead) / 1_048_576))
            } else if dt < 5 {
                decodeSeconds += dt; decodeSteps += 1
                if decodeSteps % 50 == 0 {
                    let n = Double(decodeSteps)
                    StreamLog.write(String(format: "decode: %d tokens, %.1f tok/s; miss rate %.2f; reads %.0f MB/token; per token: sync %.0f ms, fetch %.0f ms (disk %.0f + copy %.0f), compute %.0f ms",
                        decodeSteps, n / decodeSeconds,
                        Double(misses) / Double(max(1, hits + misses)),
                        Double(decodeReadBytes) / 1_048_576 / n,
                        syncSec / n * 1000, fetchSec / n * 1000, decodeReadSec / n * 1000,
                        decodeCopySec / n * 1000, computeSec / n * 1000))
                }
            }
        }
        lastStart = now
        lastTokens = tokens
    }

    func addProfile(sync: Double, fetch: Double, compute: Double) {
        lock.lock(); syncSec += sync; fetchSec += fetch; computeSec += compute; lock.unlock()
    }

    /// Decode: keep each layer's experts in a fixed pool of slots that is updated in place, so a step
    /// only copies the experts that are missing. Returns the pool tensors and expert -> slot.
    func fetchPool(layer: Int, experts: [Int], tokens: Int) -> (parts: [MLXArray], slots: [Int: Int]) {
        lock.lock(); defer { lock.unlock() }
        guard let ord = layerOrdinal[layer] else { return ([], [:]) }
        if ord == 0 { markForward(tokens: tokens) }
        let cap = max(capacity, 8)
        if pools[ord] == nil {
            let pool = Pool(capacity: cap)
            for p in meta.parts {
                // real zero-filled memory (not a lazy constant), so the CPU can write into it
                let arr = MLXArray(Data(count: cap * p.bytes), [cap] + p.shape, dtype: streamDType(p.dtype) ?? .uint32)
                let raw = arr.asData(access: .noCopy).data
                let base: UnsafeMutableRawPointer = raw.withUnsafeBytes { UnsafeMutableRawPointer(mutating: $0.baseAddress!) }
                pool.parts.append(arr)
                pool.pointers.append(base)
            }
            pools[ord] = pool
        }
        let pool = pools[ord]!
        var missing = [Int]()
        var wantedSlots = Set<Int>()
        for e in experts {
            if let slot = pool.slotOf[e] {
                hits += 1
                wantedSlots.insert(slot)
                if let i = pool.lru.firstIndex(of: slot) { pool.lru.remove(at: i) }
                pool.lru.append(slot)
            } else {
                missing.append(e)
            }
        }
        misses += missing.count

        if !missing.isEmpty {
            let rec = meta.recordBytes
            let buffers = missing.map { _ in UnsafeMutableRawPointer.allocate(byteCount: rec, alignment: 16384) }
            defer { buffers.forEach { $0.deallocate() } }
            let fd = self.fd
            let chunk = ((rec / splits + 16383) / 16384) * 16384
            let t0 = CFAbsoluteTimeGetCurrent()
            DispatchQueue.concurrentPerform(iterations: missing.count * splits) { job in
                let m = job / splits, sp = job % splits
                let start = sp * chunk
                guard start < rec else { return }
                let len = min(chunk, rec - start)
                let base = (ord * meta.numExperts + missing[m]) * rec + start
                var done = 0
                while done < len {
                    let r = pread(fd, buffers[m] + start + done, len - done, off_t(base + done))
                    if r <= 0 { break }
                    done += r
                }
            }
            let t1 = CFAbsoluteTimeGetCurrent()
            for (m, e) in missing.enumerated() {
                // least recently used slot that this call is not using
                var pick = 0
                while wantedSlots.contains(pool.lru[pick]) { pick += 1 }
                let slot = pool.lru.remove(at: pick)
                if pool.expertAt[slot] >= 0 { pool.slotOf[pool.expertAt[slot]] = nil }
                pool.expertAt[slot] = e
                pool.slotOf[e] = slot
                pool.lru.append(slot)
                wantedSlots.insert(slot)
                for (pi, p) in meta.parts.enumerated() {
                    memcpy(pool.pointers[pi] + slot * p.bytes, buffers[m] + p.offset, p.bytes)
                }
            }
            let t2 = CFAbsoluteTimeGetCurrent()
            readSeconds += t1 - t0
            buildSeconds += t2 - t1
            decodeReadSec += t1 - t0
            decodeCopySec += t2 - t1
            bytesRead += missing.count * rec
            decodeReadBytes += missing.count * rec
        }
        var slots = [Int: Int]()
        for e in experts { slots[e] = pool.slotOf[e] }
        return (pool.parts, slots)
    }

    /// Prompt-sized requests: read every needed expert and build the stacked tensors straight from
    /// the file buffers (no per-expert arrays, nothing enters the cache).
    func fetchStacked(layer: Int, experts: [Int], tokens: Int) -> [MLXArray] {
        lock.lock(); defer { lock.unlock() }
        guard let ord = layerOrdinal[layer] else { return [] }
        if ord == 0 { markForward(tokens: tokens) }
        let rec = meta.recordBytes
        let n = experts.count
        let buffers = experts.map { _ in UnsafeMutableRawPointer.allocate(byteCount: rec, alignment: 16384) }
        defer { buffers.forEach { $0.deallocate() } }
        let fd = self.fd
        let chunk = ((rec / splits + 16383) / 16384) * 16384
        let t0 = CFAbsoluteTimeGetCurrent()
        DispatchQueue.concurrentPerform(iterations: n * splits) { job in
            let m = job / splits, s = job % splits
            let start = s * chunk
            guard start < rec else { return }
            let len = min(chunk, rec - start)
            let base = (ord * meta.numExperts + experts[m]) * rec + start
            var done = 0
            while done < len {
                let r = pread(fd, buffers[m] + start + done, len - done, off_t(base + done))
                if r <= 0 { break }
                done += r
            }
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        var out = [MLXArray]()
        for p in meta.parts {
            var data = Data(count: n * p.bytes)
            data.withUnsafeMutableBytes { dst in
                for m in 0 ..< n {
                    memcpy(dst.baseAddress! + m * p.bytes, buffers[m] + p.offset, p.bytes)
                }
            }
            out.append(MLXArray(data, [n] + p.shape, dtype: streamDType(p.dtype) ?? .uint32))
        }
        let t2 = CFAbsoluteTimeGetCurrent()
        readSeconds += t1 - t0
        buildSeconds += t2 - t1
        bytesRead += n * rec
        prefillReadBytes += n * rec
        return out
    }

    /// Returns the requested experts, reading the ones that are not cached.
    func fetch(layer: Int, experts: [Int], tokens: Int = 1) -> [Int: Expert] {
        lock.lock(); defer { lock.unlock() }
        guard let ord = layerOrdinal[layer] else { return [:] }
        if ord == 0 { markForward(tokens: tokens) }
        var result = [Int: Expert]()
        var missing = [Int]()
        for e in experts {
            if let ex = caches[ord][e] {
                result[e] = ex
                hits += 1
                if let i = order[ord].firstIndex(of: e) { order[ord].remove(at: i) }
                order[ord].append(e)
            } else {
                missing.append(e)
            }
        }
        misses += missing.count

        if !missing.isEmpty {
            let rec = meta.recordBytes
            let buffers = missing.map { _ in
                UnsafeMutableRawPointer.allocate(byteCount: rec, alignment: 16384)
            }
            defer { buffers.forEach { $0.deallocate() } }
            let fd = self.fd
            let chunk = ((rec / splits + 16383) / 16384) * 16384
            let t0 = CFAbsoluteTimeGetCurrent()
            DispatchQueue.concurrentPerform(iterations: missing.count * splits) { job in
                let m = job / splits, s = job % splits
                let start = s * chunk
                guard start < rec else { return }
                let len = min(chunk, rec - start)
                let base = (ord * meta.numExperts + missing[m]) * rec + start
                var done = 0
                while done < len {
                    let n = pread(fd, buffers[m] + start + done, len - done, off_t(base + done))
                    if n <= 0 { break }
                    done += n
                }
            }
            let t1 = CFAbsoluteTimeGetCurrent()
            for (m, e) in missing.enumerated() {
                var arrays = [MLXArray]()
                for p in meta.parts {
                    let d = Data(bytesNoCopy: buffers[m] + p.offset, count: p.bytes, deallocator: .none)
                    arrays.append(MLXArray(d, p.shape, dtype: streamDType(p.dtype) ?? .uint32))
                }
                let ex = Expert(parts: arrays)
                result[e] = ex
                caches[ord][e] = ex
                order[ord].append(e)
            }
            let t2 = CFAbsoluteTimeGetCurrent()
            readSeconds += t1 - t0
            buildSeconds += t2 - t1
            bytesRead += missing.count * rec
            decodeReadBytes += missing.count * rec
        }

        // trim, but never drop something this call asked for
        let wanted = Set(experts)
        var i = 0
        while caches[ord].count > capacity && i < order[ord].count {
            let victim = order[ord][i]
            if wanted.contains(victim) { i += 1; continue }
            order[ord].remove(at: i)
            caches[ord][victim] = nil
        }

        return result
    }

    private func report() {
        let total = hits + misses
        let miss = total > 0 ? Double(misses) / Double(total) : 0
        let mb = Double(bytesRead) / 1_048_576
        StreamLog.write(String(
            format: "after %d tokens: miss rate %.2f, read %.0f MB (%.0f MB/token), read time %.2fs (%.2f GB/s), array build %.2fs, cached %.0f MB",
            calls, miss, mb, mb / Double(calls), readSeconds,
            readSeconds > 0 ? mb / 1024 / readSeconds : 0, buildSeconds, cachedMB))
    }
}
