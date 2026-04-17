import Cocoa
import Carbon
import Darwin
import UserNotifications

// MARK: - Configuration

/// Python scripts are bundled inside Murmur.app/Contents/Resources/.
/// The .venv path is read from Info.plist (MurmurVenvPath), written at build time by build_app.sh.
/// This means the app works from /Applications regardless of where the repo is cloned.

let bundle = Bundle.main
let resourcePath = bundle.resourcePath!

// Python scripts — always found inside the bundle
let recordScript    = "\(resourcePath)/record_cli.py"
let transcribeScript = "\(resourcePath)/transcribe_cli.py"

// Python interpreter resolution, in priority order:
//   1. Bundled venv inside Resources/venv — lets the .app be distributed
//      standalone (e.g. via GitHub Releases).
//   2. MurmurVenvPath from Info.plist — the absolute dev-machine venv path
//      written at build time. Used when the bundled venv is absent.
//   3. Sibling .venv next to the .app — last-resort fallback for running
//      straight out of the repo.
let pythonPath: String = {
    let fm = FileManager.default
    let bundledVenv = "\(resourcePath)/venv/bin/python"
    if fm.fileExists(atPath: bundledVenv) {
        return bundledVenv
    }
    if let venv = bundle.infoDictionary?["MurmurVenvPath"] as? String {
        return "\(venv)/bin/python"
    }
    let appDir = bundle.bundlePath.components(separatedBy: "/").dropLast().joined(separator: "/")
    return "\(appDir)/.venv/bin/python"
}()

let logPath = "\(NSHomeDirectory())/Library/Logs/Murmur.log"

// MARK: - Logger

class Logger {
    static let shared = Logger()
    private let handle: FileHandle?

    init() {
        FileManager.default.createFile(atPath: logPath, contents: nil)
        handle = FileHandle(forWritingAtPath: logPath)
        handle?.seekToEndOfFile()
    }

    func log(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "\(ts) \(msg)\n"
        print(line, terminator: "")
        handle?.write(line.data(using: .utf8)!)
    }
}

let logger = Logger.shared

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var toggleItem: NSMenuItem!
    var isRecording = false
    var audioProcess: Process?
    var tempAudioFile: String {
        let tmp = FileManager.default.temporaryDirectory
        return "\(tmp.path)/murmur_recording.wav"
    }

    // Model selection
    var currentModel = "mlx-community/whisper-base-mlx"
    let models: [(label: String, id: String)] = [
        ("Tiny  (fastest)", "mlx-community/whisper-tiny-mlx"),
        ("Base  (balanced)", "mlx-community/whisper-base-mlx"),
        ("Small (accurate)", "mlx-community/whisper-small-mlx"),
    ]

    // Active transcription backend — rebuilt whenever the user changes model.
    // Currently always a LocalMLXTranscriber; OpenAITranscriber joins the
    // roster in PR 15.
    var transcriber: Transcriber!

    // Main window's observable state + controller. The window is created
    // lazily the first time the user opens it.
    var appState: AppState!
    var mainWindowController: MainWindowController!

    /// Build a Transcriber for the given local model ID. Kept as a factory
    /// so PR 15 can extend this to return an OpenAITranscriber when the user
    /// picks the online option.
    func makeTranscriber(forLocalModel modelID: String) -> Transcriber {
        // Extract a short label like "Tiny"/"Base"/"Small" from the menu
        // label corresponding to this model ID. Falls back to the ID.
        let label = models.first { $0.id == modelID }
            .map { $0.label.split(separator: " ").first.map(String.init) ?? $0.label }
            ?? modelID
        return LocalMLXTranscriber(
            modelID: modelID,
            modelLabel: label,
            pythonPath: pythonPath,
            scriptPath: transcribeScript,
            workingDir: resourcePath
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Build the initial transcriber for the default model.
        transcriber = makeTranscriber(forLocalModel: currentModel)

        // Build the observable state for the main window. When the user
        // picks a model in the window, rebuild the transcriber.
        appState = AppState(currentModelID: currentModel, localModels: models)
        appState.onLocalModelChange = { [weak self] modelID in
            guard let self = self else { return }
            self.currentModel = modelID
            self.transcriber = self.makeTranscriber(forLocalModel: modelID)
            logger.log("[INFO] Model changed to \(self.transcriber.displayName) (\(modelID))")
        }
        mainWindowController = MainWindowController(state: appState)

        // Request notification permission
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // Check Accessibility — prompt if not granted
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        )
        if !trusted {
            logger.log("[INFO] Accessibility permission not yet granted — will prompt")
        } else {
            logger.log("[INFO] Accessibility permission granted")
        }

        // Menu bar setup
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎤"

        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Start Recording  (fn)", action: #selector(toggleRecording), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // Model selection and history now live in the main window.
        let openWindowItem = NSMenuItem(
            title: "Open Murmur…",
            action: #selector(openMainWindow),
            keyEquivalent: ","
        )
        openWindowItem.target = self
        menu.addItem(openWindowItem)

        menu.addItem(.separator())

        // Version (read from Info.plist, injected at build time from the VERSION file)
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"

        let aboutItem = NSMenuItem(title: "About Murmur", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu

        // Register fn key hotkey
        NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // Also monitor Option+Space
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 49 && event.modifierFlags.contains(.option) {
                DispatchQueue.main.async { self?.toggleRecording() }
            }
        }

        logger.log("[INFO] Murmur v\(version) started")
    }

    // MARK: - fn key handling

    var fnWasDown = false

    func handleFlagsChanged(_ event: NSEvent) {
        let fnDown = event.modifierFlags.contains(.function)
        if fnDown && !fnWasDown {
            DispatchQueue.main.async { [weak self] in self?.toggleRecording() }
        }
        fnWasDown = fnDown
    }

    // MARK: - Recording

    @objc func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        isRecording = true
        statusItem.button?.title = "🔴"
        toggleItem.title = "Stop Recording  (fn)"

        // Play start sound
        NSSound(named: "Tink")?.play()

        // Record audio using sox (comes with macOS via brew, or use rec)
        // Fallback: use Python script for recording
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [recordScript, tempAudioFile]
        process.currentDirectoryURL = URL(fileURLWithPath: resourcePath)

        do {
            try process.run()
            audioProcess = process
            logger.log("[INFO] Recording started")
        } catch {
            logger.log("[ERROR] Failed to start recording: \(error)")
            resetUI()
        }
    }

    func stopRecording() {
        isRecording = false
        statusItem.button?.title = "⏳"
        toggleItem.title = "Processing…"

        // Play stop sound
        NSSound(named: "Pop")?.play()

        // Hand off the recorder to a background queue so the main thread
        // stays responsive even if the subprocess is slow to exit.
        let process = audioProcess
        audioProcess = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.shutdownRecorder(process)
            logger.log("[INFO] Recording stopped")
            self?.transcribeAndPaste()
        }
    }

    /// Escalate through SIGINT → SIGTERM → SIGKILL so a wedged recorder
    /// can never hang the app the way it did before this fix.
    func shutdownRecorder(_ process: Process?) {
        guard let process = process, process.isRunning else { return }

        process.interrupt()  // SIGINT — graceful stop
        if waitForExit(process, timeout: 2.0) { return }

        logger.log("[WARNING] Recorder ignored SIGINT — sending SIGTERM")
        process.terminate()  // SIGTERM
        if waitForExit(process, timeout: 1.0) { return }

        logger.log("[WARNING] Recorder ignored SIGTERM — sending SIGKILL")
        if kill(process.processIdentifier, SIGKILL) != 0 {
            let err = errno
            let msg = String(cString: strerror(err))
            logger.log("[ERROR] SIGKILL failed for pid \(process.processIdentifier): errno \(err) (\(msg))")
            return
        }
        if waitForExit(process, timeout: 1.0) { return }
        logger.log("[ERROR] Recorder did not exit within timeout after SIGKILL — giving up")
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    func transcribeAndPaste() {
        let backend = transcriber!  // snapshot so a mid-transcription model change is harmless
        logger.log("[INFO] Transcribing via \(backend.displayName)...")

        let text: String
        do {
            text = try backend.transcribe(audioPath: tempAudioFile)
        } catch {
            logger.log("[ERROR] Transcription failed: \(error)")
            DispatchQueue.main.async { self.resetUI() }
            return
        }

        logger.log("[INFO] Result: \"\(text)\"")

        // Persist to history (no-op for empty text; store trims & skips).
        let modelName = backend.displayName
        DispatchQueue.main.async {
            self.appState.history.append(modelDisplayName: modelName, text: text)
        }

        if text.isEmpty {
            DispatchQueue.main.async {
                self.showNotification(title: "Murmur", body: "No speech detected")
                self.resetUI()
            }
            return
        }

        // Copy to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        if AXIsProcessTrusted() {
            simulatePaste()
            logger.log("[INFO] Pasted via CGEvent")
            DispatchQueue.main.async {
                self.showNotification(title: "Murmur", body: text)
                self.resetUI()
            }
        } else {
            logger.log("[WARNING] No Accessibility — clipboard only")
            DispatchQueue.main.async {
                self.showNotification(title: "Murmur — Copied", body: "\(text)\n\nPress Cmd+V to paste")
                self.resetUI()
            }
        }
    }

    func simulatePaste() {
        let vKeyCode: CGKeyCode = 9
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) else { return }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    func showNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(120))
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func resetUI() {
        isRecording = false
        audioProcess = nil
        statusItem.button?.title = "🎤"
        toggleItem.title = "Start Recording  (fn)"
    }

    // MARK: - About

    @objc func showAbout() {
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let copyright = bundle.infoDictionary?["NSHumanReadableCopyright"] as? String
            ?? "© 2026 2M Tech"

        // Credits: MIT license notice, shown in the scrollable area of the About panel.
        let credits = """
        Murmur — local voice-to-text dictation for macOS.

        Licensed under the MIT License.

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.
        """

        let creditsAttr = NSAttributedString(
            string: credits,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
            ]
        )

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "Murmur",
            .applicationVersion: version,
            .version: version,
            .credits: creditsAttr,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright,
        ]

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    // MARK: - Main window

    @objc func openMainWindow() {
        mainWindowController.show()
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // No dock icon
app.run()
