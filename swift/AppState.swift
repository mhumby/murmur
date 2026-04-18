import SwiftUI

/// Observable state for the main window's SwiftUI view hierarchy.
/// AppDelegate owns the canonical transcriber and wires the
/// `onBackendChange` callback so UI-driven selection rebuilds it.
class AppState: ObservableObject {
    /// Currently-selected local model ID (e.g. "mlx-community/whisper-base-mlx").
    /// Still tracked while `useOnline` is true so flipping back restores the
    /// previous local choice.
    @Published var currentModelID: String

    /// `true` when the user has picked the online (OpenAI) backend.
    /// When false, the active backend is the local model at `currentModelID`.
    @Published var useOnline: Bool = false

    /// All local Whisper models the user can choose from.
    let localModels: [(label: String, id: String)]

    /// Persistent transcription history. Observed by the UI and appended to
    /// by AppDelegate after each successful transcription.
    let history: HistoryStore

    /// API keys and user preferences (Keychain-backed).
    let settings: SettingsStore

    /// Fires whenever the active backend changes — either the local model ID
    /// or a flip between local and online. AppDelegate uses this to rebuild
    /// the `Transcriber`.
    var onBackendChange: ((_ useOnline: Bool, _ localModelID: String) -> Void)?

    init(
        currentModelID: String,
        localModels: [(label: String, id: String)],
        history: HistoryStore = HistoryStore(),
        settings: SettingsStore = SettingsStore()
    ) {
        self.currentModelID = currentModelID
        self.localModels = localModels
        self.history = history
        self.settings = settings
    }

    /// Entry point for UI to select a local model. Also flips `useOnline` off.
    func selectLocal(_ modelID: String) {
        let changed = useOnline || currentModelID != modelID
        currentModelID = modelID
        useOnline = false
        if changed {
            onBackendChange?(false, modelID)
        }
    }

    /// Entry point for UI to select the online (OpenAI) backend.
    func selectOnline() {
        guard !useOnline else { return }
        useOnline = true
        onBackendChange?(true, currentModelID)
    }
}
