import Foundation

/// Knows whether the Mac is on the lock screen.
@MainActor
final class ScreenLock {
    static let shared = ScreenLock()
    private(set) var isLocked = false
    var onChange: ((Bool) -> Void)?

    private init() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(true) }
        }
        center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(false) }
        }
    }

    private func set(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        onChange?(locked)
    }

    /// Only these tools run while locked: nothing that reads private things or acts for you.
    static let lockedAllowed = ["phone.ring", "phone.torch", "phone.vibrate", "phone.status", "phone.ringer",
                                "phone.dnd", "mac.volume"]
}
