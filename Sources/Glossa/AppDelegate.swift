import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `command`: Shift was held, so what is said becomes a shell command (see `CommandAssist`).
    enum State { case idle, recording(pushToTalk: Bool, command: Bool), transcribing, composing }

    private var state: State = .idle
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let monitor = FnKeyMonitor()
    private let recorder = Recorder()
    private let ducker = AudioDucker()
    private var config = Config()
    private var contextBefore: String?
    private var snapshot = CommandAssist.Snapshot()
    private let notice = NoticePanel()
    private var commandMenuItem: NSMenuItem!
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
        case (.idle, .toggle(let command)): startRecording(pushToTalk: false, command: command)
        case (.idle, .holdStart(let command)): startRecording(pushToTalk: true, command: command)
        case (.recording(true, _), .holdEnd): stopAndTranscribe()
        case (.recording(false, _), .tap), (.recording(false, _), .toggle(_)), (.recording(false, _), .holdEnd): stopAndTranscribe()
        default: break
        }
    }

    private func applyMonitorConfig() {
        monitor.debug = config.debug
        monitor.micKeyCode = Int64(config.micKeyCode)
    }

    private func startRecording(pushToTalk: Bool, command: Bool = false) {
        config = Config.load()
        applyMonitorConfig()
        refreshServerItems()
        notice.hide()
        // A shell prompt isn't dictated text, so in command mode only the glossary prompts Whisper;
        // the screen and window title go to the command model instead.
        contextBefore = config.useContext && !command ? Context.textBeforeCursor(maxChars: config.contextChars) : nil
        if command { snapshot = CommandAssist.Snapshot.capture(screenLines: 30) }
        // Before the recorder starts, so a combined input/output device (headset) is not mistaken for playback.
        ducker.duck(byPercent: config.duckPercent, onlyIfPlaying: config.duckOnlyIfPlaying)
        do {
            try recorder.start()
        } catch {
            Log.write("recorder failed: \(error)")
            ducker.restore()
            sound(.failed)
            return
        }
        setState(.recording(pushToTalk: pushToTalk, command: command))
        sound(command ? .startCommand : pushToTalk ? .startHold : .startToggle)
    }

    private func stopAndTranscribe() {
        guard case .recording(_, let command) = state else { return }
        let (wav, seconds) = recorder.stop()
        ducker.restore()
        guard seconds >= config.minSeconds else {
            Log.write("ignored \(String(format: "%.2f", seconds))s recording")
            sound(.ignored)
            setState(.idle)
            return
        }
        setState(.transcribing)
        sound(.stop)
        let prompt = Context.prompt(glossary: Config.loadGlossary(), before: contextBefore)
        let transcriber = Transcriber(config: config)
        let preferFallback = preferFallback
        let started = Date()
        Task { @MainActor in
            do {
                let (heard, server) = try await transcriber.transcribe(wav: wav, prompt: prompt, preferFallback: preferFallback)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Log.write("transcribed \(String(format: "%.1f", seconds))s in \(ms) ms via \(server.role) \(server.label): \(heard.trimmingCharacters(in: .whitespacesAndNewlines))")
                lastServer = server
                let (raw, removed) = Hallucinations.strip(heard)
                if let removed { Log.write("dropped Whisper hallucination: \(removed)") }
                if command {
                    await runCommand(from: raw)
                } else {
                    sound(insert(raw) ? .inserted : .ignored)
                }
            } catch {
                Log.write("transcription failed: \(error.localizedDescription)")
                if command { notice.show("Transcription failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle", seconds: 6) }
                sound(.failed)
            }
            setState(.idle)
        }
    }

    /// One round: the request and the terminal's context to the model; its one command is
    /// pasted without Return, or its question shown in the notice.
    @MainActor
    private func runCommand(from raw: String) async {
        let request = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if request.isEmpty || (request.hasPrefix("[") && request.hasSuffix("]")) || (request.hasPrefix("(") && request.hasSuffix(")")) { sound(.ignored); return }
        guard let endpoint = CommandAssist.endpoint(from: config) else {
            Log.write("voice command: \(CommandAssist.AssistError.notConfigured.localizedDescription)")
            notice.show("Voice commands need assistEndpoint in config.json.", symbol: "exclamationmark.triangle", seconds: 8)
            sound(.failed)
            return
        }
        setState(.composing)
        notice.show("“\(request)”")
        let started = Date()
        do {
            let outcome = try await CommandAssist(endpoint: endpoint).compose(request: request, snapshot: snapshot) { [weak self] text in
                guard let self, case .composing = self.state else { return }
                self.notice.show(text.isEmpty ? "“\(request)”" : text)
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Log.write("voice command in \(ms) ms via \(endpoint.model): “\(request)” -> \(outcome)")
            switch outcome {
            case .command(let c):
                Inserter.paste(c)
                if let warning = CommandAssist.warning(for: c) {
                    notice.show(warning, symbol: "exclamationmark.triangle", seconds: 10)
                    sound(.warning)
                } else {
                    notice.hide()
                    sound(.commandPasted)
                }
            case .ask(let q):
                notice.show(q, symbol: "questionmark.bubble", seconds: 10)
                sound(.ask)
            }
        } catch {
            Log.write("voice command failed: \(error.localizedDescription)")
            notice.show("Voice command failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle", seconds: 8)
            sound(.failed)
        }
    }

    /// False when there was nothing to insert (silence, only a dropped hallucination).
    @discardableResult
    private func insert(_ raw: String) -> Bool {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        // Whisper's non-speech markers: [BLANK_AUDIO], (silence), [Music] …
        if (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")")) { return false }
        if let before = contextBefore, let last = before.last,
           !last.isWhitespace, !"([{\"'“‘".contains(last) {
            text = " " + text
        }
        Inserter.paste(text)
        return true
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
            stateMenuItem.title = "Idle — mic key, double-tap or hold Fn; add Shift for a command"
            toggleMenuItem.title = "Start Recording"
            commandMenuItem.isHidden = false
        case .recording(_, let command):
            setIcon(command ? "apple.terminal.fill" : "mic.fill", tint: .systemRed)
            stateMenuItem.title = command ? "Recording a command…" : "Recording…"
            toggleMenuItem.title = "Stop & Transcribe"
            commandMenuItem.isHidden = true
        case .transcribing:
            setIcon("ellipsis.circle", tint: nil)
            stateMenuItem.title = "Transcribing…"
            toggleMenuItem.title = "Transcribing…"
            commandMenuItem.isHidden = true
        case .composing:
            setIcon("apple.terminal", tint: nil)
            stateMenuItem.title = "Writing the command…"
            toggleMenuItem.title = "Writing the command…"
            commandMenuItem.isHidden = true
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
        commandMenuItem = item("Start Voice Command", #selector(commandFromMenu))
        menu.addItem(commandMenuItem)
        menu.addItem(.separator())
        serverMenuItem = NSMenuItem(title: "Server", action: nil, keyEquivalent: "")
        serverMenuItem.isEnabled = false
        menu.addItem(serverMenuItem)
        fallbackMenuItem = item("Use Fallback Server", #selector(toggleFallback))
        menu.addItem(fallbackMenuItem)
        refreshServerItems()
        menu.addItem(.separator())
        menu.addItem(item("Edit Glossary…", #selector(openGlossary)))
        menu.addItem(item("Edit Setup Notes…", #selector(openSetup)))
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
        case .transcribing, .composing: break
        }
    }
    /// From the menu the frontmost app is still the one you were in (a menu doesn't take focus).
    @objc private func commandFromMenu() {
        if case .idle = state { startRecording(pushToTalk: false, command: true) }
    }
    @objc private func toggleFallback() {
        preferFallback.toggle()
        Log.write("fallback server \(preferFallback ? "chosen" : "automatic")")
        refreshServerItems()
    }
    @objc private func openGlossary() { NSWorkspace.shared.open(Config.glossaryURL) }
    @objc private func openSetup() { Config.ensureFiles(); NSWorkspace.shared.open(Config.setupURL) }
    @objc private func openConfig() { NSWorkspace.shared.open(Config.configURL) }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func quit() { NSApp.terminate(nil) }

    private let sounds = SoundPlayer()

    private func sound(_ e: Earcon) {
        guard config.sounds else { return }
        sounds.play(e)
    }
}
