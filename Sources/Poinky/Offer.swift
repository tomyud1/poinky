import Foundation

/// An action the talker offered and prepared ahead ("…Want me to swap it in?" plus
/// `<offer say="Swapping it in."><do>…</do></offer>`). The parser keeps it aside (nothing in it runs);
/// if the user's next words are a clear yes, Poinky runs it at once with no model call, through
/// `CallController.handle`, exactly as if the talker had written those tags now (the doer's risky-word
/// rules, the settings whitelist, the reminder checks…). A clear no drops it; anything else goes to the
/// talker as usual and the offer is forgotten. It also lapses after `lifetime` seconds, or when the front
/// app, its window or the selected text changed.
struct PendingOffer {
    let actions: TalkEvents
    let say: String?
    let made: TimeInterval
    /// Where the user was when it was offered (bundle id, window title, selected text).
    let app: String
    let window: String
    let selection: String

    static let lifetime: TimeInterval = 60

    /// Only these may wait for a yes: new wording (`<replace>`), doing it (`<do>`, `<guide>`), sketching it (`<visual>`), a helper,
    /// a reminder, a setting, a message to a helper. Never memory edits, lookups, stopping or undoing
    /// helpers, ending the session, a video, or another offer.
    static func allowed(_ e: TalkEvents) -> TalkEvents {
        var a = TalkEvents()
        a.replace = e.replace
        a.doTask = a.replace == nil ? e.doTask : nil   // one way to put the words in
        a.guide = a.doTask == nil && a.replace == nil ? e.guide : nil
        a.visual = e.visual
        a.agents = e.agents
        a.reminders = e.reminders
        a.settings = e.settings
        a.tells = e.tells
        return a
    }

    static func isEmpty(_ a: TalkEvents) -> Bool {
        a.replace == nil && a.doTask == nil && a.guide == nil && a.visual == nil && a.agents.isEmpty && a.reminders.isEmpty
            && a.settings.isEmpty && a.tells.isEmpty
    }

    /// The offer in a finished reply (`TalkEvents.offer`), or nil if it holds nothing that may wait.
    static func make(_ offer: (say: String?, body: String)?, at now: TimeInterval,
                     app: String, window: String, selection: String) -> PendingOffer? {
        guard let offer else { return nil }
        var p = TalkParser()
        let early = p.feed(offer.body)   // <do>, <guide> and <visual> come out here, the rest in finish()
        var all = p.finish()
        all.doTask = all.doTask ?? early.doTask
        all.guide = all.guide ?? early.guide
        all.visual = all.visual ?? early.visual
        let actions = allowed(all)
        guard !isEmpty(actions) else { return nil }
        let say = offer.say.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        return PendingOffer(actions: actions, say: say, made: now, app: app, window: window, selection: selection)
    }

    enum Check: Equatable { case ok, expired, moved }

    /// Still good to run now? `window` / `selection` empty: not known now (the front app wasn't read).
    func check(now: TimeInterval, app: String, window: String?, selection: String?) -> Check {
        if now - made > Self.lifetime || now < made { return .expired }
        func same(_ a: String, _ b: String) -> Bool {
            a.split(whereSeparator: \.isWhitespace) == b.split(whereSeparator: \.isWhitespace)
        }
        if !self.app.isEmpty, !app.isEmpty, self.app != app { return .moved }
        if let w = window, !self.window.isEmpty, !same(self.window, w) { return .moved }
        // Typing over a selection replaces it: only if it's still the same text.
        if actions.doTask != nil || actions.replace != nil, !self.selection.isEmpty, let s = selection, !same(self.selection, s) { return .moved }
        return .ok
    }

    /// What it did, in a few words (the log, and the talker's next message).
    var what: String {
        var n: [String] = []
        if let r = actions.replace { n.append("put in the new text\(r.named ? " in place of «\(r.from ?? "")…\(r.to ?? "")»" : "") : \(r.text)") }
        if let d = actions.doTask { n.append("did for the user: \(d)") }
        if let g = actions.guide { n.append("started showing the steps: \(g)") }
        if let v = actions.visual { n.append("started a sketch: \(v)") }
        for a in actions.agents { n.append("started a helper: \(a.title)") }
        for r in actions.reminders { n.append("set a reminder at \(r.at): \(r.text)") }
        if !actions.settings.isEmpty { n.append("changed settings: \(actions.settings.joined(separator: " "))") }
        for t in actions.tells { n.append("told \(t.name): \(t.text)") }
        return n.joined(separator: "; ")
    }

    /// What to say when it runs, if the talker didn't write `say="…"`.
    var defaultLine: String {
        if actions.replace != nil { return "Swapping it in." }
        if actions.doTask != nil { return "On it." }
        if actions.guide != nil { return "Okay, let me show you." }
        if actions.visual != nil { return "Sure, let me sketch it." }
        if !actions.reminders.isEmpty { return "Okay, it's set." }
        if !actions.tells.isEmpty { return "Okay, I'll pass it on." }
        return "Done."
    }
}

/// Is what the user said a clear yes, a clear no, or something else (that goes to the talker)?
/// Only short answers made entirely of yes words (or no words) and fillers count: "yes, but shorter",
/// "no wait", "maybe" are something else. English and Hebrew.
enum OfferReply: Equatable {
    case yes, no, other

    private static let yesWords: [String] = [
        "yes", "yeah", "yea", "yep", "yup", "ya", "yah", "sure", "sure thing", "ok", "okay", "o k", "alright", "all right",
        "go ahead", "go for it", "do it", "do that", "please do", "let's do it", "lets do it", "let's go", "lets go",
        "sounds good", "sounds great", "that works", "works for me", "perfect", "great", "absolutely", "definitely",
        "of course", "why not", "you bet", "totally", "uh huh", "mm hmm", "mhm", "yes please", "affirmative",
        "swap it in", "swap it", "put it in", "replace it", "change it", "start it", "set it", "make it so", "go on",
        "כן", "בטח", "סבבה", "יאללה", "קדימה", "תעשה", "תעשי", "תעשו", "אוקיי", "אוקי", "בסדר", "אחלה", "מעולה",
        "בוודאי", "ודאי", "בהחלט", "למה לא", "בטח שכן", "תחליף", "תחליפי", "תכניס", "תכניסי", "שים", "תשים", "תשימי",
        "תתחיל", "תתחילי", "לך על זה", "לכי על זה", "סגור", "יופי",
    ]
    private static let noWords: [String] = [
        "no", "nope", "nah", "no thanks", "no thank you", "not now", "not yet", "don't", "dont", "do not",
        "don't do it", "dont do it", "do not do it", "don't bother", "never mind", "nevermind", "leave it",
        "leave it as is", "keep it", "keep it as is", "skip it", "skip", "forget it", "cancel", "stop", "no need", "pass",
        "לא", "לא תודה", "לא צריך", "לא עכשיו", "עזוב", "עזבי", "עזוב את זה", "עזבי את זה", "אל תעשה", "אל תעשי",
        "אל תעשה את זה", "אל תעשי את זה", "ממש לא", "שכח מזה", "שכחי מזה", "בטל", "תבטל", "תשאיר", "תשאירי",
        "תשאיר ככה", "תשאירי ככה", "אין צורך",
    ]
    private static let filler: [String] = [
        "thanks", "thank you", "please", "um", "uh", "oh", "hmm", "well", "and", "then", "just", "now", "it", "that",
        "poinky", "buddy", "man", "dude", "sir", "thats", "that's", "fine", "for now",
        "תודה", "בבקשה", "את זה", "זה", "אז", "פוינקי", "רגע", "עכשיו", "אה", "אממ", "כבר",
    ]
    private static let maxWords = 8
    /// Every phrase as words with its kind (0 filler, 1 yes, 2 no), the longest first: "don't do it" is a no.
    private static let table: [(words: [String], kind: Int)] = {
        var t: [(words: [String], kind: Int)] = []
        for w in yesWords { t.append((w.split(separator: " ").map(String.init), 1)) }
        for w in noWords { t.append((w.split(separator: " ").map(String.init), 2)) }
        for w in filler { t.append((w.split(separator: " ").map(String.init), 0)) }
        return t.sorted { $0.words.count > $1.words.count }
    }()

    static func classify(_ said: String) -> OfferReply {
        let words = normalize(said)
        guard !words.isEmpty, words.count <= maxWords else { return .other }
        var i = 0, sawYes = false, sawNo = false
        while i < words.count {
            guard let (phrase, kind) = table.first(where: { p in
                i + p.words.count <= words.count && Array(words[i..<(i + p.words.count)]) == p.words
            }) else { return .other }
            if kind == 1 { sawYes = true } else if kind == 2 { sawNo = true }
            i += phrase.count
        }
        if sawYes && !sawNo { return .yes }
        if sawNo && !sawYes { return .no }
        return .other
    }

    /// Lowercased words, punctuation dropped (straight and curly apostrophes kept as `'`).
    static func normalize(_ s: String) -> [String] {
        let t = s.lowercased().replacingOccurrences(of: "’", with: "'")
        let cleaned = String(t.unicodeScalars.map { c -> Character in
            CharacterSet.letters.contains(c) || CharacterSet.decimalDigits.contains(c) || c == "'" ? Character(c) : " "
        })
        return cleaned.split(separator: " ").map(String.init)
    }
}
