import AppKit
import Foundation

/// VOID's music hands: turns music commands into actions on your YouTube Music tab,
/// keeps the library cache and your listening history, and ducks the music while you
/// and VOID talk.
@MainActor
final class MusicController {
    private let state: AppState
    private let bridge = MusicBridge()
    let store = MusicStore()

    /// The latest report from the YouTube Music tab.
    private var player: [String: Any] = [:]
    /// The song playing now, logged when it changes.
    private var current: PlayRecord?
    /// How the next song that starts was asked for.
    private var nextSource: (source: String, playlistId: String?)?
    private let sensor = ContextSensor()
    /// The moment a pick was made, kept with every song that plays from it.
    private var sessionContext: ListenContext?
    /// The playlist currently playing through, so its later songs count toward it too.
    private var activePlaylist: String?

    /// A question I asked and am waiting on the answer to.
    private enum Pending { case goal, vibe }
    private var pending: Pending?
    private var pendingSince = Date.distantPast
    /// When you recently skipped or rejected a song, to notice a pick that isn't landing.
    private var skipTimes: [Date] = []

    private var lastMusicActivity: Date?
    private var ducked = false
    private var savedVolume: Int?
    private var duckTask: Task<Void, Never>?
    private var syncing = false

    /// Set by hands-free listening while you're talking.
    var userTalking = false

    var pairingCode: String { bridge.token }

    init(state: AppState) {
        self.state = state
    }

    func start() {
        bridge.onConnectionChange = { [weak self] connected in self?.connectionChanged(connected) }
        bridge.onEvent = { [weak self] type, message in self?.event(type, message) }
        bridge.start()
        state.musicStatus = store.playlists.isEmpty
            ? "Music: waiting for Chrome"
            : "Music: \(store.playlists.count) playlists cached · waiting for Chrome"
        startDuckLoop()
    }

    func copyPairingCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pairingCode, forType: .string)
        state.statusLine = "Pairing code \(pairingCode) copied. Paste it into the VOID Music extension."
    }

    private var active: Bool {
        bridge.isConnected && !((player["videoId"] as? String) ?? "").isEmpty
    }

    // MARK: - Commands

    /// Handles a music command. Returns what VOID should say, or nil when the message
    /// isn't about music (then the brains answer as usual).
    func handle(_ text: String) async -> String? {
        if let answer = await answerPending(text) { return answer }
        guard let intent = MusicIntent.parse(text, active: active) else { return nil }
        return await run(intent)
    }

    /// Carries out a music action, whether it came from a fixed phrase or from the model.
    func run(_ intent: MusicIntent) async -> String {
        guard bridge.isConnected else {
            return "Chrome isn't connected to me yet. Open Chrome with the VOID Music extension, and paste the pairing code from my menu."
        }
        lastMusicActivity = Date()
        do {
            return try await perform(intent)
        } catch {
            return "Hmm, that didn't work. \(error.localizedDescription)"
        }
    }

    /// Reads the answer to a question I asked. Anything that isn't an answer drops the question.
    private func answerPending(_ text: String) async -> String? {
        guard let question = pending else { return nil }
        pending = nil
        guard Date().timeIntervalSince(pendingSince) < 180, bridge.isConnected else { return nil }
        let said = MusicIntent.normalize(text)
        // A normal command ("pause", "play my gym playlist") is never an answer.
        if MusicIntent.parse(text, active: active) != nil { return nil }
        let wordSet = Set(said.split(separator: " ").map(String.init))
        lastMusicActivity = Date()
        do {
            switch question {
            case .goal:
                let match = ["match", "same", "stay", "sit", "sadder", "heavy", "feel", "wallow", "vent", "it"]
                let lift = ["lift", "cheer", "up", "better", "happy", "happier", "calm", "calmer", "relax", "brighter", "energy"]
                let wantsLift = !wordSet.isDisjoint(with: lift) || said.contains("pick me up") || said.contains("snap out")
                let wantsMatch = !wordSet.isDisjoint(with: match) || said.contains("with it")
                guard wantsLift || wantsMatch else { return nil }
                sensor.setGoal(wantsLift ? "lift" : "match")
                return try await suggest(mood: nil)
            case .vibe:
                let calmer: Set = ["calm", "calmer", "slower", "softer", "quieter", "mellow", "chill", "relaxing"]
                let livelier: Set = ["livelier", "upbeat", "energetic", "faster", "louder", "happier", "hype", "fun"]
                if !wordSet.isDisjoint(with: calmer) { return try await suggest(mood: "calm") }
                if !wordSet.isDisjoint(with: livelier) { return try await suggest(mood: "upbeat") }
                if let named = MusicIntent.words(said).first(where: { MusicIntent.moods.contains($0) }) {
                    return try await suggest(mood: named)
                }
                if let match = bestPlaylist(for: said, threshold: 0.5) {
                    return try await playPlaylist(id: match.id, name: match.title, source: "playlist")
                }
                return try await playSong(said)
            }
        } catch {
            return "Hmm, that didn't work. \(error.localizedDescription)"
        }
    }

    /// After two quick skips in a row, stop guessing and ask.
    private func skipNudge() -> String? {
        let now = Date()
        skipTimes = skipTimes.filter { now.timeIntervalSince($0) < 600 } + [now]
        guard skipTimes.count >= 2 else { return nil }
        skipTimes = []
        pending = .vibe
        pendingSince = now
        return " That's two misses. Want something calmer, livelier, or a particular song or playlist?"
    }

    /// Music is "in play": a song is loaded, or music was asked for in the last 10 minutes.
    /// Only then is the model asked whether a message is about the music.
    var routerEligible: Bool {
        guard bridge.isConnected else { return false }
        if active { return true }
        return Date().timeIntervalSince(lastMusicActivity ?? .distantPast) < 600
    }

    /// "Song by Artist" for what's loaded in YouTube Music, playing or paused.
    var currentSong: String? { playingTrack?.spoken }

    private func perform(_ intent: MusicIntent) async throws -> String {
        switch intent {
        case .pause:
            try await control("pause")
            return "Paused."
        case .resume:
            try await control("play")
            return "Back on."
        case .next:
            try await control("next")
            return "Next one." + (skipNudge() ?? "")
        case .previous:
            try await control("previous")
            return "Going back."
        case .volume(let absolute, let delta):
            let now = savedVolume ?? Int(Self.number(player["volume"]) ?? 50)
            let target = min(100, max(0, absolute ?? now + delta))
            if ducked {
                savedVolume = target            // applied when the music comes back up
            } else {
                _ = try await bridge.request("volume", ["level": target])
            }
            return target == 0 ? "Muted." : "Volume \(target)."
        case .replay:
            if active {
                try await control("restart")
                return "Again."
            }
            guard let last = store.plays.last?.track else { return "I don't have a song to repeat yet." }
            try await play(Self.radioURL(last.videoId), source: "request")
            return "Playing \(last.spoken) again."
        case .nowPlaying:
            guard let track = playingTrack else { return "Nothing's playing right now." }
            return "This is \(track.spoken)."
        case .like:
            guard let track = playingTrack else { return "Nothing's playing to like." }
            try? await control("like")
            if var record = current { record.liked = true; current = record }
            store.recordLike(track, source: "voice", context: .now())
            return "Saved to your likes."
        case .dislike:
            if var record = current { record.disliked = true; current = record }
            closeCurrent()
            try await control("next")
            let line = ["Okay, not that one. Trying another.", "Fair, that one's gone. Next.",
                        "Got it, skipping that. I'll remember you didn't like it.", "Noted. Switching it up."].randomElement()!
            return line + (skipNudge() ?? "")
        case .resync:
            return await sync()
        case .likedSongs:
            return try await playPlaylist(id: "LM", name: "your liked songs")
        case .playlist(let name):
            if store.playlists.isEmpty { return "I haven't read your library yet. Give me a moment to sync it." }
            guard let match = bestPlaylist(for: name, threshold: 0.5) else {
                return "I couldn't find a playlist called \(name)."
            }
            return try await playPlaylist(id: match.id, name: match.title)
        case .song(let query):
            if let match = bestPlaylist(for: query, threshold: 0.85) {
                return try await playPlaylist(id: match.id, name: match.title)
            }
            return try await playSong(query)
        case .suggest(let mood):
            return try await suggest(mood: mood)
        case .random(let mood):
            return try await playRandom(mood: mood)
        }
    }

    private func control(_ action: String) async throws {
        _ = try await bridge.request("control", ["action": action])
    }

    private func play(_ url: String, source: String, playlistId: String? = nil, context: ListenContext? = nil) async throws {
        nextSource = (source, playlistId)
        sessionContext = context
        activePlaylist = playlistId
        _ = try await bridge.request("play", ["url": url], timeout: 40)
    }

    /// A song followed by its YouTube Music radio, so related music keeps going after it.
    private static func radioURL(_ videoId: String) -> String {
        "https://music.youtube.com/watch?v=\(videoId)&list=RDAMVM\(videoId)"
    }

    @discardableResult
    private func playPlaylist(id: String, name: String, context: ListenContext? = nil, source: String = "playlist") async throws -> String {
        let playlist = store.playlists.first { $0.id == id }
        var url = "https://music.youtube.com/watch?list=\(id)"
        // Start somewhere new each time, so the same playlist doesn't always open the same way.
        if let start = weightedPick(playlist?.tracks.filter({ !store.disliked.contains($0.videoId) }) ?? []) {
            url = "https://music.youtube.com/watch?v=\(start.videoId)&list=\(id)"
        }
        try await play(url, source: source, playlistId: id, context: context)
        store.notePlaylistPlayed(id)
        return "Putting on \(name)."
    }

    private func playSong(_ query: String) async throws -> String {
        let results = try await search(query)
        guard var best = Self.bestSong(results, query: query) else {
            return "I couldn't find \(query) on YouTube Music."
        }
        // None of the results share a word with what you asked for: trust YouTube's own order
        // and play its first song.
        let anyShared = results.contains { MusicIntent.similarity(query, "\($0.track.title) \($0.track.artist)") > 0 }
        if !anyShared, let first = results.first(where: { Self.isSong($0) }) ?? results.first {
            best = (first.track, 0)
        }
        if best.score < 0.6 {
            // Show what the search really returned, so a bad match can be diagnosed from the transcript.
            let seen = results.prefix(6).map { "\($0.track.title) — \($0.track.artist)" }.joined(separator: " | ")
            NSLog("VOID search \"\(query)\" saw: \(seen)")
            state.statusLine = "Search saw: " + seen
        }
        try await play(Self.radioURL(best.track.videoId), source: "request")
        return best.score >= 0.6 ? "Here's \(best.track.spoken)." : "Playing the closest match I found, \(best.track.spoken)."
    }

    // MARK: - Picking music

    /// Lets the sensor notice how you say you feel, in anything you tell VOID.
    func noteVoice(_ text: String, samples: [Float]) {
        guard !samples.isEmpty else { return }
        let energy = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)
        sensor.noteVoice(
            words: text.split(separator: " ").count, seconds: Double(samples.count) / 16000,
            rms: energy.squareRoot())
    }

    func noteUserText(_ text: String) {
        sensor.noteMood(from: text)
    }

    /// Picks one of your playlists for this moment: time, weather, what you're doing on the
    /// Mac, how the room sounds, how you said you feel, and what you kept playing before.
    private func suggest(mood: String?) async throws -> String {
        let pool = store.playlists.filter { !$0.tracks.isEmpty }
        guard !pool.isEmpty else { return try await playRandom(mood: mood) }
        // A mood I have no feel for and no playlist is named after (a genre, say): search for it.
        if let mood, MusicPicker.moodDials[mood] == nil,
           !pool.contains(where: { MusicIntent.words($0.title).contains(mood) }) {
            return try await playRandom(mood: mood)
        }
        // Heavy mood, and I don't know if you want to stay with it or be lifted: ask once.
        if mood == nil, let note = sensor.recentMood, note.goal == nil,
           ["sad", "stressed", "angry", "tired"].contains(note.mood) {
            pending = .goal
            pendingSince = Date()
            switch note.mood {
            case "angry": return "Sounds like a rough one. Want something to let the steam out, or something to calm you down?"
            case "tired": return "You sound tired. Want something gentle, or a pick-me-up?"
            case "stressed": return "Sounds stressful. Want something calming, or something to lift you out of it?"
            default: return "Sorry you're feeling low. Want music that sits with it, or something to lift you?"
            }
        }
        let context = await sensor.snapshot(listenToRoom: mood == nil)
        let target = MusicPicker.target(for: context, mood: mood)
        // Often, start with a song you keep replaying that suits this moment.
        if Int.random(in: 0..<100) < 35,
           let again = replayPick(target: target, avoid: store.recentlyPlayed(hours: 72).union(store.disliked)) {
            note(context, "→ replay \(again.title)")
            try await play(Self.radioURL(again.videoId), source: "random", context: context.listen)
            if let mood { return "Something \(mood): \(again.spoken), one you keep replaying." }
            return "\(MusicPicker.spokenReason(target)), so here's \(again.spoken), one you keep replaying."
        }
        let ranked = MusicPicker.rank(
            pool, target: target, context: context, plays: store.plays,
            lastPlayed: { [store] in store.lastPlayed(playlist: $0) },
            titleWords: mood.map { [$0] } ?? [], boost: replayBoost(for: pool))
        guard let pick = ranked.first?.playlist else { return try await playRandom(mood: mood) }
        note(context, "→ \(pick.title)")
        let name = pick.id == "LM" ? "your liked songs" : pick.title
        try await playPlaylist(id: pick.id, name: name, context: context.listen, source: "suggest")
        if mood != nil { return "Putting on \(name)." }
        return "\(MusicPicker.spokenReason(target)), so putting on \(name)."
    }

    /// One song from a YouTube Music search shaped by the moment, then its radio.
    private func playRandom(mood: String?) async throws -> String {
        let context = await sensor.snapshot(listenToRoom: mood == nil)
        let target = MusicPicker.target(for: context, mood: mood)
        let recent = store.recentlyPlayed(hours: 72)
        let disliked = store.disliked

        // Often, start with something you keep replaying that suits this moment.
        if Int.random(in: 0..<100) < 55, let again = replayPick(target: target, avoid: recent.union(disliked)) {
            note(context, "→ replay \(again.title)")
            try await play(Self.radioURL(again.videoId), source: "random", context: context.listen)
            if let mood { return "Something \(mood): \(again.spoken), one you keep replaying." }
            return "\(MusicPicker.spokenReason(target)), so here's \(again.spoken), one you keep replaying."
        }
        let query = randomQuery(target: target, context: context, mood: mood)
        note(context, "→ search “\(query)”")

        let results = (try? await search(query)) ?? []
        let songs = results.filter {
            Self.isSong($0) && !recent.contains($0.track.videoId) && !disliked.contains($0.track.videoId)
        }
        let liked = Set(tasteCounts().keys)
        let candidates = Array(songs.prefix(8))
        let weights = candidates.map { liked.contains($0.track.artist) ? 4.0 : 1.0 }
        var pick: MusicTrack?
        if !candidates.isEmpty {
            var roll = Double.random(in: 0..<weights.reduce(0, +))
            for (hit, weight) in zip(candidates, weights) {
                roll -= weight
                if roll < 0 { pick = hit.track; break }
            }
            pick = pick ?? candidates.last?.track
        }

        if pick == nil {
            // Search came back empty: take a song from the playlists that fit best.
            let pool = store.playlists.filter { !$0.tracks.isEmpty }
            let top = MusicPicker.rank(
                pool, target: target, context: context, plays: store.plays,
                lastPlayed: { [store] in store.lastPlayed(playlist: $0) },
                boost: replayBoost(for: pool)).prefix(3)
            pick = weightedPick(top.flatMap(\.playlist.tracks)
                .filter { !recent.contains($0.videoId) && !disliked.contains($0.videoId) })
        }
        guard let pick else { return "I couldn't find anything to play right now." }
        try await play(Self.radioURL(pick.videoId), source: "random", context: context.listen)
        if let mood { return "Something \(mood): \(pick.spoken)." }
        return "\(MusicPicker.spokenReason(target)), so here's \(pick.spoken)."
    }

    /// A random song, with songs you keep replaying about three times as likely.
    private func weightedPick(_ tracks: [MusicTrack]) -> MusicTrack? {
        guard !tracks.isEmpty else { return nil }
        let again = store.listenAgainIDs
        let weights = tracks.map { again.contains($0.videoId) ? 5.0 : 1.0 }
        var roll = Double.random(in: 0..<weights.reduce(0, +))
        for (track, weight) in zip(tracks, weights) {
            roll -= weight
            if roll < 0 { return track }
        }
        return tracks.last
    }

    /// A small bonus for playlists that hold songs you keep replaying.
    private func replayBoost(for pool: [MusicPlaylist]) -> [String: Double] {
        let again = store.listenAgainIDs
        guard !again.isEmpty else { return [:] }
        var boost: [String: Double] = [:]
        for playlist in pool {
            let count = playlist.tracks.filter { again.contains($0.videoId) }.count
            if count > 0 { boost[playlist.id] = min(0.3, 0.08 * Double(count)) }
        }
        return boost
    }

    /// A replayed song that suits the moment. A song's feel is the average feel of the
    /// playlists it sits in; a song only in Liked Music, or in none, can't be judged.
    private func replayPick(target: MusicTarget, avoid: Set<String>) -> MusicTrack? {
        var fits: [MusicTrack] = []
        var unjudged: [MusicTrack] = []
        for song in store.listenAgain where !avoid.contains(song.videoId) {
            let homes = store.playlists.filter { $0.id != "LM" && $0.tracks.contains { $0.videoId == song.videoId } }
            guard !homes.isEmpty else { unjudged.append(song); continue }
            let feels = homes.map(MusicPicker.feel(of:))
            let count = Double(feels.count)
            let energy = feels.map(\.energy).reduce(0, +) / count
            let valence = feels.map(\.valence).reduce(0, +) / count
            let focus = feels.map(\.focus).reduce(0, +) / count
            let distance = abs(energy - target.energy) + 0.7 * abs(valence - target.valence)
                + 0.6 * max(0, target.focus - focus)
            if distance <= 0.4 { fits.append(song) }
        }
        // Songs that sit in no mood-named playlist can't be judged; they join in, but a
        // song known to fit is preferred.
        if let song = fits.randomElement(), unjudged.isEmpty || Int.random(in: 0..<3) > 0 { return song }
        return unjudged.randomElement() ?? fits.randomElement()
    }

    /// The search words for a random song. Mostly built around an artist you already
    /// listen to, so the language and style follow your taste, not generic English results.
    private func randomQuery(target: MusicTarget, context: MusicContext, mood: String?) -> String {
        var feel: String
        if let mood {
            feel = mood
        } else {
            feel = target.energy < 0.3 ? "calm" : target.energy < 0.5 ? "chill" : target.energy < 0.75 ? "feel good" : "energetic"
            if target.valence < 0.35 { feel = "sad" } else if target.valence > 0.78 && target.energy >= 0.5 { feel = "happy" }
            if target.focus > 0.7 { feel = "focus" }
        }
        if Int.random(in: 0..<10) < 8, let artist = tasteArtist() {
            return Int.random(in: 0..<2) == 0 ? "\(artist) \(feel) songs" : "songs like \(artist)"
        }
        return "\(feel) songs"
    }

    /// Artists by how much you listen to them: replays count most, then listened-through
    /// songs, then likes, then what simply sits in your playlists.
    private func tasteCounts() -> [String: Double] {
        var counts: [String: Double] = [:]
        for song in store.listenAgain where !song.artist.isEmpty { counts[song.artist, default: 0] += 3 }
        for song in store.liked where !song.track.artist.isEmpty { counts[song.track.artist, default: 0] += 1 }
        for play in store.plays where !play.skipped && !play.track.artist.isEmpty { counts[play.track.artist, default: 0] += 2 }
        for playlist in store.playlists {
            for track in playlist.tracks.prefix(60) where !track.artist.isEmpty { counts[track.artist, default: 0] += 0.2 }
        }
        return counts
    }

    private func tasteArtist() -> String? {
        let top = tasteCounts().sorted { $0.value > $1.value }.prefix(15)
        guard !top.isEmpty else { return nil }
        var roll = Double.random(in: 0..<top.map(\.value).reduce(0, +))
        for entry in top {
            roll -= entry.value
            if roll < 0 { return entry.key }
        }
        return top.first?.key
    }

    private func note(_ context: MusicContext, _ choice: String) {
        state.musicContextNote = "\(context.summary) \(choice)"
    }

    // MARK: - Search

    private struct SearchHit {
        var track: MusicTrack
        var kind: String
        var subtitle: String
    }

    private func search(_ query: String) async throws -> [SearchHit] {
        let data = try await bridge.request("search", ["query": query], timeout: 40)
        let items = data["items"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let track = MusicTrack(json: item) else { return nil }
            return SearchHit(track: track, kind: item["kind"] as? String ?? "", subtitle: item["subtitle"] as? String ?? "")
        }
    }

    private static func isSong(_ result: SearchHit) -> Bool {
        result.kind.lowercased().contains("song") || result.subtitle.lowercased().hasPrefix("song")
    }

    private static func bestSong(_ results: [SearchHit], query: String) -> (track: MusicTrack, score: Double)? {
        var best: (track: MusicTrack, score: Double)?
        for result in results {
            var score = MusicIntent.similarity(query, "\(result.track.title) \(result.track.artist)")
            if isSong(result) { score += 0.15 }
            if result.kind == "Top result" { score += 0.05 }
            let kind = result.kind.lowercased() + " " + result.subtitle.lowercased()
            if kind.contains("episode") || kind.contains("podcast") { score -= 0.5 }
            if best == nil || score > best!.score { best = (result.track, score) }
        }
        return best
    }

    private func bestPlaylist(for name: String, threshold: Double) -> MusicPlaylist? {
        let asked = MusicIntent.words(name).joined(separator: " ")
        var best: (playlist: MusicPlaylist, score: Double)?
        for playlist in store.playlists {
            let title = playlist.id == "LM" ? "liked songs liked music" : playlist.title
            var score = MusicIntent.similarity(name, title)
            let plain = MusicIntent.words(title).joined(separator: " ")
            if !asked.isEmpty, plain.contains(asked) { score = max(score, 0.9) }
            if best == nil || score > best!.score { best = (playlist, score) }
        }
        guard let best, best.score >= threshold else { return nil }
        return best.playlist
    }

    // MARK: - Library

    /// Reads your playlists from YouTube Music again. Unchanged playlists keep their cached tracks.
    @discardableResult
    func sync() async -> String {
        guard bridge.isConnected else { return "Chrome isn't connected, so I can't read your library." }
        guard !syncing else { return "Already reading your library." }
        syncing = true
        defer { syncing = false }
        state.musicStatus = "Music: connected · reading your library…"
        var known: [String: String] = [:]
        for playlist in store.playlists where !playlist.tracks.isEmpty {
            // A playlist whose cache came up short is read again even if it hasn't changed.
            let expected = Self.trackCount(in: playlist.subtitle)
            let cap = playlist.id == "LM" ? 300 : 60
            if expected > 0, playlist.tracks.count < min(expected, cap) - 3 { continue }
            known[playlist.id] = playlist.subtitle
        }
        do {
            let data = try await bridge.request("syncLibrary", ["known": known], timeout: 600)
            let list = data["playlists"] as? [[String: Any]] ?? []
            var fresh: [MusicPlaylist] = []
            for item in list {
                guard let id = item["id"] as? String, let title = item["title"] as? String else { continue }
                let old = store.playlists.first { $0.id == id }
                let tracks = (item["tracks"] as? [[String: Any]]).map { $0.compactMap { MusicTrack(json: $0) } }
                fresh.append(MusicPlaylist(
                    id: id, title: title, subtitle: item["subtitle"] as? String ?? "",
                    tracks: tracks ?? old?.tracks ?? [], updated: Date()))
            }
            // Playlists that came up well short of their own track count (a few missing
            // songs are normally unavailable ones).
            var short: [String] = []
            for item in list {
                guard let title = item["title"] as? String,
                      let expected = (item["expected"] as? NSNumber)?.intValue, expected > 0,
                      let id = item["id"] as? String,
                      let got = fresh.first(where: { $0.id == id })?.tracks.count else { continue }
                let cap = id == "LM" ? 300 : 60
                if got < min(expected, cap) - 3 { short.append("\(title) (\(got) of \(expected))") }
            }
            guard !fresh.isEmpty else {
                state.musicStatus = "Music: connected · no playlists found"
                return "I couldn't see any playlists. Are you signed in to YouTube Music in Chrome?"
            }
            store.replaceLibrary(fresh)
            // What you keep replaying (YouTube Music's "Listen again"), a small bonus later.
            if let again = try? await bridge.request("syncListenAgain", timeout: 90) {
                let songs = (again["items"] as? [[String: Any]] ?? []).compactMap { MusicTrack(json: $0) }
                if !songs.isEmpty { store.replaceListenAgain(songs) }
            }
            state.musicStatus = "Music: connected · \(fresh.count) playlists, \(store.liked.count) liked songs, \(store.listenAgain.count) replays"
            let total = fresh.reduce(0) { $0 + $1.tracks.count }
            if short.isEmpty { return "I've read your library: \(fresh.count) playlists, \(total) songs." }
            state.musicStatus += " · \(short.count) incomplete"
            return "I've read \(fresh.count) playlists, \(total) songs, but \(short.count) didn't fully load: \(short.prefix(3).joined(separator: ", "))."
        } catch {
            state.musicStatus = "Music: connected · library sync failed"
            return "I couldn't read your library. \(error.localizedDescription)"
        }
    }

    /// "Official Aditya • 52 tracks" → 52 (0 when the subtitle has no count).
    private static func trackCount(in subtitle: String) -> Int {
        let words = subtitle.split(whereSeparator: { !$0.isNumber && !$0.isLetter })
        for (index, word) in words.enumerated() where index + 1 < words.count {
            let next = words[index + 1].lowercased()
            if let number = Int(word), next.hasPrefix("track") || next.hasPrefix("song") { return number }
        }
        return 0
    }

    // MARK: - Events from Chrome

    private func connectionChanged(_ connected: Bool) {
        state.musicConnected = connected
        if connected {
            state.musicStatus = "Music: connected"
            Task { [weak self] in await self?.sync() }
        } else {
            player = [:]
            state.nowPlaying = nil
            closeCurrent()
            ducked = false
            savedVolume = nil
            state.musicStatus = "Music: Chrome disconnected"
        }
    }

    private var playingTrack: MusicTrack? {
        guard let id = player["videoId"] as? String, !id.isEmpty else { return nil }
        return MusicTrack(videoId: id, title: player["title"] as? String ?? "", artist: player["artist"] as? String ?? "")
    }

    /// Opens the installed YouTube Music app, in the background, when Chrome asks for it.
    private func launchMusicApp() {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let folders = [
            home.appendingPathComponent("Applications/Chrome Apps.localized"),
            URL(fileURLWithPath: "/Applications/Chrome Apps.localized"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications"),
        ]
        for folder in folders {
            let app = folder.appendingPathComponent("YouTube Music.app")
            guard manager.fileExists(atPath: app.path) else { continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in }
            return
        }
        bridge.notify("appMissing")
    }

    private func event(_ type: String, _ message: [String: Any]) {
        if type == "launchApp" {
            launchMusicApp()
            return
        }
        guard type == "state" else { return }
        player = message
        let playing = message["playing"] as? Bool ?? false
        let time = Self.number(message["time"]) ?? 0
        let duration = Self.number(message["duration"]) ?? 0
        guard let track = playingTrack else {
            state.nowPlaying = nil
            return
        }
        state.nowPlaying = playing && !track.title.isEmpty ? track.spoken : nil

        if current?.track.videoId != track.videoId {
            closeCurrent()
            let source = nextSource
            nextSource = nil
            current = PlayRecord(
                track: track, started: Date(), listened: time, duration: duration, skipped: false,
                source: source?.source ?? "continued", playlistId: source?.playlistId ?? activePlaylist,
                disliked: nil, context: sessionContext ?? .now(), liked: nil)
        } else {
            if var record = current {
                record.listened = max(record.listened, time)
                if duration > 0 { record.duration = duration }
                if record.track.title.isEmpty { record.track = track }
                current = record
            }
        }
        if message["liked"] as? Bool == true, !store.isLiked(track.videoId) {
            if var record = current { record.liked = true; current = record }
            store.recordLike(track, source: "youtube", context: .now())
        }
    }

    /// Logs the song that just ended: listened to, or skipped in the first 30 seconds.
    private func closeCurrent() {
        guard var record = current else { return }
        current = nil
        guard record.listened > 3 || record.disliked == true else { return }
        let reachedEnd = record.duration > 0 && record.listened >= record.duration - 8
        record.skipped = record.disliked == true || (!reachedEnd && record.listened < 30)
        store.logPlay(record)
    }

    // MARK: - Ducking

    /// Lowers the music while you talk to VOID or VOID talks back, then brings it back.
    private func startDuckLoop() {
        duckTask?.cancel()
        duckTask = Task { [weak self] in
            var quietSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                if self.shouldDuck {
                    quietSince = nil
                    if !self.ducked { await self.duck(true) }
                } else if self.ducked {
                    let since = quietSince ?? Date()
                    quietSince = since
                    if Date().timeIntervalSince(since) > 0.8 {
                        await self.duck(false)
                        quietSince = nil
                    }
                }
            }
        }
    }

    private var shouldDuck: Bool {
        guard bridge.isConnected else { return false }
        switch state.phase {
        case .thinking, .speaking: return true
        case .listening: return userTalking || !state.handsFree
        default: return false
        }
    }

    private func duck(_ on: Bool) async {
        if on {
            guard player["playing"] as? Bool == true, let volume = Self.number(player["volume"]), volume > 0 else { return }
            ducked = true
            savedVolume = Int(volume)
            _ = try? await bridge.request("volume", ["level": max(3, Int(volume * 0.25))], timeout: 3)
        } else {
            ducked = false
            guard let saved = savedVolume else { return }
            savedVolume = nil
            _ = try? await bridge.request("volume", ["level": saved], timeout: 3)
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
