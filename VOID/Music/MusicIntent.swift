import Foundation

/// Music commands, recognised by fixed rules before either brain sees the message.
/// Small models are unreliable at choosing tools; these phrases are not.
enum MusicIntent: Equatable {
    case pause, resume, next, previous, replay
    case volume(absolute: Int?, delta: Int)
    case nowPlaying, like, dislike, resync
    case likedSongs
    case playlist(String)
    case song(String)
    case suggest(String?)
    case random(String?)

    /// Mood words VOID understands in "play something calm" and "a random chill song".
    static let moods = [
        "calm", "chill", "chilled", "relaxing", "relaxed", "peaceful", "soft", "mellow", "slow",
        "happy", "sad", "romantic", "love", "upbeat", "energetic", "hype", "party", "dance",
        "focus", "focused", "study", "studying", "coding", "work", "workout", "gym", "running",
        "motivational", "motivating", "sleep", "sleepy", "lofi", "lo-fi", "rainy", "night",
        "morning", "evening", "drive", "driving", "sufi", "bollywood", "punjabi", "acoustic",
    ]

    /// `active`: Chrome is connected and a YouTube Music tab is playing or paused. Short
    /// commands like "skip" or "stop" only mean music then.
    static func parse(_ raw: String, active: Bool) -> MusicIntent? {
        let text = normalizeCommand(raw)
        guard !text.isEmpty else { return nil }

        if text.contains("sync") || text.contains("refresh") || text.contains("update"),
           text.contains("library") || text.contains("playlists") {
            return .resync
        }
        if [
            "what's playing", "what is playing", "whats playing", "what song is this", "what's this song",
            "whats this song", "what is this song", "which song is this", "who sings this", "who is singing",
            "what am i listening to", "what song is playing", "name this song", "what's this track",
            "what is playing right now", "what's playing right now", "whats playing right now", "what song is playing right now",
        ].contains(text) {
            return .nowPlaying
        }

        if replayPhrases.contains(text) { return .replay }

        if active {
            if let control = control(text) { return control }
        } else if text.contains("music"), let control = control(text), control != .like, control != .dislike {
            // "pause the music" while nothing is connected: still a music command.
            return control
        }
        return play(text)
    }

    /// "again", "play that one more time", "repeat this song": the song that just played.
    private static let replayPhrases: Set<String> = [
        "again", "play again", "one more time", "once more", "play it one more time", "play that one more time",
        "play this one more time", "play it once more", "play that once more", "replay", "replay it",
        "replay this", "replay that", "replay the song", "replay this song", "replay that song", "repeat",
        "repeat it", "repeat this", "repeat that", "repeat this song", "repeat that song", "repeat the song",
        "play it again", "play that again", "play this again", "play this song again", "play that song again",
        "play the song again", "play the same song", "play the same song again", "play the same one",
        "play the same one again", "same song", "same song again", "play that one again", "play this one again",
        "play it back", "play that back", "put it on again", "put that on again", "put this on again",
        "play the last song again", "play the last one again",
    ]

    private static func control(_ text: String) -> MusicIntent? {
        let pause: Set = [
            "pause", "pause it", "pause the music", "pause music", "pause the song", "pause this", "stop",
            "stop it", "stop the music", "stop music", "stop playing", "stop the song", "music off",
            "turn off the music", "hold the music",
        ]
        if pause.contains(text) { return .pause }
        let resume: Set = [
            "resume", "resume music", "resume the music", "unpause", "continue the music", "continue playing",
            "keep playing", "play", "play it", "play again", "play it again", "music on",
            "turn the music back on", "turn on the music", "start the music again", "start the music", "start music",
        ]
        if resume.contains(text) { return .resume }
        let next: Set = [
            "next", "next song", "next track", "next one", "skip", "skip it", "skip this", "skip this song",
            "skip song", "skip the song", "play the next song", "play next song", "another song", "change song",
            "play another song", "something else", "play another", "play another one", "another one",
            "play something else", "play something different", "play a different song", "play a different one",
            "put on something else", "change it", "change the song", "change this",
        ]
        if next.contains(text) { return .next }
        let previous: Set = [
            "previous", "previous song", "previous track", "last song", "go back", "go back a song",
            "play the previous song", "play the last song", "back one song", "play that again",
        ]
        if previous.contains(text) { return .previous }
        let like: Set = [
            "like this", "like this song", "i like this song", "i love this song", "i love this", "like it",
            "save this song", "add this to liked songs", "add this to my liked songs", "add it to my likes",
            "add this to my likes", "this is a good song", "good song",
        ]
        if like.contains(text) { return .like }
        let dislike: Set = [
            "i don't like this", "i don't like this song", "i dont like this", "i dont like this song",
            "i hate this song", "change this song", "not this song", "not this one", "i don't like it",
            "this song is bad", "bad song",
        ]
        if dislike.contains(text) { return .dislike }
        return volume(text)
    }

    private static func volume(_ text: String) -> MusicIntent? {
        let words = text.split(separator: " ").map(String.init)
        let about = text.contains("volume") || text.contains("music") || text.contains("turn it")
            || ["louder", "quieter", "softer", "mute", "unmute", "a bit louder", "a bit quieter"].contains(text)
        guard about else { return nil }
        if text.hasPrefix("unmute") { return .volume(absolute: 60, delta: 0) }
        if text.hasPrefix("mute") { return .volume(absolute: 0, delta: 0) }
        if text.contains("volume"),
           let number = words.compactMap({ Int($0.replacingOccurrences(of: "%", with: "")) }).first {
            return .volume(absolute: min(100, max(0, number)), delta: 0)
        }
        let up = ["up", "louder", "raise", "increase", "higher", "max"]
        let down = ["down", "quieter", "softer", "lower", "decrease", "reduce"]
        if words.contains(where: { up.contains($0) }) { return .volume(absolute: nil, delta: 15) }
        if words.contains(where: { down.contains($0) }) { return .volume(absolute: nil, delta: -15) }
        return nil
    }

    private static func play(_ text: String) -> MusicIntent? {
        let starts = [
            "play me ", "play ", "put on ", "throw on ", "queue up ", "start playing ", "i want to listen to ",
            "i wanna listen to ", "i want to hear ", "let me listen to ", "let's listen to ", "lets listen to ",
            "listen to ", "can i listen to ", "can i hear ",
        ]
        guard let start = starts.first(where: { text.hasPrefix($0) }) else { return nil }
        var rest = String(text.dropFirst(start.count))

        // "play a game", "play along": not music.
        let restWords = Set(rest.split(separator: " ").map(String.init))
        let blockers: Set = ["game", "games", "chess", "pretend", "along", "roleplay", "trivia", "quiz"]
        if !restWords.isDisjoint(with: blockers) || rest.contains("with me") || rest.hasPrefix("a trick") {
            return nil
        }
        for tail in [" on youtube music", " on yt music", " on youtube", " from youtube", " for me", " please", " now", " right now"] {
            if rest.hasSuffix(tail) { rest = String(rest.dropLast(tail.count)) }
        }
        for article in ["some ", "a ", "an ", "the "] where rest.hasPrefix(article) {
            rest = String(rest.dropFirst(article.count))
        }
        rest = rest.trimmingCharacters(in: .whitespaces)

        let generic: Set = [
            "", "music", "songs", "song", "something", "anything", "tunes", "something good", "good music",
            "my music", "something nice", "something for me", "whatever", "whatever you like", "your choice",
            "you choose", "something you like", "music for me", "good songs", "nice music", "nice songs",
        ]
        if generic.contains(rest) { return .suggest(nil) }

        let words = rest.split(separator: " ").map(String.init)
        let mood = words.first { moods.contains($0) }
        if words.contains("random") || rest.hasPrefix("anything random") { return .random(mood) }

        let liked: Set = [
            "liked songs", "my liked songs", "my likes", "liked music", "my liked music", "my favorites",
            "my favourites", "my favourite songs", "my favorite songs", "songs i like", "what i like",
            "my favorite music", "my favourite music",
        ]
        if liked.contains(rest) { return .likedSongs }

        if words.contains("playlist") {
            let name = words.filter { !["my", "playlist", "the", "from"].contains($0) }.joined(separator: " ")
            return name.isEmpty ? .suggest(nil) : .playlist(name)
        }

        // "something calm", "chill music", "upbeat songs", "focus vibes", "lofi".
        if let mood {
            let soft = ["something", "music", "songs", "song", "vibes", "stuff", "tracks", "beats", "kind", "of", "type", "for", "the", "to", "my", "some", "any", "while", "when", "i", "am", "im"]
            let others = words.filter { !moods.contains($0) && !soft.contains($0) }
            if others.isEmpty { return .suggest(mood) }
        }

        let query = rest.replacingOccurrences(of: " by ", with: " ")
        return .song(query)
    }

    /// Lowercase, plain apostrophes, no punctuation, no "hey VOID"/"can you"/"please".
    /// `normalize`, plus Hinglish commands and speech-recognition slips turned into plain English.
    static func normalizeCommand(_ raw: String) -> String {
        Lexicon.canonical(normalize(raw))
    }

    static func normalize(_ raw: String) -> String {
        var text = raw.lowercased().replacingOccurrences(of: "’", with: "'")
        text = String(text.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "-" || scalar == "%" {
                return Character(scalar)
            }
            return " "
        })
        text = text.split(separator: " ").joined(separator: " ")
        let fillers = [
            "hey void ", "hi void ", "ok void ", "okay void ", "void ", "okay ", "ok ", "hey ", "please ",
            "can you ", "could you ", "would you ", "will you ", "can u ", "just ", "now ", "go ahead and ",
            "i want you to ", "kindly ",
        ]
        var changed = true
        while changed {
            changed = false
            for filler in fillers where text.hasPrefix(filler) {
                text = String(text.dropFirst(filler.count))
                changed = true
            }
        }
        for tail in [" please", " void", " thanks", " thank you"] where text.hasSuffix(tail) {
            text = String(text.dropLast(tail.count))
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Fuzzy matching

    private static let stopWords: Set = ["the", "a", "an", "by", "my", "of", "and", "to", "in", "on", "song", "songs", "playlist", "music", "ft", "feat"]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
    }

    /// How well `target` covers what was asked: 1 = every word asked for is there.
    static func similarity(_ query: String, _ target: String) -> Double {
        let asked = Set(words(query))
        let found = Set(words(target))
        guard !asked.isEmpty, !found.isEmpty else { return 0 }
        // A word counts when the other side has it, or a longer form of it ("choot" / "chootiya").
        func matches(_ a: String, _ b: String) -> Bool {
            a == b || (a.count >= 3 && b.count >= 3 && (a.hasPrefix(b) || b.hasPrefix(a)))
        }
        let shared = Double(asked.filter { w in found.contains { matches(w, $0) } }.count)
        return 0.8 * shared / Double(asked.count) + 0.2 * min(shared, Double(found.count)) / Double(found.count)
    }
}
