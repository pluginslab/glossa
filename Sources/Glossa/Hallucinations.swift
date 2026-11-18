import Foundation

/// Whisper was trained on subtitled video, and on silence or room noise it sometimes
/// writes the credit lines those subtitles end with. They only ever show up at the end of
/// a transcript, so only trailing sentences are checked.
enum Hallucinations {
    private static let patterns = [
        #"closed caption(ing|ed|s)?\b.*"#,
        #"(subtitles|captions|transcription|translation|transcript)( were| are)? (by|from|provided by|created by)\b.*"#,
        #"subtitled by\b.*"#,
        #"(thanks|thank you)( (so|very) much)? for watching\b.*"#,
        #"(please )?(like and )?subscribe\b.*"#,
        #".*\bamara\.org\b.*"#,
        #"(copyright|©).*(bbc|mooji|itv)\b.*"#,
        #"see you (in the )?next (time|video|episode)\b.*"#,
    ].map { try! NSRegularExpression(pattern: "^\\s*" + $0 + "$", options: [.caseInsensitive]) }

    /// A sentence that is only a web address ("brandhagen.com"): it belongs to the credit before it.
    private static let bareDomain = try! NSRegularExpression(pattern: #"^(www\.)?[\w-]+(\.[\w-]+)*\.(com|org|net|io|tv|co\.uk)\.?$"#, options: [.caseInsensitive])

    /// The text without any trailing hallucinated sentences, and what was removed.
    static func strip(_ text: String) -> (text: String, removed: String?) {
        var sentences = split(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var removed: [String] = []
        while var tail = sentences.popLast() {
            if matches(bareDomain, tail), let previous = sentences.popLast() { tail = previous + " " + tail }
            guard patterns.contains(where: { matches($0, tail) }) else { sentences.append(tail); break }
            removed.insert(tail, at: 0)
        }
        return (sentences.joined(separator: " "), removed.isEmpty ? nil : removed.joined(separator: " "))
    }

    /// Splits after ".", "!" or "?" followed by whitespace. Inner dots ("Next.js", "brandhagen.com") stay.
    private static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let re = try! NSRegularExpression(pattern: #"(?<=[.!?])\s+"#)
        var parts: [String] = [], from = text.startIndex
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            parts.append(String(text[from..<r.lowerBound])); from = r.upperBound
        }
        parts.append(String(text[from...]))
        return parts.filter { !$0.isEmpty }
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
