import SwiftUI

/// VOID lives in the menu bar. The orb itself is an AppKit panel owned by AppDelegate,
/// so the only SwiftUI scene here is the menu bar item.
@main
struct VOIDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(appDelegate.state)
        } label: {
            MenuBarIcon()
                .environment(appDelegate.state)
        }
    }
}

/// The tiny circle in the menu bar mirrors the orb's state.
struct MenuBarIcon: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Image(systemName: state.phase.menuSymbol)
    }
}

struct MenuContent: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Text(state.statusLine)

        Divider()

        Button("Show or hide VOID   ⌥Space") {
            AppDelegate.shared?.toggleOrb()
        }
        Button("Transcript") {
            AppDelegate.shared?.showTranscript()
        }
        Button("New conversation") {
            AppDelegate.shared?.conversation.newConversation()
        }

        Toggle("Hands-free conversation   ⌥⇧Space", isOn: Binding(
            get: { state.handsFree },
            set: { _ in AppDelegate.shared?.toggleHandsFree() }
        ))

        Toggle("Speak replies", isOn: Binding(
            get: { state.speakReplies },
            set: { state.speakReplies = $0; if !$0 { AppDelegate.shared?.conversation.cancel() } }
        ))

        Picker("Voice", selection: Binding(
            get: { state.voiceEngine },
            set: { AppDelegate.shared?.conversation.setVoice($0) }
        )) {
            Text("Expressive · Chatterbox (laughs, sighs)").tag(VoiceEngine.expressive)
            Text("Fast · Kokoro").tag(VoiceEngine.fast)
        }

        Picker("Speaking pace", selection: Binding(
            get: { state.pace },
            set: { AppDelegate.shared?.conversation.setPace($0) }
        )) {
            ForEach(SpeakingPace.allCases, id: \.self) { Text($0.label).tag($0) }
        }

        Divider()

        Picker("Reflex brain", selection: Binding(
            get: { state.reflexChoice },
            set: { AppDelegate.shared?.conversation.setReflex($0) }
        )) {
            Text("Qwen3.5 0.8B (default)").tag(ReflexChoice.qwen)
            Text("LFM2 1.2B (chattier, try it)").tag(ReflexChoice.lfm)
        }

        Picker("Deep brain", selection: Binding(
            get: { state.mode },
            set: { AppDelegate.shared?.conversation.setMode($0) }
        )) {
            Text("Qwen3.5 2B (normal)").tag(BrainMode.normal)
            Text("Qwen3.5 4B (best quality, close heavy apps)").tag(BrainMode.focus)
            Text("Qwen3.5 4B OptiQ (test: mixed-precision, +0.2 GB)").tag(BrainMode.focusOptiQ)
            Divider()
            Text("MoE: LFM2.5 8B-A1B 4-bit (test, 4.8 GB, close heavy apps)").tag(BrainMode.moe)
            Text("MoE: LFM2 8B-A1B 3-bit (test, 3.6 GB)").tag(BrainMode.moeLite)
            Text("MoE streamed from SSD (experiment, ~2 GB; first run converts ~5 GB)").tag(BrainMode.moeStream)
            Text("LFM2 1.2B (tiny, quick, chatty)").tag(BrainMode.lfmSmall)
            Text("LFM2 2.6B (bigger LFM)").tag(BrainMode.lfmBig)
        }

        Divider()

        Text(state.phoneStatus)
        if let pin = state.phonePin {
            Text("Pair PIN: \(pin)")
        }
        Button("Pair a phone…") {
            AppDelegate.shared?.pairPhone()
        }
        Button("Forget paired phones") {
            PhoneController.shared.forgetPhones()
        }
        quietMenu
        Toggle("Keep running with the lid closed", isOn: Binding(
            get: { KeepAwake.shared.enabled }, set: { KeepAwake.shared.set($0) }))
        Toggle("…and pause other apps while the lid is closed", isOn: Binding(
            get: { KeepAwake.shared.pauseOthers }, set: { KeepAwake.shared.pauseOthers = $0 }))
        if !KeepAwake.shared.note.isEmpty { Text(KeepAwake.shared.note) }
        Toggle("Show in the notch on the lock screen (restart to apply)", isOn: Binding(
            get: { OrbPanelController.lockScreenEnabled },
            set: { UserDefaults.standard.set($0, forKey: "lockScreenOverlay") }))

        Divider()

        Menu("Router eval") {
            Button("Run offline (rules and tool search)") { AppDelegate.shared?.runRouterEval(useModel: false) }
            Button("Run full (with the small model)") { AppDelegate.shared?.runRouterEval(useModel: true) }
        }

        Divider()

        Text(state.musicStatus)
        if let now = state.nowPlaying {
            Text("♪ \(now)")
        }
        if !state.musicContextNote.isEmpty {
            Text("Last pick: \(state.musicContextNote)")
        }
        Button("Copy music pairing code") {
            AppDelegate.shared?.conversation.music.copyPairingCode()
        }
        Button("Resync music library") {
            Task { @MainActor in
                guard let music = AppDelegate.shared?.conversation.music else { return }
                let result = await music.sync()
                AppDelegate.shared?.state.statusLine = result
            }
        }

        Divider()

        Button("Quit VOID") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    @ViewBuilder
    private var quietMenu: some View {
        let quiet = PhoneSettings.shared
        Menu(quietTitle(quiet)) {
            Toggle("Quiet during set hours", isOn: Binding(
                get: { quiet.quietEnabled }, set: { quiet.quietEnabled = $0 }))
            Menu("From \(PhoneSettings.clock(quiet.quietStart))") {
                ForEach(0..<24, id: \.self) { h in
                    Button(PhoneSettings.clock(h * 60)) { quiet.quietStart = h * 60 }
                }
            }
            Menu("To \(PhoneSettings.clock(quiet.quietEnd))") {
                ForEach(0..<24, id: \.self) { h in
                    Button(PhoneSettings.clock(h * 60)) { quiet.quietEnd = h * 60 }
                }
            }
            Divider()
            Button("Quiet for 1 hour") { quiet.quietFor(hours: 1) }
            Button("Quiet for 3 hours") { quiet.quietFor(hours: 3) }
            Button("Quiet for the rest of today") { quiet.quietRestOfToday() }
            Button("End quiet timer") { quiet.clearTimer() }
        }
    }

    private func quietTitle(_ quiet: PhoneSettings) -> String {
        if let until = quiet.quietUntil, until > Date() {
            return "Quiet until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return quiet.isQuietNow ? "Quiet hours: quiet now" : "Quiet hours: VOID may speak"
    }
}
