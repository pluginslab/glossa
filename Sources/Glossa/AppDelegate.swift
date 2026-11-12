import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    enum State { case idle, recording(pushToTalk: Bool), transcribing }

    private var state: State = .idle
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let monitor = FnKeyMonitor()
    private let recorder = Recorder()
    private let ducker = AudioDucker()
    private var config = Config()
    private var contextBefore: String?
    private var stateMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var serverMenuItem: NSMenuItem!
    private var fallbackMenuItem: NSMenuItem!
    private var accessibilityPrompted = false

    /// Menu choice to send everything to the fallback server (a laptop that knows it is offline).
    private var preferFallback: Bool {
        get { UserDefaults.standard.bool(forKey: "preferFallback") }
        set { UserDefaults.standard.set(newValue, forKey: "preferFallback") }
    }

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
        refreshServerItems()
        contextBefore = config.useContext ? Context.textBeforeCursor(maxChars: config.contextChars) : nil
        // Before the recorder starts, so a combined input/output device (headset) is not mistaken for playback.
        ducker.duck(byPercent: config.duckPercent, onlyIfPlaying: config.duckOnlyIfPlaying)
        do {
            try recorder.start()
        } catch {
            Log.write("recorder failed: \(error)")
            ducker.restore()
            sound("Basso")
            return
        }
        setState(.recording(pushToTalk: pushToTalk))
        sound("Pop")
    }

    private func stopAndTranscribe() {
        let (wav, seconds) = recorder.stop()
        ducker.restore()
        guard seconds >= config.minSeconds else {
            Log.write("ignored \(String(format: "%.2f", seconds))s recording")
            setState(.idle)
            return
        }
        setState(.transcribing)
        let prompt = Context.prompt(glossary: Config.loadGlossary(), before: contextBefore)
        let transcriber = Transcriber(config: config)
        let preferFallback = preferFallback
        let started = Date()
        Task { @MainActor in
            do {
                let (raw, server) = try await transcriber.transcribe(wav: wav, prompt: prompt, preferFallback: preferFallback)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Log.write("transcribed \(String(format: "%.1f", seconds))s in \(ms) ms via \(server.role) \(server.label): \(raw.trimmingCharacters(in: .whitespacesAndNewlines))")
                lastServer = server
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

    private var lastServer: Server? { didSet { refreshServerItems() } }

    /// The "Server:" line and the fallback toggle, from the current config and the last answer.
    private func refreshServerItems() {
        let t = Transcriber(config: config)
        if let fb = t.fallback {
            fallbackMenuItem.isHidden = false
            fallbackMenuItem.state = preferFallback ? .on : .off
            let answered = lastServer.map { " · last: \($0.role)" } ?? ""
            serverMenuItem.title = preferFallback
                ? "Server: \(fb.label) (fallback, chosen)\(answered)"
                : "Server: \(t.primary.label), fallback \(fb.label)\(answered)"
        } else {
            fallbackMenuItem.isHidden = true
            serverMenuItem.title = "Server: \(t.primary.label)"
        }
    }

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
        serverMenuItem = NSMenuItem(title: "Server", action: nil, keyEquivalent: "")
        serverMenuItem.isEnabled = false
        menu.addItem(serverMenuItem)
        fallbackMenuItem = item("Use Fallback Server", #selector(toggleFallback))
        menu.addItem(fallbackMenuItem)
        refreshServerItems()
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
    @objc private func toggleFallback() {
        preferFallback.toggle()
        Log.write("fallback server \(preferFallback ? "chosen" : "automatic")")
        refreshServerItems()
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
