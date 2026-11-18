import Foundation

/// What may go into the user's "About me" (user.md): only lasting things the user said about themselves.
/// In the tester's sessions every session added trivia there: "planning Lake Tahoe hikes" (from viewing a page),
/// "Uses TextEdit", "Tomer is the user's name, as Poinky addressed them", "Dana is a student" (a name on a
/// homework sheet). So both writers must show it came from the user's own words:
/// - the session-note writer's `ABOUT: fact | "their exact words"` lines (`aboutLines`) keep a fact only when
///   the quote is in what the user said (not in what Poinky said, and not from the screen);
/// - the talker's `<remember about="user">` (`fromUser`) keeps a fact only when it shares a distinctive word
///   with what the user just said.
/// Foundation only, so tools/eval-talker/about-me.py builds it with its own small harness.
enum UserFacts {
    /// The note writer's reply → the facts to learn. `userLines`: what the user said this session (plus any
    /// "The user said: «…»" lines from the running summary).
    static func aboutLines(_ reply: String, userLines: [String]) -> [String] {
        let said = userLines.map(words)
        var out: [String] = []
        for raw in reply.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("ABOUT:") else { continue }
            let body = line.dropFirst(6)
            guard let bar = body.range(of: "|") else { continue }   // no quote: not from the user's words
            let fact = body[..<bar.lowerBound].trimmingCharacters(in: .whitespaces)
            let quote = words(String(body[bar.upperBound...]))
            guard fact.count >= 3, quote.count >= 2,
                  said.contains(where: { s in Double(quote.filter(s.contains).count) >= Double(quote.count) * 0.8 }) else { continue }
            out.append(fact)
            if out.count == 2 { break }
        }
        return out
    }

    /// The user's own words in the running summary ("The user said: «my exam is on Thursday»").
    static func pinned(in summary: String) -> [String] {
        let r = try! NSRegularExpression(pattern: "«([^»]+)»")
        let ns = summary as NSString
        return r.matches(in: summary, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    /// A `<remember about="user">` fact the talker wrote: true when it shares a distinctive word with what the
    /// user said in the last few questions ("I'm a nursing student" → "Studies nursing").
    static func fromUser(_ fact: String, said: [String]) -> Bool {
        let f = Set(words(fact).filter { $0.count >= 4 && !common.contains($0) })
        let s = Set(said.flatMap(words))
        return !f.isDisjoint(with: s)
    }

    private static let common: Set<String> = [
        "user", "users", "their", "they", "them", "this", "that", "with", "from", "about", "likes", "like", "wants",
        "want", "uses", "used", "using", "have", "has", "always", "prefers", "prefer", "should",
        "would", "when", "what", "works", "work", "working", "name", "called", "poinky", "keep", "mind", "remember",
        "things",
    ]

    /// Says nearly the same thing (most of the shorter one's words are in the other): already known.
    static func similar(_ a: String, _ b: String) -> Bool {
        let x = Set(words(a).filter { $0.count > 2 }), y = Set(words(b).filter { $0.count > 2 })
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) >= 0.8
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}
