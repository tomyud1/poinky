import Foundation

/// The words of the first-run moments (FirstRun.swift), with no model: kept apart so a swiftc harness can test them.
enum FirstRunWords {
    /// "Hi Maya, nice to meet you! Whenever you want to ask me something, just hold Control and Option and talk." (~5 s)
    static func greeting(name: String?, keys: String) -> String {
        let hi = name.map { "Hi \($0), nice to meet you!" } ?? "Hi, nice to meet you!"
        return "\(hi) Whenever you want to ask me something, just hold \(keys) and talk."
    }

    static func spoken(_ keys: String) -> String {
        var words: [String] = []
        for part in split(keys) {
            switch part {
            case "⌃": words.append("Control")
            case "⌥": words.append("Option")
            case "⇧": words.append("Shift")
            case "⌘": words.append("Command")
            case "␣": words.append("Space")
            default: words.append(part)
            }
        }
        if words.count <= 1 { return words.first ?? "the keys" }
        return words.dropLast().joined(separator: ", ") + " and " + words.last!
    }

    /// The name the user wrote in "About me" (user.md), if it's clearly a name: "My name is Maya",
    /// "Name: Maya", "Call me Maya", "I'm Maya Cohen". Anything less clear: no name.
    static func userName(in raw: String) -> String? {
        let clean = raw.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: " ", options: .regularExpression)
        let patterns = [
            "(?i:\\bmy name is|\\bmy name's|\\bname\\s*[:\\-–]|\\bcall me|\\bi go by)\\s+(\\p{Lu}[\\p{L}'’\\-]{1,24})",
            "(?:^|[\\n.!])\\s*[-*]?\\s*(?:I'm|I’m|I am)\\s+(\\p{Lu}[\\p{L}'’\\-]{1,24})(?:\\s+\\p{Lu}[\\p{L}'’\\-]+)?\\s*(?:[,.!\\n]|$)",
            "(?i:user'?s name is|the user is called|user is named)\\s+(\\p{Lu}[\\p{L}'’\\-]{1,24})",
        ]
        let notNames: Set<String> = ["a", "an", "the", "not", "student", "teacher", "developer", "engineer", "writer", "here",
                                     "english", "hebrew", "french", "german", "spanish", "american", "british", "israeli",
                                     "poinky", "claude", "user", "me", "working", "studying", "learning", "new", "from", "in"]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) else { continue }
            let ns = clean as NSString
            for m in re.matches(in: clean, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges > 1 {
                let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: "'’-"))
                if name.count >= 2, !notNames.contains(name.lowercased()) { return name }
            }
        }
        return nil
    }

    static func sentences(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        for ch in s {
            cur.append(ch)
            if ".!?".contains(ch) { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = "" }
        }
        let rest = cur.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// "⌃⌥T" → ["⌃", "⌥", "T"] (like KeyCaps.split).
    static func split(_ s: String) -> [String] {
        var out: [String] = [], word = ""
        for ch in s {
            if "⌃⌥⇧⌘".contains(ch) { if !word.isEmpty { out.append(word); word = "" }; out.append(String(ch)) } else { word.append(ch) }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }
}
