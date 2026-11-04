import Foundation

/// Turns the small model's one-line answer into a tool call. The model only ever sees the few
/// tools the index found for this message, never the whole catalogue.
enum ToolPlanner {
    struct Call {
        let spec: ToolSpec
        let args: [String: Any]
    }

    static let system = """
    You pick ONE tool for the user's request, or none. You will be shown a few candidate tools. \
    Reply with ONE line only.
    If a candidate tool is exactly what the user is asking you to do, reply: tool_id {"arg": value}
    Use {} when the tool needs no arguments. Fill arguments from the user's words. Numbers are numbers, \
    on/off is true/false. 24-hour clock for hours.
    If the user is just chatting, asking an opinion, or none of the tools fit, reply: NONE
    Never invent a tool id. Never explain.
    """

    static func prompt(user: String, recent: String, candidates: [ToolIndex.Match]) -> String {
        var text = "Candidate tools:\n"
        for match in candidates {
            let spec = match.spec
            text += "- \(spec.id): \(spec.summary)."
            if !spec.args.isEmpty {
                text += " Args: " + spec.args.map { "\($0.name) (\($0.hint))" }.joined(separator: "; ") + "."
            }
            text += " Example: \"\(spec.examples.first ?? "")\"\n"
        }
        if !recent.isEmpty { text += "\nRecent conversation:\n\(recent)\n" }
        text += "\nUser: \(user)\nAnswer:"
        return text
    }

    /// Reads "phone.torch {"on": true}". Anything unclear is no call, so a confused model
    /// never does something by mistake.
    static func parse(_ raw: String, candidates: [ToolIndex.Match]) -> Call? {
        guard let first = raw.split(whereSeparator: \.isNewline).first else { return nil }
        var line = String(first).trimmingCharacters(in: .whitespaces)
        for lead in ["Answer:", "answer:", "->", "→"] where line.hasPrefix(lead) {
            line = String(line.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
        }
        if line.uppercased().hasPrefix("NONE") { return nil }

        var object: [String: Any] = [:]
        if let open = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}"), open < close,
           let data = String(line[open...close]).data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = parsed
        }

        // The id is usually the first word, but small models also write {"tool_id": "..."} or {"id": value}.
        let idToken = String(line.prefix { !$0.isWhitespace && $0 != "{" })
        var match = candidates.first { $0.spec.id == idToken }
        if match == nil {
            for key in ["tool_id", "tool", "id", "name"] {
                if let name = object[key] as? String, let found = candidates.first(where: { $0.spec.id == name }) {
                    match = found
                    object[key] = nil
                    break
                }
            }
        }
        if match == nil, let found = candidates.first(where: { object[$0.spec.id] != nil }) {
            match = found   // {"mac.bluetooth": "off"}
            let value = object[found.spec.id]
            object = [:]
            if let value, let only = found.spec.args.first, found.spec.args.count == 1 { object[only.name] = value }
        }
        guard let match else { return nil }

        // Only the arguments this tool declares; a lone argument can be filled from a lone value.
        let allowed = Set(match.spec.args.map(\.name))
        var args = object.filter { allowed.contains($0.key) }
        if args.isEmpty, match.spec.args.count == 1, object.count == 1, let value = object.values.first {
            args[match.spec.args[0].name] = value
        }
        return Call(spec: match.spec, args: args)
    }
}
