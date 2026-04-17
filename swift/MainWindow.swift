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
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
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
        HSplitView {
            Sidebar(state: state)
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)

            VStack(spacing: 0) {
                OpenAISection(settings: state.settings)
                    .padding(20)

                Divider()

                HistorySection(history: state.history)
                    .padding(20)
            }
            .frame(minWidth: 480)
        }
        .frame(minWidth: 780, minHeight: 560)
    }
}

// MARK: - Sidebar (model selection + help)

private struct Sidebar: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Model")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
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
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Online")
                    ModelRow(
                        label: "OpenAI — gpt-4o-transcribe",
                        selected: false,
                        enabled: false,
                        trailingNote: "Coming in v1.9.0",
                        onSelect: {}
                    )
                }
            }
            .padding(20)

            Spacer()

            HelpFooter()
                .padding(20)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .tracking(0.5)
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
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let note = trailingNote {
                    Text(note)
                        .font(.caption2)
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

// MARK: - Help footer

private struct HelpFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("How to use")
            VStack(alignment: .leading, spacing: 4) {
                HelpLine(key: "Fn", desc: "Start / stop recording")
                HelpLine(key: "⌘,", desc: "Open this window")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Link("Documentation", destination: URL(string: "https://github.com/mhumby/murmur")!)
                .font(.caption)
                .padding(.top, 4)
        }
    }
}

private struct HelpLine: View {
    let key: String
    let desc: String
    var body: some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(desc)
        }
    }
}

// MARK: - OpenAI settings (top-right)

private struct OpenAISection: View {
    @ObservedObject var settings: SettingsStore

    @State private var draftKey: String = ""
    @State private var showSaved: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("OpenAI API Key")
                    .font(.headline)
                if settings.hasOpenAIKey {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Link("Get a key",
                     destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.caption)
            }

            Text("Enter your key to enable the online model. Stored locally in macOS Keychain — never leaves your Mac except in direct requests to OpenAI.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                SecureField(settings.hasOpenAIKey ? "•••••••••••••••••••• (key saved)" : "sk-…",
                            text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)

                Button("Save") {
                    settings.setOpenAIAPIKey(draftKey)
                    draftKey = ""
                    flashSaved()
                }
                .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)

                if settings.hasOpenAIKey {
                    Button("Remove", role: .destructive) {
                        settings.clearOpenAIAPIKey()
                    }
                }
            }

            if showSaved {
                Text("Saved to Keychain.")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func flashSaved() {
        withAnimation { showSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { showSaved = false }
        }
    }
}

// MARK: - History section (bottom-right)

private struct HistorySection: View {
    @ObservedObject var history: HistoryStore
    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(.headline)
                Text("(\(history.entries.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !history.entries.isEmpty {
                    Button("Clear All") { showClearConfirm = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if history.entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, entry in
                            HistoryRow(entry: entry, onDelete: { history.delete(entry.id) })
                            if index < history.entries.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Clear all history?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { history.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No transcriptions yet")
                .foregroundStyle(.secondary)
                .font(.callout)
            Text("Press Fn to start recording.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let onDelete: () -> Void

    @State private var hovered = false
    @State private var justCopied = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        Button(action: copy) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(Self.timeFormatter.string(from: entry.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(entry.modelDisplayName)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if justCopied {
                        Text("Copied")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if hovered {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(entry.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(hovered ? Color.accentColor.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy") { copy() }
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            justCopied = false
        }
    }
}
