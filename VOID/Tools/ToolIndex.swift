import Foundation
import NaturalLanguage

/// Semantic search over VOID's tools, built into the app: no database process, no download.
/// Uses the sentence embedding that ships with macOS. Scores blend meaning (cosine over the
/// tool's description and example sentences) with shared words, so a rare tool name still wins.
actor ToolIndex {
    struct Match: Sendable {
        let spec: ToolSpec
        let score: Double
        /// How many action words the message shares with this tool ("lock", "battery", "clipboard").
        /// Zero means the match is only a vague similarity in meaning.
        var evidence: Int = 0
    }

    /// Below this best score, the message is treated as not being about a tool at all.
    static let threshold = 0.58

    private var vectors: [(spec: ToolSpec, texts: [(text: String, vector: [Double])])] = []
    private var embedder: NLEmbedding?
    private var built = false

    /// Embeds every tool once. Cheap (about a hundred short sentences); runs off the main thread.
    func build() {
        guard !built else { return }
        built = true
        embedder = NLEmbedding.sentenceEmbedding(for: .english)
        vectors = ToolRegistry.all.map { spec in
            (spec, spec.texts.map { ($0, embed($0) ?? []) })
        }
    }

    var isAvailable: Bool { embedder != nil }

    func search(_ query: String, limit: Int = 4, targets: Set<ToolSpec.Target>? = nil) -> [Match] {
        build()
        let cleaned = Self.clean(query)
        guard !cleaned.isEmpty else { return [] }
        let asked = embed(cleaned)
        let askedWords = Self.words(cleaned)

        let askedStems = Set(askedWords.subtracting(Self.weak).map(Self.stem))
        var matches: [Match] = []
        for entry in vectors {
            if let targets, !targets.contains(entry.spec.target) { continue }
            var specWords = Set<String>()
            for (text, _) in entry.texts { specWords.formUnion(Self.words(text).map(Self.stem)) }
            let evidence = askedStems.intersection(specWords).count
            var best = 0.0
            for (text, vector) in entry.texts {
                var score = 0.0
                if let asked, !vector.isEmpty { score = Self.cosine(asked, vector) }
                // A little credit for shared meaningful words ("flashlight", "notifications").
                let shared = askedWords.intersection(Self.words(text))
                if !shared.isEmpty { score += min(0.12, 0.06 * Double(shared.count)) }
                best = max(best, score)
            }
            matches.append(Match(spec: entry.spec, score: best, evidence: evidence))
        }
        return Array(matches.sorted { $0.score > $1.score }.prefix(limit))
    }

    // MARK: Helpers

    private func embed(_ text: String) -> [Double]? {
        embedder?.vector(for: text.lowercased())
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count {
            dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]
        }
        let d = (na * nb).squareRoot()
        return d > 0 ? dot / d : 0
    }

    private static let stop: Set<String> = [
        "the", "a", "an", "my", "me", "to", "on", "of", "is", "it", "i", "and", "for", "please", "can", "you",
        "do", "have", "any", "what", "whats", "what's", "this", "that", "in", "at", "up", "new",
    ]

    /// Words that say little about WHICH tool is meant.
    private static let weak: Set<String> = [
        "off", "turn", "tell", "show", "read", "set", "get", "give", "make", "check", "want", "like", "need",
        "know", "time", "hey", "void", "some", "something", "thing", "play", "open", "start", "stop", "good",
        "mood", "are", "you", "your", "morning", "focus", "phone", "mac", "mobile", "laptop", "computer", "from", "with", "about", "how", "why", "who",
    ]

    private static func stem(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") ? String(word.dropLast()) : word
    }

    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stop.contains($0) })
    }

    /// Drops "hey void", "please" and the like so they don't dilute the meaning.
    static func clean(_ text: String) -> String {
        MusicIntent.normalizeCommand(text)
    }
}
