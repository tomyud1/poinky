import AppKit

/// `--helper-test`: runs helpers through the real `AgentManager` and writes what happened (see AppDelegate).
@MainActor
enum HelperTest {
    private static var manager: AgentManager?
    private static var lines: [String] = []

    static func run(out: String, dir: String, tasks: [String]) {
        let env = ProcessInfo.processInfo.environment
        var config = AppConfig()
        config.maxHelpers = Int(env["POINKY_TEST_MAX"] ?? "") ?? 3
        let m = AgentManager()
        manager = m
        let t0 = Date()
        func log(_ s: String) {
            let line = String(format: "%6.2f ", Date().timeIntervalSince(t0)) + s
            lines.append(line)
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
        func counts() -> String { "running \(m.running.count), waiting \(m.queued.count)" }
        m.onEvent = { a, e in log("#\(a.id) \(a.name) event \(e)") }
        m.onChange = { log("change: " + counts()) }
        m.onFinished = { a in
            log("#\(a.id) \(a.name) FINISHED \(a.status.rawValue) turns=\(a.turns) steps=\(a.steps.count) checklist=\(a.checklist.count) blocked=\(a.blocked.count) followUps=\(a.followUps.count): \(a.summary.prefix(160))")
            if m.running.isEmpty && m.queued.isEmpty {
                log("ALL DONE")
                log("status lines:\n" + m.statusLines().joined(separator: "\n"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        }
        log("helper command: \(AgentManager.executable(config: config) ?? "none"), max \(config.maxHelpers)")
        for (n, task) in tasks.enumerated() {
            let a = m.start(AgentRequest(title: "Test \(n + 1)", dir: dir, task: task), config: config)
            log("start \(n + 1): " + (a.map { "#\($0.id) \($0.name) \($0.status.rawValue)" } ?? "FAILED TO START") + " | " + counts())
        }
        if let f = env["POINKY_TEST_FOLLOWUP"], let bar = f.firstIndex(of: "|"), let secs = Double(f[..<bar]) {
            let text = String(f[f.index(after: bar)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                log("follow-up to #1: sent=\(m.send(id: 1, text: text)) \"\(text)\"")
            }
        }
        if let s = env["POINKY_TEST_STOP"], let secs = Double(s) {   // stops the second helper
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { log("stop #2"); m.stop(id: 2) }
        }
        // Safety net.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) { log("TIMEOUT"); NSApp.terminate(nil) }
    }
}

extension HelperTest {
    private static var overlay: Overlay?
    private static var screen: HelperScreen?

    /// Helpers through the real overlay: a pretend session starts them, then ends (the overlay must
    /// stay up for them), they finish, and the overlay goes away when the last one is gone.
    static func runOnScreen(outDir: String, dir: String, tasks: [String]) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        var config = AppConfig()
        config.maxHelpers = Int(env["POINKY_TEST_MAX"] ?? "") ?? 3
        config.soundVolume = 0.0001   // the test is silent
        let o = Overlay(), m = AgentManager(), hs = HelperScreen(overlay: o, agents: m)
        overlay = o; manager = m; screen = hs
        let display = NSScreen.main ?? NSScreen.screens[0]
        let t0 = Date()
        var lines: [String] = []
        func log(_ s: String) {
            lines.append(String(format: "%6.2f ", Date().timeIntervalSince(t0)) + s)
            try? lines.joined(separator: "\n").write(toFile: outDir + "/log.txt", atomically: true, encoding: .utf8)
        }
        // A pretend session: the buddy sits at a fixed spot (not your real mouse).
        o.show(on: display)
        o.setBuddy(true)
        o.setPhase("ready")
        let cursor = CGPoint(x: display.frame.width * 0.42, y: display.frame.height * 0.55)
        var sessionOn = true
        let ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { if sessionOn { o.tick(cursor: cursor, level: 0) } }
        }
        hs.settings(config)
        m.onStarted = { a in log("#\(a.id) \(a.name) started"); hs.started(a) }
        m.onEvent = { a, e in hs.event(a, e) }
        m.onStopped = { a in hs.stopped(id: a.id) }
        m.onFinished = { a in
            log("#\(a.id) \(a.name) finished \(a.status.rawValue)"); hs.finished(a)
        }
        // Snapshots: often at first (spawning, flying), then every second.
        var n = 0
        func shoot() {
            let name = String(format: "%@/shot-%03d-%05.1fs.png", outDir, n, Date().timeIntervalSince(t0))
            n += 1
            o.snapshot(to: URL(fileURLWithPath: name)) {}
        }
        var schedule: [Double] = stride(from: 0.2, to: 9.0, by: 0.3).map { $0 }
        schedule += stride(from: 9.0, to: 70.0, by: 1.0).map { $0 }
        for t in schedule { DispatchQueue.main.asyncAfter(deadline: .now() + t) { if o.isShown { shoot() } } }
        // Watch the overlay: it must stay up while helpers are on screen, and go away after.
        var lastState = ""
        let watcher = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let s = "overlay \(o.isShown ? "shown" : "hidden"), helpers on screen \(o.helperCount), session \(sessionOn ? "on" : "off")"
                if s != lastState { lastState = s; log(s) }
                if !sessionOn, !o.isShown, m.running.isEmpty, m.queued.isEmpty {
                    log("ALL DONE"); ticker.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                }
            }
        }
        _ = watcher
        log("front window (\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")): \(HelperScreen.frontWindowRect(on: display).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "none")")
        log("display \(Int(display.frame.width))x\(Int(display.frame.height)), helper command \(AgentManager.executable(config: config) ?? "none")")
        for (k, task) in tasks.enumerated() {
            // Spaced like a real conversation that asks for a few things.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(k) * 2.6) {
                _ = m.start(AgentRequest(title: "Task \(k + 1)", dir: dir, task: task), config: config)
            }
        }
        // Experiments: run JavaScript in the page once it's up (POINKY_TEST_JS="seconds|script").
        if let js = env["POINKY_TEST_JS"], let bar = js.firstIndex(of: "|"), let secs = Double(js[..<bar]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { o.evaluateForTest(String(js[js.index(after: bar)...])); log("ran test script") }
        }
        // A card's Stop button, as the page sends it (POINKY_TEST_STOP=seconds stops helper #2).
        if let s = env["POINKY_TEST_STOP"], let secs = Double(s) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                log("card button: stop #2")
                o.evaluateForTest("window.webkit.messageHandlers.sb.postMessage({kind:'helperAction', id:'2', action:'stop'})")
            }
        }
        m.onStopped = { a in log("#\(a.id) \(a.name) stopped"); hs.stopped(id: a.id) }
        // The session ends while helpers still work.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(tasks.count) * 2.6 + 3) {
            sessionOn = false; o.hide(); log("session ended (overlay.hide)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { log("TIMEOUT"); NSApp.terminate(nil) }
    }
}
