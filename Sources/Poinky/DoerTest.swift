import AppKit

/// Developer checks for Poinky's hands (`Computer`), run as the signed app (it needs Accessibility):
///
/// `Poinky --keys-probe <out.txt>` opens a scratch window of its own in front, presses key combinations into it
/// through `Computer.press`, and writes what the rest of the app would read right after each one (the modifier
/// flags marking and hold-to-talk look at, "seconds since typing") plus what the window received. Nothing is
/// pressed unless Poinky's own window is in front.
///
/// `--doer-target <log.txt>` (with `--ask` and a scripted doer) opens the same window and logs every key and
/// click it gets, so a test can check the doer's clicks reached it.
@MainActor
enum DoerTest {
    @MainActor final class Target: NSObject {
        let window: NSWindow
        let text: NSTextView
        private var lines: [String] = []
        private let out: String?
        private var monitor: Any?

        init(log: String?) {
            out = log
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let size = CGSize(width: 640, height: 420)
            let frame = CGRect(x: screen.visibleFrame.minX + 120, y: screen.visibleFrame.maxY - size.height - 120,
                               width: size.width, height: size.height)
            window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.title = "Poinky test target"
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: CGRect(origin: .zero, size: size))
            scroll.hasVerticalScroller = true
            scroll.autoresizingMask = [.width, .height]
            text = NSTextView(frame: CGRect(origin: .zero, size: size))
            text.font = NSFont.systemFont(ofSize: 28, weight: .semibold)
            text.string = "TARGET WINDOW\n\nPoinky test lines\nsecond line here\n"
            text.autoresizingMask = [.width]
            scroll.documentView = text
            window.contentView = scroll
            super.init()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] e in
                MainActor.assumeIsolated { self?.note(e) }
                return e
            }
        }

        func show() {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(text)
        }

        var inFront: Bool {
            // (NSWorkspace's frontmost app lags behind and once named another copy of Poinky while this one was
            // active with this window key; NSApp.isActive is this app's own view of the same thing.)
            NSApp.isActive && (window.isKeyWindow || NSApp.keyWindow === window)
        }

        private func note(_ e: NSEvent) {
            let m = DoerTest.mods(e.modifierFlags)
            let tagged = e.cgEvent.map(Computer.isOurs) ?? false
            switch e.type {
            case .keyDown: add("key \(e.keyCode) mods=\(m) chars=\(e.charactersIgnoringModifiers ?? "")\(tagged ? " ours" : "")")
            default:
                let p = e.locationInWindow
                add("click \(e.type == .rightMouseDown ? "right" : "left") at=\(Int(p.x)),\(Int(p.y)) count=\(e.clickCount) mods=\(m)\(tagged ? " ours" : "")")
            }
        }

        func add(_ line: String) {
            lines.append(line)
            flush()
        }

        func flush() {
            guard let out else { return }
            try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }

        func close() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            window.orderOut(nil)
        }
    }

    static func mods(_ f: NSEvent.ModifierFlags) -> String {
        var s: [String] = []
        if f.contains(.control) { s.append("ctrl") }
        if f.contains(.option) { s.append("option") }
        if f.contains(.shift) { s.append("shift") }
        if f.contains(.command) { s.append("cmd") }
        return s.isEmpty ? "-" : s.joined(separator: "+")
    }

    static func mods(_ f: CGEventFlags) -> String {
        var n: NSEvent.ModifierFlags = []
        if f.contains(.maskControl) { n.insert(.control) }
        if f.contains(.maskAlternate) { n.insert(.option) }
        if f.contains(.maskShift) { n.insert(.shift) }
        if f.contains(.maskCommand) { n.insert(.command) }
        return mods(n)
    }

    private static var target: Target?

    /// `--doer-target`: the window for a scripted doer to click and type in (it's in the screenshots, so
    /// `"find"` can aim at its words).
    static func openTarget(log: String) {
        let t = Target(log: log)
        target = t
        t.show()
        ScreenCapture.includedWindowNumbers.insert(t.window.windowNumber)
    }

    /// In a test with a target window, Poinky's hands act only while that window is in front (never in
    /// whatever the person at the Mac has open).
    /// `POINKY_TEST_FRONT=<words>` (real doer runs on scratch documents): the same, for a window of another app
    /// whose title has those words.
    static var mayAct: Bool {
        // `POINKY_TEST_APP=<name>`: an app the run started itself (e.g. TextEdit, whose "Make Rich Text" turns
        // the window into "Untitled"): any of its windows.
        if let name = ProcessInfo.processInfo.environment["POINKY_TEST_APP"], !name.isEmpty {
            if NSWorkspace.shared.frontmostApplication?.localizedName == name { return true }
            Timeline.log("test.notFront", ["app": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""])
            return false
        }
        if let words = ProcessInfo.processInfo.environment["POINKY_TEST_FRONT"], !words.isEmpty {
            let title = frontWindowTitle()
            if title.localizedCaseInsensitiveContains(words) { return true }
            Timeline.log("test.notFront", ["title": title, "app": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""])
            return false
        }
        guard let t = target else { return true }
        if t.inFront { return true }
        t.add("ABORT: the target window wasn't in front, so nothing was done (active: \(NSApp.isActive), isKey: \(t.window.isKeyWindow), front: \(NSWorkspace.shared.frontmostApplication.map { "\($0.localizedName ?? "?") \($0.processIdentifier)" } ?? "?"), me: \(ProcessInfo.processInfo.processIdentifier), key window: \(NSApp.keyWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "none"))")
        return false
    }

    /// The title of the front app's focused window (accessibility; the window list's first one can be a
    /// hidden helper window).
    static func frontWindowTitle() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "" }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var w: CFTypeRef?, t: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &w) == .success, let win = w,
              CFGetTypeID(win) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &t) == .success else { return "" }
        return t as? String ?? ""
    }

    /// Every combination the doer may send with a modifier (letters and arrows that do nothing harmful in a
    /// plain text view), then what the app reads afterwards.
    static let probeCombos = ["option+up", "option+shift+down", "shift+left", "cmd+right", "cmd+shift+left",
                              "option+j", "ctrl+e", "ctrl+option+j", "cmd+option+j", "ctrl+shift+j", "ctrl+option+shift+j",
                              "ctrl+option+cmd+j", "fn+left"]

    static func keysProbe(out: String) {
        let t = Target(log: out)
        target = t
        t.show()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            t.add("trusted: \(Computer.trusted)")
            var stuck = 0
            let combos = ProcessInfo.processInfo.environment["POINKY_PROBE_COMBOS"].map { $0.split(separator: ",").map(String.init) } ?? probeCombos
            for combo in combos {
                guard t.inFront else { t.add("ABORT: the test window isn't in front"); break }
                t.add("press \(combo)")
                if let why = await Computer.press(combo) { t.add("  refused: \(why)") }
                for wait in [0.0, 0.15, 0.5] {
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                    let held = CGEventSource.flagsState(.combinedSessionState)
                    // Held anywhere (every app and every copy of Poinky sees it): never once the press is over.
                    if mods(held) != "-" { stuck += 1 }
                    t.add(String(format: "  +%.2fs NSEvent=%@ combined=%@ hid=%@ ownModifiersNow=%@ typingAgo=%.2f",
                                 wait, mods(NSEvent.modifierFlags), mods(held), mods(CGEventSource.flagsState(.hidSystemState)),
                                 Computer.ownModifiersNow ? "yes" : "no", Computer.secondsSinceUserKey()))
                }
            }
            // A press cut off half way (you stopped Poinky): nothing stays held.
            guard t.inFront else { t.add("ABORT: the test window isn't in front"); finish(t, stuck: stuck); return }
            t.add("press ctrl+shift+j, then stopped")
            let pressing = Task { await Computer.press("ctrl+shift+j") }
            Computer.token += 1
            _ = await pressing.value
            try? await Task.sleep(nanoseconds: 300_000_000)
            let after = CGEventSource.flagsState(.combinedSessionState)
            if !mods(after).elementsEqual("-") { stuck += 1 }
            t.add("  +0.30s NSEvent=\(mods(NSEvent.modifierFlags)) combined=\(mods(after))")
            finish(t, stuck: stuck)
        }
    }

    private static func finish(_ t: Target, stuck: Int) {
        t.add(stuck == 0 ? "RESULT ok: no modifier stayed down" : "RESULT FAIL: modifiers stayed down after \(stuck) presses")
        t.close()
        NSApp.terminate(nil)
    }
}
