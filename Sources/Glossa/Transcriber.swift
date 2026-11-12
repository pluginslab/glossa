import Foundation

enum TranscribeError: LocalizedError {
    case badEndpoint(String)
    case http(Int, String)
    case badResponse
    var errorDescription: String? {
        switch self {
        case .badEndpoint(let e): return "not a URL: \(e)"
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .badResponse: return "unexpected response shape"
        }
    }
}

/// One transcription server: an OpenAI-style `/v1/audio/transcriptions` endpoint (or
/// whisper-server's `/inference`, which takes the same fields), its key and model name.
struct Server {
    let endpoint: String
    let apiKey: String
    let model: String
    let role: String

    /// "host:port" for logs and the menu.
    var label: String {
        guard let u = URL(string: endpoint), let h = u.host else { return endpoint }
        return u.port.map { "\(h):\($0)" } ?? h
    }
}

struct Transcriber {
    let config: Config

    var primary: Server { Server(endpoint: config.endpoint, apiKey: config.apiKey, model: config.model, role: "primary") }
    var fallback: Server? {
        config.fallbackEndpoint.isEmpty ? nil
            : Server(endpoint: config.fallbackEndpoint, apiKey: config.fallbackApiKey, model: config.fallbackModel, role: "fallback")
    }

    /// Sends the audio to the primary server, or to the fallback when the primary fails for
    /// any reason (laptop off the network, server down, bad key) or when `preferFallback`
    /// is set from the menu. Returns the text and the server that produced it.
    func transcribe(wav: Data, prompt: String, preferFallback: Bool = false) async throws -> (text: String, server: Server) {
        if preferFallback, let fallback {
            return (try await post(wav: wav, prompt: prompt, to: fallback, timeout: 60), fallback)
        }
        let primary = primary
        do {
            // With a fallback configured, give the primary only `primaryTimeout` seconds of
            // silence before moving on; the recording is already done, the user is waiting.
            let timeout = fallback == nil ? 60 : config.primaryTimeout
            return (try await post(wav: wav, prompt: prompt, to: primary, timeout: timeout), primary)
        } catch {
            guard let fallback else { throw error }
            Log.write("primary \(primary.label) failed: \(error.localizedDescription); trying fallback \(fallback.label)")
            return (try await post(wav: wav, prompt: prompt, to: fallback, timeout: 60), fallback)
        }
    }

    private func post(wav: Data, prompt: String, to server: Server, timeout: TimeInterval) async throws -> String {
        guard let url = URL(string: server.endpoint), url.host != nil else { throw TranscribeError.badEndpoint(server.endpoint) }
        let boundary = "----Glossa-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !server.apiKey.isEmpty { req.setValue("Bearer \(server.apiKey)", forHTTPHeaderField: "Authorization") }

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", server.model)
        field("response_format", "json")
        field("temperature", "0.0")
        if !config.language.isEmpty { field("language", config.language) }
        if !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw TranscribeError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else { throw TranscribeError.badResponse }
        return text
    }
}

extension Data {
    mutating func append(_ s: String) { append(s.data(using: .utf8)!) }
}
