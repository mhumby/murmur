import Foundation
import SwiftUI

// MARK: - Entry

/// A single transcription event persisted to history.
///
/// When proofread is enabled, `text` holds the polished version and
/// `rawText` holds the original transcription so the user can toggle
/// "Show Original" to verify nothing was changed semantically.
/// `isPolishing` is a transient UI flag — it's excluded from Codable so
/// it always starts false after a relaunch.
struct HistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let modelDisplayName: String   // e.g. "Local — Base" or "OpenAI — gpt-4o-transcribe"
    var text: String
    var rawText: String?           // non-nil only when proofread changed the text

    // Transient — not encoded/decoded, reset on load.
    var isPolishing: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, timestamp, modelDisplayName, text, rawText
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        modelDisplayName: String,
        text: String,
        rawText: String? = nil,
        isPolishing: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.modelDisplayName = modelDisplayName
        self.text = text
        self.rawText = rawText
        self.isPolishing = isPolishing
    }
}

// MARK: - Store

/// Persists transcription history to
/// `~/Library/Application Support/Murmur/history.json`.
///
/// Newest entries first. Caps at `maxEntries` — on overflow, the oldest
/// entries are pruned. All mutations save synchronously; this is fine for
/// history-scale JSON (a few hundred entries at most).
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []

    private let fileURL: URL
    private let maxEntries: Int

    init(maxEntries: Int = 200) {
        self.maxEntries = maxEntries
        self.fileURL = HistoryStore.defaultFileURL()
        load()
    }

    // MARK: File location

    private static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        let dir = base.appendingPathComponent("Murmur", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    // MARK: Load / save

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([HistoryEntry].self, from: data)
        } catch {
            // Corrupt or schema-mismatched file — keep an empty in-memory list
            // and leave the file alone so the user can inspect/recover it.
            NSLog("[Murmur] Failed to load history.json: \(error)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("[Murmur] Failed to save history.json: \(error)")
        }
    }

    // MARK: Mutations

    /// Append a new transcription entry. Returns the entry's ID so a
    /// subsequent proofread pass can update it in-place via `updatePolished`.
    /// `isPolishing` starts true when a polish pass is about to run.
    /// Returns `nil` for empty input (nothing added).
    @discardableResult
    func append(modelDisplayName: String, text: String, isPolishing: Bool = false) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let entry = HistoryEntry(
            modelDisplayName: modelDisplayName,
            text: trimmed,
            isPolishing: isPolishing
        )
        entries.insert(entry, at: 0)  // newest first
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
        return entry.id
    }

    /// Replace an entry's text with the proofread version and clear
    /// `isPolishing`. `rawText` captures the pre-polish original so the
    /// "Show Original" toggle can display it. No-op if the ID is unknown
    /// (e.g. user cleared history mid-polish).
    func updatePolished(id: UUID, polishedText: String, rawText: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = polishedText.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[idx].text = trimmed.isEmpty ? rawText : trimmed
        entries[idx].rawText = (trimmed != rawText && !trimmed.isEmpty) ? rawText : nil
        entries[idx].isPolishing = false
        save()
    }

    /// Clear the `isPolishing` flag without changing text — used when the
    /// proofread pass failed and the entry should stand as the raw transcription.
    func markPolishFailed(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].isPolishing = false
        save()
    }

    /// Result of a user-initiated edit, returned so the caller can feed the
    /// before/after pair into VocabularyStore for learning.
    struct EditResult {
        let previousText: String
        let newText: String
    }

    /// Update an entry's displayed text after the user manually edits it in
    /// the history panel. Returns the before/after strings so the caller can
    /// diff them into vocabulary pairs. Returns nil if the ID is unknown or
    /// the edit is a no-op.
    ///
    /// Editing always targets the visible `text`: the pre-edit `rawText` (if
    /// any) is preserved untouched so the user can still toggle "Show Original"
    /// against the untouched transcription.
    @discardableResult
    func edit(id: UUID, newText: String) -> EditResult? {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let previous = entries[idx].text
        guard trimmed != previous else { return nil }
        entries[idx].text = trimmed
        save()
        return EditResult(previousText: previous, newText: trimmed)
    }

    func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }
}
