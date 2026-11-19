// A window of the test's own, in front, covering the screen while a test copy of Poinky takes screenshots, so they
// never show what the person at the Mac has open. Shows a picture (the homework sheet) if given.
// Usage: cover-window <seconds> <status-file> [image]
// It writes "front" to the status file once it's the front app, "notfront" if it couldn't get in front within
// 5 s (the test must not go on), and "lost" if it stops being in front while it's up.
import AppKit

let args = CommandLine.arguments
let secs = Double(args.count > 1 ? args[1] : "60") ?? 60
let status = args.count > 2 ? args[2] : "/dev/null"
func say(_ s: String) { try? (s + "\n").write(toFile: status, atomically: true, encoding: .utf8) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.main ?? NSScreen.screens[0]
let w = NSWindow(contentRect: screen.visibleFrame, styleMask: [.titled], backing: .buffered, defer: false)
w.title = "Poinky test window"
w.backgroundColor = NSColor(white: 0.93, alpha: 1)
if args.count > 3, let img = NSImage(contentsOfFile: args[3]) {
    let v = NSImageView(frame: w.contentView!.bounds)
    v.image = img
    v.imageScaling = .scaleProportionallyUpOrDown
    v.autoresizingMask = [.width, .height]
    w.contentView!.addSubview(v)
}
w.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
let me = ProcessInfo.processInfo.processIdentifier
var wasFront = false
let started = Date()
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == me
    if front && !wasFront { wasFront = true; say("front") }
    if !front && wasFront { say("lost") }
    if !wasFront && Date().timeIntervalSince(started) > 5 { say("notfront"); exit(2) }
    if Date().timeIntervalSince(started) > secs { exit(0) }
}
app.run()
