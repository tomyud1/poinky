import Foundation

/// Rewrites a sentence the way a person would say it, just before it goes to the voice.
/// Captions keep the original text: only what's heard changes. Read literally, "x^2 + 3x = 0"
/// came out as "x to prove plus three by", "1/2" as "one, two", "~/Desktop/a.py" as "tilde slash
/// desktop slash a dot pie", a URL letter by letter, and markdown or emoji as noise.
/// Pure and fast (well under a millisecond a sentence); tested by tools/tests/spoken-text.
enum SpokenText {
    static func normalize(_ input: String) -> String {
        var s = input
        s = markdown(s)
        s = dropEmoji(s)
        s = links(s)
        s = words(s)
        s = keys(s)
        s = code(s)
        s = units(s)
        s = math(s)
        s = numbers(s)
        return tidy(s)
    }

    // MARK: Markdown leftovers

    private static func markdown(_ s: String) -> String {
        var s = s
        s = sub(s, #"\[([^\]]+)\]\((?:[^)\s]+)\)"#, "$1")                 // [text](url)
        s = sub(s, #"(?m)^\s*#{1,6}\s+"#, "")                                // headings
        s = sub(s, #"(?m)^\s*(?:[-*•▪◦]|\[[ xX]\])\s+"#, "")                // bullets, checkboxes
        s = sub(s, #"(?m)^\s*(\d{1,2})[.)]\s+"#, "$1, ")                      // "1. Open it" → "1, Open it"
        s = sub(s, #"(\*\*|__)(.+?)\1"#, "$2")                                // **bold**
        s = sub(s, #"(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\w*])"#, "$1") // *italic*
        s = sub(s, "```[a-z]*", "")
        s = s.replacingOccurrences(of: "`", with: "")
        return s
    }

    private static func dropEmoji(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.value > 0x2000 }) else { return s }
        var out = ""
        for ch in s {
            let scalars = ch.unicodeScalars
            let emoji = scalars.contains { $0.properties.isEmojiPresentation }
                || (scalars.count > 1 && scalars.contains { $0.value == 0xFE0F || $0.value == 0x200D } && scalars.first!.properties.isEmoji)
                || scalars.first.map { (0x1F000...0x1FAFF).contains($0.value) } == true
            if !emoji { out.append(ch) } else { out.append(" ") }
        }
        return out
    }

    // MARK: Links, paths, files, code

    private static func links(_ s: String) -> String {
        var s = s
        // A web address is said by its site: "https://www.example.com/docs/setup" → "example.com".
        s = sub(s, #"(?i)\b(?:https?://|www\.)(?:www\.)?([a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,})(?::\d+)?(?:[/?#][^\s]*?)?(?=[.,;:!?)\]]?(?:\s|$))"#, "$1")
        // A path is said by its last part: "~/Desktop/notes/a.py" → "a.py".
        s = sub(s, #"(?<![\w/<])(?:(?:~|\.{1,2})/|/(?=[\w.@-]+/))(?:[\w.@-]+/)*([\w@-]+(?:\.\w+)?)/?(?![\w/])"#, "$1")
        s = sub(s, #"(?<=^|[\s(\"“])/([a-z][\w-]*)\b"#, "slash $1")          // a slash command: "/review"
        s = sub(s, #"(?<![\w/])(?:[A-Za-z_][\w.-]*/)+([\w-]+\.[A-Za-z]\w*)\b"#, "$1")
        s = sub(s, #"(?i)\band/or\b"#, "and or")
        return s
    }

    private static let extensions: [String: String] = [
        "py": "P Y", "js": "J S", "ts": "T S", "tsx": "T S X", "jsx": "J S X", "md": "M D", "json": "JSON",
        "swift": "swift", "sh": "S H", "txt": "text", "html": "H T M L", "css": "C S S", "yml": "YAML",
        "yaml": "YAML", "toml": "toml", "rs": "R S", "go": "go", "c": "C", "h": "H", "cpp": "C P P",
        "java": "java", "rb": "R B", "csv": "C S V", "pdf": "P D F", "png": "P N G", "jpg": "J peg",
        "jpeg": "J peg", "gif": "gif", "svg": "S V G", "docx": "doc X", "xlsx": "X L S X", "pptx": "P P T X",
        "key": "key", "pages": "pages", "zip": "zip", "dmg": "D M G", "plist": "P list", "log": "log",
        "env": "env", "lock": "lock", "ipynb": "notebook", "tex": "tech", "mp3": "M P 3", "mp4": "M P 4",
        "mov": "mov", "wav": "wave",
    ]

    private static func code(_ s: String) -> String {
        var s = s
        for (k, v) in [("Node.js", "Node JS"), ("Next.js", "Next JS"), ("Vue.js", "Vue JS"), ("C++", "C plus plus"),
                       ("C#", "C sharp"), ("F#", "F sharp"), (".NET", "dot net")] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        s = sub(s, #"(?<=^|\s)\.(env|gitignore|zshrc|bashrc|ssh|config)\b"#, "dot $1")
        // file names: "README.md" → "read me dot M D", "my_notes.txt" → "my notes dot text"
        s = replace(s, #"(?<![\w.])(\.?[\w-]+)\.([A-Za-z][A-Za-z0-9]{0,4})\b(?!\.\w)"#) { g in
            guard let ext = extensions[g[2].lowercased()] else { return g[0] }
            var name = g[1]
            if name.hasPrefix(".") { name = "dot " + name.dropFirst() }
            if name.uppercased() == "README" { name = "read me" }
            return name + " dot " + ext
        }
        s = sub(s, #"\b(\w+)\(\)"#, "$1")                                    // foo() → foo
        s = replace(s, #"\b[A-Za-z][a-z0-9]*(?:_[A-Za-z0-9]+)+\b"#) { g in   // snake_case → words
            g[0].replacingOccurrences(of: "_", with: " ")
        }
        s = replace(s, #"\b[a-z]{2,}(?:[A-Z][a-z]+)+\b"#) { g in              // camelCase → words
            sub(g[0], "([a-z])([A-Z])", "$1 $2").lowercased()
        }
        s = sub(s, #"(?<=\s|^)--([a-zA-Z][\w-]*)"#, "dash dash $1")           // --force
        s = sub(s, #"(?<=\s|^)-([a-zA-Z])\b"#, "dash $1")                     // -D
        s = sub(s, #"\bnpm\b"#, "N P M")
        s = sub(s, #"(?<=\s|^)(?:->|=>|→|⟶)(?=\s)"#, "to")
        s = sub(s, #"(?:->|→)"#, " to ")
        return s
    }

    // MARK: Keys

    private static func keys(_ s: String) -> String {
        var s = s
        for (k, v) in [("⌘", "Command "), ("⌥", "Option "), ("⌃", "Control "), ("⇧", "Shift "), ("↩", "Return "),
                       ("⏎", "Return "), ("⌫", "Delete "), ("⎋", "Escape "), ("⇥", "Tab ")] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        s = sub(s, #"\bCmd\b"#, "Command")
        s = sub(s, #"\bCtrl\b"#, "Control")
        s = sub(s, #"\bOpt\b(?=\s*[+-])"#, "Option")
        // "Command+Shift+4" → "Command Shift 4"
        for _ in 0..<3 {
            s = sub(s, #"\b(Command|Control|Shift|Option|Alt|Fn|Tab|Return|Enter|Escape|Esc|Space|Delete|Win|Super)\s*[+-]\s*(?=\w)"#, "$1 ")
        }
        return s
    }

    // MARK: Math

    private static let greek: [Character: String] = [
        "π": "pi", "∞": "infinity", "α": "alpha", "β": "beta", "γ": "gamma", "δ": "delta", "Δ": "delta",
        "ε": "epsilon", "θ": "theta", "λ": "lambda", "μ": "mu", "σ": "sigma", "φ": "phi", "ω": "omega",
        "Ω": "omega", "ρ": "rho", "τ": "tau", "η": "eta",
    ]

    private static func math(_ s: String) -> String {
        var s = s
        for (k, v) in [("≥", " greater than or equal to "), ("≤", " less than or equal to "), ("≠", " is not equal to "),
                       ("≈", " is about "), ("±", " plus or minus "), ("×", " times "), ("÷", " divided by "),
                       ("∑", " the sum of "), ("∫", " the integral of "), ("∂", " partial "), ("∈", " in "),
                       ("∀", " for all "), ("∃", " there is "), ("⇒", " implies "), ("∝", " is proportional to "),
                       ("−", "-"), ("½", " one half"), ("¼", " one quarter"), ("¾", " three quarters"),
                       ("⅓", " one third"), ("⅔", " two thirds"), (">=", " greater than or equal to "),
                       ("<=", " less than or equal to "), ("!=", " is not equal to "), ("==", " = ")] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        s = String(s.flatMap { ch -> [Character] in
            if let w = greek[ch] { return Array(" \(w) ") }
            return [ch]
        })
        // powers: x^2, x², x^n, x^(n+1)
        s = sub(s, #"\s*(?:\^2|²)(?!\d)"#, " squared")
        s = sub(s, #"\s*(?:\^3|³)(?!\d)"#, " cubed")
        s = sub(s, #"\^\(([^)]+)\)"#, " to the power of $1")
        s = sub(s, #"\^(-?\w+)"#, " to the power of $1")
        s = sub(s, "ⁿ", " to the n")
        // roots: √2, √(x+1), ∛8
        s = sub(s, #"√\s*\(([^)]+)\)"#, " the square root of $1")
        s = sub(s, #"√\s*"#, " the square root of ")
        s = sub(s, #"∛\s*"#, " the cube root of ")
        // operators between numbers or single letters
        let left = #"(?<=(?:^|[\s(])(?:\d{1,12}(?:\.\d{1,6})?|[A-Za-z]|\d{1,6}[a-z])|\)|squared|cubed)"#
        let right = #"(?=\s*(?:\d|[A-Za-z](?:\b|\d|\()|\(|the square|minus|-\d))"#
        s = sub(s, left + #"\s*=\s*"# + right, " equals ")
        s = sub(s, left + #"\s*\+\s*"# + right, " plus ")
        s = sub(s, left + #"\s+-\s+"# + right, " minus ")
        s = sub(s, left + #"\s*\*\s*"# + right, " times ")
        s = sub(s, left + #"\s+>\s+"# + right, " is greater than ")
        s = sub(s, left + #"\s+<\s+"# + right, " is less than ")
        s = sub(s, #"(?<=\s)=(?=\s)"#, "equals")
        s = sub(s, #"(?<=^|[\s(=])-(?=\d)"#, "minus ")
        // fractions: "1/2" → "one half", "x/2" → "x over 2"
        s = replace(s, #"(?<![\w/.,])(\d{1,3})/(\d{1,3})(?![\w/]|\.\d|,\d)"#) { g in fraction(g[1], g[2]) ?? g[0] }
        s = sub(s, #"(?<![\w/])([A-Za-z]|\d+|\))\s*/\s*([A-Za-z]|\d+)(?![\w/])"#, "$1 over $2")
        s = sub(s, #"(\d)°(?![CF]\b)"#, "$1 degrees")
        return s
    }

    private static let ordinals = ["", "", "half", "third", "quarter", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
                                   "eleventh", "twelfth"]
    private static let small = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                "eleven", "twelve"]

    static func fraction(_ a: String, _ b: String) -> String? {
        guard let n = Int(a), let d = Int(b), d > 0 else { return nil }
        if a == "24" && b == "7" { return "twenty-four seven" }
        if n == d && n > 12 { return "\(n) \(n)" }        // 50/50
        guard n <= 12, d >= 2, d <= 12 else { return "\(a) over \(b)" }
        var word = ordinals[d]
        if n != 1 { word = d == 2 ? "halves" : word + "s" }
        return (n == 1 ? (d == 2 ? "one" : "one") : small[n]) + " " + word
    }

    private static func units(_ s: String) -> String {
        var s = s
        s = sub(s, #"(?<=\d)\s*(?:km/h|kph)\b"#, " kilometers per hour")
        s = sub(s, #"(?<=\d)\s*m/s²"#, " meters per second squared")
        s = sub(s, #"(?<=\d)\s*m/s\b"#, " meters per second")
        s = sub(s, #"(?<=\d)\s*mph\b"#, " miles per hour")
        return s
    }

    // MARK: Numbers, dates

    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August",
                                 "September", "October", "November", "December"]

    private static func numbers(_ s: String) -> String {
        var s = s
        // 2026-11-15 → November 15, 2026
        s = replace(s, #"\b(\d{4})-(\d{2})-(\d{2})\b"#) { g in
            guard let m = Int(g[2]), let d = Int(g[3]), (1...12).contains(m), (1...31).contains(d) else { return g[0] }
            return "\(months[m - 1]) \(d), \(g[1])"
        }
        // 2.1.280 → 2 point 1 point 280 (versions)
        s = replace(s, #"\b[vV]?(\d+(?:\.\d+){2,})\b"#) { g in g[1].replacingOccurrences(of: ".", with: " point ") }
        // 10:05 → 10 oh 5; 9:00 → 9 o'clock... keep "10:30" (the voice says it well)
        s = sub(s, #"\b(\d{1,2}):00\b(?!:)"#, "$1")
        s = sub(s, #"\b(\d{1,2}):0(\d)\b(?!:)"#, "$1 oh $2")
        s = sub(s, #"(?<=\d)\s*ms\b"#, " milliseconds")
        s = sub(s, #"(?<=\d)\s*(?:fps)\b"#, " frames per second")
        s = sub(s, #"(?<=\d)\s*(?:GHz)\b"#, " gigahertz")
        s = sub(s, #"#(?=\d)"#, "number ")
        s = sub(s, #"(?<=^|\s)~(?=\d)"#, "about ")
        return s
    }

    // MARK: Abbreviations and leftovers

    private static func words(_ s: String) -> String {
        var s = s
        s = sub(s, #"(?i)\be\.g\.,?"#, "for example,")
        s = sub(s, #"(?i)\bi\.e\.,?"#, "that is,")
        s = sub(s, #"\b(?:a\.k\.a\.|aka)(?=\s)"#, "also known as")
        s = sub(s, #"(?i)\bapprox\.\s*"#, "about ")
        s = sub(s, #"(?i)\bw/o\b"#, "without")
        s = sub(s, #"(?i)\bw/(?=\s)"#, "with")
        s = sub(s, #"\bbtw\b"#, "by the way")
        s = sub(s, #"\s&\s"#, " and ")
        return s
    }

    private static func tidy(_ s: String) -> String {
        var s = s
        s = s.replacingOccurrences(of: "_", with: " ")
        s = sub(s, #"[{}\[\]|]"#, " ")
        s = sub(s, #"\s+"#, " ")
        s = sub(s, #"\s+([,.;:!?])"#, "$1")
        s = sub(s, #"([,;:])(?:\s*[,;:])+"#, "$1")
        s = sub(s, #"\(\s*\)"#, "")
        s = sub(s, #"^[\s,;:]+"#, "")
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Regex helpers

    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    private static func regex(_ p: String) -> NSRegularExpression {
        lock.lock(); defer { lock.unlock() }
        if let r = cache[p] { return r }
        let r = try! NSRegularExpression(pattern: p)
        cache[p] = r
        return r
    }

    static func sub(_ s: String, _ pattern: String, _ template: String) -> String {
        regex(pattern).stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    /// Replaces each match with what `f` returns; `f` gets the groups (0 = whole match, missing = "").
    static func replace(_ s: String, _ pattern: String, _ f: ([String]) -> String) -> String {
        let r = regex(pattern)
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in r.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let g = m.range(at: i)
                return g.location == NSNotFound ? "" : ns.substring(with: g)
            }
            out += f(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}

/// Where a streaming reply can be cut into sentences for the voice. The first piece may end at a
/// comma (once it has a few words), so speech starts sooner. A period doesn't end a sentence
/// after "e.g.", "Dr.", "vs." or a list number, or when the next word starts in lowercase
/// ("the U.S. by hand"): those were spoken as separate fragments, with a pause in the middle.
enum SentenceSplit {
    private static let enders: Set<Character> = [".", "!", "?", "…", "\n"]
    private static let softEnders: Set<Character> = [",", ";", ":", "—"]
    private static let closers = "\"')]”’"
    /// Never the end of a sentence, whatever follows.
    private static let neverLast: Set<String> = ["e.g.", "i.e.", "vs.", "mr.", "mrs.", "ms.", "dr.", "prof.", "st.",
                                                 "approx.", "fig.", "cf.", "jr.", "sr.", "mt.", "ft.", "inc."]

    /// Splits `chars` from `start`. `first`: nothing of this reply was spoken yet. `closed`: the
    /// text is complete, so its last words are a sentence too. Returns the pieces and where the
    /// unsplit rest begins.
    static func split(_ chars: [Character], from start: Int, first: Bool, closed: Bool) -> (pieces: [String], next: Int) {
        var out: [String] = []
        var start = start
        var i = start
        while i < chars.count {
            let isFirst = first && out.isEmpty
            if isFirst, softEnders.contains(chars[i]),
               String(chars[start...i]).split(separator: " ").count >= 3,
               i + 1 < chars.count, chars[i + 1].isWhitespace {
                out.append(String(chars[start...i]))
                start = i + 1
                i += 1
                continue
            }
            if enders.contains(chars[i]) {
                var j = i + 1
                while j < chars.count, closers.contains(chars[j]) { j += 1 }
                // A sentence ends at punctuation followed by a space (or the end, once the block closed).
                if j < chars.count, chars[j].isWhitespace {
                    if chars[i] == ".", !endsSentence(chars, start: start, dot: i, after: j) { i += 1; continue }
                    out.append(String(chars[start..<j]))
                    start = j
                    i = j
                    continue
                }
            }
            i += 1
        }
        if closed {
            if start < chars.count { out.append(String(chars[start...])) }
            start = chars.count
        }
        return (out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }, start)
    }

    private static func endsSentence(_ chars: [Character], start: Int, dot: Int, after: Int) -> Bool {
        // the word the period belongs to
        var w = dot
        while w > start, !chars[w - 1].isWhitespace { w -= 1 }
        let word = String(chars[w...dot]).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(\"'“"))
        if neverLast.contains(word) { return false }
        // "1." at the start of a list item
        let sofar = String(chars[start..<dot]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !sofar.isEmpty, sofar.count <= 2, sofar.allSatisfy(\.isNumber) { return false }
        // the next word: a sentence starts with a capital, a digit or a quote, not a lowercase letter
        var k = after
        while k < chars.count, chars[k] == " " { k += 1 }
        if k >= chars.count { return false }      // the next word hasn't arrived yet: wait for it
        if chars[k] != "\n", chars[k].isLowercase { return false }   // "the U.S. by hand", "pears, etc. then"
        return true
    }
}
