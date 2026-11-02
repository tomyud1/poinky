import Foundation

/// What Poinky knows about you, kept between sessions so it can feel like a friend who
/// remembers: your name, what you're working on, what interests you, how you like answers.
///
/// It's a plain list in ~/Library/Application Support/Poinky/memory.md, only on this Mac.
/// Claude adds to it with <remember> and removes with <forget>; you can read, edit or clear it
/// in Settings → Memory.
enum Memory {
    static var url: URL { AppConfig.dir.appendingPathComponent("memory.md") }
    private static let maxFacts = 80

    /// The remembered facts, one per line ("- fact (date)").
    static func facts() -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("- ") }
    }

    static func text() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    static func save(text: String) {
        try? FileManager.default.createDirectory(at: AppConfig.dir, withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func write(_ facts: [String]) {
        save(text: "# What Poinky remembers about you\n\n" + facts.joined(separator: "\n") + "\n")
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 })
    }

    /// Adds a fact (or replaces one that says nearly the same thing).
    static func remember(_ fact: String) {
        let clean = fact.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard clean.count >= 3 else { return }
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        var list = facts()
        let w = words(clean)
        // The same thing again (or an update of it): replace the old line.
        list.removeAll { line in
            let o = words(line)
            guard !o.isEmpty, !w.isEmpty else { return false }
            return Double(o.intersection(w).count) / Double(min(o.count, w.count)) >= 0.8
        }
        list.append("- \(clean) (\(date))")
        if list.count > maxFacts { list.removeFirst(list.count - maxFacts) }
        write(list)
    }

    /// Removes facts that match what the user asked to forget.
    static func forget(_ what: String) {
        let w = words(what)
        guard !w.isEmpty else { return }
        let list = facts().filter { line in
            let o = words(line)
            return Double(o.intersection(w).count) / Double(w.count) < 0.6
        }
        write(list)
    }

    static func clear() { write([]) }

    /// The part of the system prompt that makes the conversation personal.
    static func promptSection(enabled: Bool) -> String {
        guard enabled else {
            return "\n\n## Memory\nMemory is turned off: don't use <remember> or <forget>."
        }
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        var s = "\n\n## What you know about the user (from earlier conversations)\n"
        if !first.isEmpty { s += "- Their Mac account name is \(NSFullUserName()); call them \(first) unless they say otherwise.\n" }
        let list = facts()
        s += list.isEmpty ? "- Nothing else yet: this may be one of your first conversations.\n" : list.joined(separator: "\n") + "\n"
        return s
    }
}
