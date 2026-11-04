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

/// Which small model plays the instant reflex.
enum ReflexChoice: String, Hashable, Sendable {
    case qwen
    case lfm

    var label: String {
        switch self {
        case .qwen: return "0.8B"
        case .lfm: return "LFM2 1.2B"
        }
    }

    static var saved: ReflexChoice {
        ReflexChoice(rawValue: UserDefaults.standard.string(forKey: "reflexModel") ?? "") ?? .qwen
    }
}

/// How fast VOID talks.
enum SpeakingPace: String, Hashable, Sendable, CaseIterable {
    case brisk, natural, relaxed, slow

    var rate: Float {
        switch self {
        case .brisk: return 1.0
        case .natural: return 0.93
        case .relaxed: return 0.86
        case .slow: return 0.78
        }
    }

    var label: String {
        switch self {
        case .brisk: return "Brisk"
        case .natural: return "Natural"
        case .relaxed: return "Relaxed (a little slower)"
        case .slow: return "Slow and thoughtful"
        }
    }

    static var saved: SpeakingPace {
        SpeakingPace(rawValue: UserDefaults.standard.string(forKey: "speakingPace") ?? "") ?? .natural
    }
}

enum BrainMode: String, Hashable {
    /// Qwen3.5 2B.
    case normal
    /// Qwen3.5 4B: best chat quality in the research, needs ~3 GB free.
    case focus
    /// Qwen3.5 4B with OptiQ mixed-precision weights: about 8% bigger, meant to be a bit smarter.
    case focusOptiQ
    /// Liquid LFM2.5 8B-A1B, mixture-of-experts at 4-bit: about 4.8 GB, 1.5B active per word.
    case moe
    /// The same MoE at 3-bit: about 3.6 GB.
    case moeLite
    /// EXPERIMENT: the 4-bit MoE with its experts left on the SSD and loaded on demand (needs ~2 GB of memory).
    case moeStream
    /// Liquid LFM2 1.2B: tiny and quick, built for short chat.
    case lfmSmall
    /// Liquid LFM2 2.6B: the bigger LFM, about 1.5 GB.
    case lfmBig

    var short: String {
        switch self {
        case .normal: return "Qwen 2B"
        case .focus: return "Qwen 4B"
        case .focusOptiQ: return "Qwen 4B OptiQ"
        case .moe: return "LFM2.5 MoE 8B"
        case .moeLite: return "LFM2 MoE 8B (3-bit)"
        case .moeStream: return "LFM2.5 MoE 8B (streamed)"
        case .lfmSmall: return "LFM2 1.2B"
        case .lfmBig: return "LFM2 2.6B"
        }
    }

    static var saved: BrainMode {
        BrainMode(rawValue: UserDefaults.standard.string(forKey: "deepBrain") ?? "") ?? .normal
    }
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
    /// True while the deep brain is working on the real answer, until its first words are
    /// spoken. The orb shows "thinking" behind the opener's voice, then resolves.
    var deepWorking: Bool = false
    /// Increments each time the deep brain's answer begins; the orb answers with a burst.
    var handoff: Int = 0
    /// Hands-free conversation: always listening, interrupt any time.
    var handsFree: Bool = false
    var echoCancelling: Bool = false

    /// The full VOID panel is open (otherwise VOID is folded into the notch).
    var orbVisible: Bool = false
    /// The Mac is on the lock screen.
    var screenLocked: Bool = false
    var mode: BrainMode = BrainMode.saved
    var reflexChoice: ReflexChoice = ReflexChoice.saved
    var pace: SpeakingPace = SpeakingPace.saved
    var lowMemory: Bool = false

    /// The VOID Music Chrome extension is connected.
    var musicConnected: Bool = false
    var musicStatus: String = "Music: off"
    /// "Song by Artist" while YouTube Music is playing.
    var nowPlaying: String?
    /// What VOID sensed and chose the last time it picked music for you.
    var musicContextNote: String = ""

    /// Phone link.
    var phoneConnected: Bool = false
    var phoneStatus: String = "Phone: not paired"
    /// The pairing PIN while pairing is open.
    var phonePin: String?

    var messages: [ChatMessage] = []
}
