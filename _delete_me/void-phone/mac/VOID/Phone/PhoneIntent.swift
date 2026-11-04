import Foundation

/// Things you can say to VOID about your phone, recognised by fixed rules.
enum PhoneIntent: Equatable {
    case ring, stopRing
    case battery, status
    case locate
    case readMessages, readNotifications
    case text(to: String, body: String)
    case call(String)
    case reply(to: String, body: String)
    case openApp(String)
    case torch(Bool)
    case ringer(String)              // "normal", "vibrate", "silent"
    case dnd(Bool)
    case alarm(hour: Int, minute: Int)
    case timer(seconds: Int)
    case clipboardToPhone
    case media(String)               // "toggle", "next", "previous"
    case say(String)
    case confirm(Bool)

    static func parse(_ raw: String) -> PhoneIntent? {
        let text = MusicIntent.normalize(raw)
        guard !text.isEmpty else { return nil }
        let onPhone = text.contains("phone") || text.contains("mobile")

        if ["yes", "yeah", "yep", "yup", "sure", "send it", "do it", "go ahead", "yes send it", "confirm",
            "yes please", "ok send it", "okay send it", "call them", "send"].contains(text) { return .confirm(true) }
        if ["no", "nope", "cancel", "don't", "dont", "don't send it", "dont send it", "never mind",
            "nevermind", "no don't", "cancel it"].contains(text) { return .confirm(false) }

        if ["find my phone", "ring my phone", "where's my phone", "where is my phone", "wheres my phone",
            "i can't find my phone", "i cant find my phone", "make my phone ring", "locate my phone ring",
            "where did i keep my phone", "where did i put my phone"].contains(text) { return .ring }
        if ["stop ringing", "stop the phone", "found it", "i found it", "stop ringing my phone",
            "stop my phone", "found my phone", "i found my phone"].contains(text) { return .stopRing }

        if onPhone, text.contains("battery") || text.contains("charge") && !text.contains("charger") { return .battery }
        if ["is my phone connected", "phone status", "how's my phone", "hows my phone"].contains(text) { return .status }
        if ["where am i", "where is my phone right now", "where is my phone located", "where's my phone located",
            "what's my location", "whats my location", "my location", "share my location"].contains(text) { return .locate }

        if ["read my messages", "read my texts", "any new messages", "do i have any messages", "any messages",
            "read my sms", "check my messages", "check my texts", "what are my messages", "read messages",
            "any new texts", "read my latest message", "read the last message"].contains(text) { return .readMessages }
        if ["read my notifications", "what notifications do i have", "any notifications", "check my notifications",
            "what did i miss", "any new notifications", "phone notifications", "read notifications"].contains(text) {
            return .readNotifications
        }

        if let match = capture(text, #"^(?:send (?:a )?(?:text|message|sms) to|text|message|sms) (.+?) (?:saying|that says|that|to say|and say|and tell (?:him|her|them)) (.+)$"#),
           match.count == 2 {
            return .text(to: match[0], body: match[1])
        }
        if let match = capture(text, #"^reply (?:to )?(.+?) (?:saying|with|that) (.+)$"#), match.count == 2 {
            return .reply(to: match[0], body: match[1])
        }
        if let match = capture(text, #"^(?:call|dial|phone) (.+?)(?: on my phone| from my phone)?$"#), let who = match.first {
            let blocked = ["it", "me", "this", "that", "the", "a", "an", "back", "you", "him", "her", "them"]
            if !blocked.contains(where: { who == $0 || who.hasPrefix($0 + " ") }) { return .call(who) }
        }
        if let match = capture(text, #"^(?:open|launch|start) (.+?) (?:on|in) my (?:phone|mobile)$"#), let app = match.first {
            return .openApp(app)
        }

        let torchWord = text.contains("flashlight") || text.contains("torch") || text.contains("flash light")
        if torchWord {
            if text.contains(" off") || text.hasPrefix("off") { return .torch(false) }
            if text.contains(" on") || text.hasPrefix("on") { return .torch(true) }
        }
        if onPhone {
            if text.contains("silent") || text.contains("mute my phone") { return .ringer("silent") }
            if text.contains("vibrat") { return .ringer("vibrate") }
            if text.contains("do not disturb") || text.contains("dnd") {
                return .dnd(!(text.contains(" off") || text.contains("disable") || text.contains("turn off")))
            }
            if text.contains("ring mode") || text.contains("normal mode") || text.contains("unmute my phone")
                || text.contains("sound on") { return .ringer("normal") }
        }

        if text.contains("alarm"), let (hour, minute) = time(in: text) { return .alarm(hour: hour, minute: minute) }
        if text.contains("timer"), let seconds = duration(in: text) { return .timer(seconds: seconds) }

        if ["send this to my phone", "send my clipboard to my phone", "copy this to my phone",
            "send clipboard to phone", "send the clipboard to my phone", "put this on my phone"].contains(text) {
            return .clipboardToPhone
        }
        if onPhone {
            if text.hasPrefix("pause") || text.hasPrefix("play") || text.hasPrefix("resume") { return .media("toggle") }
            if text.hasPrefix("next") || text.hasPrefix("skip") { return .media("next") }
        }
        if let match = capture(text, #"^say (.+) on my phone$"#), let words = match.first { return .say(words) }
        return nil
    }

    // MARK: - Pieces

    private static func capture(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40,
        "forty-five": 45, "fifty": 50, "sixty": 60, "a": 1, "an": 1, "half": 30,
    ]

    private static func number(_ word: String) -> Int? { Int(word) ?? numberWords[word] }

    /// "7 am", "7 30 pm", "19 45", "seven thirty am".
    static func time(in text: String) -> (Int, Int)? {
        let words = text.split(separator: " ").map(String.init)
        guard let at = words.firstIndex(where: { $0 == "for" || $0 == "at" }), at + 1 < words.count,
              var hour = number(words[at + 1]), hour <= 23 else { return nil }
        var minute = 0
        var index = at + 2
        if index < words.count, let value = number(words[index]), value < 60, !["a", "an"].contains(words[index]) {
            minute = value
            index += 1
        }
        let rest = words[min(index, words.count)...].joined(separator: " ")
        let pm = rest.hasPrefix("pm") || rest.hasPrefix("p m") || rest.contains("evening") || rest.contains("night")
        let am = rest.hasPrefix("am") || rest.hasPrefix("a m") || rest.contains("morning")
        if pm && hour < 12 { hour += 12 }
        if am && hour == 12 { hour = 0 }
        return (hour, minute)
    }

    /// "for 10 minutes", "for an hour", "for 90 seconds", "for half an hour".
    static func duration(in text: String) -> Int? {
        if text.contains("half an hour") { return 1800 }
        let words = text.split(separator: " ").map(String.init)
        for (index, word) in words.enumerated() where index > 0 {
            guard let amount = number(words[index - 1]) else { continue }
            if word.hasPrefix("second") { return amount }
            if word.hasPrefix("minute") || word == "min" || word == "mins" { return amount * 60 }
            if word.hasPrefix("hour") { return amount * 3600 }
        }
        return nil
    }
}
