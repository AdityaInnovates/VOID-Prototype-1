import AppKit
import CoreLocation
import Foundation
import UserNotifications

/// VOID's phone hands. Turns what you say into actions on your Android phone, answers
/// the phone's requests for this Mac, and mirrors the phone's notifications and calls.
@MainActor
final class PhoneController {
    static let shared = PhoneController()

    let link = PhoneLink()
    private weak var state: AppState?
    private var started = false

    /// Notifications the phone forwarded, newest last.
    private(set) var notifications: [[String: Any]] = []
    /// Sending a text, calling or replying waits for your "yes", so a misheard word
    /// never messages the wrong person.
    var confirmation: (summary: String, at: Date, action: () async throws -> String)?

    /// Show the phone's notifications on the Mac too.
    var mirrorNotifications: Bool {
        get { UserDefaults.standard.object(forKey: "phoneMirrorNotifications") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "phoneMirrorNotifications") }
    }

    func start(state: AppState) {
        guard !started else { return }
        started = true
        self.state = state
        PhoneNotifier.requestPermission()
        link.onConnectionChange = { [weak self] connected, name in
            self?.state?.phoneConnected = connected
            self?.state?.phoneStatus = connected
                ? "Phone: \(name ?? "connected")"
                : (self?.link.pairedNames.isEmpty == false ? "Phone: offline" : "Phone: not paired")
            if connected { Task { await PhoneSettings.shared.syncWithPhone() } }
        }
        PhoneSettings.shared.onLocalChange = { Task { await PhoneSettings.shared.syncWithPhone() } }
        link.onPairingChange = { [weak self] pin in self?.state?.phonePin = pin }
        link.onCall = { [weak self] tool, args in
            guard let self else { return [:] }
            return try await self.answer(tool, args)
        }
        link.onEvent = { [weak self] name, data in self?.event(name, data) }
        state.phoneStatus = link.pairedNames.isEmpty ? "Phone: not paired" : "Phone: offline"
        link.start()
    }

    func openPairing() { _ = link.openPairing() }

    func forgetPhones() {
        link.forgetDevices()
        state?.phoneStatus = "Phone: not paired"
    }

    // MARK: - The phone asks the Mac

    private func answer(_ tool: String, _ args: [String: Any]) async throws -> [String: Any] {
        if tool == "ask" {
            return try await ask(args["text"] as? String ?? "", speak: args["speak"] as? Bool ?? false)
        }
        if tool == "tools" { return ["tools": MacTools.names] }
        if tool == "settings.sync" {
            PhoneSettings.shared.merge(args)
            return PhoneSettings.shared.export()
        }
        return try await MacTools.run(tool, args)
    }

    /// Runs a normal VOID turn from the phone and returns what VOID answered.
    private func ask(_ text: String, speak: Bool) async throws -> [String: Any] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MacTools.ToolError.bad("Say something first.") }
        guard let state, let conversation = AppDelegate.shared?.conversation else {
            throw MacTools.ToolError.bad("VOID is still waking up.")
        }
        let before = state.messages.count
        let speakWas = state.speakReplies
        if !speak { state.speakReplies = false }
        conversation.send(text)
        try? await Task.sleep(for: .milliseconds(400))
        // Waking the models can take a while; the phone waits up to five minutes.
        let deadline = Date().addingTimeInterval(280)
        while conversation.isWorking && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if !speak { state.speakReplies = speakWas }
        let replies = state.messages.dropFirst(before).filter { $0.role == .void }.map(\.text)
        return ["reply": replies.joined(separator: "\n")]
    }

    // MARK: - Events from the phone

    private func event(_ name: String, _ data: [String: Any]) {
        switch name {
        case "notification":
            let key = data["key"] as? String ?? UUID().uuidString
            notifications.removeAll { ($0["key"] as? String) == key }
            notifications.append(data)
            if notifications.count > 60 { notifications.removeFirst(notifications.count - 60) }
            if mirrorNotifications, data["silent"] as? Bool != true {
                let app = data["app"] as? String ?? "Phone"
                let title = data["title"] as? String ?? ""
                PhoneNotifier.post(title: title.isEmpty ? app : "\(app) · \(title)", body: data["text"] as? String ?? "",
                                   id: "phone-\(key)")
            }
        case "notification.removed":
            let key = data["key"] as? String
            notifications.removeAll { ($0["key"] as? String) == key }
            if let key { PhoneNotifier.remove(id: "phone-\(key)") }
        case "call":
            if data["state"] as? String == "ringing" {
                let who = (data["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? data["number"] as? String ?? "Someone"
                PhoneNotifier.post(title: "📞 \(who) is calling", body: "On your phone", id: "phone-call")
            } else {
                PhoneNotifier.remove(id: "phone-call")
            }
        case "battery.low":
            let level = (data["level"] as? NSNumber)?.intValue ?? 0
            PhoneNotifier.post(title: "Phone battery low", body: "\(level)% left")
        default:
            break
        }
    }

    // MARK: - You ask VOID about the phone

    /// Handles a phone command. Returns what VOID should say, or nil when the message
    /// isn't about the phone.
    func handle(_ text: String) async -> String? {
        guard let intent = PhoneIntent.parse(text) else { return nil }

        if case .confirm(let yes) = intent {
            guard let pending = confirmation, Date().timeIntervalSince(pending.at) < 90 else { return nil }
            confirmation = nil
            guard yes else { return "Okay, I won't." }
            do { return try await pending.action() } catch { return "That didn't work. \(error.localizedDescription)" }
        }
        confirmation = nil
        if ScreenLock.shared.isLocked {
            switch intent {
            case .readMessages, .readNotifications, .text, .call, .reply, .openApp, .clipboardToPhone, .say, .locate, .alarm, .timer:
                return "Unlock your Mac first, then ask me again."
            default: break
            }
        }
        guard link.isConnected else {
            return link.pairedNames.isEmpty
                ? "Your phone isn't paired yet. Click “Pair a phone…” in my menu and open the VOID app on it."
                : "Your phone isn't connected right now. Open the VOID app on it."
        }
        do {
            return try await perform(intent)
        } catch {
            return "Your phone said no: \(error.localizedDescription)"
        }
    }

    private func perform(_ intent: PhoneIntent) async throws -> String {
        switch intent {
        case .ring:
            _ = try await link.call("ring", ["seconds": 45])
            return "Ringing your phone. Say “found it” to stop."
        case .stopRing:
            _ = try await link.call("ring.stop")
            return "Stopped."
        case .battery, .status:
            let info = try await link.call("device.status")
            let level = (info["battery"] as? NSNumber)?.intValue ?? -1
            let charging = info["charging"] as? Bool == true
            let base = level >= 0 ? "Your phone is at \(level) percent" : "Your phone is connected"
            return base + (charging ? " and charging." : ".")
        case .locate:
            let spot = try await link.call("location.get", [:], timeout: 30)
            guard let lat = (spot["lat"] as? NSNumber)?.doubleValue, let lon = (spot["lon"] as? NSNumber)?.doubleValue else {
                return "Your phone couldn't get a location."
            }
            let place = await Self.placeName(lat: lat, lon: lon)
            return "Your phone is \(place ?? String(format: "at %.4f, %.4f", lat, lon))."
        case .readMessages:
            let result = try await link.call("sms.read", ["limit": 3])
            let messages = result["messages"] as? [[String: Any]] ?? []
            guard !messages.isEmpty else { return "No messages on your phone." }
            return messages.map { "\($0["from"] as? String ?? "Someone"): \(($0["body"] as? String ?? "").prefix(160))" }
                .joined(separator: ". ")
        case .readNotifications:
            let latest = notifications.suffix(5).reversed()
            guard !latest.isEmpty else { return "Nothing new on your phone." }
            return latest.map { note in
                let title = note["title"] as? String ?? ""
                return "\(note["app"] as? String ?? "An app")\(title.isEmpty ? "" : ", \(title)"): \((note["text"] as? String ?? "").prefix(120))"
            }.joined(separator: ". ")
        case .text(let to, let body):
            let contact = try await findContact(to)
            confirmation = (summary: "text", at: Date(), action: { [weak self] in
                guard let self else { return "" }
                _ = try await self.link.call("sms.send", ["to": contact.number, "body": body])
                return "Sent to \(contact.name)."
            })
            return "Text \(contact.name): “\(body)”. Send it?"
        case .call(let who):
            let contact = try await findContact(who)
            confirmation = (summary: "call", at: Date(), action: { [weak self] in
                guard let self else { return "" }
                _ = try await self.link.call("call.start", ["number": contact.number])
                return "Calling \(contact.name) on your phone."
            })
            return "Call \(contact.name)?"
        case .reply(let to, let body):
            let replyable = notifications.reversed().filter { $0["canReply"] as? Bool == true }
            guard let note = replyable.first(where: {
                MusicIntent.similarity(to, ($0["title"] as? String ?? "") + " " + ($0["app"] as? String ?? "")) >= 0.5
            }), let key = note["key"] as? String else {
                return "I don't see a message from \(to) I can reply to."
            }
            let title = note["title"] as? String ?? to
            let app = note["app"] as? String ?? "your phone"
            confirmation = (summary: "reply", at: Date(), action: { [weak self] in
                guard let self else { return "" }
                _ = try await self.link.call("notifications.reply", ["key": key, "text": body])
                return "Replied to \(title)."
            })
            return "Reply to \(title) on \(app): “\(body)”. Send it?"
        case .openApp(let name):
            let result = try await link.call("apps.open", ["name": name])
            return "Opened \(result["label"] as? String ?? name) on your phone."
        case .torch(let on):
            _ = try await link.call("torch", ["on": on])
            return on ? "Flashlight on." : "Flashlight off."
        case .ringer(let mode):
            _ = try await link.call("ringer", ["mode": mode])
            return mode == "normal" ? "Your phone will ring again." : "Your phone is on \(mode)."
        case .dnd(let on):
            _ = try await link.call("dnd", ["on": on])
            return on ? "Do not disturb is on." : "Do not disturb is off."
        case .alarm(let hour, let minute):
            _ = try await link.call("alarm.set", ["hour": hour, "minute": minute, "label": "VOID"])
            return "Alarm set on your phone for \(Self.clock(hour, minute))."
        case .timer(let seconds):
            _ = try await link.call("timer.set", ["seconds": seconds, "label": "VOID"])
            return "Timer set for \(Self.spoken(seconds))."
        case .clipboardToPhone:
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            guard !text.isEmpty else { return "Your clipboard is empty." }
            _ = try await link.call("clipboard.set", ["text": text])
            return "It's on your phone's clipboard."
        case .media(let action):
            _ = try await link.call("media", ["action": action])
            return action == "next" ? "Next on your phone." : "Done."
        case .say(let words):
            _ = try await link.call("speak", ["text": words])
            return "Said it."
        case .confirm:
            return ""
        }
    }

    func findContact(_ name: String) async throws -> (name: String, number: String) {
        if name.filter(\.isNumber).count >= 6 { return (name, name.filter { $0.isNumber || $0 == "+" }) }
        let result = try await link.call("contacts.find", ["name": name])
        guard let first = (result["contacts"] as? [[String: Any]])?.first,
              let number = first["number"] as? String else {
            throw MacTools.ToolError.bad("I couldn't find \(name) in your contacts.")
        }
        return (first["name"] as? String ?? name, number)
    }

    private static func placeName(lat: Double, lon: Double) async -> String? {
        let place = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon)).first
        guard let place else { return nil }
        let parts = [place.name, place.subLocality, place.locality].compactMap { $0 }
        var seen = Set<String>()
        let unique = parts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : "near " + unique.joined(separator: ", ")
    }

    private static func clock(_ hour: Int, _ minute: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return minute == 0 ? "\(h) \(hour < 12 ? "AM" : "PM")" : String(format: "%d:%02d %@", h, minute, hour < 12 ? "AM" : "PM")
    }

    private static func spoken(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return seconds == 3600 ? "an hour" : "\(seconds / 3600) hours" }
        if seconds % 60 == 0 { return seconds == 60 ? "a minute" : "\(seconds / 60) minutes" }
        return "\(seconds) seconds"
    }
}

/// Mac notifications for things that happen on the phone.
enum PhoneNotifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(400))
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func remove(id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}
