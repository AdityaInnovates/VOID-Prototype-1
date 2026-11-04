import AppKit
import Foundation
import IOKit
import IOKit.pwr_mgt
import Observation

/// Keeps the Mac running with the lid shut. macOS sleeps on lid close no matter what an app
/// asks for, so this flips the system's "disablesleep" setting (needs your password, once per
/// change), and also holds a no-idle-sleep assertion. Turn it off to let the Mac sleep again.
@MainActor
@Observable
final class KeepAwake {
    static let shared = KeepAwake()

    private(set) var enabled: Bool
    private(set) var note = ""
    private var assertion: IOPMAssertionID = 0
    private var watcher: Task<Void, Never>?
    private var paused: [pid_t] = []

    /// While the lid is shut, freeze every other app so VOID gets the Mac to itself.
    var pauseOthers: Bool {
        get { UserDefaults.standard.bool(forKey: "pauseOthersLidClosed") }
        set { UserDefaults.standard.set(newValue, forKey: "pauseOthersLidClosed"); access() }
    }
    private func access() { note = note + "" }   // nudges the menu to refresh

    /// Apps that must keep running: VOID itself, the desktop, and Chrome (it plays the music).
    private static let keepRunning: Set<String> = [
        "com.apple.finder", "com.google.Chrome", "com.apple.loginwindow", "com.apple.dock",
    ]

    private init() {
        enabled = Self.systemSleepDisabled()
        // If VOID died while other apps were frozen, wake them now.
        for pid in (UserDefaults.standard.array(forKey: "pausedPIDs") as? [Int32]) ?? [] { kill(pid, SIGCONT) }
        UserDefaults.standard.removeObject(forKey: "pausedPIDs")
        if enabled { holdAssertion(); startWatching() }
    }

    private func startWatching() {
        watcher?.cancel()
        watcher = Task { [weak self] in
            var wasClosed = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                let closed = Self.lidClosed()
                if closed != wasClosed {
                    wasClosed = closed
                    if closed && self.pauseOthers { self.pauseOtherApps() } else { self.resumeAll() }
                }
            }
        }
    }

    private static func lidClosed() -> Bool {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IOPMrootDomain")
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }

    private func pauseOtherApps() {
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard pid != me, !(Self.keepRunning.contains(app.bundleIdentifier ?? "")) else { continue }
            if kill(pid, SIGSTOP) == 0 { paused.append(pid) }
        }
        UserDefaults.standard.set(paused.map { Int32($0) }, forKey: "pausedPIDs")
    }

    /// Wakes everything that was frozen. Called when the lid opens, when this is turned off, and on quit.
    func resumeAll() {
        for pid in paused { kill(pid, SIGCONT) }
        paused.removeAll()
        UserDefaults.standard.removeObject(forKey: "pausedPIDs")
    }

    func set(_ on: Bool) {
        guard on != enabled else { return }
        note = ""
        Task {
            let ok = await Self.runAsAdmin("/usr/bin/pmset -a disablesleep \(on ? 1 : 0)")
            let actual = Self.systemSleepDisabled()
            enabled = actual
            if actual { holdAssertion(); startWatching() } else { releaseAssertion(); watcher?.cancel(); resumeAll() }
            if !ok || actual != on { note = "Couldn't change it (the password prompt was cancelled or refused)." }
        }
    }

    private func holdAssertion() {
        guard assertion == 0 else { return }
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "VOID keeps running" as CFString, &assertion)
    }

    private func releaseAssertion() {
        guard assertion != 0 else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
    }

    private static func systemSleepDisabled() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").contains { $0.contains("SleepDisabled") && $0.trimmingCharacters(in: .whitespaces).hasSuffix("1") }
    }

    private static func runAsAdmin(_ command: String) async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"\(command)\" with administrator privileges"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }
}
