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

// MARK: - Online (OpenAI) — stub, wired up in PR 15

/// Placeholder for OpenAI gpt-4o-transcribe. Full URLSession + Keychain
/// implementation lands in PR 15 (feat/online-transcription).
class OpenAITranscriber: Transcriber {
    var displayName: String { "OpenAI — gpt-4o-transcribe" }

    func transcribe(audioPath: String) throws -> String {
        throw TranscriptionError(
            message: "OpenAI transcription is not implemented yet — coming in PR 15"
        )
    }
}
