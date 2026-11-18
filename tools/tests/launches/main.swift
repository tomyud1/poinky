import Foundation
// Launches.classify: how the last run ended, from its last timeline event and the heartbeat. Built by tools/test-launches.sh.
var fails = 0
func check(_ name: String, _ got: [String: Any]?, _ want: String?) {
    let how = got?["how"] as? String
    let ok = how == want
    print((ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  got \(how ?? "clean"), want \(want ?? "clean")"))
    if !ok { fails += 1 }
}
let t = 1_800_000_000.0, boot = t - 86400
let noReport: (Double) -> Bool = { _ in false }
check("quit cleanly", Launches.classify(lastEvent: "app.quit", lastT: t, beat: .init(main: t, bg: t), bootTime: boot, crashReportAfter: noReport), nil)
check("first run ever", Launches.classify(lastEvent: nil, lastT: nil, beat: nil, bootTime: boot, crashReportAfter: noReport), nil)
check("killed while beating", Launches.classify(lastEvent: "state", lastT: t - 3, beat: .init(main: t - 2, bg: t), bootTime: boot, crashReportAfter: noReport), "killed")
check("froze 40 s, then killed", Launches.classify(lastEvent: "state", lastT: t - 41, beat: .init(main: t - 40, bg: t), bootTime: boot, crashReportAfter: noReport), "froze")
check("crash report after the end", Launches.classify(lastEvent: "capture", lastT: t, beat: .init(main: t, bg: t), bootTime: boot, crashReportAfter: { $0 < t }), "crashed")
check("the Mac restarted", Launches.classify(lastEvent: "state", lastT: t, beat: .init(main: t, bg: t), bootTime: t + 120, crashReportAfter: noReport), "restart")
check("no heartbeat file (older build)", Launches.classify(lastEvent: "session.end", lastT: t, beat: nil, bootTime: boot, crashReportAfter: noReport), "killed")
print(fails == 0 ? "all passed" : "\(fails) failed")
exit(fails == 0 ? 0 : 1)
