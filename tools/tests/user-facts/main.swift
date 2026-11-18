import Foundation
// UserFacts: what may go into the user's "About me".
//   user-facts --test   no-token checks (run by tools/test-talker.sh)
//   user-facts          reads [{"reply":…, "userLines":[…]}] on stdin, prints the facts kept for each (about-me.py)
if CommandLine.arguments.dropFirst().first == "--test" {
    var bad = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { bad += 1 } }
    let said = ["can you make the first paragraph shorter", "yes", "where do I change the font size"]
    check(UserFacts.aboutLines("- Shortened a paragraph.\nABOUT: Uses TextEdit on their Mac", userLines: said).isEmpty, "no quote: dropped")
    check(UserFacts.aboutLines("ABOUT: Uses TextEdit | \"I use TextEdit for everything\"", userLines: said).isEmpty, "a quote the user never said: dropped")
    check(UserFacts.aboutLines("ABOUT: Sam is the user's name | \"Sure, Sam\"", userLines: ["show me the heart in 3D"]).isEmpty, "Poinky's words as the quote: dropped")
    let s2 = ["explain question 1", "by the way I'm a third year mechanical engineering student, so you can skip the basics"]
    check(UserFacts.aboutLines("- Statics.\nABOUT: Third-year mechanical engineering student | \"I'm a third year mechanical engineering student\"", userLines: s2)
          == ["Third-year mechanical engineering student"], "the user's own words: kept")
    check(UserFacts.aboutLines("ABOUT: Exam on Thursday | \"my exam is on Thursday\"", userLines: UserFacts.pinned(in: "- The user said: «my exam is on Thursday»"))
          == ["Exam on Thursday"], "words pinned in the summary count")
    check(UserFacts.aboutLines("ABOUT: a | \"x y\"\nABOUT: b one | \"I am a nurse\"\nABOUT: c two | \"I work nights\"\nABOUT: d three | \"I like cats\"",
                               userLines: ["I am a nurse and I work nights and I like cats"]).count == 2, "at most two")
    check(UserFacts.fromUser("Studies nursing", said: ["I'm a nursing student"]), "talker's about-user fact from what they said: kept")
    check(!UserFacts.fromUser("Uses TextEdit for writing", said: ["make the title bigger"]), "talker's fact from the screen: dropped")
    check(!UserFacts.fromUser("The user is planning Lake Tahoe hikes", said: ["what's this page about"]), "a page they viewed: dropped")
    check(UserFacts.fromUser("Likes short answers", said: ["just give me short answers from now on"]), "how they like answers: kept")
    check(UserFacts.similar("Sister's birthday is December 3rd", "The user's sister's birthday is December 3rd"), "already in memory: similar")
    print("\(bad == 0 ? "all" : "\(bad) failed") user-facts checks")
    exit(bad == 0 ? 0 : 1)
}
let data = FileHandle.standardInput.readDataToEndOfFile()
let items = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
let out = items.map { UserFacts.aboutLines($0["reply"] as? String ?? "", userLines: $0["userLines"] as? [String] ?? []) }
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: out))
