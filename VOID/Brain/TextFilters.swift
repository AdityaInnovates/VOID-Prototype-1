import Foundation

enum SpokenText {
    /// Removes any <think>…</think> block (closed or still open).
    static func stripThinking(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: "<think>[\\s\\S]*?</think>",
            with: "",
            options: .regularExpression
        )
        if let open = result.range(of: "<think>") {
            result = String(result[..<open.lowerBound])
        }
        return result
    }

    /// Makes model output suitable for speaking: no think blocks, no markdown symbols.
    static func clean(_ text: String) -> String {
        var result = stripThinking(text)
        for symbol in ["**", "*", "#", "`"] {
            result = result.replacingOccurrences(of: symbol, with: "")
        }
        return result
    }

    /// Removes voice sound tags like [chuckle] for captions and plain voices.
    static func stripVoiceTags(_ text: String) -> String {
        let stripped = text.replacingOccurrences(
            of: "\\s?\\[(chuckle|laugh|sigh|gasp|cough|clear throat|sniff|groan|shush)\\]",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return stripped
    }

    static func dropLeadingWhitespace(_ text: String) -> String {
        String(text.drop(while: { $0.isWhitespace }))
    }

    /// The last part of a long text, for the one-line caption under the orb.
    static func tail(_ text: String, max: Int) -> String {
        guard text.count > max else { return text }
        return "…" + String(text.suffix(max))
    }
}

/// Filters a token stream into speakable text, emitting only what's new each time.
struct SpokenStreamFilter {
    private var raw = ""
    private var emittedCount = 0

    mutating func feed(_ chunk: String) -> String {
        raw += chunk
        var cleaned = SpokenText.clean(raw)
        if emittedCount == 0 {
            cleaned = SpokenText.dropLeadingWhitespace(cleaned)
        }
        guard cleaned.count > emittedCount else { return "" }
        let new = String(cleaned.dropFirst(emittedCount))
        emittedCount = cleaned.count
        return new
    }
}

/// Reads the reflex brain's one-line reply: "ANSWER: …" or "LEAD: …".
struct ReflexParser {
    enum Kind: Equatable { case undecided, answer, wait, unknown }

    private(set) var kind: Kind = .undecided
    private var raw = ""

    mutating func feed(_ chunk: String) {
        raw += chunk
        if kind == .undecided { decide() }
    }

    /// True once the model has finished its line (we stop it there).
    var lineComplete: Bool {
        guard kind == .answer || kind == .wait else { return false }
        return afterPrefix.contains("\n")
    }

    /// The words after the prefix, on the first line only.
    var body: String {
        let firstLine = afterPrefix
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        return SpokenText.clean(firstLine).trimmingCharacters(in: .whitespaces)
    }

    private var leading: String {
        SpokenText.dropLeadingWhitespace(SpokenText.stripThinking(raw))
            .replacingOccurrences(of: "**", with: "")
    }

    private var afterPrefix: String {
        let text = leading
        guard let colon = text.firstIndex(of: ":") else { return "" }
        return SpokenText.dropLeadingWhitespace(String(text[text.index(after: colon)...]))
    }

    private mutating func decide() {
        let head = leading.uppercased()
        if head.hasPrefix("ANSWER:") { kind = .answer; return }
        if head.hasPrefix("LEAD:") || head.hasPrefix("WAIT:") { kind = .wait; return }
        let start = String(head.prefix(7))
        if start.isEmpty { return }
        if "ANSWER:".hasPrefix(start) || "LEAD:".hasPrefix(start) || "WAIT:".hasPrefix(start) { return }
        kind = .unknown
    }
}
