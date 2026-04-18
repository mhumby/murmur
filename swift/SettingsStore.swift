import Foundation
import SwiftUI

/// User-editable settings that live outside history (API keys, preferences).
/// The API key is persisted via KeychainHelper; preferences are in UserDefaults.
final class SettingsStore: ObservableObject {
    private static let openAIAccount = "openai.api_key"
    private static let proofreadKey  = "murmur.proofreadEnabled"
    private static let proofreadModel = "gpt-4o-mini"

    /// Non-empty if an OpenAI key is stored in Keychain. Kept separate from
    /// the raw value so views don't re-render the secret every keystroke.
    @Published private(set) var hasOpenAIKey: Bool

    /// When true, each transcription is passed through gpt-4o-mini to fix
    /// grammar, punctuation, and phrasing before pasting. Requires an API key.
    @Published var proofreadEnabled: Bool {
        didSet { UserDefaults.standard.set(proofreadEnabled, forKey: Self.proofreadKey) }
    }

    init() {
        let existing = KeychainHelper.get(Self.openAIAccount) ?? ""
        self.hasOpenAIKey = !existing.isEmpty
        self.proofreadEnabled = UserDefaults.standard.bool(forKey: Self.proofreadKey)
    }

    /// Read the current OpenAI API key (nil if none). Callers should avoid
    /// caching this; fetch on demand right before making a request.
    func openAIAPIKey() -> String? {
        let v = KeychainHelper.get(Self.openAIAccount) ?? ""
        return v.isEmpty ? nil : v
    }

    /// Validates `key` against the OpenAI API, then saves it to Keychain if
    /// valid. `completion` is called on the main queue with `nil` on success
    /// or a user-facing error string on failure.
    func validateAndSaveOpenAIKey(_ key: String, completion: @escaping (String?) -> Void) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion("Key cannot be empty.")
            return
        }

        var request = URLRequest(
            url: URL(string: "https://api.openai.com/v1/models")!
        )
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion("Network error: \(error.localizedDescription)")
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    completion("No response from OpenAI.")
                    return
                }
                switch http.statusCode {
                case 200:
                    KeychainHelper.set(trimmed, for: Self.openAIAccount)
                    self?.hasOpenAIKey = true
                    completion(nil)
                case 401:
                    completion("Invalid API key — check it and try again.")
                case 429:
                    completion("Rate limited. Key looks valid, try again in a moment.")
                default:
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    completion("OpenAI \(http.statusCode): \(body.prefix(120))")
                }
            }
        }.resume()
    }

    func clearOpenAIAPIKey() {
        KeychainHelper.delete(Self.openAIAccount)
        hasOpenAIKey = false
    }

    // MARK: - Proofread

    /// Sends `text` through gpt-4o-mini to fix grammar, punctuation, and
    /// phrasing. Blocks the calling thread — call from a background queue.
    /// Returns the polished text, or throws on network/API failure.
    func proofread(_ text: String) throws -> String {
        guard let apiKey = openAIAPIKey() else {
            throw ProofreadError("No OpenAI API key — cannot proofread.")
        }

        let payload: [String: Any] = [
            "model": Self.proofreadModel,
            "temperature": 0,
            "messages": [
                [
                    "role": "system",
                    "content": """
                        You are a transcription editor. The user will give you raw \
                        speech-to-text output. Fix grammar, punctuation, capitalisation, \
                        and awkward phrasing so it reads as polished written prose. \
                        Remove filler words (um, uh, like, you know). Do not add, \
                        remove, or change any factual content. Return only the \
                        corrected text — no commentary, no quotation marks.
                        """
                ],
                [
                    "role": "user",
                    "content": text
                ]
            ]
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?
        let sem = DispatchSemaphore(value: 0)

        URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            sem.signal()
        }.resume()
        sem.wait()

        if let error = resultError {
            throw ProofreadError("Network error: \(error.localizedDescription)")
        }
        guard let http = resultResponse as? HTTPURLResponse, let data = resultData else {
            throw ProofreadError("Empty response from OpenAI.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProofreadError("OpenAI \(http.statusCode): \(body.prefix(120))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ProofreadError("Malformed response from OpenAI.")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ProofreadError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
