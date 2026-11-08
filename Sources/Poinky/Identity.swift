import Foundation

/// Who Poinky is and who the user is, in two short files the user can edit (Settings → Memory).
/// Both are read at the start of every session (and when a long session switches to a fresh talker),
/// next to `memory.md` (the facts Claude keeps with <remember>) and the last two daily notes.
/// Inspired by OpenClaw's SOUL.md / USER.md / MEMORY.md and memory/YYYY-MM-DD.md.
/// Text inside `<!-- … -->` is a note for the person editing and never reaches Claude.
enum Identity {
    static var identityURL: URL { AppConfig.dir.appendingPathComponent("identity.md") }
    static var userURL: URL { AppConfig.dir.appendingPathComponent("user.md") }
    static let identityBudget = 1500   // characters sent to Claude (the rest is cut, and the prompt says so)
    static let userBudget = 2000

    static let defaultIdentity = """
    # Who Poinky is
    <!-- Edit this to change Poinky's personality. It's read at the start of every session. Keep it short. -->

    - You're Poinky. You live in the notch of the user's Mac, see what's on their screen, and send helpers (Claude Code agents) for longer work.
    - Warm, quick and direct, like a sharp friend sitting next to them. No filler, no lecturing.
    - Honest: say plainly when you don't know or can't do something, and what you'd do instead.
    - Protective of their attention: brief when they're busy, more playful when they're relaxed.

    """

    static let defaultUser = """
    # About me
    <!-- Anything Poinky should always know: your role, your main projects and where they live,
         how you like answers. Poinky reads this at the start of every session. -->

    """

    /// The part of each file Poinky keeps up to date itself (the user's own text above it is never touched).
    static let learnedHeader = "## Learned over time"
    static let learnedNote = "<!-- Poinky adds and removes lines here as it learns. Edit or delete them freely. -->"
    static let maxLearned = [identityURL.lastPathComponent: 12, userURL.lastPathComponent: 25]

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 && $0 != "user" })
    }

    /// The file split into what the user wrote and the learned lines ("- fact (date)").
    private static func split(_ url: URL) -> (own: String, learned: [String]) {
        ensureFiles()
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let r = text.range(of: "\n" + learnedHeader) else { return (text, []) }
        let own = String(text[..<r.lowerBound])
        let learned = text[r.upperBound...].split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") }
        return (own, learned)
    }

    private static func write(_ url: URL, own: String, learned: [String]) {
        var text = own.trimmingCharacters(in: .newlines) + "\n"
        if !learned.isEmpty { text += "\n" + learnedHeader + "\n" + learnedNote + "\n" + learned.joined(separator: "\n") + "\n" }
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Adds a line to a file's learned part (replacing one that says nearly the same thing).
    /// Returns false if it was empty or already known.
    @discardableResult
    static func learn(_ fact: String, into url: URL) -> Bool {
        let clean = fact.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard clean.count >= 3 else { return false }
        var (own, learned) = split(url)
        let w = words(clean)
        // Already in what the user wrote: nothing to add.
        if !w.isEmpty, Double(words(own).intersection(w).count) / Double(w.count) >= 0.9 { return false }
        learned.removeAll { line in
            let o = words(line)
            return !o.isEmpty && !w.isEmpty && Double(o.intersection(w).count) / Double(min(o.count, w.count)) >= 0.8
        }
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        learned.append("- \(clean) (\(date))")
        let cap = maxLearned[url.lastPathComponent] ?? 20
        if learned.count > cap {
            Memory.archive(Array(learned.prefix(learned.count - cap)))   // kept and searchable, not deleted
            learned.removeFirst(learned.count - cap)
        }
        write(url, own: own, learned: learned)
        Timeline.log("learned", ["file": url.lastPathComponent])
        return true
    }

    /// Removes learned lines that match `what` (the user's own text is never removed).
    static func unlearn(_ what: String, from url: URL) {
        let w = words(what)
        guard !w.isEmpty else { return }
        let (own, learned) = split(url)
        let kept = learned.filter { Double(words($0).intersection(w).count) / Double(w.count) < 0.6 }
        if kept.count != learned.count { write(url, own: own, learned: kept) }
    }

    /// Creates the files with their defaults the first time.
    static func ensureFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(at: AppConfig.dir, withIntermediateDirectories: true)
        for (url, text) in [(identityURL, defaultIdentity), (userURL, defaultUser)] where !fm.fileExists(atPath: url.path) {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// A file's text for Claude: without the editing notes and the title, within `budget` characters.
    static func content(_ url: URL, budget: Int) -> String {
        guard var s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        s = s.replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.hasPrefix("# ") }
        s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > budget { s = String(s.prefix(budget)) + "\n(…cut: the file is longer than Poinky reads.)" }
        return s
    }

    /// The part of the system prompt with Poinky's identity and the user's own profile.
    /// (Identity and profile are the user's words, so they always count, with memory on or off.)
    static func promptSection() -> String {
        ensureFiles()
        var s = ""
        let me = content(identityURL, budget: identityBudget)
        if !me.isEmpty { s += "\n\n## Who you are (written by the user; it wins over the style notes above if they differ)\n" + me + "\n" }
        let you = content(userURL, budget: userBudget)
        if !you.isEmpty { s += "\n\n## About the user (written by them; trust it over remembered facts)\n" + you + "\n" }
        return s
    }
}

/// A few lines per session about what happened, one file per day (`notes/YYYY-MM-DD.md`, 0600).
/// Today's and yesterday's are read at the start of a session; older ones are found by <recall>.
enum DailyNotes {
    static var dir: URL {
        if let d = ProcessInfo.processInfo.environment["POINKY_NOTES_DIR"] { return URL(fileURLWithPath: d) }
        return AppConfig.dir.appendingPathComponent("notes")
    }
    static let budgetPerDay = 1200

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func url(for date: Date) -> URL { dir.appendingPathComponent(day(date) + ".md") }

    /// Adds a session's note under its time.
    static func append(_ note: String, at date: Date = Date()) {
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = url(for: date)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? "# \(day(date))\n"
        text += "\n## \(f.string(from: date))\n\(clean)\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// One day's notes without the title, the newest part kept if it's too long.
    static func text(for date: Date) -> String {
        guard let s = try? String(contentsOf: url(for: date), encoding: .utf8) else { return "" }
        let body = s.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("# ") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.count > budgetPerDay ? "…" + String(body.suffix(budgetPerDay)) : body
    }

    /// For the system prompt: yesterday's and today's notes.
    static func promptSection(now: Date = Date()) -> String {
        let today = text(for: now), yesterday = text(for: now.addingTimeInterval(-86400))
        guard !today.isEmpty || !yesterday.isEmpty else { return "" }
        var s = "\n\n## Recent sessions (your own notes; older days can be found with <recall>)\n"
        if !yesterday.isEmpty { s += "### Yesterday\n\(yesterday)\n" }
        if !today.isEmpty { s += "### Earlier today\n\(today)\n" }
        return s
    }

    /// Every day's notes (newest first, at most `limit` days), for <recall>.
    static func all(limit: Int = 60) -> [(date: Date, text: String)] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(limit)
        return files.compactMap { u in
            guard let d = f.date(from: u.deletingPathExtension().lastPathComponent),
                  let t = try? String(contentsOf: u, encoding: .utf8) else { return nil }
            return (d.addingTimeInterval(12 * 3600), t)
        }
    }

    static let notePrompt = """
    You write Poinky's private notes. Poinky is a voice assistant on the user's Mac. You get one session's exchanges \
    (what the user said, what Poinky answered, what else happened). Write 1–4 short lines starting with "- ": what the \
    user was doing or wanted, decisions, anything unfinished, and anything to remember next time. Plain facts, no \
    greetings, no screenshot details, nothing about the note itself. If nothing worth keeping happened, write "- Small talk." \
    Then, only if the user clearly said something lasting about themselves (their role, a project and where it lives, \
    how they like answers), add at most 2 lines starting with "ABOUT: " and one short fact each. Never guess, and never \
    from what Poinky said or what was on the screen.
    """

    /// The exchanges themselves, shortened: used when no model is available (or it failed).
    static func plainNote(_ exchanges: [(user: String, assistant: String)]) -> String {
        exchanges.suffix(4).map { "- Asked \"\(Recall.clip($0.user, 90))\"." }.joined(separator: "\n")
    }
}
