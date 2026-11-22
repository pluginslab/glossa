import AppKit

/// Watches the microphone/dictation key and the Fn/Globe key through a session-wide CGEvent tap.
/// Mic key: single press -> .toggle, hold -> .holdStart/.holdEnd; the event is swallowed so Apple's
/// Dictation never sees it. Fn: double-tap -> .toggle, hold -> push-to-talk, single tap -> .tap.
/// A Fn press combined with another key (Fn+Backspace, Fn+arrow) emits nothing.
/// Shift held when the key goes down marks the action as a voice command (`command: true`).
final class FnKeyMonitor {
    /// .tap: a single Fn tap. .toggle: Fn double-tap or a single microphone-key press.
    enum Action: Equatable { case tap, toggle(command: Bool), holdStart(command: Bool), holdEnd }
    enum Source { case fn, micKey }

    var onAction: ((Action) -> Void)?
    /// A key you pressed or a click (not one Glossa typed); live typing stops editing on it.
    var onUserKey: ((String) -> Void)?
    var debug = false
    /// Virtual key code of the keyboard's microphone/dictation key (176 on Apple keyboards). 0 disables it.
    var micKeyCode: Int64 = 176

    private var tap: CFMachPort?
    private var fnDownAt: Date?
    private var otherKeyDuringFn = false
    private var holding = false
    private var holdTimer: Timer?
    private var lastTapAt: Date?
    /// Shift was down when the current press started (or at the first tap of a Fn double-tap).
    private var shiftAtPress = false
    private var shiftAtLastTap = false

    private let doubleTapWindow: TimeInterval = 0.4
    private let holdThreshold: TimeInterval = 0.35
    private let fnKeyCode: Int64 = 63
    private var activeSource: Source = .fn
    private let systemDefinedType: UInt32 = 14   // NSEvent.EventType.systemDefined

    var isActive: Bool { tap != nil }

    /// Returns false when the event tap could not be created (Accessibility not granted).
    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << systemDefinedType)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(userInfo!).takeUnretainedValue()
                let swallow = monitor.handle(type: type, event: event)
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Returns true when the event should be swallowed (not passed on to the system).
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Log.write("event tap re-enabled after \(type.rawValue)")
            return false
        }
        if type == .leftMouseDown || type == .rightMouseDown {
            // The menu bar (Glossa's own icon, to stop from the menu) doesn't move the text cursor.
            if let onUserKey, !Self.inMenuBar(event.location) {
                let p = event.location
                let what = "\(type == .leftMouseDown ? "click" : "right-click") at \(Int(p.x)),\(Int(p.y))"
                DispatchQueue.main.async { onUserKey(what) }
            }
            return false
        }
        if type.rawValue == systemDefinedType {
            return handleSystemDefined(event)
        }
        if type == .keyDown || type == .keyUp {
            // Glossa's own live typing: not a key press to react to.
            if event.getIntegerValueField(.eventSourceUserData) == LiveTyper.marker { return false }
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            // Only special keys (F-keys, media keys) are logged, never typed characters.
            if debug, keycode >= 96 { Log.write("\(type == .keyDown ? "keyDown" : "keyUp") keycode=\(keycode) flags=\(event.flags.rawValue)") }
            if micKeyCode != 0, keycode == micKeyCode {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if type == .keyDown { if !isRepeat { keyDown(.micKey, shift: event.flags.contains(.maskShift)) } } else { keyUp(.micKey) }
                return true
            }
            if type == .keyDown, fnDownAt != nil { otherKeyDuringFn = true; cancelHold() }
            if type == .keyDown, let onUserKey {
                // The key code only, never the character typed.
                let what = "key code \(keycode), flags \(String(event.flags.rawValue, radix: 16)), source \(event.getIntegerValueField(.eventSourceUnixProcessID))"
                DispatchQueue.main.async { onUserKey(what) }
            }
            return false
        }
        guard type == .flagsChanged else { return false }
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if debug { Log.write("flagsChanged keycode=\(keycode) flags=\(event.flags.rawValue)") }
        guard keycode == fnKeyCode else {
            // Another modifier changed while Fn is held: treat as a combo, not a tap.
            if fnDownAt != nil { otherKeyDuringFn = true; cancelHold() }
            return false
        }
        if event.flags.contains(.maskSecondaryFn) { keyDown(.fn, shift: event.flags.contains(.maskShift)) } else { keyUp(.fn) }
        return false
    }

    /// `p` in global display coordinates (origin at the top left of the main screen):
    /// within the menu bar's height from the top of whichever screen it is on.
    private static func inMenuBar(_ p: CGPoint) -> Bool {
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return false }
        let bar = NSStatusBar.system.thickness + 6
        return NSScreen.screens.contains { screen in
            let f = screen.frame
            let top = mainHeight - f.maxY          // this screen's top edge, in CG coordinates
            return p.x >= f.minX && p.x < f.maxX && p.y >= top && p.y < top + bar
        }
    }

    /// Media keys (volume, brightness, the microphone/dictation key) arrive as NSSystemDefined subtype 8.
    private func handleSystemDefined(_ event: CGEvent) -> Bool {
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return false }
        let code = (ns.data1 & 0xFFFF_0000) >> 16
        let state = (ns.data1 & 0x0000_FF00) >> 8
        let isDown = state == 0x0A
        if debug { Log.write("systemDefined mediaKey code=\(code) \(isDown ? "down" : "up") data1=\(String(ns.data1, radix: 16))") }
        return false
    }

    private func keyDown(_ source: Source, shift: Bool) {
        guard fnDownAt == nil else { return }
        activeSource = source
        shiftAtPress = shift
        fnDownAt = Date()
        otherKeyDuringFn = false
        holding = false
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            guard let self, self.fnDownAt != nil, !self.otherKeyDuringFn else { return }
            self.holding = true
            self.emit(.holdStart(command: self.shiftAtPress))
        }
    }

    private func keyUp(_ source: Source) {
        cancelHold()
        defer { fnDownAt = nil }
        guard fnDownAt != nil, source == activeSource else { return }
        if holding {
            holding = false
            emit(.holdEnd)
            return
        }
        if otherKeyDuringFn { return }
        if source == .micKey {
            emit(.toggle(command: shiftAtPress))
            return
        }
        let now = Date()
        if let last = lastTapAt, now.timeIntervalSince(last) < doubleTapWindow {
            lastTapAt = nil
            emit(.toggle(command: shiftAtPress || shiftAtLastTap))
        } else {
            lastTapAt = now
            shiftAtLastTap = shiftAtPress
            emit(.tap)
        }
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    private func emit(_ action: Action) {
        if debug { Log.write("fn action: \(action)") }
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
    }
}
