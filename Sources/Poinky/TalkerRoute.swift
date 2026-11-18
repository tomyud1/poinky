import Foundation

/// What a question is, from its words alone (no model, well under a millisecond): whether the teacher starts
/// in parallel with the talker (a sketch, or a careful check of the user's work), and which extra context and
/// instructions the talker's message gets (the app manual, the helpers' finer tags, the video section, the
/// reminders list, a reply-shape hint). One place, so routing can be changed without guessing: every rule is
/// pinned by the phrase table in tools/tests/talker-route/cases.tsv (run by tools/test-talker.sh).
struct TalkerRoute: Equatable {
    enum Teacher: String { case none, sketch, check }
    enum Shape: String { case rewrite, summary, quiz, recall, guide }

    var teacher: Teacher = .none
    /// Which rule decided `teacher` (the table test and the timeline name it).
    var reason = "none"
    /// About Poinky itself: the manual and the current settings go with the question.
    var aboutApp = false
    /// About helpers (continue, undo, git, plan, a model…): their finer tags and the earlier-helpers list.
    var aboutHelpers = false
    /// About time (reminders, timers): the list of scheduled ones.
    var aboutTime = false
    /// About usage or cost: the helpers' usage line.
    var aboutUsage = false
    /// Asks for a video or a long explanation: the video section goes with the question (the talker decides).
    var wantsVideo = false
    /// A reply the fast talker kept getting wrong: a hint about its shape, right before the format reminder.
    var shape: Shape?

    static func classify(_ question: String, marked: Bool = false, work: String = "") -> TalkerRoute {
        let s = question.lowercased().replacingOccurrences(of: "’", with: "'")
        var r = TalkerRoute()
        r.aboutApp = has(s, aboutAppWords)
        r.aboutHelpers = has(s, aboutHelpersWords)
        r.aboutTime = has(s, aboutTimeWords)
        r.aboutUsage = has(s, aboutUsageWords)
        r.wantsVideo = has(s, longWords)
        (r.teacher, r.reason) = teacher(s, marked: marked, work: work)
        r.shape = has(s, rewriteWords) ? .rewrite : has(s, summaryWords) ? .summary : has(s, quizWords) ? .quiz
            : has(s, pastWords) ? .recall
            : r.reason == "how-to" && !r.aboutApp && has(s, appHowToWords) ? .guide : nil
        return r
    }

    private static func teacher(_ s: String, marked: Bool, work: String) -> (Teacher, String) {
        // Their own work ("did I get number 2 right?"): the teacher checks it carefully, whatever is on screen.
        // The fast talker answers without a thinking step and called right work wrong (and wrong work right).
        if has(s, checkMineWords) || s.range(of: checkItemPattern, options: .regularExpression) != nil { return (.check, "check-mine") }
        // "Is this right?" about selected or marked work with math in it.
        if has(s, checkWords), work.range(of: mathPattern, options: .regularExpression) != nil { return (.check, "check-math") }
        // They asked for it short, or for a few words ("how do you say… in French"): the talker answers alone.
        if has(s, quickWords) { return (.none, "quick") }
        // A video or a long explanation: the talker decides (it may make a video instead of a sketch).
        if has(s, longWords) { return (.none, "long") }
        // "How do I solve this?" is a lesson; "how do I export this?" is a walkthrough in the app (the talker's <guide>).
        if has(s, howToWords) { return has(s, studyWords) ? (.sketch, "solve") : (.none, "how-to") }
        if has(s, strongWords) { return (.sketch, "explain") }
        // Marked something and asked what/why about it.
        if marked, has(s, softWords), s.split(separator: " ").count >= 3 { return (.sketch, "marked") }
        return (.none, "none")
    }

    // MARK: Word lists
    // A phrase matches anywhere in the lowercased question ("how do " also matches "how does"). A leading
    // "=" means whole words only ("=sound" doesn't match "sounds good"; "=pr" doesn't match "price").

    static let quickWords = [
        "briefly", "in brief", "quick question", "quickly", "real quick", "in one sentence", "in a sentence",
        "in a few words", "in a word", "short answer", "just tell me", "tl;dr", "tldr", "keep it short",
        "how do you say", "how do i say", "how would you say", "how would i say", "how do you pronounce",
        "how do i pronounce", "how do you spell", "how do i spell", "how do you write", "translate", "what's the word for",
        "בקצרה", "בקיצור", "במשפט אחד", "איך אומרים", "איך כותבים", "תתרגם", "תרגם",
    ]
    static let longWords = ["video", "explainer", "long explanation", "in depth", "in-depth", "deep dive",
                            "the whole story", "full story", "סרטון"]
    static let howToWords = ["how do i", "how can i", "how to ", "where do i", "where can i", "help me ", "walk me through",
                             "show me how to", "איך אני", "איך עושים", "איך משנים", "איפה אני"]
    /// With a how-to word: learning something (a lesson), not doing something in an app.
    static let studyWords = [
        "solve", "calculate", "compute", "factor", "simplify", "integrate", "differentiate", "derive", "prove",
        "balance", "find x", "find y", "find the value", "find the area", "find the slope", "find the derivative",
        "work this out", "work it out", "figure this out", "figure it out", "approach this", "do this problem",
        "do this question", "do number", "do question", "answer this question", "understand",
        "לפתור", "פותרים", "לחשב", "מחשבים", "להבין",
    ]
    static let strongWords = [
        "explain", "how does", "how do ", "how is ", "how are", "how it works", "show me", "draw", "sketch",
        "diagram", "in 3d", "3d model", "teach me", "visualize", "what's the difference", "what is the difference", "compare",
        // The same asks in other languages people talk to Poinky in (Hebrew, Spanish, French, German).
        "תסביר", "הסבר", "תסבירי", "איך פותרים", "איך לפתור", "איך מחשבים", "איך עובד", "איך זה עובד", "תראה לי", "תראי לי", "תצייר", "מה ההבדל",
        "explica", "cómo funciona", "explique", "comment ça marche", "erklär", "wie funktioniert",
    ]
    static let softWords = ["what does", "what is", "what's", "what are", "why ", "mean"]

    /// Asking about their own work: always a careful check.
    static let checkMineWords = [
        "did i get", "is my answer", "are my answers", "check my work", "check my answer", "check my homework",
        "check my math", "did i solve", "did i do this right", "did i do it right", "did i do that right",
        "where did i go wrong", "what did i do wrong", "where's my mistake", "where is my mistake", "did i make a mistake",
        "צדקתי", "פתרתי נכון", "תבדוק לי", "תבדקי לי", "איפה טעיתי",
    ]
    /// "Is number 2 right?", "is question 3 correct?"
    static let checkItemPattern = #"\b(number|question|problem|exercise|#)\s*\w+\s+(right|correct|wrong)\b"#
    /// "Is this right?": a check only when the selected or marked text has math in it.
    static let checkWords = ["is this right", "is this correct", "is that right", "is that correct", "is it right",
                             "is it correct", "am i right", "check this", "any mistakes", "זה נכון", "תבדוק"]
    static let mathPattern = #"\d\s*[=+×÷^²³√<>≤≥−-]|[=²³√≤≥]\s*\d"#

    static let aboutAppWords = [
        "poinky", "=settings", "the setting", "that setting", "your voice", "the voice", "=voice", "different voice", "another voice",
        "=accent", "=faster", "=slower", "slow down", "speed up", "too fast", "too slow", "=louder", "=quieter",
        "=buddy", "=shortcut", "=shortcuts", "=hotkey", "=keyboard", "the sound", "the sounds", "sound effect", "sound volume", "=mute",
        "=notch", "=memory", "=forget", "the teacher", "=chalkboard", "hands-free", "hands free", "=privacy",
        "what did you see", "what do you send", "what you send", "start fresh", "=update", "=updates",
        "what can you do", "what else can you", "how do you work", "who are you", "what are you", "your name",
        "type to you", "helpers window", "away mode", "=ntfy",
        "הגדרות", "הגדרה", "מהר יותר", "לאט יותר", "תדבר לאט", "תדבר מהר", "הקול",
    ]
    static let aboutHelpersWords = [
        "=agent", "=agents", "=helper", "=helpers", "=continue", "=earlier", "last time", "=resume", "=undo", "=revert",
        "=commit", "=push", "pull request", "=pr", "code review", "security review", "review the changes", "review my code", "make a plan", "plan first", "a plan",
        "with opus", "with sonnet", "with haiku", "with fable", "use opus", "use sonnet", "use haiku", "use fable",
        "עוזר", "סוכן",
    ]
    static let aboutTimeWords = ["remind", "schedul", "alarm", "every ", "tomorrow", "later", "timer",
                                 "תזכיר", "תזכורת", "טיימר", "מחר"]
    static let aboutUsageWords = ["usage", "used", "cost", "spent", "limit", "tokens", "how much"]
    static let rewriteWords = ["punchier", "shorter", "rewrite", "reword", "rephrase", "fix the grammar", "more formal",
                               "less formal", "tighten", "make it sound", "make this sound", "more polite", "politer"]
    static let summaryWords = ["short version", "sum it up", "summarize", "summarise", "tl;dr", "tldr", "gist",
                               "in a nutshell", "quick summary"]

    static let quizWords = ["quiz me", "test me", "ask me questions", "בוחן", "תבחן אותי", "תשאל אותי"]
    /// About something before this conversation: look it up (`<recall>`) instead of saying "I don't remember".
    static let pastWords = ["yesterday", "last time", "last week", "the other day", "earlier today", "this morning",
                            "what did you tell me", "what did we talk", "what were we", "אתמול", "בפעם הקודמת"]
    /// A how-to that's a walkthrough in an app ("help me with number three" isn't).
    static let appHowToWords = ["how do i", "how can i", "how to ", "where do i", "where can i", "walk me through",
                                "show me how to", "איך אני", "איך עושים", "איך משנים", "איפה אני"]

    static func has(_ s: String, _ phrases: [String]) -> Bool {
        phrases.contains { p in
            guard p.hasPrefix("=") else { return s.contains(p) }
            let w = NSRegularExpression.escapedPattern(for: String(p.dropFirst()))
            return s.range(of: #"(?<![\p{L}\p{N}])"# + w + #"(?![\p{L}\p{N}])"#, options: .regularExpression) != nil
        }
    }

    /// A hand-over line in the question's language, for the "the teacher is already sketching" note: with only an
    /// English example, Haiku answered Hebrew questions in full instead of handing over.
    static func handOverExample(_ question: String, checking: Bool) -> String {
        if question.unicodeScalars.contains(where: { (0x0590...0x05FF).contains($0.value) }) {
            return checking ? "בוא נעבור על זה." : "בטח, אני אראה לך."
        }
        return checking ? "Let me go through it." : "Sure, let me show you."
    }

    /// While the teacher sketches the answer in parallel, the talker only hands over. Haiku without a thinking step
    /// still explained it first (in Hebrew in every run), so the explanation was said twice. What of its reply is
    /// spoken: pieces up to the end of its first sentence, at most `handOverWords` words in all; a first piece that's
    /// longer becomes the stock line. `before`: the pieces already let through this turn. Nil: drop the piece.
    static let handOverWords = 16
    static func handOver(piece: String, before: [String], question: String) -> String? {
        if let last = before.last, last.last.map({ ".!?…".contains($0) }) == true { return nil }
        let words = (before + [piece]).joined(separator: " ").split(whereSeparator: \.isWhitespace).count
        if words <= handOverWords { return piece }
        return before.isEmpty ? handOverExample(question, checking: false) : nil
    }

    /// The hint `shape` stands for, said right where the fast talker reads last.
    var shapeHint: String? {
        switch shape {
        case .rewrite?:
            return "(New wording: <say> must contain the whole new text itself, word for word, then \"Want me to swap it in?\", then <offer say=\"Swapping it in.\"><do>Replace the selected text with exactly: …the new text…</do></offer>. Rewrite only the selected words: no greeting or sign-off they didn't select. Never \"here's a version\" without the words.)"
        case .summary?:
            return "(Summary: at most 3 short sentences, about 40 words, the main point first. Don't list every item.)"
        case .quiz?:
            return "(Quiz: you ask. Put the first question itself in <say> and wait for their answer. No <visual>, no helper.)"
        case .recall?:
            return "(About something before this conversation: don't answer from memory or say you don't have it. Say a short line like \"Let me look.\" and write <recall>topic and time words</recall>.)"
        case .guide?:
            return "(How to do something: if it's done in an app on screen, your <say> is only \"Sure, I'll walk you through it.\" (no steps in it) and you add <guide>the goal</guide>; it shows them one click at a time.)"
        case nil:
            return nil
        }
    }
}
