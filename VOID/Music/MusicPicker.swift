import Foundation

/// What this moment calls for, on three dials from 0 to 1.
struct MusicTarget {
    /// Calm (0) to high-energy (1).
    var energy: Double
    /// Dark or sad (0) to bright and happy (1).
    var valence: Double
    /// How much it should stay out of the way of focus: soft, steady, few surprises.
    var focus: Double
    /// Short spoken reasons, most important first: "rainy out", "deep in Xcode".
    var reasons: [String]
    /// Situations that fit right now: "night", "workout", "social"…
    var situations: Set<String>
}

/// How a playlist feels, on the same three dials.
struct PlaylistFeel {
    var energy = 0.5
    var valence = 0.5
    var focus = 0.2
    var tags: Set<String> = []
}

/// Scores your playlists against the moment.
///
/// score = closeness on energy, mood and focus
///       + situations that fit (night, workout, people around…)
///       + what you actually kept playing in this part of the day before
///       − anything played in the last day
///       + a little randomness
enum MusicPicker {

    // MARK: - The moment

    static func target(for context: MusicContext, mood explicit: String?) -> MusicTarget {
        var energy = 0.5, valence = 0.55, focus = 0.2
        var reasons: [String] = []
        var situations: Set<String> = []

        switch context.daypart {
        case .morning: energy = 0.5; valence = 0.65; situations.insert("morning")
        case .afternoon: energy = 0.5; focus = 0.3
        case .evening: energy = 0.55; valence = 0.6
        case .night: energy = 0.35; valence = 0.5; situations.insert("night")
        case .lateNight: energy = 0.2; valence = 0.45; focus = 0.4; situations.insert("night")
        }
        if context.weekend { energy += 0.05; valence += 0.05 }

        if let weather = context.weather {
            if weather.isRainy {
                energy -= 0.06; valence -= 0.04
                reasons.append(weather.isStormy ? "stormy out" : "rainy out")
                situations.insert("rain")
            } else if weather.isSnowy || weather.isFoggy {
                energy -= 0.05
                reasons.append(weather.isSnowy ? "snowing" : "foggy out")
            } else if weather.isClear && weather.isDay && weather.temperature >= 26 {
                energy += 0.03; valence += 0.05
                reasons.append("sunny and warm")
            } else if weather.temperature <= 12 {
                reasons.append("cold out")
            }
        }

        let app = context.frontApp ?? "your app"
        switch context.appKind {
        case .coding where context.minutesInApp >= 15:
            focus = 0.8; energy -= 0.1
            reasons.insert("deep in \(app) for \(Self.duration(context.minutesInApp))", at: 0)
            situations.insert("focus")
        case .coding, .writing:
            focus = max(focus, 0.6); energy -= 0.05
            situations.insert("focus")
        case .creative:
            focus = max(focus, 0.45)
            if context.minutesInApp >= 15 { reasons.insert("in the zone in \(app)", at: 0) }
        case .gaming:
            energy += 0.2; focus = 0.1
            situations.insert("hype")
        case .video:
            energy -= 0.1
        case .meeting:
            focus = 0.9; energy = 0.2
        default:
            break
        }
        if context.switchesPerMinute > 0.8 { reasons.append("jumping between apps") }
        if context.idleMinutes >= 10 {
            energy -= 0.05
            reasons.append("you've stepped away a bit")
        }

        if let room = context.room {
            if room.talking {
                energy += 0.05; focus -= 0.2
                reasons.insert("people around", at: 0)
                situations.insert("social")
            } else if room.silent && context.daypart == .lateNight {
                energy -= 0.05
                reasons.append("it's quiet")
            }
            if room.rain && !situations.contains("rain") {
                energy -= 0.05
                reasons.append("I can hear rain")
                situations.insert("rain")
            }
            if room.typing { focus += 0.1 }
        }

        // What you said about how you feel outranks everything I sensed. For heavy moods,
        // "match" stays with the feeling and "lift" moves you out of it; until you say
        // which, the default is gentle.
        if let note = context.mood {
            let goal = note.goal
            switch note.mood {
            case "tired":
                if goal == "lift" { energy = 0.6; valence = 0.7; reasons.insert("you're tired and want a pick-me-up", at: 0) }
                else { energy = 0.25; valence = 0.5; reasons.insert("you sound tired", at: 0) }
            case "stressed":
                if goal == "lift" { energy = 0.55; valence = 0.75; reasons.insert("you're stressed and want a lift", at: 0) }
                else { energy = 0.25; valence = 0.55; focus = max(focus, 0.6); reasons.insert("you're stressed", at: 0) }
            case "sad":
                if goal == "match" { energy = 0.3; valence = 0.2; reasons.insert("you want something that sits with it", at: 0) }
                else if goal == "lift" { energy = 0.5; valence = 0.75; reasons.insert("you want a lift", at: 0) }
                else { energy = 0.3; valence = 0.5; reasons.insert("you seem low", at: 0) }
            case "angry":
                if goal == "lift" { energy = 0.3; valence = 0.6; reasons.insert("you want to calm down", at: 0) }
                else { energy = 0.75; valence = 0.3; reasons.insert("you need to let some steam out", at: 0) }
            case "bored": energy = 0.65; valence = 0.7; reasons.insert("you're bored", at: 0)
            case "happy": energy = 0.75; valence = 0.85; reasons.insert("you're in a good mood", at: 0)
            case "focused": focus = 0.85; energy = 0.35; reasons.insert("you want to focus", at: 0)
            default: break
            }
        } else if let arousal = context.voiceArousal, abs(arousal) >= 0.8 {
            // Only a weak hint, and only when you haven't said how you feel.
            energy += arousal > 0 ? 0.06 : -0.06
            if abs(arousal) >= 1.2 { reasons.append(arousal > 0 ? "you sound lively" : "you sound low-key") }
        }

        // A mood you asked for wins over all of it.
        if let explicit, let dials = Self.moodDials[explicit] {
            energy = dials.energy; valence = dials.valence; focus = dials.focus
            reasons = []
            situations.formUnion(dials.situations)
        }

        if reasons.isEmpty { reasons.append(context.daypart == .lateNight ? "it's late" : "it's \(context.daypart.spoken)") }

        return MusicTarget(
            energy: clamp(energy), valence: clamp(valence), focus: clamp(focus),
            reasons: reasons, situations: situations)
    }

    /// The dials for moods you can ask for by name ("play something calm").
    static let moodDials: [String: (energy: Double, valence: Double, focus: Double, situations: Set<String>)] = [
        "calm": (0.2, 0.55, 0.5, []), "chill": (0.3, 0.6, 0.4, []), "chilled": (0.3, 0.6, 0.4, []),
        "relaxing": (0.2, 0.6, 0.5, []), "relaxed": (0.25, 0.6, 0.45, []), "peaceful": (0.15, 0.6, 0.55, []),
        "soft": (0.2, 0.55, 0.4, []), "mellow": (0.25, 0.5, 0.4, []), "slow": (0.2, 0.45, 0.4, []),
        "happy": (0.7, 0.9, 0.2, []), "sad": (0.3, 0.15, 0.3, []),
        "romantic": (0.35, 0.7, 0.3, ["love"]), "love": (0.35, 0.7, 0.3, ["love"]),
        "upbeat": (0.8, 0.8, 0.1, []), "energetic": (0.9, 0.75, 0.1, ["hype"]), "hype": (0.95, 0.7, 0.05, ["hype"]),
        "party": (0.9, 0.85, 0.0, ["social"]), "dance": (0.9, 0.8, 0.0, ["social"]),
        "focus": (0.3, 0.55, 0.9, ["focus"]), "focused": (0.3, 0.55, 0.9, ["focus"]),
        "study": (0.25, 0.55, 0.9, ["focus"]), "studying": (0.25, 0.55, 0.9, ["focus"]),
        "coding": (0.35, 0.55, 0.85, ["focus"]), "work": (0.35, 0.55, 0.8, ["focus"]),
        "workout": (0.95, 0.65, 0.0, ["workout"]), "gym": (0.95, 0.65, 0.0, ["workout"]),
        "running": (0.9, 0.7, 0.0, ["workout"]), "motivational": (0.85, 0.7, 0.1, ["workout"]),
        "motivating": (0.85, 0.7, 0.1, ["workout"]),
        "sleep": (0.05, 0.5, 0.7, ["night"]), "sleepy": (0.1, 0.5, 0.6, ["night"]),
        "lofi": (0.25, 0.55, 0.85, ["focus"]), "lo-fi": (0.25, 0.55, 0.85, ["focus"]),
        "rainy": (0.25, 0.4, 0.4, ["rain"]), "night": (0.3, 0.45, 0.4, ["night"]),
        "morning": (0.5, 0.7, 0.2, ["morning"]), "evening": (0.45, 0.6, 0.2, []),
        "drive": (0.6, 0.65, 0.1, ["drive"]), "driving": (0.6, 0.65, 0.1, ["drive"]),
    ]

    // MARK: - The playlists

    /// Reads a playlist's feel from its name. You name yours by mood ("Soft sad raps",
    /// "Jolly happy mood", "GYM"), which says a lot.
    static func feel(of playlist: MusicPlaylist) -> PlaylistFeel {
        if playlist.id == "LM" { return PlaylistFeel(energy: 0.5, valence: 0.6, focus: 0.2, tags: ["liked"]) }
        let lower = playlist.title.lowercased()
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        func has(_ keys: [String]) -> Bool { words.contains { word in keys.contains { word.hasPrefix($0) } } }

        var result = PlaylistFeel()
        let soft = has(["soft", "calm", "sleep", "slow", "chill", "acoustic", "peace", "mellow", "classic", "old",
                        "relax", "ambient", "unplugged", "lofi"]) || lower.contains("lo-fi")
        let intense = has(["gym", "workout", "hardstyle", "party", "fire", "hype", "dance", "edm", "pump", "beast",
                           "running", "club", "bass", "energ", "rage", "drill", "phonk"])
        if intense { result.energy += has(["gym", "hardstyle", "workout", "phonk"]) ? 0.42 : 0.35 }
        if soft { result.energy -= has(["super"]) ? 0.35 : 0.25 }
        if has(["rap"]) && !soft { result.energy += 0.1 }

        if has(["happy", "jolly", "fun", "joy", "sunny", "party", "upbeat", "cheer"]) { result.valence += 0.3 }
        if has(["love", "romantic", "romance"]) { result.valence += 0.15; result.energy -= 0.05; result.tags.insert("love") }
        if has(["sad", "broken", "lost", "alone", "heart", "cry", "tear", "pain", "emotional", "depress", "lonely",
                "devil", "dark", "breakup", "miss"]) { result.valence -= 0.3 }
        if has(["acceptance", "nostalg"]) { result.valence -= 0.05 }

        if has(["lofi", "focus", "study", "instrumental", "ambient", "concentrat", "coding"]) || lower.contains("lo-fi") {
            result.focus += 0.55
        } else if soft {
            result.focus += 0.2
        }
        if has(["rap", "party", "hardstyle"]) { result.focus -= 0.15 }

        if has(["drive", "driving", "road", "trip", "travel"]) { result.tags.insert("drive") }
        if has(["walk", "stroll"]) { result.tags.insert("walk") }
        if has(["gym", "workout", "hardstyle", "running"]) { result.tags.insert("workout") }
        if has(["night", "sleep", "late", "midnight"]) { result.tags.insert("night") }
        if has(["morning", "sunrise", "wake"]) { result.tags.insert("morning") }
        if has(["party", "dance", "club"]) { result.tags.insert("social") }
        if has(["rain", "monsoon"]) { result.tags.insert("rain") }
        if intense { result.tags.insert("hype") }

        result.energy = clamp(result.energy)
        result.valence = clamp(result.valence)
        result.focus = clamp(result.focus)
        return result
    }

    // MARK: - Scoring

    struct Ranked {
        var playlist: MusicPlaylist
        var score: Double
        var feel: PlaylistFeel
    }

    static func rank(
        _ playlists: [MusicPlaylist], target: MusicTarget, context: MusicContext,
        plays: [PlayRecord], lastPlayed: (String) -> Date?, titleWords: [String] = [],
        boost: [String: Double] = [:]
    ) -> [Ranked] {
        playlists.map { (playlist) -> Ranked in
            let shape = Self.feel(of: playlist)
            var score = 1.2
            score -= abs(shape.energy - target.energy) * 1.0
            score -= abs(shape.valence - target.valence) * 0.7
            score -= max(0, target.focus - shape.focus) * 0.6

            // Situations that fit, and ones that clash.
            score += Double(shape.tags.intersection(target.situations).count) * 0.2
            if target.situations.contains("focus") && (shape.tags.contains("workout") || shape.tags.contains("social")) {
                score -= 0.3
            }
            if context.daypart == .lateNight && shape.tags.contains("workout") { score -= 0.3 }

            // Asked for a word that's in the playlist's name ("play something romantic").
            let title = Set(MusicIntent.words(playlist.title))
            score += Double(titleWords.filter { title.contains($0) }.count) * 0.5

            score += learned(playlist.id, daypart: context.daypart, weekend: context.weekend, plays: plays)
            score += boost[playlist.id] ?? 0

            if let last = lastPlayed(playlist.id) {
                let hours = Date().timeIntervalSince(last) / 3600
                if hours < 12 { score -= 0.35 } else if hours < 24 { score -= 0.15 }
            }
            if playlist.id == "LM" { score -= 0.05 }       // broad: fine, but rarely the sharpest fit
            score += Double.random(in: 0...0.1)
            return Ranked(playlist: playlist, score: score, feel: shape)
        }
        .sorted { $0.score > $1.score }
    }

    /// What you kept playing from this playlist before, in tiers:
    /// - a playlist I picked: a quick skip means my guess missed (strong), hearing it means it landed
    /// - a playlist you asked for by name: hearing it is a strong yes
    /// - later songs and radio: weak evidence either way
    /// - a like always counts for it, and a dislike against it
    /// The same part of the day and the same kind of day (weekday or weekend) count most.
    static func learned(_ id: String, daypart: Daypart, weekend: Bool, plays: [PlayRecord]) -> Double {
        var wins = 0.0, losses = 0.0
        for record in plays where record.playlistId == id {
            let sameDaypart = Daypart(hour: record.context.hour) == daypart
            let sameKind = (record.context.weekday == 1 || record.context.weekday == 7) == weekend
            let weight = sameDaypart ? (sameKind ? 1.0 : 0.6) : 0.3
            let heard = record.listened >= 60 || (record.duration > 0 && record.listened >= record.duration - 8)
            var value: Double
            switch record.source {
            case "suggest":
                if record.disliked == true { value = -1.2 } else if record.skipped { value = -1.0 }
                else { value = heard ? 0.6 : 0 }
            case "playlist":
                if record.disliked == true { value = -0.3 } else { value = heard ? 1.0 : 0 }
            default:
                if record.disliked == true { value = -0.3 } else if record.skipped { value = -0.15 }
                else { value = heard ? 0.25 : 0 }
            }
            if record.liked == true { value += 0.8 }
            if value > 0 { wins += weight * value } else { losses -= weight * value }
        }
        return 0.5 * (wins - losses) / (wins + losses + 3)
    }

    /// "rainy out and deep in Xcode for 2 hours"
    static func spokenReason(_ target: MusicTarget) -> String {
        let parts = Array(target.reasons.prefix(2))
        guard let first = parts.first else { return "" }
        let joined = parts.count == 2 ? "\(first) and \(parts[1])" : first
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }

    private static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = Double(minutes) / 60
        return hours < 1.5 ? "an hour" : "\(Int(hours.rounded())) hours"
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}
