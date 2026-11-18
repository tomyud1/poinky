import Foundation

/// What the teacher (the `artist` role) said and showed for one question, and how it ended, so that the talker's
/// next message, the session summary, the conversation log (and so `<recall>`), the daily note and the teacher's own
/// next message all agree about it. The teacher usually ends after the talker's turn did, so its side is written
/// down when it ends: all its lines heard (finished), you talked over it or asked something else (interrupted),
/// an error (failed), or the session ended first. `CallController` feeds it from the teacher's stream and the
/// voice (`onSentenceStarted` tags); nothing here calls a model.
struct TeacherLesson {
    enum End: String { case finished, interrupted, failed, sessionEnded = "cut off by the end of the session" }

    let id: Int
    let turn: Int            // the question it answers (`CallController.turn`)
    let question: String
    var title = ""           // the paper's title (<lesson title>)
    var models: [String] = []   // 3D models it built or stepped through
    var lines: [(text: String, tag: Int)] = []
    var heardTags: Set<Int> = []
    /// Paper and 3D steps, by the line they go with (-1: before the first line).
    var stepsAfter: [Int: Int] = [:]
    var notes: [String] = []     // the 3D step notes beside a model
    var written = false          // the teacher finished writing it
    var end: End?
    var toldTalker = 0           // heard lines the talker was told about
    var toldTalkerEnd = false
    var toldTeacher = false

    var heard: [String] { lines.filter { heardTags.contains($0.tag) }.map(\.text) }
    var allHeard: Bool { lines.allSatisfy { heardTags.contains($0.tag) } }
    /// Steps that were drawn: those before the first line and those of the lines that were heard.
    var stepsShown: Int {
        var n = stepsAfter[-1] ?? 0
        for (i, l) in lines.enumerated() where heardTags.contains(l.tag) { n += stepsAfter[i] ?? 0 }
        return n
    }
    var stepsWritten: Int { stepsAfter.values.reduce(0, +) }

    /// "the lesson “checking number one” on the paper", "the 3D model “heart”".
    var what: String {
        if !models.isEmpty, title.isEmpty { return "the 3D model “\(models.joined(separator: "”, “"))”" }
        if !title.isEmpty { return "the lesson “\(title)” on the paper" + (models.isEmpty ? "" : " and the 3D model “\(models[0])”") }
        return stepsWritten > 0 ? "a sketch on the paper" : "a spoken explanation"
    }

    /// "finished, 5 steps", "interrupted after 3 of its 6 lines, 3 steps drawn".
    var state: String {
        let shown = stepsShown
        let steps = shown == 1 ? "1 step" : "\(shown) steps"
        switch end {
        case .finished?: return "finished, \(steps)"
        case .failed?: return heard.isEmpty ? "failed before it began" : "failed after \(heard.count) of its lines, \(steps) drawn"
        case .interrupted?, .sessionEnded?:
            let why = end == .interrupted ? "interrupted" : end!.rawValue
            if heard.isEmpty { return "\(why) before its first line" }
            return "\(why) after \(heard.count) of its \(max(lines.count, heard.count)) lines\(written ? "" : " written so far"), \(steps) drawn"
        case nil: return "still going: \(heard.count) lines heard so far, \(steps) drawn"
        }
    }

    /// The heard lines, joined, at most `max` characters: the first and the last ones kept when it's long
    /// (a lesson's conclusion is usually its last line).
    static func joined(_ lines: [String], max: Int) -> String {
        let quoted = lines.map { "«\(clip($0, 220))»" }
        var all = quoted.joined(separator: " ")
        guard all.count > max, quoted.count > 2 else { return clip(all, max) }
        var head = [quoted[0]], tail: [String] = []
        var room = max - quoted[0].count - 8
        for q in quoted.dropFirst().reversed() {
            guard q.count + 1 <= room else { break }
            tail.insert(q, at: 0); room -= q.count + 1
        }
        let skipped = quoted.count - 1 - tail.count
        if skipped > 0 { head.append("(…\(skipped) more…)") }
        all = (head + tail).joined(separator: " ")
        return clip(all, max)
    }

    /// For the record (conversation log, summary, daily note): what it was, how it ended, what was said.
    func digest(max: Int = 600) -> String {
        var s = "\(what), \(state)"
        if !notes.isEmpty { s += "; steps: " + notes.prefix(6).joined(separator: " / ") }
        let said = heard
        if !said.isEmpty { s += ". Said: " + Self.joined(said, max: Swift.max(120, max - s.count - 8)) }
        return Self.clip(s, max)
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count > n ? String(t.prefix(n - 1)) + "…" : t
    }
}

/// The teacher's lessons of this session (newest last) and the ending rules; see `TeacherLesson`.
@MainActor
final class TeacherLog {
    private(set) var lessons: [TeacherLesson] = []
    private var nextID = 0
    /// A lesson ended (once each): CallController writes it into the record.
    var onEnd: ((TeacherLesson) -> Void)?
    static let maxKept = 12

    func reset() { lessons.removeAll() }

    private func index(_ id: Int?) -> Int? { id.flatMap { id in lessons.firstIndex { $0.id == id } } }

    @discardableResult
    func begin(turn: Int, question: String) -> Int {
        nextID += 1
        lessons.append(TeacherLesson(id: nextID, turn: turn, question: question))
        if lessons.count > Self.maxKept { lessons.removeFirst(lessons.count - Self.maxKept) }
        return nextID
    }

    func title(_ id: Int?, _ t: String) {
        guard let i = index(id), !t.isEmpty, lessons[i].title.isEmpty else { return }
        lessons[i].title = t
    }
    func line(_ id: Int?, _ text: String, tag: Int) { if let i = index(id) { lessons[i].lines.append((text, tag)) } }
    /// A paper or 3D step (with the line written last).
    func step(_ id: Int?, model: String? = nil, note: String? = nil) {
        guard let i = index(id) else { return }
        lessons[i].stepsAfter[lessons[i].lines.count - 1, default: 0] += 1
        if let m = model, !m.isEmpty, !lessons[i].models.contains(m) { lessons[i].models.append(m) }
        if let n = note, !n.isEmpty, lessons[i].notes.count < 12 { lessons[i].notes.append(n) }
    }
    func model(_ id: Int?, _ name: String) {
        guard let i = index(id), !name.isEmpty, !lessons[i].models.contains(name) else { return }
        lessons[i].models.append(name)
    }

    /// A line started playing.
    func heard(tag: Int) {
        guard let i = lessons.lastIndex(where: { l in l.end == nil && l.lines.contains { $0.tag == tag } }) else { return }
        lessons[i].heardTags.insert(tag)
        if lessons[i].written, lessons[i].allHeard { finish(i, .finished) }
    }

    /// The teacher finished writing (`ok` false: it failed).
    func written(_ id: Int?, ok: Bool) {
        guard let i = index(id), lessons[i].end == nil else { return }
        lessons[i].written = true
        if !ok { finish(i, .failed) } else if lessons[i].allHeard { finish(i, .finished) }
    }

    /// The voice went quiet: lessons that were completely written are done (a line whose voice failed still
    /// had its steps drawn by `finishedSpeaking`).
    func speechDone() {
        for i in lessons.indices where lessons[i].end == nil && lessons[i].written {
            for l in lessons[i].lines { lessons[i].heardTags.insert(l.tag) }
            finish(i, .finished)
        }
    }

    /// You talked over it or asked something else: whatever isn't done ends here.
    func interrupt() { for i in lessons.indices where lessons[i].end == nil { finish(i, .interrupted) } }
    func endSession() { for i in lessons.indices where lessons[i].end == nil { finish(i, .sessionEnded) } }

    func isOpen(turn: Int) -> Bool { lessons.contains { $0.turn == turn && $0.end == nil } }
    func lesson(_ id: Int) -> TeacherLesson? { index(id).map { lessons[$0] } }

    private func finish(_ i: Int, _ end: TeacherLesson.End) {
        lessons[i].end = end
        onEnd?(lessons[i])
    }

    /// For the talker's next message: what the teacher said since the talker last heard about it, in the
    /// talker's own voice (the user hears one Poinky), capped. Nil when there's nothing new.
    func talkerNews(max: Int = 700) -> String? {
        var parts: [String] = []
        for i in lessons.indices {
            let l = lessons[i]
            let said = l.heard
            let newLines = Array(said.dropFirst(l.toldTalker))
            let endNews = l.end != nil && !l.toldTalkerEnd
            guard !newLines.isEmpty || endNews else { continue }
            guard !(said.isEmpty && l.end == .interrupted && l.stepsShown == 0) else {   // nothing reached the user
                lessons[i].toldTalkerEnd = true; continue
            }
            var s = "\(l.what) for “\(TeacherLesson.clip(l.question, 80))” (\(l.state))"
            if !newLines.isEmpty { s += (l.toldTalker > 0 ? ", then said: " : ", said: ") + TeacherLesson.joined(newLines, max: 420) }
            parts.append(s)
            lessons[i].toldTalker = said.count
            lessons[i].toldTalkerEnd = l.end != nil
        }
        guard !parts.isEmpty else { return nil }
        let body = TeacherLesson.clip(parts.suffix(2).joined(separator: " Also "), max)
        return "(What you just showed and said in your sketch, which the user saw and heard in your voice, so it is part of your answer: \(body). Build on it and keep to it; if you now think something in it was wrong, say plainly that you're correcting it.)"
    }

    /// For the teacher's next brief: its last lesson didn't finish (cut off or failed), once.
    func teacherNews() -> String? {
        guard let i = lessons.lastIndex(where: { $0.end != nil }), !lessons[i].toldTeacher else { return nil }
        lessons[i].toldTeacher = true
        let l = lessons[i]
        switch l.end {
        case .interrupted?, .sessionEnded?:
            let said = l.heard
            guard !said.isEmpty || l.stepsShown > 0 else {
                return "(Your last answer, for “\(TeacherLesson.clip(l.question, 80))”, was dropped before the user heard any of it: they asked something else.)"
            }
            var s = "(Your last lesson, \(l.what), was cut off: the user interrupted after hearing \(said.count) of the \(l.lines.count) lines you wrote"
            if let last = said.last { s += "; the last one they heard: «\(TeacherLesson.clip(last, 200))»" }
            s += ". What's on the paper or model is what went with those lines (\(l.stepsShown) of \(l.stepsWritten) steps); nothing after that was said or drawn."
            s += " If they now want more of it (\"continue\", \"and the next step?\", \"go on\"), pick up right there on the same paper (<lesson continue=\"true\">) or model, without repeating what they heard. If they ask about something else, answer that.)"
            return s
        case .failed?:
            return "(Your last lesson, for “\(TeacherLesson.clip(l.question, 80))”, failed with an error after \(l.heard.count) lines; the user heard that the drawing didn't work.)"
        default:
            return nil
        }
    }
}
