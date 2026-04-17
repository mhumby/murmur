import Foundation
import SwiftUI

// MARK: - Entry

/// A single transcription event persisted to history.
struct HistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let modelDisplayName: String   // e.g. "Local — Base" or "OpenAI — gpt-4o-transcribe"
    let text: String

    init(id: UUID = UUID(), timestamp: Date = Date(), modelDisplayName: String, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.modelDisplayName = modelDisplayName
        self.text = text
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

    /// Append a new transcription. Called from the main thread after a
    /// successful transcription — SwiftUI observers update immediately.
    func append(modelDisplayName: String, text: String) {
        // Skip empty transcriptions entirely.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let entry = HistoryEntry(modelDisplayName: modelDisplayName, text: trimmed)
        entries.insert(entry, at: 0)  // newest first
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
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
