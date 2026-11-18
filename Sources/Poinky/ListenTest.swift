import AppKit

/// `Poinky --listen-test <script.json> <out.txt>`: holds of the talk keys and the words the speech engine
/// "hears", scripted, through the real call loop and overlay (no microphone, no keyboard). Each step runs at
/// `at` seconds after launch:
///   {"at": 1.0, "keys": "down"}            the talk keys go down (or "up"); PushToTalk's own timing applies
///   {"at": 1.6, "words": "what is", "final": false, "live": true}   a result (main transcriber unless "live")
///   {"at": 2.4, "probe": "label"}          writes what the bubble shows (SB.bubbleState) and the call state
///   {"at": 3.0, "killPage": true}         ends the overlay page's process (as memory pressure would)
///   {"at": 1.0, "contentVisible": false}  the drawings' window is covered (WindowTracker hides them)
///   {"at": 1.0, "endSession": true}       the session ends (as after 15 idle minutes)
///   {"at": 1.0, "js": "expr", "expectJS": "value", "label": "…"}   evaluates in the overlay page and checks the result
///   {"at": 1.0, "saved": true}            a page was saved ("save my notes"): Poinky says where
///   {"at": 1.0, "helper": "fixture:fix-bug"}   starts a helper (POINKY_HELPER_CMD={root}/tools/fake-helper.py)
///   {"at": 2.0, "pointHelper": true}      as if the mouse rested on the newest helper (false: on nothing)
///   {"at": 1.0, "type": "question"}       a typed question (⌃⌥T)
///   {"at": 9.0, "quit": true}
/// A probe's "expect" is checked here (ListenTest.check) and written as an ok / FAIL line. A script can be a list of
/// steps or {"env": {…}, "steps": […]} (tools/test-listen.sh passes the env on).
/// Use with POINKY_SUPPORT_DIR (scratch settings), POINKY_CLAUDE_CMD=tools/fake-claude.py (no tokens) and
/// POINKY_OVERLAY_LOG (every call into the page). tools/test-listen.sh runs the scenarios in tools/listen-test/.
@MainActor
enum ListenTest {
    /// What a probe expects: "state", "kind" (you / claude / none), "text" (exact), "contains", "dim", "miss", "near"
    /// (the bubble is next to the buddy). Returns what didn't match.
    static func check(_ want: [String: Any], got: [String: Any], state: String) -> [String] {
        var bad: [String] = []
        let on = got["on"] as? Bool ?? false
        let kind = on ? (got["kind"] as? String ?? "none") : "none"
        let text = got["text"] as? String ?? "", cls = got["cls"] as? String ?? ""
        if let s = want["state"] as? String, s != state { bad.append("state \(state), wanted \(s)") }
        if let s = want["notState"] as? String, s == state { bad.append("state \(state)") }
        if let k = want["kind"] as? String, k != kind { bad.append("bubble \(kind) “\(text)”, wanted \(k)") }
        if let t = want["text"] as? String, on, t != text { bad.append("text “\(text)”, wanted “\(t)”") }
        if let t = want["contains"] as? String, !(on && text.contains(t)) { bad.append("text “\(text)” lacks “\(t)”") }
        if let d = want["dim"] as? Bool, d != cls.contains("dim") { bad.append("dim \(!d)") }
        if let m = want["miss"] as? Bool, m != cls.contains("miss") { bad.append("note \(!m)") }
        if want["near"] as? Bool == true, let b = got["buddy"] as? [String: Any] {
            let bx = (b["x"] as? NSNumber)?.doubleValue ?? 0, by = (b["y"] as? NSNumber)?.doubleValue ?? 0
            let x = (got["x"] as? NSNumber)?.doubleValue ?? 0, y = (got["y"] as? NSNumber)?.doubleValue ?? 0
            let w = (got["w"] as? NSNumber)?.doubleValue ?? 0, h = (got["h"] as? NSNumber)?.doubleValue ?? 0
            let dx = max(x - bx, 0, bx - (x + w)), dy = max(y - by, 0, by - (y + h))
            if (dx * dx + dy * dy).squareRoot() > 40 { bad.append("bubble at \(Int(x)),\(Int(y)), buddy at \(Int(bx)),\(Int(by))") }
        } else if want["near"] as? Bool == true { bad.append("buddy not placed") }
        return bad
    }

    static func prepare() {
        SpeechListener.fake = true
        AudioIO.fakeMic = true
    }

    private static var timers: [DispatchSourceTimer] = []

    static func run(script: String, out: String, controller c: CallController) {
        c.testKeys(down: false)   // from now on the real ⌃⌥ is ignored (the owner's own Poinky may be running)
        FileManager.default.createFile(atPath: out, contents: nil)
        let h = FileHandle(forWritingAtPath: out)
        func write(_ line: String) {
            h?.write(Data((line + "\n").utf8))
            Overlay.logCall("# " + line)
        }
        let json = FileManager.default.contents(atPath: script).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        guard let steps = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["steps"] as? [[String: Any]]) else {
            write("error: can't read \(script)"); NSApp.terminate(nil); return
        }
        let started = ProcessInfo.processInfo.systemUptime
        for step in steps {
            let at = (step["at"] as? NSNumber)?.doubleValue ?? 0
            // (A plain asyncAfter tens of seconds out runs up to ~1.5 s late: GCD's leeway grows with the delay.)
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
            timers.append(timer)
            timer.schedule(deadline: .now() + at, leeway: .milliseconds(2))
            defer { timer.resume() }
            timer.setEventHandler {
                MainActor.assumeIsolated {
                    if let k = step["keys"] as? String {
                        c.testKeys(down: k == "down")
                        write(String(format: "%.2f keys %@ (state %@, %.2f s late)", at, k, c.testState,
                                     ProcessInfo.processInfo.systemUptime - started - at))
                    }
                    if let w = step["words"] as? String {
                        c.testWords(w, final: step["final"] as? Bool ?? false, live: step["live"] as? Bool ?? false)
                    }
                    if let label = step["probe"] as? String {
                        c.overlay.evaluateForTest("JSON.stringify(SB.bubbleState ? SB.bubbleState() : null)") { r in
                            MainActor.assumeIsolated {
                                let json = (r as? String) ?? "null"
                                write(String(format: "%.2f probe %@ state=%@ bubble=%@", at, label, c.testState, json))
                                if let want = step["expect"] as? [String: Any] {
                                    let got = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
                                    let bad = check(want, got: got, state: c.testState)
                                    write((bad.isEmpty ? "ok   " : "FAIL ") + label + (bad.isEmpty ? "" : " (" + bad.joined(separator: "; ") + ")"))
                                }
                            }
                        }
                    }
                    if let on = step["contentVisible"] as? Bool { c.testCoverDrawings(!on); write(String(format: "%.2f drawings %@", at, on ? "shown" : "hidden (a window covers them)")) }
                    if step["endSession"] as? Bool == true { c.testEndSession(); write(String(format: "%.2f session ended", at)) }
                    if let js = step["js"] as? String {
                        c.overlay.evaluateForTest(js) { r in
                            MainActor.assumeIsolated {
                                let got = r.map { "\($0)" } ?? "nil"
                                write(String(format: "%.2f js %@ = %@", at, js, got))
                                if let want = step["expectJS"] as? String { write((got == want ? "ok   " : "FAIL ") + (step["label"] as? String ?? js) + (got == want ? "" : " (got \(got), wanted \(want))")) }
                            }
                        }
                    }
                    if step["saved"] as? Bool == true { c.testLessonSaved(); write(String(format: "%.2f a page was saved (state %@)", at, c.testState)) }
                    if let task = step["helper"] as? String {
                        write(String(format: "%.2f helper %@", at, c.testStartHelper(task).map { "\($0)" } ?? "didn't start"))
                    }
                    if let p = step["pointHelper"] as? Bool {
                        let id = p ? c.agents.agents.last?.id : nil
                        c.overlay.testPointHelper(id)
                        write(String(format: "%.2f pointing at helper %@", at, id.map { "\($0)" } ?? "none"))
                    }
                    if let t = step["type"] as? String { c.askTyped(t); write(String(format: "%.2f typed", at)) }
                    if step["killPage"] as? Bool == true { c.overlay.testKillPage(); write(String(format: "%.2f page killed", at)) }
                    if step["quit"] as? Bool == true { try? h?.synchronize(); NSApp.terminate(nil) }
                }
            }
        }
    }
}
