import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: CallController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Developer check: `open -n -g Poinky.app --args --read-app <out.txt> ["Menu > Item"]`
        // writes what the doer would read about the front app, then quits.
        let args = CommandLine.arguments
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
            SettingsWindowController.shared.snapshotTab(to: args[i + 1], voice: args.dropFirst(i + 2).first == "voice")
            return
        }
        if let i = args.firstIndex(of: "--helper-test"), i + 2 < args.count {
            HelperTest.run(out: args[i + 1], dir: args[i + 2], tasks: Array(args[(i + 3)...]))
            return
        }
        let c = CallController()
        c.setup()
        controller = c
        // Developer checks for video explainers (see CallController+Video.swift).
        if let i = args.firstIndex(of: "--video"), i + 1 < args.count { c.devVideo(topic: args[i + 1]) }
        if let i = args.firstIndex(of: "--play-video"), i + 1 < args.count { c.devPlayVideo(dir: args[i + 1]) }
        // `Poinky --ask "question" [--ask …] [--quit-after secs]`: asks a typed question in a real session (tests of the
        // call loop without a mic; with POINKY_CLAUDE_CMD=tools/fake-claude.py no tokens are used).
        // Several `--ask`s are asked one after another, `POINKY_ASK_GAP` seconds apart (default 5).
        let gap = ProcessInfo.processInfo.environment["POINKY_ASK_GAP"].flatMap(Double.init) ?? 5
        let asks = args.indices.filter { args[$0] == "--ask" && $0 + 1 < args.count }.map { args[$0 + 1] }
        for (n, q) in asks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1 + Double(n) * gap) { c.askTyped(q) }
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
    }
}
