import Foundation

/// Turns Hinglish commands and common speech-recognition slips into the plain English phrases
/// the rules and the tool search already understand. Only command-shaped Hinglish is touched,
/// so song titles that happen to contain Hindi words are left alone.
enum Lexicon {
    static func canonical(_ text: String) -> String {
        var t = fixSlips(text)
        t = hinglish(t)
        t = spokenVolume(t)
        return t
    }

    // MARK: Speech-recognition slips

    private static let slips: [String: String] = [
        "musik": "music", "musc": "music", "fone": "phone", "foan": "phone", "baterry": "battery",
        "batery": "battery", "bettery": "battery", "ths": "this", "nex": "next", "nxt": "next",
        "volumn": "volume", "volum": "volume", "bluetoothh": "bluetooth", "blutooth": "bluetooth",
        "fourty": "forty", "skipp": "skip", "watsapp": "whatsapp", "whatsap": "whatsapp", "massages": "messages",
    ]

    private static func fixSlips(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        for index in words.indices {
            if let fixed = slips[words[index]] { words[index] = fixed }
        }
        if words.first == "plays" { words[0] = "play" }
        return words.joined(separator: " ")
    }

    // MARK: Numbers

    static let numberWords: [String: Int] = [
        "zero": 0, "ten": 10, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100,
        "das": 10, "bees": 20, "tees": 30, "chalis": 40, "pachas": 50, "saath": 60, "sattar": 70,
        "assi": 80, "nabbe": 90, "sau": 100,
    ]
    private static let smallNumbers: [String: Int] = [
        "ek": 1, "do": 2, "teen": 3, "char": 4, "chaar": 4, "paanch": 5, "panch": 5, "chhe": 6, "che": 6,
        "saat": 7, "aath": 8, "nau": 9, "das": 10, "gyarah": 11, "barah": 12, "pandrah": 15, "bees": 20,
        "tees": 30,
    ]

    private static func spokenVolume(_ text: String) -> String {
        guard let m = match(text, #"^(?:set )?(?:the )?(?:mac |music |my )?volume (?:to |at )?(\S+)$"#),
              let word = m.first, let number = numberWords[word] else { return text }
        return "volume \(number)"
    }

    // MARK: Hinglish

    private static let markers: Set<String> = [
        "chalao", "lagao", "laga", "chala", "bajao", "karo", "kardo", "gaana", "gana", "gaane", "awaaz",
        "padho", "dhundo", "dhoondo", "kholo", "aaya", "pichla", "agla", "mera", "meri", "mere", "kuch",
        "koi", "wahi", "dilana", "sunao", "shaant", "rok", "roko", "badlo", "dikhao",
    ]

    private static let wordMap: [String: String] = [
        "gaana": "song", "gana": "song", "gaane": "songs", "gaano": "songs", "shaant": "calm",
        "udaas": "sad", "kuch": "something",
    ]

    private static func hinglish(_ input: String) -> String {
        let tokens = input.split(separator: " ").map(String.init)
        let hit = tokens.contains { markers.contains($0) } || tokens.contains("batao") || tokens.contains("kitni") || input.contains(" kar do") || input.contains(" laga do")
        guard hit else { return input }

        var t = tokens.map { wordMap[$0] ?? $0 }.joined(separator: " ")

        let verbs = #"(?:chalao|lagao|laga do|chala do|bajao|chalaiye)"#
        let doIt = #"(?: karo| kar do| kardo)"#
        let rules: [(String, String)] = [
            (#"^(?:song|music) (?:pause|band|rok|roko|stop)\#(doIt)?(?: do)?$"#, "pause the music"),
            (#"^(?:agla|next|dusra|naya) song \#(verbs)$"#, "next song"),
            (#"^song (?:change|badlo|badal do|badalo)\#(doIt)?$"#, "next song"),
            (#"^(?:ye|yeh|is) song skip\#(doIt)$"#, "skip this song"),
            (#"^skip\#(doIt)$"#, "skip"),
            (#"^(?:pichla|pehla|previous) song \#(verbs)$"#, "previous song"),
            (#"^song (?:chalu|shuru|start)\#(doIt)$"#, "resume the music"),
            (#"^(?:awaaz|volume) (?:thoda |zara )?(?:kam|slow|dheema|halka|neeche)(?: karo| kar do| kardo)?$"#, "volume down"),
            (#"^(?:awaaz|volume) (?:thoda |zara )?(?:badha|badhao|zyada|jyada|tez|upar)(?: do| karo| kar do)?$"#, "volume up"),
            (#"^(?:awaaz|volume) (\S+)\#(doIt)$"#, "volume $1"),
            (#"^(?:ye|yeh) konsa song hai$"#, "what song is this"),
            (#"^konsa song (?:chal raha|baj raha) hai$"#, "what song is this"),
            (#"^(?:ye|yeh) song pasand (?:aaya|aaya hai|hai)$"#, "like this song"),
            (#"^(?:mere|meri|mera) (liked songs|favourite songs|favorite songs|favourites|favorites) \#(verbs)$"#, "play my $1"),
            (#"^(?:phir se|dobara) wahi song \#(verbs)$"#, "play the same song again"),
            (#"^wahi song (?:phir se|dobara) \#(verbs)$"#, "play the same song again"),
            (#"^(?:mera|meri) phone ring\#(doIt)$"#, "ring my phone"),
            (#"^phone (?:dhundo|dhoondo|dhundho)(?: do)?$"#, "find my phone"),
            (#"^(?:mere|meri) (messages|msgs|texts|notifications) (?:padho|dikhao|sunao)$"#, "read my $1"),
            (#"^(.+) ko (?:call|phone)\#(doIt)$"#, "call $1"),
            (#"^phone ko silent\#(doIt)$"#, "put my phone on silent"),
            (#"^phone ko (?:ring|normal) mode (?:pe|par|mein)\#(doIt)$"#, "put my phone on ring mode"),
            (#"^phone ko vibrate\#(doIt)$"#, "put my phone on vibrate"),
            (#"^dnd (on|off)\#(doIt)$"#, "turn $1 do not disturb on my phone"),
            (#"^phone (?:par|pe|mein) (\S+) kholo$"#, "open $1 on my phone"),
            (#"^phone lock\#(doIt)$"#, "lock my phone"),
            (#"^(notifications|messages|msgs|texts) batao$"#, "read my $1"),
            (#"^mac ki (\S+) kitni(?: hai)?$"#, "mac $1 status"),
            (#"^(\S+) ko (?:text|message|sms|msg)\#(doIt)(?: ki)? (.+)$"#, "text $1 saying $2"),
            (#"^(?:mac )?(\S+) kholo$"#, "open $1"),
            (#"^phone ki battery (?:kitni|batao)(?: hai)?$"#, "phone battery"),
        ]
        for (pattern, template) in rules {
            if let replaced = replace(t, pattern, template) { return replaced }
        }

        // "subah 6 baje ka alarm lagao"
        if let m = match(t, #"^(subah|savere|shaam|raat|dopahar) (\d{1,2}) baje ka alarm (?:lagao|laga do|set karo)$"#), m.count == 2 {
            let half = (m[0] == "subah" || m[0] == "savere") ? "am" : "pm"
            return "set an alarm for \(m[1]) \(half)"
        }
        // "ek ghante baad yaad dilana"
        if let m = match(t, #"^(\S+) (ghante|ghanta|minute|minat|mins?) baad (?:yaad dilana|yaad dila do|remind karna)$"#), m.count == 2 {
            let n = Int(m[0]) ?? smallNumbers[m[0]] ?? 1
            let unit = m[1].hasPrefix("gh") ? (n == 1 ? "hour" : "hours") : "minutes"
            return "set a timer for \(n) \(unit)"
        }

        // "<something> chalao" is "play <something>".
        if let m = match(t, #"^(.+?) \#(verbs)$"#), let body = m.first {
            var rest = body
            for junk in [" ka koi song", " ka koi", " ka song"] where rest.hasSuffix(junk) {
                rest = String(rest.dropLast(junk.count))
            }
            rest = rest.replacingOccurrences(of: #"\bkoi\b ?"#, with: "", options: .regularExpression)
            if rest.hasSuffix(" sa") { rest = String(rest.dropLast(3)) }
            rest = rest.trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { t = "play " + rest }
        }
        return t
    }

    // MARK: Regex helpers

    private static func match(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { index in
            Range(m.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return regex.replacementString(for: m, in: text, offset: 0, template: template)
    }
}
