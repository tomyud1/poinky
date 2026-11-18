import AppKit

/// `--helper-test`: runs helpers through the real `AgentManager` and writes what happened (see AppDelegate).
@MainActor
enum HelperTest {
    private static var manager: AgentManager?
    private static var manager2: AgentManager?
    private static var away: AwayNotifier?
    private static var notifier: HelperNotifier?
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
        m.onStarted = { a in log("#\(a.id) \(a.name) started, its time: \(Int(Date().timeIntervalSince(a.started)))s") }
        m.onChange = {
            log("change: " + counts())
            notifier?.stillOpen(m.agents.flatMap { h in h.asks.map { (h.id, $0) } })   // like the app: answered ones go away
        }
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
        // POINKY_TEST_NOTIFY=<allow|deny|choose|open,choose…>: no session runs, so a request becomes a Mac
        // notification (a fake center: no permission prompt), and these buttons are clicked on it, a second apart.
        let notifyClicks = (env["POINKY_TEST_NOTIFY"] ?? "").split(separator: ",").compactMap { HelperNotifier.Action(rawValue: String($0)) }
        let fakeCenter = FakeNotifications()
        if !notifyClicks.isEmpty {
            let n = HelperNotifier(poster: fakeCenter)
            notifier = n
            var c = config
            c.helperNotify = true; c.helperNotifyDone = true
            n.settings(c)
            n.isAway = { true }
            fakeCenter.log = { log($0) }
            n.onAnswer = { id, rid, reply in log("from a notification: #\(id) \(reply) → \(m.answer(id: id, requestID: rid, reply))") }
            n.onOpen = { id in log("from a notification: open #\(id)'s window") }
        }
        m.onFinished = { a in
            notifier?.stillOpen(m.agents.flatMap { h in h.asks.map { (h.id, $0) } })
            notifier?.finished(a)
            log("#\(a.id) \(a.name) FINISHED \(a.status.rawValue) turns=\(a.turns) steps=\(a.steps.count) checklist=\(a.checklist.count) blocked=\(a.blocked.count) followUps=\(a.followUps.count) tokens=\(a.outputTokens)/\(a.contextTokens): \(a.summary.prefix(160))")
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
            notifier?.stillOpen(m.agents.flatMap { h in h.asks.map { (h.id, $0) } })
            if let n = notifier, let first = a.asks.first {
                n.asking(a, first, inSession: false)
                for (k, action) in notifyClicks.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(k)) {
                        log("click \(action.rawValue) on #\(a.id)'s notification")
                        fakeCenter.click(action, agent: a.id)
                    }
                }
            }
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
            hw.onNew = { req in let a = m.start(req, config: config); log("new from the window: \(req.title) in \(req.dir.map { ($0 as NSString).lastPathComponent } ?? "?") → \(a.map { "#\($0.id) \($0.name)" } ?? "FAILED")"); return a }
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
                        // What it changed: the bar, then the diff (⌘D), from the app.
                        hw.evaluateForTest("(() => { const r = document.getElementById('changes').hidden ? 'none' : document.getElementById('chN').textContent + ': ' + document.getElementById('chFiles').textContent; document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'd', metaKey: true, bubbles: true})); return r; })()") { r in log("window changes: \(r.map { "\($0)" } ?? "nil")") }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        hw.evaluateForTest("document.getElementById('diff').hidden ? 'closed' : document.getElementById('diffBody').textContent.slice(0, 200)") { r in log("window diff: \(r.map { "\($0)" } ?? "nil")") }
                        hw.evaluateForTest("(() => { document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true})); return document.getElementById('diff').hidden; })()") { _ in }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        hw.evaluateForTest("(() => { const b = document.getElementById('box'); b.value = 'Now also update the README.'; b.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', bubbles: true})); return b.placeholder; })()") { r in log("typed to the finished helper (box said \"\(r ?? "")\")") }
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        hw.evaluateForTest(state) { r in log("window after continuing: \(r.map { "\($0)" } ?? "nil")") }
                        hw.snapshotForTest(to: URL(fileURLWithPath: outDir + "/window-continued.png"))
                    }
                    guard ended == 2 else { return }
                    // A new helper from the window's form (⌘N), in the same folder.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        hw.evaluateForTest("(() => { document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'n', metaKey: true, bubbles: true})); return 1; })()") { _ in }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        hw.evaluateForTest("(() => { const t = document.getElementById('nTask'); t.value = 'fixture:quiet Check the README'; document.getElementById('nPlan').checked = false; t.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', metaKey: true, bubbles: true})); return document.getElementById('nDir').value; })()") { r in log("new helper from the window in \((r as? String).map { ($0 as NSString).lastPathComponent } ?? "nil")") }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
                        hw.evaluateForTest("document.getElementById('name').textContent + ' — ' + document.getElementById('title').textContent + ' | ' + [...document.querySelectorAll('.it .n')].map(e => e.firstChild.textContent).join(',')") { r in log("window after a new helper: \(r.map { "\($0)" } ?? "nil")") }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { hw.close() }
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
        // Typed to a helper by name: "@Mint add tests".
        for (said, name, intent) in [("@Mint add a test for 4 people", "Mint", HelperTalk.Intent.message("Add a test for 4 people")),
                                     ("@coral: stop", "Coral", .stop), ("@Mint /review", "Mint", .message("/review")),
                                     ("@Mint how's it going?", "Mint", .status)] as [(String, String, HelperTalk.Intent)] {
            let got = HelperTalk.byName(said, names: names)
            check(got?.name == name && got?.intent == intent, "typed \"\(said)\" → \(got.map { "\($0.name) \($0.intent)" } ?? "not about a helper")")
        }
        check(HelperTalk.byName("@Violet add tests", names: names) == nil, "typed \"@Violet …\" with no Violet: not about a helper")
        // A second Mint ("Mint 2"): said or typed by name, never mixed up with the first one.
        let names2 = ["Mint", "Coral", "Mint 2"]
        for (said, name, intent) in [("How's Mint 2 doing?", "Mint 2", HelperTalk.Intent.status), ("how's mint two doing", "Mint 2", .status),
                                     ("How's Mint doing?", "Mint", .status), ("Tell Mint two to also add a test", "Mint 2", .message("Also add a test")),
                                     ("tell mint 2 to use yarn", "Mint 2", .message("Use yarn")), ("Tell Mint to use yarn", "Mint", .message("Use yarn")),
                                     ("Stop Mint 2", "Mint 2", .stop), ("stop mint", "Mint", .stop), ("Mint 2, also update the README", "Mint 2", .message("Also update the README")),
                                     ("Mint two, wait", "Mint 2", .pause), ("Undo what Mint 2 did", "Mint 2", .undo), ("what's mint number 2 up to", "Mint 2", .status),
                                     ("@Mint 2 add a test for 4 people", "Mint 2", .message("Add a test for 4 people")), ("@mint2 /review", "Mint 2", .message("/review")),
                                     ("@Mint-2: stop", "Mint 2", .stop), ("@Mint add a test", "Mint", .message("Add a test"))] as [(String, String, HelperTalk.Intent)] {
            let got = HelperTalk.byName(said, names: names2)
            check(got?.name == name && got?.intent == intent, "two Mints: \"\(said)\" → \(got.map { "\($0.name) \($0.intent)" } ?? "not about a helper")")
        }
        check(HelperTalk.byName("How's Mint 2 doing?", names: names) == nil, "\"Mint 2\" with only one Mint: not about a helper")
        check(HelperTalk.without(name: "Mint", in: "Mint 2, yes") == nil && HelperTalk.without(name: "Mint 2", in: "Mint 2, yes") == "yes"
              && HelperTalk.without(name: "Mint", in: "Mint, yes") == "yes", "answering by name: \"Mint 2, yes\" isn't for Mint")
        check(HelperTalk.canonical("mint two, yes", names: names2) == "Mint 2, yes" && HelperTalk.canonical("Mint, two tests fail", names: names2) == "Mint, two tests fail",
              "\"mint two\" → \(HelperTalk.canonical("mint two, yes", names: names2))")
        // Helper names: never one this run already had (the Helpers window lists them all).
        let n1 = AgentManager.pickName(used: [("Mint", false)])
        let n2 = AgentManager.pickName(used: AgentManager.names.map { ($0, false) })
        let n3 = AgentManager.pickName(used: AgentManager.names.map { ($0, false) } + [("Mint 2", true)], reserved: ["Coral 2"])
        check(n1 == "Coral" && n2 == "Mint 2" && n3 == "Violet 2", "names: a finished Mint isn't reused (\(n1)); after all six: \(n2), then \(n3)")
        // Tokens from the stream: a reply's usage repeats on each of its parts, so it counts once.
        var ts = HelperStream()
        let reply = { (id: String, out: Int, ctx: Int, nested: Bool) in
            #"{"type":"assistant","parent_tool_use_id":"# + (nested ? #""t1""# : "null") + #","message":{"id":""# + id + #"","content":[],"usage":{"input_tokens":3,"cache_read_input_tokens":"# + "\(ctx)" + #","cache_creation_input_tokens":0,"output_tokens":"# + "\(out)" + "}}}\n"
        }
        _ = ts.feed(Data((reply("a", 50, 1000, false) + reply("a", 50, 1000, false) + reply("b", 200, 4000, false) + reply("c", 30, 9999, true)).utf8))
        check(ts.outputTokens == 280 && ts.contextTokens == 4003, "tokens: \(ts.outputTokens) written (each reply once, sub-agents too), conversation \(ts.contextTokens) (not a sub-agent's)")
        // A live cost estimate from the same tokens (list prices; Claude Code's own figure comes at a turn's end).
        var cs = HelperStream()
        let costLines: [String] = [
            #"{"type":"system","subtype":"init","session_id":"s","model":"claude-sonnet-5-5"}"#,
            #"{"type":"assistant","parent_tool_use_id":null,"message":{"id":"a","content":[],"usage":{"input_tokens":1000,"cache_read_input_tokens":100000,"cache_creation_input_tokens":20000,"output_tokens":5000}}}"#,
            #"{"type":"assistant","parent_tool_use_id":null,"message":{"id":"a","content":[],"usage":{"input_tokens":1000,"cache_read_input_tokens":100000,"cache_creation_input_tokens":20000,"output_tokens":5000}}}"#,
            #"{"type":"assistant","parent_tool_use_id":"t1","message":{"id":"h","model":"claude-haiku-5-5","content":[],"usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":100000}}}"#]
        _ = cs.feed(Data(costLines.map { $0 + "\n" }.joined().utf8))
        // Sonnet 5.5: 1000×2 + 5000×10 + 100000×0.10 + 20000×2.5 = 112,000 µ$ = $0.112; its Haiku sub-agent: 100000×0.5 = $0.05.
        let est = cs.estimatedCost ?? -1
        check(abs(est - 0.162) < 0.0001, "cost: estimated from each reply's tokens and its own model (\(est))")
        let pOpus55: Bool = HelperCost.price(for: "claude-opus-5-5[1m]")?.output == 20
        let pOpus5: Bool = HelperCost.price(for: "claude-opus-5")?.output == 25
        let pFable: Bool = HelperCost.price(for: "claude-fable-5-1")?.cacheRead == 0.25
        check(pOpus55 && pOpus5 && pFable && HelperCost.price(for: "gpt-5") == nil, "cost: the price table picks the right model")
        let l1 = HelperCost.live(cost: nil, estimate: 0.05, estimateAtCost: 0)
        let l2 = HelperCost.live(cost: 0.40, estimate: 0.30, estimateAtCost: 0.30)
        let l3 = HelperCost.live(cost: 0.40, estimate: 0.45, estimateAtCost: 0.30)
        let l4 = HelperCost.live(cost: nil, estimate: nil, estimateAtCost: 0)
        let liveOK1: Bool = l1?.estimated == true && l2?.dollars == 0.40 && l2?.estimated == false
        let liveOK2: Bool = abs((l3?.dollars ?? 0) - 0.55) < 1e-9 && l3?.estimated == true && l4 == nil
        check(liveOK1 && liveOK2, "cost: Claude Code's figure at a turn's end, plus an estimate after it")
        changesChecks(check)
        // A new helper from the Helpers window (⌘N).
        check(HelperWindows.title(for: "fix the failing login test and add one for expired passwords") == "Fix the failing login test", "new helper: a title from the task (\(HelperWindows.title(for: "fix the failing login test and add one for expired passwords")))")
        let hw = HelperWindows()
        var got: AgentRequest?
        hw.onNew = { req in got = req; return nil }
        check(hw.startNew(task: "  ", dir: NSHomeDirectory(), model: "", plan: false) == "Say what it should do.", "new helper: nothing to do")
        check(hw.startNew(task: "x", dir: "/no/such/folder", model: "", plan: false) == "That folder doesn’t exist.", "new helper: a folder that isn't there")
        _ = hw.startNew(task: "/review", dir: "~", model: "opus", plan: true)
        check(got?.task == "/review" && got?.dir == NSHomeDirectory() && got?.model == "claude-opus-5-5" && got?.planFirst == true,
              "new helper: task, folder (~ expanded), model and plan reach the app (\(String(describing: got)))")
        editMenuChecks(check)
        askChecks(check)
        notifierChecks(check)
        lines.append(fails == 0 ? "ALL OK" : "\(fails) FAILED")
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    /// What a helper changed (files from its steps, their diff in a scratch git repo), and the Terminal script.
    static func changesChecks(_ check: (Bool, String) -> Void) {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory.appendingPathComponent("poinky-changes-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: repo) }
        try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
        func sh(_ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", repo.path] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; try? p.run(); p.waitUntilExit() }
        try? "def add(a, b):\n    return a - b\n".write(to: repo.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        try? "notes\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        sh(["init", "-q"]); sh(["add", "-A"]); sh(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "start"])
        try? "notes\nmine, not committed\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let base = HelperChanges.startPoint(repo)   // when the helper starts: your uncommitted change is part of it
        try? "notes\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try? "def add(a, b):\n    return a + b\n".write(to: repo.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        try? "def test_add():\n    assert add(1, 2) == 3\n".write(to: repo.appendingPathComponent("test_calc.py"), atomically: true, encoding: .utf8)
        let p = { (f: String) in repo.appendingPathComponent(f).path }
        let entries = [HelperEntry(k: "task", text: "t", detail: repo.path, kind: "Mint"),
                       HelperEntry(k: "step", text: "Reading calc.py", detail: p("calc.py"), kind: "read"),
                       HelperEntry(k: "step", text: "Editing calc.py", detail: p("calc.py"), kind: "edit"),
                       HelperEntry(k: "step", text: "Writing test_calc.py", detail: p("test_calc.py"), kind: "edit"),
                       HelperEntry(k: "step", text: "Editing calc.py", detail: p("calc.py"), kind: "edit"),
                       HelperEntry(k: "step", text: "Editing notes.txt", detail: p("notes.txt"), kind: "edit")]
        let files = HelperChanges.files(entries)
        check(files == [p("calc.py"), p("test_calc.py"), p("notes.txt")], "changes: the files it edited, once each, in order (\(files.map { ($0 as NSString).lastPathComponent }))")
        check(HelperWindows.short(p("calc.py"), in: repo) == "calc.py", "changes: shown relative to its folder")
        let d = HelperChanges.diff(files: files, in: repo)
        let c = HelperChanges.counts(d)
        check(d.contains("-    return a - b") && d.contains("+    return a + b"), "changes: the diff of an edited file")
        check(d.contains("+++ b/test_calc.py") && d.contains("+    assert add(1, 2) == 3"), "changes: a new file in full")
        check(d.contains("No changes now") && d.contains("notes.txt"), "changes: a file with no changes now is named, not hidden")
        check(c.added == 3 && c.removed == 1, "changes: +\(c.added) −\(c.removed)")
        // It commits its work: from where it started, that still shows; from HEAD it doesn't.
        sh(["add", "-A"]); sh(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "helper"])
        let since = HelperChanges.diff(files: files, in: repo, base: base)
        check(base != nil && since.hasPrefix("#@since-start") && since.contains("+    return a + b") && since.contains("+++ b/test_calc.py"),
              "changes: what it committed still shows (from where it started)")
        check(since.contains("-mine, not committed"), "changes: from where it started, your folder as it was then (\(HelperChanges.counts(since)))")
        check(HelperChanges.diff(files: files, in: repo).contains("No changes now"), "changes: without a start point, only what isn't committed")
        check(HelperChanges.base([HelperEntry(k: "worktree", text: "/r", detail: "/w", id: "abc123")]) == "abc123", "changes: a worktree's start point")
        // Work kept on a branch (its worktree's changes didn't fit): the window shows that branch.
        sh(["checkout", "-q", "-b", "poinky/coral-test"])
        try? "def add(a, b):\n    return b + a\n".write(to: repo.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        sh(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam", "coral"])
        sh(["checkout", "-q", "-"])
        let head = { () -> String in let p = Process(); let o = Pipe(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path, "rev-parse", "HEAD"]; p.standardOutput = o; try? p.run(); p.waitUntilExit()
            return String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }()
        let kept = [HelperEntry(k: "worktree", text: repo.path, detail: "/tmp/gone-worktree-xyz", id: head),
                    HelperEntry(k: "branch", text: repo.path, id: "poinky/coral-test")]
        let bd = HelperChanges.branchDiff(kept) ?? ""
        check(bd.hasPrefix("#@branch poinky/coral-test") && bd.contains("+    return b + a") && bd.contains("-    return a + b"), "changes: work kept on a branch shows that branch's diff")
        check(HelperChanges.branchDiff([HelperEntry(k: "branch", text: repo.path, id: "poinky/gone")])?.contains("isn't there any more") == true, "changes: a branch that's gone says so")
        check(HelperChanges.branchDiff(entries) == nil, "changes: no branch, no branch diff")
        let nogit = HelperChanges.diff(files: ["/tmp/x.txt"], in: URL(fileURLWithPath: "/"))
        check(nogit.hasPrefix("# Not in a git repository"), "changes: not in a repo, it says so")
        // A worktree that's gone: its files are shown in your folder.
        let wt = [HelperEntry(k: "worktree", text: repo.path, detail: "/tmp/gone-worktree-xyz"),
                  HelperEntry(k: "step", text: "e", detail: "/tmp/gone-worktree-xyz/calc.py", kind: "edit")]
        check(HelperChanges.files(wt) == [p("calc.py")], "changes: from a worktree that's gone, the same file in your folder")
        let script = HelperChanges.terminalScript(claude: "/usr/local/bin/claude", dir: URL(fileURLWithPath: "/Users/x/My Project"), session: "3f2a-9c1b", fork: true)
        check(script.contains("cd '/Users/x/My Project'") && script.contains("exec '/usr/local/bin/claude' --resume 3f2a-9c1b --fork-session"), "terminal: resumes its session in its folder (a copy while it works)")
        let odd = HelperChanges.terminalScript(claude: "claude", dir: URL(fileURLWithPath: "/x"), session: "a'b; rm", fork: false)
        check(odd.contains("--resume 'a'\\''b; rm'") && !odd.contains("--fork-session"), "terminal: an odd session id is quoted")
    }

    /// ⌘C / ⌘V / ⌘A / ⌘Z work in the type box and the Helpers window (a menu bar app has no Edit menu of its own).
    static func editMenuChecks(_ check: (Bool, String) -> Void) {
        EditMenu.install()
        let keys = Dictionary((NSApp.mainMenu?.items ?? []).flatMap { $0.submenu?.items ?? [] }
            .filter { !$0.keyEquivalent.isEmpty }.map { ($0.keyEquivalent + ($0.keyEquivalentModifierMask.contains(.shift) ? "⇧" : ""), $0.action) }, uniquingKeysWith: { a, _ in a })
        let want: [(String, Selector)] = [("c", #selector(NSText.copy(_:))), ("v", #selector(NSText.paste(_:))), ("x", #selector(NSText.cut(_:))),
                                          ("a", #selector(NSText.selectAll(_:))), ("z", Selector(("undo:"))), ("z⇧", Selector(("redo:"))),
                                          ("w", #selector(NSWindow.performClose(_:)))]
        for (k, sel) in want { check(keys[k] == sel, "edit menu: ⌘\(k.uppercased()) → \(NSStringFromSelector(sel))") }
    }
}

extension HelperTest {
    /// Mac notifications for helpers, through a fake notification center (no permission prompt on this Mac).
    static func notifierChecks(_ check: (Bool, String) -> Void) {
        func request(_ id: String, _ tool: String, _ input: [String: Any]) -> HelperAsk? {
            HelperAsk.from(["type": "control_request", "request_id": id, "request": ["subtype": "can_use_tool", "tool_name": tool, "input": input]])
        }
        guard let npm = request("r1", "Bash", ["command": "make build"]),
              let push = request("r2", "Bash", ["command": "git push origin main --force"]),
              let edit = request("r3", "Edit", ["file_path": "/tmp/proj/calc.py"]),
              let q = request("r4", "AskUserQuestion", ["questions": [["question": "Tabs or spaces?", "options": [["label": "Tabs"], ["label": "Spaces"]]]]]),
              let plan = request("r5", "ExitPlanMode", ["plan": "# Fix the rounding\n1. Read calc.py"])
        else { check(false, "notifier: requests parse"); return }
        let fake = FakeNotifications()
        let n = HelperNotifier(poster: fake)
        var c = AppConfig()
        c.helperNotify = true
        n.settings(c)
        var away = false
        n.isAway = { away }
        var answers: [(Int, String, HelperAsk.Reply)] = [], opened: [Int] = []
        n.onAnswer = { answers.append(($0, $1, $2)) }
        n.onOpen = { opened.append($0) }
        var a = AgentManager.Agent(id: 7, name: "Mint 2", title: "Add left-pad to the demo", task: "…", dir: URL(fileURLWithPath: "/tmp/proj"), started: Date(), log: URL(fileURLWithPath: "/tmp/x.md"))

        n.asking(a, npm, inSession: true)
        check(fake.posted.isEmpty, "notifier: in a session Poinky says it out loud (no notification)")
        n.asking(a, npm, inSession: false)
        let p1 = fake.posted.last
        check(p1?.title == "Mint 2: Add left-pad to the demo" && p1?.body == "Can I run make build?" && p1?.category == HelperNotifier.askCategory,
              "notifier: no session: its name and task, the plain question (\(p1.map { "\($0.title) / \($0.body)" } ?? "none"))")
        n.asking(a, npm, inSession: true, parked: true)
        check(fake.posted.count == 1, "notifier: parked later: not shown twice")
        fake.click(.allow, agent: 7)
        check(answers.count == 1 && answers[0].0 == 7 && answers[0].1 == "r1" && answers[0].2 == .yes(always: false, extra: ""),
              "notifier: Allow answers that one request with a plain yes (never \"always\")")
        fake.click(.allow, agent: 7)
        check(answers.count == 1, "notifier: a second click on an answered one does nothing")

        // Answered by voice (or on the card): its notification goes away, and its buttons no longer count.
        n.asking(a, edit, inSession: false)
        n.stillOpen([])
        check(fake.removed.contains(HelperNotifier.id(edit)), "notifier: answered elsewhere: its notification is removed")
        fake.click(.allow, agent: 7)
        check(answers.count == 1, "notifier: … and Allow on it does nothing")

        // Risky: Allow still works (an explicit click), but the exact command is said, and the Allow is the red one.
        a.asks = [push]
        n.asking(a, push, inSession: true, parked: true)
        let p2 = fake.posted.last
        check(p2?.category == HelperNotifier.riskyCategory && p2?.body.contains("git push origin main --force") == true,
              "notifier: a risky one says exactly what it runs (\(p2?.body.replacingOccurrences(of: "\n", with: " / ") ?? ""))")
        fake.click(.deny, agent: 7)
        check(answers.last?.1 == "r2" && answers.last?.2 == .no(reason: ""), "notifier: Don't allow says no")

        // A question: Open shows its window (answers nothing); You choose answers it.
        n.asking(a, q, inSession: false)
        check(fake.posted.last?.category == HelperNotifier.questionCategory && fake.posted.last?.body == "Tabs or spaces?\nTabs · Spaces", "notifier: a question with its choices")
        let before = answers.count
        fake.click(.allow, agent: 7)
        fake.click(.open, agent: 7)
        check(answers.count == before && opened == [7, 7], "notifier: a question isn't answered by Allow; Open shows its window")
        fake.click(.choose, agent: 7)
        check(answers.last?.1 == "r4" && answers.last?.2 == .answer("No preference: you choose."), "notifier: You choose answers the question")

        n.asking(a, plan, inSession: false)
        check(fake.posted.last?.category == HelperNotifier.planCategory && fake.posted.last?.body.contains("Fix the rounding") == true, "notifier: a plan, with its title")

        // Finished: only when asked for, and only while you're away.
        a.status = .done; a.summary = "Added left-pad. All tests pass. Nothing else changed."
        let count = fake.posted.count
        n.finished(a)
        check(fake.posted.count == count, "notifier: finished: off unless you turn it on")
        c.helperNotifyDone = true
        n.settings(c); n.isAway = { away }
        n.finished(a)
        check(fake.posted.count == count, "notifier: finished while you're at the Mac: no notification")
        away = true
        n.finished(a)
        check(fake.posted.last?.title == "Mint 2 finished: Add left-pad to the demo" && fake.posted.last?.body == "Added left-pad. All tests pass.",
              "notifier: finished while away: \(fake.posted.last.map { "\($0.title) / \($0.body)" } ?? "none")")
        fake.click(.open, agent: 7)
        check(opened.last == 7, "notifier: clicking it opens its window")

        // Turned off: nothing, and what was shown goes away.
        c.helperNotify = false
        n.settings(c)
        let count2 = fake.posted.count
        n.asking(a, edit, inSession: false)
        check(fake.posted.count == count2 && fake.removed.contains(HelperNotifier.id(plan)), "notifier: turned off: no notifications, open ones removed")
    }
}
