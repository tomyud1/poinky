import AppKit
import WebKit

/// The Helpers window (web/helper-window.html): a list of helpers on the left (working ones first, then
/// earlier ones, also from before Poinky restarted), and the selected one's work on the right: its task,
/// what it wrote, its steps, its to-do list, what it asked and what you answered, and how it ended,
/// updated live. A box at the bottom sends it a message, or continues a finished one.
@MainActor
final class HelperWindows: NSObject, NSWindowDelegate, WKNavigationDelegate {
    weak var agents: AgentManager?
    /// Allow / Don't allow (You choose / Skip, Go ahead / Not now) clicked for a request, by its id.
    var onAnswer: ((_ id: Int, _ requestID: String, _ yes: Bool) -> Void)?
    /// Something typed while it waits for an answer, read as one (yes, no, a choice, what to change in a plan).
    var onTypedAnswer: ((_ id: Int, _ reply: HelperAsk.Reply, _ text: String) -> Void)?
    /// Pause in its window (the app also shows it paused on screen).
    var onPause: ((_ id: Int) -> Void)?
    /// Something typed to a finished helper: continue it (the app starts it). Returns the new helper.
    var onResume: ((_ past: PastHelper, _ text: String) -> AgentManager.Agent?)?

    private var window: NSWindow?
    private var web: WKWebView?
    private var loaded = false
    private var pending: [String] = []
    /// What's shown: "a<id>" (a helper of this run) or "f<path>" (an earlier one, from its saved window).
    private var selected: String?
    private var listWork: DispatchWorkItem?
    private var past: [PastHelper] = []

    var isOpen: Bool { window?.isVisible == true }
    /// The helper of this run that's shown (nil: none, or an earlier one).
    var shownID: Int? { selected.flatMap { $0.hasPrefix("a") ? Int($0.dropFirst()) : nil } }

    /// Opens the window on a helper of this run.
    func show(_ id: Int) { select("a\(id)") }

    /// Opens the window on a helper by its log (one of this run, or an earlier one).
    func show(log: URL) {
        if let a = agents?.agents.last(where: { $0.log.place == log.place }) { select("a\(a.id)"); return }
        select("f" + log.deletingPathExtension().appendingPathExtension("chat.jsonl").path)
    }

    /// Opens the window on the newest helper.
    func showList() {
        if isOpen, selected != nil { bringForward(); return }
        if window == nil { build() }
        reloadPast()
        select((items().first?["key"] as? String) ?? "")
    }

    private func select(_ key: String) {
        let opening = window == nil
        if opening { build() }
        if opening || key.hasPrefix("f") { reloadPast() }
        selected = key.isEmpty ? nil : key
        pushList(now: true)
        pushSelected()
        bringForward()
    }

    private func bringForward() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - From the helpers

    /// A new line for a helper's window.
    func entry(_ a: AgentManager.Agent, _ e: HelperEntry) {
        guard window != nil else { return }
        if selected == "a\(a.id)" {
            run("HW.add(\(e.json))")
            run("HW.status(\(Self.json(state(a, entries: false))))")
        }
        pushList()
    }

    /// Something changed (status, what it's doing now, waiting for you).
    func updateAll() {
        guard window != nil, let agents else { return }
        if let id = shownID, let a = agents.agents.first(where: { $0.id == id }) {
            run("HW.status(\(Self.json(state(a, entries: false))))")
        }
        pushList()
    }

    // MARK: - What the page shows

    private func reloadPast() {
        let mine = Set((agents?.agents ?? []).map(\.chat.place))
        past = PastHelper.list(in: AgentManager.logDir, limit: 60, excluding: mine)
    }

    /// The list on the left: this run's helpers (working first, then newest), then earlier ones.
    private func items() -> [[String: Any]] {
        let all = agents?.agents ?? []
        let live = all.filter { $0.status == .running || $0.status == .queued }
        let finished = Array(all.filter { $0.status != .running && $0.status != .queued }.reversed())
        var out: [[String: Any]] = (live + finished).map { a in
            ["key": "a\(a.id)", "name": a.name, "title": a.title, "color": Self.color(a.name), "status": a.status.rawValue,
             "waiting": !a.asks.isEmpty, "paused": a.paused, "ago": a.finished.map { CallController.ago($0) } ?? ""]
        }
        let mine = Set(all.map(\.chat.place))
        for p in past where !mine.contains(p.chat.place) {
            out.append(["key": "f" + p.chat.path, "name": p.name, "title": p.title, "color": Self.color(p.name),
                        "status": p.status, "waiting": false, "paused": false, "ago": CallController.ago(p.started), "earlier": true])
        }
        return out
    }

    private func pushList(now: Bool = false) {
        guard window != nil else { return }
        listWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.run("HW.list(\(Self.json(self.items())), \(Self.str(self.selected ?? "")))")
        }
        listWork = work
        if now { work.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work) }
    }

    private func pushSelected() {
        guard let key = selected else { run("HW.empty()"); return }
        if key.hasPrefix("a"), let id = Int(key.dropFirst()), let a = agents?.agents.first(where: { $0.id == id }) {
            run("HW.init(\(Self.json(state(a, entries: true))))")
            window?.title = "\(a.name) — \(a.title)"
        } else if key.hasPrefix("f"), let p = pastHelper(key) {
            let d: [String: Any] = ["name": p.name, "title": p.title, "color": Self.color(p.name), "status": p.status,
                                    "entries": HelperEntry.read(p.chat).compactMap { try? JSONSerialization.jsonObject(with: Data($0.json.utf8)) },
                                    "resumable": true]
            run("HW.init(\(Self.json(d)))")
            window?.title = "\(p.name) — \(p.title)"
        } else {
            selected = nil
            run("HW.empty()")
        }
    }

    private func pastHelper(_ key: String) -> PastHelper? {
        guard key.hasPrefix("f") else { return nil }
        let path = String(key.dropFirst())
        return past.first { $0.chat.path == path } ?? PastHelper.load(chat: URL(fileURLWithPath: path))
    }

    private func state(_ a: AgentManager.Agent, entries: Bool) -> [String: Any] {
        var d: [String: Any] = [
            "status": a.status.rawValue,
            "waiting": !a.asks.isEmpty,
            "paused": a.paused,
            "now": a.latest,
            "elapsed": (a.finished ?? Date()).timeIntervalSince(a.started),
            "resumable": true,
        ]
        if entries {
            d["name"] = a.name
            d["title"] = a.title
            d["color"] = Self.color(a.name)
            d["entries"] = a.entries.compactMap { try? JSONSerialization.jsonObject(with: Data($0.json.utf8)) }
        }
        return d
    }

    /// The same colors as the helpers on screen (web/helpers.js).
    static let colors = ["Mint": "#34c98e", "Coral": "#ff7a59", "Violet": "#9b6bff", "Amber": "#ffb020", "Rose": "#ff5c9a", "Sky": "#38bdf8"]
    static func color(_ name: String) -> String { colors[name.components(separatedBy: " ")[0]] ?? "#34c98e" }

    // MARK: - From the page

    fileprivate func received(_ body: Any) {
        guard let msg = body as? [String: Any], let type = msg["type"] as? String else { return }
        if type == "select", let key = msg["key"] as? String { select(key); return }
        guard let agents, let key = selected else { return }
        let a = shownID.flatMap { id in agents.agents.first { $0.id == id } }
        switch type {
        case "send":
            guard let text = (msg["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            guard let a, a.status == .running || a.status == .queued else {
                // Finished (this run or earlier): it picks up where it left off.
                if let p = a.map({ agents.past($0) }) ?? pastHelper(key), let started = onResume?(p, text) { select("a\(started.id)") }
                else { hint("It couldn’t continue: is Claude Code installed?", warn: true) }
                return
            }
            let id = a.id
            // Waiting for your answer: what you type answers it, if it reads as one.
            if let ask = a.asks.first {
                let reply = ask.reply(to: text, addressed: true)   // for a plan: what to change
                if reply != .unclear { onTypedAnswer?(id, reply, text); return }
                if ask.kind == .permission {
                    hint("\(a.name) is waiting for your OK first: Allow, Don’t allow, or type yes or no.", warn: true)
                    return
                }
            }
            let sent = HelperTalk.isRedirect(text) ? agents.redirect(id: id, text: text) : agents.send(id: id, text: text)
            if !sent { hint("\(a.name) can’t get messages right now.", warn: true) }
        case "answer":
            guard let a, let rid = msg["id"] as? String else { return }
            onAnswer?(a.id, rid, (msg["ok"] as? Bool) ?? false)
        case "stop": if let a { agents.stop(id: a.id) }
        case "pause": if let a { onPause?(a.id) }
        case "resume": if let a { agents.resume(id: a.id) }
        case "undo":
            guard let p = a.map({ agents.past($0) }) ?? pastHelper(key), let run = msg["run"] as? Int else { return }
            let confirmed = (msg["confirmed"] as? Bool) == true
            agents.undo(p, run: run, dryRun: !confirmed) { [weak self] outcome in
                guard let self, self.selected == key else { return }
                switch outcome {
                case .preview(let pv):
                    self.run("HW.undoAsk(\(run), \(Self.str(pv.files.isEmpty ? "" : HelperUndo.names(pv.files))), \(Self.str(pv.changedSince.isEmpty ? "" : HelperUndo.names(pv.changedSince))))")
                case .done:
                    if a == nil { self.pushSelected() }   // an earlier helper: show its window again, with the undo
                case .failed(let why):
                    self.hint("Couldn’t undo: \(why)", warn: true)
                    self.pushSelected()
                }
            }
        case "folder": if let dir = a?.dir ?? pastHelper(key)?.dir { NSWorkspace.shared.open(dir) }
        case "log": if let log = a?.log ?? pastHelper(key)?.log { NSWorkspace.shared.open(log) }
        default: break
        }
    }

    private func hint(_ text: String, warn: Bool) { run("HW.hint(\(Self.str(text)), \(warn))") }

    // MARK: - For tests

    /// Runs JavaScript in the window and returns the result.
    func evaluateForTest(_ js: String, _ done: @escaping (Any?) -> Void) {
        guard let web else { done(nil); return }
        web.evaluateJavaScript(js) { r, _ in done(r) }
    }

    /// A picture of the window.
    func snapshotForTest(to url: URL) {
        web?.takeSnapshot(with: nil) { img, _ in
            guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        }
    }

    func close() { window?.close() }

    // MARK: - Plumbing

    private func build() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(HWMessages(self), name: "hw")
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.navigationDelegate = self
        w.setValue(false, forKey: "drawsBackground")
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 660),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.title = "Helpers"
        win.minSize = NSSize(width: 420, height: 380)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = w
        win.center()
        win.setFrameAutosaveName("PoinkyHelpers")
        window = win
        web = w
        loaded = false
        if let url = Bundle.main.url(forResource: "helper-window", withExtension: "html", subdirectory: "web") {
            w.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }

    private func run(_ js: String) {
        guard let web else { return }
        if loaded { web.evaluateJavaScript(js, completionHandler: nil) } else { pending.append(js) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        for js in pending { webView.evaluateJavaScript(js, completionHandler: nil) }
        pending.removeAll()
    }

    func windowWillClose(_ notification: Notification) {
        web?.configuration.userContentController.removeScriptMessageHandler(forName: "hw")
        listWork?.cancel()
        window = nil
        web = nil
        loaded = false
        pending.removeAll()
        selected = nil
    }

    /// A value as JavaScript (JSON).
    static func json(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v),
              let s = String(data: d, encoding: .utf8) else { return "null" }
        return s
    }

    /// A string as JavaScript.
    static func str(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed) else { return "\"\"" }
        return String(data: d, encoding: .utf8) ?? "\"\""
    }
}

private final class HWMessages: NSObject, WKScriptMessageHandler {
    weak var target: HelperWindows?
    init(_ target: HelperWindows) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.received(body) }
    }
}
