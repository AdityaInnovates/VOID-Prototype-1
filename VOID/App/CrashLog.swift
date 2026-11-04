import Foundation

/// Writes what went wrong to crash.log beside the project (found by walking up from the app
/// until project.yml), so a crash can be read without digging through Console.
enum CrashLog {
    static let path: String = {
        var url = Bundle.main.bundleURL
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.yml").path) {
                return url.appendingPathComponent("crash.log").path
            }
        }
        return NSTemporaryDirectory() + "void-crash.log"
    }()

    static func write(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\n=== \(stamp) ===\n\(text)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            CrashLog.write("Exception \(exception.name.rawValue): \(exception.reason ?? "")\n"
                           + exception.callStackSymbols.joined(separator: "\n"))
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
            signal(sig) { number in
                CrashLog.write("Signal \(number)\n" + Thread.callStackSymbols.joined(separator: "\n"))
                signal(number, SIG_DFL)
                raise(number)
            }
        }
    }
}
