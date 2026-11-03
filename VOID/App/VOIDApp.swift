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

        Divider()

        Picker("Deep brain", selection: Binding(
            get: { state.mode },
            set: { AppDelegate.shared?.conversation.setMode($0) }
        )) {
            Text("Normal · Qwen3.5 2B").tag(BrainMode.normal)
            Text("Focus · Qwen3.5 4B (close heavy apps)").tag(BrainMode.focus)
        }

        Divider()

        Button("Quit VOID") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
