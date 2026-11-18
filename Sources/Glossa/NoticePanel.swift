import AppKit

/// A small floating line at the top of the screen for command mode: the answer as it
/// streams, then the model's question or a warning about the pasted command. Never takes
/// focus, ignores the mouse, and goes away on its own.
final class NoticePanel {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWork: DispatchWorkItem?

    /// `seconds`: hide after this long; nil keeps it up until the next call.
    func show(_ text: String, symbol: String = "terminal", seconds: TimeInterval? = nil) {
        let (panel, label) = ensurePanel()
        label.stringValue = text
        if let icon = panel.contentView?.viewWithTag(1) as? NSImageView {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
        layout(panel, label)
        panel.orderFrontRegardless()
        hideWork?.cancel()
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> (NSPanel, NSTextField) {
        if let panel, let label { return (panel, label) }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true

        let icon = NSImageView()
        icon.tag = 1
        icon.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        icon.contentTintColor = .secondaryLabelColor

        let l = NSTextField(wrappingLabelWithString: "")
        l.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        l.textColor = .labelColor
        l.maximumNumberOfLines = 3
        l.lineBreakMode = .byTruncatingHead

        bg.addSubview(icon)
        bg.addSubview(l)
        p.contentView = bg
        panel = p
        label = l
        return (p, l)
    }

    /// Centered near the top of the screen with the mouse, sized to the text (one to three lines).
    private func layout(_ panel: NSPanel, _ label: NSTextField) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let maxWidth = min(720, visible.width - 80)
        let pad: CGFloat = 14, iconW: CGFloat = 18, gap: CGFloat = 10
        let textMax = maxWidth - pad * 2 - iconW - gap
        label.preferredMaxLayoutWidth = textMax
        let size = label.sizeThatFits(NSSize(width: textMax, height: 200))
        let textW = min(max(size.width, 120), textMax)
        let textH = min(size.height, 3 * 17 + 2)
        let w = pad * 2 + iconW + gap + textW
        let h = max(textH + 20, 40)
        panel.setFrame(NSRect(x: visible.midX - w / 2, y: visible.maxY - h - 12, width: w, height: h), display: false)
        panel.contentView?.viewWithTag(1)?.frame = NSRect(x: pad, y: (h - iconW) / 2, width: iconW, height: iconW)
        label.frame = NSRect(x: pad + iconW + gap, y: (h - textH) / 2, width: textW, height: textH)
    }
}
