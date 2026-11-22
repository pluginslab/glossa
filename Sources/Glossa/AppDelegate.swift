import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    private var liveMenuItem: NSMenuItem!

    /// Type While Speaking: dictation appears as you talk, its changing end rewritten.
    private var liveTyping: Bool {
        get { UserDefaults.standard.bool(forKey: "liveTyping") }
        set { UserDefaults.standard.set(newValue, forKey: "liveTyping") }
    }
    private let live = LiveTyper()
    private var liveTask: Task<Void, Never>?
    /// This recording types live (the menu setting when it started, never for commands).
    private var liveThisRecording = false
    private var transcript = LiveTranscript()

    /// Microphone chosen in the menu (a Core Audio device UID); nil follows the system default.
    private var inputDeviceUID: String? {
        get { UserDefaults.standard.string(forKey: "inputDeviceUID") }
        set { UserDefaults.standard.set(newValue, forKey: "inputDeviceUID") }
    }
    private let micMenu = NSMenu()

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
        monitor.onUserKey = { [weak self] what in
            guard let self, self.liveThisRecording, case .recording = self.state else { return }
            self.live.freeze(what)
        }
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
            try recorder.start(deviceUID: inputDeviceUID)
        } catch {
            Log.write("recorder failed: \(error)")
            ducker.restore()
            sound(.failed)
            return
        }
        setState(.recording(pushToTalk: pushToTalk, command: command))
        sound(command ? .startCommand : pushToTalk ? .startHold : .startToggle)
        liveThisRecording = liveTyping && !command
        if liveThisRecording { startLiveTyping() }
    }

    /// Every `liveInterval` seconds, the audio so far goes to Whisper and the typed text
    /// follows the answer. One pass at a time; a slow server just means fewer passes.
    private func startLiveTyping() {
        live.begin(leadingSpace: needsLeadingSpace)
        transcript = LiveTranscript()
        let glossary = Config.loadGlossary()
        let transcriber = Transcriber(config: config)
        let preferFallback = preferFallback
        let interval = max(0.3, config.liveInterval)
        liveTask?.cancel()
        liveTask = Task { @MainActor [weak self] in
            var passes = 0
            var heardUpTo = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled, case .recording = self.state, !self.live.frozen else { return }
                // Only the audio after the sentences already locked (all of it without timestamps).
                let start = self.transcript.offset
                let snap = self.recorder.snapshot(from: start)
                // Wait for a second of audio with speech in it.
                guard snap.seconds >= 1.0, snap.peakDB > -55 else { continue }
                // A pause: nothing new since the last pass, so nothing to change.
                guard start + snap.seconds > heardUpTo + 0.15 else { continue }
                heardUpTo = start + snap.seconds
                let prompt = self.livePrompt(glossary: glossary)
                do {
                    let (heard, segments) = try await transcriber.quick(wav: snap.wav, prompt: prompt, preferFallback: preferFallback)
                    guard !Task.isCancelled, case .recording = self.state else { return }
                    let text = Hallucinations.strip(heard, glossary: glossary).text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty, !Self.isMarker(text) else { continue }
                    let cleanSegments = segments?.filter { !Hallucinations.strip($0.text, glossary: glossary).text.isEmpty }
                    self.transcript.ingest(text: text, segments: cleanSegments)
                    self.live.update(locked: self.transcript.locked, tentative: self.transcript.tentative)
                    passes += 1
                } catch {
                    if case TranscribeError.http(429, _) = error {
                        // Over the key's requests-per-minute limit: stop live passes for a
                        // while so the final pass still gets through.
                        Log.write("live passes paused for 15 s: the server's rate limit (HTTP 429)")
                        try? await Task.sleep(for: .seconds(15))
                    } else if passes == 0 {
                        Log.write("live pass failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// Whisper's prompt for a live window: the glossary, then what came before it (the text
    /// before the cursor and the sentences already locked), so the window continues it.
    private func livePrompt(glossary: [String]) -> String {
        let before = LiveTranscript.join(contextBefore ?? "", transcript.promptTail)
        return Context.prompt(glossary: glossary, before: String(before.suffix(300)))
    }

    /// Whisper's non-speech markers: [BLANK_AUDIO], (silence), [Music] …
    private static func isMarker(_ text: String) -> Bool {
        (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")"))
    }

    /// The text before the cursor ends in a word, so dictation starts with a space.
    private var needsLeadingSpace: Bool {
        guard let last = contextBefore?.last else { return false }
        return !last.isWhitespace && !"([{\"'“‘".contains(last)
    }

    private func stopAndTranscribe() {
        guard case .recording(_, let command) = state else { return }
        liveTask?.cancel(); liveTask = nil
        let liveRun = liveThisRecording
        liveThisRecording = false
        var (wav, seconds, peakDB) = recorder.stop()
        ducker.restore()
        // Even a quiet room is around -70 dBFS; well below that the microphone sent nothing,
        // and Whisper would answer silence with the glossary ("Ploi, DigitalOcean, Xcode, …").
        if peakDB < config.silenceDB {
            Log.write(String(format: "microphone sent silence (%.0f dBFS, %.1fs) from %@: not sent", peakDB, seconds, recorder.inputName))
            notice.show("The microphone sent silence (\(recorder.inputName)). Pick another in Glossa → Microphone, or check System Settings → Sound.",
                        symbol: "mic.slash", seconds: 8)
            sound(.failed)
            setState(.idle)
            return
        }
        guard seconds >= config.minSeconds else {
            Log.write("ignored \(String(format: "%.2f", seconds))s recording")
            sound(.ignored)
            setState(.idle)
            return
        }
        setState(.transcribing)
        sound(.stop)
        let glossary = Config.loadGlossary()
        var prompt = Context.prompt(glossary: glossary, before: contextBefore)
        // Live typing locked sentences up to `offset`: only the rest needs the final pass.
        if liveRun, transcript.offset > 0 {
            wav = recorder.snapshot(from: transcript.offset, keep: 0.5).wav
            prompt = livePrompt(glossary: glossary)
        }
        let transcriber = Transcriber(config: config)
        let preferFallback = preferFallback
        let started = Date()
        Task { @MainActor in
            do {
                let (heard, server) = try await transcriber.transcribe(wav: wav, prompt: prompt, preferFallback: preferFallback)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                Log.write("transcribed \(String(format: "%.1f", seconds))s in \(ms) ms via \(server.role) \(server.label): \(heard.trimmingCharacters(in: .whitespacesAndNewlines))")
                lastServer = server
                let (raw, removed) = Hallucinations.strip(heard, glossary: glossary)
                if let removed { Log.write("dropped Whisper hallucination: \(removed)") }
                if command {
                    await runCommand(from: raw)
                } else if liveRun && (live.isActive || live.frozen) {
                    finishLive(transcript.final(with: Self.isMarker(raw) ? "" : raw))
                } else {
                    sound(insert(raw) ? .inserted : .ignored)
                }
            } catch {
                Log.write("transcription failed: \(error.localizedDescription)")
                if liveRun && live.isActive { notice.show("Transcription failed: the text typed so far is what was heard live.", symbol: "exclamationmark.triangle", seconds: 6) }
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

    /// The final pass replaces the live text. If editing froze (focus moved, a key pressed),
    /// nothing more is typed: the full text goes to the clipboard instead.
    private func finishLive(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isMarker(text) { text = "" }
        if live.finish(with: text) {
            sound(text.isEmpty ? .ignored : .inserted)
        } else {
            if !text.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            notice.show("Glossa stopped typing when you clicked or pressed a key. The full text is on the clipboard: ⌘V to paste it.",
                        symbol: "doc.on.clipboard", seconds: 8)
            sound(.warning)
        }
    }

    /// False when there was nothing to insert (silence, only a dropped hallucination).
    @discardableResult
    private func insert(_ raw: String) -> Bool {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        // Whisper's non-speech markers: [BLANK_AUDIO], (silence), [Music] …
        if (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")")) { return false }
        if needsLeadingSpace { text = " " + text }
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
        let mic = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micMenu.delegate = self
        mic.submenu = micMenu
        menu.addItem(mic)
        serverMenuItem = NSMenuItem(title: "Server", action: nil, keyEquivalent: "")
        serverMenuItem.isEnabled = false
        menu.addItem(serverMenuItem)
        fallbackMenuItem = item("Use Fallback Server", #selector(toggleFallback))
        menu.addItem(fallbackMenuItem)
        liveMenuItem = item("Type While Speaking", #selector(toggleLive))
        liveMenuItem.state = liveTyping ? .on : .off
        menu.addItem(liveMenuItem)
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
    /// Rebuilt each time it opens, so plugged-in and removed devices show up.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === micMenu else { return }
        menu.removeAllItems()
        let devices = AudioDevices.inputs()
        let chosen = inputDeviceUID
        let chosenMissing = chosen != nil && !devices.contains { $0.uid == chosen }
        let defaultName = AudioDevices.defaultInput.flatMap(AudioDevices.name(of:)) ?? "none"
        let sys = NSMenuItem(title: "System Default (\(defaultName))", action: #selector(chooseMic(_:)), keyEquivalent: "")
        sys.target = self
        sys.state = chosen == nil ? .on : .off
        menu.addItem(sys)
        menu.addItem(.separator())
        for d in devices {
            let i = NSMenuItem(title: d.name, action: #selector(chooseMic(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = d.uid
            i.state = d.uid == chosen ? .on : .off
            menu.addItem(i)
        }
        if chosenMissing {
            menu.addItem(.separator())
            let note = NSMenuItem(title: "Chosen microphone not connected: using the default", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
    }

    @objc private func chooseMic(_ sender: NSMenuItem) {
        inputDeviceUID = sender.representedObject as? String
        Log.write("microphone: \(sender.title)")
    }

    @objc private func toggleLive() {
        liveTyping.toggle()
        liveMenuItem.state = liveTyping ? .on : .off
        Log.write("type while speaking \(liveTyping ? "on" : "off")")
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
