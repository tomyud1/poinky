import Foundation

// tools/test-record.sh: the shared record of what Poinky said and showed (TeacherRecord.swift, CarryOver.swift).
var failed = 0
func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
    print((ok ? "ok   " : "FAIL ") + what + (ok ? "" : "  (\(detail()))"))
    if !ok { failed += 1 }
}

@MainActor func run() {
    // r01: the teacher says answer 1 is wrong; the talker must hear that before "wait why is it wrong".
    let log = TeacherLog()
    var ended: [TeacherLesson] = []
    log.onEnd = { ended.append($0) }
    let id = log.begin(turn: 3, question: "is my answer right for number one")
    log.title(id, "checking number one")
    let r01 = ["Your factoring is right, but the last line has a sign slip.",
               "Factoring is correct: two numbers that multiply to 6 and add to negative 5.",
               "Now each bracket equals zero, so x minus 2 is zero, and x minus 3 is zero.",
               "You wrote negative 2 and negative 3, but the signs flip when you move the number over.",
               "The correct answer is x equals 2 or x equals 3."]
    for (i, l) in r01.enumerated() { log.line(id, l, tag: 10 + i); log.step(id) }
    check(log.isOpen(turn: 3), "a lesson being written is open")
    let mid = log.talkerNews() ?? ""
    check(mid.isEmpty, "nothing heard yet: nothing for the talker", mid)
    log.heard(tag: 10); log.heard(tag: 11)
    let partial = log.talkerNews() ?? ""
    check(partial.contains("still going") && partial.contains("sign slip"), "heard so far, while it goes on", partial)
    log.written(id, ok: true)
    check(ended.isEmpty, "written but not all heard: not ended yet")
    for t in 12...14 { log.heard(tag: t) }
    check(ended.count == 1 && ended[0].end == .finished, "all lines heard: finished", "\(ended.map { $0.end?.rawValue ?? "" })")
    let d = ended.first?.digest() ?? ""
    check(d.contains("“checking number one”") && d.contains("finished, 5 steps") && d.contains("sign slip") && d.contains("x equals 2 or x equals 3"),
          "the digest has the title, the end state, the first and the last line", d)
    let news = log.talkerNews() ?? ""
    check(news.contains("then said") && news.contains("x equals 2 or x equals 3") && !news.contains("sign slip") && news.contains("finished"),
          "the talker then hears the rest and the end, not again what it was told", news)
    check(news.contains("Never contradict it silently") && news.contains("no apology"), "and is told to keep to it, never contradicting it silently", news)
    check(log.talkerNews() == nil, "once")
    check(log.teacherNews() == nil, "a finished lesson isn't news for the teacher")

    // Interrupted after 3 of 6 lines (holding the keys mid-lesson).
    let id2 = log.begin(turn: 5, question: "explain how the heart works")
    log.title(id2, "the heart")
    for i in 0..<6 { log.line(id2, "Heart line \(i + 1).", tag: 30 + i); log.step(id2) }
    for t in 30...32 { log.heard(tag: t) }
    log.interrupt()
    check(ended.last?.end == .interrupted && ended.last?.heard.count == 3, "interrupted: ended at the third line")
    let tn = log.teacherNews() ?? ""
    check(tn.contains("cut off") && tn.contains("3 of the 6") && tn.contains("Heart line 3.") && tn.contains("continue=\"true\""),
          "the teacher's next brief says where the user stopped and how to go on", tn)
    check(log.teacherNews() == nil, "once")
    let tk = log.talkerNews() ?? ""
    check(tk.contains("interrupted after 3 of its 6 lines") && tk.contains("Heart line 3.") && !tk.contains("Heart line 4."),
          "the talker hears only what was heard", tk)
    check(ended.last?.digest().contains("3 steps drawn") == true, "the record says what's on the paper", ended.last?.digest() ?? "")

    // Failed, and a voice that went quiet.
    let id3 = log.begin(turn: 7, question: "draw it")
    log.written(id3, ok: false)
    check(ended.last?.end == .failed, "an error: failed")
    let id4 = log.begin(turn: 8, question: "show me")
    log.line(id4, "One.", tag: 50); log.written(id4, ok: true)
    log.speechDone()
    check(ended.last?.end == .finished, "the voice finished (a line never reported): finished")
    let id5 = log.begin(turn: 9, question: "and the next?")
    log.line(id5, "Two.", tag: 60); log.heard(tag: 60)
    log.endSession()
    check(ended.last?.end == .sessionEnded && ended.last?.digest().contains("end of the session") == true, "the session ended first: said so")
    // Nothing reached the user: the talker isn't told about it.
    let id6 = log.begin(turn: 10, question: "x"); _ = id6
    log.interrupt()
    _ = log.talkerNews()
    check(log.talkerNews() == nil, "a lesson dropped before its first line isn't talker news")

    // Size: a long lesson stays short for the talker.
    let big = TeacherLog()
    let b = big.begin(turn: 1, question: "a long one")
    for i in 0..<20 { big.line(b, "This is a fairly long spoken line number \(i) about the subject at hand, with detail.", tag: i); big.heard(tag: i) }
    big.written(b, ok: true)
    let bn = big.talkerNews() ?? ""
    check(bn.count < 1000 && bn.contains("number 0") && bn.contains("number 19"), "a 20-line lesson is capped for the talker, first and last lines kept (\(bn.count) chars)", bn)

    // The previous session (carriedOver).
    let cursor = [CarryOver.Item(you: "can you make the first paragraph shorter",
                                 poinky: "Sure. The first paragraph is the Mint timer and sketchboard bug list, so I'll shorten that one.",
                                 app: "Cursor", window: "bugs.md", lesson: nil)]
    check(CarryOver.lines(cursor, ago: "4 minutes ago", question: "can you make the first paragraph shorter", app: "TextEdit", window: "summer-job.txt").isEmpty,
          "r03b: another app in front and no reference back: left out")
    let back = CarryOver.lines(cursor, ago: "4 minutes ago", question: "what did we talk about earlier today?", app: "Google Chrome", window: "New Tab")
    check(back.count == 2 && back[0].contains("NOT the screen now") && back[0].contains("Cursor in front then") && back[1].contains("[in Cursor"),
          "asked about earlier: kept, labeled as another moment and app", back.joined(separator: "\n"))
    let same = CarryOver.lines(cursor, ago: "4 minutes ago", question: "and the second paragraph?", app: "Cursor", window: "bugs.md")
    check(same.count == 2 && !same[0].contains("the user is in"), "the same app and window: kept", same.joined(separator: "\n"))
    check(CarryOver.lines(cursor, ago: "x", question: "and the second paragraph?", app: "Cursor", window: "other.md").isEmpty,
          "the same app, another window: left out")
    check(!CarryOver.lines(cursor, ago: "x", question: "מה אמרת קודם?", app: "Safari", window: "").isEmpty, "Hebrew \"what did you say before\": kept")
    let withLesson = [CarryOver.Item(you: "explain the chart", poinky: "Sure, let me show you.", app: "Google Chrome", window: "Report", lesson: "the lesson “tickets” on the paper, finished, 6 steps")]
    check(CarryOver.lines(withLesson, ago: "x", question: "what did we just cover", app: "Google Chrome", window: "Report").joined().contains("Your sketch: the lesson “tickets”"),
          "the sketch of an old exchange is in the block too")
}

MainActor.assumeIsolated { run() }
print(failed == 0 ? "all passed" : "\(failed) failed")
exit(failed == 0 ? 0 : 1)
