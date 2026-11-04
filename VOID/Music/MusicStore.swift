import AppKit
import Foundation

struct MusicTrack: Codable, Hashable {
    var videoId: String
    var title: String
    var artist: String

    init(videoId: String, title: String, artist: String) {
        self.videoId = videoId
        self.title = title
        self.artist = artist
    }

    init?(json: [String: Any]) {
        guard let id = json["videoId"] as? String, !id.isEmpty else { return nil }
        self.init(videoId: id, title: json["title"] as? String ?? "", artist: json["artist"] as? String ?? "")
    }

    var spoken: String { artist.isEmpty ? title : "\(title) by \(artist)" }
}

struct MusicPlaylist: Codable, Identifiable {
    var id: String
    var title: String
    /// "Playlist • Aditya • 54 tracks": when this changes, the tracks are read again.
    var subtitle: String
    var tracks: [MusicTrack]
    var updated: Date
}

/// The moment around a play or a like. Later phases fill weather, room sound and mood;
/// the recommender learns from these.
struct ListenContext: Codable {
    var hour: Int
    var weekday: Int
    var frontApp: String?
    var weather: String?
    var ambient: String?
    var mood: String?

    @MainActor
    static func now() -> ListenContext {
        let parts = Calendar.current.dateComponents([.hour, .weekday], from: Date())
        return ListenContext(
            hour: parts.hour ?? 0,
            weekday: parts.weekday ?? 1,
            frontApp: NSWorkspace.shared.frontmostApplication?.localizedName)
    }
}

/// VOID's own record of a song you like, kept even if YouTube's list changes.
struct LikedSong: Codable {
    var track: MusicTrack
    var likedAt: Date
    /// "voice" (you told VOID), "youtube" (you liked it in YouTube Music), "import" (it was
    /// already in your Liked Music when VOID first read it).
    var source: String
    var context: ListenContext?
    var plays: Int
    var skips: Int
    var lastPlayed: Date?
}

struct PlayRecord: Codable {
    var track: MusicTrack
    var started: Date
    var listened: Double
    var duration: Double
    var skipped: Bool
    /// How it started: "playlist", "request", "random", "suggest", or "continued" (autoplay).
    var source: String
    var playlistId: String?
    var disliked: Bool?
    var context: ListenContext
    /// You liked the song while it played.
    var liked: Bool?
}

/// Everything VOID remembers about your music, in ~/Library/Application Support/VOID/music.
@MainActor
final class MusicStore {
    private(set) var playlists: [MusicPlaylist] = []
    private(set) var liked: [LikedSong] = []
    private(set) var plays: [PlayRecord] = []
    private var playlistPlayed: [String: Date] = [:]
    private(set) var synced: Date?
    /// Songs from YouTube Music's "Listen again" page: what you keep replaying.
    private(set) var listenAgain: [MusicTrack] = []

    private struct LibraryFile: Codable {
        var playlists: [MusicPlaylist]
        var playlistPlayed: [String: Date]
        var synced: Date?
    }

    private let folder: URL
    private var libraryURL: URL { folder.appendingPathComponent("library.json") }
    private var likedURL: URL { folder.appendingPathComponent("liked.json") }
    private var listenAgainURL: URL { folder.appendingPathComponent("listen_again.json") }
    private var playsURL: URL { folder.appendingPathComponent("plays.jsonl") }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("VOID/music", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: libraryURL),
           let file = try? decoder.decode(LibraryFile.self, from: data) {
            playlists = file.playlists
            playlistPlayed = file.playlistPlayed
            synced = file.synced
        }
        if let data = try? Data(contentsOf: listenAgainURL),
           let songs = try? decoder.decode([MusicTrack].self, from: data) {
            listenAgain = songs
        }
        if let data = try? Data(contentsOf: likedURL),
           let songs = try? decoder.decode([LikedSong].self, from: data) {
            liked = songs
        }
        if let text = try? String(contentsOf: playsURL, encoding: .utf8) {
            plays = text.split(separator: "\n").suffix(1000).compactMap {
                try? decoder.decode(PlayRecord.self, from: Data($0.utf8))
            }
        }
    }

    // MARK: - Library

    func replaceLibrary(_ fresh: [MusicPlaylist]) {
        playlists = fresh
        synced = Date()
        if let likedMusic = fresh.first(where: { $0.id == "LM" }) { importLiked(likedMusic.tracks) }
        saveLibrary()
    }

    func replaceListenAgain(_ songs: [MusicTrack]) {
        listenAgain = songs
        if let data = try? encoder.encode(songs) { try? data.write(to: listenAgainURL, options: .atomic) }
    }

    var listenAgainIDs: Set<String> { Set(listenAgain.map(\.videoId)) }

    func notePlaylistPlayed(_ id: String) {
        playlistPlayed[id] = Date()
        saveLibrary()
    }

    func lastPlayed(playlist id: String) -> Date? { playlistPlayed[id] }

    private func saveLibrary() {
        let file = LibraryFile(playlists: playlists, playlistPlayed: playlistPlayed, synced: synced)
        if let data = try? encoder.encode(file) { try? data.write(to: libraryURL, options: .atomic) }
    }

    // MARK: - Likes

    func isLiked(_ videoId: String) -> Bool { liked.contains { $0.track.videoId == videoId } }

    func recordLike(_ track: MusicTrack, source: String, context: ListenContext?) {
        guard !isLiked(track.videoId) else { return }
        liked.append(LikedSong(track: track, likedAt: Date(), source: source, context: context,
                               plays: 0, skips: 0, lastPlayed: nil))
        saveLiked()
    }

    private func importLiked(_ tracks: [MusicTrack]) {
        var added = false
        for track in tracks where !isLiked(track.videoId) {
            liked.append(LikedSong(track: track, likedAt: Date(), source: "import", context: nil,
                                   plays: 0, skips: 0, lastPlayed: nil))
            added = true
        }
        if added { saveLiked() }
    }

    private func saveLiked() {
        if let data = try? encoder.encode(liked) { try? data.write(to: likedURL, options: .atomic) }
    }

    // MARK: - Plays

    func logPlay(_ record: PlayRecord) {
        plays.append(record)
        if plays.count > 1000 { plays.removeFirst(plays.count - 1000) }
        if let index = liked.firstIndex(where: { $0.track.videoId == record.track.videoId }) {
            if record.skipped { liked[index].skips += 1 } else { liked[index].plays += 1 }
            liked[index].lastPlayed = record.started
            saveLiked()
        }
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: playsURL) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: playsURL, options: .atomic)
        }
    }

    func recentlyPlayed(hours: Double) -> Set<String> {
        let since = Date().addingTimeInterval(-hours * 3600)
        return Set(plays.filter { $0.started > since }.map(\.track.videoId))
    }

    var disliked: Set<String> {
        Set(plays.filter { $0.disliked == true }.map(\.track.videoId))
    }
}
