import Foundation
import Observation

/// What the orb is doing right now. Every motion on screen maps to one of these.
enum OrbPhase: Equatable {
    case loading
    case idle
    case listening
    case thinking
    case speaking

    var menuSymbol: String {
        switch self {
        case .loading: return "circle.dotted"
        case .idle: return "circle.fill"
        case .listening: return "circle.inset.filled"
        case .thinking: return "circle.circle"
        case .speaking: return "waveform.circle.fill"
        }
    }
}

/// Which voice VOID speaks with.
enum VoiceEngine: String, Hashable, Sendable {
    /// Chatterbox Nano: more human, can laugh and sigh. A little slower to start.
    case expressive
    /// Kokoro-82M: very fast and clean, less emotional.
    case fast

    var label: String {
        switch self {
        case .expressive: return "Chatterbox voice"
        case .fast: return "Kokoro voice"
        }
    }

    static var saved: VoiceEngine {
        VoiceEngine(rawValue: UserDefaults.standard.string(forKey: "voiceEngine") ?? "") ?? .expressive
    }
}

enum BrainMode: String, Hashable {
    case normal
    case focus
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, void }
    enum Source: Equatable { case user, reflex, deep, system }

    let id: UUID
    let role: Role
    var text: String
    var source: Source
    var metrics: String?

    init(role: Role, text: String, source: Source, metrics: String? = nil) {
        self.id = UUID()
        self.role = role
        self.text = text
        self.source = source
        self.metrics = metrics
    }
}

/// Shared, observable UI state. Written only on the main actor.
@Observable
@MainActor
final class AppState {
    var phase: OrbPhase = .loading
    var loadProgress: Double = 0
    var statusLine: String = "Waking up…"

    /// Live caption under the orb.
    var caption: String = ""
    var captionVisible: Bool = false

    /// Speech recognition (Parakeet) and the voice (Kokoro) finished loading.
    var earsReady: Bool = false
    var earsError: String?
    var voiceReady: Bool = false
    /// Speak replies out loud. Turn off for silent, text-only chatting.
    var speakReplies: Bool = true
    /// The voice the user picked, and the one that actually loaded (nil = macOS system voice).
    var voiceEngine: VoiceEngine = VoiceEngine.saved
    var activeVoice: VoiceEngine?
    /// 0 = not thinking, 1 = reflex reacting, 2 = deep brain working. Drives the inner rings.
    var thinkingDepth: Int = 0
    /// Hands-free conversation: always listening, interrupt any time.
    var handsFree: Bool = false
    var echoCancelling: Bool = false

    var orbVisible: Bool = false
    var mode: BrainMode = .normal
    var lowMemory: Bool = false

    var messages: [ChatMessage] = []
}
