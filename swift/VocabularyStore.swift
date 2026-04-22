import Foundation
import SwiftUI

// MARK: - Pair

/// A learned `{heard -> corrected}` mapping, derived from a user editing an
/// entry in the history panel. `count` increments every time we see the same
/// correction again so popular pairs rank higher when we inject them into
/// prompts. `lastSeen` is used as a tiebreaker during prune / sort.
struct VocabularyPair: Codable, Identifiable, Hashable {
    var id: String { "\(heard.lowercased())->\(corrected.lowercased())" }
    var heard: String         // what the transcription produced
    var corrected: String     // what the user changed it to
    var count: Int
    var lastSeen: Date
}

// MARK: - Store

/// Persistent custom vocabulary learned from history edits.
///
/// When the user edits a history row, `learn(original:edited:)` diffs the two
/// texts at the word level and turns meaningful substitutions into pairs.
/// Trivial edits (case-only, punctuation-only, pure additions/deletions) are
/// ignored: we only want lexical corrections that are worth teaching the
/// transcription model about.
///
/// Pairs are stored in `~/Library/Application Support/Murmur/custom_vocabulary.json`,
/// capped at `maxPairs`, and injected into the online transcription prompt
/// and the proofread system prompt via `SettingsStore`.
final class VocabularyStore: ObservableObject {
    @Published private(set) var pairs: [VocabularyPair] = []

    private let fileURL: URL
    private let maxPairs: Int

    init(maxPairs: Int = 50) {
        self.maxPairs = maxPairs
        self.fileURL = VocabularyStore.defaultFileURL()
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
        return dir.appendingPathComponent("custom_vocabulary.json")
    }

    // MARK: Load / save

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            pairs = try decoder.decode([VocabularyPair].self, from: data)
        } catch {
            NSLog("[Murmur] Failed to load custom_vocabulary.json: \(error)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(pairs)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("[Murmur] Failed to save custom_vocabulary.json: \(error)")
        }
    }

    // MARK: Public API

    /// Extract meaningful pairs from an edit and upsert them. Returns the
    /// number of new or incremented pairs so callers can log / react.
    @discardableResult
    func learn(original: String, edited: String) -> Int {
        let extracted = VocabularyDiff.extractPairs(original: original, edited: edited)
        guard !extracted.isEmpty else { return 0 }

        let now = Date()
        for pair in extracted {
            if let idx = pairs.firstIndex(where: {
                $0.heard.caseInsensitiveCompare(pair.heard) == .orderedSame
                    && $0.corrected.caseInsensitiveCompare(pair.corrected) == .orderedSame
            }) {
                pairs[idx].count += 1
                pairs[idx].lastSeen = now
                // Prefer the user's latest capitalisation of the corrected form.
                pairs[idx].corrected = pair.corrected
            } else {
                pairs.append(
                    VocabularyPair(heard: pair.heard, corrected: pair.corrected,
                                   count: 1, lastSeen: now)
                )
            }
        }

        prune()
        save()
        return extracted.count
    }

    /// Top-N pairs, ranked by `count` descending, then by `lastSeen`.
    /// Used for prompt injection; keep the limit small to stay under the
    /// OpenAI ~224-token prompt budget.
    func topPairs(limit: Int = 15) -> [VocabularyPair] {
        pairs
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.lastSeen > rhs.lastSeen
            }
            .prefix(limit)
            .map { $0 }
    }

    func clearAll() {
        pairs.removeAll()
        save()
    }

    func delete(_ id: String) {
        pairs.removeAll { $0.id == id }
        save()
    }

    // MARK: Pruning

    /// Drop low-count, stale entries until we're back under `maxPairs`.
    private func prune() {
        guard pairs.count > maxPairs else { return }
        pairs.sort { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.lastSeen > rhs.lastSeen
        }
        pairs = Array(pairs.prefix(maxPairs))
    }
}

// MARK: - Diff

/// Word-level diff that turns `(original, edited)` into `[(heard, corrected)]`
/// pairs worth learning. Deliberately conservative: we'd rather miss a real
/// correction than teach the model a bogus one, because bad pairs leak into
/// every future transcription prompt.
enum VocabularyDiff {
    struct ExtractedPair: Equatable {
        let heard: String
        let corrected: String
    }

    /// Split into word tokens paired with the separator run that followed each
    /// (so we can rebuild case-preserved phrases when extracting multi-word
    /// pairs). A "word" here is any run of letters/digits/apostrophes.
    private struct Token: Equatable {
        let word: String
        let normalised: String  // lowercased + trimmed of outer punctuation
    }

    private static func tokenise(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            let normalised = current
                .lowercased()
                .trimmingCharacters(in: CharacterSet.punctuationCharacters)
            if !normalised.isEmpty {
                tokens.append(Token(word: current, normalised: normalised))
            }
            current = ""
        }
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "\u{2019}" {
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// Extract meaningful substitution pairs. See file header for the
    /// "conservative" design intent.
    static func extractPairs(original: String, edited: String) -> [ExtractedPair] {
        let a = tokenise(original)
        let b = tokenise(edited)
        guard !a.isEmpty, !b.isEmpty else { return [] }

        let ops = diff(a.map { $0.normalised }, b.map { $0.normalised })
        var out: [ExtractedPair] = []

        // Walk through `replace` regions only. Pure insertions / deletions
        // aren't lexical corrections — they're the user rewording the sentence.
        var i = 0   // index into a
        var j = 0   // index into b
        for op in ops {
            switch op {
            case .equal(let n):
                i += n; j += n
            case .delete(let n):
                // Look ahead: if immediately followed by insert, it's a replace.
                // diff() below already merges these, so this branch is only
                // hit for pure deletions — skip.
                i += n
            case .insert(let n):
                j += n
            case .replace(let delCount, let insCount):
                let heardTokens  = Array(a[i ..< i + delCount])
                let editedTokens = Array(b[j ..< j + insCount])
                if let pair = pair(from: heardTokens, to: editedTokens) {
                    out.append(pair)
                }
                i += delCount
                j += insCount
            }
        }
        return out
    }

    /// Turn a replace region into a single pair, if it looks meaningful.
    private static func pair(from heard: [Token], to corrected: [Token]) -> ExtractedPair? {
        let heardPhrase     = heard.map { $0.word }.joined(separator: " ")
        let correctedPhrase = corrected.map { $0.word }.joined(separator: " ")
        let heardNorm       = heard.map { $0.normalised }.joined(separator: " ")
        let correctedNorm   = corrected.map { $0.normalised }.joined(separator: " ")

        // Case-only change → the user just fixed capitalisation, not a lexical
        // correction. Not worth a vocab entry.
        if heardNorm == correctedNorm { return nil }
        if heardPhrase.isEmpty || correctedPhrase.isEmpty { return nil }

        // Filter obvious filler-word edits — removing "um/uh/like" is not a
        // vocabulary lesson, it's a style edit that already happens at
        // proofread time.
        let filler: Set<String> = ["um", "uh", "er", "ah", "like", "you", "know", "so"]
        if heard.allSatisfy({ filler.contains($0.normalised) }) { return nil }

        // Cap length. Phrase pairs longer than 4 words are almost always the
        // user rewording — the learning value per prompt-token is poor.
        if heard.count > 4 || corrected.count > 4 { return nil }

        return ExtractedPair(heard: heardPhrase, corrected: correctedPhrase)
    }

    // MARK: - Diff primitive

    /// Minimal LCS-based diff producing `equal / delete / insert / replace`
    /// operations. Consecutive delete+insert are merged into a single
    /// `replace` so callers don't have to track adjacency themselves.
    private enum Op {
        case equal(Int)
        case delete(Int)
        case insert(Int)
        case replace(delCount: Int, insCount: Int)
    }

    private static func diff(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        // Build LCS DP table.
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0..<n {
            for j in 0..<m {
                if a[i] == b[j] {
                    dp[i+1][j+1] = dp[i][j] + 1
                } else {
                    dp[i+1][j+1] = max(dp[i][j+1], dp[i+1][j])
                }
            }
        }
        // Backtrack to raw ops.
        var raw: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && a[i-1] == b[j-1] {
                raw.append(.equal(1)); i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j-1] >= dp[i-1][j]) {
                raw.append(.insert(1)); j -= 1
            } else {
                raw.append(.delete(1)); i -= 1
            }
        }
        raw.reverse()

        // Coalesce adjacent same-kind ops and merge delete+insert -> replace.
        var merged: [Op] = []
        for op in raw {
            if case .delete(let d) = op,
               let last = merged.last, case .insert(let ins) = last {
                merged.removeLast()
                merged.append(.replace(delCount: d, insCount: ins))
                continue
            }
            if case .insert(let ins) = op,
               let last = merged.last, case .delete(let d) = last {
                merged.removeLast()
                merged.append(.replace(delCount: d, insCount: ins))
                continue
            }
            if let last = merged.last {
                switch (last, op) {
                case (.equal(let a), .equal(let b)):
                    merged.removeLast(); merged.append(.equal(a + b)); continue
                case (.delete(let a), .delete(let b)):
                    merged.removeLast(); merged.append(.delete(a + b)); continue
                case (.insert(let a), .insert(let b)):
                    merged.removeLast(); merged.append(.insert(a + b)); continue
                case (.replace(let d1, let i1), .replace(let d2, let i2)):
                    merged.removeLast()
                    merged.append(.replace(delCount: d1 + d2, insCount: i1 + i2))
                    continue
                case (.replace(let d, let i), .delete(let dn)):
                    merged.removeLast()
                    merged.append(.replace(delCount: d + dn, insCount: i))
                    continue
                case (.replace(let d, let i), .insert(let ins)):
                    merged.removeLast()
                    merged.append(.replace(delCount: d, insCount: i + ins))
                    continue
                default: break
                }
            }
            merged.append(op)
        }
        return merged
    }
}
