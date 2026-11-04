import AppKit
import Foundation

extension MusicIntent {
    /// The short label the eval file uses, e.g. "music:pause".
    var evalName: String {
        switch self {
        case .pause: "pause"
        case .resume: "resume"
        case .next: "next"
        case .previous: "previous"
        case .replay: "replay"
        case .volume: "volume"
        case .nowPlaying: "nowPlaying"
        case .like: "like"
        case .dislike: "dislike"
        case .resync: "resync"
        case .likedSongs: "likedSongs"
        case .playlist: "playlist"
        case .song: "song"
        case .suggest: "suggest"
        case .random: "random"
        }
    }
}

extension PhoneIntent {
    /// The tool this phrase maps to, in the eval file's "tool:<id>" naming.
    var evalTool: String {
        switch self {
        case .ring: "phone.ring"
        case .stopRing: "phone.ring.stop"
        case .battery, .status: "phone.status"
        case .locate: "phone.location"
        case .readMessages: "phone.sms.read"
        case .readNotifications: "phone.notifications"
        case .text: "phone.sms.send"
        case .call: "phone.call"
        case .reply: "phone.reply"
        case .openApp: "phone.apps.open"
        case .torch: "phone.torch"
        case .ringer: "phone.ringer"
        case .dnd: "phone.dnd"
        case .alarm: "phone.alarm"
        case .timer: "phone.timer"
        case .clipboardToPhone: "phone.clipboard.set"
        case .media: "phone.media"
        case .say: "phone.speak"
        case .confirm: "confirm"
        }
    }
}

/// Checks how well VOID's routing sends a message to the right place, using a labelled file
/// of commands (Eval/router_eval.jsonl). It follows the same order as a real turn:
/// phone phrases, music phrases, the music model, then tool search and the tool planner.
/// Nothing is executed: no song plays, no text is sent.
extension Conversation {
    struct EvalCase {
        let id, slice, text: String
        let expect: [String]
        let args: [String: Any]
    }

    struct EvalResult {
        let item: EvalCase
        let got: String
        let stage: String
        let ms: Int
        let ok: Bool
        let argsChecked: Bool
        let argsOK: Bool
        let note: String
    }

    func runRouterEval(file: URL, useModel: Bool) async -> URL? {
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var cases: [EvalCase] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = o["id"] as? String, let text = o["text"] as? String,
                  let expect = o["expect"] as? String else { continue }
            cases.append(EvalCase(id: id, slice: o["slice"] as? String ?? "other", text: text,
                                  expect: expect.components(separatedBy: "|"), args: o["args"] as? [String: Any] ?? [:]))
        }
        guard !cases.isEmpty else { return nil }

        var results: [EvalResult] = []
        for (i, item) in cases.enumerated() {
            state.statusLine = "Router eval \(i + 1)/\(cases.count)…"
            results.append(await evalOne(item, useModel: useModel))
        }
        state.statusLine = "Router eval done."
        return writeEvalReport(results, file: file, useModel: useModel)
    }

    private func evalOne(_ item: EvalCase, useModel: Bool) async -> EvalResult {
        let started = Date()
        func done(_ got: String, _ stage: String, argsChecked: Bool = false, argsOK: Bool = true, note: String = "") -> EvalResult {
            EvalResult(item: item, got: got, stage: stage, ms: Int(Date().timeIntervalSince(started) * 1000),
                       ok: item.expect.contains(got), argsChecked: argsChecked, argsOK: argsOK, note: note)
        }
        if let phone = PhoneIntent.parse(item.text) {
            return done(phone.evalTool == "confirm" ? "chat" : "tool:" + phone.evalTool, "phone-rules")
        }
        if let intent = MusicIntent.parse(item.text, active: true) {
            return done("music:" + intent.evalName, "music-rules")
        }
        if useModel, !Self.mentionsPhone(item.text), let intent = await routeMusic(item.text) {
            return done("music:" + intent.evalName, "music-model")
        }
        guard let plan = await planTool(item.text, runModel: useModel) else { return done("chat", "no-tool-match") }
        guard !plan.candidates.isEmpty else {
            return done("chat", "below-threshold", note: plan.candidates.isEmpty ? plan.raw : "best \(plan.candidates.first?.spec.id ?? "-") \(String(format: "%.2f", plan.topScore))")
        }
        guard useModel else {
            // Without the model, judge the search alone: is the top candidate the right tool?
            let top = plan.candidates.first?.spec.id ?? ""
            return done("tool:" + top, "tool-search", note: String(format: "%.2f", plan.topScore))
        }
        guard let call = plan.call else { return done("chat", "planner-none", note: plan.raw.trimmingCharacters(in: .whitespacesAndNewlines)) }
        var argsOK = true
        for (key, want) in item.args {
            argsOK = argsOK && Self.sameValue(call.args[key], want)
        }
        return done("tool:" + call.spec.id, "tool-planner", argsChecked: !item.args.isEmpty, argsOK: argsOK,
                    note: item.args.isEmpty ? "" : "args \(call.args)")
    }

    private static func sameValue(_ got: Any?, _ want: Any) -> Bool {
        guard let got else { return false }
        if let w = want as? Bool { return (got as? Bool) == w }
        if let w = want as? NSNumber, !(want is Bool) {
            if let g = got as? NSNumber { return g.doubleValue == w.doubleValue }
            if let g = got as? String, let d = Double(g) { return d == w.doubleValue }
            return false
        }
        if let w = want as? String {
            // Names are matched loosely: "to mom" and "Mom" both count.
            return String(describing: got).lowercased().contains(w.lowercased())
        }
        return false
    }

    private func writeEvalReport(_ results: [EvalResult], file: URL, useModel: Bool) -> URL? {
        let total = results.count, right = results.filter(\.ok).count
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : String(format: "%.0f%%", 100 * Double(a) / Double(b)) }

        var md = "# Router eval\n\n"
        md += "- Date: \(ISO8601DateFormatter().string(from: Date()))\n"
        md += "- Mode: \(useModel ? "full (with the small model)" : "offline (rules + tool search only)")\n"
        md += "- Tool search threshold: \(ToolIndex.threshold)\n"
        md += "- **Overall: \(right)/\(total) (\(pct(right, total)))**\n\n"

        md += "## By slice\n\n| Slice | Right | Total | Accuracy |\n|---|---|---|---|\n"
        for slice in Set(results.map { $0.item.slice }).sorted() {
            let rows = results.filter { $0.item.slice == slice }
            let r = rows.filter(\.ok).count
            md += "| \(slice) | \(r) | \(rows.count) | \(pct(r, rows.count)) |\n"
        }
        let argRows = results.filter(\.argsChecked)
        if !argRows.isEmpty {
            md += "\nArguments right when the tool was right: \(argRows.filter(\.argsOK).count)/\(argRows.count)\n"
        }
        let chat = results.filter { $0.item.expect == ["chat"] }
        md += "\nFalse triggers (chat that fired a tool or music): \(chat.filter { !$0.ok }.count)/\(chat.count)\n"

        md += "\n## By stage\n\n| Stage | Cases | Right | Avg ms |\n|---|---|---|---|\n"
        for stage in Set(results.map(\.stage)).sorted() {
            let rows = results.filter { $0.stage == stage }
            let avg = rows.map(\.ms).reduce(0, +) / max(rows.count, 1)
            md += "| \(stage) | \(rows.count) | \(rows.filter(\.ok).count) | \(avg) |\n"
        }

        md += "\n## Misses\n\n| id | said | wanted | got | stage | note |\n|---|---|---|---|---|---|\n"
        for r in results where !r.ok || (r.argsChecked && !r.argsOK) {
            let bad = r.ok ? " (wrong args)" : ""
            md += "| \(r.item.id) | \(r.item.text) | \(r.item.expect.joined(separator: " or ")) | \(r.got)\(bad) | \(r.stage) | \(r.note.replacingOccurrences(of: "|", with: "/")) |\n"
        }

        let folder = file.deletingLastPathComponent().appendingPathComponent("results", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let out = folder.appendingPathComponent("router_eval_\(useModel ? "full" : "offline")_\(stamp).md")
        try? md.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

extension AppDelegate {
    /// Menu action: runs the router eval on Eval/router_eval.jsonl next to the app's project folder,
    /// or on a file you pick.
    func runRouterEval(useModel: Bool) {
        Task { @MainActor in
            var file = Bundle.main.bundleURL
            for _ in 0..<5 { file.deleteLastPathComponent() }
            file.appendPathComponent("Eval/router_eval.jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                let panel = NSOpenPanel()
                panel.message = "Choose router_eval.jsonl"
                panel.allowedContentTypes = [.json, .plainText]
                guard panel.runModal() == .OK, let picked = panel.url else { return }
                file = picked
            }
            guard let out = await conversation.runRouterEval(file: file, useModel: useModel) else {
                state.statusLine = "Router eval couldn't read the file."
                return
            }
            state.statusLine = "Router eval saved: \(out.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([out])
        }
    }
}
