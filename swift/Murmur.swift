import Cocoa
import Carbon
import UserNotifications

// MARK: - Configuration

let projectDir = "\(NSHomeDirectory())/dev-projects/murmur"
let pythonPath = "\(projectDir)/.venv/bin/python"
let transcribeScript = "\(projectDir)/transcribe_cli.py"
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
    var tempAudioFile: String { "\(projectDir)/.murmur_recording.wav" }

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
        process.arguments = ["\(projectDir)/record_cli.py", tempAudioFile]
        process.currentDirectoryURL = URL(fileURLWithPath: projectDir)

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

        // Stop the recording process
        audioProcess?.interrupt()
        audioProcess?.waitUntilExit()
        audioProcess = nil

        logger.log("[INFO] Recording stopped")

        // Transcribe in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.transcribeAndPaste()
        }
    }

    func transcribeAndPaste() {
        logger.log("[INFO] Transcribing...")

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [transcribeScript, tempAudioFile, currentModel]
        process.currentDirectoryURL = URL(fileURLWithPath: projectDir)
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
