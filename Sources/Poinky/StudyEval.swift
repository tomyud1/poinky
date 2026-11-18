import AppKit

/// Developer check of a study session with the real models and the real prompts and messages, but no screen,
/// mic or overlay: `Poinky --study-eval <outdir> <sheet.pdf|.png> <en|he> <step>…`
///   steps: present[:N]  hint  solve  fix  fixhint  ask:<words>  check:<photo>  part:<label or index>
/// Writes each teacher reply (NN-kind.txt), every reply of a part in order (part-<label>.txt, for
/// tools/lesson-shots.mjs), the solver's reply (solver-N.txt), timings (times.txt) and the state (state.json).
@MainActor
enum StudyEval {
    static func run(_ args: [String]) async {
        guard args.count >= 3 else { print("usage: --study-eval <outdir> <sheet> <en|he> <step>…"); exit(2) }
        let out = URL(fileURLWithPath: args[0], isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let file = URL(fileURLWithPath: args[1])
        let lang = args[2]
        let steps = Array(args.dropFirst(3))
        let config = AppConfig.load()
        guard let teacher = StudySession.teacherBrain(config), let solver = StudySession.solverBrain(config) else { print("no brain"); exit(1) }
        var sheet = StudySheet(id: "eval", title: file.deletingPathExtension().lastPathComponent,
                               document: StudySource.isPDF(file) ? file.path : nil, userLanguage: lang)
        var shot: String? = nil
        if !StudySource.isPDF(file), let img = NSImage(contentsOf: file) { shot = StudySource.jpeg(img, maxSide: 1568)?.base64EncodedString() }
        var n = 0
        var times: [String] = []
        var said = ""
        var solverTask: Task<Void, Never>?
        func log(_ s: String) { print(s); times.append(s) }
        func save(_ kind: String, _ text: String) {
            n += 1
            try? text.write(to: out.appendingPathComponent(String(format: "%02d-%@.txt", n, kind)), atomically: true, encoding: .utf8)
            let label = sheet.currentPart?.label ?? "q"
            let partFile = out.appendingPathComponent("part-\(label.isEmpty ? "q" : label).txt")
            let old = (try? String(contentsOf: partFile, encoding: .utf8)) ?? ""
            try? (old + "\n" + text).write(to: partFile, atomically: true, encoding: .utf8)
        }
        func ask(_ brain: Brain, _ text: String, images: [String]) async -> (String, StudyStream) {
            let stream = StudyStream()
            let t0 = Date()
            var first: Double?
            let reply = (try? await brain.ask(BrainQuestion(text: text, snapshot: nil, extraImages: images)) { d in
                if first == nil, !d.isEmpty { first = Date().timeIntervalSince(t0) }
                _ = stream.feed(d)
            }) ?? "(failed)"
            _ = stream.finish()
            log(String(format: "  first text %.1fs, total %.1fs, %d chars", first ?? -1, Date().timeIntervalSince(t0), reply.count))
            return (reply, stream)
        }
        let context = ["Screenshot size: 1512x982 px (coordinates use this size).", "Nothing is drawn on screen right now.",
                       "Paper room: 800 units wide, about 900 units tall before it runs out of space (use newpage for more)."]
        var paperOpen = false, paperTag = ""
        for step in steps {
            let (cmd, arg) = step.split(separator: ":", maxSplits: 1).map(String.init).splitPair
            log("== \(step)")
            switch cmd {
            case "say": said = arg
            case "present":
                var pages: [Int] = [], images: [String] = []
                if StudySource.isPDF(file) {
                    pages = StudySource.questionPages(file, number: arg.isEmpty ? nil : arg)
                    if pages.isEmpty { pages = [0] }
                    images = pages.compactMap { StudySource.pageImage(file, page: $0) }
                }
                let msg = StudyBrief.message(.present, sheet: sheet, number: arg.isEmpty ? nil : arg, said: said, pdfPages: StudySource.isPDF(file) ? images.count : 0)
                    + "\n" + context.joined(separator: "\n")
                let (reply, stream) = await ask(teacher, msg, images: (shot.map { [$0] } ?? []) + images)
                guard let o = stream.question, var q = StudyStream.question(from: o, number: arg) else {
                    log("  NO QUESTION: \(stream.questionError ?? "")"); save("present", reply); continue
                }
                q.sourcePages = pages
                if let l = o["language"] as? String { sheet.language = l }
                sheet.questions.append(q); sheet.current = sheet.questions.count - 1; sheet.part = 0
                save("present", reply)
                log("  question \(q.number): \(q.parts.map(\.label)) complete=\(o["complete"] ?? "?")")
                paperOpen = true; paperTag = "0"
                // The solver, as the app starts it (in the background).
                var simages: [String] = shot.map { [$0] } ?? []
                if StudySource.isPDF(file) {
                    let ps = (pages + StudySource.answerPages(file)).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
                    simages = ps.prefix(4).compactMap { StudySource.pageImage(file, page: $0) }
                }
                let smsg = StudyBrief.solverMessage(q, sheet: sheet, images: simages.count)
                let qi = sheet.current
                solverTask = Task { @MainActor in
                    let t0 = Date()
                    let reply = (try? await solver.ask(BrainQuestion(text: smsg, snapshot: nil, extraImages: simages)) { _ in }) ?? "(failed)"
                    try? reply.write(to: out.appendingPathComponent("solver-\(q.number).txt"), atomically: true, encoding: .utf8)
                    let sols = StudyStream.solutions(reply)
                    for (pi, p) in sheet.questions[qi].parts.enumerated() {
                        guard let s = sols[p.label] ?? (sheet.questions[qi].parts.count == 1 ? sols.values.first : nil) else { continue }
                        sheet.questions[qi].parts[pi].reference = s.work
                        sheet.questions[qi].parts[pi].answer = s.answer
                        sheet.questions[qi].parts[pi].confidence = s.confidence
                    }
                    log(String(format: "  (solver done in %.0fs: %d parts)", Date().timeIntervalSince(t0), sols.count))
                }
            case "part":
                if let q = sheet.question, let i = CallController.partIndex(arg, in: q) ?? Int(arg) { sheet.part = i }
            case "hint", "solve", "fix", "fixhint", "ask", "check":
                let kind: StudyBrief.Kind = cmd == "hint" ? .hint : cmd == "solve" ? .solve : cmd == "fix" ? .fix : cmd == "fixhint" ? .fixHint : cmd == "ask" ? .ask : .check
                let needsRef = kind != .ask && !(kind == .hint && (sheet.currentPart?.hints ?? 0) == 0)
                if needsRef, let t = solverTask { await t.value }
                var images: [String] = []
                var note: String?
                if kind == .check {
                    // check:<photo>[,<photo>…]: pages of one piece of work, cleaned as the app does.
                    for (k, path) in arg.split(separator: ",").enumerated() {
                        let url = URL(fileURLWithPath: String(path))
                        guard let (clean, kept) = StudySource.cleanPhotoInfo(url, flat: url.pathExtension.lowercased() == "pdf"),
                              let data = StudySource.jpeg(clean, maxSide: 1568) else { continue }
                        images.append(data.base64EncodedString())
                        try? data.write(to: out.appendingPathComponent("photo-\(n + 1)-\(k + 1).jpg"))
                        if kept < 0.45, let orig = PhotoFiles.forClaude(url) { images.append(orig); note = "a photo whose page took up little of it is also sent uncropped, right after its cleaned copy" }
                    }
                } else if kind == .ask { said = arg } else if !shot.isNil { images = [] }
                let tag = "\(sheet.current)-\(sheet.part)"
                let newPaper = !paperOpen || paperTag != tag && !(paperTag == "0" && sheet.part == 0)
                paperOpen = true; paperTag = tag
                let msg = StudyBrief.message(kind, sheet: sheet, said: said, newPaper: newPaper, note: note, photos: max(1, images.count)) + "\n" + context.joined(separator: "\n")
                let (reply, stream) = await ask(teacher, msg, images: images)
                save(cmd, reply)
                said = ""
                switch kind {
                case .hint, .fixHint: sheet.update { $0.hints += 1 }
                case .solve, .fix: sheet.update { if $0.status != .solvedByUser { $0.status = .shown } }
                case .check:
                    let v = stream.verdict ?? (result: "none", line: nil, note: "")
                    log("  VERDICT \(v.result) line \(v.line.map(String.init) ?? "-"): \(v.note)")
                    sheet.update { $0.attempts.append(StudyAttempt(at: Date(), image: nil, verdict: v.result, line: v.line, note: v.note)) }
                case .ask: if stream.passed { log("  PASSED to the talker") }
                case .present: break
                }
            default: log("  unknown step")
            }
        }
        if let t = solverTask { await t.value }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try? enc.encode(sheet).write(to: out.appendingPathComponent("state.json"))
        try? times.joined(separator: "\n").write(to: out.appendingPathComponent("times.txt"), atomically: true, encoding: .utf8)
        teacher.stop(); solver.stop()
        exit(0)
    }
}

private extension Array where Element == String {
    var splitPair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}
private extension Optional {
    var isNil: Bool { self == nil }
}
