import Foundation

// TalkerRoute's phrase table: each row of cases.tsv is a question and what the router must make of it.
//   talker-route cases.tsv     the table test (prints ok/FAIL per row, exits 1 on any failure)
//   talker-route --json        reads [{"q":…, "marked":bool, "work":…}] on stdin, prints the routes (the eval uses it)

func flags(_ r: TalkerRoute) -> [String] {
    var f: [String] = []
    if r.aboutApp { f.append("app") }
    if r.aboutHelpers { f.append("helpers") }
    if r.aboutTime { f.append("time") }
    if r.aboutUsage { f.append("usage") }
    if r.wantsVideo { f.append("video") }
    if let s = r.shape { f.append(s.rawValue) }
    return f
}

let args = CommandLine.arguments
if args.count > 1, args[1] == "--json" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let qs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    let out: [[String: Any]] = qs.map { q in
        let r = TalkerRoute.classify(q["q"] as? String ?? "", marked: q["marked"] as? Bool ?? false, work: q["work"] as? String ?? "")
        let q0 = q["q"] as? String ?? ""
        return ["teacher": r.teacher.rawValue, "reason": r.reason, "flags": flags(r), "hint": r.shapeHint ?? NSNull(),
                "handOver": TalkerRoute.handOverExample(q0, checking: r.teacher == .check)]
    }
    let json = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    FileHandle.standardOutput.write(json)
    exit(0)
}

// The hand-over gate while the teacher sketches in parallel: what of the talker's pieces is spoken.
if args.count > 1, args[1] == "--handover" {
    let cases: [([String], [String])] = [
        (["Sure, let me show you."], ["Sure, let me show you."]),
        (["Sure,", "let me show you."], ["Sure,", "let me show you."]),
        (["Sure, let me sketch it.", "The friction pulls back, so you subtract four from ten."], ["Sure, let me sketch it."]),
        (["The friction of four newtons pulls the cart back against the ten newton pull, so the net is six.", "Let me sketch it."],
         ["Sure, let me show you."]),
        (["הסיכום: חוקרים מצאו שהליכה של עשרים דקות אחרי הארוחה מורידה את העלייה בסוכר בדם, בעיקר אם מתחילים ללכת תוך חצי שעה."],
         ["בטח, אני אראה לך."]),
    ]
    var bad = 0
    for (pieces, want) in cases {
        var said: [String] = []
        let q = pieces.first?.unicodeScalars.contains(where: { (0x0590...0x05FF).contains($0.value) }) == true ? "תסביר לי" : "explain this"
        for p in pieces { if let k = TalkerRoute.handOver(piece: p, before: said, question: q) { said.append(k) } }
        if said != want { bad += 1; print("FAIL \(pieces) → \(said), want \(want)") } else { print("ok   \(pieces.count) piece(s) → \(said)") }
    }
    // What follows the talker's own <say>: a <visual> drops the rest of an explanation.
    let after: [(String, Bool, TalkerRoute.AfterSay)] = [
        ("<say>The crash is a divide by zero. You typed", false, .wait),
        ("<say>The crash is a divide by zero.</say>\n", false, .wait),
        ("<say>The crash is a divide by zero.</say>\n<vis", false, .visual),
        ("<say>The crash is a divide by zero.</say>\n<vi", false, .wait),
        ("<say>Mint will make it.</say>\n<video title=", false, .other),
        ("<say>The crash is a divide by zero.</say>\n<draw>{", false, .other),
        ("<say>Sure, I'll walk you through it.</say><guide>export", false, .other),
        ("<say>Want me to sketch it?</say>\n<offer say=\"Okay.\"><visual>Lesson", false, .wait),
        ("<say>Want me to sketch it?</say>\n<offer say=\"Okay.\"><visual>Lesson…</visual></offer>", true, .other),
        ("<say>It's six.</say>", true, .other),
    ]
    for (text, done, want) in after {
        let got = TalkerRoute.afterSay(text, finished: done)
        if got != want { bad += 1; print("FAIL afterSay \(text.debugDescription) → \(got), want \(want)") } else { print("ok   afterSay → \(got)") }
    }
    // Honoring the route in code: a quick answer keeps no paper; a small edit or a redraw starts no helper; spoken
    // steps of an app how-to become a walkthrough; a helper never works in a folder unrelated to the document in front.
    var more = 0
    func expect(_ ok: Bool, _ what: String) { more += 1; if !ok { bad += 1; print("FAIL \(what)") } else { print("ok   \(what)") } }
    expect(TalkerRoute.classify("explain briefly what Rubisco does").dropsVisual("explain briefly what Rubisco does"), "quick: a <visual> is dropped")
    expect(!TalkerRoute.classify("briefly show me the graph").dropsVisual("briefly show me the graph"), "quick but asked to see: kept")
    expect(!TalkerRoute.classify("explain this").dropsVisual("explain this"), "not quick: kept")
    expect(TalkerRoute.classify("change Friday to Saturday").refusesHelper, "a one-word change starts no helper")
    expect(TalkerRoute.classify("can you show it as a line instead").refusesHelper, "a redraw starts no helper")
    expect(!TalkerRoute.classify("start a helper to change all the dates to ISO format").refusesHelper, "asked for a helper: allowed")
    expect(!TalkerRoute.classify("fix this bug").refusesHelper, "a bug fix may get a helper")
    expect(TalkerRoute.spokenSteps("Click Format, then choose Font and Bigger."), "spoken steps are noticed")
    expect(!TalkerRoute.spokenSteps("The title is the first line."), "plain sentences aren't steps")
    expect(TalkerRoute.guideGoal("How do I make the title bigger?") == "make the title bigger", "the walkthrough's goal")
    let doc = URL(fileURLWithPath: "/Users/u/Documents/party-plan.txt")
    expect(TalkerRoute.helperDir(requested: "~/code/poinky", document: doc, project: nil, question: "change Friday to Saturday") == "/Users/u/Documents",
           "a code folder unrelated to the open note: the note's folder")
    expect(TalkerRoute.helperDir(requested: "/Users/u/code/app", document: URL(fileURLWithPath: "/Users/u/code/app/src/a.py"), project: nil, question: "fix it") == "/Users/u/code/app",
           "the document's own project: kept")
    expect(TalkerRoute.helperDir(requested: "~/code/website", document: doc, project: nil, question: "have a helper update the website repo") == "~/code/website",
           "a folder the question names: kept")
    expect(TalkerRoute.helperDir(requested: "~/code/x", document: nil, project: nil, question: "fix it") == "~/code/x", "no document: the talker's choice")
    print("\(cases.count + after.count + more - bad)/\(cases.count + after.count + more) hand-over and honoring cases")
    exit(bad == 0 ? 0 : 1)
}

// Columns (tab-separated): question, marked (y/n), work (the selected/marked text, or -), teacher, flags (comma list or -).
let path = args.count > 1 ? args[1] : "tools/tests/talker-route/cases.tsv"
guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("FAIL can't read \(path)"); exit(1) }
var failed = 0, rows = 0
for line in text.split(separator: "\n", omittingEmptySubsequences: true) where !line.hasPrefix("#") {
    let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    guard c.count >= 5 else { print("FAIL bad row: \(line)"); failed += 1; continue }
    rows += 1
    let r = TalkerRoute.classify(c[0], marked: c[1] == "y", work: c[2] == "-" ? "" : c[2])
    let want = c[4] == "-" ? [] : c[4].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.sorted()
    let got = flags(r).sorted()
    if r.teacher.rawValue != c[3] || got != want {
        failed += 1
        print("FAIL \"\(c[0])\": teacher \(r.teacher.rawValue) (\(r.reason)), want \(c[3]); flags \(got.isEmpty ? "-" : got.joined(separator: ",")), want \(c[4])")
    } else {
        print("ok   \"\(c[0])\" → \(r.teacher.rawValue) (\(r.reason))\(got.isEmpty ? "" : " + " + got.joined(separator: ","))")
    }
}
print("\(rows - failed)/\(rows) rows route as the table says")
exit(failed == 0 ? 0 : 1)
