import AppKit
import Foundation
import IOKit.ps

/// What your phone can do on this Mac. Each tool takes JSON arguments and returns JSON.
@MainActor
enum MacTools {
    enum ToolError: LocalizedError {
        case unknown(String)
        case bad(String)

        var errorDescription: String? {
            switch self {
            case .unknown(let tool): return "VOID on the Mac doesn't know “\(tool)”."
            case .bad(let message): return message
            }
        }
    }

    /// Everything the phone app may call, for its tool list.
    static let names = [
        "ask", "mac.status", "mac.open", "mac.apps", "mac.clipboard.get", "mac.clipboard.set",
        "mac.notify", "mac.say", "mac.lock", "mac.sleep", "mac.volume", "mac.media", "mac.shortcut",
        "mac.screenshot", "mac.file.push",
    ]

    static func run(_ tool: String, _ args: [String: Any]) async throws -> [String: Any] {
        switch tool {
        case "mac.status":
            return status()

        case "mac.open":
            if let url = args["url"] as? String, let parsed = URL(string: url), parsed.scheme != nil {
                NSWorkspace.shared.open(parsed)
                return ["opened": url]
            }
            guard let name = args["app"] as? String, !name.isEmpty else { throw ToolError.bad("Say which app or link to open.") }
            let result = try await shell("/usr/bin/open", ["-a", name])
            guard result.status == 0 else { throw ToolError.bad("I couldn't find an app called \(name) on the Mac.") }
            return ["opened": name]

        case "mac.apps":
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap(\.localizedName)
            return ["apps": apps, "front": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""]

        case "mac.clipboard.get":
            return ["text": NSPasteboard.general.string(forType: .string) ?? ""]

        case "mac.clipboard.set":
            let text = args["text"] as? String ?? ""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return ["chars": text.count]

        case "mac.notify":
            PhoneNotifier.post(title: args["title"] as? String ?? "From your phone", body: args["body"] as? String ?? "")
            return [:]

        case "mac.say":
            let text = String((args["text"] as? String ?? "").prefix(500))
            _ = try await shell("/usr/bin/say", [text])
            return [:]

        case "mac.lock":
            // Puts the display to sleep; with "require password immediately" on, that locks the Mac.
            _ = try await shell("/usr/bin/pmset", ["displaysleepnow"])
            return [:]

        case "mac.sleep":
            _ = try await shell("/usr/bin/pmset", ["sleepnow"])
            return [:]

        case "mac.volume":
            if let level = (args["level"] as? NSNumber)?.intValue {
                let clamped = max(0, min(100, level))
                _ = try await shell("/usr/bin/osascript", ["-e", "set volume output volume \(clamped)"])
                return ["level": clamped]
            }
            let result = try await shell("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"])
            return ["level": Int(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1]

        case "mac.media":
            // Media keys reach whatever is playing (YouTube Music, Spotify, a video).
            let key: Int32
            switch args["action"] as? String ?? "toggle" {
            case "next": key = 17           // NX_KEYTYPE_NEXT
            case "previous": key = 18       // NX_KEYTYPE_PREVIOUS
            default: key = 16               // NX_KEYTYPE_PLAY
            }
            pressMediaKey(key)
            return [:]

        case "mac.shortcut":
            guard let name = args["name"] as? String, !name.isEmpty else { throw ToolError.bad("Which shortcut?") }
            var arguments = ["run", name]
            if let input = args["input"] as? String {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("void-shortcut-input.txt")
                try input.write(to: file, atomically: true, encoding: .utf8)
                arguments += ["--input-path", file.path]
            }
            let result = try await shell("/usr/bin/shortcuts", arguments)
            guard result.status == 0 else { throw ToolError.bad("The shortcut “\(name)” failed: \(result.output.prefix(200))") }
            return ["output": String(result.output.prefix(4000))]

        case "mac.screenshot":
            // Needs Screen Recording permission for VOID (System Settings → Privacy & Security).
            let folder = FileManager.default.temporaryDirectory
            let raw = folder.appendingPathComponent("void-shot.png")
            let small = folder.appendingPathComponent("void-shot.jpg")
            try? FileManager.default.removeItem(at: raw)
            try? FileManager.default.removeItem(at: small)
            _ = try await shell("/usr/sbin/screencapture", ["-x", "-t", "png", raw.path])
            guard FileManager.default.fileExists(atPath: raw.path) else {
                throw ToolError.bad("macOS blocked the screenshot. Give VOID Screen Recording permission in System Settings.")
            }
            _ = try await shell("/usr/bin/sips", ["-s", "format", "jpeg", "-s", "formatOptions", "70", "-Z", "1600", raw.path, "--out", small.path])
            let data = try Data(contentsOf: small)
            return ["jpeg": data.base64EncodedString()]

        case "mac.file.push":
            guard let encoded = args["data"] as? String, let data = Data(base64Encoded: encoded) else {
                throw ToolError.bad("No file came through.")
            }
            let name = sanitize(args["name"] as? String ?? "From phone")
            let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("From Phone", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var target = folder.appendingPathComponent(name)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) {
                let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            try data.write(to: target)
            PhoneNotifier.post(title: "From your phone", body: "Saved \(target.lastPathComponent) to Downloads › From Phone")
            return ["saved": target.path]

        default:
            throw ToolError.unknown(tool)
        }
    }

    // MARK: - Helpers

    static func status() -> [String: Any] {
        var info: [String: Any] = [
            "name": Host.current().localizedName ?? "Mac",
            "front": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
            "uptimeHours": Int(ProcessInfo.processInfo.systemUptime / 3600),
        ]
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
                else { continue }
                if let current = description[kIOPSCurrentCapacityKey] as? Int,
                   let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    info["battery"] = current * 100 / max
                }
                info["charging"] = description[kIOPSIsChargingKey] as? Bool ?? false
                info["onPower"] = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            }
        }
        return info
    }

    private static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = cleaned.hasPrefix(".") ? "file" + cleaned : cleaned
        return trimmed.isEmpty ? "From phone" : String(trimmed.prefix(120))
    }

    private static func pressMediaKey(_ key: Int32) {
        func post(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((down ? 0xa : 0xb) << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }

    struct ShellResult: Sendable {
        let status: Int32
        let output: String
    }

    /// Runs a program off the main thread and returns its exit status and output.
    static func shell(_ path: String, _ arguments: [String], timeout: Double = 30) async throws -> ShellResult {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            // Stop it if it hangs; reading to the end returns once it exits.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ShellResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        }.value
    }
}
