import Foundation

/// Talking to a helper (pointing at it while holding the keys, or by name): what you meant, worked out
/// without a model, and its status in one spoken sentence from what it has reported so far.
enum HelperTalk {
    enum Intent: Equatable {
        case stop
        case status
        case pause             // "wait", "hold on": interrupt what it's doing, keep it
        case resume            // "go on", "continue" (after a pause)
        case undo              // "undo that": put back the files it changed in its last run
        case message(String)   // a follow-up for its work
    }

    /// What you said to a helper you're pointing at.
    static func intent(_ text: String) -> Intent {
        let t = plain(text)
        if t.isEmpty { return .status }
        if isStop(t) { return .stop }
        if isPause(t) { return .pause }
        if isResume(t) { return .resume }
        if isUndo(t) { return .undo }
        if isStatus(t) { return .status }
        return .message(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Speaking about a helper by name ("how's Mint doing?", "stop Coral", "tell Violet to also add a test",
    /// "Mint, also add a test"): its name and what you meant. Nil when it isn't clearly about one of `names`.
    static func byName(_ text: String, names: [String]) -> (name: String, intent: Intent)? {
        let t = plain(text)
        let words = t.split(separator: " ").map(String.init)
        for name in names {
            let n = name.lowercased()
            guard words.contains(n) else { continue }
            let rest = t.replacingOccurrences(of: "\\b\(n)\\b", with: "", options: .regularExpression)
                .replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
            // "stop mint", "cancel mint please"
            if words.count <= 5, isStop(rest) { return (name, .stop) }
            // "wait mint", "mint hold on", "mint go on"
            if words.count <= 5, isPause(rest) { return (name, .pause) }
            if words.count <= 5, isResume(rest) { return (name, .resume) }
            // "undo mint", "undo what mint did", "undo mint s changes", "revert mint"
            if t.range(of: "^(please )?(undo|revert|roll back|put back)( what| everything)? \(n)( s)?( did| did there| changed| made| changes| work| last change(s)?)?( please)?$", options: .regularExpression) != nil {
                return (name, .undo)
            }
            // "how's mint doing", "what's mint up to", "is mint done", "status of mint"
            let statusPatterns = ["^(how s|hows|how is|how are) \(n)( doing| going| getting on| coming along)?$",
                                  "^what (s |is )?\(n) (doing|up to|working on)$", "^(is|has) \(n) (done|finished)( yet)?$",
                                  "^(status of|any news from|update from|check on) \(n)$", "^\(n) status$",
                                  "^what did \(n) (do|find|change)$"]
            if statusPatterns.contains(where: { t.range(of: $0, options: .regularExpression) != nil }) { return (name, .status) }
            // "tell mint to also add a test", "ask coral to use the json flag"
            let original = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let r = original.range(of: "^(please )?(tell|ask) \(name)( to| that)? ", options: [.regularExpression, .caseInsensitive]) {
                let msg = String(original[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty { return (name, .message(sentence(msg))) }
            }
            // "Mint, also add a test" (a few words after the name)
            if let r = original.range(of: "^(hey )?\(name)[,:] ", options: [.regularExpression, .caseInsensitive]) {
                let msg = String(original[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let p = plain(msg)
                if isStop(p) { return (name, .stop) }
                if isPause(p) { return (name, .pause) }
                if isResume(p) { return (name, .resume) }
                if isUndo(p) { return (name, .undo) }
                if isStatus(p) { return (name, .status) }
                if p.split(separator: " ").count >= 2 { return (name, .message(sentence(msg))) }
            }
        }
        return nil
    }

    /// What you said to a helper by name, without the name ("Mint, yes" → "yes", "tell Coral no, use yarn" →
    /// "no, use yarn", "yes Violet" → "yes"). Nil if the name isn't in it.
    static func without(name: String, in text: String) -> String? {
        let n = NSRegularExpression.escapedPattern(for: name)
        guard text.range(of: "\\b\(n)\\b", options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "^(please |hey |okay |ok )?(tell|ask|let) \(n)( to| that)?[,:]?\\s*", with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "^(hey |okay |ok )?\(n)[,:.!]?\\s+", with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "[,]?\\s*\(n)[.!?]?$", with: "", options: [.regularExpression, .caseInsensitive])
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One or two spoken sentences: what it's doing now, how far along, for how long.
    static func status(_ a: AgentManager.Agent, now: Date = Date()) -> String {
        let secs = (a.finished ?? now).timeIntervalSince(a.started)
        let time = secs < 60 ? "under a minute" : secs < 120 ? "a minute" : "\(Int(secs / 60)) minutes"
        switch a.status {
        case .queued:
            return "\(a.name) is waiting for a free spot. It starts when another helper finishes."
        case .running where a.paused:
            return "\(a.name) is paused. Tell it what to do next, or say go on."
        case .running:
            if let ask = a.asks.first {
                return ask.kind == .question
                    ? "\(a.name) is waiting for your answer. It \(ask.spoken)"
                    : "\(a.name) is waiting for your OK. It \(ask.spoken)"
            }
            var s: String
            let latest = a.latest.trimmingCharacters(in: .whitespacesAndNewlines)
            let w = latest.split(separator: " ").map { $0.lowercased() }
            if let first = w.first, first.hasSuffix("ing") || (first == "now" && w.count > 1 && w[1].hasSuffix("ing")) {
                s = "\(a.name) is \(lowerFirst(latest))"
                if !s.hasSuffix(".") { s += "." }
            } else if !latest.isEmpty {
                s = "\(a.name) says: \(latest)"
                if !s.hasSuffix(".") && !s.hasSuffix("!") && !s.hasSuffix("?") { s += "." }
            } else {
                s = "\(a.name) is working on \(lowerFirst(a.title))."
            }
            let done = a.checklist.filter { $0.state == .done }.count
            if !a.checklist.isEmpty {
                s += " It has done \(done) of \(a.checklist.count) steps, \(time) in."
            } else {
                s += " It's been working for \(time)."
            }
            if let b = a.blocked.last { s += " It wasn't allowed to \(lowerFirst(b))." }
            return s
        case .done:
            return "\(a.name) finished. " + firstSentences(a.summary, 2)
        case .failed:
            return "\(a.name) couldn't finish. " + firstSentences(a.summary, 2)
        case .stopped:
            return "\(a.name) was stopped."
        }
    }

    // MARK: - Words

    static func isUndo(_ t: String) -> Bool {
        t.range(of: "^(please )?(undo|revert|roll back|put back)( it| that| this| your changes| what you did| everything| all of it| the changes| your last change(s)?)?( please)?$|^(put|roll) (it|that|everything) back( please)?$",
                options: .regularExpression) != nil
    }

    static func isPause(_ t: String) -> Bool {
        t.range(of: "^(please )?(wait|hold on|hang on|pause|hold it|one sec(ond)?|just a (sec|second|moment|minute)|(wait|hold on) a (sec|second|moment|minute)|stop for a (sec|second|moment|minute))( please| a second| a sec| a moment| there)?$",
                options: .regularExpression) != nil
    }

    static func isResume(_ t: String) -> Bool {
        t.range(of: "^(okay |ok |alright )?(please )?(go on|continue|carry on|keep going|resume|go ahead and continue|you can (go on|continue)|unpause)( please| now| then)?$",
                options: .regularExpression) != nil
    }

    /// "wait, use yarn instead", "actually skip the docs": a change of direction, not just more to do.
    static func isRedirect(_ text: String) -> Bool {
        let t = plain(text)
        guard t.split(separator: " ").count >= 3 else { return false }
        return t.range(of: "^(no |nope )?(wait|hold on|hang on|actually|instead|scratch that|change of plan(s)?|stop|don t do that|forget that)\\b", options: .regularExpression) != nil
    }

    private static func isStop(_ t: String) -> Bool {
        t.range(of: "^(please )?(stop|cancel|abort|halt|quit|kill it|never ?mind|forget it|that s enough|enough)( it| that| this| now| please| working| everything| the task| for now)*$",
                options: .regularExpression) != nil
    }

    private static func isStatus(_ t: String) -> Bool {
        guard t.split(separator: " ").count <= 9 else { return false }
        // Whole-sentence only ("update the README" is a task, not a status question).
        let exact = ["status", "progress", "update", "status update", "any progress", "any update", "what s up", "status please"]
        if exact.contains(t) { return true }
        let phrases = ["what are you doing", "what re you doing", "what you doing", "what are you up to", "how s it going",
                       "hows it going", "how is it going", "how are you doing", "how are you getting on", "how far are you",
                       "how far along", "are you done", "are you finished", "are you almost done", "how long", "what s happening",
                       "what is happening", "what did you do", "what have you done", "what s the status", "what is the status",
                       "where are you at", "how much longer", "how long have you been", "how long will it take"]
        return phrases.contains { t == $0 || t.hasPrefix($0 + " ") || t.hasSuffix(" " + $0) || t.contains(" " + $0 + " ") }
    }

    /// Lowercase words and spaces only ("How's it going?" → "how s it going").
    static func plain(_ s: String) -> String { HelperStream.plain(s) }
    static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }
    static func sentence(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
    static func firstSentences(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        var out = "", count = 0
        for part in t.split(separator: ".", omittingEmptySubsequences: false) {
            out += part + "."
            if !part.trimmingCharacters(in: .whitespaces).isEmpty { count += 1 }
            if count >= n { break }
        }
        return (out.count > t.count ? t : out).trimmingCharacters(in: .whitespaces)
    }
}
