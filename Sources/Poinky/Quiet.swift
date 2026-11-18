import Foundation

// Quiet mode and answers you can read: the small rules, with no model and no UI, so they can be tested alone
// (`swiftc Sources/Poinky/Quiet.swift tools/quiet-test/main.swift`).

/// "Be quiet" / "you can talk again", said or typed: switches quiet mode right away, without asking the talker
/// (its reply would be heard before its `<set>` took effect). Only short, clear requests count; anything else
/// ("why is it so quiet?", "mute the video") goes to the talker, which can still write `<set>{"quiet":…}</set>`.
enum QuietPhrase {
    /// true: turn quiet mode on; false: off; nil: not a request to switch it.
    static func intent(_ said: String) -> Bool? {
        var t = said.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"[.!?,;:"“”]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // Polite words and the name around the request ("Poinky, please be quiet now").
        for f in ["hey poinky ", "poinky ", "ok ", "okay ", "please ", "can you ", "could you ", "would you ", "now ", "so "] where t.hasPrefix(f) {
            t.removeFirst(f.count)
        }
        for f in [" please", " poinky", " now", " for now", " for a while", " for a bit", " thanks", " thank you", " ok", " okay"] where t.hasSuffix(f) {
            t.removeLast(f.count)
        }
        for f in ["please ", "now "] where t.hasPrefix(f) { t.removeFirst(f.count) }   // "ok please …", "can you please …"
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.split(separator: " ").count <= 9 else { return nil }
        if off.contains(where: { t.range(of: "^(?:\($0))$", options: .regularExpression) != nil }) { return false }
        if on.contains(where: { t.range(of: "^(?:\($0))$", options: .regularExpression) != nil }) { return true }
        return nil
    }

    private static let on = [
        "(?:be|go|stay|keep) (?:quiet|silent)", "quiet(?: mode)?(?: on)?", "silent mode(?: on)?", "(?:turn|switch) (?:on )?quiet mode(?: on)?",
        "(?:turn|switch) on (?:quiet|silent) mode", "(?:switch|go|change) (?:in)?to (?:quiet|silent) mode", "(?:shh+|shush|hush)", "mute(?: yourself| your voice)?",
        "(?:stop|quit) (?:talking|speaking) (?:out loud|aloud)", "(?:don't|do not) (?:talk|speak) (?:out loud|aloud)",
        "(?:turn|switch) off (?:your|the) voice", "(?:turn|switch) (?:your|the) voice off", "no (?:more )?voice",
        "(?:just )?(?:write|type|text)(?: it)? (?:instead(?: of talking)?|only)", "text only", "only (?:write|text)",
        "(?:answer|reply) (?:in|with) (?:text|writing)(?: only)?", "(?:i'm|i am) in a (?:library|lecture|meeting|call|class)(?: be quiet)?",
        // Hebrew
        "שקט", "(?:תהיה|תהי|היה) בשקט", "מצב שקט", "בלי קול", "תפסיק לדבר(?: בקול)?", "אל תדבר(?: בקול)?", "רק טקסט", "תכתוב במקום לדבר",
    ]
    private static let off = [
        "(?:you can|you may|ok to|okay to) (?:talk|speak)(?: again| out loud| aloud)*", "(?:talk|speak) (?:to me )?(?:again|out loud|aloud|normally)(?: again)?",
        "unmute(?: yourself)?", "quiet mode off", "(?:turn|switch) off quiet mode", "(?:turn|switch) quiet mode off", "(?:stop|end|exit|leave) quiet mode",
        "(?:turn|switch) (?:your|the) voice (?:back )?on", "(?:turn|switch) on (?:your|the) voice", "(?:use|with) (?:your|the) voice(?: again)?",
        "(?:you can )?(?:stop being|no need to be|don't be) quiet", "(?:i'm|i am) (?:back|out of the (?:library|lecture|meeting))",
        // Hebrew
        "(?:אפשר|מותר לך) לדבר(?: שוב)?", "תדבר שוב", "(?:בטל|תבטל) (?:את )?מצב שקט", "בלי מצב שקט", "תחזור לדבר",
    ]
}

/// How long a sentence stays "being said" when nothing is played (quiet mode, or a typed question): its caption and
/// anything waiting on it (a lesson step, the next sentence, `<end/>`) keep their order and spacing. A plain answer
/// comes in at reading pace (it all stays on screen, so a slow reader isn't rushed); a lesson line keeps the pace of
/// speech, so the pen has time to draw its step.
enum QuietPace {
    static func seconds(_ text: String, drawing: Bool) -> Double {
        let words = text.split(whereSeparator: \.isWhitespace).count
        // Scripts written without spaces (Chinese, Japanese, Thai): about two characters a word.
        let dense = text.unicodeScalars.filter { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) || (0x0E00...0x0E7F).contains($0.value) }.count
        let units = Double(words) + Double(dense) / 2
        return drawing ? min(12, max(1.6, units / 2.6 + 0.3)) : min(8, max(0.9, units / 4.0 + 0.25))
    }
}

/// The part of an answer meant to be used, not just heard: a rewrite, a command, a line to paste. The Copy buttons
/// copy it (or, when there's none, the whole answer).
enum Copyable {
    static func extract(answer: String, offer: String? = nil) -> String? {
        // A rewrite the talker prepared for "Want me to swap it in?": its exact words are in the offer.
        if let o = offer, let r = o.range(of: #"with exactly:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            let t = unquote(String(o[r.upperBound...]))
            if !t.isEmpty { return t }
        }
        // A command or a short piece of code: `git stash pop`.
        let code = matches(#"`([^`\n]{2,400})`"#, in: answer)
        if let c = code.max(by: { $0.count < $1.count }) { return c }
        // A line to paste, in quotes: “Thanks for the quick reply, I'll send it Monday.”
        let quoted = matches(#"[“"]([^”"\n]{8,1200})[”"]"#, in: answer).filter { $0.split(separator: " ").count >= 4 }
        if let q = quoted.max(by: { $0.count < $1.count }) { return q }
        // A rewrite said in full, then "Want me to swap it in?" (no offer came with it).
        let sentences = answer.components(separatedBy: CharacterSet(charactersIn: "\n")).joined(separator: " ")
        if let ask = sentences.range(of: #"\s*(?:Want|Shall|Should|Do you want) (?:me to |I )?(?:swap|paste|put|replace|use|drop)\b[^?]*\?\s*$"#,
                                     options: [.regularExpression, .caseInsensitive]) {
            var body = String(sentences[..<ask.lowerBound]).trimmingCharacters(in: .whitespaces)
            // "Here's a punchier version: …" → the words after the colon.
            if let colon = body.firstIndex(of: ":"), body[..<colon].split(separator: " ").count <= 10 {
                body = String(body[body.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            body = unquote(body)
            if body.split(separator: " ").count >= 3 { return body }
        }
        return nil
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for (a, b) in [("\"", "\""), ("“", "”"), ("'", "'"), ("`", "`"), ("‘", "’")] where t.count >= 2 && t.hasPrefix(a) && t.hasSuffix(b) {
            t = String(t.dropFirst().dropLast())
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range(at: 1), in: s).map { String(s[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }
}
