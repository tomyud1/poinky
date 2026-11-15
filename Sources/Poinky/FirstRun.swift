import AppKit
import AVFoundation
import SwiftUI

/// Two small first-run moments, no model calls:
///  - Hello: right after the welcome tour's Done, the buddy appears at the cursor and greets you out loud
///    (by name if "About me" has one), in your voice (Apple's until the natural one is installed).
///  - "I live here": the first time a session ends (once ever, `AppConfig.homeShown`), the buddy flies up to
///    the notch (or the menu bar icon on a Mac without one), the notch opens a little with a glow, it says where
///    to find it, and tucks in. Reduced Motion: a fade instead of the flight (web/buddy.js `SB.homeGo`).
/// Both wait until you're free (no session, not typing, screen unlocked, tour closed), and stop the moment
/// you hold or tap the keys or press any key. Timeline: `firstrun.*`. Test picture: POINKY_FIRSTRUN_SHOT=<dir>.
@MainActor
final class FirstRun: NSObject, AVSpeechSynthesizerDelegate {
    private let overlay: Overlay
    private let phonon: PhononVoice
    private let notch: NotchModel
    private let menuIconFrame: () -> CGRect?
    private let isFree: () -> Bool
    private let sessionIdle: () -> Bool

    private var helloPending = false
    private var homePending = false
    private var running: String?          // "hello" / "home"
    private var gen = 0
    private var waitTries = 0
    private var waiting = false
    private var ticker: Timer?
    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()
    private var onSpoken: (() -> Void)?
    private var shownOn: NSScreen?
    private var startedAt: TimeInterval = 0

    init(overlay: Overlay, phonon: PhononVoice, notch: NotchModel, menuIconFrame: @escaping () -> CGRect?,
         isFree: @escaping () -> Bool, sessionIdle: @escaping () -> Bool) {
        self.overlay = overlay
        self.phonon = phonon
        self.notch = notch
        self.menuIconFrame = menuIconFrame
        self.isFree = isFree
        self.sessionIdle = sessionIdle
        super.init()
        synth.delegate = self
    }

    var isRunning: Bool { running != nil }

    // MARK: Triggers

    /// A session ended (not when quitting): the first time, show where Poinky lives.
    func sessionEnded() {
        guard !AppConfig.load().homeShown, running == nil else { return }
        homePending = true
        later(1.6)
    }

    /// The tour's Done: say hello. If a session already ended during the tour, "I live here" follows it.
    func tourFinished() {
        helloPending = true
        later(0.7)
    }

    /// A session is starting, or the keys were tapped: stop whatever is showing (it doesn't come back).
    func interrupt(_ why: String) {
        if why == "reset" { homePending = false; helloPending = false }   // not right after "I got stuck"
        guard let r = running else { return }
        Timeline.log("firstrun.cut", ["what": r, "why": why])
        gen += 1
        running = nil
        helloPending = false
        stopVoice()
        ticker?.invalidate(); ticker = nil
        notch.beckon = false
        overlay.setPhase("off")   // the buddy goes back to the cursor for the session
        if sessionIdle() { overlay.hide() }
    }

    // MARK: Waiting for a free moment

    private func later(_ secs: Double) {
        guard !waiting else { return }
        waiting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            guard let self else { return }
            self.waiting = false
            self.tryNext()
        }
    }

    private func tryNext() {
        guard running == nil, helloPending || homePending else { return }
        guard isFree() else {
            waitTries += 1
            // Up to ~10 minutes; after that "I live here" waits for the next session to end.
            if waitTries > 600 { waitTries = 0; helloPending = false; homePending = false; Timeline.log("firstrun.gaveUp"); return }
            later(1)
            return
        }
        waitTries = 0
        if helloPending { helloPending = false; runHello() }
        else if homePending { homePending = false; runHome() }
    }

    // MARK: Hello

    private func runHello() {
        let cfg = AppConfig.load()
        let screen = Self.screenWithMouse()
        let line = FirstRunWords.greeting(name: Self.userName(), keys: Self.spokenKeys(cfg))
        Timeline.log("firstrun.hello", ["named": Self.userName() != nil])
        begin("hello", on: screen, buddy: cfg.buddy)
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.gen == g else { return }
            self.shoot("hello")
            self.say(line, cfg: cfg) { [weak self] in
                guard let self, self.gen == g else { return }
                self.overlay.setPhase("ready")
                self.overlay.fadeCaptions()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    guard let self, self.gen == g else { return }
                    // The first session already ended during the tour: show home right away, same buddy.
                    if !AppConfig.load().homeShown, self.homePending {
                        self.homePending = false
                        self.running = nil
                        self.runHome(continuing: true)
                    } else {
                        self.finish()
                    }
                }
            }
        }
    }

    // MARK: "I live here"

    private func runHome(continuing: Bool = false) {
        var cfg = AppConfig.load()
        cfg.homeShown = true          // once ever, even if it's cut short
        cfg.save()
        // Where home is: the notch's bottom center, or the menu bar icon (screen points, top-left origin).
        let notchScreen = NotchHome.notchScreen
        let iconFrame = notchScreen == nil ? menuIconFrame() : nil
        guard let screen = notchScreen ?? iconFrame.flatMap(Self.screen(containing:)) ?? NSScreen.main else { return }
        let target: CGPoint, face: CGPoint, line: String
        if notchScreen != nil, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let notchW = screen.frame.width - l.width - r.width
            let x = l.width + notchW / 2, top = screen.safeAreaInsets.top
            target = CGPoint(x: x, y: top + 18); face = CGPoint(x: x, y: 0)
            line = "This is where I live. Hover over the notch any time for my controls."
        } else if let f = iconFrame {
            let x = f.midX - screen.frame.minX, bottom = screen.frame.maxY - f.minY
            target = CGPoint(x: x, y: bottom + 16); face = CGPoint(x: x, y: bottom / 2)
            line = "This is where I live. Click the sparkles in the menu bar any time for my controls."
        } else {
            let bar = screen.frame.maxY - screen.visibleFrame.maxY
            target = CGPoint(x: screen.frame.width / 2, y: bar + 16); face = CGPoint(x: screen.frame.width / 2, y: 0)
            line = "This is where I live, up in the menu bar. Look for the sparkles any time."
        }
        Timeline.log("firstrun.home", ["notch": notchScreen != nil, "icon": iconFrame != nil, "continuing": continuing])
        if !(continuing && shownOn == screen) { begin("home", on: screen, buddy: cfg.buddy) } else { running = "home" }
        let g = gen
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        DispatchQueue.main.asyncAfter(deadline: .now() + (continuing ? 0.1 : 0.45)) { [weak self] in
            guard let self, self.gen == g else { return }
            self.overlay.homeGo(target, facing: face)
            // As it arrives, home opens a little and glows.
            DispatchQueue.main.asyncAfter(deadline: .now() + (calm ? 0.35 : 0.75)) { [weak self] in
                guard let self, self.gen == g else { return }
                self.notch.beckon = true
                self.shoot("home")
                self.say(line, cfg: cfg) { [weak self] in
                    guard let self, self.gen == g else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, self.gen == g else { return }
                        self.overlay.homeEnd()
                        self.notch.beckon = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                            guard let self, self.gen == g else { return }
                            self.finish()
                        }
                    }
                }
            }
        }
    }

    // MARK: Showing and speaking

    private func begin(_ what: String, on screen: NSScreen, buddy: Bool) {
        running = what
        gen += 1
        startedAt = ProcessInfo.processInfo.systemUptime
        shownOn = screen
        overlay.show(on: screen)
        overlay.setBuddy(buddy)
        overlay.setCaption(you: nil, claude: nil)
        overlay.setPhase("ready")
        tick()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Keeps the buddy at the cursor (until it flies home), and stops if you start typing.
    private func tick() {
        guard let s = shownOn else { return }
        let loc = NSEvent.mouseLocation
        overlay.tick(cursor: NSMouseInRect(loc, s.frame, false) ? CGPoint(x: loc.x - s.frame.minX, y: s.frame.maxY - loc.y) : nil, level: 0)
        if ProcessInfo.processInfo.systemUptime - startedAt > 0.3, CallController.secondsSinceTyping() < 0.25 { interrupt("typing") }
    }

    private func finish() {
        Timeline.log("firstrun.done", ["what": running ?? ""])
        running = nil
        ticker?.invalidate(); ticker = nil
        notch.beckon = false
        overlay.setCaption(you: nil, claude: nil)
        overlay.setPhase("off")
        if sessionIdle() { overlay.hide() }
        if homePending || helloPending { later(1) }
    }

    /// Speaks a line in your voice, with its sentences as captions as they're heard.
    private func say(_ line: String, cfg: AppConfig, done: @escaping () -> Void) {
        let g = gen
        onSpoken = done
        func captions(over seconds: Double) {
            overlay.setPhase("speaking")
            let parts = FirstRunWords.sentences(line)
            let total = Double(max(1, parts.reduce(0) { $0 + $1.count }))
            var t = 0.0, shown = ""
            for p in parts {
                let at = t
                shown += (shown.isEmpty ? "" : " ") + p
                let text = shown
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in
                    guard let self, self.gen == g else { return }
                    self.overlay.setClaudeCaption(text)
                }
                t += seconds * Double(p.count) / total
            }
        }
        let natural = cfg.voiceEngine == "phonon" && cfg.language.lowercased().hasPrefix("en") && PhononVoice.isInstalled
        if natural, (try? phonon.start()) != nil {
            phonon.synthesize(line, voice: cfg.phononVoice, speed: cfg.voiceSpeed) { [weak self] pcm in
                guard let self, self.gen == g else { return }
                if let pcm, let p = Self.player(for: pcm) {
                    self.player = p
                    p.volume = 1
                    p.play()
                    captions(over: p.duration)
                    DispatchQueue.main.asyncAfter(deadline: .now() + p.duration + 0.1) { [weak self] in
                        guard let self, self.gen == g else { return }
                        self.spoken()
                    }
                } else {
                    self.sayWithApple(line, cfg: cfg); captions(over: Double(line.count) / 15)
                }
            }
        } else {
            sayWithApple(line, cfg: cfg)
            captions(over: Double(line.count) / 15)   // about how fast Apple's voice reads
        }
    }

    private func sayWithApple(_ line: String, cfg: AppConfig) {
        let s = Speaker()
        _ = s.configure(language: cfg.language, voiceName: cfg.voice, rate: cfg.speechRate)
        let u = AVSpeechUtterance(string: line)
        u.voice = s.voice
        u.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, cfg.speechRate))
        synth.speak(u)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.spoken() } }
    }

    private func spoken() {
        let d = onSpoken
        onSpoken = nil
        d?()
    }

    private func stopVoice() {
        onSpoken = nil
        player?.stop(); player = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    private static func player(for pcm: AVAudioPCMBuffer) -> AVAudioPlayer? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poinky-firstrun.caf")
        try? FileManager.default.removeItem(at: url)
        do {
            let file = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
            try file.write(from: pcm)
        } catch { return nil }
        return try? AVAudioPlayer(contentsOf: url)
    }

    /// POINKY_FIRSTRUN_SHOT=<dir>: a picture of the overlay a moment after the buddy reaches home (tests).
    private func shoot(_ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["POINKY_FIRSTRUN_SHOT"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // The notch as it looks right now (its own panel isn't in the overlay's picture), over a gray menu bar.
        let host = NSHostingView(rootView: NotchView(m: notch).frame(width: 420, height: 90).background(Color.gray.opacity(0.35)))
        let w = NSWindow(contentRect: CGRect(x: -3000, y: 0, width: 420, height: 90), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("firstrun-\(name)-notch.png"))
            }
            w.orderOut(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.overlay.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("firstrun-\(name).png")) {}
            self?.overlay.evaluateForTest("JSON.stringify(SB.homeState())") { r in
                try? ((r as? String) ?? "").write(toFile: dir + "/firstrun-\(name).json", atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: Words (no model)

    /// The hold-to-talk keys as words: "⌃⌥" → "Control and Option".
    static func spokenKeys(_ cfg: AppConfig) -> String {
        let hold = PushToTalk.displayString(cfg.pushToTalk)
        return FirstRunWords.spoken(hold == "Off" ? HotKey.displayString(cfg.hotkey) : hold)
    }

    static func userName() -> String? {
        FirstRunWords.userName(in: (try? String(contentsOf: Identity.userURL, encoding: .utf8)) ?? "")
    }

    private static func screenWithMouse() -> NSScreen {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }
    private static func screen(containing r: CGRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(r) }
    }
}
