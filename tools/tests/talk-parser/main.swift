import Foundation

// TalkParser on replies real models sometimes write: what's said (captioned and spoken) must be speech only,
// the same however the reply is cut into stream pieces. Built by tools/test-talker.sh (T3).

func run(_ raw: String, step: Int) -> (said: [String], ev: TalkEvents) {
    var p = TalkParser()
    var said: [String] = []
    var all = TalkEvents()
    let chars = Array(raw)
    var i = 0
    while i < chars.count {
        let e = p.feed(String(chars[i..<min(i + step, chars.count)]))
        said += e.sentences; all.draws += e.draws
        all.visual = all.visual ?? e.visual
        i += step
    }
    let f = p.finish()
    said += f.sentences; all.draws += f.draws
    all.visual = all.visual ?? f.visual
    all.agents = f.agents; all.remember = f.remember; all.settings = f.settings; all.end = f.end; all.search = f.search
    return (said, all)
}

var failures = 0
func check(_ name: String, _ raw: String, said want: [String], _ extra: ((TalkEvents) -> String?)? = nil) {
    for step in [1, 2, 5, 9, 10_000] {
        let (said, ev) = run(raw, step: step)
        var problem: String? = nil
        if said != want { problem = "said \(said), want \(want)" }
        else if let e = extra?(ev) { problem = e }
        if let problem {
            print("FAIL \(name) (pieces of \(step)): \(problem)")
            failures += 1
            return
        }
    }
    print("ok   \(name)")
}

check("an unclosed <say> before <draw>: the JSON isn't read out, the marks still come",
      #"<say>Look at this line. It's the bug.<draw>{"items":[{"type":"box","x":10,"y":20,"w":30,"h":40}]}</draw>"#,
      said: ["Look at this line.", "It's the bug."]) { $0.draws.count == 1 ? nil : "draws \($0.draws.count)" }
check("an unclosed <say> before <visual>", "<say>Sure, let me show you.<visual>a diagram of the heart</visual>",
      said: ["Sure, let me show you."]) { $0.visual == "a diagram of the heart" ? nil : "visual \($0.visual ?? "nil")" }
check("an unclosed <say> before <agent>", #"<say>I'll have Mint fix that.<agent title="Fix" dir="~/x">fix the bug</agent>"#,
      said: ["I'll have Mint fix that."]) { $0.agents.count == 1 ? nil : "agents \($0.agents.count)" }
check("an unclosed <say> before <remember> and <set>", #"<say>Okay, faster.<set>{"voiceSpeed":1.2}</set><remember>likes tea</remember>"#,
      said: ["Okay, faster."]) { $0.settings.count == 1 && $0.remember == ["likes tea"] ? nil : "set \($0.settings) remember \($0.remember)" }
check("a <draw> inside <say>", #"<say>Look here <draw>{"items":[]}</draw> that's it.</say>"#, said: ["Look here that's it."])
check("a second <say> before the first closed", "<say>First part. <say>Second part.</say>", said: ["First part.", "Second part."])
check("inline tags like <b>", "<say>Click <b>Save</b> then you're done.</say>", said: ["Click Save then you're done."])
check("a plain < stays", "<say>If x < 5 then it's small. Otherwise big.</say>", said: ["If x < 5 then it's small.", "Otherwise big."])
check("a reply cut off inside its first tag says nothing", "<sa", said: [])
check("a reply cut off mid-sentence says what came", "<say>The answer is four. And th", said: ["The answer is four.", "And th"])
check("no tags at all (the format forgotten)", "Sure! The answer is four. Want more?", said: ["Sure! The answer is four. Want more?"])
check("empty and whitespace replies say nothing", " \n\t ", said: [])
check("two <say> with a <search> between", "<say>One sec.</say><search>weather</search><say>Let me check.</say>",
      said: ["One sec.", "Let me check."]) { $0.search == "weather" ? nil : "search \($0.search ?? "nil")" }
check("<end/> between two <say>", "<say>Bye now.</say><end/><say>See you.</say>", said: ["Bye now.", "See you."]) { $0.end ? nil : "no end" }
check("emoji and Hebrew", "<say>Great job 👍🏽 really. שלום, מה שלומך היום?</say>", said: ["Great job 👍🏽 really.", "שלום, מה שלומך היום?"])

// The teacher's lines too.
var a = ArtistStream()
let evs = a.feed("<lesson title=\"t\"><say>The <b>left</b> side pumps.</say><step>[]</step></lesson>")
if evs.contains(.say("The left side pumps.")) { print("ok   the teacher's <say> loses inline tags") }
else { print("FAIL the teacher's <say>: \(evs)"); failures += 1 }

exit(failures == 0 ? 0 : 1)
