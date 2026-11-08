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
