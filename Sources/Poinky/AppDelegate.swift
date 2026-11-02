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
        let c = CallController()
        c.setup()
        controller = c
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdown()
    }
}
