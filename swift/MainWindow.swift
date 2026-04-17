import SwiftUI
import AppKit

// MARK: - Window Controller

/// Owns the single main window instance. Closing the window hides it rather
/// than destroying it, so reopening is instant and state (size, position,
/// selection) is preserved across open/close cycles.
class MainWindowController {
    private var window: NSWindow?
    private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    func show() {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: ContentView(state: state))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Murmur"
        window.contentViewController = hosting
        window.center()
        window.setFrameAutosaveName("MurmurMainWindow")
        // Keep the window object alive across close/reopen so state persists.
        window.isReleasedWhenClosed = false

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - SwiftUI Content

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ModelSection(state: state)
            HistorySection()
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 480)
    }
}

// MARK: - Model Section

private struct ModelSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Whisper Model")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                SectionLabel("Local")
                ForEach(state.localModels, id: \.id) { model in
                    ModelRow(
                        label: model.label,
                        selected: state.currentModelID == model.id,
                        enabled: true,
                        trailingNote: nil,
                        onSelect: { state.selectLocal(model.id) }
                    )
                }

                SectionLabel("Online")
                    .padding(.top, 8)
                ModelRow(
                    label: "OpenAI — gpt-4o-transcribe",
                    selected: false,
                    enabled: false,
                    trailingNote: "Coming in v1.9.0",
                    onSelect: {}
                )
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
}

private struct ModelRow: View {
    let label: String
    let selected: Bool
    let enabled: Bool
    let trailingNote: String?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(label)
                    .foregroundStyle(enabled ? .primary : .secondary)
                Spacer()
                if let note = trailingNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - History Section (placeholder — wired in PR 14)

private struct HistorySection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("History")
                .font(.headline)

            VStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Coming in v1.8.0")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
