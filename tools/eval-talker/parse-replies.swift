import Foundation

// Runs saved talker replies through the app's own TalkParser (streamed in small pieces, like the app gets
// them) and prints what it found as JSON, for `run.py --replay`. Built by tools/test-talker.sh with the
// talker part of Brain.swift, SpokenText.swift and Offer.swift.
//   parse-replies replies.json   ([{"raw": "..."}…] → [{"say": …, "do": …, …}…])

let data = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let replies = (try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]).map { $0["raw"] as? String ?? "" }
var out: [[String: Any]] = []
for raw in replies {
    var p = TalkParser()
    var said: [String] = [], draws: [String] = []
    var doTask: String?, guide: String?, visual: String?
    let chars = Array(raw)
    var i = 0
    while i < chars.count {
        let e = p.feed(String(chars[i..<min(i + 9, chars.count)]))
        said += e.sentences; draws += e.draws
        doTask = doTask ?? e.doTask; guide = guide ?? e.guide; visual = visual ?? e.visual
        i += 9
    }
    let f = p.finish()
    said += f.sentences; draws += f.draws
    doTask = doTask ?? f.doTask; guide = guide ?? f.guide; visual = visual ?? f.visual
    var r: [String: Any] = ["say": said.joined(separator: " "), "draws": draws.count]
    if let doTask { r["do"] = doTask }
    if let guide { r["guide"] = guide }
    if let visual { r["visual"] = visual }
    r["agent"] = f.agents.map { ["title": $0.title, "dir": $0.dir ?? "", "plan": $0.planFirst] }
    r["remind"] = f.reminders.map { ["at": $0.at, "text": $0.text, "every": $0.every ?? ""] }
    r["set"] = f.settings
    r["tell"] = f.tells.map { ["agent": $0.name, "text": $0.text] }
    r["remember"] = f.remember + f.aboutUser + f.aboutSelf
    r["forget"] = f.forget + f.unlearnSelf
    if let s = f.search { r["search"] = s }
    if let s = f.recall { r["recall"] = s }
    if let v = f.video { r["video"] = v.title }
    if f.end { r["end"] = true }
    if let o = PendingOffer.make(f.offer, at: 0, app: "", window: "", selection: "") {
        var a: [String: Any] = ["say": o.say ?? "", "agents": o.actions.agents.count, "reminders": o.actions.reminders.count,
                                "settings": o.actions.settings.count, "tells": o.actions.tells.count]
        if let d = o.actions.doTask { a["do"] = d }
        if let x = o.actions.replace { a["replace"] = x.text }
        if let v = o.actions.visual { a["visual"] = v }
        if let g = o.actions.guide { a["guide"] = g }
        r["offer"] = a
    } else if f.offer != nil {
        r["offer"] = ["empty": true]
    }
    out.append(r)
}
let json = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
FileHandle.standardOutput.write(json)
