import AppKit
import SkyLightWindow
import SwiftUI

/// A borderless panel that can take keyboard focus without activating the app, and that
/// is allowed to sit over the menu bar, the notch, and the lock screen.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// macOS normally pushes windows out of the menu bar; the notch UI has to sit in it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// A window pushed up against the notch gets safe-area insets that change as it is resized,
/// which sends AppKit's layout into a loop and crashes. The notch UI handles the notch itself.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override var safeAreaRect: NSRect { bounds }
}

/// Where the camera notch is on a screen (or, on a screen without one, a menu-bar-high strip).
@MainActor
@Observable
final class NotchLayout {
    var width: CGFloat = 0
    var height: CGFloat = 32
    var hasNotch = false

    func update(for screen: NSScreen) {
        if screen.safeAreaInsets.top > 0 {
            hasNotch = true
            height = screen.safeAreaInsets.top
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                width = max(120, screen.frame.width - left.width - right.width)
            } else {
                width = 200
            }
        } else {
            hasNotch = false
            height = max(24, NSStatusBar.system.thickness)
            width = 0
        }
    }
}

/// VOID lives in the notch: a black pill that blends into it, widens to show the little
/// orb while VOID listens or talks, and opens into the full VOID panel (the same orb,
/// caption and text field as before) when you press ⌥Space, click it, or hover over it.
/// The window is moved onto the lock-screen layer, so it also shows (and listens) while locked.
@MainActor
final class OrbPanelController {
    private let panel: KeyPanel
    private let state: AppState
    private let conversation: Conversation
    private let layout = NotchLayout()

    static let expandedSize = NSSize(width: 430, height: 156)
    static let earWidth: CGFloat = 46
    static let lockSize = NSSize(width: 300, height: 340)

    private var inSky = false
    private var pinned = false
    private var hoverTask: Task<Void, Never>?
    private var shrinkTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    /// Show on the lock screen too (turn off from the menu if it ever misbehaves).
    static var lockScreenEnabled: Bool {
        UserDefaults.standard.object(forKey: "lockScreenOverlay") as? Bool ?? true
    }

    init(state: AppState, conversation: Conversation, signal: OrbSignal) {
        self.state = state
        self.conversation = conversation
        self.panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: Self.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .init(rawValue: Int(Int32.max - 2))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.canBecomeVisibleWithoutLogin = true
        panel.appearance = NSAppearance(named: .darkAqua)

        let root = NotchRootView(
            state: state,
            signal: signal,
            layout: layout,
            onOrbTap: { [weak conversation] in conversation?.toggleListening() },
            onSubmit: { [weak conversation] text in conversation?.send(text) },
            onEscape: { [weak self] in self?.handleEscape() },
            onCollapsedTap: { [weak self] in self?.collapsedTapped() },
            onHover: { [weak self] inside in self?.hover(inside) }
        )
        let hosting = NotchHostingView(rootView: root)
        // The window is sized by hand; letting SwiftUI resize it as well fights with that.
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        // SwiftUI resizes a window whose content view is its hosting view to fit the animated
        // shape, which fights the hand-set frame and loops. A plain container view stops that.
        let container = NSView(frame: NSRect(origin: .zero, size: Self.expandedSize))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container

        trackPhase()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    /// The pill widens when VOID starts listening or talking, so the window follows it.
    private func trackPhase() {
        withObservationTracking {
            _ = state.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !self.state.orbVisible, self.panel.isVisible { self.applyFrame(expanded: false) }
                self.trackPhase()
            }
        }
    }

    // MARK: - Screen

    /// The screen with the notch if there is one (the built-in display), else the main screen.
    private var targetScreen: NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private var collapsedSize: NSSize {
        let active = state.phase != .idle || state.screenLocked
        var width = layout.width
        if active { width += Self.earWidth * 2 }
        if !layout.hasNotch { width = active ? 150 : 0 }
        return NSSize(width: max(width, 1), height: layout.height)
    }

    private func reposition() {
        guard let screen = targetScreen else { return }
        layout.update(for: screen)
        applyFrame(expanded: state.orbVisible, on: screen)
    }

    private func applyFrame(expanded: Bool, on screen: NSScreen? = nil) {
        guard let screen = screen ?? targetScreen else { return }
        layout.update(for: screen)
        if state.screenLocked {
            let size = Self.lockSize
            // The orb's centre sits just above the middle of the screen: below the clock,
            // above the avatar and password box.
            let centreFromTop = screen.frame.height * 0.47
            let frame = NSRect(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.maxY - centreFromTop - size.height * 0.40,
                width: size.width, height: size.height)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            return
        }
        // The window is only as big as what's showing, so the transparent part never blocks clicks.
        let size = expanded ? Self.expandedSize : collapsedSize
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width, height: size.height)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    /// Moves the window onto the lock-screen layer, once it has a window number.
    private func moveToSky() {
        guard !inSky, Self.lockScreenEnabled, panel.windowNumber > 0 else { return }
        inSky = true
        SkyLightOperator.shared.delegateWindow(panel)
    }

    // MARK: - Showing and hiding

    func toggle() {
        state.orbVisible ? hide() : show()
    }

    func showIfHidden() {
        if !state.orbVisible { show() }
    }

    /// Opens VOID out of the notch and stays open until Esc or the hotkey.
    func show() {
        pinned = true
        expand()
    }

    private func expand() {
        hoverTask?.cancel()
        shrinkTask?.cancel()
        guard !state.orbVisible || !panel.isVisible else { return }
        applyFrame(expanded: true)
        panel.orderFrontRegardless()
        moveToSky()
        panel.makeKey()
        // Let the wider window settle first. Animating at the same moment makes the pill slide
        // in from the left as the window grows; this way it opens from the centre, downward.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { self.state.orbVisible = true }
        }
    }

    /// Folds back into the notch. The window stays, as a pill, so it is always there to click.
    func hide() {
        hoverTask?.cancel()
        pinned = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { state.orbVisible = false }
        shrinkTask?.cancel()
        shrinkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled, let self, !self.state.orbVisible else { return }
            self.applyFrame(expanded: false)
            self.panel.orderFrontRegardless()
            self.moveToSky()
        }
    }

    /// Makes sure the pill is on screen (called at launch and after unlock).
    func ensureVisible() {
        if !panel.isVisible { applyFrame(expanded: state.orbVisible); panel.orderFrontRegardless() }
        moveToSky()
    }

    /// The Mac just locked: fold up so the lock screen is clear.
    /// On the lock screen VOID becomes a floating glass orb between the clock and the
    /// password box (see `lockBody`), not the notch panel.
    func screenLocked() {
        hoverTask?.cancel()
        shrinkTask?.cancel()
        state.orbVisible = false
        applyFrame(expanded: false)
        panel.orderFrontRegardless()
        moveToSky()
    }

    func screenUnlocked() {
        state.orbVisible = false
        applyFrame(expanded: false)
        panel.orderFrontRegardless()
        moveToSky()
    }

    private func collapsedTapped() {
        show()
        // Locked, there is no keyboard to type with: a tap goes straight to listening.
        if state.screenLocked, !conversation.isBusy { conversation.toggleListening() }
    }

    private func hover(_ inside: Bool) {
        hoverTask?.cancel()
        if inside, !state.orbVisible {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled, let self else { return }
                self.expand()   // opened by hover: closes again when the mouse leaves
            }
        } else if !inside, state.orbVisible, !pinned, !conversation.isBusy {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, let self, !self.pinned else { return }
                self.hide()
            }
        }
    }

    /// Esc stops VOID if it's talking; otherwise it folds back into the notch.
    private func handleEscape() {
        if conversation.isBusy {
            conversation.cancel()
        } else {
            hide()
        }
    }
}

/// The notch outline: flat on top where it meets the screen edge, flaring outward at the
/// top corners and rounded at the bottom, like the real notch.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.height / 2), b = min(bottomRadius, max(0, rect.height - t))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRootView: View {
    let state: AppState
    let signal: OrbSignal
    let layout: NotchLayout
    let onOrbTap: () -> Void
    let onSubmit: (String) -> Void
    let onEscape: () -> Void
    let onCollapsedTap: () -> Void
    let onHover: (Bool) -> Void

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    private var expanded: Bool { state.orbVisible }
    private var active: Bool { state.phase != .idle || state.screenLocked }

    private var shapeSize: CGSize {
        if expanded { return CGSize(width: OrbPanelController.expandedSize.width, height: OrbPanelController.expandedSize.height) }
        var width = layout.width
        if active { width += OrbPanelController.earWidth * 2 }
        if !layout.hasNotch { width = active ? 150 : 0 }
        return CGSize(width: width, height: layout.height)
    }

    var body: some View {
        if state.screenLocked { lockBody } else { notchBody }
    }

    /// The lock-screen look: a transparent, glossy orb of liquid glass with VOID under it.
    private var lockBody: some View {
        let cyan = Color(red: 0.36, green: 0.84, blue: 1.0)
        let violet = Color(red: 0.72, green: 0.62, blue: 1.0)
        return VStack(spacing: 6) {
            ZStack {
                // Soft light spilling around the orb.
                Circle()
                    .fill(RadialGradient(colors: [cyan.opacity(0.30), violet.opacity(0.12), .clear],
                                         center: .center, startRadius: 30, endRadius: 140))
                    .frame(width: 280, height: 280)
                    .blur(radius: 18)
                // The glass body: clear in the middle, brighter toward the rim.
                Circle()
                    .fill(RadialGradient(colors: [Color.white.opacity(0.02), Color.white.opacity(0.10), Color.white.opacity(0.24)],
                                         center: .center, startRadius: 20, endRadius: 100))
                    .frame(width: 200, height: 200)
                // A slow band of colour running round the rim.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    Circle()
                        .strokeBorder(
                            AngularGradient(colors: [Color.white.opacity(0.9), cyan.opacity(0.6), .clear, violet.opacity(0.6), Color.white.opacity(0.9)],
                                            center: .center),
                            lineWidth: 1.6)
                        .frame(width: 200, height: 200)
                        .rotationEffect(.degrees(t * 24))
                }
                // Light caught on the top-left, and a cool reflection at the bottom.
                Ellipse()
                    .fill(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.0)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 120, height: 56)
                    .blur(radius: 5)
                    .offset(x: -22, y: -72)
                Ellipse()
                    .fill(LinearGradient(colors: [cyan.opacity(0.0), cyan.opacity(0.32)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 130, height: 40)
                    .blur(radius: 8)
                    .offset(y: 76)
                // The ring that lives in the middle: it reacts to your voice as always.
                OrbView(state: state, signal: signal, animating: true)
                    .frame(width: 150, height: 150)
            }
            .frame(width: 280, height: 260)
            .contentShape(Circle().inset(by: 40))
            .onTapGesture(perform: onOrbTap)

            Text("VOID")
                .font(.system(size: 19, weight: .thin))
                .tracking(12)
                .foregroundStyle(LinearGradient(colors: [Color.white.opacity(0.95), cyan.opacity(0.8)],
                                                startPoint: .leading, endPoint: .trailing))
                .shadow(color: cyan.opacity(0.55), radius: 8)
                .padding(.leading, 12)

            Text(state.caption)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: 250, height: 34, alignment: .top)
                .opacity(state.captionVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.4), value: state.captionVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    private var notchBody: some View {
        ZStack(alignment: .top) {
            Color.clear
            ZStack(alignment: .top) {
                NotchShape(topRadius: expanded ? 14 : 6, bottomRadius: expanded ? 26 : 12)
                    .fill(Color.black)
                if expanded { expandedContent.transition(.opacity) } else { collapsedContent.transition(.opacity) }
            }
            .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
            .clipShape(NotchShape(topRadius: expanded ? 14 : 6, bottomRadius: expanded ? 26 : 12))
            .contentShape(Rectangle())
            .onHover(perform: onHover)
            .onTapGesture { if !expanded { onCollapsedTap() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: expanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: active)
        .ignoresSafeArea()
        .onExitCommand(perform: onEscape)
        .onChange(of: state.orbVisible) { _, visible in
            if visible { inputFocused = true }
        }
        .preferredColorScheme(.dark)
    }

    /// The small version: the orb in the left ear while VOID is working.
    private var collapsedContent: some View {
        HStack {
            if active {
                OrbView(state: state, signal: signal, animating: true)
                    .frame(width: 24, height: 24)
                    .padding(.leading, 18)
                Spacer(minLength: layout.width)
                Circle()
                    .fill(Color(red: 0.36, green: 0.84, blue: 1.0).opacity(0.85))
                    .frame(width: 5, height: 5)
                    .padding(.trailing, 20)
            }
        }
        .frame(height: layout.height)
    }

    /// The same VOID as before, laid out wide: the orb on the left; what VOID says on the
    /// right, with the box to type in underneath.
    private var expandedContent: some View {
        HStack(spacing: 12) {
            OrbView(state: state, signal: signal)
                .frame(width: 104, height: 104)
                .onTapGesture(perform: onOrbTap)
                .help("Click to talk. Click again to send.")

            VStack(alignment: .leading, spacing: 8) {
                Text(state.caption.isEmpty ? " " : state.caption)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(state.captionVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.45), value: state.captionVisible)

                TextField(
                    "",
                    text: $input,
                    prompt: Text(state.screenLocked ? "Tap the orb and speak" : "Hold ⌥Space to talk, or type")
                        .foregroundStyle(Color.white.opacity(0.28))
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.white.opacity(0.9))
                .focused($inputFocused)
                .onSubmit {
                    let text = input
                    input = ""
                    onSubmit(text)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 22)
        .padding(.top, layout.height - 6)
        .padding(.bottom, 12)
        .frame(width: OrbPanelController.expandedSize.width, height: OrbPanelController.expandedSize.height, alignment: .top)
        .onAppear { inputFocused = true }
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
