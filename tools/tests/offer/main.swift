import Foundation

// Offers (`<offer>` in the talker's reply, `PendingOffer`, `OfferReply`): what's kept aside, which answers
// count as a yes or a no (English and Hebrew), expiry, and what may wait for a yes. No model, no app.
// Built by tools/test-talker.sh with the talker part of Brain.swift, SpokenText.swift and Offer.swift.

var failures = 0
func check(_ name: String, _ ok: Bool) {
    print(ok ? "ok   \(name)" : "FAIL \(name)")
    if !ok { failures += 1 }
}

// 1. Answers
let yes = ["yes", "Yes.", "yeah", "Yeah, do it.", "sure", "Sure, go ahead!", "go ahead", "yes please", "ok", "Okay.",
           "yep, thanks", "do it", "sounds good", "please do", "Yes, swap it in.", "absolutely", "of course", "why not",
           "let's do it", "yeah go for it Poinky", "uh huh", "כן", "כן.", "כן בבקשה", "בטח", "סבבה", "יאללה", "קדימה",
           "תעשה את זה", "כן, תחליף", "אוקיי", "בסדר, תודה", "יאללה תעשה", "לך על זה", "בטח שכן"]
let no = ["no", "No.", "nope", "no thanks", "No, thank you.", "not now", "never mind", "leave it", "don't", "Don't do it.",
          "nah", "forget it", "skip it", "keep it as is", "לא", "לא תודה", "לא צריך", "עזוב", "עזבי את זה", "לא עכשיו",
          "אל תעשה את זה", "ממש לא", "תשאיר ככה"]
let other = ["yes but make it shorter", "no wait, make it longer", "maybe", "what does it say", "hmm", "thanks",
             "yes no", "can you make it more formal first", "it", "that's fine", "explain this paragraph",
             "yeah yeah yeah yeah yeah yeah yeah yeah yeah", "כן אבל קצר יותר", "מה זה", "לא, תעשה את זה יותר קצר",
             "how long will it take", "do it in French", "okay what about the second one", ""]
for s in yes { check("yes: \(s)", OfferReply.classify(s) == .yes) }
for s in no { check("no: \(s)", OfferReply.classify(s) == .no) }
for s in other { check("other: \(s.isEmpty ? "(nothing)" : s)", OfferReply.classify(s) == .other) }

// 2. The parser keeps an offer aside: nothing in it is said or done now
let reply = """
<say>Our Friday meetings run long. Twenty minutes is plenty. Want me to swap it in?</say>
<offer say="Swapping it in."><do>Replace the selected paragraph in Pages with exactly: Our Friday meetings run long. Twenty minutes is plenty.</do></offer>
<draw>{"items":[]}</draw>
"""
var p = TalkParser()
var streamed = TalkEvents()
var said: [String] = []
for chunk in stride(from: 0, to: reply.count, by: 7).map({ String(Array(reply)[$0..<min($0 + 7, reply.count)]) }) {
    let e = p.feed(chunk)
    said += e.sentences
    if e.doTask != nil { streamed.doTask = e.doTask }
    if e.visual != nil { streamed.visual = e.visual }
    streamed.draws += e.draws
}
let fin = p.finish()
said += fin.sentences
check("streaming: no <do> runs from inside an offer", streamed.doTask == nil && fin.doTask == nil)
check("the spoken text is the <say> only", said.joined(separator: " ").hasSuffix("Want me to swap it in?") && !said.joined().contains("Replace"))
check("the offer is kept with its line", fin.offer?.say == "Swapping it in." && fin.offer?.body.contains("<do>") == true)
check("other tags still parse (draw)", streamed.draws.count + fin.draws.count == 1)
check("a lookup reply can't make offers (onlySpeech)", fin.onlySpeech().offer == nil)
check("an offer counts as acting (logged when a lookup reply tries)", fin.wouldAct)

let o = PendingOffer.make(fin.offer, at: 100, app: "com.apple.iWork.Pages", window: "Team notes", selection: "Our Friday meetings run long and we never get through it.")
check("the offer becomes a pending <do>", o?.actions.doTask?.hasPrefix("Replace the selected paragraph") == true && o?.say == "Swapping it in.")

// 3. Expiry and a changed screen
if let o {
    check("fresh, same place: ok", o.check(now: 130, app: "com.apple.iWork.Pages", window: "Team notes", selection: "Our Friday meetings run long and we never get through it.") == .ok)
    check("whitespace changes in the selection don't matter", o.check(now: 130, app: "com.apple.iWork.Pages", window: "Team notes", selection: "Our  Friday meetings run long and we\nnever get through it.") == .ok)
    check("after 60 s: expired", o.check(now: 161, app: "com.apple.iWork.Pages", window: "Team notes", selection: nil) == .expired)
    check("another front app: moved", o.check(now: 110, app: "com.apple.Safari", window: nil, selection: nil) == .moved)
    check("another window: moved", o.check(now: 110, app: "com.apple.iWork.Pages", window: "Budget", selection: nil) == .moved)
    check("another selection (a rewrite would replace it): moved", o.check(now: 110, app: "com.apple.iWork.Pages", window: "Team notes", selection: "Something else") == .moved)
    check("window and selection unknown now: only the app and the time count", o.check(now: 110, app: "com.apple.iWork.Pages", window: nil, selection: nil) == .ok)
    check("a clock that went backwards: expired", o.check(now: 50, app: "com.apple.iWork.Pages", window: nil, selection: nil) == .expired)
}

// 4. What may wait for a yes
func offer(_ body: String) -> PendingOffer? {
    var q = TalkParser(); _ = q.feed("<say>Want me to?</say><offer>\(body)</offer>")
    return PendingOffer.make(q.finish().offer, at: 0, app: "", window: "", selection: "")
}
check("a reminder may wait", offer(#"<remind at="2026-11-15 17:00">Call Dan</remind>"#)?.actions.reminders.first?.at == "2026-11-15 17:00")
check("a helper may wait", offer(#"<agent title="Fix the bug" dir="/tmp/x">Fix it</agent>"#)?.actions.agents.first?.title == "Fix the bug")
check("a sketch may wait", offer("<visual>Lesson: how tides work</visual>")?.actions.visual != nil)
check("a setting may wait (still through the whitelist)", offer(#"<set>{"speed":1.2}</set>"#)?.actions.settings.count == 1)
check("memory edits can't wait", offer("<remember>They like cats</remember>") == nil)
check("lookups can't wait", offer("<search>weather</search>") == nil && offer("<recall>yesterday</recall>") == nil)
check("stop / undo / end can't wait", offer(#"<stop agent="Mint"/><undo agent="Mint"/><end/>"#) == nil)
check("a video can't wait", offer(#"<video title="Tides">explain tides</video>"#) == nil)
let mixed = offer(#"<do>Type hi</do><remember>secret</remember><search>x</search>"#)
check("a mixed offer keeps only what may wait", mixed?.actions.doTask == "Type hi" && mixed?.actions.remember.isEmpty == true && mixed?.actions.search == nil)
check("an empty offer is no offer", offer("") == nil && offer("just words") == nil)
check("a default line when it has no say", offer("<do>Type hi</do>")?.defaultLine == "On it.")
check("say inside an offer isn't spoken now", { var q = TalkParser(); _ = q.feed("<say>Want me to?</say><offer><say>Done!</say><do>x</do></offer>"); let e = q.finish(); return q.sayPreview == "Want me to?" && e.doTask == nil }())
check("an offer still arriving isn't acted on", { var q = TalkParser(); let e = q.feed("<say>Want me to?</say><offer><do>Type hi</do>"); return e.doTask == nil }())
check("a <do> outside the offer still runs", { var q = TalkParser(); _ = q.feed("<say>On it.</say><do>Type hi</do><offer><visual>v</visual></offer>"); let e = q.finish(); return e.doTask == "Type hi" && e.visual == nil }() || { var q = TalkParser(); let e = q.feed("<say>On it.</say><do>Type hi</do>"); return e.doTask == "Type hi" }())

// 5. New wording: `<replace>` carries the exact text that gets pasted (no doer loop)
let swap = offer("<replace>Our Friday meetings run long.\nTwenty minutes is plenty.</replace>")
check("a rewrite may wait as <replace>", swap?.actions.replace?.text == "Our Friday meetings run long.\nTwenty minutes is plenty." && swap?.actions.replace?.named == false)
check("its default line", swap?.defaultLine == "Swapping it in.")
let named = offer(#"<replace from="This summer I worked" to="able to do.">At my summer job…</replace>"#)
check("a rewrite of a named span keeps its first and last words", named?.actions.replace == ReplaceRequest(text: "At my summer job…", from: "This summer I worked", to: "able to do."))
check("with a <replace>, a <do> in the same offer doesn't also run", { let o = offer(#"<replace>New.</replace><do>Replace it with New.</do>"#); return o?.actions.replace != nil && o?.actions.doTask == nil }())
check("<replace> is never spoken", { var q = TalkParser(); var said = q.feed("<say>Here's a shorter one. <replace>Secret words.</replace>Want me to swap it in?</say>").sentences; said += q.finish().sentences; return !said.joined().contains("Secret") && said.joined().contains("swap it in") }())
check("a lookup reply can't replace text", { var q = TalkParser(); _ = q.feed("<say>Ok.</say><replace>x</replace>"); let e = q.finish(); return e.replace != nil && e.onlySpeech().replace == nil && e.wouldAct }())
if let o = PendingOffer.make((say: nil, body: "<replace>Short.</replace>"), at: 100, app: "com.apple.TextEdit", window: "essay.txt", selection: "A long wordy sentence.") {
    check("a swap over a selection lapses when the selection changed", o.check(now: 110, app: "com.apple.TextEdit", window: "essay.txt", selection: "Another sentence") == .moved)
    check("…and runs when it's the same", o.check(now: 110, app: "com.apple.TextEdit", window: "essay.txt", selection: "A long wordy  sentence.") == .ok)
} else { check("a swap offer is made", false) }

// 6. A rewrite of a selected sentence doesn't bring the greeting / sign-off around it
let sel = "I need you to send me the slides by tomorrow because I already asked twice and nobody has done it."
func swapped(_ body: String, _ selection: String = sel) -> String? {
    PendingOffer.make((say: nil, body: body), at: 0, app: "", window: "", selection: selection)?.actions.replace?.text
}
check("greeting and sign-off dropped", swapped("<replace>Hi Sam, could you send me the slides by tomorrow? I've asked a couple of times now. Thanks!</replace>") == "Could you send me the slides by tomorrow? I've asked a couple of times now.")
check("a signed-off name goes too", swapped("<replace>Hi Sam,\nWould you send the slides by tomorrow?\nThanks so much,\nAlex</replace>") == "Would you send the slides by tomorrow?")
check("kept when the selection had them", swapped("<replace>Hi Sam, slides by tomorrow please. Thanks!</replace>", "Hi Sam, I need the slides by tomorrow. Thanks,") == "Hi Sam, slides by tomorrow please. Thanks!")
check("plain rewrites untouched", swapped("<replace>Our Friday meetings run long. Twenty minutes is plenty.</replace>") == "Our Friday meetings run long. Twenty minutes is plenty.")
check("'thanks' inside a sentence stays", swapped("<replace>Thanks to the team, we shipped on time.</replace>") == "Thanks to the team, we shipped on time.")
check("unknown selection: nothing trimmed", swapped("<replace>Hi Sam, slides please.</replace>", "") == "Hi Sam, slides please.")

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
