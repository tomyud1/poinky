import AppKit

/// A small box to type to Poinky instead of talking (⌃⌥T, or from the menu): long questions, pasted
/// errors and code. It opens next to the mouse; Return sends, Shift-Return adds a line, Esc closes.
/// Opened while pointing at a helper, it types to that helper.
@MainActor
final class TypeBox: NSObject, NSTextViewDelegate, NSWindowDelegate {
    /// What you typed, and the helper it's for (nil: Poinky).
    var onSend: ((_ text: String, _ helper: Int?) -> Void)?

    fileprivate var panel: TypePanel?
    fileprivate var text: PlaceholderTextView?
    private var helper: Int?
    /// What you were typing when it closed without sending (kept for next time).
    private var draft = ""

    var isOpen: Bool { panel?.isVisible == true }

    /// Opens the box near the mouse. `helper`: the helper it types to, with its name and color.
    func open(helper: (id: Int, name: String, color: NSColor)? = nil) {
        if panel == nil { build() }
        guard let panel, let text else { return }
        self.helper = helper?.id
        text.placeholder = helper.map { "Tell \($0.name) something…" } ?? "Ask Poinky…"
        dot?.color = helper?.color ?? NSColor(red: 0.25, green: 0.56, blue: 1, alpha: 1)
        if helper == nil, text.string.isEmpty { text.string = draft }
        resize()
        // Just below and to the right of the mouse, kept on its screen.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vis = screen.visibleFrame
        var o = NSPoint(x: mouse.x + 18, y: mouse.y - 22 - panel.frame.height)
        o.x = min(max(vis.minX + 8, o.x), vis.maxX - panel.frame.width - 8)
        if o.y < vis.minY + 8 { o.y = mouse.y + 22 }
        panel.setFrameOrigin(o)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(text)
        text.selectAll(nil)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        if helper == nil { draft = text?.string ?? "" }
        panel.orderOut(nil)
    }

    private func send() {
        guard let t = text?.string.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
        let target = helper
        text?.string = ""
        draft = ""
        close()
        onSend?(t, target)
    }

    // MARK: - Building it

    private static let width: CGFloat = 440

    private func build() {
        let p = TypePanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 52),
                          styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        p.onCancel = { [weak self] in self?.close() }

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 14
        fx.layer?.cornerCurve = .continuous
        fx.layer?.masksToBounds = true
        fx.layer?.borderWidth = 0.5
        fx.layer?.borderColor = NSColor.separatorColor.cgColor
        p.contentView = fx

        let dot = DotView(frame: NSRect(x: 16, y: 0, width: 10, height: 10))
        fx.addSubview(dot)
        self.dot = dot

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = PlaceholderTextView()
        tv.delegate = self
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 15)
        tv.textColor = .labelColor
        tv.insertionPointColor = .controlAccentColor
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.onReturn = { [weak self] in self?.send() }
        tv.onEscape = { [weak self] in self?.close() }
        scroll.documentView = tv
        fx.addSubview(scroll)

        let hint = NSTextField(labelWithString: "↩")
        hint.font = .systemFont(ofSize: 12, weight: .medium)
        hint.textColor = .tertiaryLabelColor
        fx.addSubview(hint)
        self.hint = hint

        panel = p
        text = tv
        scrollView = scroll
    }

    private var scrollView: NSScrollView?
    private var dot: DotView?
    private var hint: NSTextField?

    /// Grows with what you type, up to about eight lines.
    private func resize() {
        guard let panel, let text, let scroll = scrollView, let lm = text.layoutManager, let tc = text.textContainer else { return }
        let inner = Self.width - 36 - 34
        tc.containerSize = NSSize(width: inner, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let line = (text.font?.boundingRectForFont.height ?? 19)
        let content = max(line, lm.usedRect(for: tc).height)
        let textH = min(content, 8 * line)
        let h = ceil(textH + 30)
        var f = panel.frame
        let top = f.maxY
        f.size = NSSize(width: Self.width, height: h)
        f.origin.y = top - h
        panel.setFrame(f, display: true)
        scroll.frame = NSRect(x: 36, y: 15, width: inner + 4, height: textH)
        text.frame.size.width = inner
        dot?.setFrameOrigin(NSPoint(x: 16, y: h - 15 - line / 2 - 5))
        if let hint {
            hint.sizeToFit()
            hint.setFrameOrigin(NSPoint(x: Self.width - 16 - hint.frame.width, y: 15 + (line - hint.frame.height) / 2 + textH - line))
        }
    }

    func textDidChange(_ notification: Notification) {
        resize()
        text?.needsDisplay = true
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

extension TypeBox {
    private static var keep: TypeBox?

    /// For tests: open it, type, Shift-Return, Return; log what was sent and take pictures.
    static func selfTest(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var lines: [String] = []
        func log(_ s: String) { lines.append(s); try? lines.joined(separator: "\n").write(toFile: outDir + "/log.txt", atomically: true, encoding: .utf8) }
        let box = TypeBox()
        keep = box
        box.onSend = { text, helper in log("sent \(String(reflecting: text)) to \(helper.map { "#\($0)" } ?? "Poinky")") }
        func key(_ code: UInt16, shift: Bool = false) {
            guard let tv = box.text, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0,
                                                             windowNumber: box.panel?.windowNumber ?? 0, context: nil, characters: "\r",
                                                             charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code) else { return }
            tv.keyDown(with: e)
        }
        func shot(_ name: String) {
            guard let v = box.panel?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outDir + "/\(name).png"))
        }
        box.open()
        log("open \(box.isOpen), key \(box.panel?.isKeyWindow == true), placeholder \(box.text?.placeholder ?? "")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            shot("empty")
            box.text?.insertText("Why does this fail?", replacementRange: NSRange(location: NSNotFound, length: 0))
            key(36, shift: true)
            box.text?.insertText("TypeError: x is undefined", replacementRange: NSRange(location: NSNotFound, length: 0))
            log("after Shift-Return: \(String(reflecting: box.text?.string ?? "")), height \(Int(box.panel?.frame.height ?? 0))")
            shot("typed")
            key(36)
            log("after Return: open \(box.isOpen)")
            box.open(helper: (3, "Violet", NSColor(hex: "#9b6bff")))
            log("for a helper: placeholder \(box.text?.placeholder ?? "")")
            box.text?.insertText("also add a test", replacementRange: NSRange(location: NSNotFound, length: 0))
            key(36)
            box.open()
            box.text?.insertText("a draft", replacementRange: NSRange(location: NSNotFound, length: 0))
            key(53)
            log("Esc: open \(box.isOpen)")
            box.open()
            log("draft kept: \(String(reflecting: box.text?.string ?? ""))")
            box.close()
            log("DONE")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
        }
    }
}

/// The panel takes typing without bringing Poinky to the front (your app stays the one Poinky sees).
final class TypePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A text view with a placeholder; Return sends, Shift-Return (or ⌥-Return) adds a line.
final class PlaceholderTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {   // Return, Enter
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else if !hasMarkedText() {
                onReturn?()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        if event.keyCode == 53 { onEscape?(); return }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 15), .foregroundColor: NSColor.placeholderTextColor]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width, y: textContainerInset.height), withAttributes: attrs)
    }
}

/// The colored dot for who you're typing to (Poinky's blue, or the helper's color).
final class DotView: NSView {
    var color: NSColor = .systemBlue { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

extension NSColor {
    /// "#34c98e"
    convenience init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x34c98e
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
