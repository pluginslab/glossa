import Foundation

struct Config: Codable {
    /// Any OpenAI-style transcription endpoint. whisper-server's /inference accepts the same multipart fields.
    var endpoint = "http://127.0.0.1:8178/inference"
    /// Sent as a Bearer token when non-empty (needed for llm-router, ignored by whisper-server).
    var apiKey = ""
    /// Model field in the request. whisper-server ignores it; llm-router routes on it.
    var model = "whisper-1"
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
    /// Log every Fn, key and media-key event to ~/Library/Logs/glossa.log.
    var debug = false
    /// Virtual key code of the keyboard's microphone/dictation key (176 on Apple keyboards). 0 = disabled.
    var micKeyCode = 176

    init() {}

    /// Tolerant decoding: keys missing from an older config.json keep their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? endpoint
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? apiKey
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? language
        useContext = try c.decodeIfPresent(Bool.self, forKey: .useContext) ?? useContext
        contextChars = try c.decodeIfPresent(Int.self, forKey: .contextChars) ?? contextChars
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? sounds
        minSeconds = try c.decodeIfPresent(Double.self, forKey: .minSeconds) ?? minSeconds
        debug = try c.decodeIfPresent(Bool.self, forKey: .debug) ?? debug
        micKeyCode = try c.decodeIfPresent(Int.self, forKey: .micKeyCode) ?? micKeyCode
    }

    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/glossa")
    static let configURL = dir.appendingPathComponent("config.json")
    static let glossaryURL = dir.appendingPathComponent("glossary.txt")

    static let defaultGlossary = """
    # One term per line. Lines starting with # are ignored.
    # These are sent to Whisper as vocabulary so it spells them right.
    vLLM
    megamaschine
    sparkmaschine
    supermaschine
    llm-router
    LiteLLM
    Tailscale
    MagicDNS
    Codeable
    Pluginslab
    WordPress
    Gutenberg
    Cloudflare
    Lucas PM
    Claude Code
    Whisper
    whisper.cpp
    Homebrew
    launchd
    Ploi
    DigitalOcean
    Outline
    Synology
    Xcode
    SwiftUI
    Astro
    Tailwind
    Nemotron
    Gemma
    Qwen
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
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            Log.write("config: using defaults (could not read \(configURL.path))")
            return Config()
        }
        return cfg
    }

    static func loadGlossary() -> [String] {
        guard let text = try? String(contentsOf: glossaryURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
