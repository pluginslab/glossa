import Foundation

struct Config: Codable {
    /// Any OpenAI-style transcription endpoint. whisper-server's /inference accepts the same multipart fields.
    var endpoint = "http://127.0.0.1:8178/inference"
    /// Sent as a Bearer token when non-empty (needed for llm-router, ignored by whisper-server).
    var apiKey = ""
    /// Model field in the request. whisper-server ignores it; llm-router routes on it.
    var model = "whisper-1"
    /// A second server, used when `endpoint` fails (laptop off the network, server down) or
    /// when "Use Fallback Server" is checked in the menu. Typically the local whisper-server
    /// when `endpoint` is a GPU box on the network. Empty disables it.
    var fallbackEndpoint = ""
    var fallbackApiKey = ""
    var fallbackModel = "whisper-1"
    /// Seconds of silence from `endpoint` before the fallback is tried (only with a fallback set).
    var primaryTimeout = 10.0
    /// Whisper language code. "auto" works but costs an extra encoder pass (~0.5 s) per request.
    var language = "en"
    /// Read the text before the cursor via Accessibility and feed it to Whisper as context.
    var useContext = true
    /// How many characters before the cursor to include.
    var contextChars = 300
    /// Play start/stop/error sounds.
    var sounds = true
    /// Ignore recordings shorter than this (seconds), to swallow accidental taps.
    var minSeconds = 0.4
    /// Lower the output volume by this many percentage points while recording. 0 disables it.
    var duckPercent = 10
    /// Only duck when something is actually playing on the output device.
    var duckOnlyIfPlaying = true
    /// Log every Fn, key and media-key event to ~/Library/Logs/glossa.log.
    var debug = false
    /// Virtual key code of the keyboard's microphone/dictation key (176 on Apple keyboards). 0 = disabled.
    var micKeyCode = 176
    /// Voice commands (Shift with the mic key or Fn): an OpenAI-style chat completions URL.
    /// Empty: derived from `endpoint` when it is a `/v1/audio/transcriptions` URL (llm-router).
    var assistEndpoint = ""
    /// Bearer token for `assistEndpoint`. Empty: `apiKey` is used.
    var assistApiKey = ""
    /// Model for voice commands (an llm-router alias).
    var assistModel = "code"

    init() {}

    /// Tolerant decoding: keys missing from an older config.json keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? endpoint
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? apiKey
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        fallbackEndpoint = try c.decodeIfPresent(String.self, forKey: .fallbackEndpoint) ?? fallbackEndpoint
        fallbackApiKey = try c.decodeIfPresent(String.self, forKey: .fallbackApiKey) ?? fallbackApiKey
        fallbackModel = try c.decodeIfPresent(String.self, forKey: .fallbackModel) ?? fallbackModel
        primaryTimeout = try c.decodeIfPresent(Double.self, forKey: .primaryTimeout) ?? primaryTimeout
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
        useContext = try c.decodeIfPresent(Bool.self, forKey: .useContext) ?? useContext
        contextChars = try c.decodeIfPresent(Int.self, forKey: .contextChars) ?? contextChars
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? sounds
        minSeconds = try c.decodeIfPresent(Double.self, forKey: .minSeconds) ?? minSeconds
        duckPercent = try c.decodeIfPresent(Int.self, forKey: .duckPercent) ?? duckPercent
        duckOnlyIfPlaying = try c.decodeIfPresent(Bool.self, forKey: .duckOnlyIfPlaying) ?? duckOnlyIfPlaying
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? debug
        micKeyCode = try c.decodeIfPresent(Int.self, forKey: .micKeyCode) ?? micKeyCode
        assistEndpoint = try c.decodeIfPresent(String.self, forKey: .assistEndpoint) ?? assistEndpoint
        assistApiKey = try c.decodeIfPresent(String.self, forKey: .assistApiKey) ?? assistApiKey
        assistModel = try c.decodeIfPresent(String.self, forKey: .assistModel) ?? assistModel
    }

    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/glossa")
    static let configURL = dir.appendingPathComponent("config.json")
    static let glossaryURL = dir.appendingPathComponent("glossary.txt")
    /// Notes about your machines and habits, sent with every voice command.
    static let setupURL = dir.appendingPathComponent("setup.txt")

    static let defaultSetup = """
    # Notes about your setup, sent with every voice command (Shift + mic key) so the
    # command can use your real hosts, aliases and habits. Plain text, any shape.
    # Lines starting with # are ignored. Keep secrets out: this goes to the model.
    #
    # Examples:
    # Servers: "web1" is the production box (Ubuntu 24.04, ssh web1), "nas" is a Synology.
    # Docker runs on web1; the app containers are named app-web and app-db.
    # I use pnpm, not npm. Projects live in ~/code/<name>.
    # Prefer rg over grep and eza over ls.
    """

    static let defaultGlossary = """
    # One term per line. Lines starting with # are ignored.
    # These are sent to Whisper as vocabulary so it spells them right.
    # Replace them with your own: product names, hostnames, acronyms, colleagues.
    kubectl
    nginx
    PostgreSQL
    Grafana
    Next.js
    pnpm
    GitHub
    Homebrew
    launchd
    Tailscale
    Cloudflare
    WordPress
    Gutenberg
    Xcode
    SwiftUI
    Astro
    Tailwind
    Whisper
    whisper.cpp
    LiteLLM
    vLLM
    Claude Code
    MCP
    """

    static func ensureFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configURL.path) {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(Config()).write(to: configURL)
        }
        if !fm.fileExists(atPath: glossaryURL.path) {
            try? defaultGlossary.write(to: glossaryURL, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: setupURL.path) {
            try? defaultSetup.write(to: setupURL, atomically: true, encoding: .utf8)
        }
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            Log.write("config: using defaults (could not read \(configURL.path))")
            return Config()
        }
        return cfg
    }

    /// setup.txt without comment lines, capped at 6000 characters; empty when unset.
    static func loadSetup() -> String {
        guard let text = try? String(contentsOf: setupURL, encoding: .utf8) else { return "" }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(kept.prefix(6000))
    }

    static func loadGlossary() -> [String] {
        guard let text = try? String(contentsOf: glossaryURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
