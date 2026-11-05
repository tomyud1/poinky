import AppKit
import WebKit

/// Plays a video explainer full screen (`web/video.html`). It opens by growing out of the helper's
/// card and closes by folding back into the buddy. It sits just under the overlay, so the buddy,
/// captions and drawings stay on top and you can ask Poinky about what's on screen.
///
/// The panel takes keys (Space, ←, →, Esc go to the page) without activating Poinky, so the app you
/// were using stays the active one.
@MainActor
final class VideoWindow: NSObject, WKNavigationDelegate {
    private var panel: VideoPanel?
    private var web: WKWebView?
    private var loaded = false
    private var pendingJS: [String] = []
    private var awake: NSObjectProtocol?
    private(set) var job: VideoJob?
    private(set) var isOpen = false        // on screen (opening, playing, paused, or closing)
    private(set) var isPlaying = false
    private(set) var time: Double = 0      // the last position the page reported
    var onClosed: ((VideoJob) -> Void)?
    var onWantClose: (() -> Void)?

    /// The panel's window number, so screenshots include the video (Poinky's own windows are left out).
    var windowNumber: Int? { isOpen ? panel?.windowNumber : nil }

    /// `from`: the helper's card (screen points, top-left origin on `screen`); `pan`: -1…1 where the sound starts.
    func open(_ job: VideoJob, on screen: NSScreen, from: CGRect?, color: String, pan: Double, sound: (on: Bool, volume: Double)) {
        if isOpen { closeNow() }
        self.job = job
        guard prepareFiles() else { NSLog("Poinky: the video player is missing from the app bundle"); return }
        build(on: screen)
        isOpen = true
        isPlaying = false
        time = 0
        awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                       reason: "Playing a video explainer")
        let f = from.map { "{x:\(Int($0.minX)),y:\(Int($0.minY)),w:\(Int($0.width)),h:\(Int($0.height))}" } ?? "null"
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let manifest = job.manifestJSON.isEmpty ? "{\"scenes\":[]}" : job.manifestJSON
        js("V.open({dir: \(Self.jsString(job.dir.lastPathComponent)), manifest: \(manifest), from: \(f), color: \(Self.jsString(color)), x: \(pan), reduced: \(reduced), sound: {on: \(sound.on), volume: \(sound.volume)}})")
        panel?.orderFrontRegardless()
        panel?.makeKey()
    }

    /// The pipeline published something new (a scene, a reviewed version).
    func update() {
        guard isOpen, let job, !job.manifestJSON.isEmpty else { return }
        js("V.manifest(\(job.manifestJSON))")
    }

    func pause() { if isOpen { isPlaying = false; js("V.pause()") } }
    func resume() { if isOpen { js("V.resume()") } }

    /// Folds back into the buddy (`to`, screen points on the same screen), then goes away.
    func close(to: CGPoint?) {
        guard isOpen else { return }
        let t = to.map { "{x:\(Int($0.x)),y:\(Int($0.y))}" } ?? "null"
        js("V.close(\(t))")
        panel?.ignoresMouseEvents = true
        // In case the page never reports back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.isOpen == true, self?.panel?.ignoresMouseEvents == true { self?.closeNow() } }
    }

    /// Where it is right now (asks the page; falls back to the last reported position).
    func currentTime(_ done: @escaping (Double) -> Void) {
        guard isOpen, let web, loaded else { done(time); return }
        web.evaluateJavaScript("V.state()") { [weak self] r, _ in
            MainActor.assumeIsolated {
                if let s = r as? String, let d = s.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = o["t"] as? Double {
                    self?.time = t
                    self?.isPlaying = o["playing"] as? Bool ?? false
                }
                done(self?.time ?? 0)
            }
        }
    }

    private func closeNow() {
        guard isOpen else { return }
        isOpen = false
        isPlaying = false
        panel?.orderOut(nil)
        panel = nil
        web = nil
        loaded = false
        pendingJS.removeAll()
        if let a = awake { ProcessInfo.processInfo.endActivity(a); awake = nil }
        if let job { onClosed?(job) }
    }

    // MARK: - Page

    fileprivate func received(_ body: Any) {
        guard let m = body as? [String: Any], let kind = m["kind"] as? String else { return }
        switch kind {
        case "state":
            isPlaying = m["playing"] as? Bool ?? false
            time = m["t"] as? Double ?? time
        case "ended": isPlaying = false; VideoJob.log("played to the end")
        case "wantClose": onWantClose?()
        case "opened": VideoJob.log("full screen, playing")
        case "closed":
            time = m["t"] as? Double ?? time
            closeNow()
        case "error": VideoJob.log("page error: \(m["message"] ?? "")")
        default: break
        }
    }

    /// The page, the engine and the sounds go next to the videos, so the page can load each video's
    /// scenes and voice as plain files.
    private func prepareFiles() -> Bool {
        guard let res = Bundle.main.resourceURL else { return false }
        let fm = FileManager.default
        try? fm.createDirectory(at: VideoJob.root, withIntermediateDirectories: true)
        for (from, to) in [("web/video.html", "video.html"), ("explainer/engine.js", "engine.js"), ("web/sounds.js", "sounds.js")] {
            let src = res.appendingPathComponent(from), dst = VideoJob.root.appendingPathComponent(to)
            guard fm.fileExists(atPath: src.path) else { return false }
            try? fm.removeItem(at: dst)
            do { try fm.copyItem(at: src, to: dst) } catch { return false }
        }
        return true
    }

    private func build(on screen: NSScreen) {
        let p = VideoPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // Just under the overlay (the buddy, captions and drawings), over everything else.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.setFrame(screen.frame, display: false)

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(VideoMessageHandler(self), name: "video")
        cfg.mediaTypesRequiringUserActionForPlayback = []
        let w = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        w.navigationDelegate = self
        w.autoresizingMask = [.width, .height]
        p.contentView = w
        web = w
        loaded = false
        let page = VideoJob.root.appendingPathComponent("video.html")
        w.loadFileURL(page, allowingReadAccessTo: VideoJob.root)
        panel = p
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        for s in pendingJS { webView.evaluateJavaScript(s, completionHandler: nil) }
        pendingJS.removeAll()
        panel?.makeFirstResponder(webView)
    }

    private func js(_ script: String) {
        guard let web else { return }
        if loaded { web.evaluateJavaScript(script) { _, e in if let e { NSLog("Poinky: video js: \(e.localizedDescription)") } } }
        else { pendingJS.append(script) }
    }

    static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]), let arr = String(data: data, encoding: .utf8) else { return "\"\"" }
        return "\(arr)[0]"
    }
}

/// Takes keys without making Poinky the active app.
final class VideoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class VideoMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: VideoWindow?
    init(_ target: VideoWindow) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.received(body) }
    }
}
