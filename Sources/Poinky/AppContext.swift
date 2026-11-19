import AppKit
import ApplicationServices

/// What the app in front is showing, beyond pixels: its name, the window title, the open document
/// (a lecture PDF in Preview, an essay in Pages, a file in an editor), the web page's address,
/// and the text the user selected. Sent with every question, so "explain this paragraph",
/// "summarize this lecture" or "fix this error" work on exactly that, and helpers can start in the
/// right folder. Read through Accessibility (nothing without that permission), never from a
/// password field or an app excluded in Settings → Privacy, with short timeouts.
struct AppContext: Equatable {
    var app = ""
    var bundleID = ""
    var window = ""
    var document: URL?        // a file
    var page: String = ""     // a web address (http/https only, secret-looking query parts removed)
    var selection = ""

    static let maxSelection = 2000

    var isEmpty: Bool { app.isEmpty }

    /// The lines for Claude.
    var lines: [String] {
        guard !app.isEmpty else { return [] }
        var front = "Front app: \(app)"
        if !window.isEmpty { front += ", window “\(Self.clip(window, 120))”" }
        var out = [front + "."]
        if let d = document {
            var line = "Open document: \(Self.tilde(d.path))"
            if let root = Self.projectFolder(of: d) { line += " (in the project folder \(Self.tilde(root.path)))" }
            out.append(line + ".")
        }
        if !page.isEmpty { out.append("Web page: \(page)") }
        if !selection.isEmpty {
            out.append("The user selected this text (when they say \"this\" or \"it\" without marking anything, they most likely mean it):\n«\(selection)»")
        }
        return out
    }

    /// Where a helper should work for this document: the enclosing git repository, else its folder.
    static func projectFolder(of file: URL) -> URL? {
        let fm = FileManager.default
        var dir = file.deletingLastPathComponent()
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        while dir.path.count > 1, dir.path != home {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    /// Web pages only, without anything that looks like a secret: "…/watch?v=abc&token=x#t" → "…/watch?v=abc".
    /// (The query often says what the page is: YouTube's v=, Wikipedia's title=, a search's q=.)
    static func cleanURL(_ s: String) -> String {
        guard var c = URLComponents(string: s), let scheme = c.scheme, ["http", "https"].contains(scheme) else { return "" }
        let secret = ["token", "key", "auth", "sig", "code", "session", "sess", "pass", "secret", "access", "credential", "jwt", "otp", "ticket", "nonce", "state"]
        let kept = (c.queryItems ?? []).filter { item in
            let n = item.name.lowercased()
            let v = item.value ?? ""
            return !secret.contains(where: { n.contains($0) }) && v.count <= 40
        }
        c.queryItems = kept.isEmpty ? nil : kept
        c.fragment = nil
        c.user = nil
        c.password = nil
        return c.string ?? ""
    }
}

enum AppContextReader {
    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    private static func str(_ el: AXUIElement, _ name: String) -> String {
        (attr(el, name) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    private static func url(_ v: CFTypeRef?) -> String {
        guard let v else { return "" }
        if CFGetTypeID(v) == CFURLGetTypeID() { return (v as! URL).absoluteString }
        return (v as? String) ?? ""
    }

    /// Reads the front app (call off the main thread; each Accessibility call gives up after 0.25 s).
    static func read(app: NSRunningApplication?, excluded: Set<String>) -> AppContext {
        var c = AppContext()
        guard AXIsProcessTrusted(), let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !excluded.contains(app.bundleIdentifier ?? "") else { return c }
        c.app = app.localizedName ?? ""
        c.bundleID = app.bundleIdentifier ?? ""
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.25)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)   // Chrome, Electron

        if let w = element(attr(ax, kAXFocusedWindowAttribute)) ?? element(attr(ax, kAXMainWindowAttribute)) {
            c.window = str(w, kAXTitleAttribute)
            let doc = url(attr(w, kAXDocumentAttribute))
            if let u = URL(string: doc), u.isFileURL { c.document = u.standardizedFileURL }
            else if !doc.isEmpty { c.page = AppContext.cleanURL(doc) }   // Safari puts the page here
            if c.page.isEmpty, c.document == nil { c.page = webPage(in: w) }
        }

        if let f = element(attr(ax, kAXFocusedUIElementAttribute)) {
            let role = str(f, kAXRoleAttribute), sub = str(f, kAXSubroleAttribute)
            if role != "AXSecureTextField", sub != "AXSecureTextField" {
                let s = str(f, kAXSelectedTextAttribute)
                if !s.isEmpty { c.selection = AppContext.clip(s, AppContext.maxSelection) }
            }
        }
        return c
    }

    /// The page address from a browser's web area (Chrome, Arc, Edge, Electron), looking a short way down.
    private static func webPage(in window: AXUIElement) -> String {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var seen = 0
        while !queue.isEmpty, seen < 300 {
            let (el, depth) = queue.removeFirst()
            seen += 1
            if str(el, kAXRoleAttribute) == "AXWebArea" {
                let u = AppContext.cleanURL(url(attr(el, "AXURL")))
                if !u.isEmpty { return u }
            }
            guard depth < 10 else { continue }
            for ch in (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { queue.append((ch, depth + 1)) }
        }
        return ""
    }
}
