import AppKit
import Foundation

/// Runs the tool the planner chose, on the phone or on this Mac, and says what happened.
extension PhoneController {
    func execute(_ spec: ToolSpec, _ args: [String: Any], said: String = "") async -> String {
        var args = args
        if ScreenLock.shared.isLocked, !ScreenLock.lockedAllowed.contains(where: { spec.id.hasPrefix($0) }) {
            return "Unlock your Mac first, then ask me again."
        }
        // On/off is too important to leave to a small model: read it from the words themselves.
        if spec.id == "mac.bluetooth" || spec.id == "mac.wifi" {
            let words = Set(said.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
            let off = !words.isDisjoint(with: ["off", "disable", "disconnect", "kill", "stop"])
            let on = !words.isDisjoint(with: ["on", "enable", "enabled", "activate", "start"])
            let asks = !words.isDisjoint(with: ["is", "check", "status", "whether"]) && !off
            if off && !on { args["state"] = "off" }
            else if on && !off && !asks { args["state"] = "on" }
            else if asks { args["state"] = "status" }
        }
        if spec.target == .phone {
            guard link.isConnected else {
                return link.pairedNames.isEmpty
                    ? "Your phone isn't paired yet. Click Pair a phone in my menu."
                    : "Your phone isn't connected right now. Open the VOID app on it."
            }
        }
        do {
            // Names become numbers before anything is sent.
            var who: String?
            if spec.id == "phone.sms.send" || spec.id == "phone.call" {
                let name = (args["to"] as? String) ?? ""
                guard !name.isEmpty else { return "Who should I \(spec.id == "phone.call" ? "call" : "text")?" }
                let contact = try await findContact(name)
                args["to"] = contact.number
                who = contact.name
            }
            if spec.id == "phone.reply" {
                // The model can't know notification keys; pick the newest one that accepts a reply.
                guard let note = notifications.reversed().first(where: { $0["canReply"] as? Bool == true }),
                      let key = note["key"] as? String else { return "I don't see a message I can reply to." }
                args["key"] = key
                who = note["title"] as? String
            }

            if let question = spec.confirm {
                let toolName = spec.tool, target = spec.target
                var prompt = question
                if let who { prompt = spec.id == "phone.call" ? "Call \(who)?" : "\(spec.summary) to \(who). \(question)" }
                if let body = args["body"] as? String ?? args["text"] as? String, spec.id != "phone.tap" {
                    prompt = "\(who.map { "To \($0): " } ?? "")“\(body)”. \(question)"
                }
                let captured = args
                confirmation = (summary: spec.id, at: Date(), action: { [weak self] in
                    guard let self else { return "" }
                    let result = try await self.invoke(target, toolName, captured)
                    return Self.say(spec, result, who: who)
                })
                return prompt
            }
            let result = try await invoke(spec.target, spec.tool, args)
            return Self.say(spec, result, who: who)
        } catch {
            return "That didn't work. \(error.localizedDescription)"
        }
    }

    private func invoke(_ target: ToolSpec.Target, _ tool: String, _ args: [String: Any]) async throws -> [String: Any] {
        switch target {
        case .phone: return try await link.call(tool, args, timeout: 30)
        case .mac: return try await MacTools.run(tool, args)
        }
    }

    /// Turns a tool's raw answer into a sentence.
    private static func say(_ spec: ToolSpec, _ result: [String: Any], who: String?) -> String {
        switch spec.id {
        case "phone.status":
            let level = (result["battery"] as? NSNumber)?.intValue ?? -1
            let charging = result["charging"] as? Bool == true
            return (level >= 0 ? "Your phone is at \(level) percent" : "Your phone is connected") + (charging ? " and charging." : ".")
        case "phone.location":
            guard let lat = (result["lat"] as? NSNumber)?.doubleValue, let lon = (result["lon"] as? NSNumber)?.doubleValue else {
                return "Your phone couldn't get a location."
            }
            return String(format: "Your phone is at %.4f, %.4f.", lat, lon)
        case "phone.sms.read":
            let messages = result["messages"] as? [[String: Any]] ?? []
            guard !messages.isEmpty else { return "No messages on your phone." }
            return messages.map { "\($0["from"] as? String ?? "Someone"): \(($0["body"] as? String ?? "").prefix(160))" }.joined(separator: ". ")
        case "phone.notifications":
            let list = (result["notifications"] as? [[String: Any]] ?? []).suffix(5).reversed()
            guard !list.isEmpty else { return "Nothing new on your phone." }
            return list.map { note in
                let title = note["title"] as? String ?? ""
                return "\(note["app"] as? String ?? "An app")\(title.isEmpty ? "" : ", \(title)"): \((note["text"] as? String ?? "").prefix(120))"
            }.joined(separator: ". ")
        case "phone.contacts":
            let found = result["contacts"] as? [[String: Any]] ?? []
            guard let first = found.first else { return "I couldn't find that contact." }
            return "\(first["name"] as? String ?? "They"): \(first["number"] as? String ?? "")."
        case "phone.apps.list":
            let apps = (result["apps"] as? [String] ?? []).prefix(25)
            return apps.isEmpty ? "I couldn't read the app list." : "You have " + apps.joined(separator: ", ") + ", and more."
        case "phone.clipboard.get", "mac.clipboard.get":
            let text = result["text"] as? String ?? ""
            return text.isEmpty ? "The clipboard is empty." : "It says: \(text.prefix(300))"
        case "phone.apps.open":
            return "Opened \(result["label"] as? String ?? "it") on your phone."
        case "phone.sms.send": return "Sent to \(who ?? "them")."
        case "phone.call": return "Calling \(who ?? "them") on your phone."
        case "phone.reply": return "Replied to \(who ?? "them")."
        case "mac.status":
            let battery = (result["battery"] as? NSNumber)?.intValue
            let front = result["front"] as? String ?? ""
            return (battery.map { "Your Mac is at \($0) percent" } ?? "Your Mac is fine") + (front.isEmpty ? "." : ", and you're in \(front).")
        case "mac.apps":
            return "Open: " + (result["apps"] as? [String] ?? []).joined(separator: ", ") + "."
        case "mac.bluetooth", "mac.wifi":
            let name = spec.id == "mac.wifi" ? "Wi-Fi" : "Bluetooth"
            return "\(name) is \((result["on"] as? Bool) == true ? "on" : "off")."
        case "mac.volume":
            let level = (result["level"] as? NSNumber)?.intValue ?? -1
            return level >= 0 ? "Volume \(level)." : spec.done
        default:
            return spec.done
        }
    }
}
