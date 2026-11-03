import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    enum State { case idle, recording(pushToTalk: Bool), transcribing }

    private var state: State = .idle
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let monitor = FnKeyMonitor()
    private let recorder = Recorder()
    private var config = Config()
    private var contextBefore: String?
    private var stateMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var accessibilityPrompted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("--- Glossa launched")
        Config.ensureFiles()
        config = Config.load()
        buildMenu()
        setIcon("mic.slash", tint: nil)
        AVCaptureDevice.requestAccess(for: .audio) { ok in Log.write("microphone access: \(ok)") }
        monitor.onAction = { [weak self] action in self?.handle(action) }
        applyMonitorConfig()
        armEventTap()
    }

    // MARK: - Permissions / event tap

    private func armEventTap() {
        let trusted: Bool
        if accessibilityPrompted {
            trusted = AXIsProcessTrusted()
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(opts)
            accessibilityPrompted = true
        }
        if trusted, monitor.start() {
            Log.write("event tap active (endpoint \(config.endpoint))")
            setState(.idle)
            return
        }
        stateMenuItem.title = "Waiting for Accessibility permission…"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.armEventTap() }
    }

    // MARK: - Hotkey state machine

    private func handle(_ action: FnKeyMonitor.Action) {
        switch (state, action) {
        case (.idle, .toggle): startRecording(pushToTalk: false)
        case (.idle, .holdStart): startRecording(pushToTalk: true)
        case (.recording(true), .holdEnd): stopAndTranscribe()
        case (.recording(false), .tap), (.recording(false), .toggle), (.recording(false), .holdEnd): stopAndTranscribe()
        default: break
        }
    }

    private func applyMonitorConfig() {
        monitor.debug = config.debug
        monitor.micKeyCode = Int64(config.micKeyCode)
    }

    private func startRecording(pushToTalk: Bool) {
        config = Config.load()
        applyMonitorConfig()
        contextBefore = config.useContext ? Context.textBeforeCursor(maxChars: config.contextChars) : nil
        do {
            try recorder.start()
        } catch {
            Log.write("recorder failed: \(error)")
            sound("Basso")
            return
        }
        setState(.recording(pushToTalk: pushToTalk))
        sound("Pop")
    }

    private func stopAndTranscribe() {
        let (wav, seconds) = recorder.stop()
        guard seconds >= config.minSeconds else {
            Log.write("ignored \(String(format: "%.2f", seconds))s recording")
            setState(.idle)
            return
        }
        setState(.transcribing)
        let prompt = Context.prompt(glossary: Config.loadGlossary(), before: contextBefore)
        let transcriber = Transcriber(config: config)
        let started = Date()
        Task { @MainActor in
            do {
                let raw = try await transcriber.transcribe(wav: wav, prompt: prompt)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Log.write("transcribed \(String(format: "%.1f", seconds))s in \(ms) ms: \(raw.trimmingCharacters(in: .whitespacesAndNewlines))")
                insert(raw)
                sound("Tink")
            } catch {
                Log.write("transcription failed: \(error.localizedDescription)")
                sound("Basso")
            }
            setState(.idle)
        }
    }

    private func insert(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Whisper's non-speech markers: [BLANK_AUDIO], (silence), [Music] …
        if (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")")) { return }
        if let before = contextBefore, let last = before.last,
           !last.isWhitespace, !"([{\"'“‘".contains(last) {
            text = " " + text
        }
        Inserter.paste(text)
    }

    // MARK: - UI

    private func setState(_ s: State) {
        state = s
        switch s {
        case .idle:
            setIcon("mic", tint: nil)
            stateMenuItem.title = "Idle — press the mic key, double-tap Fn, or hold Fn"
            toggleMenuItem.title = "Start Recording"
        case .recording:
            setIcon("mic.fill", tint: .systemRed)
            stateMenuItem.title = "Recording…"
            toggleMenuItem.title = "Stop & Transcribe"
        case .transcribing:
            setIcon("ellipsis.circle", tint: nil)
            stateMenuItem.title = "Transcribing…"
            toggleMenuItem.title = "Transcribing…"
        }
    }

    private func setIcon(_ symbol: String, tint: NSColor?) {
        guard let button = statusItem.button,
              var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Glossa") else { return }
        if let tint {
            image = image.withSymbolConfiguration(.init(paletteColors: [tint])) ?? image
            image.isTemplate = false
        } else {
            image.isTemplate = true
        }
        button.image = image
    }

    private func buildMenu() {
        let menu = NSMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let about = NSMenuItem(title: "Glossa \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        stateMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        stateMenuItem.isEnabled = false
        menu.addItem(stateMenuItem)
        toggleMenuItem = NSMenuItem(title: "Start Recording", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)
        menu.addItem(.separator())
        menu.addItem(item("Edit Glossary…", #selector(openGlossary)))
        menu.addItem(item("Edit Config…", #selector(openConfig)))
        menu.addItem(item("Open Log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Glossa", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleFromMenu() {
        switch state {
        case .idle: startRecording(pushToTalk: false)
        case .recording: stopAndTranscribe()
        case .transcribing: break
        }
    }
    @objc private func openGlossary() { NSWorkspace.shared.open(Config.glossaryURL) }
    @objc private func openConfig() { NSWorkspace.shared.open(Config.configURL) }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func sound(_ name: String) {
        guard config.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
