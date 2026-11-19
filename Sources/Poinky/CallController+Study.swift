import AppKit

/// A study session's teacher job, run by `runArtist` like any lesson: its own brain (the study teacher), the
/// sheet's pages or a photo as extra images, and a tap that takes Poinky's blocks (`<question>`, `<verdict>`,
/// `<pass/>`) out of the stream before the pen and voice see it.
struct StudyJob {
    let brain: Brain
    var images: [String] = []
    var sendShot = true
    let tap: (String) -> String
    let finish: () -> String
    let done: (Bool) -> Void
}

/// Working through homework together (StudySession.swift has the state and the words; this is the flow).
///
///   "let's do this homework together" → the question is read once (the teacher returns its parts as data,
///   from the PDF's own pages when the sheet is a file) and presented without its parts → part א is shown and
///   Poinky waits: a question, "a hint" (three levels), "I'll try it", a photo or "check my work", "show me"
///   → when the part is done, "shall we go on?" → the solved PDF grows after every finished part.
///
/// Routing is done here in code from the session's state and plain phrases; only what needs judgment goes
/// to the teacher. A solver (the strongest model, thinking) works out every part in the background as soon
/// as the question is read, and hints, checks and full solutions wait for it, so nothing is judged by
/// plausibility.
extension CallController {
    private var study: StudySession { StudySession.shared }

    /// Study papers are always light paper: they go into a PDF that's printed.
    var studyPaperLook: String? { study.isActive(call: studyCall) ? "paper" : nil }

    // MARK: Hooks

    /// What you said (or typed), before the talker sees it. True when the study session took it.
    func studyHeard(_ text: String) -> Bool {
        study.driver = self
        if let (photo, note) = study.takePhoto() {
            studyCheck(photo: photo, note: note, said: text)
            return true
        }
        guard study.isActive(call: studyCall) else {
            if case .start(let q, let fresh)? = StudyIntent.start(text) {
                studyStart(question: q, fresh: fresh, said: text)
                return true
            }
            return false
        }
        studySetQuestion(text)
        if let lang = Self.language(of: text), study.sheet?.userLanguage != lang { study.sheet?.userLanguage = lang }
        // "Let's do question 2 together" during a session: go there.
        if case .start(let q?, _)? = StudyIntent.start(text), q != study.sheet?.question?.number {
            studyGoTo(question: q, part: nil, said: text)
            return true
        }
        let intent = StudyIntent.classify(text, awaiting: study.awaiting)
        Timeline.log("study.heard", ["intent": intent.map { "\($0)" } ?? "ask", "awaiting": study.awaiting.rawValue])
        // A teacher reply still being written is dropped for whatever comes next.
        if intent != .hush, intent != .whereAreWe, study.teacherBusy || studyTeacherBusy { studyStopLesson() }
        let he = (study.sheet?.userLanguage ?? "en") == "he"
        switch intent {
        case .hush?: return true
        case .stop?: studyStop(said: text)
        case .hint?: studyHint(said: text)
        case .tryIt?:
            study.sheet?.update { $0.status = .trying }
            study.awaiting = .working
            studyStatus(he ? "תורך" : "your turn")
            studySayNow(StudyWords.tryIt(he), said: text)
        case .check?: studyCheck(photo: nil, note: nil, said: text)
        case .show?:
            if study.awaiting == .afterWrong { studyTeach(.fix, said: text) } else { studyTeach(.solve, said: text) }
        case .next?: studyNext(said: text)
        case .skip?:
            study.sheet?.update { $0.status = .skipped }
            studyNext(said: text)
        case .repeatPart?: studyPresentPart(newPaper: !studyPaperOpen, said: text, again: true)
        case .whereAreWe?:
            if let s = study.sheet, let q = s.question, let p = s.currentPart {
                let status = p.done ? (he ? "הוא גמור." : "It's done.") : p.hints > 0 ? (he ? "קיבלת \(p.hints) רמזים." : "You've had \(p.hints) hint\(p.hints == 1 ? "" : "s").") : ""
                studySayNow(StudyWords.onPart(q.number, p.label, status, he: he), said: text)
            }
        case .goTo(let part, let question)?: studyGoTo(question: question, part: part, said: text)
        case .openPDF?: studyPDF(open: true, said: text)
        case .wherePDF?, .savePDF?: studyPDF(open: false, said: text)
        case .include(let what)?:
            // The part just finished (or this one).
            guard var s = study.sheet else { return true }
            if let q = s.question, !(s.currentPart?.done ?? false), s.part > 0, q.parts[s.part - 1].done { s.part -= 1 }
            let label = s.currentPart?.label ?? ""
            study.sheet?.questions[s.current].parts[s.part].include = what
            studySayNow(StudyWords.include(what, label, he: he), said: text)
            studyRebuildPDF()
        case .yes?:
            switch study.awaiting {
            case .nextPart, .nextQuestion: studyNext(said: text)
            case .resume: studyPresentPart(newPaper: true, said: text)
            case .afterWrong: studyTeach(.fix, said: text)
            case .scroll: studyRead(number: study.sheet?.question?.number, said: text, snap: nil, quiet: false)
            case .working, .clarify, .nothing, .choice: studyTeach(.ask, said: text)
            }
        case .no?:
            switch study.awaiting {
            case .nextPart, .nextQuestion:
                study.awaiting = .nothing
                studySayNow(he ? "בסדר. מה תרצה לעשות?" : "Okay. What would you like to do?", said: text)
            case .resume:
                study.awaiting = .nothing
                studySayNow(he ? "בסדר. איזו שאלה נעשה?" : "Okay. Which question shall we do?", said: text)
            case .choice: studySayNow(StudyWords.choiceAgain(he), said: text)
            default: studyTeach(.ask, said: text)
            }
        case .start?:
            studyPresentPart(newPaper: true, said: text)
        case nil:
            if study.awaiting == .scroll, ["go on", "continue", "תמשיך", "המשך"].contains(where: { text.lowercased().contains($0) }) {
                studyRead(number: study.sheet?.question?.number, said: text, snap: nil, quiet: false)
            } else {
                studyTeach(.ask, said: text)
            }
        }
        return true
    }

    /// The talker's `<study q="2"/>`: it heard a wish to work through the sheet that the phrases above missed.
    func studyTalkerTag(_ reply: String, said: String) {
        guard !study.isActive(call: studyCall),
              let r = reply.range(of: #"<study(\s+[^>]*)?/?>"#, options: .regularExpression) else { return }
        let tag = String(reply[r])
        let q = StudyStream.attr("q", tag).flatMap { $0.isEmpty ? nil : $0 }
        // After the talker's own line ("Sure, let's go through it.").
        DispatchQueue.main.async { [weak self] in self?.studyStart(question: q, fresh: tag.contains("fresh=\"true\""), said: said, quiet: true) }
    }

    /// For the talker: a saved session on the sheet in front (so "let's go on" can pick it up).
    func studyTalkerLines() -> [String] {
        guard !study.isActive(call: studyCall) else { return [] }
        let f = studyFront
        guard f.document != nil || !f.page.isEmpty || !f.window.isEmpty else { return [] }
        let id = StudyStore.id(document: f.document, page: f.page, window: f.window)
        guard let s = StudyStore.load(id), let q = s.question, let p = s.currentPart, s.unfinished else { return [] }
        return ["(A homework session on this sheet is saved: question \(q.number), part \(p.label) is next. If the user wants to go on with it or to work through the sheet together, write <study/> and one short line.)"]
    }

    func studyLessonStopped() {
        guard study.teacherBusy else { return }
        study.gen += 1
        study.teacher?.cancelCurrent()
    }

    func studySessionEnded() {
        guard study.activeCall >= 0 else { return }
        study.gen += 1
        study.activeCall = -1
        study.teacherBusy = false
        study.working = false
        studyTag("")
        study.teacher?.stop()
        study.teacher = nil
        // (The solver finishes what it's solving and saves it; then it stops.)
        if study.solving.isEmpty { study.solver?.stop(); study.solver = nil }
    }

    // MARK: Starting

    static func language(of text: String) -> String? {
        let he = text.unicodeScalars.filter { (0x0590...0x05FF).contains($0.value) }.count
        let latin = text.unicodeScalars.filter { ("a"..."z").contains(Character($0)) || ("A"..."Z").contains(Character($0)) }.count
        if he == 0 && latin == 0 { return nil }
        return he >= latin ? "he" : "en"
    }

    func studyStart(question: String?, fresh: Bool, said: String, quiet: Bool = false) {
        let s = study
        s.driver = self
        overlay.onStudyPDF = { [weak self] in self?.studyPDF(open: true, said: "") }
        s.activeCall = studyCall
        s.awaiting = .nothing
        s.working = true
        let lang = Self.language(of: said) ?? "en"
        let myGen = s.gen
        if !quiet { studySay(StudyWords.reading(lang == "he")) }
        Timeline.log("study.start", ["question": question ?? "", "fresh": fresh])
        Task { @MainActor in
            guard let snap = try? await self.studyCapture(), myGen == s.gen else {
                s.working = false
                if myGen == s.gen { s.activeCall = -1; self.studySay(lang == "he" ? "סליחה, לא הצלחתי לראות את המסך." : "Sorry, I couldn't see the screen.") }
                return
            }
            s.lastShot = snap
            var f = self.studyFront
            // Tests: the sheet's file, whatever is in front (the fake brain doesn't look at the screen).
            if let doc = ProcessInfo.processInfo.environment["POINKY_STUDY_DOCUMENT"] { f.document = URL(fileURLWithPath: doc) }
            let id = StudyStore.id(document: f.document, page: f.page, window: f.window)
            var sheet = fresh ? nil : StudyStore.load(id)
            // "Let's continue the homework" with no sheet in front: the last one.
            if sheet == nil, !fresh, f.document == nil || !StudySource.isPDF(f.document), question == nil,
               ["continue", "pick up", "back to", "נמשיך", "להמשיך"].contains(where: { said.lowercased().contains($0) }) {
                sheet = StudyStore.all().first(where: \.unfinished)
            }
            if sheet == nil {
                let doc = f.document.flatMap { StudySource.isPDF($0) || StudySource.isImage($0) ? $0.path : nil }
                let title = f.document?.deletingPathExtension().lastPathComponent ?? (f.window.isEmpty ? f.app : f.window)
                sheet = StudySheet(id: id, title: title, document: doc, page: f.page.isEmpty ? nil : f.page, userLanguage: lang)
            }
            sheet!.userLanguage = lang
            s.sheet = sheet
            let he = lang == "he"
            if let q = question, let qi = sheet!.questions.firstIndex(where: { $0.number == q }) {
                // That question was read before: straight to its first open part.
                s.sheet?.current = qi
                s.sheet?.part = sheet!.questions[qi].parts.firstIndex(where: { !$0.done }) ?? 0
                s.working = false
                if sheet!.questions[qi].parts.contains(where: { $0.reference == nil }) { self.studySolve(qi) }
                self.studyPresentPart(newPaper: true, said: said)
                return
            }
            if question == nil, sheet!.question != nil, sheet!.unfinished {
                // Where we were: the first part that isn't done (in this question, else the next one read).
                if sheet!.currentPart?.done ?? true {
                    if let pi = sheet!.question!.parts.firstIndex(where: { !$0.done }) { sheet!.part = pi }
                    else if let qi = sheet!.questions.firstIndex(where: { $0.parts.contains { !$0.done } }) {
                        sheet!.current = qi; sheet!.part = sheet!.questions[qi].parts.firstIndex(where: { !$0.done }) ?? 0
                    }
                    s.sheet = sheet
                }
                let q = sheet!.question!, p = sheet!.currentPart!
                s.working = false
                s.awaiting = .resume
                if q.parts.contains(where: { $0.reference == nil }) { self.studySolve(sheet!.current) }
                self.studySay(StudyWords.resume(q.number, p.label, he: he))
                return
            }
            let next = question ?? (sheet!.questions.isEmpty ? nil : String((sheet!.questions.compactMap { Int($0.number) }.max() ?? 0) + 1))
            self.studyRead(number: next, said: said, snap: snap, quiet: true)
        }
    }

    /// Reads question `number` (nil: the one in view) and presents it, without its parts.
    func studyRead(number: String?, said: String, snap given: Snapshot?, quiet: Bool) {
        let s = study
        guard s.sheet != nil else { return }
        s.working = true
        let myGen = s.gen
        let he = s.sheet!.userLanguage == "he"
        if !quiet { studySay(StudyWords.reading(he)) }
        Task { @MainActor in
            var snap = given
            if snap == nil { snap = try? await self.studyCapture() }
            guard let snap, myGen == s.gen, var sheet = s.sheet else { s.working = false; return }
            if s.teacher == nil { s.teacher = StudySession.teacherBrain(self.studyConfig) }
            guard let teacher = s.teacher else { s.working = false; self.studySay("I couldn't start the teacher."); return }
            // The question's own pages, sharp, when the sheet is a PDF file.
            var pages: [Int] = []
            var images: [String] = []
            if let doc = sheet.document.map(URL.init(fileURLWithPath:)), StudySource.isPDF(doc) {
                pages = StudySource.questionPages(doc, number: number)
                images = pages.compactMap { StudySource.pageImage(doc, page: $0) }
            }
            let stream = StudyStream()
            stream.onQuestion = { [weak self] obj in
                guard let self, myGen == s.gen, var q = StudyStream.question(from: obj, number: number) else { return }
                q.sourcePages = pages
                if let lang = obj["language"] as? String, ["he", "en"].contains(lang) { sheet.language = lang }
                if pages.isEmpty, let data = Data(base64Encoded: snap.jpegBase64) {
                    q.shot = StudyStore.write(data, name: "q\(q.number)-sheet.jpg", sheet: sheet.id)
                }
                if let i = sheet.questions.firstIndex(where: { $0.number == q.number }) {
                    // Read again: keep what was done on parts with the same label.
                    for (pi, p) in q.parts.enumerated() {
                        if let old = sheet.questions[i].parts.first(where: { $0.label == p.label }) {
                            q.parts[pi].status = old.status; q.parts[pi].hints = old.hints; q.parts[pi].attempts = old.attempts
                            q.parts[pi].pages = old.pages; q.parts[pi].include = old.include
                        }
                    }
                    sheet.questions[i] = q
                    sheet.current = i
                } else {
                    sheet.questions.append(q)
                    sheet.questions.sort { (Int($0.number) ?? 99) < (Int($1.number) ?? 99) }
                    sheet.current = sheet.questions.firstIndex(where: { $0.number == q.number }) ?? 0
                }
                sheet.part = 0
                s.sheet = sheet
                self.studyTag(sheet.tag(sheet.current, 0))
                // The sheet's own figure (cropped from the PDF page the teacher named): shown on the paper as it is,
                // instead of a re-drawing (`figure` op in lesson.js).
                self.studyFigure(nil)
                if let doc = sheet.document.map(URL.init(fileURLWithPath:)), let fb = obj["figureBox"] as? [String: Any],
                   let n = (fb["page"] as? NSNumber)?.intValue, pages.indices.contains(n - 1),
                   let v = (fb["box"] as? [Any])?.compactMap({ ($0 as? NSNumber).map { CGFloat($0.doubleValue) } }), v.count == 4,
                   let fig = StudySource.figure(doc, page: pages[n - 1], box: CGRect(x: v[0], y: v[1], width: v[2], height: v[3])) {
                    self.studyFigure(fig)
                }
                // Keep the paper off the question on screen.
                if let b = obj["box"] as? [Any], b.count == 4 {
                    let v = b.compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } }
                    if v.count == 4, v[2] > 20, v[3] > 20 { self.studyFocus(CGRect(x: v[0] / snap.scale, y: v[1] / snap.scale, width: v[2] / snap.scale, height: v[3] / snap.scale)) }
                }
                self.studySolve(sheet.current)
            }
            let text = (StudyBrief.message(.present, sheet: sheet, number: number, said: said, pdfPages: images.count)
                        + "\n" + self.studyContext(snap).joined(separator: "\n"))
            let job = StudyJob(brain: teacher, images: images, sendShot: true, tap: stream.feed, finish: stream.finish) { [weak self] ok in
                guard let self else { return }
                s.teacherBusy = false
                s.working = false
                guard myGen == s.gen else { return }
                let he = (s.sheet?.userLanguage ?? "en") == "he"
                if stream.questionError != nil || (stream.question == nil && ok) {
                    Timeline.log("study.noQuestion", ["why": stream.questionError ?? "no block"])
                    self.studySay(StudyWords.noSheet(he))
                    if s.sheet?.questions.isEmpty ?? true { s.activeCall = -1 }
                    return
                }
                guard stream.question != nil else {
                    self.studySay(he ? "סליחה, לא הצלחתי לקרוא את השאלה. ננסה שוב?" : "Sorry, I couldn't read the question. Shall we try again?")
                    return
                }
                self.studyKeepPages()
                if (stream.question?["complete"] as? Bool) == false, pages.isEmpty {
                    s.awaiting = .scroll
                    self.studySay(StudyWords.scroll(he))
                    return
                }
                self.studyPresentPart(newPaper: false, said: "")
            }
            s.teacherBusy = true
            self.studyReceipt(BrainQuestion(text: text, snapshot: snap, extraImages: images), said: said, snap: snap,
                              note: images.isEmpty ? "Study session: the teacher read the question from the screenshot"
                                                   : "Study session: the teacher read the question from \(images.count) page\(images.count == 1 ? "" : "s") of \(sheet.document.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "the sheet")")
            self.studyRun(text, snapshot: snap, job: job)
        }
    }

    // MARK: Parts

    /// Shows the current part on the paper and says what it asks, then waits (no model).
    func studyPresentPart(newPaper: Bool, said: String, again: Bool = false) {
        let s = study
        guard let sheet = s.sheet, let q = sheet.question, let p = sheet.currentPart, let snap = s.lastShot else { return }
        let he = sheet.userLanguage == "he", rtl = sheet.hebrew
        let tag = sheet.tag(sheet.current, sheet.part)
        studyTag(tag)
        if p.status == .waiting { s.sheet?.update { $0.status = .presented } }
        let name = p.label.isEmpty ? "" : StudyWords.part(p.label, he: he)
        let intro = p.label.isEmpty ? (he ? "הנה מה ששואלים: \(p.say)" : "Here's what it asks: \(p.say)") : "\(name.prefix(1).uppercased() + name.dropFirst()): \(p.say)"
        var ops: [[String: Any]] = []
        let head = p.label.isEmpty ? (rtl ? "מה שואלים" : "What it asks") : (rtl ? "סעיף \(p.label)" : "Part \(p.label)")
        ops.append(rtl ? ["op": "text", "id": "\(tag)-h", "x": 760, "align": "right", "text": head, "size": 28, "bold": true, "color": "blue"]
                       : ["op": "text", "id": "\(tag)-h", "x": 40, "text": head, "size": 28, "bold": true, "color": "blue"])
        for (i, line) in Self.wrap(p.text, width: rtl ? 54 : 58).enumerated() {
            ops.append(rtl ? ["op": "text", "id": "\(tag)-t\(i)", "x": 760, "align": "right", "text": line, "size": 23, "math": false]
                           : ["op": "text", "id": "\(tag)-t\(i)", "x": 40, "text": line, "size": 23, "math": false])
        }
        let turn = he ? "תורך: לנסות לבד · רמז · „תראה לי”" : "Your turn: try it · a hint · \u{201C}show me\u{201D}"
        let turnOp: [String: Any] = rtl || he ? ["op": "text", "id": "\(tag)-turn", "x": 760, "align": "right", "text": turn, "size": 18, "color": "gray"]
                                              : ["op": "text", "id": "\(tag)-turn", "x": 40, "text": turn, "size": 18, "color": "gray"]
        let title = sheet.hebrew ? "שאלה \(q.number)\(p.label.isEmpty ? "" : " · סעיף \(p.label)")" : "Question \(q.number)\(p.label.isEmpty ? "" : " · part \(p.label)")"
        let json = { (o: [[String: Any]]) -> String in
            String(data: (try? JSONSerialization.data(withJSONObject: ["ops": o])) ?? Data(), encoding: .utf8) ?? "{\"ops\":[]}"
        }
        studyDraw([.lessonStart(title: title, continuing: !newPaper), .say(intro), .step(json(ops)),
                   .say(StudyWords.choice(he)), .step(json([turnOp])), .lessonEnd], snapshot: snap)
        if !said.isEmpty { studyLog(said, intro + " " + StudyWords.choice(he), note: "study: presented part \(p.label)") }
        s.paperTag = tag
        s.awaiting = .choice
        studyStatus(he ? "תורך" : "your turn")
        if !again { studyKeepPages(after: 2) }
    }

    /// Splits a part's words into lines that fit the paper (about `width` characters).
    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = [], cur = ""
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if cur.isEmpty { cur = String(word) } else if cur.count + 1 + word.count <= width { cur += " " + word } else { lines.append(cur); cur = String(word) }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines.isEmpty ? [text] : lines
    }

    func studyNext(said: String) {
        let s = study
        guard let sheet = s.sheet, let q = sheet.question else { return }
        let he = sheet.userLanguage == "he"
        studyRebuildPDF()
        if s.awaiting == .nextQuestion || sheet.part + 1 >= q.parts.count {
            if s.awaiting == .nextQuestion || sheet.currentPart?.done == true || sheet.part + 1 >= q.parts.count {
                guard s.awaiting == .nextQuestion else {
                    s.awaiting = .nextQuestion
                    studySayNow(StudyWords.lastPart(q.number, he: he), said: said)
                    return
                }
                let n = String((Int(q.number) ?? 0) + 1)
                studyGoTo(question: n, part: nil, said: said)
                return
            }
        }
        s.sheet?.part += 1
        studyPresentPart(newPaper: true, said: said)
    }

    func studyGoTo(question: String?, part: String?, said: String) {
        let s = study
        guard var sheet = s.sheet else { return }
        if var qn = question {
            if qn == "+1" { qn = String((Int(sheet.question?.number ?? "0") ?? 0) + 1) }
            if let qi = sheet.questions.firstIndex(where: { $0.number == qn }) {
                sheet.current = qi
                sheet.part = Self.partIndex(part, in: sheet.questions[qi]) ?? sheet.questions[qi].parts.firstIndex(where: { !$0.done }) ?? 0
                s.sheet = sheet
                studyPresentPart(newPaper: true, said: said)
            } else {
                studyStopLesson()
                studyRead(number: qn, said: said, snap: nil, quiet: false)
            }
            return
        }
        guard let q = sheet.question, let pi = Self.partIndex(part, in: q) else {
            studyTeach(.ask, said: said); return
        }
        s.sheet?.part = pi
        studyPresentPart(newPaper: true, said: said)
    }

    /// "b", "ב", "#2" → the part's index.
    static func partIndex(_ said: String?, in q: StudyQuestion) -> Int? {
        guard let said else { return nil }
        if said.hasPrefix("#"), let n = Int(said.dropFirst()), q.parts.indices.contains(n - 1) { return n - 1 }
        if let i = q.parts.firstIndex(where: { $0.label.lowercased() == said.lowercased() }) { return i }
        // Hebrew sheet, English letter (or the other way round): by position.
        let he = ["א", "ב", "ג", "ד", "ה", "ו", "ז", "ח"], en = ["a", "b", "c", "d", "e", "f", "g", "h"]
        if let i = en.firstIndex(of: said.lowercased()) ?? he.firstIndex(of: said), q.parts.indices.contains(i) { return i }
        return nil
    }

    // MARK: The teacher's tasks

    func studyHint(said: String) {
        guard let p = study.sheet?.currentPart else { return }
        let he = (study.sheet?.userLanguage ?? "en") == "he"
        if p.hints >= 3 {
            studySayNow(he ? "נתתי כבר שלושה רמזים. רוצה לנסות, או שאראה לך את הפתרון?" : "You've had all three hints. Want to try it, or shall I show you the solution?", said: said)
            study.awaiting = .choice
            return
        }
        studyTeach(study.awaiting == .afterWrong ? .fixHint : .hint, said: said)
    }

    /// Runs one teacher task on the current part: waits for the solver's reference first when it matters.
    func studyTeach(_ kind: StudyBrief.Kind, said: String, image: String? = nil, imageName: String? = nil, note: String? = nil) {
        let s = study
        guard let sheet0 = s.sheet, sheet0.question != nil else {
            // No question yet (it couldn't be read): read it now.
            if s.sheet != nil { studyRead(number: nil, said: said, snap: nil, quiet: false) }
            return
        }
        let he = sheet0.userLanguage == "he"
        let needsReference = kind != .ask && !(kind == .hint && (sheet0.currentPart?.hints ?? 0) == 0)
        let myGen = s.gen
        s.working = true
        Task { @MainActor in
            // The solver first: hints past the first, checks and full solutions go by its worked solution.
            if needsReference, s.sheet?.currentPart?.reference == nil, let number = s.sheet?.question?.number {
                if s.solving[number] == nil { self.studySolve(s.sheet!.current) }
                if let task = s.solving[number] {
                    self.studySay(StudyWords.workingOut(he))
                    self.overlay.setClaudeCaption("✎ …")
                    _ = try? await Deadline.run(Self.solverWait, "The study solver") { await task.value }
                }
            }
            guard myGen == s.gen, var sheet = s.sheet else { s.working = false; return }
            if s.teacher == nil { s.teacher = StudySession.teacherBrain(self.studyConfig) }
            guard let teacher = s.teacher else { s.working = false; return }
            let snap: Snapshot
            if let fresh = try? await self.studyCapture() { snap = fresh } else if let old = s.lastShot { snap = old } else { s.working = false; return }
            guard myGen == s.gen else { s.working = false; return }
            s.lastShot = snap
            sheet = s.sheet ?? sheet
            let tag = sheet.tag(sheet.current, sheet.part)
            let newPaper = !self.studyPaperOpen || s.paperTag != tag
            // The "your turn" line has done its job: it doesn't go into the PDF.
            if !newPaper { self.overlay.lessonStep(#"{"ops":[{"op":"erase","ids":["\#(tag)-turn"]}]}"#, scale: snap.scale) }
            self.studyTag(tag)
            s.paperTag = tag
            var text = StudyBrief.message(kind, sheet: sheet, said: said, newPaper: newPaper, note: note)
            text += "\n" + self.studyContext(snap).joined(separator: "\n")
            let stream = StudyStream()
            let qi = sheet.current, pi = sheet.part
            let job = StudyJob(brain: teacher, images: image.map { [$0] } ?? [], sendShot: image == nil,
                               tap: stream.feed, finish: stream.finish) { [weak self] ok in
                guard let self else { return }
                s.teacherBusy = false
                s.working = false
                guard myGen == s.gen else { return }
                if stream.passed {
                    // Not about the homework: the talker answers it as usual.
                    self.studyAskTalker(said)
                    return
                }
                guard ok else {
                    self.studySay(he ? "סליחה, משהו השתבש. ננסה שוב?" : "Sorry, something went wrong there. Shall we try again?")
                    return
                }
                self.studyAfter(kind, stream: stream, qi: qi, pi: pi, imageName: imageName)
            }
            s.teacherBusy = true
            self.studyReceipt(BrainQuestion(text: text, snapshot: image == nil ? snap : nil, extraImages: image.map { [$0] } ?? []),
                              said: said, snap: snap, note: image == nil ? "Study session (\(kind.rawValue)): the teacher got the screenshot"
                                                                         : "Study session: the teacher got the photo of your work")
            Timeline.log("study.teach", ["kind": kind.rawValue, "reference": s.sheet?.currentPart?.reference != nil, "newPaper": newPaper])
            self.studyRun(text, snapshot: snap, job: job)
        }
    }
    static var solverWait: Double { ProcessInfo.processInfo.environment["POINKY_STUDY_SOLVER_WAIT"].flatMap(Double.init) ?? 240 }

    /// After a teacher task: what it means for the part, and what Poinky asks next.
    private func studyAfter(_ kind: StudyBrief.Kind, stream: StudyStream, qi: Int, pi: Int, imageName: String?) {
        let s = study
        guard var sheet = s.sheet, sheet.questions.indices.contains(qi), sheet.questions[qi].parts.indices.contains(pi) else { return }
        let he = sheet.userLanguage == "he"
        var part = sheet.questions[qi].parts[pi]
        let nextLabel = sheet.questions[qi].parts.indices.contains(pi + 1) ? sheet.questions[qi].parts[pi + 1].label : nil
        let goOn = { nextLabel.map { StudyWords.goOn($0, he: he) } ?? StudyWords.lastPart(sheet.questions[qi].number, he: he) }
        var line: String?
        switch kind {
        case .hint, .fixHint:
            part.hints += 1
            line = part.hints >= 3 ? StudyWords.lastHint(he) : StudyWords.moreHint(he)
            s.awaiting = .choice
        case .solve, .fix:
            if part.status != .solvedByUser { part.status = .shown }
            line = goOn()
            s.awaiting = nextLabel == nil ? .nextQuestion : .nextPart
        case .check:
            let v = stream.verdict ?? (result: "unknown", line: nil, note: "")
            part.attempts.append(StudyAttempt(at: Date(), image: imageName, verdict: v.result, line: v.line, note: v.note))
            Timeline.log("study.verdict", ["result": v.result, "line": v.line ?? 0])
            switch v.result {
            case "right":
                part.status = .solvedByUser
                line = goOn()
                s.awaiting = nextLabel == nil ? .nextQuestion : .nextPart
            case "wrong":
                line = StudyWords.afterWrong(he)
                s.awaiting = .afterWrong
            case "unreadable":
                s.awaiting = .clarify   // the teacher asked about the line it couldn't read
            case "unfinished":
                line = StudyWords.keepGoing(he)
                s.awaiting = .working
            default:
                s.awaiting = .choice
            }
        case .ask, .present:
            break
        }
        sheet.questions[qi].parts[pi] = part
        s.sheet = sheet
        if let line { studySay(line) }
        studyStatus(part.done ? (he ? "✓ גמור" : "✓ done") : s.awaiting == .afterWrong ? (he ? "לתקן" : "fix it") : (he ? "תורך" : "your turn"))
        studyKeepPages(rebuild: part.done)
    }

    /// "Check my work": a photo (the iPhone, `--study-photo`), an image open in front, or what's on screen.
    func studyCheck(photo: URL?, note: String?, said: String) {
        let s = study
        if !s.isActive(call: studyCall) {
            // A photo with no session running: pick up the sheet in front, else the last one.
            let id = StudyStore.id(document: studyFront.document, page: studyFront.page, window: studyFront.window)
            guard let sheet = StudyStore.load(id) ?? StudyStore.all().first, sheet.question != nil else {
                studySayNow(StudyWords.noSheet(Self.language(of: said) == "he"), said: said)
                return
            }
            s.sheet = sheet
            s.activeCall = studyCall
            s.driver = self
            overlay.onStudyPDF = { [weak self] in self?.studyPDF(open: true, said: "") }
        }
        guard let sheet = s.sheet else { return }
        let file = photo ?? studyFront.document.flatMap { StudySource.isImage($0) ? $0 : nil }
        var b64: String?, name: String?
        if let file, let clean = StudySource.cleanPhoto(file) {
            let n = (sheet.currentPart?.attempts.count ?? 0) + 1
            let base = "\(sheet.tag(sheet.current, sheet.part))-mine-\(n)"
            if let big = StudySource.jpeg(clean, maxSide: 2400, quality: 0.8) { name = StudyStore.write(big, name: base + ".jpg", sheet: sheet.id) }
            b64 = StudySource.jpeg(clean, maxSide: 1568, quality: 0.85)?.base64EncodedString()
        }
        Timeline.log("study.check", ["photo": b64 != nil])
        if s.lastShot == nil {
            Task { @MainActor in
                s.lastShot = try? await self.studyCapture()
                self.studyTeach(.check, said: said, image: b64, imageName: name, note: note)
            }
        } else {
            studyTeach(.check, said: said, image: b64, imageName: name, note: note)
        }
    }

    // MARK: The solver (hidden)

    func studySolve(_ qi: Int) {
        let s = study
        guard let sheet = s.sheet, sheet.questions.indices.contains(qi) else { return }
        let q = sheet.questions[qi]
        guard s.solving[q.number] == nil, q.parts.contains(where: { $0.reference == nil }) else { return }
        if s.solver == nil { s.solver = StudySession.solverBrain(studyConfig) }
        guard let solver = s.solver else { return }
        var images: [String] = []
        if let doc = sheet.document.map(URL.init(fileURLWithPath:)), StudySource.isPDF(doc) {
            let pages = (q.sourcePages + StudySource.answerPages(doc)).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
            images = pages.prefix(4).compactMap { StudySource.pageImage(doc, page: $0) }
        }
        if images.isEmpty, let shot = s.lastShot { images = [shot.jpegBase64] }
        let text = StudyBrief.solverMessage(q, sheet: sheet, images: images.count)
        let sheetID = sheet.id, number = q.number
        let started = ProcessInfo.processInfo.systemUptime
        Timeline.log("study.solve", ["question": number])
        s.solving[number] = Task { @MainActor in
            defer {
                s.solving[number] = nil
                if s.activeCall < 0, s.solving.isEmpty { s.solver?.stop(); s.solver = nil }
            }
            do {
                let reply = try await solver.ask(BrainQuestion(text: text, snapshot: nil, extraImages: images)) { _ in }
                Self.rawLog(role: "study-solver", text: reply)
                let sols = StudyStream.solutions(reply)
                guard var sheet = s.sheet, sheet.id == sheetID, let qi = sheet.questions.firstIndex(where: { $0.number == number }) else { return }
                for (pi, p) in sheet.questions[qi].parts.enumerated() {
                    let sol = sols[p.label] ?? (sols.count == sheet.questions[qi].parts.count ? Array(sols.values)[pi] : nil)
                        ?? (sheet.questions[qi].parts.count == 1 ? sols.values.first : nil)
                    guard let sol else { continue }
                    sheet.questions[qi].parts[pi].reference = sol.work
                    sheet.questions[qi].parts[pi].answer = sol.answer
                    sheet.questions[qi].parts[pi].confidence = sol.confidence
                }
                s.sheet = sheet
                Timeline.log("study.solved", ["question": number, "parts": sols.count, "secs": Int(ProcessInfo.processInfo.systemUptime - started)])
            } catch {
                Timeline.log("study.solveFailed", ["question": number, "why": error.localizedDescription])
            }
        }
    }

    static func rawLog(role: String, text: String) {
        guard let path = ProcessInfo.processInfo.environment["POINKY_RAW_LOG"] else { return }
        let line = (try? JSONSerialization.data(withJSONObject: ["t": Date().timeIntervalSince1970, "role": role, "text": text])) ?? Data()
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line + Data([0x0A])); h.closeFile() }
        else { FileManager.default.createFile(atPath: path, contents: line + Data([0x0A])) }
    }

    // MARK: Papers, the PDF, stopping

    /// The paper's study tag (which part what's drawn next belongs to) and its quiet status.
    func studyFigure(_ f: (dataURL: String, aspect: CGFloat)?) {
        overlay.evaluateForTest("SB.studyFigure && SB.studyFigure(\(Self.js(f?.dataURL ?? "")), \(f.map { Double($0.aspect) } ?? 0))")
    }
    func studyTag(_ tag: String) { overlay.evaluateForTest("SB.studyTag && SB.studyTag(\(Self.js(tag)))") }
    func studyStatus(_ text: String) { overlay.evaluateForTest("SB.studyStatus && SB.studyStatus(\(Self.js(text)))") }
    static func js(_ s: String) -> String {
        String(data: (try? JSONSerialization.data(withJSONObject: [s])) ?? Data(), encoding: .utf8).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }

    /// Once the drawing is done: keeps this part's papers as pictures in the sheet's folder (they survive
    /// the session ending, a restart, days), then rebuilds the PDF if the part is finished.
    func studyKeepPages(after delay: Double = 0, rebuild: Bool = false) {
        let s = study
        guard let sheet = s.sheet else { return }
        let qi = sheet.current, pi = sheet.part, tag = sheet.tag(qi, pi), call = studyCall, id = sheet.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64((delay + 0.3) * 1e9))
            let started = ProcessInfo.processInfo.systemUptime
            // Wait until the teacher is done, its lines heard and the pen still.
            while self.studyCall == call, ProcessInfo.processInfo.systemUptime - started < 240 {
                if !self.studyTeacherBusy, !self.studySpeaking, (await self.studyJS("SB.lessonBusy ? SB.lessonBusy() : false") as? Bool) != true { break }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            guard self.studyCall == call else { return }
            _ = await self.studyJS("window.__studyPics = null; SB.studyPictures && SB.studyPictures(\(Self.js(tag))).then(r => { window.__studyPics = JSON.stringify(r) }); true")
            for _ in 0..<40 {
                if let json = await self.studyJS("window.__studyPics") as? String {
                    self.studySavePictures(json, tag: tag, call: call, sheet: id, qi: qi, pi: pi, rebuild: rebuild)
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func studyJS(_ script: String) async -> Any? {
        await withCheckedContinuation { c in overlay.evaluateForTest(script) { r in c.resume(returning: r) } }
    }

    private func studySavePictures(_ json: String, tag: String, call: Int, sheet id: String, qi: Int, pi: Int, rebuild: Bool) {
        let s = study
        guard let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]],
              var sheet = s.sheet, sheet.id == id, sheet.questions.indices.contains(qi), sheet.questions[qi].parts.indices.contains(pi) else { return }
        let prefix = "\(tag)-s\(call)-"
        var names: [String] = []
        for (i, p) in list.enumerated() {
            guard let png = p["png"] as? String, let comma = png.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(png[png.index(after: comma)...])),
                  let name = StudyStore.write(data, name: "\(prefix)\(i + 1).png", sheet: id) else { continue }
            names.append(name)
        }
        var pages = sheet.questions[qi].parts[pi].pages.filter { !$0.hasPrefix(prefix) }
        pages += names
        sheet.questions[qi].parts[pi].pages = pages
        s.sheet = sheet
        Timeline.log("study.pages", ["tag": tag, "pages": names.count])
        if rebuild { studyRebuildPDF() }
    }

    func studyRebuildPDF(then: ((URL?) -> Void)? = nil) {
        guard let sheet = study.sheet, StudyPDF.hasContent(sheet) else { then?(nil); return }
        let target = StudyPDF.outputURL(sheet)
        Task.detached(priority: .utility) {
            let url = StudyPDF.build(sheet, to: target)
            await MainActor.run {
                if let url, StudySession.shared.sheet?.id == sheet.id { StudySession.shared.sheet?.output = url.path }
                Timeline.log("study.pdf", ["ok": url != nil])
                then?(url)
            }
        }
    }

    func studyPDF(open: Bool, said: String) {
        let he = (study.sheet?.userLanguage ?? "en") == "he"
        studyRebuildPDF { [weak self] url in
            guard let self else { return }
            guard let url else { self.studySayNow(StudyWords.pdfNone(he), said: said); return }
            if open { NSWorkspace.shared.open(url) }
            self.studySayNow(open ? StudyWords.pdfOpening(he) : StudyWords.pdfAt(url, he: he), said: said)
        }
    }

    func studyStop(said: String) {
        let s = study
        guard let sheet = s.sheet, let q = sheet.question else { s.activeCall = -1; return }
        let he = sheet.userLanguage == "he"
        let label = sheet.currentPart?.label ?? ""
        s.awaiting = .nothing
        studyRebuildPDF { [weak self] url in
            guard let self else { return }
            self.studySayNow(StudyWords.stopped(q.number, label, pdf: url, he: he), said: said)
            s.gen += 1
            s.activeCall = -1
            s.teacher?.stop(); s.teacher = nil
            self.studyTag("")
        }
    }
}
