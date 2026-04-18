import Foundation

// MARK: - Protocol

/// A transcription backend. Given a path to a WAV file, returns the
/// transcribed text. Implementations may run locally (Python subprocess)
/// or call a remote API (OpenAI, etc.). Called from a background queue,
/// so implementations may block.
protocol Transcriber {
    /// Human-readable identifier for logs and UI, e.g. "Local — Base" or
    /// "OpenAI — gpt-4o-transcribe".
    var displayName: String { get }

    /// Transcribe the WAV at `audioPath` and return the text.
    /// Throws on failure — the caller decides how to surface errors.
    func transcribe(audioPath: String) throws -> String
}

struct TranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Local (MLX via Python)

/// Runs Whisper locally by spawning the bundled Python interpreter against
/// the bundled `transcribe_cli.py`. This wraps the behaviour that used to
/// live inline in `AppDelegate.transcribeAndPaste()`.
class LocalMLXTranscriber: Transcriber {
    let modelID: String        // e.g. "mlx-community/whisper-base-mlx"
    let modelLabel: String     // e.g. "Base"
    let pythonPath: String
    let scriptPath: String
    let workingDir: String

    var displayName: String { "Local — \(modelLabel)" }

    init(
        modelID: String,
        modelLabel: String,
        pythonPath: String,
        scriptPath: String,
        workingDir: String
    ) {
        self.modelID = modelID
        self.modelLabel = modelLabel
        self.pythonPath = pythonPath
        self.scriptPath = scriptPath
        self.workingDir = workingDir
    }

    func transcribe(audioPath: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath, audioPath, modelID]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text
    }
}

// MARK: - Online (OpenAI)

/// Transcribes via OpenAI's `/v1/audio/transcriptions` endpoint
/// (model: gpt-4o-transcribe). Uses multipart/form-data with the bundled
/// WAV file. Synchronous — blocks the calling thread until the response
/// arrives or the request times out, matching the Transcriber contract.
class OpenAITranscriber: Transcriber {
    static let modelName = "gpt-4o-transcribe"
    private static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private static let timeout: TimeInterval = 60

    private let apiKeyProvider: () -> String?

    var displayName: String { "OpenAI — \(Self.modelName)" }

    /// `apiKeyProvider` is called on every transcribe so a key that gets
    /// updated or removed mid-session is picked up without rebuilding.
    init(apiKeyProvider: @escaping () -> String?) {
        self.apiKeyProvider = apiKeyProvider
    }

    func transcribe(audioPath: String) throws -> String {
        guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
            throw TranscriptionError(message: "No OpenAI API key set. Open Murmur and add one.")
        }

        let fileURL = URL(fileURLWithPath: audioPath)
        let audioData = try Data(contentsOf: fileURL)

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(
            boundary: boundary,
            audio: audioData,
            filename: fileURL.lastPathComponent
        )

        // Bridge the async URLSession API to synchronous.
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
            throw TranscriptionError(message: "Network error: \(error.localizedDescription)")
        }
        guard let http = resultResponse as? HTTPURLResponse, let data = resultData else {
            throw TranscriptionError(message: "Empty response from OpenAI.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError(
                message: "OpenAI \(http.statusCode): \(Self.extractErrorMessage(body: body))"
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw TranscriptionError(message: "Malformed OpenAI response.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func multipartBody(boundary: String, audio: Data, filename: String) -> Data {
        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
                .data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        appendField(name: "model", value: modelName)
        appendField(name: "response_format", value: "json")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private static func extractErrorMessage(body: String) -> String {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any],
              let msg = err["message"] as? String else {
            return body.isEmpty ? "(no body)" : body
        }
        return msg
    }
}
