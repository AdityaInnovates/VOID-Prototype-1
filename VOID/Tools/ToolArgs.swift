import Foundation

/// Arguments the words themselves settle (on/off, numbers, times, names), filled in by
/// plain code so the small model can't get them wrong. The model's guesses are kept only
/// where the words don't decide.
extension ToolPlanner {
    static func fillArgs(_ spec: ToolSpec, said: String, args: [String: Any]) -> [String: Any] {
        let t = MusicIntent.normalizeCommand(said)
        let words = t.split(separator: " ").map(String.init)
        let set = Set(words)
        let declared = Set(spec.args.map(\.name))
        var out = args.filter { declared.contains($0.key) }

        let off = !set.isDisjoint(with: ["off", "disable", "disconnect", "kill", "stop", "band", "hatao"])
            || t.contains("turn of ")
        let on = !set.isDisjoint(with: ["on", "enable", "enabled", "activate", "start", "chalu", "shuru"])

        if declared.contains("on") {
            if off && !on { out["on"] = false } else if on && !off { out["on"] = true }
            else if off && on, let at = words.firstIndex(where: { ["off", "disable", "band"].contains($0) }),
                    let onAt = words.firstIndex(of: "on") { out["on"] = onAt > at ? false : true }
        }
        if declared.contains("state") {
            let asks = words.first == "is" || !set.isDisjoint(with: ["status", "check", "whether"])
            if asks && !(words.first == "turn") { out["state"] = "status" }
            else if off && !on { out["state"] = "off" }
            else if on && !off { out["state"] = "on" }
            else if off && on {
                let o = words.firstIndex(of: "off") ?? 0, n = words.firstIndex(of: "on") ?? 0
                out["state"] = n > o ? "off" : "on"
            }
        }
        if declared.contains("mode") {
            if t.contains("silent") || t.contains("mute") { out["mode"] = "silent" }
            else if t.contains("vibrat") { out["mode"] = "vibrate" }
            else if t.contains("ring") || t.contains("normal") || t.contains("sound") { out["mode"] = "normal" }
        }
        if declared.contains("seconds"), let seconds = PhoneIntent.duration(in: t) { out["seconds"] = seconds }
        if declared.contains("hour"), let (h, m) = PhoneIntent.time(in: t) { out["hour"] = h; out["minute"] = m }
        if declared.contains("level") {
            if let n = words.compactMap({ Int($0.replacingOccurrences(of: "%", with: "")) }).first { out["level"] = min(100, max(0, n)) }
            else if let word = words.first(where: { Lexicon.numberWords[$0] != nil }) { out["level"] = Lexicon.numberWords[word] }
        }
        if spec.id == "phone.contacts", declared.contains("name") {
            if let who = match(t, #"(\S+?)'s (?:number|phone)"#) ?? match(t, #"number (?:of|for) (\S+)"#)
                ?? match(t, #"^(?:find|get|look up|lookup|what is|whats) (?!my )(\S+)"#) { out["name"] = who }
        }
        if spec.id == "mac.shortcut", declared.contains("name"),
           let name = match(t, #"^(?:run|start|play|trigger) (?:my |the )?(.+?)(?: shortcut)?$"#) { out["name"] = name }
        if spec.id == "phone.apps.open" || spec.id == "mac.open" {
            if let thing = match(t, #"^(?:open|launch|start) (\S+)"#) {
                if spec.id == "mac.open", thing.contains("."), declared.contains("url") {
                    out["url"] = thing.hasPrefix("http") ? thing : "https://" + thing
                } else if declared.contains("app") {
                    out["app"] = thing
                } else if declared.contains("name") {
                    out["name"] = thing
                }
            }
        }
        if spec.id == "phone.sms.send" || spec.id == "phone.call", declared.contains("to"),
           let who = match(t, #"^(?:text|message|sms|call|dial) (\S+)"#), !["me", "my", "the", "a"].contains(who) {
            out["to"] = who
        }
        return out
    }

    private static func match(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let range = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
