import Foundation

/// The small model's job when a message isn't an exact music command: read the
/// conversation, decide whether the person means the music, and name the action.
extension Persona {
    static let musicRouter = """
    You control a music player (YouTube Music) for the user. Read their latest message, using the recent \
    conversation to understand what "it", "that" or "another" mean. Decide if they want something done with the \
    music. Reply with ONE line: the action, nothing else.

    Actions:
    NONE - not asking for anything about the music (chatting, a mention, an opinion with no request)
    PAUSE
    RESUME
    NEXT - skip to the next song
    PREVIOUS - go back
    VOLUME_UP
    VOLUME_DOWN
    MUTE
    NOW_PLAYING - asks what song or artist this is
    LIKE - says they love or like the current song
    DISLIKE - says the current song is bad, boring or not their taste, or wants it gone or wants another (it skips and remembers)
    PLAYLIST: <name> - play one of their playlists by name
    SONG: <title and artist> - play a specific song
    MOOD: <word> - they name the kind of music they want (calm, sad, gym, party, lofi, focus)
    SUGGEST - play something that fits now, no details given, or they only say how they feel
    RANDOM - a random song, surprise me

    Examples:
    that song was not good, play another -> DISLIKE
    ugh not this one -> DISLIKE
    this is so boring -> DISLIKE
    i love this song -> LIKE
    can you make it a bit quieter -> VOLUME_DOWN
    i can't hear it -> VOLUME_UP
    ok continue -> RESUME
    who sings this -> NOW_PLAYING
    put on tum hi ho by arijit singh -> SONG: Tum Hi Ho Arijit Singh
    play my gym playlist -> PLAYLIST: gym
    something calm please -> MOOD: calm
    i'm feeling low, put something on -> SUGGEST
    play something for me -> SUGGEST
    surprise me -> RANDOM
    how is the weather today -> NONE
    this meeting is boring -> NONE
    that song reminds me of school -> NONE
    what do you think of this artist -> NONE
    """

    static func musicRouterPrompt(user: String, recent: String, nowPlaying: String?) -> String {
        var text = ""
        if let nowPlaying { text += "Now playing: \(nowPlaying)\n" } else { text += "Now playing: nothing\n" }
        if !recent.isEmpty { text += "Recent conversation:\n\(recent)\n" }
        text += "\nLatest message: \(user)\nAction:"
        return text
    }
}

extension MusicIntent {
    /// Reads the router's one-line answer. Anything unclear is "not a music request",
    /// so a confused model never starts music by mistake.
    /// Does the message talk about playback at all? The router model is never asked about the rest.
    static func musicish(_ message: String) -> Bool {
        let t = normalizeCommand(message)
        let words = Set(t.split(separator: " ").map(String.init))
        let keywords: Set<String> = [
            "song", "songs", "music", "track", "tracks", "play", "playing", "pause", "paused", "skip", "next",
            "previous", "volume", "louder", "quieter", "softer", "mute", "unmute", "playlist", "album", "artist",
            "listen", "tune", "tunes", "resume", "replay", "repeat", "again", "queue", "shuffle", "vibe", "vibes",
            "lofi", "liked", "likes", "favourites", "favorites", "singing", "sings", "stop", "like", "love", "hate",
        ]
        if !words.isDisjoint(with: keywords) { return true }
        return t.contains("this one") || t.contains("turn it") || t.contains("it up") || t.contains("it down")
            || t.contains("something else") || t.contains("something calm") || t.contains("in the mood")
    }

    static func fromRouter(_ raw: String, message: String) -> MusicIntent? {
        guard let first = raw.split(whereSeparator: \.isNewline).first else { return nil }
        var line = String(first).trimmingCharacters(in: .whitespaces)
        for lead in ["Action:", "action:", "->", "→"] where line.hasPrefix(lead) {
            line = String(line.dropFirst(lead.count)).trimmingCharacters(in: .whitespaces)
        }
        let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let name = pieces[0].trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: " ", with: "_")
        let argument = pieces.count > 1
            ? pieces[1].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'“”")))
            : ""

        // Starting new music needs the message to sound like asking for music.
        let lower = message.lowercased()
        let asksForMusic = [
            "play", "put on", "listen", "hear", "song", "music", "playlist", "track", "something", "another",
            "different", "queue", "throw on", "switch", "surprise", "random", "vibe", "mood", "feeling", "feel",
        ].contains { lower.contains($0) }

        // Each action also needs words that really ask for it, so the model can't turn a remark
        // like "i hate mondays" into a dislike or "turn it off" into a volume change.
        let said = " " + MusicIntent.normalizeCommand(message) + " "
        func has(_ any: [String]) -> Bool { any.contains { said.contains($0) } }
        let aboutSong = has([" song", " track", " this", " it ", " that", " one "])
        switch name {
        case "PAUSE": guard has(["pause", "stop", " off", "quiet", "silence", "hold", "halt", "shut"]) else { return nil }
        case "RESUME": guard has(["resume", "continue", "play", "unpause", "start", "keep"]) else { return nil }
        case "NEXT": guard has(["next", "skip", "another", "different", "else", "change", "switch"]) else { return nil }
        case "PREVIOUS": guard has(["previous", "last", "back", "before"]) else { return nil }
        case "VOLUME_UP": guard has([" up", "louder", "raise", "increase", "higher", "loud", "max"]) else { return nil }
        case "VOLUME_DOWN": guard has([" down", "quieter", "softer", "lower", "decrease", "reduce", "quiet"]) else { return nil }
        case "MUTE": guard has(["mute", "silent", "silence"]) else { return nil }
        case "NOW_PLAYING": guard has([" this", "playing", "current", "listening", "right now"]) else { return nil }
        case "LIKE", "DISLIKE": guard aboutSong && has(["like", "love", "hate", "dislike", "bad", "good", "save", "add", "not "]) else { return nil }
        default: break
        }
        switch name {
        case "PAUSE": return .pause
        case "RESUME": return .resume
        case "NEXT": return .next
        case "PREVIOUS": return .previous
        case "VOLUME_UP": return .volume(absolute: nil, delta: 15)
        case "VOLUME_DOWN": return .volume(absolute: nil, delta: -15)
        case "MUTE": return .volume(absolute: 0, delta: 0)
        case "NOW_PLAYING": return .nowPlaying
        case "LIKE": return .like
        case "DISLIKE": return .dislike
        case "PLAYLIST":
            return asksForMusic && !argument.isEmpty ? .playlist(argument.lowercased()) : nil
        case "SONG":
            return asksForMusic && !argument.isEmpty ? .song(argument) : nil
        case "MOOD":
            guard asksForMusic, !argument.isEmpty else { return nil }
            let mood = argument.lowercased().split(separator: " ").map(String.init).first { moods.contains($0) }
            return .suggest(mood ?? argument.lowercased())
        case "SUGGEST":
            return asksForMusic ? .suggest(nil) : nil
        case "RANDOM":
            return asksForMusic ? .random(nil) : nil
        default:
            return nil
        }
    }
}
