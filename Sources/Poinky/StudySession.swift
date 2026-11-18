import AppKit
import CryptoKit

// Study sessions: working through a problem sheet together, part by part, ending with a solved PDF.
// The state lives here, in code, and on disk (`Poinky/study/<sheet>/state.json`, 0600), never only in a
// model's memory: the question and its parts (read once by the teacher), where you are, the hints you had,
// your attempts and their verdicts, which papers and photos belong to which part. The flow itself is in
// CallController+Study.swift; the PDF in StudyPDF.swift; reading the sheet and photos in StudySource.swift.

/// One lettered part of a question (סעיף א, part b…).
struct StudyPart: Codable, Equatable {
    enum Status: String, Codable { case waiting, presented, trying, solvedByUser, shown, skipped }
    /// What goes into the solved PDF for this part. `auto`: your work if you solved it, else Poinky's pages.
    enum Include: String, Codable { case auto, mine, poinky, both }

    var label: String            // exactly as on the sheet: "א", "b"
    var text: String             // its words, from the sheet
    var say: String              // one spoken sentence, in the user's language, saying what it asks
    var status: Status = .waiting
    var hints = 0
    var attempts: [StudyAttempt] = []
    var pages: [String] = []     // Poinky's papers for this part (PNG files in the sheet's folder), in order
    var include: Include = .auto
    var reference: String?       // the solver's worked solution (hidden from the user)
    var answer: String?          // its final result
    var confidence: String?

    var done: Bool { status == .solvedByUser || status == .shown || status == .skipped }
    /// Which pages go in the PDF: (your photos, Poinky's papers).
    var pdfContent: (mine: [String], poinky: [String]) {
        let photos = attempts.compactMap(\.image)
        let lastRight = attempts.last(where: { $0.verdict == "right" })?.image
        let mine = lastRight.map { [$0] } ?? photos
        switch include {
        case .mine: return (mine, mine.isEmpty ? pages : [])
        case .poinky: return ([], pages)
        case .both: return (mine, pages)
        case .auto: return status == .solvedByUser && !mine.isEmpty ? (mine, []) : ([], pages)
        }
    }
}

struct StudyAttempt: Codable, Equatable {
    var at: Date
    var image: String?           // the cleaned photo (file name in the sheet's folder); nil: it was on screen
    var verdict: String          // right / wrong / unreadable / unfinished / unknown
    var line: Int?               // their first wrong or unreadable line
    var note: String
}

struct StudyQuestion: Codable, Equatable {
    var number: String
    var title: String
    var statement: String
    var givens: [String]
    var figure: String
    var parts: [StudyPart]
    var finalAnswers: [String: String] = [:]
    var sourcePages: [Int] = []  // pages of the sheet's PDF with this question (0-based)
    var shot: String?            // the screenshot it was read from, when there's no PDF file (for the solved PDF)
    var solving = false          // (not saved meaningfully: a solve that was running when the app quit is redone)
}

/// A problem sheet you're working through. Saved after every change.
struct StudySheet: Codable, Equatable {
    var id: String
    var title: String
    var document: String?        // the sheet's PDF (or image) file, when there is one
    var page: String?            // a web page
    var language = "en"          // the sheet's language
    var userLanguage = "en"      // the language the user speaks to Poinky
    var questions: [StudyQuestion] = []
    var current = 0              // index into questions
    var part = 0                 // index into the current question's parts
    var created = Date()
    var updated = Date()
    var output: String?          // the solved PDF Poinky made (it only ever replaces this file)

    var question: StudyQuestion? { questions.indices.contains(current) ? questions[current] : nil }
    var currentPart: StudyPart? {
        guard let q = question, q.parts.indices.contains(part) else { return nil }
        return q.parts[part]
    }
    var hebrew: Bool { language == "he" }
    var unfinished: Bool { questions.contains { $0.parts.contains { !$0.done } } || questions.isEmpty }

    /// The part's tag on papers ("q1-a" style; the label as written).
    func tag(_ qi: Int, _ pi: Int) -> String {
        guard questions.indices.contains(qi), questions[qi].parts.indices.contains(pi) else { return "q\(qi)-\(pi)" }
        return "q\(questions[qi].number)-\(pi)"
    }

    mutating func update(_ f: (inout StudyPart) -> Void) {
        guard questions.indices.contains(current), questions[current].parts.indices.contains(part) else { return }
        f(&questions[current].parts[part])
    }
}

// MARK: - Where it's kept

enum StudyStore {
    static var root: URL {
        if let d = ProcessInfo.processInfo.environment["POINKY_STUDY_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return AppConfig.dir.appendingPathComponent("study", isDirectory: true)
    }
    static func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    /// A stable id for a sheet: its file, else its web page, else its window title.
    static func id(document: URL?, page: String, window: String) -> String {
        let key = document?.standardizedFileURL.path ?? (page.isEmpty ? window : page)
        let d = SHA256.hash(data: Data(key.utf8))
        return d.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func save(_ s: StudySheet) {
        let fm = FileManager.default
        let dir = folder(s.id)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(s) else { return }
        let url = dir.appendingPathComponent("state.json")
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(_ id: String) -> StudySheet? {
        let url = folder(id).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(StudySheet.self, from: data)
    }

    /// Every saved sheet, newest first.
    static func all() -> [StudySheet] {
        let fm = FileManager.default
        let ids = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap(load).sorted { $0.updated > $1.updated }
    }

    /// Writes a file that belongs to a sheet (a cleaned photo, a paper), 0600. Returns its name.
    @discardableResult
    static func write(_ data: Data, name: String, sheet id: String) -> String? {
        let dir = folder(id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = dir.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return name
    }
    static func url(_ name: String, sheet id: String) -> URL { folder(id).appendingPathComponent(name) }
}

// MARK: - What the user means (no model)

/// What was said during (or to start) a study session, read in code: English and Hebrew, simple shapes.
/// Anything else during a session goes to the teacher as a question about the material.
enum StudyIntent: Equatable {
    case start(question: String?, fresh: Bool)
    case hint, tryIt, check, show, next, skip, stop, repeatPart, whereAreWe
    case goTo(part: String?, question: String?)
    case openPDF, wherePDF, savePDF
    case include(StudyPart.Include)
    case yes, no
    case hush        // a bare "wait" / "stop": stay quiet

    static func norm(_ s: String) -> String {
        let lower = s.lowercased().replacingOccurrences(of: "’", with: "'")
        let kept = lower.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == " " ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    private static func has(_ s: String, _ list: [String]) -> Bool {
        let padded = " " + s + " "
        return list.contains { w in
            // Hebrew words take prefixes (ו, ה, ל, ב…): plain contains. English: whole words.
            w.unicodeScalars.contains { $0.value >= 0x0590 && $0.value <= 0x05FF } ? s.contains(w) : padded.contains(" " + w + " ")
        }
    }

    private static let numberWords = ["one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
                                      "first": "1", "second": "2", "third": "3", "fourth": "4", "fifth": "5",
                                      "אחת": "1", "אחד": "1", "שתיים": "2", "שניים": "2", "שתים": "2", "שלוש": "3", "שלושה": "3", "ארבע": "4", "חמש": "5", "שש": "6"]
    /// "question 2", "problem three", "שאלה 1", "תרגיל מספר 2".
    static func questionNumber(_ s: String) -> String? {
        let n = norm(s)
        let pattern = #"(?:question|problem|exercise|q|שאלה|בשאלה|לשאלה|תרגיל|בעיה)\s+(?:number\s+|no\s+|מספר\s+)?([0-9]{1,2}|[a-z]+|[א-ת]+)"#
        guard let r = n.range(of: pattern, options: .regularExpression) else { return nil }
        let tail = n[r].split(separator: " ").last.map(String.init) ?? ""
        if Int(tail) != nil { return tail }
        return numberWords[tail]
    }

    /// "part b", "סעיף ב", "go back to א", "part two" → the label as said (a letter, or an index "#2").
    static func partLabel(_ s: String) -> String? {
        let n = norm(s)
        let letterNames = ["אלף": "א", "בית": "ב", "בת": "ב", "גימל": "ג", "דלת": "ד", "הא": "ה", "הי": "ה", "וו": "ו", "ואו": "ו",
                           "alef": "א", "aleph": "א", "bet": "ב", "beth": "ב", "gimel": "ג", "dalet": "ד", "vav": "ו"]
        let pattern = #"(?:part|section|סעיף|לסעיף|בסעיף|הסעיף)\s+([a-z]|[א-ת]{1,5}|[0-9]|one|two|three|four|five|six|alef|aleph|bet|beth|gimel|dalet|vav)(?:\s|$)"#
        if let r = n.range(of: pattern, options: .regularExpression) {
            let w = String(n[r].split(separator: " ")[1])
            if let l = letterNames[w] { return l }
            if Int(w) != nil { return "#" + w }
            if let d = numberWords[w] { return "#" + d }
            return w
        }
        // "go back to א" / "back to b"
        if let r = n.range(of: #"(?:back to|go to|חזרה ל|תחזור ל|נחזור ל)\s*([a-z]|[א-ו])(?:\s|$)"#, options: .regularExpression) {
            return String(n[r].trimmingCharacters(in: .whitespaces).last!)
        }
        return nil
    }

    /// A phrase that starts (or continues) working through a sheet. Needs a "together / walk through / let's
    /// solve / continue" shape AND a homework word, so "when is my homework due?" doesn't start one.
    static func start(_ s: String) -> StudyIntent? {
        let n = norm(s)
        let verbs = ["together", "walk me through", "walk through", "go through", "work through", "let's do", "lets do", "let's solve",
                     "lets solve", "help me solve", "solve with me", "continue", "pick up", "back to", "let's work on", "lets work on",
                     "study session", "tutor me", "teach me", "start",
                     "ביחד", "יחד", "נפתור", "נעבור על", "תעבור איתי", "נעשה את", "נמשיך", "תעזור לי לפתור", "בוא נעבוד"]
        let nouns = ["homework", "question", "problem", "exercise", "assignment", "worksheet", "problem set", "sheet", "study session",
                     "שאלה", "תרגיל", "שיעורי", "שיעורים", "מטלה", "גיליון", "בעיה", "התרגיל"]
        guard has(n, verbs), has(n, nouns) else { return nil }
        if n.contains("together") == false, n.contains("ביחד") == false, n.contains("יחד") == false,
           ["what is", "what's", "when is", "due", "explain"].contains(where: { n.contains($0) }), !n.contains("walk") { return nil }
        let fresh = has(n, ["start over", "from the beginning", "from scratch", "new session", "מההתחלה", "מחדש"])
        return .start(question: questionNumber(s), fresh: fresh)
    }

    /// During a session. `awaiting`: what Poinky just asked (a yes/no question, or which way to go).
    static func classify(_ s: String, awaiting: StudyAwaiting) -> StudyIntent? {
        let n = norm(s)
        guard !n.isEmpty else { return nil }
        let words = n.split(separator: " ").count
        if ["wait", "stop", "hold on", "one sec", "one second", "רגע", "שנייה", "חכה", "עצור"].contains(n) { return .hush }
        if has(n, ["stop for today", "let's stop", "lets stop", "stop the homework", "enough for today", "done for today", "call it a day",
                   "stop here", "pause the homework", "end the study", "finish for today",
                   "נעצור", "די להיום", "מספיק להיום", "נפסיק", "בוא נסיים", "נמשיך מחר", "לסיים להיום"]) { return .stop }
        let pdfWord = has(n, ["pdf", "file", "document", "submission", "the solved", "קובץ", "הקובץ", "המסמך"])
        if pdfWord {
            if has(n, ["where", "איפה"]) { return .wherePDF }
            if has(n, ["open", "show", "see", "look", "תפתח", "תראה", "פתח", "להראות"]) { return .openPDF }
            if has(n, ["save", "make", "export", "build", "create", "תשמור", "שמור", "תייצא", "תכין"]) { return .savePDF }
        }
        if words <= 4, has(n, ["save it", "save that", "save the homework", "תשמור", "שמור את זה"]) { return .savePDF }
        // Which solution goes into the PDF.
        let putting = has(n, ["put", "use", "include", "keep", "submit", "go in", "תכניס", "תשים", "תשתמש", "תכלול", "להגיש", "שים"])
        if putting || pdfWord {
            if has(n, ["both", "שניהם", "שתיהן", "שניים"]) { return .include(.both) }
            if has(n, ["my work", "my solution", "my version", "mine", "my own", "my answer", "שלי", "הפתרון שלי"]) { return .include(.mine) }
            if has(n, ["your solution", "your work", "your version", "yours", "שלך", "הפתרון שלך"]) { return .include(.poinky) }
        }
        if has(n, ["check my", "check this", "check it", "here's my", "here is my", "heres my", "is this right", "is that right", "is it right",
                   "is this correct", "did i get it", "did i get this", "look at my", "i solved it", "i've solved", "i finished", "i'm done", "im done",
                   "i did it", "my solution", "my answer is", "how did i do",
                   "תבדוק", "תבדקי", "הנה הפתרון", "פתרתי", "סיימתי", "זה נכון", "צדקתי", "תסתכל על הפתרון"]) { return .check }
        if has(n, ["repeat the question", "what was the question", "read it again", "say that again", "what does it ask", "what's the question",
                   "repeat the part", "read the part", "תחזור על השאלה", "מה השאלה", "מה שואלים", "תקרא שוב", "תחזור על הסעיף"]) { return .repeatPart }
        if has(n, ["where are we", "which part", "what part are we", "באיזה סעיף", "איפה אנחנו"]) { return .whereAreWe }
        if has(n, ["hint", "clue", "nudge", "i'm stuck", "im stuck", "where do i start", "how do i start", "how should i start", "help me start",
                   "רמז", "כיוון", "תקוע", "תקועה", "איך מתחילים", "איך להתחיל"]) { return .hint }
        if has(n, ["next question", "השאלה הבאה", "לשאלה הבאה"]) { return .goTo(part: nil, question: "+1") }
        if let q = questionNumber(s), has(n, ["go to", "move to", "let's do", "lets do", "now", "on to", "עבור ל", "נעבור", "בוא נעשה"]) {
            return .goTo(part: partLabel(s), question: q)
        }
        if let p = partLabel(s), has(n, ["go", "back", "move", "let's", "lets", "do", "now", "skip to", "on to", "start", "נעבור", "חזרה", "תחזור", "נחזור", "בוא", "עכשיו"]) || words <= 3 {
            return .goTo(part: p, question: nil)
        }
        if has(n, ["skip", "skip it", "skip this", "דלג", "תדלג", "נדלג"]) { return .skip }
        if has(n, ["next part", "next one", "move on", "let's move on", "the next", "next", "onward", "onwards", "go on", "keep going",
                   "הבא", "הלאה", "סעיף הבא", "תמשיך", "נמשיך", "להמשיך"]) && words <= 6 { return .next }
        if has(n, ["show me the", "show me how", "just show me", "solve it", "full solution", "the solution", "the answer", "you solve",
                   "you do it", "go ahead and solve", "work it out", "explain the solution", "how do you solve", "show me",
                   "תראה לי", "תראי לי", "תפתור", "פתרון מלא", "את הפתרון", "תסביר את הפתרון", "תפתרי"]) && words <= 9 { return .show }
        if has(n, ["i'll try", "ill try", "let me try", "i want to try", "i'll do it", "i'll solve", "myself", "on my own", "give me a minute",
                   "let me think", "i'll give it a go", "i'll give it a try", "try it",
                   "אני אנסה", "אנסה", "לבד", "לנסות", "תן לי לחשוב", "תני לי לחשוב", "אני אפתור"]) { return .tryIt }
        switch OfferReply.classify(s) {
        case .yes where words <= 5: return .yes
        case .no where words <= 4: return .no
        default: return nil
        }
    }
}

/// What Poinky just asked, so a bare "yes" means the right thing.
enum StudyAwaiting: String, Codable {
    case nothing
    case choice      // "try it, a hint, or shall I show you?"
    case working     // the user is trying it
    case nextPart    // "shall we go on to part ב?"
    case nextQuestion
    case afterWrong  // "a hint to fix it, or the corrected continuation?"
    case clarify     // the teacher asked about a line it couldn't read
    case resume      // "we stopped at question 1, part ב: carry on?"
    case scroll      // the question goes on below
}

// MARK: - Poinky's own lines (said without a model, in the user's language)

enum StudyWords {
    static func letterName(_ l: String) -> String {
        ["א": "Alef", "ב": "Bet", "ג": "Gimel", "ד": "Dalet", "ה": "He", "ו": "Vav", "ז": "Zayin", "ח": "Het"][l] ?? l.uppercased()
    }
    /// "part Bet" (English speaker, Hebrew sheet), "part b", "סעיף ב".
    static func part(_ l: String, he: Bool) -> String { he ? "סעיף \(l)" : "part \(letterName(l))" }

    static func reading(_ he: Bool) -> String { he ? "רגע, אני קורא את השאלה." : "Let me read the question first." }
    static func choice(_ he: Bool) -> String { he ? "רוצה לנסות לבד, לקבל רמז, או שאראה לך?" : "Want to try it yourself, get a hint, or shall I show you?" }
    static func choiceAgain(_ he: Bool) -> String { he ? "לנסות לבד, רמז, או הפתרון המלא?" : "Try it yourself, a hint, or the full solution?" }
    static func tryIt(_ he: Bool) -> String {
        he ? "בטח, קח את הזמן. כשתסיים, תראה לי: תשלח תמונה, או תפתח אותה על המסך ותגיד תבדוק."
           : "Sure, take your time. When you're done, show me: send a photo, or put it on screen and say check my work."
    }
    static func moreHint(_ he: Bool) -> String { he ? "רוצה לנסות עכשיו, או עוד רמז?" : "Want to try it now, or another hint?" }
    static func lastHint(_ he: Bool) -> String {
        he ? "זה הרמז האחרון לפני שאני מגלה את הפתרון. תנסה, או שאראה לך את ההמשך."
           : "That's as far as hints go without giving it away. Give it a try, or I'll show you the rest."
    }
    static func goOn(_ label: String, he: Bool) -> String { he ? "נמשיך ל\(part(label, he: true))?" : "Shall we go on to \(part(label, he: false))?" }
    static func lastPart(_ n: String, he: Bool) -> String {
        he ? "זה היה הסעיף האחרון של שאלה \(n). נמשיך לשאלה הבאה?" : "That was the last part of question \(n). Want to go on to the next question?"
    }
    static func workingOut(_ he: Bool) -> String { he ? "רגע, אני פותר את זה בעצמי קודם." : "Let me work it out myself first." }
    static func afterWrong(_ he: Bool) -> String {
        he ? "רוצה רמז כדי לתקן, או שאראה לך איך ממשיכים?" : "Want a hint to fix it, or shall I show you how it goes on?"
    }
    static func keepGoing(_ he: Bool) -> String { he ? "עד כאן נכון. תמשיך, ותראה לי כשתסיים." : "Right so far. Keep going, and show me when you're done." }
    static func noSheet(_ he: Bool) -> String {
        he ? "אני לא רואה דף תרגילים. תפתח אותו על המסך ותבקש שוב." : "I don't see a problem sheet. Open it on screen and ask me again."
    }
    static func scroll(_ he: Bool) -> String {
        he ? "השאלה ממשיכה למטה. תגלול קצת ותגיד תמשיך." : "The question goes on below. Scroll down a bit and say go on."
    }
    static func resume(_ q: String, _ label: String, he: Bool) -> String {
        he ? "עצרנו בשאלה \(q), \(part(label, he: true)). נמשיך משם?" : "We stopped at question \(q), \(part(label, he: false)). Shall we pick up there?"
    }
    static func stopped(_ q: String, _ label: String, pdf: URL?, he: Bool) -> String {
        let file = pdf.map { he ? " הפתרון עד עכשיו נשמר ב-\($0.deletingLastPathComponent().lastPathComponent)." : " What we've solved so far is in \($0.lastPathComponent), in \($0.deletingLastPathComponent().lastPathComponent)." } ?? ""
        return he ? "בסדר, נעצור כאן. שמרתי איפה אנחנו, שאלה \(q), \(part(label, he: true)).\(file)"
                  : "Okay, let's stop here. I saved where we are, question \(q), \(part(label, he: false)).\(file)"
    }
    static func allDone(_ he: Bool) -> String { he ? "סיימנו את כל הסעיפים ששמרתי. כל הכבוד!" : "That's every part we have. Nice work!" }
    static func pdfAt(_ url: URL, he: Bool) -> String {
        he ? "הקובץ נקרא \(url.deletingPathExtension().lastPathComponent), בתיקייה \(url.deletingLastPathComponent().lastPathComponent)."
           : "It's \(url.deletingPathExtension().lastPathComponent), in \(url.deletingLastPathComponent().lastPathComponent)."
    }
    static func pdfOpening(_ he: Bool) -> String { he ? "פותח אותו." : "Opening it." }
    static func pdfNone(_ he: Bool) -> String { he ? "עוד אין מה לשים בקובץ. נסיים סעיף קודם." : "There's nothing in it yet. Let's finish a part first." }
    static func include(_ i: StudyPart.Include, _ label: String, he: Bool) -> String {
        switch i {
        case .mine: return he ? "בסדר, בקובץ של \(part(label, he: true)) יהיה הפתרון שלך." : "Okay, \(part(label, he: false)) in the PDF will be your own work."
        case .poinky: return he ? "בסדר, בקובץ של \(part(label, he: true)) יהיה הפתרון שלי." : "Okay, \(part(label, he: false)) in the PDF will be my worked solution."
        case .both, .auto: return he ? "בסדר, שניהם ייכנסו." : "Okay, both go in."
        }
    }
    static func noPhoto(_ he: Bool) -> String {
        he ? "אני לא רואה את הפתרון שלך. תשלח תמונה, או תפתח אותו על המסך ותגיד שוב תבדוק."
           : "I can't see your work. Send a photo, or open it on screen and say check my work again."
    }
    static func onPart(_ q: String, _ label: String, _ status: String, he: Bool) -> String {
        he ? "אנחנו בשאלה \(q), \(part(label, he: true)). \(status)" : "We're on question \(q), \(part(label, he: false)). \(status)"
    }
}

// MARK: - The teacher's study replies

/// Pulls Poinky's own blocks out of the teacher's stream (`<question>{json}</question>`, `<verdict …>…</verdict>`,
/// `<pass/>`) and passes everything else on to `ArtistStream` unchanged.
final class StudyStream {
    private(set) var raw = ""
    private var held = ""
    private(set) var question: [String: Any]?
    private(set) var questionError: String?
    private(set) var verdict: (result: String, line: Int?, note: String)?
    private(set) var passed = false
    var onQuestion: (([String: Any]) -> Void)?

    private static let blocks = [("<question>", "</question>"), ("<verdict", "</verdict>"), ("<pass", "/>")]

    /// Returns what the drawing pipeline should see of this delta.
    func feed(_ delta: String) -> String {
        raw += delta
        held += delta
        var out = ""
        while !held.isEmpty {
            guard let lt = held.firstIndex(of: "<") else { out += held; held = ""; break }
            out += held[..<lt]
            held = String(held[lt...])
            // Maybe the start of one of ours: wait for more text.
            if Self.blocks.contains(where: { $0.0.hasPrefix(held) && held.count < $0.0.count }) { break }
            guard let (open, close) = Self.blocks.first(where: { held.hasPrefix($0.0) }) else {
                out += "<"; held.removeFirst(); continue
            }
            guard let end = held.range(of: close) else { break }   // the block isn't finished yet
            let block = String(held[..<end.upperBound])
            held = String(held[end.upperBound...])
            take(open: open, block: block)
        }
        return out
    }

    func finish() -> String { let rest = held; held = ""; return rest.hasPrefix("<question") || rest.hasPrefix("<verdict") ? "" : rest }

    private func take(open: String, block: String) {
        switch open {
        case "<question>":
            let inner = String(block.dropFirst("<question>".count).dropLast("</question>".count))
            let json = JSONRepair.clean(inner.trimmingCharacters(in: .whitespacesAndNewlines)) ?? inner
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
                questionError = "unreadable"; return
            }
            if let e = obj["error"] as? String { questionError = e; return }
            question = obj
            onQuestion?(obj)
        case "<verdict":
            guard let gt = block.firstIndex(of: ">") else { return }
            let attrs = String(block[..<gt])
            let note = String(block[block.index(after: gt)...].dropLast("</verdict>".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let result = Self.attr("result", attrs) ?? "unknown"
            verdict = (result.lowercased(), Self.attr("line", attrs).flatMap { Int($0) }, note)
        default:
            passed = true
        }
    }

    static func attr(_ name: String, _ s: String) -> String? {
        guard let r = s.range(of: name + "=\""), let e = s[r.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(s[r.upperBound..<e])
    }

    /// The question block as a `StudyQuestion` (nil when it has no parts or no statement).
    static func question(from o: [String: Any], number: String?) -> StudyQuestion? {
        func str(_ k: String) -> String { (o[k] as? String) ?? (o[k].map { "\($0)" } ?? "") }
        let parts = (o["parts"] as? [[String: Any]] ?? []).compactMap { p -> StudyPart? in
            let label = (p["label"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " .)("))
            let text = p["text"] as? String ?? ""
            guard !label.isEmpty || !text.isEmpty else { return nil }
            return StudyPart(label: label.isEmpty ? "?" : label, text: text, say: p["say"] as? String ?? text)
        }
        let statement = str("statement")
        guard !statement.isEmpty || !parts.isEmpty else { return nil }
        var answers: [String: String] = [:]
        for (k, v) in o["finalAnswers"] as? [String: Any] ?? [:] { answers[k] = "\(v)" }
        return StudyQuestion(number: str("number").isEmpty ? (number ?? "1") : str("number"), title: str("title"), statement: statement,
                             givens: (o["givens"] as? [Any] ?? []).map { "\($0)" }, figure: str("figure"),
                             parts: parts.isEmpty ? [StudyPart(label: "", text: statement, say: "")] : parts, finalAnswers: answers)
    }

    /// The solver's reply: `<part label="א">…<answer>…</answer><confidence>…</confidence></part>` for each part.
    static func solutions(_ text: String) -> [String: (work: String, answer: String, confidence: String)] {
        var out: [String: (String, String, String)] = [:]
        var rest = Substring(text)
        while let open = rest.range(of: "<part"), let gt = rest[open.upperBound...].firstIndex(of: ">"),
              let close = rest[gt...].range(of: "</part>") {
            let label = attr("label", String(rest[open.lowerBound..<gt])) ?? ""
            let body = String(rest[rest.index(after: gt)..<close.lowerBound])
            func inner(_ tag: String) -> String {
                guard let a = body.range(of: "<\(tag)>"), let b = body.range(of: "</\(tag)>", range: a.upperBound..<body.endIndex) else { return "" }
                return String(body[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            out[label.trimmingCharacters(in: .whitespaces)] = (body.trimmingCharacters(in: .whitespacesAndNewlines), inner("answer"), inner("confidence"))
            rest = rest[close.upperBound...]
        }
        return out
    }
}

// MARK: - The messages (built in code from the saved state, so a fresh teacher after a restart knows it all)

enum StudyBrief {
    enum Kind: String { case present, hint, solve, check, fix, fixHint = "fix-hint", ask }

    static func language(_ code: String) -> String { code == "he" ? "Hebrew" : code == "en" ? "English" : code }

    /// The state block every study message starts with.
    static func state(_ s: StudySheet, reference: Bool) -> [String] {
        var l = ["Sheet: \(s.title.isEmpty ? "(untitled)" : s.title), written in \(language(s.language)). The user speaks \(language(s.userLanguage)): speak \(language(s.userLanguage)), keep the sheet's terms and symbols."]
        guard let q = s.question else { return l }
        l.append("Question \(q.number)\(q.title.isEmpty ? "" : " (\(q.title))"): \(q.statement)")
        if !q.givens.isEmpty { l.append("Given: " + q.givens.joined(separator: "; ")) }
        if !q.figure.isEmpty { l.append("Figure: \(q.figure)") }
        l.append("Parts:")
        for (i, p) in q.parts.enumerated() {
            var st = "\(p.status.rawValue)"
            if p.hints > 0 { st += ", \(p.hints) hint\(p.hints == 1 ? "" : "s") given" }
            for a in p.attempts { st += ", attempt: \(a.verdict)\(a.line.map { " at their line \($0)" } ?? "")\(a.note.isEmpty ? "" : " (\(a.note))")" }
            l.append("- \(p.label): \(p.text) [\(st)]\(i == s.part ? "  ← CURRENT PART" : "")")
        }
        if reference, let p = s.currentPart {
            if let r = p.reference {
                l.append("Reference solution for part \(p.label) (worked out separately and checked; hidden from the user, use it to be right):\n\(r)")
            } else {
                l.append("(No reference solution for this part yet: work it out carefully yourself before you say anything about it.)")
            }
            if let a = q.finalAnswers[p.label], !a.isEmpty { l.append("The sheet itself prints this final answer for part \(p.label): \(a)") }
        }
        return l
    }

    static func message(_ kind: Kind, sheet s: StudySheet, number: String? = nil, said: String = "", paperBottom: Int? = nil,
                        newPaper: Bool = false, pdfPages: Int = 0, note: String? = nil) -> String {
        var l = ["STUDY: \(kind.rawValue)"]
        switch kind {
        case .present:
            l.append("Read question \(number ?? "1") from the images\(pdfPages > 0 ? " (the screenshot, then \(pdfPages) clean render\(pdfPages == 1 ? "" : "s") of the sheet's PDF page\(pdfPages == 1 ? "" : "s"))" : "").")
            l.append("The user speaks \(language(s.userLanguage)): write each part's \"say\" and your lesson in \(language(s.userLanguage)).")
            if !said.isEmpty { l.append("User said: \"\(said)\"") }
            l.append("New paper. Present the question only: the setup, the givens, the figure. Stop before the parts.")
            return l.joined(separator: "\n")
        default: break
        }
        l += state(s, reference: kind != .ask || true)
        if !said.isEmpty { l.append("User said: \"\(said)\"") }
        let p = s.currentPart
        switch kind {
        case .hint:
            let level = (p?.hints ?? 0) + 1
            l.append("Give hint \(level) of 3 for the current part (\(level == 1 ? "the principle or approach only" : level == 2 ? "set up the governing equation(s), don't solve" : "the next step from where they are, then stop")).")
        case .solve: l.append("Show the full worked solution of the current part.")
        case .check:
            l.append("The user's own work for the current part is in the last image\(note == nil ? "" : " (\(note!))"). Check it line by line.")
        case .fix: l.append("The user wants the corrected continuation of their attempt: continue from their last right line and finish the part.")
        case .fixHint: l.append("Give one hint that helps them fix their wrong step themselves.")
        case .ask: l.append("The user asked this during the session. Answer it (or write only <pass/> if it isn't about the homework).")
        case .present: break
        }
        if newPaper {
            l.append("Start a new paper: <lesson title=\"…\"> (not continue).")
        } else {
            l.append("Continue the open paper: <lesson title=\"…\" continue=\"true\">\(paperBottom.map { ", below y≈\($0)" } ?? "") (use newpage if it's full).")
        }
        return l.joined(separator: "\n")
    }

    /// For the solver: the question as read, and what the sheet says.
    static func solverMessage(_ q: StudyQuestion, sheet s: StudySheet, images: Int) -> String {
        var l = ["Solve question \(q.number) completely. The images are the sheet (\(images) image\(images == 1 ? "" : "s")).",
                 "The question as read from the sheet: \(q.statement)"]
        if !q.givens.isEmpty { l.append("Given: " + q.givens.joined(separator: "; ")) }
        if !q.figure.isEmpty { l.append("Figure: \(q.figure)") }
        l.append("Parts:")
        for p in q.parts { l.append("- \(p.label): \(p.text)") }
        if !q.finalAnswers.isEmpty { l.append("Final answers printed on the sheet: " + q.finalAnswers.map { "\($0.key): \($0.value)" }.joined(separator: "; ")) }
        l.append("Write the derivations in \(language(s.language == "he" ? "en" : s.language)) with the sheet's symbols.")
        return l.joined(separator: "\n")
    }
}

// MARK: - The entry point for photos of your work

/// The study session everyone talks to: the iPhone capture (and `--study-photo`) hands photos of the
/// user's own work to `checkWork`. The flow runs in `CallController+Study.swift`.
@MainActor
final class StudySession {
    static let shared = StudySession()

    var sheet: StudySheet? { didSet { if let s = sheet, s != oldValue { var t = s; t.updated = Date(); StudyStore.save(t) } } }
    var activeCall = -1               // the voice session the study session runs in
    var awaiting: StudyAwaiting = .nothing
    var teacher: Brain?               // the study teacher: artist prompt + study prompt, thinks
    var solver: Brain?                // solves each question once, hidden, before any hint or check
    var solving: [String: Task<Void, Never>] = [:]   // by question number
    var teacherBusy = false
    var working = false               // waiting on the solver or the teacher (tests: not quiet yet)
    var paperTag: String?             // the part the open paper belongs to
    var gen = 0                       // changes when a teacher job is cut off
    var pendingPhoto: URL?            // a photo waiting for the session to start
    var pendingNote: String?
    var lastShot: Snapshot?
    weak var driver: CallController?

    /// A photo of the user's handwritten work (the iPhone capture calls this; also `--study-photo`).
    /// Starts a session if none is running, and checks the work against the current part.
    func checkWork(image: NSImage, note: String? = nil) {
        guard let data = StudySource.jpeg(image, maxSide: 3000) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poinky-work-\(UUID().uuidString).jpg")
        guard (try? data.write(to: url)) != nil else { return }
        checkWork(file: url, note: note)
    }

    func checkWork(file: URL, note: String? = nil) {
        pendingPhoto = file
        pendingNote = note
        driver?.askTyped(sheet?.userLanguage == "he" ? "תבדוק את הפתרון שלי" : "check my work")
    }

    /// Takes the waiting photo (once).
    func takePhoto() -> (URL, String?)? {
        guard let p = pendingPhoto else { return nil }
        pendingPhoto = nil
        defer { pendingNote = nil }
        return (p, pendingNote)
    }

    func isActive(call: Int) -> Bool { sheet != nil && activeCall == call }

    /// Brains: the teacher uses the artist's model with the study instructions added and thinks before it
    /// answers (correctness over speed); the solver uses the strongest model, thinking hard.
    static func teacherBrain(_ config: AppConfig) -> Brain? {
        let env = ProcessInfo.processInfo.environment
        var prompt = SystemPrompt.load(.artist)
        prompt += "\n\n" + Self.prompt("study-prompt")
        let model = env["POINKY_STUDY_MODEL"] ?? config.model(for: .artist)
        let chosen = config.effort(for: .artist)
        let effort = env["POINKY_STUDY_EFFORT"] ?? (chosen.isEmpty ? "medium" : chosen)
        return make(config, model: model, effort: effort, prompt: prompt, artist: true)
    }

    static func solverBrain(_ config: AppConfig) -> Brain? {
        let env = ProcessInfo.processInfo.environment
        let model = env["POINKY_STUDY_SOLVER_MODEL"] ?? (config.brain == .claudeCode ? "claude-opus-5-5" : config.model(for: .artist))
        return make(config, model: model, effort: env["POINKY_STUDY_SOLVER_EFFORT"] ?? "high", prompt: Self.prompt("study-solver-prompt"), artist: false)
    }

    private static func make(_ config: AppConfig, model: String, effort: String, prompt: String, artist: Bool) -> Brain? {
        switch config.brain {
        case .claudeCode:
            return ClaudeCodeBrain(model: model, effort: effort, claudePath: config.claudePath, systemPrompt: prompt)
        case .api:
            let key = config.apiKey.isEmpty ? (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "") : config.apiKey
            guard !key.isEmpty else { return nil }
            return APIBrain(model: model, effort: effort, apiKey: key, systemPrompt: prompt, maxTokens: 32000)
        }
    }

    static func prompt(_ name: String) -> String {
        let override = AppConfig.dir.appendingPathComponent("\(name).md")
        if let s = try? String(contentsOf: override, encoding: .utf8), !s.isEmpty { return s }
        if let url = Bundle.main.url(forResource: name, withExtension: "md"), let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return ""
    }

    /// Ends the brains (the session's state stays on disk).
    func endBrains() {
        teacher?.stop(); teacher = nil
        solver?.stop(); solver = nil
        for t in solving.values { t.cancel() }
        solving.removeAll()
        teacherBusy = false
    }
}
