import Foundation

/// A helper needs you: Claude Code wants permission for something the helper isn't allowed to do on
/// its own (a `can_use_tool` request), or the helper asked you a question (AskUserQuestion).
///
/// The helper waits until you answer: nothing is approved without your yes. Answers come only from
/// what you say (or a click on its card), worked out here without a model; the talker can't approve
/// anything, so text on the screen can't either.
struct HelperAsk: Equatable {
    struct Question: Equatable {
        let text: String
        let options: [String]
        let multi: Bool
    }
    enum Kind: Equatable { case permission, question }

    let requestID: String
    let tool: String
    let kind: Kind
    /// The tool's input exactly as Claude Code sent it (sent back unchanged on yes).
    let inputJSON: Data
    /// Exactly what it wants to do, for its card ("npm install left-pad --no-save").
    let detail: String
    /// Short and in its own words, for its bubble ("Can I run npm install left-pad?").
    let bubble: String
    /// What Poinky says after its name ("wants to run npm install left-pad. Is that okay?").
    let spoken: String
    /// AskUserQuestion: its questions, asked one at a time.
    let questions: [Question]
    /// Claude Code's suggested "always allow" rules (JSON), used when you say "yes, always".
    let suggestionsJSON: Data?
    /// Pushing, deleting, installing, sending: always asks, and "always" doesn't apply.
    let risky: Bool
    /// AskUserQuestion: answers so far (question → answer).
    var answers: [String: String] = [:]

    /// The question being asked now (AskUserQuestion), or nil.
    var currentQuestion: Question? { questions.first { answers[$0.text] == nil } }

    // MARK: - From Claude Code's request

    /// From a `control_request` line (`subtype: can_use_tool`).
    static func from(_ obj: [String: Any]) -> HelperAsk? {
        guard let rid = obj["request_id"] as? String, let req = obj["request"] as? [String: Any],
              req["subtype"] as? String == "can_use_tool", let tool = req["tool_name"] as? String else { return nil }
        let input = req["input"] as? [String: Any] ?? [:]
        let inputJSON = (try? JSONSerialization.data(withJSONObject: input)) ?? Data("{}".utf8)
        let suggestions = (req["permission_suggestions"] as? [[String: Any]]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let s = { (k: String) in (input[k] as? String) ?? "" }
        let file = { (k: String) in (s(k) as NSString).lastPathComponent }
        if tool == "AskUserQuestion" {
            let qs: [Question] = ((input["questions"] as? [[String: Any]]) ?? []).compactMap { q in
                guard let text = q["question"] as? String, !text.isEmpty else { return nil }
                let opts = ((q["options"] as? [[String: Any]]) ?? []).compactMap { $0["label"] as? String }
                return Question(text: text, options: opts, multi: q["multiSelect"] as? Bool ?? false)
            }
            guard let first = qs.first else { return nil }
            return HelperAsk(requestID: rid, tool: tool, kind: .question, inputJSON: inputJSON,
                             detail: questionDetail(first), bubble: HelperStream.clip(first.text, 60),
                             spoken: "asks: " + spokenQuestion(first), questions: qs, suggestionsJSON: nil, risky: false)
        }

        var detail: String, bubble: String, spoken: String
        var risky = false
        switch tool {
        case "Bash":
            let cmd = s("command").trimmingCharacters(in: .whitespacesAndNewlines)
            detail = HelperStream.clip(cmd, 400)
            let said = speakable(cmd)
            bubble = "Can I run \(shortCommand(cmd))?"
            spoken = "wants to run \(said)."
            risky = isRisky(command: cmd)
        case "Edit", "MultiEdit", "NotebookEdit":
            let path = s("file_path").isEmpty ? s("notebook_path") : s("file_path")
            detail = path
            bubble = "Can I edit \((path as NSString).lastPathComponent)?"
            spoken = "wants to edit \((path as NSString).lastPathComponent)."
        case "Write":
            detail = s("file_path")
            bubble = "Can I write \(file("file_path"))?"
            spoken = "wants to write the file \(file("file_path"))."
        case "WebFetch":
            let host = URL(string: s("url"))?.host ?? "a web page"
            detail = s("url")
            bubble = "Can I open \(host)?"
            spoken = "wants to open \(host)."
        case "WebSearch":
            detail = s("query")
            bubble = "Can I search the web?"
            spoken = "wants to search the web for \(HelperStream.clip(s("query"), 60))."
        case "ExitPlanMode":
            detail = HelperStream.clip(s("plan"), 400)
            bubble = "Can I start making changes?"
            spoken = "has a plan and wants to start making changes."
        case "Task", "Agent":
            detail = s("description")
            bubble = "Can I start a sub-agent?"
            spoken = "wants to hand part of the work to a sub-agent."
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.components(separatedBy: "__")
                let name = (parts.last ?? tool).replacingOccurrences(of: "_", with: " ")
                let server = parts.count > 2 ? parts[1] : ""
                detail = server.isEmpty ? name : "\(name) (\(server))"
                bubble = "Can I use \(HelperStream.clip(name, 28))?"
                spoken = "wants to use \(name)\(server.isEmpty ? "" : " from \(server)")."
                risky = ["send", "post", "delete", "remove", "publish", "create", "write", "update", "pay", "buy", "merge", "push"]
                    .contains { name.lowercased().contains($0) }
            } else {
                detail = tool
                bubble = "Can I use \(tool)?"
                spoken = "wants to use \(tool)."
            }
        }
        return HelperAsk(requestID: rid, tool: tool, kind: .permission, inputJSON: inputJSON, detail: detail,
                         bubble: bubble, spoken: spoken + " Is that okay?", questions: [],
                         suggestionsJSON: suggestions, risky: risky)
    }

    /// The command in a few words you can say: flags dropped, paths shortened, parts joined with "then"
    /// ("cd app && npm install --save-dev left-pad" → "npm install left-pad"). Risky parts are always said.
    static func speakable(_ command: String) -> String {
        let parts = speakableParts(command)
        guard !parts.isEmpty else {
            let line = command.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? command
            return HelperStream.clip(line, 60)
        }
        // Every risky part, then the first others, up to two (in their order).
        var keep = Set(parts.indices.filter { parts[$0].risky })
        for i in parts.indices where keep.count < 2 { keep.insert(i) }
        let said = parts.indices.filter(keep.contains).map { parts[$0].text }
        return said.joined(separator: ", then ") + (parts.count > said.count ? ", and more" : "")
    }

    /// For its bubble: the part that matters most (the risky one, else the first), "and more" if there are others.
    static func shortCommand(_ command: String) -> String {
        let parts = speakableParts(command)
        guard let main = parts.first(where: \.risky) ?? parts.first else { return HelperStream.clip(command, 34) }
        return HelperStream.clip(main.text, parts.count > 1 ? 26 : 34) + (parts.count > 1 ? " and more" : "")
    }

    /// Each part of a command in a few words, and whether it's risky. Moving to a folder, listing files and
    /// trimming the output (| tail, | grep) aren't worth saying.
    static func speakableParts(_ command: String) -> [(text: String, risky: Bool)] {
        let line = command.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? command
        let parts = line.components(separatedBy: "&&").flatMap { $0.components(separatedBy: ";") }
            .flatMap { $0.components(separatedBy: "||") }.flatMap { $0.components(separatedBy: "|") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let quiet: Set<String> = ["cd", "ls", "tail", "head", "grep", "sort", "uniq", "wc", "less", "more", "tee", "cat", "true", "pwd", "echo"]
        var out: [(text: String, risky: Bool)] = []
        for part in parts {
            if let first = part.split(separator: " ").first.map(String.init), quiet.contains(first), parts.count > 1 { continue }
            var words: [String] = []
            var afterFlag = false
            for w in part.split(separator: " ").map(String.init) {
                // A flag's path ("--prefix ./demo2") isn't worth saying.
                if afterFlag, w.hasPrefix(".") || w.hasPrefix("/") || w.hasPrefix("~") { afterFlag = false; continue }
                afterFlag = w.hasPrefix("-") && !w.contains("=")
                if w.hasPrefix("-") { continue }
                if w == ">" || w == ">>" || w == "2>&1" || w == "2>" { if w != "2>&1" { words.append("into") }; continue }
                if w.contains("/") && !w.hasPrefix("http") { words.append((w as NSString).lastPathComponent); continue }
                words.append(w.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            }
            words = words.filter { !$0.isEmpty }
            if !words.isEmpty { out.append((words.prefix(7).joined(separator: " "), isRisky(command: part))) }
        }
        return out
    }

    /// Commands that always need your yes, even in auto mode (see `askRules`).
    static func isRisky(command: String) -> Bool {
        let c = " " + command.lowercased().replacingOccurrences(of: "\n", with: " ") + " "
        let patterns = [#"\bgit\s+push\b"#, #"\bgit\s+reset\s+--hard\b"#, #"\bgit\s+clean\b"#, #"(^\s*|[;&|(]\s*|\b(sudo|xargs|exec|then|do)\s+)rm(dir)?\s"#, #"\bsudo\b"#,
                        #"\b(npm|pnpm|yarn|bun)\s+(install|i|add|publish)\b"#, #"\bpip3?\s+install\b"#, #"\bbrew\s+install\b"#,
                        #"\bgem\s+install\b"#, #"\bcargo\s+install\b"#, #"\bgh\s+(pr\s+(create|merge)|release)\b"#,
                        #"\bcurl\b.*(\s-X\s*(POST|PUT|DELETE|PATCH)|\s-d\s|--data)"#, #"\bnpm\s+publish\b"#]
        return patterns.contains { c.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    /// Rules that make Claude Code ask before these, whatever the permission mode (passed with `--settings`).
    static let askRules = [
        "Bash(git push:*)", "Bash(git reset --hard:*)", "Bash(git clean:*)", "Bash(rm:*)", "Bash(rmdir:*)", "Bash(sudo:*)",
        "Bash(npm install:*)", "Bash(npm i:*)", "Bash(npm publish:*)", "Bash(pnpm add:*)", "Bash(pnpm install:*)",
        "Bash(yarn add:*)", "Bash(yarn install:*)", "Bash(bun add:*)", "Bash(bun install:*)", "Bash(pip install:*)",
        "Bash(pip3 install:*)", "Bash(brew install:*)", "Bash(gem install:*)", "Bash(cargo install:*)",
        "Bash(gh pr create:*)", "Bash(gh pr merge:*)", "Bash(gh release:*)",
    ]

    static func questionDetail(_ q: Question) -> String {
        q.options.isEmpty ? q.text : q.text + "\n" + q.options.joined(separator: " · ")
    }
    /// "Do you prefer tabs or spaces? Tabs, or spaces?" (the choices, unless the question already says them).
    static func spokenQuestion(_ q: Question) -> String {
        var s = q.text.trimmingCharacters(in: .whitespaces)
        if !s.hasSuffix("?") && !s.hasSuffix(".") { s += "?" }
        let plainQ = HelperStream.plain(q.text)
        let named = q.options.allSatisfy { plainQ.contains(HelperStream.plain($0)) }
        if !q.options.isEmpty, q.options.count <= 4, !named {
            let opts = q.options.map { HelperStream.clip($0, 40) }
            s += " " + (opts.count == 1 ? opts[0] : opts.dropLast().joined(separator: ", ") + ", or " + opts.last!) + "?"
        }
        return s
    }

    // MARK: - Your answer

    enum Reply: Equatable {
        /// Yes. `always`: don't ask again for this kind of thing (this session only; never for risky ones).
        /// `extra`: something you added ("yes, but only the dev dependencies"), sent on as a follow-up.
        case yes(always: Bool, extra: String)
        /// No, with what you said after it, if anything ("no, use yarn instead").
        case no(reason: String)
        /// The answer to its current question.
        case answer(String)
        /// Not clearly an answer: it keeps waiting.
        case unclear
    }

    /// What you meant, from what you said. `addressed`: you were pointing at it or said its name, so a
    /// free answer to its question counts too.
    func reply(to text: String, addressed: Bool) -> Reply {
        let t = HelperStream.plain(text)
        guard !t.isEmpty else { return .unclear }
        if let q = currentQuestion {
            if let pick = Self.pick(t, q) { return .answer(pick) }
            if Self.matches(t, Self.anyAnswer) { return .answer("No preference: you choose.") }
            if Self.leading(t, Self.noWords) != nil, t.split(separator: " ").count <= 4 { return .no(reason: "") }
            if addressed, !Self.starts(t, Self.hesitations) { return .answer(Self.sentence(text)) }
            return .unclear
        }
        let words = t.split(separator: " ").map(String.init)
        let yesRest = Self.leading(t, Self.yesWords), noRest = Self.leading(t, Self.noWords)
        // The longer match wins: "no problem" is a yes, "no" is a no.
        let isYes = yesRest != nil && (noRest == nil || yesRest!.count < noRest!.count)
        if !isYes, let rest = noRest {
            // "No wait, what is it?" isn't an answer yet. (Saying no is always safe: it finds another way.)
            if Self.starts(rest, Self.hesitations) || ["idea", "clue"].contains(rest.split(separator: " ").first.map(String.init) ?? "") { return .unclear }
            return .no(reason: Self.trimLinkers(rest, original: text))
        }
        if let rest = yesRest {
            let always = ["always", "every time", "don t ask again", "dont ask again", "from now on", "for the rest", "stop asking"]
                .contains { t.contains($0) }
            // A yes has to be clear: "okay, what does it want?" or "yes no wait" isn't one.
            if Self.starts(rest, Self.hesitations) { return .unclear }
            if !always, rest.split(separator: " ").prefix(4).contains(where: { ["no", "not", "don", "dont", "wait", "hold", "later"].contains($0) }),
               !rest.hasPrefix("but ") { return .unclear }
            if rest.hasPrefix("but not") || rest.hasPrefix("not ") { return .unclear }
            let restWords = rest.split(separator: " ").count
            guard always || restWords <= 2 || Self.starts(rest, Self.approvals + Self.addOns) else { return .unclear }
            var extra = ""
            // Only a clear add-on becomes a follow-up ("yes, but use yarn"); "yes, go ahead and install it" doesn't.
            if let r = rest.range(of: #"^(but|and also|also|just|only)\b"#, options: .regularExpression), words.count >= 3 {
                extra = Self.trimLinkers(String(rest[r.lowerBound...]), original: text)
            }
            return .yes(always: always, extra: extra)
        }
        return .unclear
    }

    private static let yesWords = ["yes please", "yes", "yeah", "yep", "yup", "ya", "sure", "okay", "ok", "go ahead", "do it", "allow it",
                                   "allow", "allowed", "approve", "approved", "fine", "go for it", "please do", "of course",
                                   "absolutely", "sounds good", "alright", "all right", "you can", "you may", "permission granted", "affirmative",
                                   "no problem", "no worries", "that s fine", "that s okay", "it s fine", "sure thing", "why not"]
    private static let noWords = ["no thanks", "no", "nope", "nah", "don t", "dont", "do not", "deny", "denied", "not now", "not yet",
                                  "skip it", "skip", "never", "negative", "absolutely not", "don t do it"]
    /// Not an answer yet: a question back, or thinking out loud.
    private static let hesitations = ["what", "why", "how", "which", "who", "where", "when", "wait", "hold on", "um", "uh", "hmm",
                                      "let me", "is it", "is that", "does", "do you", "can you", "could", "should", "would", "tell me",
                                      "explain", "remind me", "repeat", "say again", "i m not sure", "not sure", "maybe"]
    /// After a yes: still just a yes.
    private static let approvals = ["go ahead", "do it", "run it", "install it", "push it", "delete it", "please", "thanks", "thank you",
                                    "that s fine", "it s fine", "that s okay", "sounds good", "go for it", "you can", "you may", "and go",
                                    "carry on", "continue", "keep going", "allow it", "approved", "always", "and don t ask", "don t ask again"]
    /// After a yes: something to pass on ("yes, but only the dev dependencies").
    private static let addOns = ["but", "and also", "also", "just", "only"]
    private static func starts(_ t: String, _ phrases: [String]) -> Bool { phrases.contains { t == $0 || t.hasPrefix($0 + " ") } }
    private static let anyAnswer = ["you choose", "you decide", "your choice", "your call", "up to you", "whatever", "doesn t matter",
                                    "does not matter", "dont care", "don t care", "either", "any", "anything", "no preference", "pick one", "you pick"]

    /// If `t` starts with one of `phrases` (whole words), what's after it.
    private static func leading(_ t: String, _ phrases: [String]) -> String? {
        for p in phrases.sorted(by: { $0.count > $1.count }) where t == p || t.hasPrefix(p + " ") {
            var rest = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            // "yes yes go ahead": drop repeats.
            while let more = phrases.first(where: { rest == $0 || rest.hasPrefix($0 + " ") }), phrases == yesWords {
                rest = String(rest.dropFirst(more.count)).trimmingCharacters(in: .whitespaces)
            }
            return rest
        }
        return nil
    }
    private static func matches(_ t: String, _ phrases: [String]) -> Bool {
        phrases.contains { t == $0 || t.hasPrefix($0 + " ") || t.hasSuffix(" " + $0) }
    }

    /// Its option you named ("spaces", "the second one"), or nil.
    private static func pick(_ t: String, _ q: Question) -> String? {
        let opts = q.options
        guard !opts.isEmpty else { return nil }
        let words = t.split(separator: " ").map(String.init)
        let ordinals: [(String, Int)] = [("first", 0), ("one", 0), ("1", 0), ("second", 1), ("two", 1), ("2", 1), ("third", 2),
                                         ("three", 2), ("3", 2), ("fourth", 3), ("four", 3), ("4", 3), ("last", opts.count - 1)]
        // Named options, by where they're said ("spaces, not tabs" picks the first mentioned... unless negated).
        var found: [(pos: Int, label: String)] = []
        for o in opts {
            let p = HelperStream.plain(o)
            guard !p.isEmpty, let r = t.range(of: "\\b\(NSRegularExpression.escapedPattern(for: p))\\b", options: .regularExpression) else { continue }
            let before = t[..<r.lowerBound].split(separator: " ").suffix(1).map(String.init)
            if before == ["not"] || before == ["no"] { continue }
            found.append((t.distance(from: t.startIndex, to: r.lowerBound), o))
        }
        if q.multi, !found.isEmpty { return found.sorted { $0.pos < $1.pos }.map(\.label).joined(separator: ", ") }
        if let f = found.min(by: { $0.pos < $1.pos }) { return f.label }
        // "the first one", "the second", "option two", "number 3" (short answers only; "two-space indents" isn't a pick).
        if words.count <= 4 {
            for (w, i) in ordinals where words.contains(w) && i < opts.count && i >= 0 {
                let numberWord = !["first", "second", "third", "fourth", "last"].contains(w)
                if numberWord, !(words.count == 1 || words.contains("option") || words.contains("number")) { continue }
                return opts[i]
            }
        }
        return nil
    }

    /// The rest of what you said, in your words (from the original text, minus linking words).
    private static func trimLinkers(_ plainRest: String, original: String) -> String {
        guard !plainRest.isEmpty else { return "" }
        // Find the same words in the original (keeps capitals and punctuation).
        let firstWord = plainRest.split(separator: " ").first.map(String.init) ?? ""
        var out = plainRest
        if let r = original.range(of: "\\b\(NSRegularExpression.escapedPattern(for: firstWord))\\b", options: [.regularExpression, .caseInsensitive]) {
            out = String(original[r.lowerBound...])
        }
        out = out.replacingOccurrences(of: #"^(and|but|so|then)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.split(separator: " ").count >= 2 ? sentence(out) : ""
    }
    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.prefix(1).uppercased() + t.dropFirst()
    }

    // MARK: - The response to Claude Code

    /// `control_response` for this request, given your reply. Nil for `.unclear`.
    /// For a question with more to ask, `answer` only records it: use `recording(_:)` first.
    func response(_ reply: Reply) -> [String: Any]? {
        var input = (try? JSONSerialization.jsonObject(with: inputJSON)) as? [String: Any] ?? [:]
        var body: [String: Any]
        switch reply {
        case .unclear:
            return nil
        case .no(let reason):
            let what = kind == .question ? "The user chose not to answer" : "The user said no"
            body = ["behavior": "deny", "message": reason.isEmpty ? "\(what)." : "\(what): \(reason)"]
        case .yes(let always, _):
            if kind == .question {
                input["answers"] = Dictionary(uniqueKeysWithValues: questions.map { ($0.text, answers[$0.text] ?? "No preference: you choose.") })
            }
            body = ["behavior": "allow", "updatedInput": input]
            // "Always": Claude Code's own suggested rules, for this session only (never saved to the project).
            if always, !risky, let data = suggestionsJSON,
               var rules = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !rules.isEmpty {
                for i in rules.indices { rules[i]["destination"] = "session" }
                body["updatedPermissions"] = rules
            }
        case .answer(let a):
            var all = answers
            if let q = currentQuestion { all[q.text] = a }
            input["answers"] = Dictionary(uniqueKeysWithValues: questions.map { ($0.text, all[$0.text] ?? "No preference: you choose.") })
            body = ["behavior": "allow", "updatedInput": input]
        }
        return ["type": "control_response",
                "response": ["subtype": "success", "request_id": requestID, "response": body] as [String: Any]]
    }

    /// Records an answer to its current question. Returns the ask with its next question, or nil when all are answered.
    func recording(_ answer: String) -> HelperAsk? {
        guard let q = currentQuestion else { return nil }
        var next = self
        next.answers[q.text] = answer
        guard let nq = next.currentQuestion else { return nil }
        return HelperAsk(requestID: requestID, tool: tool, kind: kind, inputJSON: inputJSON, detail: Self.questionDetail(nq),
                         bubble: HelperStream.clip(nq.text, 60), spoken: "asks: " + Self.spokenQuestion(nq), questions: questions,
                         suggestionsJSON: nil, risky: false, answers: next.answers)
    }
}
