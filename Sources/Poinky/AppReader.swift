import AppKit
import ApplicationServices

/// Reads the app you're using through macOS accessibility: its buttons, fields and menus, with exact
/// positions. The doer gets this next to the screenshot, so it can click the real thing instead of guessing.
@MainActor
enum AppReader {
    struct Element {
        let id: Int
        let role: String
        let label: String
        let rectPx: CGRect      // in screenshot pixels
    }

    struct Reading {
        var app = ""
        var bundleID = ""
        var pid: pid_t = 0
        var lines: [String] = []        // for the model
        var elements: [Int: Element] = [:]
    }

    /// Roles worth listing (things you click or type into), with a short name for the model.
    private static let kinds: [String: String] = [
        "AXButton": "button", "AXTextField": "text field", "AXTextArea": "text area", "AXCheckBox": "checkbox",
        "AXRadioButton": "option", "AXPopUpButton": "pop-up menu", "AXMenuButton": "menu button", "AXComboBox": "combo box",
        "AXLink": "link", "AXSlider": "slider", "AXDisclosureTriangle": "disclosure", "AXTab": "tab",
        "AXSearchField": "search field", "AXSwitch": "switch", "AXIncrementor": "stepper", "AXDateField": "date field",
    ]

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    private static func str(_ el: AXUIElement, _ name: String) -> String {
        (attr(el, name) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// The app in front (not Poinky).
    static func frontApp() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let a = NSWorkspace.shared.frontmostApplication, a.processIdentifier != me { return a }
        return nil
    }

    /// Reads the front app's window on `screen`. `scale` = screenshot pixels per screen point.
    static func read(screen: NSScreen, scale: CGFloat, budget: TimeInterval = 0.45) -> Reading {
        var r = Reading()
        guard Computer.trusted, let app = frontApp() else { return r }
        r.app = app.localizedName ?? ""
        r.bundleID = app.bundleIdentifier ?? ""
        r.pid = app.processIdentifier
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.6)
        // Chrome and Electron apps only build their accessibility tree when asked.
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(ax, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenTop = mainHeight - screen.frame.maxY
        let screenRect = CGRect(x: screen.frame.minX, y: screenTop, width: screen.frame.width, height: screen.frame.height)
        func px(_ g: CGRect) -> CGRect {
            CGRect(x: (g.minX - screen.frame.minX) * scale, y: (g.minY - screenTop) * scale, width: g.width * scale, height: g.height * scale)
        }
        func fmt(_ g: CGRect) -> String {
            let p = px(g)
            return "(\(Int(p.midX)), \(Int(p.midY)))"
        }

        r.lines.append("Front app: \(r.app)\(r.bundleID.isEmpty ? "" : " (\(r.bundleID))").")

        // Its menus (the doer can pick any menu item by name).
        if let bar = attr(ax, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() {
            let names = children(bar as! AXUIElement).dropFirst().map { str($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
            if !names.isEmpty { r.lines.append("Its menu bar: " + names.joined(separator: ", ") + ".") }
        }

        // Where typing goes right now.
        if let f = attr(ax, kAXFocusedUIElementAttribute), CFGetTypeID(f) == AXUIElementGetTypeID() {
            let el = f as! AXUIElement
            let role = str(el, kAXRoleAttribute), sub = str(el, kAXSubroleAttribute)
            let name = [str(el, kAXTitleAttribute), str(el, kAXDescriptionAttribute), str(el, kAXPlaceholderValueAttribute)].first { !$0.isEmpty } ?? ""
            var line = "Keyboard focus: \(kinds[sub] ?? kinds[role] ?? role.replacingOccurrences(of: "AX", with: "").lowercased())"
            if !name.isEmpty { line += " “\(name.prefix(40))”" }
            if sub == (kAXSecureTextFieldSubrole as String) { line += " (a password field: never type here)" }
            else if let v = attr(el, kAXValueAttribute) as? String {
                let t = v.replacingOccurrences(of: "\n", with: " ⏎ ")
                line += t.isEmpty ? " (empty)" : ", it contains: «\(t.prefix(160))\(t.count > 160 ? "…" : "")»"
            }
            if let g = frame(el) { line += " at \(fmt(g))" }
            r.lines.append(line + ".")
        }

        // Buttons and fields in the focused window (plus sheets/popovers in it), on this screen.
        guard let w = attr(ax, kAXFocusedWindowAttribute) ?? attr(ax, kAXMainWindowAttribute),
              CFGetTypeID(w) == AXUIElementGetTypeID() else { return r }
        let win = w as! AXUIElement
        let winTitle = str(win, kAXTitleAttribute)
        if !winTitle.isEmpty { r.lines.append("Window: “\(winTitle.prefix(80))”.") }
        let winRect = frame(win)?.intersection(screenRect) ?? screenRect
        guard !winRect.isNull, winRect.width > 20 else { return r }

        let deadline = Date().addingTimeInterval(budget)
        var stack: [(AXUIElement, Int)] = [(win, 0)]
        var visited = 0
        struct Found { let kind: String, label: String, extra: String, g: CGRect, isField: Bool }
        var found: [Found] = []
        var seen = Set<String>()
        while let (el, depth) = stack.popLast(), visited < 5000, found.count < 300, Date() < deadline {
            visited += 1
            let role = str(el, kAXRoleAttribute)
            let g = frame(el)
            // Skip whatever is scrolled out of view.
            if let g, depth > 0, g.width > 0, g.height > 0, !g.intersects(winRect) { continue }
            let sub = str(el, kAXSubroleAttribute)
            if let kind = kinds[sub] ?? kinds[role], let g, g.width >= 4, g.height >= 4 {
                let enabled = (attr(el, kAXEnabledAttribute) as? Bool) ?? true
                var label = [str(el, kAXTitleAttribute), str(el, kAXDescriptionAttribute),
                             str(el, kAXPlaceholderValueAttribute), str(el, kAXHelpAttribute)].first { !$0.isEmpty } ?? ""
                if label.isEmpty, role == "AXLink" || role == "AXButton" {
                    // Web links/buttons keep their words in a child.
                    label = children(el).prefix(3).map { str($0, kAXValueAttribute).isEmpty ? str($0, kAXTitleAttribute) : str($0, kAXValueAttribute) }
                        .joined(separator: " ").trimmingCharacters(in: .whitespaces)
                }
                let isField = ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
                var extra = ""
                if sub == (kAXSecureTextFieldSubrole as String) { extra = " (password field)" }
                else if isField, let v = attr(el, kAXValueAttribute) as? String {
                    extra = v.isEmpty ? " (empty)" : " = «\(v.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(50))»"
                } else if role == "AXCheckBox" || role == "AXRadioButton" || sub == "AXSwitch", let n = attr(el, kAXValueAttribute) as? NSNumber {
                    extra = n.intValue == 1 ? " (on)" : " (off)"
                } else if role == "AXPopUpButton", let v = attr(el, kAXValueAttribute) as? String, !v.isEmpty {
                    extra = " = «\(v.prefix(40))»"
                }
                if !enabled { extra += " (disabled)" }
                // Unnamed buttons are noise, unless it's a field (you can still type into it).
                if !label.isEmpty || isField {
                    let key = "\(kind)|\(label)|\(Int(g.midX / 8))|\(Int(g.midY / 8))"
                    if !seen.contains(key) {
                        seen.insert(key)
                        found.append(Found(kind: kind, label: label, extra: extra, g: g, isField: isField))
                    }
                }
                // A field's or button's insides aren't worth reading.
                if role != "AXGroup", role != "AXWebArea" { continue }
            }
            if depth < 40 {
                for c in children(el).reversed() { stack.append((c, depth + 1)) }
            }
        }
        // Keep every field (that's where typing goes), then the rest in window order, up to 100.
        let room = max(0, 100 - found.filter(\.isField).count)
        var others = 0
        var items: [String] = []
        for f in found {
            if !f.isField { guard others < room else { continue }; others += 1 }
            let id = r.elements.count + 1
            let name = f.label.isEmpty ? "" : " “\(f.label.replacingOccurrences(of: "\n", with: " ").prefix(50))”"
            r.elements[id] = Element(id: id, role: f.kind, label: f.label, rectPx: px(f.g))
            items.append("[\(id)] \(f.kind)\(name)\(f.extra) at \(fmt(f.g))")
        }
        if found.count > items.count { items.append("(\(found.count - items.count) more not listed)") }
        if !items.isEmpty {
            r.lines.append("Buttons and fields in this window (use \"el\" to act on one; x,y are screenshot pixels):\n" + items.joined(separator: "\n"))
        }
        return r
    }

    // MARK: - Menus

    /// Picks a menu item by its path, like ["Format", "Checklist"]. Returns why not, or nil when done.
    static func pickMenu(_ path: [String], pid: pid_t) -> String? {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 1.0)
        guard let bar = attr(ax, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return "this app has no menu bar" }
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "").trimmingCharacters(in: .whitespaces)
        }
        var level = children(bar as! AXUIElement)
        for (i, want) in path.enumerated() {
            let items = level.filter { !str($0, kAXTitleAttribute).isEmpty }
            let w = norm(want)
            guard let hit = items.first(where: { norm(str($0, kAXTitleAttribute)) == w })
                    ?? items.first(where: { norm(str($0, kAXTitleAttribute)).hasPrefix(w) }) else {
                let names = items.map { str($0, kAXTitleAttribute) }.prefix(40).joined(separator: ", ")
                return "no menu item “\(want)”. The items there are: \(names)"
            }
            if i == path.count - 1 {
                if (attr(hit, kAXEnabledAttribute) as? Bool) == false { return "“\(want)” is greyed out right now" }
                return AXUIElementPerformAction(hit, kAXPressAction as CFString) == .success ? nil : "couldn't pick “\(want)”"
            }
            // Its submenu's items.
            level = children(hit).flatMap { children($0) }
        }
        return "empty menu path"
    }
}
