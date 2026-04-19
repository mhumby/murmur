import Foundation
import SwiftUI

/// User-editable settings that live outside history (API keys, preferences).
/// The API key is persisted via KeychainHelper; preferences are in UserDefaults.
final class SettingsStore: ObservableObject {
    private static let openAIAccount = "openai.api_key"
    private static let proofreadKey  = "murmur.proofreadEnabled"
    private static let speakerContextKey = "murmur.speakerContext"
    private static let proofreadModel = "gpt-4o-mini"

    /// Prompt sent with every online transcription request. The OpenAI
    /// `prompt` field biases the model by style, not by rule-text — so
    /// example sentences that USE the target vocabulary outperform
    /// instructional prose like "Claude, not cloud". This is a miniature
    /// corpus of the speaker's likely lexicon written in their natural
    /// voice. Kept under 220 tokens to stay within the API's prompt budget.
    private static let accentHint = """
        I am using Claude, the AI assistant from Anthropic, to help me code. \
        I write Swift, Python, and TypeScript in VS Code and Xcode. \
        Today I opened a PR on GitHub, reviewed the diff in Cursor, and \
        merged it after CI passed. I deployed the service to Kubernetes \
        using Docker and kubectl. I use the OpenAI API, ChatGPT, and Copilot \
        alongside Claude. I work with LLMs, SDKs, CLIs, MCPs, JSON, and YAML. \
        macOS, iOS, and Linux are my platforms. API keys, PRs, and LLM prompts \
        are part of my daily vocabulary.
        """

    /// Non-empty if an OpenAI key is stored in Keychain. Kept separate from
    /// the raw value so views don't re-render the secret every keystroke.
    @Published private(set) var hasOpenAIKey: Bool

    /// When true, each transcription is passed through gpt-4o-mini to fix
    /// grammar, punctuation, and phrasing before pasting. Requires an API key.
    @Published var proofreadEnabled: Bool {
        didSet { UserDefaults.standard.set(proofreadEnabled, forKey: Self.proofreadKey) }
    }

    /// Optional user-supplied context about who is speaking — injected into
    /// the online transcription prompt to improve accuracy on domain terms.
    /// Example: "I am a software engineer talking about DevOps and Swift."
    @Published var speakerContext: String {
        didSet {
            UserDefaults.standard.set(
                speakerContext.trimmingCharacters(in: .whitespacesAndNewlines),
                forKey: Self.speakerContextKey
            )
        }
    }

    init() {
        let existing = KeychainHelper.get(Self.openAIAccount) ?? ""
        self.hasOpenAIKey = !existing.isEmpty
        self.proofreadEnabled = UserDefaults.standard.bool(forKey: Self.proofreadKey)
        self.speakerContext =
            UserDefaults.standard.string(forKey: Self.speakerContextKey) ?? ""
    }

    /// Prompt sent with online transcription requests. Combines the fixed
    /// accent hint with the user's optional speaker context (if non-empty).
    /// Kept under OpenAI's 224-token prompt limit by trimming context.
    func transcriptionPrompt() -> String {
        let context = speakerContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if context.isEmpty { return Self.accentHint }
        // Cap the user portion so we stay well under the model's prompt budget.
        let capped = String(context.prefix(400))
        return "\(Self.accentHint) Speaker context: \(capped)"
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

        let session = OpenAINetworking.makeSession(
            requestTimeout: 10, resourceTimeout: 12
        )
        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    completion(OpenAINetworking.describe(error))
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

        let contextHint = speakerContext.trimmingCharacters(in: .whitespacesAndNewlines)
        var systemPrompt = """
            You are a transcription editor for a software engineer's dictation. \
            Fix grammar, punctuation, capitalisation, and awkward phrasing so it \
            reads as polished written prose. Remove filler words (um, uh, like, \
            you know).

            You MAY correct obviously misrecognised proper nouns and technical \
            terms when the surrounding context makes the intended word \
            unambiguous. Examples of common misrecognitions to fix:
              "cloud" -> "Claude" (when discussing an AI assistant)
              "get hub" -> "GitHub"
              "cube kernel" / "cube control" -> "kubectl"
              "pie thon" -> "Python"
              "co pilot" -> "Copilot"
              "p r" -> "PR"
              "a p i" -> "API"
            Only make these swaps when context clearly supports them. Never \
            invent facts or change the meaning of a sentence.

            Preserve conventional capitalisation: GitHub, macOS, iOS, Kubernetes, \
            Swift, Python, VS Code, Xcode, OpenAI, Anthropic, Claude. Keep \
            acronyms uppercase (PR, API, LLM, SDK, CLI, MCP, JSON, YAML).

            Return only the corrected text — no commentary, no quotation marks.
            """
        if !contextHint.isEmpty {
            systemPrompt += "\n\nAdditional speaker context: \(contextHint.prefix(400))"
        }

        let payload: [String: Any] = [
            "model": Self.proofreadModel,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": text]
            ]
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(
            url: URL(string: "https://api.openai.com/v1/chat/completions")!
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let session = OpenAINetworking.makeSession(
            requestTimeout: 15, resourceTimeout: 20
        )
        let (resultData, resultResponse, resultError)
            = OpenAINetworking.performSync(request, on: session)

        if let error = resultError {
            throw ProofreadError(OpenAINetworking.describe(error))
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
