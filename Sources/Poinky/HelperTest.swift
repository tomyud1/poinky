import AppKit

/// `--helper-test`: runs helpers through the real `AgentManager` and writes what happened (see AppDelegate).
@MainActor
enum HelperTest {
    private static var manager: AgentManager?
    private static var manager2: AgentManager?
    private static var away: AwayNotifier?
    private static var restarted = false
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
        m.onHands = { id in log("mouse and keyboard: \(id.map { "#\($0)" } ?? "free")") }
        m.onEvent = { a, e in log("#\(a.id) \(a.name) event \(e)") }
        m.onChange = { log("change: " + counts()) }
        func finishIfDone() {
            // Everyone else is done: one still waiting for an answer that never came keeps waiting (then we stop it).
            let waitingOnly = !m.running.isEmpty && m.queued.isEmpty && m.running.allSatisfy { !$0.asks.isEmpty }
            if waitingOnly {
                for a in m.running {
                    log("#\(a.id) \(a.name) STILL WAITING for an answer (asks=\(a.asks.count)) after the others finished")
                    log("status lines:\n" + m.statusLines().joined(separator: "\n"))
                    m.stop(id: a.id)
                }
            }
            // POINKY_TEST_UNDO=1: then undo #1's run (first which files, then for real).
            if m.running.isEmpty && m.queued.isEmpty, let uid = Int(env["POINKY_TEST_UNDO"] ?? ""), !restarted, let a = m.agents.first(where: { $0.id == uid }) {
                restarted = true
                let cp = HelperEntry.runStarts(a.entries)
                log("undo #\(uid): checkpoints \(cp.map { $0 == nil ? "none" : "kept" })")
                m.undo(m.past(a), dryRun: true) { o in
                    log("undo #\(uid) preview: \(o)")
                    m.undo(m.past(a), dryRun: false) { o2 in
                        let marker = (try? String(contentsOfFile: a.dir.appendingPathComponent(".fake-undo").path, encoding: .utf8)) ?? "none"
                        log("undo #\(uid): \(o2); rewound to the first checkpoint: \(marker == (cp.first ?? nil))")
                        let e = HelperEntry.read(a.chat).last
                        log("its window: \(e?.k ?? "") \(e?.text ?? "")")
                        try? FileManager.default.removeItem(at: a.dir.appendingPathComponent(".fake-undo"))
                        log("ALL DONE")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                    }
                }
                return
            }
            // POINKY_TEST_RESTART=1: then, as if Poinky had restarted, a new manager continues the first one from its saved window.
            if m.running.isEmpty && m.queued.isEmpty, env["POINKY_TEST_RESTART"] == "1", !restarted {
                restarted = true
                let fresh = AgentManager()
                manager2 = fresh
                let list = PastHelper.list(in: AgentManager.logDir)
                log("after a restart: \(list.count) earlier helpers: " + list.map { "\($0.name) \"\($0.title)\" \($0.status) key \($0.key)" }.joined(separator: "; "))
                guard let p = list.last else { log("ALL DONE"); NSApp.terminate(nil); return }
                let firstSession = m.agents.first { $0.log.place == p.log.place }?.session ?? "?"
                fresh.onEvent = { a, e in if case .started(let s, _, _) = e { log("#\(a.id) \(a.name) continued: same session \(s == firstSession)") } }
                fresh.onFinished = { a in
                    log("#\(a.id) \(a.name) FINISHED \(a.status.rawValue) (continued): \(a.summary.prefix(160))")
                    let entries = HelperEntry.read(a.chat)
                    log("its window now: \(entries.filter { $0.k == "task" }.count) task, \(entries.filter { $0.k == "end" }.count) ends, you: \(entries.filter { $0.k == "you" }.map(\.text))")
                    log("ALL DONE")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                }
                let a = fresh.resume(p, text: "Now also update the README.", config: config)
                log("continue \(p.name): \(a.map { "#\($0.id) \($0.name)" } ?? "FAILED")")
                return
            }
            if m.running.isEmpty && m.queued.isEmpty {
                log("ALL DONE")
                log("status lines:\n" + m.statusLines().joined(separator: "\n"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        }
        m.onFinished = { a in
            log("#\(a.id) \(a.name) FINISHED \(a.status.rawValue) turns=\(a.turns) steps=\(a.steps.count) checklist=\(a.checklist.count) blocked=\(a.blocked.count) followUps=\(a.followUps.count): \(a.summary.prefix(160))")
            finishIfDone()
        }
        // Answers, by helper: "1=yes,2=No, use a pad helper,3=ignore" (said to it, a second after it asks).
        var planned: [Int: String] = [:]
        for part in (env["POINKY_TEST_ANSWERS"] ?? "").components(separatedBy: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2, let id = Int(kv[0].trimmingCharacters(in: .whitespaces)) { planned[id] = kv[1] }
        }
        let tellFirst = env["POINKY_TEST_TELL"] == "1"
        // POINKY_TEST_NTFY=<server>: you're away, and questions go to that (fake) ntfy server; its buttons answer.
        if let server = env["POINKY_TEST_NTFY"] {
            let n = AwayNotifier()
            away = n
            var c = config
            c.awayNotify = true; c.ntfyServer = server; c.ntfyTopic = "poinky-test"
            n.settings(c)
            n.forceAway = true
            n.onAnswer = { id, rid, reply in log("from the phone: #\(id) \(reply) → \(m.answer(id: id, requestID: rid, reply))") }
        }
        m.onAsksChanged = { a in
            away?.stillOpen(Set(m.agents.flatMap { $0.asks.map(\.requestID) }))
            if let first = a.asks.first { away?.asking(a, first) }
            guard let ask = a.asks.first else { log("#\(a.id) \(a.name) has no open requests"); return }
            log("#\(a.id) \(a.name) ASKS: \(ask.bubble) [\(ask.detail.replacingOccurrences(of: "\n", with: " / "))] spoken: \"\(a.name) \(ask.spoken)\" risky=\(ask.risky)")
            let id = a.id, rid = ask.requestID
            // What the talker's <tell agent> does: a message, which must not answer the request.
            if tellFirst {
                log("tell #\(id) (like the talker): sent=\(m.send(id: id, text: "Yes, you're allowed to do that."))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let still = m.agents.first { $0.id == id }?.asks.contains { $0.requestID == rid } ?? false
                    log("#\(id) after the talker's message: \(still ? "still waiting" : "NOT WAITING")")
                }
            }
            guard let said = planned[id], said != "ignore" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + (tellFirst ? 2.5 : 1)) {
                guard let now = m.agents.first(where: { $0.id == id })?.asks.first else { return }
                let reply = now.reply(to: said, addressed: true)
                log("answer #\(id) \"\(said)\" → \(reply): \(m.answer(id: id, reply))")
                finishIfDone()
            }
        }
        log("helper command: \(AgentManager.executable(config: config) ?? "none"), max \(config.maxHelpers)")
        for (n, task) in tasks.enumerated() {
            // POINKY_TEST_PLAN=1: each makes a plan first and waits for the go-ahead.
            let a = m.start(AgentRequest(title: "Test \(n + 1)", dir: dir, task: task, planFirst: env["POINKY_TEST_PLAN"] == "1"), config: config)
            log("start \(n + 1): " + (a.map { "#\($0.id) \($0.name) \($0.status.rawValue)" } ?? "FAILED TO START") + " | " + counts())
        }
        if let f = env["POINKY_TEST_FOLLOWUP"], let bar = f.firstIndex(of: "|"), let secs = Double(f[..<bar]) {
            let text = String(f[f.index(after: bar)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
                log("follow-up to #1: sent=\(m.send(id: 1, text: text)) \"\(text)\"")
            }
        }
        // POINKY_TEST_PAUSE="3|6|Use yarn instead": "wait" to #1 at 3 s (it should stay, paused), then a new direction at 6 s.
        let pauseParts = (env["POINKY_TEST_PAUSE"] ?? "").components(separatedBy: "|")
        if pauseParts.count == 3, let p1 = Double(pauseParts[0]), let p2 = Double(pauseParts[1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + p1) {
                log("pause #1: \(m.pause(id: 1))")
                DispatchQueue.main.asyncAfter(deadline: .now() + (p2 - p1) / 2) {
                    if let a = m.agents.first(where: { $0.id == 1 }) {
                        log("#1 after pausing: status \(a.status.rawValue), paused \(a.paused), talk: \(HelperTalk.status(a))")
                        log("status line: " + (m.statusLines().first ?? ""))
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + p2) {
                log("new direction to #1: \(m.send(id: 1, text: pauseParts[2])), paused now \(m.agents.first { $0.id == 1 }?.paused ?? true)")
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
    private static var windows: HelperWindows?

    /// Helpers through the real overlay: a pretend session starts them, then ends (the overlay must
    /// stay up for them), they finish, and the overlay goes away when the last one is gone.
    static func runOnScreen(outDir: String, dir: String, tasks: [String]) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        // A locked screen pauses WebKit's animations, so nothing would move.
        if CallController.screenLocked() {
            try? "SCREEN LOCKED".write(toFile: outDir + "/log.txt", atomically: true, encoding: .utf8)
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
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
        var cursor = CGPoint(x: display.frame.width * 0.42, y: display.frame.height * 0.55)
        var sessionOn = true
        let ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated { if sessionOn { o.tick(cursor: cursor, level: 0) } }
        }
        // POINKY_TEST_TALK=1: point at helpers and talk to them (a follow-up, a status question, "stop").
        let talkTest = env["POINKY_TEST_TALK"] == "1"
        if talkTest {
            func pointAt(_ id: Int, at t: Double) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    o.evaluateForTest("JSON.stringify(SB.helperPos('\(id)'))") { r in
                        guard let s = r as? String, let d = s.data(using: .utf8),
                              let p = try? JSONSerialization.jsonObject(with: d) as? [String: Double] else { log("no helper #\(id) to point at"); return }
                        cursor = CGPoint(x: (p["x"] ?? 0) + 5, y: (p["y"] ?? 0) + 5)
                        log("cursor on helper #\(id)")
                    }
                }
            }
            func say(_ text: String, to id: Int, at t: Double) {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    guard let pointed = o.pointedHelper else { log("said \"\(text)\" but no helper is pointed at"); return }
                    o.helperListen(id: pointed, on: true)
                    log("holding the keys, pointing at #\(pointed)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        let r = hs.talk(to: pointed, HelperTalk.intent(text))
                        log("said \"\(text)\" to #\(pointed) → \(r.map { "\($0)" } ?? "nothing")")
                        if let a = m.agents.first(where: { $0.id == pointed }) { log("#\(a.id) \(a.name) status \(a.status.rawValue), follow-ups \(a.followUps)") }
                    }
                }
                _ = id
            }
            pointAt(1, at: 12); say("Also add a test for 4 people.", to: 1, at: 13)
            say("What are you doing?", to: 1, at: 15.5)
            pointAt(2, at: 17.5); say("stop", to: 2, at: 18.5)
        }
        // POINKY_TEST_ASK=1: helpers raise their hands (fixtures ask-install / ask-question). Each comes to the
        // buddy in turn; what "you say" goes through the same routing as in the app. #3 gets no answer: it
        // goes back to the edge and is answered later by name.
        let askTest = env["POINKY_TEST_ASK"] == "1"
        var askingNow: Int?
        m.onAsksChanged = { a in
            hs.asksChanged(a)
            log("#\(a.id) \(a.name) open requests: \(a.asks.count)" + (a.asks.first.map { " (\($0.bubble))" } ?? ""))
        }
        hs.onCardAnswer = { id, yes in log("card button: #\(id) \(yes ? "allow" : "deny") → \(hs.answer(id, yes ? .yes(always: false, extra: "") : .no(reason: "")))") }
        func hear(_ text: String) {
            guard let (id, reply) = hs.askReply(text, pointing: o.pointedHelper, asking: askingNow) else { log("said \"\(text)\" → not an answer"); return }
            let r = hs.answer(id, reply)
            log("said \"\(text)\" → #\(id) \(reply): \(r)")
            if askingNow == id, m.agents.first(where: { $0.id == id })?.asks.isEmpty != false { askingNow = nil }
        }
        if askTest {
            let plan = [1: "Yes, go ahead", 2: "No, write a small pad helper instead", 4: "The database"]
            o.onHelperAsking = { id in
                askingNow = id
                let name = m.agents.first { $0.id == id }?.name ?? "?"
                log("#\(id) \(name) is asking next to the buddy")
                // A question back isn't an answer: it keeps waiting.
                if id == 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { hear("Wait, what does it want?") } }
                if let said = plan[id] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { hear(said) }
                } else {
                    // Nobody answers: back to the edge, hand up. Later: answered by name.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        guard askingNow == id else { return }
                        askingNow = nil; hs.park(id: id); log("parked #\(id)")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { hear("\(name), yes") }
                    }
                }
            }
        }
        // POINKY_TEST_WINDOW=1: open the Helpers window on #1, watch it fill in, type to it, and continue it once it's done.
        if env["POINKY_TEST_WINDOW"] == "1" {
            let hw = HelperWindows()
            windows = hw
            hw.agents = m
            m.onChange = { hw.updateAll() }
            hw.onTypedAnswer = { id, reply, text in log("typed \"\(text)\" → answer \(reply): \(hs.answer(id, reply))") }
            hw.onResume = { past, text in
                let a = m.resume(past, text: text, config: config)
                log("continue \(past.name) (session \(past.session.isEmpty ? "none" : "kept")): \(a.map { "#\($0.id) \($0.name)" } ?? "FAILED")")
                return a
            }
            let state = "JSON.stringify({entries: document.querySelectorAll('#list .e').length, steps: [...document.querySelectorAll('.steps .lbl')].map(e => e.textContent), pill: document.getElementById('pill').textContent, now: document.getElementById('now').hidden ? '' : document.getElementById('nowTxt').textContent, box: document.getElementById('box').placeholder, list: [...document.querySelectorAll('.it')].map(e => e.textContent)})"
            func look(_ at: Double, _ what: String, _ js: String) {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { hw.evaluateForTest(js) { r in log("window \(what): \(r.map { "\($0)" } ?? "nil")") } }
            }
            var ended = 0
            m.onEntry = { a, e in
                hw.entry(a, e)
                guard e.k == "end" else { return }
                ended += 1
                if ended == 1 {
                    // Finished: how it looks, then type to it to continue it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        hw.evaluateForTest(state + " + ' ' + (document.querySelector('.end .head span') || {}).textContent") { r in log("window at the end: \(r.map { "\($0)" } ?? "nil")") }
                        hw.snapshotForTest(to: URL(fileURLWithPath: outDir + "/window-done.png"))
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        hw.evaluateForTest("(() => { const b = document.getElementById('box'); b.value = 'Now also update the README.'; b.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); return b.placeholder; })()") { r in log("typed to the finished helper (box said \"\(r ?? "")\")") }
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        hw.evaluateForTest(state) { r in log("window after continuing: \(r.map { "\($0)" } ?? "nil")") }
                        hw.snapshotForTest(to: URL(fileURLWithPath: outDir + "/window-continued.png"))
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { hw.close() }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { hw.show(1); log("opened #1's window") }
            look(6, "while working", state)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
                hw.evaluateForTest("(() => { const b = document.getElementById('box'); b.value = 'Also make the README example use $100.'; b.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); return b.value; })()") { r in
                    log("typed into #1's window (box now \"\(r ?? "")\"); follow-ups: \(m.agents.first { $0.id == 1 }?.followUps ?? [])")
                }
                hw.snapshotForTest(to: URL(fileURLWithPath: outDir + "/window-working.png"))
            }
            look(8, "after typing", "JSON.stringify([...document.querySelectorAll('.you div')].map(e => e.textContent))")
        }
        hs.settings(config)
        m.onStarted = { a in log("#\(a.id) \(a.name) started"); hs.started(a) }
        m.onEvent = { a, e in hs.event(a, e) }
        m.onStopped = { a in hs.stopped(id: a.id) }
        // Reports, the way the app does them: a finished helper waits at the edge while you're busy
        // (POINKY_TEST_BUSY="from|to" seconds: pretend you're talking), then the buddy comes back,
        // they fly to it while it "speaks", and merge when it's done.
        var busy: (Double, Double) = (0, 0)
        if let b = env["POINKY_TEST_BUSY"], let bar = b.firstIndex(of: "|"), let x = Double(b[..<bar]), let y = Double(b[b.index(after: bar)...]) { busy = (x, y) }
        var pending: [Int] = []
        var reporting = false
        func deliver() {
            guard !pending.isEmpty, !reporting else { return }
            let now = Date().timeIntervalSince(t0)
            if now >= busy.0 && now < busy.1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { deliver() }
                return
            }
            let ids = pending; pending.removeAll(); reporting = true
            sessionOn = true; o.show(on: display); o.setBuddy(true); o.setPhase("speaking")
            o.helperReport(ids: ids); log("report \(ids)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(ids.count)) {
                o.helperRelease(ids: ids); log("release \(ids)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    reporting = false; sessionOn = false; o.hide(); log("report session ended")
                    deliver()
                }
            }
        }
        m.onFinished = { a in
            log("#\(a.id) \(a.name) finished \(a.status.rawValue)"); hs.finished(a)
            pending.append(a.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { deliver() }
        }
        // What each helper is doing, as the page has it.
        var lastPhases = ""
        let phaseWatch = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                o.evaluateForTest("SB.helperPhases()") { r in
                    let s = (r as? String) ?? ""
                    if s != lastPhases { lastPhases = s; log("phases: " + s) }
                }
            }
        }
        _ = phaseWatch
        // Snapshots: often at first (spawning, flying), then every second.
        var n = 0
        func shoot() {
            let name = String(format: "%@/shot-%03d-%05.1fs.png", outDir, n, Date().timeIntervalSince(t0))
            n += 1
            o.snapshot(to: URL(fileURLWithPath: name)) {}
        }
        var schedule: [Double] = stride(from: 0.2, to: 9.0, by: 0.3).map { $0 }
        schedule += stride(from: 9.0, to: 70.0, by: 1.0).map { $0 }
        let shots = env["POINKY_TEST_SHOTS"] != "0"
        for t in schedule where shots { DispatchQueue.main.asyncAfter(deadline: .now() + t) { if o.isShown { shoot() } } }
        // Frame timing while helpers move, every second.
        let fps = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                o.evaluateForTest("SB.helperStats()") { r in
                    if let s = r as? String, s != "{\"frames\":0}" { log("frames: " + s) }
                }
            }
        }
        _ = fps
        // Watch the overlay: it must stay up while helpers are on screen, and go away after.
        var lastState = ""
        let watcher = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                let s = "overlay \(o.isShown ? "shown" : "hidden"), helpers on screen \(o.helperCount), session \(sessionOn ? "on" : "off")"
                if s != lastState { lastState = s; log(s) }
                if !sessionOn, !o.isShown, m.running.isEmpty, m.queued.isEmpty, pending.isEmpty, !reporting {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + (askTest ? 34 : talkTest ? 22 : 0.6 + Double(tasks.count) * 2.6 + 3)) {
            sessionOn = false; o.hide(); log("session ended (overlay.hide)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { log("TIMEOUT"); NSApp.terminate(nil) }
    }
}

extension HelperTest {
    /// Phase 6: a helper's request in plain words, your spoken answer, and the response Claude Code gets.
    static func askChecks(_ check: (Bool, String) -> Void) {
        func request(_ tool: String, _ input: [String: Any], suggestions: [[String: Any]]? = nil) -> HelperAsk? {
            var req: [String: Any] = ["subtype": "can_use_tool", "tool_name": tool, "input": input]
            if let s = suggestions { req["permission_suggestions"] = s }
            return HelperAsk.from(["type": "control_request", "request_id": "r1", "request": req])
        }
        let sugg: [[String: Any]] = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "make build"]], "behavior": "allow", "destination": "localSettings"]]
        guard let npm = request("Bash", ["command": "npm install left-pad --no-save --prefix ./demo2", "description": "Install left-pad"]),
              let mk = request("Bash", ["command": "mkdir -p demo && date > demo/hello.txt"]),
              let make = request("Bash", ["command": "make build"], suggestions: sugg),
              let web = request("WebFetch", ["url": "https://example.com/docs", "prompt": "read"]),
              let q = request("AskUserQuestion", ["questions": [["question": "Do you prefer tabs or spaces for indentation?", "header": "Indent",
                                                                  "options": [["label": "Tabs"], ["label": "Spaces"]], "multiSelect": false]]]),
              let q2 = request("AskUserQuestion", ["questions": [["question": "Which database should I use?", "header": "DB",
                                                                   "options": [["label": "SQLite"], ["label": "Postgres"]], "multiSelect": false],
                                                                  ["question": "Add tests?", "header": "Tests", "options": [["label": "Yes"], ["label": "No"]]]]])
        else { check(false, "requests parse"); return }
        check(npm.bubble == "Can I run npm install left-pad?", "bubble: \(npm.bubble)")
        check(npm.spoken == "wants to run npm install left-pad. Is that okay?", "spoken: \(npm.spoken)")
        check(npm.detail == "npm install left-pad --no-save --prefix ./demo2", "card shows the exact command")
        check(mk.spoken == "wants to run mkdir demo, then date into hello.txt. Is that okay?", "two commands: \(mk.spoken)")
        let long = HelperAsk.speakable("cd /tmp/x/live && python3 -m unittest -v 2>&1 | tail -12 && python3 tipsplit.py 87.40 18 3 && python3 tipsplit.py 10 0 3")
        check(long == "python3 unittest, then python3 tipsplit.py 87.40 18 3, and more", "a long command, said short: \(long)")
        let del = "cd /tmp/live2 && ls -la one/notes-old.txt && git status && python3 x.py && rm one/notes-old.txt && ls one"
        check(HelperAsk.speakable(del) == "git status, then rm notes-old.txt, and more", "the risky part is always said: \(HelperAsk.speakable(del))")
        check(HelperAsk.shortCommand(del) == "rm notes-old.txt and more", "its bubble names the risky part: \(HelperAsk.shortCommand(del))")
        check(web.bubble == "Can I open example.com?", "web: \(web.bubble)")
        check(q.kind == .question && q.spoken == "asks: Do you prefer tabs or spaces for indentation?", "question: \(q.spoken)")
        check(q2.spoken == "asks: Which database should I use? SQLite, or Postgres?", "question with its choices: \(q2.spoken)")
        let risky = ["npm install left-pad", "rm -rf build", "git push origin main", "ls; rm notes.txt", "pip install requests", "gh pr create --fill"]
        let safe = ["git status", "echo hi", "npm test", "python3 -m pytest", "grep -r rm .", "git commit -m 'x'"]
        check(risky.allSatisfy(HelperAsk.isRisky(command:)), "risky: \(risky.filter { !HelperAsk.isRisky(command: $0) })")
        check(!safe.contains(where: HelperAsk.isRisky(command:)), "not risky: \(safe.filter(HelperAsk.isRisky(command:)))")
        let replies: [(String, HelperAsk.Reply)] = [
            ("Yes.", .yes(always: false, extra: "")), ("Yeah, go ahead", .yes(always: false, extra: "")), ("Do it", .yes(always: false, extra: "")),
            ("Sure, but use yarn instead", .yes(always: false, extra: "Use yarn instead")), ("Yes, always", .yes(always: true, extra: "")),
            ("Okay and don't ask again", .yes(always: true, extra: "")), ("No problem", .yes(always: false, extra: "")),
            ("No.", .no(reason: "")), ("Nope", .no(reason: "")), ("Not now", .no(reason: "")),
            ("No, use yarn instead", .no(reason: "Use yarn instead")),
            ("Okay, what does it want?", .unclear), ("No wait, what is it?", .unclear), ("What is npm?", .unclear), ("Yes no wait", .unclear),
            ("You can tell me later", .unclear), ("Hmm", .unclear), ("Open Safari for me", .unclear), ("No idea", .unclear),
        ]
        for (said, want) in replies { let got = npm.reply(to: said, addressed: false); check(got == want, "\"\(said)\" → \(got)") }
        let answers: [(String, Bool, HelperAsk.Reply)] = [
            ("Spaces", false, .answer("Spaces")), ("the first one", false, .answer("Tabs")), ("Spaces, not tabs", false, .answer("Spaces")),
            ("You choose", false, .answer("No preference: you choose.")), ("Skip", false, .no(reason: "")),
            ("Two-space indentation please", true, .answer("Two-space indentation please")), ("Two-space indentation please", false, .unclear),
            ("What's the difference?", true, .unclear),
        ]
        for (said, addressed, want) in answers { let got = q.reply(to: said, addressed: addressed); check(got == want, "question: \"\(said)\"\(addressed ? " (to it)" : "") → \(got)") }
        // What Claude Code gets.
        func body(_ r: [String: Any]?) -> [String: Any] { ((r?["response"] as? [String: Any])?["response"] as? [String: Any]) ?? [:] }
        let yes = body(npm.response(.yes(always: false, extra: "")))
        check(yes["behavior"] as? String == "allow" && (yes["updatedInput"] as? [String: Any])?["command"] as? String == npm.detail, "yes → allow, same command")
        let no = body(npm.response(.no(reason: "Use yarn instead")))
        check(no["behavior"] as? String == "deny" && no["message"] as? String == "The user said no: Use yarn instead", "no → deny: \(no["message"] ?? "")")
        let always = body(make.response(.yes(always: true, extra: "")))
        let rules = always["updatedPermissions"] as? [[String: Any]]
        check(rules?.first?["destination"] as? String == "session", "yes, always → a rule for this session only")
        check(body(npm.response(.yes(always: true, extra: "")))["updatedPermissions"] == nil, "risky: \"always\" doesn't stick")
        let picked = body(q.response(.answer("Spaces")))
        check(((picked["updatedInput"] as? [String: Any])?["answers"] as? [String: String])?["Do you prefer tabs or spaces for indentation?"] == "Spaces", "question → its answer")
        check(npm.response(.unclear) == nil, "unclear → nothing sent")
        // Two questions in one request: asked one at a time.
        let after = q2.recording("SQLite")
        check(after?.currentQuestion?.text == "Add tests?" && after?.answers["Which database should I use?"] == "SQLite", "two questions: the second comes next")
        let both = ((body(after?.response(.answer("Yes")))["updatedInput"] as? [String: Any])?["answers"] as? [String: String]) ?? [:]
        check(both == ["Which database should I use?": "SQLite", "Add tests?": "Yes"], "two questions: both answers sent (\(both))")
        // Answering by name.
        for (said, name, want) in [("Mint, yes", "Mint", "yes"), ("tell Coral no, use yarn", "Coral", "no, use yarn"), ("Yes Violet.", "Violet", "Yes"),
                                    ("Let Mint do it", "Mint", "do it"), ("What's up?", "Mint", nil)] as [(String, String, String?)] {
            let got = HelperTalk.without(name: name, in: said)
            check(got == want, "\"\(said)\" to \(name) → \(got ?? "nil")")
        }
        // The stream: a request becomes an ask, a withdrawal cancels it.
        var stream = HelperStream()
        let line = #"{"type":"control_request","request_id":"abc","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"npm install"}}}"# + "\n"
            + #"{"type":"control_cancel_request","request_id":"abc"}"# + "\n"
        let evs = stream.feed(Data(line.utf8))
        if evs.count == 2, case .asking(let a) = evs[0], case .askCancelled(let id) = evs[1] { check(a.requestID == "abc" && id == "abc", "stream: request and withdrawal") }
        else { check(false, "stream: request and withdrawal (\(evs))") }
    }

    /// `--helper-talk-test <out.txt>`: what you say to a helper (stop / status / follow-up), by pointing or
    /// by name, its spoken status, and the talker's <tell>/<stop> tags. No model, no screen.
    static func talkSelfTest(out: String) {
        var lines: [String] = [], fails = 0
        func check(_ ok: Bool, _ what: String) { lines.append((ok ? "ok   " : "FAIL ") + what); if !ok { fails += 1 } }
        let intents: [(String, HelperTalk.Intent)] = [
            ("Stop", .stop), ("stop it please", .stop), ("Never mind.", .stop), ("cancel that", .stop),
            ("What are you doing?", .status), ("How's it going?", .status), ("status", .status), ("Are you done yet?", .status),
            ("how much longer", .status),
            ("Stop using the old file and read config.py instead", .message("Stop using the old file and read config.py instead")),
            ("Also add a test for 4 people.", .message("Also add a test for 4 people.")),
            ("update the README too", .message("update the README too")),
            ("Wait.", .pause), ("hold on a second", .pause), ("one sec", .pause), ("hang on", .pause),
            ("Go on.", .resume), ("okay continue", .resume), ("keep going", .resume),
            ("Undo that.", .undo), ("undo your changes", .undo), ("put it back", .undo), ("revert it", .undo),
            ("undo the change to the README but keep the rest", .message("undo the change to the README but keep the rest")),
            ("wait for the build before testing", .message("wait for the build before testing")),
        ]
        for (said, want) in intents { let got = HelperTalk.intent(said); check(got == want, "\"\(said)\" → \(got)") }
        let names = ["Mint", "Coral"]
        let byName: [(String, String?, HelperTalk.Intent?)] = [
            ("How's Mint doing?", "Mint", .status), ("what's coral up to", "Coral", .status), ("Is Mint done?", "Mint", .status),
            ("Stop Coral", "Coral", .stop), ("Tell Mint to also add a test", "Mint", .message("Also add a test")),
            ("ask coral to use the json flag", "Coral", .message("Use the json flag")), ("Mint, also update the README", "Mint", .message("Also update the README")),
            ("Mint, how's it going?", "Mint", .status),
            ("Mint, wait.", "Mint", .pause), ("Wait Mint", "Mint", .pause), ("Coral, go on", "Coral", .resume),
            ("Undo what Mint did", "Mint", .undo), ("undo Coral's changes", "Coral", .undo), ("Mint, undo that", "Mint", .undo), ("revert mint", "Mint", .undo),
            ("Is mint tea good for you?", nil, nil), ("What color is coral?", nil, nil), ("How's Violet doing?", nil, nil),
        ]
        for (said, want) in [("Wait, use yarn instead", true), ("Actually, skip the docs", true), ("no wait, keep the old name", true),
                             ("Also add a test", false), ("wait for the build first", true), ("Stop.", false)] {
            check(HelperTalk.isRedirect(said) == want, "\"\(said)\" \(want ? "changes" : "doesn't change") its direction")
        }
        for (said, want) in [("use Opus for this one", "claude-opus-5-5"), ("Sonnet 5.5", "claude-sonnet-5-5"), ("haiku", "claude-haiku-5-5"),
                             ("fable", "claude-fable-5-1"), ("claude-opus-5-5", "claude-opus-5-5"), ("gpt", nil)] as [(String, String?)] {
            check(AgentRequest.modelName(said) == want, "model \"\(said)\" → \(AgentRequest.modelName(said) ?? "none")")
        }
        for (said, name, intent) in byName {
            let got = HelperTalk.byName(said, names: names)
            check(got?.name == name && got?.intent == intent, "\"\(said)\" → \(got.map { "\($0.name) \($0.intent)" } ?? "not about a helper")")
        }
        let dir = URL(fileURLWithPath: "/tmp/proj"), log = URL(fileURLWithPath: "/tmp/x.md")
        var a = AgentManager.Agent(id: 1, name: "Mint", title: "Fix the tip bug", task: "…", dir: dir, started: Date().addingTimeInterval(-200), log: log)
        a.latest = "Running the tests"
        a.checklist = [HelperTask(text: "a", state: .done), HelperTask(text: "b", state: .done), HelperTask(text: "c", state: .active)]
        let s1 = HelperTalk.status(a)
        check(s1 == "Mint is running the tests. It has done 2 of 3 steps, 3 minutes in.", "status while working: \(s1)")
        a.latest = "Two tests fail, confirming the bug."; a.checklist = []
        let s2 = HelperTalk.status(a)
        check(s2.hasPrefix("Mint says: Two tests fail, confirming the bug. It's been working for 3 minutes."), "status from a note: \(s2)")
        a.latest = "Now adding the 4-person test to test_tipsplit.py."
        let s4 = HelperTalk.status(a)
        check(s4.hasPrefix("Mint is now adding the 4-person test to test_tipsplit.py. It's been"), "status from \"Now adding…\": \(s4)")
        a.status = .done; a.finished = Date(); a.summary = "Fixed the rounding. All 4 tests pass. Nothing else changed."
        let s3 = HelperTalk.status(a)
        check(s3 == "Mint finished. Fixed the rounding. All 4 tests pass.", "status when done: \(s3)")
        var p = TalkParser()
        _ = p.feed(#"<say>I'll tell Mint.</say><tell agent="Mint">Also add a test for 4 people.</tell><stop agent="Coral"/>"#)
        let ev = p.finish()
        check(ev.tells.first?.name == "Mint" && ev.tells.first?.text == "Also add a test for 4 people." && ev.stops == ["Coral"],
              "talker tags: tell \(ev.tells.map { "\($0.name): \($0.text)" }), stop \(ev.stops)")
        check(ev.sentences == ["I'll tell Mint."] || ev.sentences.isEmpty, "the tags aren't spoken (\(ev.sentences))")
        var p2 = TalkParser()
        _ = p2.feed(#"<say>On it.</say><agent title="Fix login" dir="/tmp/x" model="opus" plan="true">Fix the login test.</agent><agent resume="3f2a9c1b">Also update the README.</agent><undo agent="Coral"/>"#)
        let ev2 = p2.finish()
        let r0 = ev2.agents.first, r1 = ev2.agents.dropFirst().first
        check(r0?.model == "claude-opus-5-5" && r0?.planFirst == true && r0?.resumeKey == nil, "talker tags: a model and plan first for one task (\(String(describing: r0)))")
        check(r1?.resumeKey == "3f2a9c1b" && r1?.task == "Also update the README.", "talker tags: continue an earlier helper by its key")
        check(ev2.undos == ["Coral"], "talker tags: undo (\(ev2.undos))")
        askChecks(check)
        lines.append(fails == 0 ? "ALL OK" : "\(fails) FAILED")
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
