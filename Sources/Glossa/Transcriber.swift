import Foundation

enum TranscribeError: LocalizedError {
    case http(Int, String)
    case badResponse
    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .badResponse: return "unexpected response shape"
        }
    }
}

struct Transcriber {
    let config: Config

    func transcribe(wav: Data, prompt: String) async throws -> String {
        guard let url = URL(string: config.endpoint) else { throw TranscribeError.badResponse }
        let boundary = "----Glossa-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", config.model)
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
