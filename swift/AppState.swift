import SwiftUI

/// Observable state for the main window's SwiftUI view hierarchy.
/// AppDelegate owns the canonical state (`currentModel`, `transcriber`) and
/// wires the `onLocalModelChange` callback so UI-driven changes rebuild the
/// active Transcriber.
class AppState: ObservableObject {
    /// Currently-selected model ID (e.g. "mlx-community/whisper-base-mlx").
    /// Mutations are expected on the main thread (SwiftUI-driven).
    @Published var currentModelID: String

    /// All local Whisper models the user can choose from.
    let localModels: [(label: String, id: String)]

    /// Fires when the user picks a different local model. AppDelegate hooks
    /// this up to rebuild `transcriber` via `makeTranscriber(forLocalModel:)`.
    var onLocalModelChange: ((String) -> Void)?

    init(currentModelID: String, localModels: [(label: String, id: String)]) {
        self.currentModelID = currentModelID
        self.localModels = localModels
    }

    /// Entry point for UI to select a local model. Updates state and fires
    /// the change callback so the transcription backend stays in sync.
    func selectLocal(_ modelID: String) {
        guard currentModelID != modelID else { return }
        currentModelID = modelID
        onLocalModelChange?(modelID)
    }
}
