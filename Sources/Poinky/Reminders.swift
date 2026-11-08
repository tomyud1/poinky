import Foundation

/// Things Poinky says (or starts) by itself at a time: "remind me to email Dana tomorrow at 9",
/// "every weekday at 8, remind me to review my flashcards", "every morning at 9 have a helper
/// summarize the news on my thesis topic". The talker writes
/// `<remind at="2026-11-09 09:00" every="weekdays">Review your flashcards</remind>`
/// (add `agent="Title"` to start a helper with that task instead of just saying it).
/// Kept in `reminders.json` (0600) so they survive restarts; one missed while the Mac was off or
/// asleep is said when it's back, with "earlier".
struct Reminder: Codable, Equatable {
    var id: String = UUID().uuidString
    var text: String
    var at: Date
    var every: Repeat?
    var agentTitle: String?     // set: start a helper with `text` as its task
    var agentDir: String?

    enum Repeat: String, Codable { case daily, weekdays, weekly, hourly }

    /// The next time after `date` (for repeating ones).
    func next(after date: Date, calendar cal: Calendar = .current) -> Date? {
        guard let every else { return nil }
        var t = at
        var guardCount = 0
        while t <= date, guardCount < 2000 {
            guardCount += 1
            switch every {
            case .hourly: t = cal.date(byAdding: .hour, value: 1, to: t)!
            case .daily: t = cal.date(byAdding: .day, value: 1, to: t)!
            case .weekly: t = cal.date(byAdding: .day, value: 7, to: t)!
            case .weekdays:
                t = cal.date(byAdding: .day, value: 1, to: t)!
                while cal.isDateInWeekend(t) { t = cal.date(byAdding: .day, value: 1, to: t)! }
            }
        }
        return t
    }
}

enum Reminders {
    static var url: URL {
        if let d = ProcessInfo.processInfo.environment["POINKY_REMINDERS_FILE"] { return URL(fileURLWithPath: d) }
        return AppConfig.dir.appendingPathComponent("reminders.json")
    }
    static let maxCount = 50

    static func all() -> [Reminder] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return ((try? dec.decode([Reminder].self, from: data)) ?? []).sorted { $0.at < $1.at }
    }

    static func save(_ list: [Reminder]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(Array(list.sorted { $0.at < $1.at }.prefix(maxCount))) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// "2026-11-09 09:00" (or "…T09:00", with seconds, or ISO 8601 with a zone) in the user's time zone.
    static func parseTime(_ s: String, zone: TimeZone = .current) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let d = ISO8601DateFormatter().date(from: t) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    /// Adds one (a near-identical one at the same time replaces it). Nil if the time can't be read.
    @discardableResult
    static func add(text: String, at: String, every: String?, agentTitle: String? = nil, agentDir: String? = nil, now: Date = Date()) -> Reminder? {
        let clean = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, var when = parseTime(at) else { return nil }
        let rep = every.flatMap { Reminder.Repeat(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces)) }
        var r = Reminder(text: clean, at: when, every: rep, agentTitle: agentTitle, agentDir: agentDir)
        // A repeating one whose first time already passed today starts at the next one.
        if when <= now, rep != nil, let n = r.next(after: now) { when = n; r.at = n }
        guard when > now.addingTimeInterval(-60) else { return nil }   // in the past: refuse rather than fire at once
        var list = all().filter { !($0.text.lowercased() == clean.lowercased() && abs($0.at.timeIntervalSince(when)) < 60) }
        list.append(r)
        save(list)
        return r
    }

    /// Removes the ones whose text matches `what` (most words in common); returns how many.
    @discardableResult
    static func cancel(_ what: String) -> Int {
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
        }
        let w = words(what)
        let list = all()
        let all = w.isEmpty || ["all", "everything"].contains(what.lowercased().trimmingCharacters(in: .whitespaces))
        let kept = all ? [] : list.filter { r in
            let o = words(r.text)
            return o.isEmpty || Double(o.intersection(w).count) / Double(min(o.count, w.count)) < 0.5
        }
        save(kept)
        return list.count - kept.count
    }

    /// The ones due by `now`: removed (or moved to their next time) and returned, oldest first.
    static func takeDue(now: Date = Date()) -> [Reminder] {
        var list = all()
        let due = list.filter { $0.at <= now }
        guard !due.isEmpty else { return [] }
        list.removeAll { $0.at <= now }
        for var r in due where r.every != nil {
            if let n = r.next(after: now) { r.at = n; list.append(r) }
        }
        save(list)
        return due
    }

    /// For the talker: what's scheduled, in the user's words and time.
    static func summary(now: Date = Date(), limit: Int = 12) -> String {
        let list = all()
        guard !list.isEmpty else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d MMM, h:mm a"
        return "Scheduled (you'll say or start these by yourself at the time):\n" + list.prefix(limit).map { r in
            var s = "- \(f.string(from: r.at)): \(r.agentTitle.map { "start a helper \"\($0)\": " } ?? "")\(r.text)"
            if let e = r.every { s += " (every \([Reminder.Repeat.daily: "day", .weekdays: "weekday", .weekly: "week", .hourly: "hour"][e]!))" }
            return s
        }.joined(separator: "\n")
    }

    /// What Poinky says when one comes due. `late`: it was due a while ago (the Mac was asleep or off).
    static func spoken(_ r: Reminder, late: Bool) -> String {
        if r.agentTitle != nil { return late ? "Starting the helper you scheduled earlier: \(r.text)" : "Starting what you scheduled: \(r.text)" }
        let t = r.text.hasSuffix(".") || r.text.hasSuffix("!") || r.text.hasSuffix("?") ? r.text : r.text + "."
        return late ? "Earlier reminder: \(t)" : "Reminder: \(t)"
    }
}
