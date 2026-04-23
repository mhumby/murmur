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

                HistorySection(
                    history: state.history,
                    vocabulary: state.vocabulary
                )
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
    @ObservedObject var settings: SettingsStore
    @ObservedObject var vocabulary: VocabularyStore

    init(state: AppState) {
        self.state = state
        self.settings = state.settings
        self.vocabulary = state.vocabulary
    }

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
                            selected: !state.useOnline && state.currentModelID == model.id,
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
                        selected: state.useOnline,
                        enabled: settings.hasOpenAIKey,
                        trailingNote: settings.hasOpenAIKey ? nil : "Add API key →",
                        onSelect: { state.selectOnline() }
                    )
                }
            }
            .padding(20)

            Divider()

            VocabularySection(vocabulary: vocabulary)
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
    @State private var validating: Bool = false
    @State private var saveError: String? = nil
    @State private var showSaved: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("OpenAI API Key")
                    .font(.headline)
                if settings.hasOpenAIKey {
                    Label("Verified", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Spacer()
                Link("Get a key",
                     destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.caption)
            }

            Text("Enter your key to enable the online model. It is validated against OpenAI before saving, then stored in macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $settings.proofreadEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Proofread after transcription")
                        .font(.callout)
                    Text("Fixes grammar, punctuation, and phrasing via gpt-4o-mini. Works with any model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.hasOpenAIKey)
            .opacity(settings.hasOpenAIKey ? 1 : 0.45)

            VStack(alignment: .leading, spacing: 4) {
                Text("Speaker context (optional)")
                    .font(.callout)
                Text("Helps the model pick the right words for your domain. Used by both online transcription and proofread.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "e.g. I am a software engineer talking about Swift, DevOps, and GitHub.",
                    text: $settings.speakerContext,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...3)
                .disabled(!settings.hasOpenAIKey)
                .opacity(settings.hasOpenAIKey ? 1 : 0.45)
            }

            Divider()

            HStack(spacing: 8) {
                SecureField(settings.hasOpenAIKey ? "•••••••••••••••••••• (key saved)" : "sk-…",
                            text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .disabled(validating)

                if validating {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 60)
                } else {
                    Button("Save") { save() }
                        .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)

                    if settings.hasOpenAIKey {
                        Button("Remove", role: .destructive) {
                            settings.clearOpenAIAPIKey()
                            saveError = nil
                        }
                    }
                }
            }

            if let error = saveError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if showSaved {
                Label("Saved to Keychain.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        saveError = nil
        validating = true
        settings.validateAndSaveOpenAIKey(draftKey) { error in
            validating = false
            if let error = error {
                saveError = error
            } else {
                draftKey = ""
                withAnimation { showSaved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { showSaved = false }
                }
            }
        }
    }
}

// MARK: - History section (bottom-right)

private struct HistorySection: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var vocabulary: VocabularyStore
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
                            HistoryRow(
                                entry: entry,
                                onDelete: { history.delete(entry.id) },
                                onSaveEdit: { newText in
                                    if let result = history.edit(id: entry.id, newText: newText) {
                                        vocabulary.learn(
                                            original: result.previousText,
                                            edited: result.newText
                                        )
                                    }
                                }
                            )
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
    let onSaveEdit: (String) -> Void

    @State private var hovered = false
    @State private var justCopied = false
    @State private var showingRaw = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    /// What's actually displayed in the row — toggles between polished
    /// and the pre-polish raw transcription when "Show Original" is on.
    private var displayedText: String {
        if showingRaw, let raw = entry.rawText { return raw }
        return entry.text
    }

    var body: some View {
        Group {
            if editing {
                editorBody
            } else {
                displayBody
            }
        }
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy") { copy() }
            Button("Edit") { beginEdit() }
            if entry.rawText != nil {
                Button(showingRaw ? "Show Proofread" : "Show Original") {
                    showingRaw.toggle()
                }
            }
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    // Click-to-copy surface. Hover reveals a pencil (edit) icon alongside
    // the copy glyph — the pencil is outside the Button so its click
    // doesn't trigger a copy.
    private var displayBody: some View {
        ZStack(alignment: .topTrailing) {
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

                        if entry.isPolishing {
                            ProgressView()
                                .controlSize(.mini)
                                .padding(.leading, 2)
                            Text("Polishing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if entry.rawText != nil {
                            Text(showingRaw ? "Original" : "Proofread")
                                .font(.caption2)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }

                        Spacer()
                        // Reserve space for the pencil + copy icons on the
                        // right so text never sits under them.
                        Color.clear.frame(width: 56, height: 1)
                    }
                    Text(displayedText)
                        .font(.callout)
                        .foregroundStyle(entry.isPolishing ? .secondary : .primary)
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

            // Hover-revealed actions. Kept outside the copy Button so clicking
            // the pencil doesn't also copy. "Polishing" state suppresses edit
            // because the text will change out from under the user.
            HStack(spacing: 6) {
                if justCopied {
                    Text("Copied")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if hovered {
                    if !entry.isPolishing {
                        Button(action: beginEdit) {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Edit transcription")
                    }
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
    }

    // Inline editor. Save on ⌘↩ / Save button; Cancel or ⎋ discards.
    // On save, the delta flows into VocabularyStore so the correction is
    // remembered for future prompts.
    private var editorBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("Editing")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
            }
            TextEditor(text: $draft)
                .font(.callout)
                .frame(minHeight: 60)
                .focused($editorFocused)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
            HStack {
                Text("Edits are saved and used to improve future transcriptions.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { cancelEdit() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commitEdit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
        .onAppear { editorFocused = true }
    }

    // MARK: - Actions

    private func beginEdit() {
        draft = displayedText
        editing = true
    }

    private func cancelEdit() {
        editing = false
        draft = ""
    }

    private func commitEdit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onSaveEdit(trimmed)
        }
        editing = false
        draft = ""
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(displayedText, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            justCopied = false
        }
    }
}

// MARK: - Custom Vocabulary (sidebar)

/// Surfaces pairs Murmur has learned from history edits. Collapsed by default
/// so it doesn't dominate the sidebar when empty; expands to a compact list
/// with counts and a clear action.
private struct VocabularySection: View {
    @ObservedObject var vocabulary: VocabularyStore
    @State private var expanded = false
    @State private var showClearConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $expanded) {
                content
                    .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    SectionLabel("Custom Vocabulary")
                    Text("(\(vocabulary.pairs.count))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if vocabulary.pairs.isEmpty {
            Text("Edit any history entry to teach Murmur a correction. Learned pairs are added to future transcription prompts automatically.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(vocabulary.topPairs(limit: 50)) { pair in
                            VocabularyRow(pair: pair) {
                                vocabulary.delete(pair.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 140)

                Button("Clear Vocabulary") { showClearConfirm = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .confirmationDialog(
                "Clear all learned vocabulary?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear", role: .destructive) { vocabulary.clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Murmur will stop applying these corrections until it relearns them from future edits.")
            }
        }
    }
}

private struct VocabularyRow: View {
    let pair: VocabularyPair
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(pair.heard)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(pair.corrected)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if hovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Forget this pair")
            } else if pair.count > 1 {
                Text("×\(pair.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}
