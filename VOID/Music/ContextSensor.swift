import AppKit
import AVFoundation
import CoreLocation
import SoundAnalysis

// MARK: - What VOID senses

enum Daypart: String {
    case morning, afternoon, evening, night, lateNight

    init(hour: Int) {
        switch hour {
        case 5..<11: self = .morning
        case 11..<17: self = .afternoon
        case 17..<21: self = .evening
        case 21..<24: self = .night
        default: self = .lateNight
        }
    }

    var spoken: String {
        switch self {
        case .morning: return "morning"
        case .afternoon: return "afternoon"
        case .evening: return "evening"
        case .night: return "night"
        case .lateNight: return "late night"
        }
    }
}

struct WeatherNow: Codable {
    var temperature: Double
    /// WMO weather code, as Open-Meteo reports it.
    var code: Int
    var isDay: Bool

    var isRainy: Bool { (51...67).contains(code) || (80...82).contains(code) || (95...99).contains(code) }
    var isStormy: Bool { (95...99).contains(code) }
    var isSnowy: Bool { (71...77).contains(code) || code == 85 || code == 86 }
    var isFoggy: Bool { code == 45 || code == 48 }
    var isClear: Bool { code <= 1 }
    var isCloudy: Bool { code == 2 || code == 3 }

    var summary: String {
        let sky: String
        if isStormy { sky = "storm" }
        else if isRainy { sky = "rain" }
        else if isSnowy { sky = "snow" }
        else if isFoggy { sky = "fog" }
        else if isClear { sky = isDay ? "sunny" : "clear night" }
        else { sky = "cloudy" }
        return "\(sky) \(Int(temperature.rounded()))°"
    }
}

/// A two-second listen to the room, taken only at the moment VOID picks music.
/// Only labels and loudness are kept; the audio itself is never stored.
struct RoomReading {
    var loudnessDB: Double
    var labels: [String: Double]

    private func score(_ names: [String]) -> Double {
        labels.filter { label, _ in names.contains { label.contains($0) } }.values.max() ?? 0
    }
    var talking: Bool { score(["speech", "conversation", "crowd", "chatter", "laughter", "babble"]) > 0.35 }
    var rain: Bool { score(["rain"]) > 0.3 }
    var typing: Bool { score(["typing", "keyboard"]) > 0.3 }
    var traffic: Bool { score(["vehicle", "traffic", "car", "engine", "horn", "motorcycle"]) > 0.35 }
    var silent: Bool { loudnessDB < -55 }
    var loud: Bool { loudnessDB > -28 }

    var summary: String {
        var parts: [String] = []
        if talking { parts.append("people talking") }
        if rain { parts.append("rain") }
        if typing { parts.append("typing") }
        if traffic { parts.append("traffic") }
        if parts.isEmpty { parts.append(silent ? "silent" : loud ? "loud" : "quiet") }
        return parts.joined(separator: ", ")
    }
}

/// How the person is feeling, from what they said recently ("I'm so tired").
struct MoodNote {
    var mood: String
    var at: Date
    /// What the person wants from music right now: "match" (stay with it) or "lift", once asked.
    var goal: String? = nil
}

enum AppKind: String {
    case coding, creative, writing, chatting, meeting, browsing, video, gaming, other
}

struct MusicContext {
    var date: Date
    var hour: Int
    var weekday: Int
    var daypart: Daypart
    var weekend: Bool
    var weather: WeatherNow?
    var frontApp: String?
    var appKind: AppKind
    var minutesInApp: Int
    var idleMinutes: Double
    var switchesPerMinute: Double
    var room: RoomReading?
    var mood: MoodNote?
    /// How lively the voice has sounded lately against your own usual, about -2 (flat) to 2.
    var voiceArousal: Double?

    /// The compact version kept with every play and like, for learning later.
    var listen: ListenContext {
        ListenContext(hour: hour, weekday: weekday, frontApp: frontApp, weather: weather?.summary,
                      ambient: room?.summary, mood: mood?.mood)
    }

    /// One line for the menu, so you can see what VOID saw.
    var summary: String {
        var parts = [daypart.spoken]
        if let weather { parts.append(weather.summary) }
        if let frontApp { parts.append("\(frontApp) \(minutesInApp) min") }
        if idleMinutes >= 5 { parts.append("idle \(Int(idleMinutes)) min") }
        if let room { parts.append("room: \(room.summary)") }
        if let mood { parts.append("mood: \(mood.mood)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The sensor

/// Gathers the moment around a music pick: time, weather, what you're doing on the Mac,
/// how the room sounds, and how you said you feel. Everything stays on this Mac except
/// the weather lookup, which sends Open-Meteo a rounded location.
@MainActor
final class ContextSensor {
    private var frontApp: String?
    private var frontBundle: String?
    private var frontSince = Date()
    private var switches: [Date] = []
    private var mood: MoodNote?
    private var observer: NSObjectProtocol?
    private var fetcher: LocationFetcher?

    init() {
        let app = NSWorkspace.shared.frontmostApplication
        frontApp = app?.localizedName
        frontBundle = app?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(app) }
        }
    }

    private func activated(_ app: NSRunningApplication?) {
        // VOID's own panel coming forward isn't you switching tasks.
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        guard app.bundleIdentifier != frontBundle else { return }
        frontApp = app.localizedName
        frontBundle = app.bundleIdentifier
        frontSince = Date()
        switches.append(Date())
        let cutoff = Date().addingTimeInterval(-600)
        switches.removeAll { $0 < cutoff }
    }

    // MARK: Mood from what you say

    private static let moodWords: [(mood: String, words: [String])] = [
        ("tired", ["tired", "exhausted", "sleepy", "drained", "worn out", "so done", "no energy", "burnt out", "burned out"]),
        ("stressed", ["stressed", "anxious", "tense", "overwhelmed", "pressure", "panicking", "nervous", "deadline"]),
        ("sad", ["sad", "down", "low", "upset", "lonely", "heartbroken", "miss her", "miss him", "crying", "depressed", "not okay", "not ok"]),
        ("angry", ["angry", "frustrated", "annoyed", "pissed", "irritated", "mad at"]),
        ("bored", ["bored", "boring", "nothing to do"]),
        ("happy", ["happy", "great day", "feeling good", "feel good", "excited", "awesome", "amazing", "pumped", "hyped", "let's go", "lets go", "in a good mood"]),
        ("focused", ["need to focus", "need focus", "have to study", "deep work", "need to concentrate", "lock in"]),
    ]

    /// Looks for how you're feeling in anything you say to VOID. Kept for three hours.
    func noteMood(from text: String) {
        let lower = " " + text.lowercased() + " "
        for entry in Self.moodWords {
            if entry.words.contains(where: { lower.contains(" \($0) ") || lower.contains(" \($0),") || lower.contains(" \($0).") }) {
                mood = MoodNote(mood: entry.mood, at: Date())
                return
            }
        }
    }

    private var currentMood: MoodNote? {
        guard let mood, Date().timeIntervalSince(mood.at) < 3 * 3600 else { return nil }
        return mood
    }

    var recentMood: MoodNote? { currentMood }

    /// Remembers whether you want music that stays with the mood or lifts it.
    func setGoal(_ goal: String) {
        if var note = mood {
            note.goal = goal
            mood = note
        }
    }

    // MARK: Voice energy, against your own usual

    private var voiceScores: [(at: Date, score: Double)] = []

    /// Notes how fast and how loud you spoke, compared with your own running average.
    /// Only a weak hint about energy, never about whether you feel good or bad.
    func noteVoice(words: Int, seconds: Double, rms: Double) {
        guard words >= 3, seconds >= 1, rms > 1e-5 else { return }
        let rate = Double(words) / seconds
        let level = 20 * log10(rms)
        let defaults = UserDefaults.standard
        var baseRate = defaults.double(forKey: "voiceBaseRate")
        var baseLevel = defaults.double(forKey: "voiceBaseLevel")
        let count = defaults.integer(forKey: "voiceBaseCount")
        if count == 0 { baseRate = rate; baseLevel = level }
        if count >= 15 {
            let score = 0.5 * log(rate / baseRate) / 0.25 + 0.5 * (level - baseLevel) / 4
            voiceScores.append((Date(), max(-2, min(2, score))))
            if voiceScores.count > 8 { voiceScores.removeFirst(voiceScores.count - 8) }
        }
        // The baseline learns quickly at first, then follows you slowly.
        let alpha = count < 15 ? 1.0 / Double(count + 1) : 0.03
        baseRate += (rate - baseRate) * alpha
        baseLevel += (level - baseLevel) * alpha
        defaults.set(baseRate, forKey: "voiceBaseRate")
        defaults.set(baseLevel, forKey: "voiceBaseLevel")
        defaults.set(count + 1, forKey: "voiceBaseCount")
    }

    private var voiceArousal: Double? {
        let recent = voiceScores.filter { Date().timeIntervalSince($0.at) < 900 }.suffix(5)
        guard recent.count >= 3 else { return nil }
        return recent.map(\.score).reduce(0, +) / Double(recent.count)
    }

    // MARK: Snapshot

    /// Everything at once. Weather and the room listen run side by side (about 2 s).
    func snapshot(listenToRoom: Bool) async -> MusicContext {
        async let weatherReading = currentWeather()
        async let roomReading: RoomReading? = listenToRoom ? RoomListener().listen(seconds: 2) : nil
        let weather = await weatherReading
        let room = await roomReading

        let now = Date()
        let parts = Calendar.current.dateComponents([.hour, .weekday], from: now)
        let hour = parts.hour ?? 12
        let weekday = parts.weekday ?? 2
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let recentSwitches = switches.filter { now.timeIntervalSince($0) < 600 }.count
        return MusicContext(
            date: now, hour: hour, weekday: weekday, daypart: Daypart(hour: hour),
            weekend: weekday == 1 || weekday == 7,
            weather: weather, frontApp: frontApp, appKind: Self.kind(of: frontApp, bundle: frontBundle),
            minutesInApp: Int(now.timeIntervalSince(frontSince) / 60),
            idleMinutes: idle / 60, switchesPerMinute: Double(recentSwitches) / 10,
            room: room, mood: currentMood, voiceArousal: voiceArousal)
    }

    private static func kind(of name: String?, bundle: String?) -> AppKind {
        let text = ((name ?? "") + " " + (bundle ?? "")).lowercased()
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }
        if has(["xcode", "visual studio", "vscode", "com.microsoft.vscode", "cursor", "terminal", "iterm", "warp",
                "pycharm", "intellij", "android studio", "sublime", "zed", "ghostty", "nova", "webstorm", "datagrip",
                "postman", "docker"]) { return .coding }
        if has(["zoom", "teams", "facetime", "webex", "meet"]) { return .meeting }
        if has(["figma", "photoshop", "illustrator", "blender", "sketch", "davinci", "final cut", "logic pro",
                "garageband", "canva", "affinity", "premiere", "after effects", "lightroom"]) { return .creative }
        if has(["pages", "microsoft word", "notion", "obsidian", "bear", "craft", "ulysses", "keynote", "excel",
                "numbers", "powerpoint"]) { return .writing }
        if has(["slack", "messages", "whatsapp", "telegram", "discord", "mail", "outlook", "signal"]) { return .chatting }
        if has(["vlc", "iina", "quicktime", "netflix", "tv", "prime video", "infuse"]) { return .video }
        if has(["steam", "epic games", "minecraft", "league", "valorant", "game"]) { return .gaming }
        if has(["chrome", "safari", "arc", "firefox", "brave", "edge", "orion"]) { return .browsing }
        return .other
    }

    // MARK: Weather (macOS location, kept for a day)

    private struct Place: Codable { var lat: Double; var lon: Double; var fetched: Date }
    private struct CachedWeather: Codable { var weather: WeatherNow; var fetched: Date }

    private func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Weather is looked up again after two hours; the location itself is kept a day.
    private func currentWeather() async -> WeatherNow? {
        let cached = load(CachedWeather.self, "musicWeather")
        if let cached, Date().timeIntervalSince(cached.fetched) < 2 * 3600 { return cached.weather }
        guard let place = await location() else { return cached?.weather }
        // Two decimals (about 1 km) is plenty for weather.
        let lat = String(format: "%.2f", place.lat)
        let lon = String(format: "%.2f", place.lon)
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,weather_code,is_day") else {
            return cached?.weather
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let temperature = (current["temperature_2m"] as? NSNumber)?.doubleValue,
                  let code = (current["weather_code"] as? NSNumber)?.intValue else { return cached?.weather }
            let isDay = (current["is_day"] as? NSNumber)?.intValue ?? 1
            let weather = WeatherNow(temperature: temperature, code: code, isDay: isDay == 1)
            save(CachedWeather(weather: weather, fetched: Date()), "musicWeather")
            return weather
        } catch {
            return cached?.weather
        }
    }

    private func location() async -> Place? {
        let saved = load(Place.self, "musicPlace")
        if let saved, Date().timeIntervalSince(saved.fetched) < 24 * 3600 { return saved }
        let fetcher = LocationFetcher()
        self.fetcher = fetcher
        let found = await fetcher.request(timeout: 10)
        self.fetcher = nil
        guard let found else { return saved }          // an old place beats no weather
        let place = Place(lat: found.coordinate.latitude, lon: found.coordinate.longitude, fetched: Date())
        save(place, "musicPlace")
        return place
    }
}

// MARK: - Location

/// Asks macOS once for a rough location. Gives up after `timeout` seconds.
final class LocationFetcher: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    func request(timeout: Double) async -> CLLocation? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = continuation
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyKilometer
            switch manager.authorizationStatus {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .denied, .restricted:
                finish(nil)
            default:
                manager.requestLocation()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(nil) }
        }
    }

    private func finish(_ location: CLLocation?) {
        continuation?.resume(returning: location)
        continuation = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            if continuation != nil { manager.requestLocation() }
        case .denied, .restricted:
            finish(nil)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
}

// MARK: - Room listening

/// Listens through the mic for a moment and names what it hears, using Apple's built-in,
/// on-device sound classifier.
final class RoomListener: NSObject, SNResultsObserving, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "void.room")
    private let lock = NSLock()
    private var labels: [String: Double] = [:]
    private var powerSum = 0.0
    private var powerCount = 0

    func listen(seconds: Double) async -> RoomReading? {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return nil }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        let analyzer = SNAudioStreamAnalyzer(format: format)
        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            try analyzer.add(request, withObserver: self)
        } catch {
            return nil
        }
        input.installTap(onBus: 0, bufferSize: 8192, format: format) { [weak self] buffer, time in
            guard let self else { return }
            self.measure(buffer)
            self.queue.async { analyzer.analyze(buffer, atAudioFramePosition: time.sampleTime) }
        }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return nil
        }
        try? await Task.sleep(for: .seconds(seconds))
        input.removeTap(onBus: 0)
        engine.stop()
        queue.sync { analyzer.completeAnalysis() }

        lock.lock()
        defer { lock.unlock() }
        guard powerCount > 0 else { return nil }
        let rms = (powerSum / Double(powerCount)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return RoomReading(loudnessDB: db, labels: labels)
    }

    private func measure(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        var sum = 0.0
        for i in 0..<count { sum += Double(data[i] * data[i]) }
        lock.lock()
        powerSum += sum / Double(count)
        powerCount += 1
        lock.unlock()
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        lock.lock()
        for item in result.classifications.prefix(8) where item.confidence > 0.15 {
            labels[item.identifier] = max(labels[item.identifier] ?? 0, item.confidence)
        }
        lock.unlock()
    }
}
