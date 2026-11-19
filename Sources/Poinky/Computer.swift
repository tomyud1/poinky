import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Poinky's hands: moves the mouse, clicks, types and presses keys (needs Accessibility permission).
///
/// Points are global screen coordinates with the origin at the top-left of the main display
/// (what `WindowTracker.toGlobal` returns). Every action can be cancelled through `token`.
@MainActor
enum Computer {
    /// Bumped to stop whatever is running right now (you interrupted).
    static var token = 0
    /// True while Poinky itself is pressing keys (so its own Esc doesn't count as yours).
    static private(set) var pressing = false

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's "allow Poinky to control your computer" prompt.
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Poinky's own event source (a private one: the user's held keys never leak into its events). Note that
    /// macOS still counts what it posts as keys held and typed for everyone (`.hidSystemState` too), so the
    /// readers of "your keys" skip the moment of Poinky's own presses (`ownModifiersNow`).
    private static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.userData = Computer.tag
        return s
    }()

    /// Written into every event Poinky posts (`eventSourceUserData`), so its own clicks can be told apart.
    nonisolated static let tag: Int64 = 0x504F_494E_4B59   // "POINKY"

    nonisolated static func isOurs(_ e: CGEvent) -> Bool {
        e.getIntegerValueField(.eventSourceUserData) == tag
    }

    /// Poinky's hands are busy (a doer step's acts): the overlay lets every click through and ⌥ doesn't mark.
    static var acting = false
    /// When Poinky last posted a key, and a key with modifiers (uptime).
    static private(set) var lastKey: TimeInterval = 0
    static private(set) var lastModifierKey: TimeInterval = 0
    private static var lastEscape: TimeInterval = 0
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Poinky pressed a key with modifiers a moment ago: the modifier state anyone reads right now may be its
    /// own (hold-to-talk and ⌥ marking skip this moment instead of reading it as you holding ⌃⌥ or ⌥).
    static var ownModifiersNow: Bool { now - lastModifierKey < 0.15 }

    static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// Glides the real cursor to `p` (the buddy follows it), so you can see where it's going.
    @discardableResult
    static func glide(to p: CGPoint, seconds: Double = 0.35) async -> Bool {
        let my = token, start = cursor
        let steps = max(6, Int(seconds * 60))
        for i in 1...steps {
            guard my == token else { return false }
            let u = Double(i) / Double(steps)
            let e = u < 0.5 ? 2 * u * u : 1 - pow(-2 * u + 2, 2) / 2
            let q = CGPoint(x: start.x + (p.x - start.x) * e, y: start.y + (p.y - start.y) * e)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: q, mouseButton: .left)?.post(tap: .cghidEventTap)
            await sleep(seconds / Double(steps))
        }
        return my == token
    }

    @discardableResult
    static func click(at p: CGPoint, count: Int = 1, right: Bool = false) async -> Bool {
        guard await glide(to: p) else { return false }
        await sleep(0.08)
        let my = token
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for n in 1...max(1, min(3, count)) {
            guard my == token else { return false }
            for type in [down, up] {
                let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e?.post(tap: .cghidEventTap)
                await sleep(0.03)
            }
            await sleep(0.06)
        }
        return true
    }

    /// Scrolls at `p` (or where the cursor is); positive `lines` scrolls down.
    @discardableResult
    static func scroll(lines: Int, at p: CGPoint?) async -> Bool {
        if let p, !(await glide(to: p, seconds: 0.25)) { return false }
        let my = token
        let n = max(-40, min(40, lines)), dir: Int32 = n > 0 ? -1 : 1
        for _ in 0..<abs(n) {
            guard my == token else { return false }
            CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: dir * 3, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            await sleep(0.025)
        }
        return true
    }

    /// Is the focused text field a password field? (Poinky never types there.)
    static func focusIsSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return false }
        var sub: CFTypeRef?
        if AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSubroleAttribute as CFString, &sub) == .success,
           let s = sub as? String, s == (kAXSecureTextFieldSubrole as String) { return true }
        return false
    }

    /// Chat apps where Return sends the message: there a new line is Shift+Return.
    static let chatApps: Set<String> = ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "net.whatsapp.WhatsApp",
                                        "WhatsApp", "com.hnc.Discord", "ru.keepcoder.Telegram", "com.microsoft.teams2",
                                        "com.microsoft.teams", "org.whispersystems.signal-desktop", "com.facebook.archon"]

    /// Types text as if from the keyboard (any language, emoji included).
    /// A new line is a plain Return (a new paragraph), or Shift+Return when `softBreaks` (chat boxes, where Return sends).
    @discardableResult
    static func type(_ text: String, softBreaks: Bool = false) async -> Bool {
        let my = token
        pressing = true
        defer { pressing = false; lastKey = now }
        // A few characters per event: fast, and apps still see every keystroke.
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            guard my == token else { return false }
            // Newlines are real Return presses: new paragraphs, so apps format each line on its own.
            if units[i] == 10 || units[i] == 13 {
                tap(UInt16(kVK_Return), flags: softBreaks ? [.maskShift] : [])
                i += (units[i] == 13 && i + 1 < units.count && units[i + 1] == 10) ? 2 : 1
                await sleep(0.02)
                continue
            }
            var j = min(units.count, i + 8)
            if let nl = units[i..<j].firstIndex(where: { $0 == 10 || $0 == 13 }) { j = nl }
            // Don't split a surrogate pair (emoji).
            if j < units.count, j > i + 1, UTF16.isLeadSurrogate(units[j - 1]) { j -= 1 }
            var chunk = Array(units[i..<j])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.flags = []
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                e?.post(tap: .cghidEventTap)
            }
            i = j
            lastKey = now
            await sleep(0.018)
        }
        return true
    }

    /// Puts `text` where the cursor or selection is by pasting it (⌘V): fast, any length, and one ⌘Z undoes
    /// it. The clipboard gets back everything it held before (every type of every item) unless something else
    /// was copied meanwhile. Never into a password field. Returns why not, or nil.
    static func paste(_ text: String) async -> String? {
        if focusIsSecure() { return "the cursor is in a password field" }
        let pb = NSPasteboard.general
        let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Clipboard managers skip it (it's Poinky's, for a moment).
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pb.writeObjects([item])
        let mine = pb.changeCount
        let why = await press("cmd+v")
        // The app reads the clipboard when it handles ⌘V: give it time before putting the old contents back.
        try? await Task.sleep(nanoseconds: 600_000_000)
        if pb.changeCount == mine {
            pb.clearContents()
            let items = saved.map { types -> NSPasteboardItem in
                let i = NSPasteboardItem()
                for (t, d) in types { i.setData(d, forType: t) }
                return i
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        return why
    }

    /// Shortcuts that could lose work or end things; Poinky won't press them.
    static let blocked: Set<String> = ["cmd+q", "cmd+option+escape", "cmd+delete", "cmd+shift+delete",
                                       "cmd+option+shift+delete", "ctrl+cmd+q", "cmd+option+q", "ctrl+option+cmd+eject",
                                       "cmd+shift+q", "cmd+option+shift+q", "cmd+option+delete"]

    /// Presses a key combination like "cmd+l", "return", "shift+tab", "cmd+shift+4". Returns why it didn't, or nil.
    static func press(_ combo: String) async -> String? {
        let my = token
        let parts = combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard let keyName = parts.last, let code = keyCodes[keyName] else { return "unknown key \(combo)" }
        var flags: CGEventFlags = []
        var mods: [String] = []
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command", "⌘": flags.insert(.maskCommand); mods.append("cmd")
            case "shift", "⇧": flags.insert(.maskShift); mods.append("shift")
            case "option", "opt", "alt", "⌥": flags.insert(.maskAlternate); mods.append("option")
            case "ctrl", "control", "⌃": flags.insert(.maskControl); mods.append("ctrl")
            case "fn": flags.insert(.maskSecondaryFn)
            default: return "unknown modifier \(m)"
            }
        }
        let normalized = (["ctrl", "option", "shift", "cmd"].filter { mods.contains($0) } + [keyName]).joined(separator: "+")
        let check = (["ctrl", "cmd", "option", "shift"].filter { mods.contains($0) } + [keyName]).joined(separator: "+")
        if blocked.contains(normalized) || blocked.contains(check) || blocked.contains(combo.lowercased()) {
            return "\(combo) is blocked (it could close apps or delete things)"
        }
        guard my == token else { return "stopped" }
        // The same modifier tapped twice in quick succession is a shortcut of its own in other apps: double ⌥
        // opens the Claude app's quick entry (it took the keyboard from the window being typed in, so the doer's
        // later keys and typing went nowhere), double ⌃ / fn starts Dictation. A second press with a modifier
        // the last one also used waits until that modifier has been up for a moment.
        let wait = modifierKeys.filter { flags.contains($0.flag) }.map { m in (lastRelease[m.code] ?? 0) + Self.modifierGap - now }.max() ?? 0
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        guard my == token else { return "stopped" }
        pressing = true
        tap(code, flags: flags)
        try? await Task.sleep(nanoseconds: 40_000_000)
        pressing = false
        return nil
    }

    /// When each modifier key last came up after one of Poinky's presses (uptime), and how long it stays up
    /// before Poinky presses it again (double-tap shortcuts usually need the second tap within ~0.3–0.5 s).
    private static var lastRelease: [UInt16: TimeInterval] = [:]
    static let modifierGap: TimeInterval = 0.6

    /// The modifier keys, in the order a person presses them.
    private static let modifierKeys: [(flag: CGEventFlags, code: UInt16)] = [
        (.maskControl, UInt16(kVK_Control)), (.maskAlternate, UInt16(kVK_Option)),
        (.maskShift, UInt16(kVK_Shift)), (.maskCommand, UInt16(kVK_Command)), (.maskSecondaryFn, UInt16(kVK_Function)),
    ]

    /// Presses a key like a keyboard does: each modifier goes down, the key goes down and up, the modifiers
    /// come up again, all at once (nothing can cut it off half way). Posting only the key with its flags
    /// left those flags held for the whole login session: every app and every copy of Poinky saw ⌥ held
    /// down (marking mode caught the doer's next clicks as red pins), and a ⌃⌥ shortcut would have opened
    /// the mic.
    private static func tap(_ code: UInt16, flags: CGEventFlags) {
        let mods = modifierKeys.filter { flags.contains($0.flag) }
        var held: CGEventFlags = []
        func post(_ key: UInt16, down: Bool, _ f: CGEventFlags) {
            let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
            e?.flags = f
            e?.post(tap: .cghidEventTap)
        }
        for m in mods { held.insert(m.flag); post(m.code, down: true, held) }
        post(code, down: true, held)
        post(code, down: false, held)
        for m in mods.reversed() { held.remove(m.flag); post(m.code, down: false, held); lastRelease[m.code] = now }
        lastKey = now
        if !mods.isEmpty { lastModifierKey = now }
        if code == UInt16(kVK_Escape) { lastEscape = now }
    }

    /// Is this key down on the keyboard right now (and not one Poinky just pressed)?
    static func userKeyDown(_ code: Int) -> Bool {
        if code == kVK_Escape, now - lastEscape < 0.3 { return false }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code))
    }

    /// Seconds since the last key press that wasn't Poinky typing (its own keys read as "not typing").
    static func secondsSinceUserKey() -> Double {
        let raw = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        if pressing || abs((now - raw) - lastKey) < 0.3 { return 999 }
        return raw
    }

    static let keyCodes: [String: UInt16] = {
        var m: [String: UInt16] = [
            "return": UInt16(kVK_Return), "enter": UInt16(kVK_Return), "tab": UInt16(kVK_Tab), "space": UInt16(kVK_Space),
            "delete": UInt16(kVK_Delete), "backspace": UInt16(kVK_Delete), "forwarddelete": UInt16(kVK_ForwardDelete),
            "escape": UInt16(kVK_Escape), "esc": UInt16(kVK_Escape),
            "left": UInt16(kVK_LeftArrow), "right": UInt16(kVK_RightArrow), "up": UInt16(kVK_UpArrow), "down": UInt16(kVK_DownArrow),
            "home": UInt16(kVK_Home), "end": UInt16(kVK_End), "pageup": UInt16(kVK_PageUp), "pagedown": UInt16(kVK_PageDown),
            ",": UInt16(kVK_ANSI_Comma), ".": UInt16(kVK_ANSI_Period), "/": UInt16(kVK_ANSI_Slash), ";": UInt16(kVK_ANSI_Semicolon),
            "'": UInt16(kVK_ANSI_Quote), "[": UInt16(kVK_ANSI_LeftBracket), "]": UInt16(kVK_ANSI_RightBracket),
            "\\": UInt16(kVK_ANSI_Backslash), "-": UInt16(kVK_ANSI_Minus), "=": UInt16(kVK_ANSI_Equal), "`": UInt16(kVK_ANSI_Grave),
            "comma": UInt16(kVK_ANSI_Comma), "period": UInt16(kVK_ANSI_Period), "slash": UInt16(kVK_ANSI_Slash),
            "f1": UInt16(kVK_F1), "f2": UInt16(kVK_F2), "f3": UInt16(kVK_F3), "f4": UInt16(kVK_F4), "f5": UInt16(kVK_F5),
            "f6": UInt16(kVK_F6), "f7": UInt16(kVK_F7), "f8": UInt16(kVK_F8), "f9": UInt16(kVK_F9), "f10": UInt16(kVK_F10),
            "f11": UInt16(kVK_F11), "f12": UInt16(kVK_F12),
        ]
        let letters: [(String, Int)] = [("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K),
            ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q),
            ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T), ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W),
            ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2),
            ("3", kVK_ANSI_3), ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9)]
        for (k, v) in letters { m[k] = UInt16(v) }
        return m
    }()

    /// Esc held down by you (not by Poinky): stop acting.
    static var escapePressed: Bool { userKeyDown(kVK_Escape) }
}
