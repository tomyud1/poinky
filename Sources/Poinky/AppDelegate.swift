import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: CallController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        EditMenu.install()   // ⌘C / ⌘V / ⌘A / ⌘Z in the type box and the Helpers window
        // Developer check: `open -n -g Poinky.app --args --read-app <out.txt> ["Menu > Item"]`
        // writes what the doer would read about the front app, then quits.
        let args = CommandLine.arguments
        // Updates (see Updater.swift): `--update-test out.txt` checks, updates and maybe restarts;
        // the restarted copy gets `--update-relaunched out.txt`, writes which commit it is, and quits.
        if let i = args.firstIndex(of: "--update-relaunched"), i + 1 < args.count {
            let line = "relaunched \(Updater.running.commit.prefix(7)) at \(Bundle.main.bundlePath)\n"
            if let h = FileHandle(forWritingAtPath: args[i + 1]) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
            NSApp.terminate(nil)
            return
        }
        if let i = args.firstIndex(of: "--update-test"), i + 1 < args.count {
            Updater.shared.selfTest(out: args[i + 1])
            return
        }
        // `Poinky --study-eval <outdir> <sheet> <en|he> <step>…`: a study session with the real models, no screen (StudyEval.swift).
        if let i = args.firstIndex(of: "--study-eval") {
            let rest = Array(args[(i + 1)...])
            Task { @MainActor in await StudyEval.run(rest) }
            return
        }
        // `Poinky --study-pdf <state.json> <out.pdf>`: the solved PDF of a saved study session (its files beside state.json).
        if let i = args.firstIndex(of: "--study-pdf"), i + 2 < args.count {
            let state = URL(fileURLWithPath: args[i + 1]), dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let data = try? Data(contentsOf: state), let sheet = try? dec.decode(StudySheet.self, from: data) {
                setenv("POINKY_STUDY_DIR", state.deletingLastPathComponent().deletingLastPathComponent().path, 1)
                print(StudyPDF.build(sheet, to: URL(fileURLWithPath: args[i + 2]))?.path ?? "failed")
            } else { print("can't read \(state.path)") }
            exit(0)
        }
        // `Poinky --read-context out.txt`: what AppContextReader sees in the front app (as the signed app).
        if let i = args.firstIndex(of: "--read-context"), i + 1 < args.count {
            let out = args[i + 1]
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                let t = Date()
                let c = AppContextReader.read(app: NSWorkspace.shared.frontmostApplication, excluded: [])
                let text = "trusted: \(AXIsProcessTrusted()), took \(Int(Date().timeIntervalSince(t) * 1000)) ms\n" + c.lines.joined(separator: "\n") + "\n"
                try? text.write(toFile: out, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        if let i = args.firstIndex(of: "--read-app"), i + 1 < args.count {
            let out = args[i + 1], menu = i + 2 < args.count ? args[i + 2] : nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    let screen = NSScreen.main ?? NSScreen.screens[0]
                    let t = Date()
                    let r = AppReader.read(screen: screen, scale: ScreenCapture.imageScale(for: screen.frame.size))
                    var text = "trusted: \(Computer.trusted), took \(Int(Date().timeIntervalSince(t) * 1000)) ms\n" + r.lines.joined(separator: "\n")
                    if let menu {
                        text += "\nmenu: " + (AppReader.pickMenu(menu.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }, pid: r.pid) ?? "ok")
                    }
                    try? text.write(toFile: out, atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                }
            }
            return
        }
        // Developer check for helpers: `Poinky --helper-test <out.txt> <folder> <task>…` runs the
        // tasks through AgentManager and writes every event, then quits. With
        // POINKY_HELPER_CMD=tools/fake-helper.py and tasks like "fixture:fix-bug" it spends no tokens.
        // POINKY_TEST_MAX: helpers at once (default 3). POINKY_TEST_FOLLOWUP="5|text": a follow-up to the first.
        // `Poinky --helper-screen-test <outdir> <folder> <task>…`: the same, shown on screen through the real
        // overlay, with snapshots of what it draws (outdir/shot-*.png) and a log (outdir/log.txt).
        if let i = args.firstIndex(of: "--helper-screen-test"), i + 2 < args.count {
            HelperTest.runOnScreen(outDir: args[i + 1], dir: args[i + 2], tasks: Array(args[(i + 3)...]))
            return
        }
        if let i = args.firstIndex(of: "--helper-talk-test"), i + 1 < args.count {
            HelperTest.talkSelfTest(out: args[i + 1])
            return
        }
        // `Poinky --type-box-test <outdir>`: opens the box to type in, types into it, and checks Return and
        // Shift-Return (outdir/log.txt, and pictures of it).
        if let i = args.firstIndex(of: "--type-box-test"), i + 1 < args.count {
            TypeBox.selfTest(outDir: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--settings-shot"), i + 1 < args.count {
            SettingsWindowController.shared.snapshotTab(to: args[i + 1], tab: args.dropFirst(i + 2).first ?? "claude")
            return
        }
        if let i = args.firstIndex(of: "--helper-test"), i + 2 < args.count {
            HelperTest.run(out: args[i + 1], dir: args[i + 2], tasks: Array(args[(i + 3)...]))
            return
        }
        // `Poinky --mic-check-shot <out.png>` (with POINKY_MIC_CHECK_WAVS=<dir>): the mic check on recordings.
        if let i = args.firstIndex(of: "--mic-check-shot"), i + 1 < args.count {
            MicCheckWindow.snapshot(to: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--receipts-shot"), i + 1 < args.count {
            ReceiptsWindow.snapshot(to: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--notch-shot"), i + 1 < args.count {
            NotchHome.snapshot(to: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--welcome-shot"), i + 1 < args.count {
            WelcomeWindowController.shared.snapshot(outDir: args[i + 1])
            return
        }
        // The first-run tour opens for a new install (no settings yet) or one left halfway; `--welcome` forces it.
        let configExisted = FileManager.default.fileExists(atPath: AppConfig.fileURL.path)
        let listenTest = args.firstIndex(of: "--listen-test").flatMap { i in i + 2 < args.count ? (args[i + 1], args[i + 2]) : nil }
        if listenTest != nil { ListenTest.prepare() }
        let c = CallController()
        c.setup()
        controller = c
        // `Poinky --listen-test <script.json> <out.txt>`: scripted holds and heard words (ListenTest.swift).
        if let (script, out) = listenTest { ListenTest.run(script: script, out: out, controller: c) }
        // `Poinky --mic-check`: opens the microphone check (also Settings → Voice).
        if args.contains("--mic-check") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MicCheckWindow.shared.show() } }
        let quiet = args.contains { ["--ask", "--type", "--video", "--play-video", "--listen-test", "--mic-check"].contains($0) }
        if let page = args.contains("--welcome") ? .hello : quiet ? nil : WelcomeModel.pageToResume(configExisted: configExisted) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { WelcomeWindowController.shared.show(at: page) }
        }
        // FirstRun.swift: the hello that follows the tour (`--firstrun-hello [secs]`, e.g. after an --ask's answer).
        if let i = args.firstIndex(of: "--firstrun-hello") {
            let secs = args.indices.contains(i + 1) ? Double(args[i + 1]) ?? 0 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { c.testFirstRunHello() }
        }
        // Developer checks for video explainers (see CallController+Video.swift).
        if let i = args.firstIndex(of: "--video"), i + 1 < args.count { c.devVideo(topic: args[i + 1]) }
        if let i = args.firstIndex(of: "--play-video"), i + 1 < args.count { c.devPlayVideo(dir: args[i + 1]) }
        // `Poinky --ask "question" [--ask …] [--quit-after secs]`: asks a typed question in a real session (tests of the
        // call loop without a mic; with POINKY_CLAUDE_CMD=tools/fake-claude.py no tokens are used).
        // Several `--ask`s are asked one after another, `POINKY_ASK_GAP` seconds apart (default 5).
        let gap = ProcessInfo.processInfo.environment["POINKY_ASK_GAP"].flatMap(Double.init) ?? 5
        // `--study-photo <file>` among the asks: a photo of your work handed to the study session (as the iPhone capture does).
        let asks = args.indices.filter { ["--ask", "--study-photo"].contains(args[$0]) && $0 + 1 < args.count }
            .map { args[$0] == "--study-photo" ? "\u{1}photo:" + args[$0 + 1] : args[$0 + 1] }
        let ask: (String) -> Void = { q in
            if q.hasPrefix("\u{1}photo:") { StudySession.shared.driver = c; StudySession.shared.checkWork(file: URL(fileURLWithPath: String(q.dropFirst(7)))) } else { c.askTyped(q) }
        }
        if let wait = ProcessInfo.processInfo.environment["POINKY_ASK_WAIT"].flatMap(Double.init), asks.count > 1 {
            // Each question after the first waits until the last answer is done (spoken and sketched) plus `wait` s.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { ask(asks[0]) }
            var next = 1, quietSince: Double?
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
                MainActor.assumeIsolated {
                    guard next < asks.count else { t.invalidate(); return }
                    let now = ProcessInfo.processInfo.systemUptime
                    if !c.quietForTests { quietSince = nil; return }
                    if quietSince == nil { quietSince = now }
                    if now - quietSince! >= wait { ask(asks[next]); next += 1; quietSince = nil }
                }
            }
        } else {
            for (n, q) in asks.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(n) * gap) { ask(q) }
            }
        }
        // `--type "question"`: typed in the type box (it stays open with the answer; nothing is said).
        for (n, q) in args.indices.filter({ args[$0] == "--type" && $0 + 1 < args.count }).map({ args[$0 + 1] }).enumerated() {
            TypeBox.keepForTests = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(n) * gap) { c.typeInBox(q) }
        }
        if let i = args.firstIndex(of: "--end-after"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { c.endCall(quietly: true) }   // tests: the session ends (daily note)
        }
        if let i = args.firstIndex(of: "--quit-after"), i + 1 < args.count, let secs = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { NSApp.terminate(nil) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
        Timeline.flush()   // "app.quit" must be on disk, or the next launch counts this run as unclean
    }
}
