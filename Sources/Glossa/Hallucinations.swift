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

    /// The text without any trailing hallucinated sentences, and what was removed. A whole
    /// transcript that is stuck in a loop or only echoes the glossary is removed entirely.
    static func strip(_ text: String, glossary: [String] = []) -> (text: String, removed: String?) {
        if isLoop(text) || isGlossaryEcho(text, glossary: glossary) {
            return ("", String(text.prefix(120)))
        }
        let (collapsed, loop) = collapseLoops(text)
        var sentences = split(collapsed.trimmingCharacters(in: .whitespacesAndNewlines))
        var removed: [String] = []
        while var tail = sentences.popLast() {
            if matches(bareDomain, tail), let previous = sentences.popLast() { tail = previous + " " + tail }
            guard patterns.contains(where: { matches($0, tail) }) else { sentences.append(tail); break }
            removed.insert(tail, at: 0)
        }
        if let loop { removed.insert(loop, at: 0) }
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

    /// Whisper looping on silence repeats a phrase back to back ("All right. All right. All
    /// right. …"). A run of 2 to 8 words said three times or more in a row, or one word four
    /// times or more, is kept once. Returns the text and a note of what was cut.
    static func collapseLoops(_ text: String) -> (String, String?) {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        func key(_ w: Substring) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let keys = words.map(key)
        var out: [Substring] = [], cut: [String] = []
        var i = 0
        while i < words.count {
            var best: (n: Int, reps: Int)?
            for n in 1...8 where i + n * 2 <= words.count {
                var reps = 1
                while i + n * (reps + 1) <= words.count, Array(keys[(i + n * reps)..<(i + n * (reps + 1))]) == Array(keys[i..<(i + n)]) { reps += 1 }
                if reps >= (n == 1 ? 4 : 3), best == nil || n * reps > best!.n * best!.reps { best = (n, reps) }
            }
            if let b = best {
                out += words[i..<(i + b.n)]
                cut.append("\(words[i..<(i + b.n)].joined(separator: " ")) ×\(b.reps)")
                i += b.n * b.reps
            } else {
                out.append(words[i]); i += 1
            }
        }
        return (out.joined(separator: " "), cut.isEmpty ? nil : "loop: " + cut.joined(separator: ", "))
    }

    /// Whisper stuck repeating itself: one word makes up more than half of 12+ words.
    static func isLoop(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard words.count >= 12 else { return false }
        let counts = Dictionary(words.map { ($0, 1) }, uniquingKeysWith: +)
        return Double(counts.values.max() ?? 0) > Double(words.count) * 0.5
    }

    /// The prompt read back: a comma list where every item is a glossary term.
    static func isGlossaryEcho(_ text: String, glossary: [String]) -> Bool {
        guard !glossary.isEmpty else { return false }
        let terms = Set(glossary.map { $0.lowercased() })
        var body = text.lowercased()
        if body.hasPrefix("vocabulary:") { body = String(body.dropFirst(11)) }
        let items = body.split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) }
            .map { $0.hasSuffix(".com") ? String($0.dropLast(4)) : $0 }
            .filter { !$0.isEmpty }
        return items.count >= 3 && items.allSatisfy { terms.contains($0) }
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
