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

    private static let source = CGEventSource(stateID: .hidSystemState)

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
        defer { pressing = false }
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
            await sleep(0.018)
        }
        return true
    }

    /// Shortcuts that could lose work or end things; Poinky won't press them.
    static let blocked: Set<String> = ["cmd+q", "cmd+option+escape", "cmd+delete", "cmd+shift+delete",
                                       "cmd+option+shift+delete", "ctrl+cmd+q", "cmd+option+q", "ctrl+option+cmd+eject",
                                       "cmd+shift+q", "cmd+option+shift+q", "cmd+option+delete"]

    /// Presses a key combination like "cmd+l", "return", "shift+tab", "cmd+shift+4". Returns why it didn't, or nil.
    static func press(_ combo: String) async -> String? {
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
        pressing = true
        tap(code, flags: flags)
        try? await Task.sleep(nanoseconds: 60_000_000)
        pressing = false
        return nil
    }

    private static func tap(_ code: UInt16, flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
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
    static var escapePressed: Bool {
        !pressing && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape))
    }
}
