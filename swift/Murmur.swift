import Cocoa
import Carbon
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

// .venv path — encoded in Info.plist at build time
let pythonPath: String = {
    if let venv = bundle.infoDictionary?["MurmurVenvPath"] as? String {
        return "\(venv)/bin/python"
    }
    // Fallback: look next to the .app bundle
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        let modelMenu = NSMenu()
        for (i, model) in models.enumerated() {
            let item = NSMenuItem(title: model.label, action: #selector(selectModel(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = model.id == currentModel ? .on : .off
            modelMenu.addItem(item)
        }
        let modelItem = NSMenuItem(title: "Whisper Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        menu.addItem(.separator())
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

        logger.log("[INFO] Murmur started")
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
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    func transcribeAndPaste() {
        logger.log("[INFO] Transcribing...")

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [transcribeScript, tempAudioFile, currentModel]
        process.currentDirectoryURL = URL(fileURLWithPath: resourcePath)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.log("[ERROR] Transcription failed: \(error)")
            DispatchQueue.main.async { self.resetUI() }
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        logger.log("[INFO] Result: \"\(text)\"")

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

    // MARK: - Model selection

    @objc func selectModel(_ sender: NSMenuItem) {
        currentModel = models[sender.tag].id
        if let menu = sender.menu {
            for item in menu.items { item.state = .off }
        }
        sender.state = .on
        logger.log("[INFO] Model changed to \(currentModel)")
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // No dock icon
app.run()
