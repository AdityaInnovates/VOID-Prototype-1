import AppKit
import SwiftUI

/// A borderless floating panel that can take keyboard focus without activating the app,
/// the same way Spotlight does.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OrbPanelController {
    private let panel: KeyPanel
    private let state: AppState
    private let conversation: Conversation

    static let size = NSSize(width: 340, height: 500)

    init(state: AppState, conversation: Conversation, signal: OrbSignal) {
        self.state = state
        self.conversation = conversation
        self.panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)

        let root = OrbPanelView(
            state: state,
            signal: signal,
            onOrbTap: { [weak conversation] in
                conversation?.toggleListening()
            },
            onSubmit: { [weak conversation] text in
                conversation?.send(text)
            },
            onEscape: { [weak self] in
                self?.handleEscape()
            }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hosting
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func showIfHidden() {
        if !panel.isVisible || state.orbVisible == false { show() }
    }

    func show() {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            let origin = NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 72)
            panel.setFrameOrigin(origin)
        }
        state.orbVisible = true
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel.orderOut(nil)
                self?.state.orbVisible = false
            }
        })
    }

    /// Esc stops VOID if it's talking; otherwise it hides the orb.
    private func handleEscape() {
        if conversation.isBusy {
            conversation.cancel()
        } else {
            hide()
        }
    }
}

struct OrbPanelView: View {
    let state: AppState
    let signal: OrbSignal
    let onOrbTap: () -> Void
    let onSubmit: (String) -> Void
    let onEscape: () -> Void

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            OrbView(state: state, signal: signal)
                .frame(width: 290, height: 290)
                .onTapGesture(perform: onOrbTap)
                .help("Click to talk. Click again to send.")

            Text(state.caption)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .frame(width: 280, height: 54, alignment: .top)
                .opacity(state.captionVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.45), value: state.captionVisible)

            TextField(
                "",
                text: $input,
                prompt: Text("Hold ⌥Space to talk, or type").foregroundStyle(Color.white.opacity(0.28))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Color.white.opacity(0.9))
            .multilineTextAlignment(.center)
            .focused($inputFocused)
            .onSubmit {
                let text = input
                input = ""
                onSubmit(text)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(width: 260)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .padding(.vertical, 26)
        .frame(width: OrbPanelController.size.width, height: OrbPanelController.size.height)
        .background(
            ZStack {
                VisualEffectBackground()
                Color(red: 0.03, green: 0.03, blue: 0.04).opacity(0.78)
            }
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .onExitCommand(perform: onEscape)
        .onAppear { inputFocused = true }
        .onChange(of: state.orbVisible) { _, visible in
            if visible { inputFocused = true }
        }
        .preferredColorScheme(.dark)
    }
}

/// Blurs whatever is behind the panel.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
