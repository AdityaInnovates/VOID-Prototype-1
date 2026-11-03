import SwiftUI

/// The full conversation, hidden by default. Shows which brain said what, and how fast.
struct TranscriptView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if state.messages.isEmpty {
                        Text("Nothing yet. Press ⌥Space and say hi.")
                            .foregroundStyle(Color.white.opacity(0.35))
                            .padding(.top, 40)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(state.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 36)
            }
            .onChange(of: state.messages.last?.text) { _, _ in
                if let last = state.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 400)
        .background(Color(red: 0.035, green: 0.035, blue: 0.045))
        .preferredColorScheme(.dark)
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(labelColor)
            Text(message.text.isEmpty ? "…" : message.text)
                .font(.system(size: 13.5))
                .foregroundStyle(Color.white.opacity(message.role == .user ? 0.6 : 0.88))
                .textSelection(.enabled)
            if let metrics = message.metrics {
                Text(metrics)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.28))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: String {
        switch message.source {
        case .user: return "YOU"
        case .reflex: return "VOID · REFLEX"
        case .deep: return "VOID · DEEP"
        case .system: return "SYSTEM"
        }
    }

    private var labelColor: Color {
        switch message.source {
        case .user: return Color.white.opacity(0.35)
        case .reflex, .deep: return Color(red: 0.36, green: 0.84, blue: 1.0).opacity(0.75)
        case .system: return Color.white.opacity(0.3)
        }
    }
}
