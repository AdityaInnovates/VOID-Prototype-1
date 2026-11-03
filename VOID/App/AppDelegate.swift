import AppKit
import Carbon.HIToolbox
import MLX
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    let state = AppState()
    let signal = OrbSignal()
    private(set) lazy var conversation = Conversation(state: state, signal: signal)

    private var orbPanel: OrbPanelController?
    private var transcriptWindow: NSWindow?
    private var hotKey: HotKey?
    private var handsFreeKey: HotKey?
    private var memoryMonitor: MemoryMonitor?

    // ⌥Space: tap = show/hide, hold = talk (release to send).
    private var keyIsDown = false
    private var holdActive = false
    private var holdTask: Task<Void, Never>?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Keep MLX's buffer cache small: this Mac has 8 GB shared with the GPU.
        Memory.cacheLimit = 128 * 1024 * 1024

        orbPanel = OrbPanelController(state: state, conversation: conversation, signal: signal)

        hotKey = HotKey(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey),
            onPress: {
                Task { @MainActor in AppDelegate.shared?.hotKeyDown() }
            },
            onRelease: {
                Task { @MainActor in AppDelegate.shared?.hotKeyUp() }
            }
        )

        // ⌥⇧Space: hands-free conversation on/off.
        handsFreeKey = HotKey(
            id: 2,
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey | shiftKey),
            onPress: {
                Task { @MainActor in AppDelegate.shared?.toggleHandsFree() }
            }
        )

        memoryMonitor = MemoryMonitor { event in
            MainActor.assumeIsolated {
                AppDelegate.shared?.conversation.handleMemoryPressure(event)
            }
        }

        orbPanel?.show()
        conversation.warmUp()
    }

    private func hotKeyDown() {
        guard !keyIsDown else { return }
        keyIsDown = true
        holdActive = false
        holdTask?.cancel()
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, let self, self.keyIsDown else { return }
            self.holdActive = true
            self.orbPanel?.showIfHidden()
            self.conversation.startListening(hold: true)
        }
    }

    private func hotKeyUp() {
        guard keyIsDown else { return }
        keyIsDown = false
        holdTask?.cancel()
        if holdActive {
            holdActive = false
            conversation.finishListening()
        } else {
            toggleOrb()
        }
    }

    func toggleHandsFree() {
        if !state.handsFree { orbPanel?.showIfHidden() }
        conversation.toggleHandsFree()
    }

    func toggleOrb() {
        orbPanel?.toggle()
    }

    func hideOrb() {
        orbPanel?.hide()
    }

    func showTranscript() {
        if transcriptWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "VOID Transcript"
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: TranscriptView().environment(state)
            )
            window.center()
            transcriptWindow = window
        }
        NSApp.activate()
        transcriptWindow?.makeKeyAndOrderFront(nil)
    }
}
