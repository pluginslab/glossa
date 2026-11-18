import AppKit

/// Voice commands: Shift with the mic key (or with Fn) turns what you say into one shell
/// command instead of the words. What you said, plus where you are (the frontmost app, its
/// window title, the last lines on screen, this Mac's host, user and shell), goes to a chat
/// model once, and the one command it answers with is pasted without Return. You read it
/// and press return yourself. One round: it gets it or it asks, never a follow-up.
///
/// Same contract as Smart Terminal's voice commands (its `CommandAssist`), so one prompt
/// and one llm-router alias serve both.
struct CommandAssist {
    struct Endpoint {
        let url: String
        let apiKey: String
        let model: String
    }

    enum Outcome: Equatable {
        case command(String)
        case ask(String)
    }

    enum AssistError: LocalizedError {
        case notConfigured, badEndpoint(String), http(Int, String), empty
        var errorDescription: String? {
            switch self {
            case .notConfigured: "no assistEndpoint in config.json (and endpoint is not an OpenAI-style /v1/audio/transcriptions URL to derive one from)"
            case .badEndpoint(let e): "assistEndpoint is not a URL: \(e)"
            case .http(let code, let body): "HTTP \(code): \(body.prefix(200))"
            case .empty: "no command came back"
            }
        }
    }

    /// `assistEndpoint` from the config, or, when it is empty and `endpoint` is an
    /// OpenAI-style transcription URL (llm-router, LiteLLM), the chat URL next to it with
    /// the same key.
    static func endpoint(from config: Config) -> Endpoint? {
        if !config.assistEndpoint.isEmpty {
            return Endpoint(url: config.assistEndpoint,
                            apiKey: config.assistApiKey.isEmpty ? config.apiKey : config.assistApiKey,
                            model: config.assistModel)
        }
        let marker = "/v1/audio/transcriptions"
        guard let r = config.endpoint.range(of: marker) else { return nil }
        let url = config.endpoint.replacingCharacters(in: r, with: "/v1/chat/completions")
        return Endpoint(url: url, apiKey: config.assistApiKey.isEmpty ? config.apiKey : config.assistApiKey,
                        model: config.assistModel)
    }

    // MARK: - Context

    /// What we know about where the command will land, gathered when recording starts
    /// (before focus can move).
    struct Snapshot {
        var app = ""
        var windowTitle = ""
        var screen = ""
        /// The user's own notes (`setup.txt`): hosts, aliases, habits.
        var setup = ""

        static func capture(screenLines: Int) -> Snapshot {
            var s = Snapshot()
            s.setup = Config.loadSetup()
            let front = NSWorkspace.shared.frontmostApplication
            s.app = front?.localizedName ?? ""
            if let pid = front?.processIdentifier {
                s.windowTitle = Context.focusedWindowTitle(pid: pid) ?? ""
            }
            s.screen = Context.screenText(lines: screenLines) ?? ""
            return s
        }

        /// The machine part is this Mac's; the screen says if the terminal is somewhere else (ssh).
        var description: String {
            var lines: [String] = []
            let pi = ProcessInfo.processInfo
            let os = pi.operatingSystemVersion
            lines.append("local machine: \(Host.current().localizedName ?? pi.hostName) (macOS \(os.majorVersion).\(os.minorVersion))")
            lines.append("user: \(NSUserName())   login shell: \(Self.loginShell)")
            if !app.isEmpty { lines.append("frontmost app: \(app)") }
            if !windowTitle.isEmpty { lines.append("window title: \(windowTitle)") }
            lines.append("(The window title often holds the folder or the remote host; the screen shows the prompt. "
                + "If the screen shows an ssh session or another machine's prompt, write for that machine.)")
            return lines.joined(separator: "\n")
        }

        private static var loginShell: String {
            if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell { return String(cString: sh) }
            return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        }
    }

    // MARK: - The request

    private static let system = """
    You turn a spoken request into ONE shell command, to be typed into the terminal described \
    below. The user reads it and presses return; you never run anything.
    Reply with exactly one line and nothing else:
    CMD: <the command>
    or, when it can't be a sensible command (unclear, not a terminal task, or you'd have to guess \
    a path or name you can't see in the context):
    ASK: <one short question>
    Rules: one line, chain steps with && if needed. Write for the shell named in the context (on \
    macOS: BSD tools, so sed -i '' and no GNU-only flags unless the screen shows Linux). \
    In zsh: never put ! in a pattern or in double quotes (history expansion breaks it), and a \
    pattern that matches nothing is an error, so for hidden files use zsh's *(D) or *(ND) \
    instead of bash idioms like .[!.]* (sizes of everything here: du -sh -- *(D) | sort -hr). \
    Keep commands as light as the request: the entries here, not the whole tree below. You're \
    already typing into the right terminal: never wrap the command in ssh, tmux send-keys or \
    similar to reach it. Only when the request names another machine than the one on screen \
    (one from the setup notes, say), run it there with ssh <host> '<command>'. Prefer names you can see in the context (paths in the title or on screen, \
    containers, branches, and hosts, aliases and tools from the user's setup notes) over \
    guessing; follow the habits those notes state. "start claude" means running `claude`. Never use echo \
    or printf to talk to the user: if it isn't a terminal task, ASK. No markdown, no \
    explanation, no backticks.
    """

    let endpoint: Endpoint

    /// Streams the answer, calling `progress` on the main actor with the text so far.
    func compose(request: String, snapshot: Snapshot,
                 progress: @escaping @MainActor (String) -> Void) async throws -> Outcome {
        guard let url = URL(string: endpoint.url), url.host != nil else { throw AssistError.badEndpoint(endpoint.url) }
        var user = "Terminal:\n\(snapshot.description)"
        if !snapshot.setup.isEmpty { user += "\n\nThe user's setup notes:\n\(snapshot.setup)" }
        if !snapshot.screen.isEmpty { user += "\n\nLast lines on screen:\n\(snapshot.screen)" }
        user += "\n\nRequest: \(request)"
        let body: [String: Any] = [
            "model": endpoint.model, "stream": true, "max_tokens": 400, "temperature": 0,
            "messages": [["role": "system", "content": Self.system], ["role": "user", "content": user]],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !endpoint.apiKey.isEmpty { req.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var text = ""
            for try await line in bytes.lines { text += line; if text.count > 300 { break } }
            throw AssistError.http(http.statusCode, text)
        }
        var reasoning = "", content = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data: "), !line.contains("[DONE]"),
                  let data = line.dropFirst(6).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let delta = (json["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }
            if let r = (delta["reasoning_content"] ?? delta["reasoning"]) as? String { reasoning += r }
            if let c = delta["content"] as? String { content += c }
            let shown = content.isEmpty ? reasoning : content
            await progress(shown.replacingOccurrences(of: "\n", with: " "))
        }
        return try Self.parse(content)
    }

    static func parse(_ raw: String) throws -> Outcome {
        let line = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        func strip(_ s: Substring) -> String {
            s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }
        if line.hasPrefix("CMD:") { let c = strip(line.dropFirst(4)); if !c.isEmpty { return .command(c) } }
        if line.hasPrefix("ASK:") { let q = strip(line.dropFirst(4)); if !q.isEmpty { return .ask(q) } }
        if line.isEmpty { throw AssistError.empty }
        return .ask(line)   // not in the format: show it rather than type it
    }

    /// Commands worth a second look before return: deleting, privileges, disks, force pushes.
    static func warning(for command: String) -> String? {
        let checks: [(String, String)] = [
            (#"\brm\s+(-[a-zA-Z]*[rf]|--recursive|--force)"#, "deletes files"),
            (#"\bsudo\b"#, "runs as root"),
            (#"\b(dd|mkfs(\.\w+)?|fdisk|parted|wipefs|diskutil\s+(erase\w*|partition\w*))\b"#, "writes to a disk"),
            (#"\bgit\s+push\b.*(-f\b|--force)"#, "force-pushes"),
            (#"\bgit\s+(reset\s+--hard|clean\s+-[a-zA-Z]*f)"#, "throws away changes"),
            (#"\b(shutdown|reboot|halt|poweroff)\b"#, "stops the machine"),
            (#"\b(kill|pkill|killall)\b"#, "stops processes"),
            (#"\bchmod\s+(-R\s+)?[0-7]*777\b|\bchown\s+-R\b"#, "changes permissions widely"),
            (#">\s*/(etc|boot|dev|System)/"#, "overwrites a system file"),
        ]
        for (pattern, what) in checks where command.range(of: pattern, options: .regularExpression) != nil {
            return "Careful: this \(what). Check it before return."
        }
        return nil
    }
}
