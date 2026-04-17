import Foundation
import SwiftUI

/// User-editable settings that live outside history (API keys, preferences).
/// The API key is persisted via KeychainHelper; only an in-memory copy is
/// exposed to the UI, and `hasAPIKey` is the flag the UI should gate on.
final class SettingsStore: ObservableObject {
    private static let openAIAccount = "openai.api_key"

    /// Non-empty if an OpenAI key is stored in Keychain. Kept separate from
    /// the raw value so views don't re-render the secret every keystroke.
    @Published private(set) var hasOpenAIKey: Bool

    init() {
        let existing = KeychainHelper.get(Self.openAIAccount) ?? ""
        self.hasOpenAIKey = !existing.isEmpty
    }

    /// Read the current OpenAI API key (nil if none). Callers should avoid
    /// caching this; fetch on demand right before making a request.
    func openAIAPIKey() -> String? {
        let v = KeychainHelper.get(Self.openAIAccount) ?? ""
        return v.isEmpty ? nil : v
    }

    func setOpenAIAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        KeychainHelper.set(trimmed, for: Self.openAIAccount)
        hasOpenAIKey = !trimmed.isEmpty
    }

    func clearOpenAIAPIKey() {
        KeychainHelper.delete(Self.openAIAccount)
        hasOpenAIKey = false
    }
}
