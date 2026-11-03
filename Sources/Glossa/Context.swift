import AppKit
import ApplicationServices

enum Context {
    /// Text immediately before the insertion point in the focused UI element, if the app exposes it.
    static func textBeforeCursor(maxChars: Int) -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(focused, to: AXUIElement.self)

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String, !text.isEmpty else { return nil }

        let utf16 = Array(text.utf16)
        var cursor = utf16.count
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let r = rangeRef, CFGetTypeID(r) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(unsafeBitCast(r, to: AXValue.self), .cfRange, &range) { cursor = range.location }
        }
        let end = min(max(cursor, 0), utf16.count)
        let start = max(0, end - maxChars)
        guard end > start else { return nil }
        return String(decoding: utf16[start..<end], as: UTF16.self)
    }

    /// Builds the Whisper prompt: glossary first, then the surrounding text last so it survives truncation.
    static func prompt(glossary: [String], before: String?) -> String {
        var parts: [String] = []
        if !glossary.isEmpty { parts.append("Vocabulary: " + glossary.joined(separator: ", ") + ".") }
        if let before = before?.trimmingCharacters(in: .whitespacesAndNewlines), !before.isEmpty {
            parts.append(before)
        }
        return parts.joined(separator: "\n")
    }
}
