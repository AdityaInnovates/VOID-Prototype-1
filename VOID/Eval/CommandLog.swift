import Foundation

/// A private, local record of what you said and which path VOID used for it
/// (~/Library/Application Support/VOID/commands.jsonl). It is only ever read by you: the router
/// eval turns it into test cases. Switch it off with: defaults write com.adityainnovates.void commandLog -bool NO
enum CommandLog {
    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: "commandLog") as? Bool ?? true
    }

    static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VOID", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("commands.jsonl")
    }

    static func record(text: String, route: String) {
        guard enabled else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let row: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "text": String(clean.prefix(400)),
            "route": route,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let target = url
        if let handle = try? FileHandle(forWritingTo: target) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: target, atomically: true, encoding: .utf8)
        }
    }
}
