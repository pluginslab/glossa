import Foundation

/// What live typing knows about the recording so far: finished sentences, which are locked
/// (typed for good), and the tentative rest, which each pass may still rewrite.
///
/// A sentence is finished when Whisper closed it with . ? or ! and more speech follows it.
/// With timestamps (llm-router, Speaches, OpenAI) the locked sentences also mark a point in
/// the audio: later passes, and the final one, only send the audio after `offset`, so each
/// request stays short however long you talk. Without timestamps (whisper.cpp's server)
/// every pass covers the whole recording and skips the `lockedSentences` it already locked.
struct LiveTranscript {
    struct Segment {
        let start: Double
        let end: Double
        let text: String
    }

    /// Locked text before the current window (its audio is behind `offset`).
    private(set) var lockedBefore = ""
    /// Sentences of the current window that are locked: finished, with more after them.
    /// Whisper often keeps several sentences in one segment, so locking goes by text; the
    /// window only moves on at a segment boundary, where the timestamp is exact.
    private(set) var windowLocked: [String] = []
    /// Seconds of audio `lockedBefore` covers; the next window starts here.
    private(set) var offset = 0.0
    private(set) var tentative = ""
    /// The window was moved on an estimate, a little early: the next pass may start with the
    /// last words of the locked text again.
    private var trimOverlap = false

    /// Past this, a window is moved on even inside a segment (an estimate), so Whisper never
    /// gets close to its 30 s window, where it starts inventing text.
    static let longWindow = 20.0

    var locked: String { Self.join(lockedBefore, windowLocked.joined(separator: " ")) }
    var display: String { Self.join(locked, tentative) }

    /// One pass over the audio from `offset`. `segments` with timestamps (relative to the
    /// window) let the window move on; without them every pass covers the whole recording.
    mutating func ingest(text: String, segments: [Segment]?) {
        var sentences: [String]
        // Sentences up to the last segment that ends one and has more segments after it.
        var boundary: (count: Int, end: Double)?
        if let segs = segments?.filter({ !Self.clean($0.text).isEmpty }), !segs.isEmpty, segs.contains(where: { $0.end > 0 }) {
            let perSegment = segs.map { Self.sentences($0.text) }
            sentences = perSegment.flatMap { $0 }
            if let i = segs.indices.dropLast().last(where: { Self.endsSentence(segs[$0].text) }) {
                boundary = (perSegment[...i].reduce(0) { $0 + $1.count }, segs[i].end)
            }
        } else {
            sentences = Self.sentences(text)
        }
        if trimOverlap {
            let before = sentences.count
            sentences = Self.sentences(Self.dropOverlap(sentences.joined(separator: " "), after: lockedBefore))
            if let b = boundary { boundary = (b.count - (before - sentences.count), b.end) }
        }
        // Where the window's locked sentences end in this pass: matched by content, so a pass
        // that splits or merges sentences differently doesn't shift everything by one.
        guard let lockedHere = lockedCount(in: sentences) else { return }   // can't tell: keep what is shown
        var rest = Array(sentences.dropFirst(lockedHere))
        if rest.count > 1, let f = rest.dropLast().lastIndex(where: Self.endsSentence) {
            windowLocked += rest[...f]
            rest.removeFirst(f + 1)
        }
        tentative = rest.joined(separator: " ")
        let lockedNow = lockedHere + (sentences.count - lockedHere - rest.count)
        if let b = boundary, b.count > 0, b.count == lockedNow {
            // A segment ends right after the last locked sentence: an exact place to move on.
            lockedBefore = Self.join(lockedBefore, windowLocked.joined(separator: " "))
            windowLocked = []
            offset += b.end
            trimOverlap = false
        } else if let segs = segments, let windowEnd = segs.last?.end, windowEnd > Self.longWindow,
                  !windowLocked.isEmpty, let at = Self.estimateEnd(ofSentences: windowLocked.count, in: segs) {
            lockedBefore = Self.join(lockedBefore, windowLocked.joined(separator: " "))
            windowLocked = []
            offset += max(0, at - 0.4)
            trimOverlap = true
        }
    }

    /// How many of `sentences` (one pass over the window) are the window's locked ones:
    /// up to the best match for the last locked sentence, near where it should be.
    /// nil when there is none (the pass is too different to place).
    private func lockedCount(in sentences: [String]) -> Int? {
        guard let last = windowLocked.last else { return 0 }
        var best: (index: Int, score: Double)?
        for (j, s) in sentences.enumerated() {
            let score = Self.similarity(s, last) - 0.05 * Double(abs(j - (windowLocked.count - 1)))
            if score > (best?.score ?? 0.5) { best = (j, score) }
        }
        if let best { return best.index + 1 }
        return sentences.count >= windowLocked.count ? windowLocked.count : nil
    }

    /// Word overlap of two sentences, 0...1, ignoring case and punctuation.
    static func similarity(_ a: String, _ b: String) -> Double {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init))
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// Where, in window seconds, the first `count` sentences end: in the segment holding the
    /// last of them, by the share of that segment's characters up to its end.
    static func estimateEnd(ofSentences count: Int, in segments: [Segment]) -> Double? {
        var seen = 0
        for seg in segments where !clean(seg.text).isEmpty {
            let parts = sentences(seg.text)
            if seen + parts.count >= count {
                let upTo = parts.prefix(count - seen).joined(separator: " ").count
                let total = max(1, clean(seg.text).count)
                return seg.start + (seg.end - seg.start) * Double(upTo) / Double(total)
            }
            seen += parts.count
        }
        return nil
    }

    /// `text` without leading words that repeat the end of `previous` (up to 6 words).
    static func dropOverlap(_ text: String, after previous: String) -> String {
        func key(_ w: Substring) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let words = clean(text).split(separator: " ")
        let tail = clean(previous).split(separator: " ").suffix(6).map(key)
        for n in stride(from: min(6, words.count, tail.count), through: 1, by: -1)
        where Array(tail.suffix(n)) == words.prefix(n).map(key) {
            return words.dropFirst(n).joined(separator: " ")
        }
        return clean(text)
    }

    /// The whole text once the final pass is in; that pass heard the audio from `offset`.
    func final(with text: String) -> String {
        let sentences = Self.sentences(trimOverlap ? Self.dropOverlap(text, after: lockedBefore) : text)
        guard let lockedHere = lockedCount(in: sentences) else { return Self.join(lockedBefore, Self.clean(text)) }
        return Self.join(locked, sentences.dropFirst(lockedHere).joined(separator: " "))
    }

    /// Context for Whisper's prompt: the end of the text before the window, so the window
    /// continues it. Not the sentences locked inside the window: their audio is in the window
    /// already, and Whisper given them as a prompt tends to copy them in again.
    var promptTail: String { String(lockedBefore.suffix(200)) }

    // MARK: - Helpers

    static func clean(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }

    static func endsSentence(_ s: String) -> Bool {
        guard let last = clean(s).last else { return false }
        return ".?!…".contains(last)
    }

    /// Splits after . ? ! followed by whitespace; "Next.js" and "3.5" stay whole.
    static func sentences(_ text: String) -> [String] {
        let t = clean(text)
        guard !t.isEmpty else { return [] }
        var out: [String] = [], current = ""
        let chars = Array(t)
        for (i, c) in chars.enumerated() {
            current.append(c)
            if ".?!…".contains(c), i + 1 < chars.count, chars[i + 1] == " " {
                out.append(current); current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
