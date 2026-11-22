import AppKit
import ApplicationServices

/// Types a transcript into the focused app while you are still talking, and rewrites its
/// changing end: each update deletes only what differs from the last one (Backspace) and
/// types the new ending (synthetic Unicode key events, no pasteboard).
///
/// Backspaces are only safe while the cursor is still where Glossa left it, so editing
/// freezes for good the moment you click, press a key yourself, or another app comes to
/// the front. (Not by comparing the focused element: terminals such as Smart Terminal
/// swap it while they redraw.) Glossa's own key events carry `marker`, so the key monitor can tell them apart.
final class LiveTyper {
    /// Stamped into `eventSourceUserData` of every event Glossa posts ("GLSA").
    static let marker: Int64 = 0x474C_5341

    /// What Glossa has typed in this recording, as the app should now show it.
    private(set) var typed = ""
    private(set) var frozen = false
    private var pid: pid_t = 0
    /// Words that two passes in a row agreed on: never deleted again during the recording.
    private var committed: [Substring] = []
    private var lastHypothesis: [Substring] = []
    private var prefix = ""
    private var lockedText = ""

    var isActive: Bool { !typed.isEmpty }

    /// Call when recording starts. `leadingSpace`: the text before the cursor ends in a word.
    func begin(leadingSpace: Bool) {
        typed = ""; frozen = false; committed = []; lastHypothesis = []; lockedText = ""
        prefix = leadingSpace ? " " : ""
        pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    }

    func freeze(_ reason: String) {
        guard !frozen else { return }
        frozen = true
        Log.write("live typing stopped: \(reason)")
    }

    /// A pass: `locked` sentences are final; of the tentative rest, words two passes in a
    /// row agree on stay, the others follow the newest pass.
    func update(locked: String, tentative text: String) {
        if locked != lockedText { lockedText = locked; committed = []; lastHypothesis = [] }
        let words = Self.collapseRepeats(text.split(separator: " "))
        // Local agreement: the common word prefix of this pass and the last one is settled.
        var agreed = 0
        while agreed < min(words.count, lastHypothesis.count), words[agreed] == lastHypothesis[agreed] { agreed += 1 }
        if agreed > committed.count { committed = Array(words.prefix(agreed)) }
        lastHypothesis = words
        let tail = words.count > committed.count ? Array(words[committed.count...]) : []
        show(LiveTranscript.join(locked, (committed + tail).joined(separator: " ")))
    }

    /// Whisper looping on a pause repeats a phrase back to back ("if they are corrected if
    /// they are corrected"). Drops every immediate repeat of a run of 2 to 12 words, and of
    /// single words said three times or more.
    static func collapseRepeats(_ words: [Substring]) -> [Substring] {
        func key(_ w: Substring) -> String { w.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        var out: [Substring] = []
        for w in words {
            out.append(w)
            var changed = true
            while changed {
                changed = false
                for n in stride(from: min(12, out.count / 2), through: 2, by: -1) {
                    let a = out[(out.count - 2 * n)..<(out.count - n)].map(key)
                    let b = out[(out.count - n)...].map(key)
                    if a == b { out.removeLast(n); changed = true; break }
                }
            }
            if out.count >= 3, Set(out.suffix(3).map(key)).count == 1 { out.removeLast() }
        }
        return out
    }

    /// The final transcript: replaces everything typed in this recording, settled words included.
    /// Returns false when editing was frozen (the caller then offers the text another way).
    @discardableResult
    func finish(with text: String) -> Bool {
        show(text)
        return !frozen
    }

    private func show(_ text: String) {
        let target = text.isEmpty ? "" : prefix + text
        guard !frozen else { return }
        guard focusIsUnchanged() else { freeze("another app came to the front"); return }
        let common = typed.commonPrefix(with: target)
        let delete = typed.count - common.count
        let insert = String(target.dropFirst(common.count))
        guard delete > 0 || !insert.isEmpty else { return }
        backspace(delete)
        type(insert)
        typed = target
        Log.write("live: -\(delete) +\"\(insert)\"")
    }

    private func focusIsUnchanged() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    // MARK: - Key events

    private let source: CGEventSource? = {
        // A private state: the events don't pick up modifiers held on the keyboard (Fn held
        // for push-to-talk would turn Backspace into Forward Delete).
        let s = CGEventSource(stateID: .privateState)
        s?.userData = LiveTyper.marker
        return s
    }()

    private func post(_ make: (Bool) -> CGEvent?) {
        for down in [true, false] {
            guard let e = make(down) else { continue }
            e.flags = []
            e.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            e.post(tap: .cghidEventTap)
        }
    }

    private func backspace(_ count: Int) {
        for _ in 0..<count { post { CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: $0) } }
    }

    private func type(_ text: String) {
        var units = Array(text.utf16)[...]
        while !units.isEmpty {
            // Up to 20 UTF-16 units per event, never splitting a surrogate pair.
            var n = min(20, units.count)
            if n < units.count, UTF16.isLeadSurrogate(units[units.startIndex + n - 1]) { n -= 1 }
            let chunk = Array(units.prefix(n))
            units = units.dropFirst(n)
            post { down in
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                return e
            }
        }
    }
}
