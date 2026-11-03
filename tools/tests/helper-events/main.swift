import Foundation
var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "  ok   \(what)" : "  FAIL \(what)"); if !ok { failures += 1 } }

func events(_ name: String, chunk: Int) -> [HelperEvent] {
    let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1] + "/\(name).jsonl"))
    var s = HelperStream(); var out: [HelperEvent] = []
    var i = 0
    while i < data.count { let j = min(data.count, i + chunk); out += s.feed(data[i..<j]); i = j }
    return out
}
/// The window's entries for a recorded run.
func entries(_ name: String, chunk: Int) -> [HelperEntry] {
    let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1] + "/\(name).jsonl"))
    var s = HelperStream(); var out: [HelperEntry] = []
    var i = 0
    while i < data.count { let j = min(data.count, i + chunk); _ = s.feed(data[i..<j]); out += s.takeEntries(); i = j }
    return out
}
// `parser <dir> --entries <run>`: print a run's window entries (one JSON per line).
if let k = CommandLine.arguments.firstIndex(of: "--entries"), k + 1 < CommandLine.arguments.count {
    for e in entries(CommandLine.arguments[k + 1], chunk: 100_000) { print(e.json) }
    exit(0)
}
func steps(_ e: [HelperEvent]) -> [String] { e.compactMap { if case .step(let s) = $0 { return s }; return nil } }

for name in ["fix-bug", "todo-blocked", "two-turns", "crash", "error"] {
    let a = events(name, chunk: 7), b = events(name, chunk: 100_000)
    print("\(name): \(a.count) events")
    check(a == b, "same events whatever the chunk size")
    if case .started = a.first { check(true, "starts with started") } else { check(false, "starts with started") }
    if CommandLine.arguments.contains("-v") { for e in a { print("     ", e) } }
}
let fix = events("fix-bug", chunk: 64)
check(steps(fix).contains("Reading tipsplit.py"), "fix-bug: Reading tipsplit.py")
check(steps(fix).contains("Running the tests"), "fix-bug: tests named plainly")
check(steps(fix).contains("Editing tipsplit.py"), "fix-bug: Editing tipsplit.py")
if case .turnEnded(let ok, let summary, _, _) = fix.last { check(ok && summary.hasPrefix("All 4 tests pass"), "fix-bug: ends ok with summary") } else { check(false, "fix-bug: ends with turnEnded") }

let todo = events("todo-blocked", chunk: 64)
let blocked = todo.compactMap { if case .blocked(let s) = $0 { return s }; return nil }
check(blocked.count == 5 && blocked[0].hasPrefix("Run curl -sI https://example.com"), "todo-blocked: 5 refusals, first is curl (\(blocked.count))")
let lists = todo.compactMap { if case .checklist(let l) = $0 { return l }; return nil }
check(lists.count >= 3, "todo-blocked: checklist updates (\(lists.count))")
check(lists.last?.allSatisfy { $0.state == .done } == true || lists.last?.contains { $0.state == .done } == true, "todo-blocked: items get done")
check(!steps(todo).contains { $0.contains("ToolSearch") || $0.contains("TodoWrite") }, "todo-blocked: no tool plumbing in steps")
check(steps(todo).contains("Running the tests"), "todo-blocked: unittest is 'Running the tests'")

let two = events("two-turns", chunk: 5)
check(two.filter { if case .note = $0 { return true }; return false }.isEmpty, "two-turns: one-word replies are not notes")
check(two.filter { if case .turnEnded = $0 { return true }; return false }.count == 2, "two-turns: two turns")
let crash = events("crash", chunk: 9)
check(!crash.contains { if case .turnEnded = $0 { return true }; return false }, "crash: no result")
let err = events("error", chunk: 9)
if case .turnEnded(let ok, _, _, _) = err.last { check(!ok, "error: ends not ok") } else { check(false, "error: ends with turnEnded") }

// The helper's window
let fe = entries("fix-bug", chunk: 7)
check(fe == entries("fix-bug", chunk: 100_000), "window: same entries whatever the chunk size")
let fnotes = fe.filter { $0.k == "note" }
check(!fnotes.isEmpty && fnotes.contains { $0.text.count > 60 }, "window: notes are kept in full (\(fnotes.map(\.text.count)))")
let fsteps = fe.filter { $0.k == "step" }
check(fsteps.contains { $0.kind == "read" && $0.detail?.hasSuffix("tipsplit.py") == true }, "window: a read step keeps its file")
check(fsteps.contains { $0.kind == "test" && !($0.detail ?? "").isEmpty }, "window: a test step keeps its command")
check(fsteps.contains { $0.kind == "edit" }, "window: edits are edits")
let te = entries("todo-blocked", chunk: 64)
check(te.filter { $0.k == "todo" }.count >= 3 && te.first { $0.k == "todo" }?.items?.isEmpty == false, "window: to-do lists with their items")
check(te.filter { $0.k == "blocked" }.count == 5, "window: refusals")
func feedLines(_ lines: [String]) -> [HelperEntry] {
    var s = HelperStream(); _ = s.feed(Data((lines.joined(separator: "\n") + "\n").utf8)); return s.takeEntries()
}
let ae = feedLines([#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"npm install left-pad"},"tool_use_id":"t1"}}"#,
                    #"{"type":"control_cancel_request","request_id":"r1"}"#])
check(ae.first.map { $0.k == "ask" && $0.kind == "permission" && ($0.detail ?? "").contains("npm install") && $0.id == "r1" } == true, "window: a permission request with its command")
check(ae.last.map { $0.k == "answer" && $0.id == "r1" } == true, "window: a withdrawn request")
let qe = feedLines([#"{"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which database?","header":"DB","multiSelect":false,"options":[{"label":"SQLite","description":""},{"label":"Postgres","description":""}]}]},"tool_use_id":"t2"}}"#])
check(qe.first.map { $0.k == "ask" && $0.kind == "question" } == true, "window: a question")
check(!entries("two-turns", chunk: 5).contains { $0.k == "note" && $0.text.isEmpty }, "window: no empty notes")

// Words
check(HelperStream.gerund("Run existing tests") == "Running existing tests", "gerund run")
check(HelperStream.gerund("Check Python version") == "Checking Python version", "gerund check")
check(HelperStream.gerund("Make a list") == "Making a list", "gerund make")
check(HelperStream.gerund("Install deps") == "Installing deps", "gerund install")
check(HelperStream.gerund("Listing files") == "Listing files", "gerund keeps -ing")
check(HelperStream.gerund("Copy files") == "Copying files", "gerund copy")
check(HelperStream.firstSentence("**Good.** Two tests fail. More") == "Good.", "first sentence strips markdown")
check(HelperStream.firstSentence("My plan:\n1. Fix it") == "My plan", "first sentence stops at a colon")
check(HelperStream.describe(tool: "mcp__github__create_issue", input: [:]) == "Using create_issue (github)", "mcp tool")
check(HelperStream.describe(tool: "WebFetch", input: ["url": "https://docs.swift.org/x"]) == "Reading docs.swift.org", "web fetch")
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
