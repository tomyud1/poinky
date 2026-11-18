import Foundation

/// What Poinky did, step by step, so a freeze or a slow answer can be traced afterwards.
/// One JSON line per event in `Poinky/timeline/YYYY-MM-DD.jsonl` (0600, kept 7 days):
/// `{"t": 1731090000.123, "ev": "state", "to": "thinking", "turn": 12}`.
/// Never the words you said or Claude's answer (those live in the conversation log, if it's on).
/// Safe to call from any thread. `POINKY_TIMELINE_DIR` puts it elsewhere (tests).
enum Timeline {
    static let dir: URL = {
        if let d = ProcessInfo.processInfo.environment["POINKY_TIMELINE_DIR"] { return URL(fileURLWithPath: d) }
        return AppConfig.dir.appendingPathComponent("timeline")
    }()
    static let keepDays = 7

    private static let queue = DispatchQueue(label: "poinky.timeline")
    private static var handle: FileHandle?
    private static var handleDay = ""
    private static var pruned = false
    private static var latencies: [Double] = []   // seconds from "you finished asking" to the first word, newest last

    static func log(_ ev: String, _ fields: [String: Any] = [:]) {
        let t = Date().timeIntervalSince1970
        queue.async {
            var obj = fields
            obj["t"] = (t * 1000).rounded() / 1000
            obj["ev"] = ev
            guard JSONSerialization.isValidJSONObject(obj),
                  var line = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
            line.append(0x0A)
            write(line, day: Self.day(t))
        }
    }

    /// Waits until everything logged so far is written (quitting: the process ends right after).
    static func flush() { queue.sync { try? handle?.synchronize() } }

    /// A question was answered out loud: how long the user waited (keys released → first sound).
    static func latency(_ seconds: Double, turn: Int) {
        log("firstSound", ["wait": (seconds * 1000).rounded() / 1000, "turn": turn])
        queue.async {
            latencies.append(seconds)
            if latencies.count > 50 { latencies.removeFirst(latencies.count - 50) }
        }
    }

    /// Median wait over the last `n` answers this run, or nil before the first one.
    static func medianLatency(last n: Int = 20) -> Double? {
        queue.sync {
            let xs = latencies.suffix(n).sorted()
            guard !xs.isEmpty else { return nil }
            return xs.count % 2 == 1 ? xs[xs.count / 2] : (xs[xs.count / 2 - 1] + xs[xs.count / 2]) / 2
        }
    }

    /// The last `n` lines (today's file, then yesterday's if today's is short): for "Copy diagnostics".
    static func recent(_ n: Int = 200) -> [String] {
        queue.sync {
            try? handle?.synchronize()
            let now = Date().timeIntervalSince1970
            var lines: [String] = []
            for back in 0..<2 {
                let url = dir.appendingPathComponent(day(now - Double(back) * 86400) + ".jsonl")
                guard let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
                lines = s.split(separator: "\n").map(String.init) + lines
                if lines.count >= n { break }
            }
            return Array(lines.suffix(n))
        }
    }

    // MARK: - Files (on `queue`)

    private static func day(_ t: TimeInterval) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    private static func write(_ line: Data, day: String) {
        if handle == nil || handleDay != day {
            try? handle?.close()
            handle = nil
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = dir.appendingPathComponent(day + ".jsonl")
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            handleDay = day
            if !pruned { pruned = true; prune() }
        }
        try? handle?.write(contentsOf: line)
    }

    private static func prune() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86400)
        for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            guard url.pathExtension == "jsonl",
                  let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }
}

/// How the last run ended, told apart afterwards: a run that logged "app.quit" ended cleanly. Otherwise a
/// heartbeat file (`timeline/alive`, written every 5 s from a background queue with the main thread's last
/// beat) says which: the main thread had stopped beating well before the end (it froze, then was killed), the
/// Mac started since (restart or power loss), a crash report was written, or it was killed / crashed. Logged as
/// "app.unclean" at the next launch; nothing is shown to the user.
enum Launches {
    struct Beat: Equatable { var main: Double; var bg: Double }

    static var aliveURL: URL { Timeline.dir.appendingPathComponent("alive") }
    nonisolated(unsafe) private static var mainBeat = Date().timeIntervalSince1970
    private static let beatQueue = DispatchQueue(label: "poinky.alive")
    nonisolated(unsafe) private static var bgTimer: DispatchSourceTimer?
    nonisolated(unsafe) private static var mainTimer: Timer?
    /// Tests: `POINKY_TEST_FREEZE=secs`, the main thread blocks for good that long after launch.
    static let testFreezeAfter = ProcessInfo.processInfo.environment["POINKY_TEST_FREEZE"].flatMap(Double.init)

    /// What the last line of the timeline and the heartbeat say about the previous run (nil: it quit cleanly,
    /// or there's no earlier run).
    static func classify(lastEvent: String?, lastT: Double?, beat: Beat?, bootTime: Double, crashReportAfter: (Double) -> Bool) -> [String: Any]? {
        guard let ev = lastEvent, ev != "app.quit" else { return nil }
        var f: [String: Any] = ["last": ev]
        let end = max(beat?.bg ?? 0, lastT ?? 0)
        if end > 0 { f["endedAt"] = (end * 1000).rounded() / 1000 }
        let how: String
        if let b = beat, b.bg - b.main > 15 {
            how = "froze"
            f["frozeFor"] = Int(b.bg - b.main)
        } else if end > 0, crashReportAfter(end - 60) {
            how = "crashed"
        } else if end > 0, bootTime > end {
            how = "restart"   // the Mac started again after the last sign of life: restart, power loss, panic
        } else {
            how = "killed"    // force-quit, killed, or a crash with no report
        }
        f["how"] = how
        return f
    }

    /// At launch, before "app.start": log how the last run ended, then start the heartbeat.
    static func started() {
        let (ev, t) = lastEvent()
        let beat = readBeat()
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        let bootTime = Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6
        if let f = classify(lastEvent: ev, lastT: t, beat: beat, bootTime: bootTime, crashReportAfter: crashReport(after:)) {
            Timeline.log("app.unclean", f)
            NSLog("Poinky: the last run ended uncleanly (\(f["how"] ?? "?"))")
        }
        mainBeat = Date().timeIntervalSince1970
        mainTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in mainBeat = Date().timeIntervalSince1970 }
        let timer = DispatchSource.makeTimerSource(queue: beatQueue)
        timer.schedule(deadline: .now(), repeating: 5)
        timer.setEventHandler { writeBeat() }
        timer.resume()
        bgTimer = timer
        if let s = testFreezeAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { NSLog("Poinky: test: freezing the main thread"); while true { sleep(60) } }
        }
    }

    private static func writeBeat() {
        let s = String(format: "%.3f %.3f\n", mainBeat, Date().timeIntervalSince1970)
        try? FileManager.default.createDirectory(at: Timeline.dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? s.write(to: aliveURL, atomically: true, encoding: .utf8)
    }

    private static func readBeat() -> Beat? {
        guard let s = try? String(contentsOf: aliveURL, encoding: .utf8) else { return nil }
        let p = s.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        return p.count == 2 ? Beat(main: p[0], bg: p[1]) : nil
    }

    /// The last run's newest event ("app.quit" if it quit cleanly) and its time (today's file, else the newest
    /// earlier one).
    private static func lastEvent() -> (String?, Double?) {
        var lastSeen: String?
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: Timeline.dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in files.prefix(2) {
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 4096 ? size - 4096 : 0)
            let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
            var newestT: Double?
            for line in tail.split(separator: "\n").reversed() {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let ev = o["ev"] as? String else { continue }
                if newestT == nil { newestT = (o["t"] as? NSNumber)?.doubleValue }
                // (A clean quit logs a few lines after "app.quit", such as the session's end.)
                if ev == "app.quit" { return ("app.quit", newestT) }
                if ev == "app.start" { return (lastSeen ?? ev, newestT) }
                if lastSeen == nil { lastSeen = ev }
            }
            if let l = lastSeen { return (l, newestT) }
        }
        return (nil, nil)
    }

    /// A crash report for Poinky written after `t` (macOS writes them to DiagnosticReports).
    private static func crashReport(after t: Double) -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return items.contains { u in
            u.lastPathComponent.hasPrefix("Poinky") &&
                ((try? u.resourceValues(forKeys: [.creationDateKey]).creationDate?.timeIntervalSince1970) ?? 0) > t
        }
    }
}
