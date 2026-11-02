import AppKit
import WebKit

/// A transparent, always-on-top window covering one screen.
/// Clicks pass straight through it, except over a card (so you can drag, rotate or close it)
/// and while you hold ⌥ to mark things.
@MainActor
final class Overlay: NSObject, WKNavigationDelegate {
    struct SceneItem { let id: String; let type: String; let label: String; let box: [Int]? }

    /// You finished drawing a mark (⌥ + click / drag).
    var onMarkAdded: (() -> Void)?

    /// Errors from inside a card (e.g. broken 3D code): id, type, message.
    var onCardError: ((String, String, String) -> Void)?
    var onClear: (() -> Void)?        // the Clear button on the overlay was clicked
    /// A button on a helper's card: id, "stop" / "log" / "folder".
    var onHelperAction: ((Int, String) -> Void)?

    private var panel: OverlayPanel?
    private var web: WKWebView!
    private var markView: MarkView!
    private var loaded = false
    private var pendingJS: [String] = []
    private(set) var screen: NSScreen?
    private(set) var isMarking = false
    private var isHoveringCard = false
    private(set) var scene: [SceneItem] = []
    private var cardRects: [CGRect] = []

    var marks: [Mark] { markView?.marks ?? [] }

    /// What's drawn right now, described for Claude (in screenshot pixels).
    func sceneDescription(scale: CGFloat) -> String {
        guard !scene.isEmpty else { return "Nothing is drawn on screen right now." }
        let lines = scene.map { item -> String in
            var s = "- \(item.type) id=\"\(item.id)\""
            if !item.label.isEmpty { s += " “\(item.label)”" }
            if let b = item.box, b.count == 4 {
                let px = b.map { Int((CGFloat($0) * scale).rounded()) }
                s += " at x=\(px[0]) y=\(px[1]) w=\(px[2]) h=\(px[3])"
            }
            return s
        }
        return "Already drawn on screen:\n" + lines.joined(separator: "\n")
    }

    func show(on screen: NSScreen) {
        if panel == nil { build() }
        wantsHidden = false
        helperCursorTimer?.invalidate(); helperCursorTimer = nil
        keepAwake(true)
        self.screen = screen
        guard let panel else { return }
        panel.setFrame(screen.frame, display: true)
        if let content = panel.contentView {
            web.frame = content.bounds
            markView.frame = content.bounds
        }
        panel.orderFrontRegardless()
    }

    // MARK: The buddy at your cursor

    private var lastTick = ""

    /// Moves the buddy to the cursor (nil: the cursor is on another screen). `level`: mic level 0…1.
    func tick(cursor: CGPoint?, level: Float) {
        let s = cursor.map { "SB.tick(\(Int($0.x)),\(Int($0.y)),\(String(format: "%.2f", level)))" } ?? "SB.tick(null,null,0)"
        guard s != lastTick else { return }
        lastTick = s
        js(s)
    }

    /// "ready", "listening", "thinking", "speaking", "starting" or "off"; `guide`: a walkthrough is running.
    func setPhase(_ phase: String, guide: Bool = false) {
        js("SB.phase(\(jsString(phase)), \(guide))")
    }

    func setBuddy(_ on: Bool) { js("SB.buddyOn(\(on))") }
    func showBuddy(_ on: Bool) { js("SB.buddyShow(\(on))") }

    func hide() {
        setMarking(false)
        clearAll()
        setCaption(you: nil, claude: nil)
        setPhase("off")
        setArtistBusy(false)
        wantsHidden = true
        // Helpers keep working after a session ends: the overlay stays up (click-through) until they're gone.
        if helperCount > 0 { followCursorForHelpers() } else { panel?.orderOut(nil); keepAwake(false) }
    }

    /// While anything is on screen, macOS must not "nap" Poinky: with no session (no audio running)
    /// it would slow its timers and pause the page's animations, and helpers would freeze mid-flight.
    private var awake: NSObjectProtocol?
    private func keepAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                          reason: "Poinky is animating on screen")
        } else if !on, let a = awake {
            ProcessInfo.processInfo.endActivity(a)
            awake = nil
        }
    }

    // MARK: Helpers (background agents) on screen, web/helpers-app.js

    var isShown: Bool { panel?.isVisible == true }
    /// Helpers on screen right now (reported by the page).
    private(set) var helperCount = 0
    private var wantsHidden = true
    private var helperCursorTimer: Timer?

    /// A helper is starting: make sure the overlay is up (on the screen with the mouse if no session has it).
    /// Open helper cards (they take clicks).
    private var helperRects: [CGRect] = []
    private var lastAvoid = ""

    func helperSpawn(id: Int, name: String, task: String, note: Int, detail: String, folder: String) {
        if panel?.isVisible != true {
            let mouse = NSEvent.mouseLocation
            let s = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
            let hidden = wantsHidden
            show(on: s)
            wantsHidden = hidden
            if hidden { setPhase("off"); followCursorForHelpers() }
        }
        helperCount = max(helperCount, 1)   // until the page reports
        js("SB.helperSpawn(\(id), \(jsString(name)), \(jsString(task)), \(note), \(jsString(detail)), \(jsString(folder)))")
    }
    func helperStep(id: Int, text: String) { js("SB.helperStep(\(id), \(jsString(text)))") }
    func helperChecklist(id: Int, items: [HelperTask]) {
        let list = items.map { ["text": $0.text, "state": $0.state.rawValue] }
        let json = (try? JSONSerialization.data(withJSONObject: list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        js("SB.helperChecklist(\(id), \(json))")
    }
    func helperDone(id: Int, ok: Bool, summary: String) { js("SB.helperDone(\(id), \(ok), \(jsString(summary)))") }
    func helperStop(id: Int) { js("SB.helperStop(\(id))") }
    /// Poinky is about to say what these helpers did: they fly to the buddy and wait there.
    func helperReport(ids: [Int]) { if !ids.isEmpty { js("SB.helperReport(\(ids))") } }
    /// Done saying it: they merge into the buddy.
    func helperRelease(ids: [Int]) { if !ids.isEmpty { js("SB.helperRelease(\(ids))") } }
    func helperSounds(on: Bool, volume: Double) { js("SB.helperSounds(\(on), \(volume))") }
    /// The window you're using, in this overlay's points (nil: none).
    func helperAvoid(_ r: CGRect?) {
        let s = r.map { "{x:\(Int($0.minX)),y:\(Int($0.minY)),w:\(Int($0.width)),h:\(Int($0.height))}" } ?? "null"
        guard s != lastAvoid else { return }
        lastAvoid = s
        js("SB.helperAvoid(\(s))")
    }
    /// For developer checks: run JavaScript in the overlay page.
    func evaluateForTest(_ script: String) { js(script) }
    func evaluateForTest(_ script: String, done: @escaping (Any?) -> Void) {
        guard web != nil, loaded else { done(nil); return }
        web.evaluateJavaScript(script) { r, _ in done(r) }
    }

    /// With no session running, the buddy is hidden but helpers still need to know where it would be.
    private func followCursorForHelpers() {
        guard helperCursorTimer == nil else { return }
        helperCursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let screen = self.screen else { return }
                let loc = NSEvent.mouseLocation
                let p = NSMouseInRect(loc, screen.frame, false) ? CGPoint(x: loc.x - screen.frame.minX, y: screen.frame.maxY - loc.y) : nil
                self.tick(cursor: p, level: 0)
                self.trackMouse()   // an open helper card takes clicks
            }
        }
    }

    private func helpersChanged(_ count: Int) {
        helperCount = count
        guard count == 0, wantsHidden else { return }
        helperCursorTimer?.invalidate(); helperCursorTimer = nil
        panel?.orderOut(nil)
        keepAwake(false)
    }

    /// What the overlay shows right now, as a PNG (developer checks).
    func snapshot(to url: URL, done: @escaping () -> Void) {
        guard let web else { done(); return }
        web.takeSnapshot(with: nil) { image, _ in
            if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
            done()
        }
    }

    func setMarking(_ on: Bool) {
        guard on != isMarking else { return }
        isMarking = on
        markView?.isMarking = on
        updateMouse()
        js("SB.marking(\(on ? "true" : "false"))")
    }

    /// Called often with the mouse position; lets the mouse reach a card while you hover it.
    func trackMouse() {
        guard let screen, panel?.isVisible == true else { return }
        let loc = NSEvent.mouseLocation
        let p = CGPoint(x: loc.x - screen.frame.minX, y: screen.frame.maxY - loc.y)
        let over = (!contentHidden && cardRects.contains { $0.insetBy(dx: -2, dy: -2).contains(p) })
            || helperRects.contains { $0.insetBy(dx: -2, dy: -2).contains(p) }
        if over != isHoveringCard {
            isHoveringCard = over
            updateMouse()
        }
    }

    private func updateMouse() {
        panel?.ignoresMouseEvents = !(isMarking || isHoveringCard)
    }

    /// `json` is already-validated JSON; `scale` is screenshot pixels per screen point.
    func apply(_ json: String, scale: CGFloat) {
        let k = scale > 0 ? 1 / scale : 1
        js("SB.apply(\(json), \(k))")
    }

    // MARK: Lessons (the paper window and the yellow pen)

    /// Opens a fresh paper at `frame` (screen points, top-left origin).
    /// `continuing`: keep drawing on the paper that's already open (a follow-up), if there is one.
    /// `avoid`: what's being explained; the paper never moves over it when it needs more room.
    func lessonBegin(frame: CGRect, title: String, continuing: Bool = false, avoid: CGRect? = nil) {
        let a = avoid.map { ",avoid:{x:\(Int($0.minX)),y:\(Int($0.minY)),w:\(Int($0.width)),h:\(Int($0.height))}" } ?? ""
        js("SB.lessonBegin({x:\(Int(frame.minX)),y:\(Int(frame.minY)),w:\(Int(frame.width)),h:\(Int(frame.height)),h0:240\(a)}, \(jsString(title)), \(continuing))")
    }

    // MARK: Drawings follow their window

    private(set) var contentHidden = false
    func shiftContent(dx: CGFloat, dy: CGFloat) { js("SB.shift(\(dx), \(dy))") }
    func bakeContent() { js("SB.bake()") }
    func setContentVisible(_ on: Bool) {
        guard on == contentHidden else { return }
        contentHidden = !on
        js("SB.setVisible(\(on))")
        trackMouse()
    }

    // MARK: Captions
    func captionsAtTop(_ top: Bool) { js("SB.captionsAt(\(top))") }
    func fadeCaptions() { js("SB.fadeCaptions()") }

    /// Runs more code inside an existing 3D model (a narrated step or a follow-up addition).
    func run3d(id: String, code: String) {
        js("SB.run3d(\(jsString(id)), \(jsString(code)))")
    }

    /// More code of a 3D model that's still being written: it runs statement by statement as it arrives.
    func feed3d(id: String, code: String) {
        js("SB.feed3d(\(jsString(id)), \(jsString(code)))")
    }

    /// The 3D model's code is complete (runs whatever is left).
    /// A photo (data URL) pinned like a polaroid to the corner of the card with id `forId` (or top right).
    func showPhoto(forId: String?, src: String, caption: String) {
        var o: [String: Any] = ["src": src, "caption": caption]
        if let forId { o["for"] = forId }
        guard let data = try? JSONSerialization.data(withJSONObject: o), let json = String(data: data, encoding: .utf8) else { return }
        js("SB.photo(\(json))")
    }

    func end3d(id: String) {
        js("SB.end3d(\(jsString(id)))")
    }

    /// Queues one drawing step. `json` is {"ops":[…]}; screen marks inside use screenshot pixels.
    func lessonStep(_ json: String, scale: CGFloat) {
        let k = scale > 0 ? 1 / scale : 1
        js("SB.lessonStep(\(json), \(k))")
    }

    func lessonStop() { js("SB.lessonStop()") }

    /// Screen rectangles of things currently drawn (cards and the paper), in points.
    var occupiedRects: [CGRect] { cardRects }

    func clearAnnotations() { js("SB.clearAnnotations()") }
    func fadeAnnotations() { js("SB.fadeAnnotations()") }
    /// A small ring where Poinky clicks for you (screen points).
    func ripple(at p: CGPoint) { js("SB.ripple && SB.ripple(\(p.x), \(p.y))") }
    func clearAll() { js("SB.clearAll()") }
    func clearMarks() { markView?.clear() }

    func setCaption(you: String?, claude: String?) {
        setYouCaption(you)
        setClaudeCaption(claude)
    }
    func setClaudeCaption(_ text: String?) { js("SB.caption('claude', \(jsString(text)))") }
    func setYouCaption(_ text: String?) { js("SB.caption('you', \(jsString(text)))") }
    func setArtistBusy(_ on: Bool) { js("SB.artist(\(on ? "true" : "false"))") }

    // MARK: - Setup

    private func build() {
        let p = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let container = NSView()
        container.wantsLayer = true

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(WeakMessageHandler(self), name: "sb")
        cfg.mediaTypesRequiringUserActionForPlayback = []   // lets the paper make its soft sound
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        w.navigationDelegate = self
        w.autoresizingMask = [.width, .height]
        web = w

        let mv = MarkView()
        mv.autoresizingMask = [.width, .height]
        mv.onMarkAdded = { [weak self] in self?.onMarkAdded?() }
        markView = mv

        container.addSubview(w)
        container.addSubview(mv)
        p.contentView = container
        if let url = Bundle.main.url(forResource: "overlay", withExtension: "html", subdirectory: "web") {
            w.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            NSLog("Poinky: overlay.html missing from the app bundle")
        }
        panel = p
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        for s in pendingJS { webView.evaluateJavaScript(s, completionHandler: nil) }
        pendingJS.removeAll()
    }

    fileprivate func received(_ body: Any) {
        guard let msg = body as? [String: Any], let kind = msg["kind"] as? String else { return }
        switch kind {
        case "scene":
            let items = (msg["items"] as? [[String: Any]]) ?? []
            scene = items.map {
                SceneItem(id: "\($0["id"] ?? "")", type: "\($0["type"] ?? "")",
                          label: "\($0["label"] ?? "")", box: ($0["box"] as? [NSNumber])?.map(\.intValue))
            }
            cardRects = ((msg["rects"] as? [[NSNumber]]) ?? []).compactMap { r in
                r.count == 4 ? CGRect(x: r[0].doubleValue, y: r[1].doubleValue, width: r[2].doubleValue, height: r[3].doubleValue) : nil
            }
            trackMouse()
        case "error":
            onCardError?("\(msg["id"] ?? "")", "\(msg["type"] ?? "")", "\(msg["message"] ?? "")")
        case "clear":
            onClear?()
        case "helpers":
            helpersChanged((msg["count"] as? NSNumber)?.intValue ?? 0)
        case "helperRects":
            helperRects = ((msg["rects"] as? [[NSNumber]]) ?? []).compactMap { r in
                r.count == 4 ? CGRect(x: r[0].doubleValue, y: r[1].doubleValue, width: r[2].doubleValue, height: r[3].doubleValue) : nil
            }
            trackMouse()
        case "helperAction":
            if let id = Int("\(msg["id"] ?? "")"), let action = msg["action"] as? String { onHelperAction?(id, action) }
        default:
            break
        }
    }

    private func js(_ script: String) {
        guard web != nil else { return }
        if loaded { web.evaluateJavaScript(script, completionHandler: nil) } else { pendingJS.append(script) }
    }

    private func jsString(_ s: String?) -> String {
        guard let s else { return "null" }
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: data, encoding: .utf8) else { return "null" }
        return "\(arr)[0]"
    }
}

/// Avoids a retain cycle between the web view and the overlay.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: Overlay?
    init(_ target: Overlay) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.received(body) }
    }
}

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Captures ⌥ + click (pin) and ⌥ + drag (circle / underline) and draws them in red.
final class MarkView: NSView {
    var isMarking = false
    var onMarkAdded: (() -> Void)?
    private(set) var marks: [Mark] = []
    private var current: [CGPoint] = []

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isMarking ? self : nil }

    func clear() {
        marks.removeAll()
        current.removeAll()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        current = [convert(event.locationInWindow, from: nil)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    // ⌃-click counts as a right click in macOS: while holding ⌃⌥ to talk, treat it as a normal mark.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }

    override func mouseUp(with event: NSEvent) {
        guard !current.isEmpty else { return }
        current.append(convert(event.locationInWindow, from: nil))
        let xs = current.map(\.x), ys = current.map(\.y)
        let spread = (xs.max()! - xs.min()!) + (ys.max()! - ys.min()!)
        if spread < 8 {
            marks.append(Mark(kind: .pin, points: [current[0]]))
        } else {
            marks.append(Mark(kind: .stroke, points: current))
        }
        current.removeAll()
        needsDisplay = true
        onMarkAdded?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let red = NSColor(calibratedRed: 1, green: 0.23, blue: 0.19, alpha: 0.95)
        red.setStroke()
        red.setFill()
        var all = marks
        if current.count > 1 { all.append(Mark(kind: .stroke, points: current)) }
        for m in all {
            switch m.kind {
            case .stroke:
                guard let first = m.points.first else { continue }
                let p = NSBezierPath()
                p.lineWidth = 5
                p.lineCapStyle = .round
                p.lineJoinStyle = .round
                p.move(to: first)
                for pt in m.points.dropFirst() { p.line(to: pt) }
                p.stroke()
            case .pin:
                guard let c = m.points.first else { continue }
                let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28))
                ring.lineWidth = 4
                ring.stroke()
                NSBezierPath(ovalIn: NSRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)).fill()
            }
        }
    }
}
