import Foundation
import Observation

/// Settings shared with the phone (quiet hours for now). Each field keeps the time it was
/// last changed; when the Mac and phone meet, the newer change wins field by field. Works
/// fully offline on both sides.
@MainActor
@Observable
final class PhoneSettings {
    static let shared = PhoneSettings()

    enum Key: String, CaseIterable {
        case quietEnabled, quietStart, quietEnd, quietUntil
    }

    private struct Field: Codable { var v: Double; var t: Double }

    private var fields: [String: Field]
    /// Called after a change made here, so the link can push it to the phone.
    @ObservationIgnored var onLocalChange: (() -> Void)?

    private static let storeKey = "phoneSettings.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storeKey),
           let saved = try? JSONDecoder().decode([String: Field].self, from: data) {
            fields = saved
        } else {
            fields = [:]
        }
    }

    private static func defaultValue(_ key: Key) -> Double {
        switch key {
        case .quietEnabled: 1
        case .quietStart: 8 * 60
        case .quietEnd: 18 * 60
        case .quietUntil: 0
        }
    }

    func value(_ key: Key) -> Double { fields[key.rawValue]?.v ?? Self.defaultValue(key) }

    private func save() {
        if let data = try? JSONEncoder().encode(fields) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    func set(_ key: Key, _ value: Double) {
        fields[key.rawValue] = Field(v: value, t: Date().timeIntervalSince1970 * 1000)
        save()
        onLocalChange?()
    }

    // MARK: Quiet hours

    var quietEnabled: Bool {
        get { value(.quietEnabled) > 0 }
        set { set(.quietEnabled, newValue ? 1 : 0) }
    }
    var quietStart: Int {
        get { Int(value(.quietStart)) }
        set { set(.quietStart, Double(newValue)) }
    }
    var quietEnd: Int {
        get { Int(value(.quietEnd)) }
        set { set(.quietEnd, Double(newValue)) }
    }
    var quietUntil: Date? {
        let ms = value(.quietUntil)
        return ms > 0 ? Date(timeIntervalSince1970: ms / 1000) : nil
    }

    /// True if VOID should stay silent right now: a timer is running, or the schedule says so.
    var isQuietNow: Bool {
        if let until = quietUntil, until > Date() { return true }
        guard quietEnabled else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let start = quietStart, end = quietEnd
        if start == end { return false }
        return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
    }

    func quietFor(hours: Double) {
        set(.quietUntil, (Date().timeIntervalSince1970 + hours * 3600) * 1000)
    }

    func quietRestOfToday() {
        let end = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: Date()) ?? Date()
        set(.quietUntil, end.timeIntervalSince1970 * 1000)
    }

    func clearTimer() { set(.quietUntil, 0) }

    /// "8:00 AM" style label for a minutes-after-midnight value.
    static func clock(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return String(format: "%d:%02d %@", h % 12 == 0 ? 12 : h % 12, m, h < 12 ? "AM" : "PM")
    }

    // MARK: Sync

    func export() -> [String: Any] {
        var out: [String: Any] = [:]
        for key in Key.allCases {
            out[key.rawValue] = ["v": value(key), "t": fields[key.rawValue]?.t ?? 0] as [String: Any]
        }
        return out
    }

    /// Takes the other side's newer values. Returns true if anything here changed.
    @discardableResult
    func merge(_ other: [String: Any]) -> Bool {
        var changed = false
        for key in Key.allCases {
            guard let f = other[key.rawValue] as? [String: Any],
                  let t = (f["t"] as? NSNumber)?.doubleValue,
                  let v = (f["v"] as? NSNumber)?.doubleValue else { continue }
            if t > (fields[key.rawValue]?.t ?? 0) {
                fields[key.rawValue] = Field(v: v, t: t)
                changed = true
            }
        }
        if changed { save() }
        return changed
    }

    /// Offers our settings to the phone and takes back whatever it has newer.
    func syncWithPhone() async {
        let link = PhoneController.shared.link
        guard link.isConnected else { return }
        if let back = try? await link.call("settings.sync", export(), timeout: 10) {
            merge(back)
        }
    }
}
