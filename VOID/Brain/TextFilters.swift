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

    /// Makes model output suitable for speaking: no think blocks, no markdown symbols, and stage
    /// directions like *sighs*, (chuckles) or [sighs] turned into the voice's own tags (or dropped).
    static func clean(_ text: String) -> String {
        var result = stripThinking(text)
        result = normalizeEmotes(result)
        result = addColour(result)
        // an emote still being written (e.g. "*chuck") waits until it is complete
        result = result.replacingOccurrences(
            of: #"[\*\(\[~](?=\S)[^*()\[\]~\n]{0,25}$"#, with: "", options: .regularExpression)
        for symbol in ["**", "*", "#", "`"] {
            result = result.replacingOccurrences(of: symbol, with: "")
        }
        return result
    }

    /// Small models rarely write the sound tags themselves. When a reply has none, add ONE where the words
    /// already carry the feeling (laughter, sympathy, a wry aside). The match is always a complete phrase
    /// and the tag goes after it, so text that was already spoken never changes while a reply streams in.
    private static let colourCues: [(pattern: String, tag: String, replaceMatch: Bool)] = [
        (#"\b(?:ha){2,}\b|\b(?:he){2,}\b"#, "[laugh]", true),
        (#"\bheh\b"#, "[chuckle]", true),
        (#"\bsorry to hear that\b|\bthat sounds (?:really )?(?:rough|hard|tough|draining|exhausting|heavy|frustrating)\b"#, " [sigh]", false),
        (#"\bthat'?s (?:actually )?(?:funny|hilarious|kind of funny)\b|\bfunny thing\b|\bfunny enough\b"#, " [chuckle]", false),
        (#"\bwhoa\b|\boh wow\b|\bno way\b"#, " [gasp]", false),
    ]

    private static func addColour(_ text: String) -> String {
        guard !text.contains("[") else { return text }     // the model already wrote its own
        let serious = ["passed away", "died", "funeral", "cancer", "suicide", "hospital", "emergency"]
        let lower = text.lowercased()
        if serious.contains(where: { lower.contains($0) }) { return text }
        let ns = text as NSString
        var best: (range: NSRange, tag: String, replace: Bool)?
        for cue in colourCues {
            guard let re = try? NSRegularExpression(pattern: cue.pattern, options: .caseInsensitive),
                let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            else { continue }
            if best == nil || m.range.location < best!.range.location {
                best = (m.range, cue.tag, cue.replaceMatch)
            }
        }
        guard let b = best, let r = Range(b.range, in: text) else { return text }
        var out = text
        if b.replace {
            out.replaceSubrange(r, with: b.tag)
        } else {
            out.insert(contentsOf: b.tag, at: r.upperBound)
        }
        return out
    }

    private static let emoteSpan = try! NSRegularExpression(
        pattern: #"\*([^*\n]{1,40})\*|\(([^()\n]{1,40})\)|\[([^\[\]\n]{1,40})\]|~([^~\n]{1,40})~"#)

    /// The voice tag for a stage direction, "" for one to drop, or nil if it is ordinary text.
    private static func emoteTag(_ raw: String) -> String? {
        var t = raw.lowercased().trimmingCharacters(in: .whitespaces)
        for adverb in ["softly ", "gently ", "quietly ", "lightly ", "dryly ", "wryly ", "a little ",
                       "a bit ", "briefly ", "warmly ", "slightly ", "deeply ", "heavily ", "quick ", "short "] {
            if t.hasPrefix(adverb) { t = String(t.dropFirst(adverb.count)) }
        }
        let tags: [(String, String)] = [
            ("chuckl", "[chuckle]"), ("giggl", "[laugh]"), ("snicker", "[laugh]"), ("laugh", "[laugh]"),
            ("sigh", "[sigh]"), ("gasp", "[gasp]"), ("cough", "[cough]"), ("clear", "[clear throat]"),
            ("sniff", "[sniff]"), ("groan", "[groan]"), ("shush", "[shush]"),
        ]
        for (stem, tag) in tags where t.hasPrefix(stem) { return tag }
        let silent = ["smil", "grin", "nod", "wink", "shrug", "smirk", "yawn", "hum", "pause", "beam",
                      "blush", "grimac", "exhal", "inhal", "scoff", "tsk", "whisper", "lean", "tilt",
                      "raise", "rolls eyes", "roll eyes", "shake", "frown", "wave"]
        for stem in silent where t.hasPrefix(stem) { return "" }
        return nil
    }

    private static func normalizeEmotes(_ text: String) -> String {
        guard text.contains(where: { "*()[]~".contains($0) }) else { return text }
        let ns = text as NSString
        var out = text
        let matches = emoteSpan.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            var inner = ""
            for g in 1...4 where m.range(at: g).location != NSNotFound {
                inner = ns.substring(with: m.range(at: g))
            }
            let whole = ns.substring(with: m.range)
            let replacement: String
            if let tag = emoteTag(inner) {
                replacement = tag
            } else if whole.hasPrefix("*") {
                replacement = inner            // plain emphasis: keep the words
            } else {
                continue                        // ordinary parentheses or brackets stay as they are
            }
            if let r = Range(m.range, in: out) { out.replaceSubrange(r, with: replacement) }
        }
        return out
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
