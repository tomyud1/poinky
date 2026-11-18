// Table tests for Sources/Poinky/Quiet.swift: which words switch quiet mode, what the Copy button copies, and the
// pace of a sentence nobody hears. Run: tools/quiet-test/run.sh
import Foundation

var failed = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok { failed += 1 }
}

// Quiet mode, said or typed (nil: goes to the talker as usual).
let phrases: [(String, Bool?)] = [
    ("Be quiet", true), ("be quiet please", true), ("Poinky, be quiet.", true), ("please be quiet now", true),
    ("quiet mode", true), ("Turn on quiet mode", true), ("switch to quiet mode", true), ("go quiet", true),
    ("stop talking out loud", true), ("don't talk out loud", true), ("Shh", true), ("shhh!", true), ("mute", true),
    ("mute yourself", true), ("turn off your voice", true), ("just write it instead", true), ("text only", true),
    ("answer in text", true), ("I'm in a library", true), ("I’m in a lecture", true), ("can you please be quiet", true),
    ("ok please go quiet", true),
    ("You can talk again.", false), ("talk to me again", false), ("talk to me normally again", false), ("speak out loud", false),
    ("unmute", false), ("quiet mode off", false), ("turn off quiet mode", false), ("stop quiet mode", false),
    ("turn your voice back on", false), ("I'm back", false), ("you can stop being quiet", false),
    ("תהיה בשקט", true), ("מצב שקט", true), ("שקט", true), ("אפשר לדבר שוב", false), ("תבטל את מצב שקט", false),
    // Not a switch: questions, other things to mute, interrupting, longer requests.
    ("why are you so quiet?", nil), ("mute the video", nil), ("stop talking", nil), ("stop", nil), ("what does quiet mode do", nil),
    ("is it quiet in here", nil), ("write an email to Sam", nil), ("type this for me", nil), ("be quiet about the surprise when you talk to Sam later today", nil),
    ("make this paragraph shorter", nil), ("talk", nil), ("text", nil), ("write", nil), ("", nil),
]
for (said, want) in phrases {
    let got = QuietPhrase.intent(said)
    check(got == want, "“\(said)” → \(got.map { $0 ? "on" : "off" } ?? "talker")" + (got == want ? "" : " (want \(want.map { $0 ? "on" : "off" } ?? "talker"))"))
}

// What Copy copies.
let copies: [(String, String?, String?, String)] = [
    ("Here's a punchier version: We ship Friday, tested and ready. Want me to swap it in?",
     "Replace the selected text in Pages with exactly: We ship Friday, tested and ready.", "We ship Friday, tested and ready.", "a rewrite: the offer's exact words"),
    ("Here's a punchier version: We ship Friday, tested and ready. Want me to swap it in?", nil,
     "We ship Friday, tested and ready.", "a rewrite with no offer: the words before the question, after the colon"),
    ("Run `git stash pop` to get your changes back.", nil, "git stash pop", "a command in backticks"),
    ("You could reply: “Thanks, I'll send the report on Monday.”", nil, "Thanks, I'll send the report on Monday.", "a line in quotes"),
    ("That button saves the file.", nil, nil, "a plain answer has nothing special to copy"),
    ("It's called \"Save\" in the menu.", nil, nil, "a short quoted word isn't a line to paste"),
    ("Replace it with “שלום לכולם, נתראה מחר בבוקר”.", nil, "שלום לכולם, נתראה מחר בבוקר", "a Hebrew line in quotes"),
    ("Sure. Swap the second sentence. Want me to put it in?", "Replace the selected text with exactly: \"Shorter is better.\"", "Shorter is better.", "quotes around the offer's words go"),
]
for (answer, offer, want, what) in copies {
    let got = Copyable.extract(answer: answer, offer: offer)
    check(got == want, what + (got == want ? "" : " (got \(got.map { "“\($0)”" } ?? "nil"))"))
}

// Pace: reading for plain answers, speech for lesson lines (the pen draws with them).
let line = "This is a sentence of about ten words in all, really."
check(QuietPace.seconds(line, drawing: false) < QuietPace.seconds(line, drawing: true), "a lesson line takes longer than a plain one")
check(abs(QuietPace.seconds(line, drawing: false) - 2.75) < 0.3, "ten words read in about 2.7 s (\(QuietPace.seconds(line, drawing: false)))")
check(QuietPace.seconds("Yes.", drawing: false) >= 0.9, "a one-word sentence still shows for a moment")
check(QuietPace.seconds("Yes.", drawing: true) >= 1.6, "a short lesson line leaves the pen time to draw")
check(QuietPace.seconds("这是一个关于心脏如何工作的很长的句子，我们一步一步来看。", drawing: false) > 2, "Chinese is paced by its characters")
check(QuietPace.seconds(String(repeating: "word ", count: 400), drawing: false) <= 8, "a very long sentence is capped")

print(failed == 0 ? "PASS" : "FAIL (\(failed))")
exit(failed == 0 ? 0 : 1)
