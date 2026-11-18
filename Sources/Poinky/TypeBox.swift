import AppKit

/// A small box to type to Poinky instead of talking (⌃⌥T, or from the menu): long questions, pasted
/// errors and code. It opens next to the mouse; Return sends, Shift-Return adds a line, Esc closes.
/// Opened while pointing at a helper, it types to that helper.
/// Typed in, text out: after you send, the box stays open and the answer is written under your question (nothing
/// is said), with Copy; type the next question right there. Esc or a click elsewhere closes it.
@MainActor
final class TypeBox: NSObject, NSTextViewDelegate, NSWindowDelegate {
    /// What you typed, and the helper it's for (nil: Poinky).
    var onSend: ((_ text: String, _ helper: Int?) -> Void)?
    /// The Copy button: the text to put on the clipboard.
    var onCopy: ((String) -> Void)?

    fileprivate var panel: TypePanel?
    fileprivate var text: PlaceholderTextView?
    private var helper: Int?
    /// What you were typing when it closed without sending (kept for next time).
    private var draft = ""

    var isOpen: Bool { panel?.isVisible == true }

    /// Opens the box near the mouse. `helper`: the helper it types to, with its name and color.
    /// `helpers`: the names of helpers at work (the placeholder says "@Mint" reaches one).
    func open(helper: (id: Int, name: String, color: NSColor)? = nil, helpers: [String] = []) {
        if panel == nil { build() }
        guard let panel, let text else { return }
        self.helper = helper?.id
        text.placeholder = helper.map { "Tell \($0.name) something…" }
            ?? (helpers.first.map { "Ask Poinky, or @\($0) to tell a helper…" } ?? "Ask Poinky…")
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
        panel.setFrameOrigin(Self.testOrigin ?? o)
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
        clearAnswer()
        Self.log("closed")
    }

    private func send() {
        guard let t = text?.string.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
        let target = helper
        text?.string = ""
        draft = ""
        // To a helper: it answers in its own card and window. To Poinky: the answer comes here.
        if target != nil { close() } else { text?.placeholder = "Ask a follow-up…"; resize() }
        onSend?(t, target)
    }

    /// Tests (`--type`): as if typed and sent with Return.
    func testSend(_ t: String) {
        text?.string = t
        send()
    }

    // MARK: - The answer, under your question

    private var question = ""
    private var answer = ""
    private var copyText: String?
    private var answerState = ""          // "" (none) · thinking · writing · done

    /// You sent a question: it shows above the answer area, which says it's thinking.
    func asked(_ q: String) {
        guard isOpen else { return }
        question = q
        answer = ""
        copyText = nil
        answerState = "thinking"
        layoutAnswer()
        Self.log("asked \(String(reflecting: q))")
    }

    /// The answer so far (it grows sentence by sentence, at reading pace).
    func showAnswer(_ a: String) {
        guard isOpen else { return }
        answer = a
        if answerState != "done" { answerState = "writing" }
        layoutAnswer()
        Self.log("answer \(String(reflecting: a))")
    }

    /// The answer is complete: Copy copies `copy` (a rewrite or a command in it) or else the whole answer.
    func answerDone(copy: String?) {
        guard isOpen, !answer.isEmpty else { return }
        copyText = copy ?? answer
        answerState = "done"
        layoutAnswer()
        Self.log("done copy=\(String(reflecting: copyText ?? ""))")
    }

    private func clearAnswer() {
        question = ""; answer = ""; copyText = nil; answerState = ""
        layoutAnswer()
    }

    @objc private func copyAnswer() {
        guard let t = copyText ?? (answer.isEmpty ? nil : answer) else { return }
        onCopy?(t)
        copyButton?.title = "Copied ✓"
        Self.log("copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.copyButton?.title = "Copy" }
    }

    /// `POINKY_TYPEBOX_LOG=file` (tests): what the box showed, in order.
    private static let logPath = ProcessInfo.processInfo.environment["POINKY_TYPEBOX_LOG"]
    static func log(_ line: String) {
        guard let path = logPath, let d = (line + "\n").data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: d) }
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

        // The answer area (hidden until you ask): your question, the answer, and Copy.
        let sep = NSBox(); sep.boxType = .separator
        fx.addSubview(sep)
        let q = NSTextField(labelWithString: "")
        q.font = .systemFont(ofSize: 12)
        q.textColor = .secondaryLabelColor
        q.lineBreakMode = .byTruncatingTail
        q.maximumNumberOfLines = 1
        fx.addSubview(q)
        let ascroll = NSScrollView()
        ascroll.drawsBackground = false
        ascroll.hasVerticalScroller = true
        ascroll.autohidesScrollers = true
        ascroll.borderType = .noBorder
        let av = NSTextView()
        av.isEditable = false
        av.isSelectable = true      // select part of it and ⌘C, or Copy for the whole thing
        av.isRichText = false
        av.drawsBackground = false
        av.font = .systemFont(ofSize: 14)
        av.textColor = .labelColor
        av.textContainerInset = NSSize(width: 0, height: 0)
        av.textContainer?.lineFragmentPadding = 0
        av.isVerticallyResizable = true
        av.isHorizontallyResizable = false
        av.autoresizingMask = [.width]
        av.textContainer?.widthTracksTextView = true
        av.baseWritingDirection = .natural   // a Hebrew answer reads right to left
        ascroll.documentView = av
        fx.addSubview(ascroll)
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = .tertiaryLabelColor
        fx.addSubview(status)
        let copy = HoverButton(title: "Copy", target: self, action: #selector(copyAnswer))
        copy.toolTip = "Copy the answer (or the part of it to paste)"
        fx.addSubview(copy)
        separator = sep; questionLabel = q; answerScroll = ascroll; answerView = av; statusLabel = status; copyButton = copy
        [sep, q, ascroll, status, copy].forEach { $0.isHidden = true }

        panel = p
        text = tv
        scrollView = scroll
    }

    private var scrollView: NSScrollView?
    private var dot: DotView?
    private var hint: NSTextField?
    private var separator: NSBox?
    fileprivate var questionLabel: NSTextField?
    fileprivate var answerScroll: NSScrollView?
    fileprivate var answerView: NSTextView?
    fileprivate var statusLabel: NSTextField?
    fileprivate var copyButton: HoverButton?
    private var answerHeight: CGFloat = 0

    /// Grows with what you type, up to about eight lines (and with the answer under it, up to about 300 points,
    /// then it scrolls). The top edge stays put.
    private func resize() {
        guard let panel, let text, let scroll = scrollView, let lm = text.layoutManager, let tc = text.textContainer else { return }
        let inner = Self.width - 36 - 34
        tc.containerSize = NSSize(width: inner, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let line = (text.font?.boundingRectForFont.height ?? 19)
        let content = max(line, lm.usedRect(for: tc).height)
        let textH = min(content, 8 * line)
        let a = answerHeight
        let h = ceil(textH + 30 + a)
        var f = panel.frame
        let top = f.maxY
        f.size = NSSize(width: Self.width, height: h)
        f.origin.y = top - h
        // Kept on screen when the answer makes it taller.
        if let vis = panel.screen?.visibleFrame, f.minY < vis.minY + 8 { f.origin.y = vis.minY + 8 }
        panel.setFrame(f, display: true)
        scroll.frame = NSRect(x: 36, y: 15 + a, width: inner + 4, height: textH)
        text.frame.size.width = inner
        dot?.setFrameOrigin(NSPoint(x: 16, y: h - 15 - line / 2 - 5))
        if let hint {
            hint.sizeToFit()
            hint.setFrameOrigin(NSPoint(x: Self.width - 16 - hint.frame.width, y: 15 + a + (line - hint.frame.height) / 2 + textH - line))
        }
    }

    /// Lays out the answer area (bottom part of the box) and resizes the box around it.
    private func layoutAnswer() {
        let views: [NSView?] = [separator, questionLabel, answerScroll, statusLabel, copyButton]
        guard let av = answerView, let ascroll = answerScroll, let lm = av.layoutManager, let tc = av.textContainer,
              let q = questionLabel, let status = statusLabel, let copy = copyButton, let sep = separator else { return }
        let showing = !answerState.isEmpty
        views.forEach { $0?.isHidden = !showing }
        guard showing else { answerHeight = 0; resize(); return }
        let inner = Self.width - 36 - 20
        q.stringValue = question.replacingOccurrences(of: "\n", with: " ")
        if av.string != answer {
            let atEnd = ascroll.contentView.bounds.maxY >= av.frame.height - 4
            av.string = answer
            if atEnd { av.scrollToEndOfDocument(nil) }
        }
        tc.containerSize = NSSize(width: inner, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let line = av.font?.boundingRectForFont.height ?? 18
        let bodyH = answer.isEmpty ? 0 : min(300, max(line, lm.usedRect(for: tc).height))
        status.stringValue = answerState == "thinking" ? "Thinking…" : answerState == "writing" ? "Writing…" : "Esc closes"
        status.sizeToFit()
        copy.isHidden = answerState != "done"
        copy.sizeToFit()
        let foot: CGFloat = 26, qH: CGFloat = 16
        // From the bottom up: footer, answer, question, separator.
        let a = 10 + foot + (bodyH > 0 ? bodyH + 6 : 0) + qH + 10
        copy.setFrameOrigin(NSPoint(x: Self.width - 14 - copy.frame.width, y: 8 + (foot - copy.frame.height) / 2))
        status.setFrameOrigin(NSPoint(x: 36, y: 8 + (foot - status.frame.height) / 2))
        ascroll.frame = NSRect(x: 36, y: 10 + foot, width: inner + 6, height: bodyH)
        av.frame.size.width = inner
        q.frame = NSRect(x: 36, y: 10 + foot + (bodyH > 0 ? bodyH + 6 : 0), width: inner, height: qH)
        sep.frame = NSRect(x: 16, y: a - 1, width: Self.width - 32, height: 1)
        answerHeight = a
        resize()
    }

    func textDidChange(_ notification: Notification) {
        resize()
        text?.needsDisplay = true
    }

    /// A click elsewhere closes it (Copy first if you want the answer; it's also in the notch).
    func windowDidResignKey(_ notification: Notification) { if !Self.keepForTests { close() } }
    /// Tests (`--type`, launched in the background): the box can't keep the keyboard there, so it stays open anyway.
    static var keepForTests = false
    /// Tests (`--type-box-test`): off screen, so the pictures don't put a box in front of whoever uses the Mac.
    static var testOrigin: NSPoint?
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
        testOrigin = NSPoint(x: -4000, y: 400)
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
        if ProcessInfo.processInfo.environment["POINKY_SHOT_DARK"] == "1" { box.panel?.appearance = NSAppearance(named: .darkAqua) }
        keepForTests = true
        log("open \(box.isOpen), key \(box.panel?.isKeyWindow == true), placeholder \(box.text?.placeholder ?? "")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            shot("empty")
            box.text?.insertText("Why does this fail?", replacementRange: NSRange(location: NSNotFound, length: 0))
            key(36, shift: true)
            box.text?.insertText("TypeError: x is undefined", replacementRange: NSRange(location: NSNotFound, length: 0))
            log("after Shift-Return: \(String(reflecting: box.text?.string ?? "")), height \(Int(box.panel?.frame.height ?? 0))")
            shot("typed")
            key(36)
            log("after Return: open \(box.isOpen), placeholder \(box.text?.placeholder ?? "")")
            // Typed in, text out: the answer under the question, with Copy (pictures in light and dark).
            box.onCopy = { t in log("copied \(String(reflecting: t))") }
            box.asked("Why does this fail?\nTypeError: x is undefined")
            log("thinking: \(box.statusLabel?.stringValue ?? ""), copy hidden \(box.copyButton?.isHidden ?? false)")
            shot("answer-thinking")
            box.showAnswer("x is undefined because the loop starts at 1, so the first item is never set.")
            box.answerDone(copy: nil)
            log("answered: \(String(reflecting: box.answerView?.string ?? "")), height \(Int(box.panel?.frame.height ?? 0)), copy shown \(box.copyButton?.isHidden == false)")
            shot("answer")
            box.copyButton?.performClick(nil)
            box.asked("make this shorter")
            box.showAnswer("Here's a shorter version: We ship Friday, tested and ready. Want me to swap it in?")
            box.answerDone(copy: "We ship Friday, tested and ready.")
            box.copyButton?.performClick(nil)
            shot("answer-rewrite")
            let long = (1...30).map { "Sentence number \($0) of a long answer that goes on for a while." }.joined(separator: " ")
            box.asked("explain all of it in detail please, with every step")
            box.showAnswer(long)
            box.answerDone(copy: nil)
            log("long: height \(Int(box.panel?.frame.height ?? 0)) (≤ 420), scrolls \((box.answerView?.frame.height ?? 0) > (box.answerScroll?.frame.height ?? 0))")
            shot("answer-long")
            box.asked("מה זה אומר?")
            box.showAnswer("זה אומר שהקובץ נשמר בתיקייה הראשית, ולא בתיקייה של הפרויקט.")
            box.answerDone(copy: nil)
            shot("answer-hebrew")
            box.open(helper: (3, "Violet", NSColor(hex: "#9b6bff")))
            log("for a helper: placeholder \(box.text?.placeholder ?? "")")
            box.text?.insertText("also add a test", replacementRange: NSRange(location: NSNotFound, length: 0))
            key(36)
            box.open(helpers: ["Mint", "Coral"])
            log("with helpers at work: placeholder \(box.text?.placeholder ?? "")")
            box.close()
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

/// A small capsule button that shows it's a button: brighter under the mouse, darker and a touch smaller while
/// pressed, and a pointing-hand cursor (the type box is the key window, so its tracking areas always work).
final class HoverButton: NSButton {
    private(set) var hot = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    override init(frame: NSRect) { super.init(frame: frame); setUp() }
    required init?(coder: NSCoder) { super.init(coder: coder); setUp() }
    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
    }
    private func setUp() {
        isBordered = false
        font = .systemFont(ofSize: 11.5, weight: .semibold)
        setButtonType(.momentaryChange)
    }
    override var intrinsicContentSize: NSSize {
        let w = (title as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 11.5)]).width
        return NSSize(width: ceil(w) + 24, height: 22)
    }
    override func sizeToFit() { setFrameSize(intrinsicContentSize) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hot = true }
    override func mouseExited(with event: NSEvent) { hot = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        super.mouseDown(with: event)   // tracks until mouse up, then sends the action
        pressed = false
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: pressed ? 1.5 : 0.5, dy: pressed ? 1.5 : 0.5)
        let accent = NSColor.controlAccentColor
        (pressed ? accent.blended(withFraction: 0.25, of: .black) ?? accent : hot ? accent : accent.withAlphaComponent(0.82)).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        if hot && !pressed {
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: r.height / 2, yRadius: r.height / 2)
            ring.lineWidth = 1; ring.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 11.5), .foregroundColor: NSColor.white]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attrs)
    }
    /// Tests: what the mouse would do.
    func testHover(_ on: Bool) { hot = on }
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

/// A menu bar app has no menus of its own, so ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z did nothing in the type box and the
/// Helpers window (pasting an error is half of what they're for). This hidden main menu gives them the
/// standard Edit keys, and ⌘W closes a window. Nothing shows: the app has no menu bar.
enum EditMenu {
    @MainActor static func install() {
        guard NSApp.mainMenu?.items.contains(where: { $0.title == "Edit" }) != true else { return }
        let main = NSApp.mainMenu ?? NSMenu()
        func menu(_ title: String, _ items: [(String, Selector, String, NSEvent.ModifierFlags)]) {
            let m = NSMenu(title: title)
            for (t, sel, key, mods) in items {
                let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
                i.keyEquivalentModifierMask = mods
                m.addItem(i)
            }
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
        }
        if main.items.isEmpty { main.addItem(NSMenuItem(title: "Poinky", action: nil, keyEquivalent: "")) }
        menu("Edit", [("Undo", Selector(("undo:")), "z", [.command]), ("Redo", Selector(("redo:")), "z", [.command, .shift]),
                      ("Cut", #selector(NSText.cut(_:)), "x", [.command]), ("Copy", #selector(NSText.copy(_:)), "c", [.command]),
                      ("Paste", #selector(NSText.paste(_:)), "v", [.command]), ("Select All", #selector(NSText.selectAll(_:)), "a", [.command])])
        menu("Window", [("Close", #selector(NSWindow.performClose(_:)), "w", [.command])])
        NSApp.mainMenu = main
    }
}
