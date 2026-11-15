import Foundation

// Checks SpokenText.normalize (what the voice hears) and SentenceSplit (where speech can start).
// Run: tools/test-voice.sh
var failed = 0
func check(_ input: String, _ want: String, file: StaticString = #file, line: UInt = #line) {
    let got = SpokenText.normalize(input)
    if got == want { return }
    failed += 1
    print("FAIL normalize (line \(line))\n   in:   \(input)\n   want: \(want)\n   got:  \(got)")
}

// Plain sentences are left alone.
check("Sure, that's the save button.", "Sure, that's the save button.")
check("It's 3 o'clock, isn't it?", "It's 3 o'clock, isn't it?")
check("That costs $1,299 right now.", "That costs $1,299 right now.")
check("Battery is at 50% now.", "Battery is at 50% now.")
check("The file is 3.5GB, so it takes a while.", "The file is 3.5GB, so it takes a while.")
check("It's about 5km away.", "It's about 5km away.")
check("Meet at 10:30.", "Meet at 10:30.")
check("It's 72°F outside.", "It's 72°F outside.")
check("Well-known, state-of-the-art work.", "Well-known, state-of-the-art work.")
check("Pages 10-12 cover it.", "Pages 10-12 cover it.")
check("The years 2020-2024 were busy.", "The years 2020-2024 were busy.")
check("Hmm — not quite.", "Hmm — not quite.")
check("In Hebrew that's שלום, which means hello.", "In Hebrew that's שלום, which means hello.")
check("I'm on macOS 26 with an iPhone.", "I'm on macOS 26 with an iPhone.")
check("Use JavaScript or TypeScript.", "Use JavaScript or TypeScript.")
check("Go to example.com for more.", "Go to example.com for more.")
check("It's Python vs. JavaScript, etc.", "It's Python vs. JavaScript, etc.")
check("The ratio is 3:2.", "The ratio is 3:2.")
check("Section A is done.", "Section A is done.")
check("I think so - mostly.", "I think so - mostly.")
check("Rock & roll.", "Rock and roll.")

// Math
check("So x^2 + 3x = 0 has two roots.", "So x squared plus 3x equals 0 has two roots.")
check("x² − 4 = 0", "x squared minus 4 equals 0")
check("Then a^3 is 27.", "Then a cubed is 27.")
check("It grows like 2^n.", "It grows like 2 to the power of n.")
check("e^(x+1) is the answer.", "e to the power of x plus 1 is the answer.")
check("So 1/2 plus 1/4 is 3/4.", "So one half plus one quarter is three quarters.")
check("About 2/3 of people.", "About two thirds of people.")
check("Then 5/16 of it.", "Then 5 over 16 of it.")
check("It's open 24/7.", "It's open twenty-four seven.")
check("Divide x/2 first.", "Divide x over 2 first.")
check("The date 11/15/2026 is fine.", "The date 11/15/2026 is fine.")
check("The square root, √2, is about 1.41.", "The square root, the square root of 2, is about 1.41.")
check("√(x+1) is positive.", "the square root of x plus 1 is positive.")
check("We need x ≥ 3 and y ≤ 5.", "We need x greater than or equal to 3 and y less than or equal to 5.")
check("Pi, π, is roughly 3.14.", "Pi, pi, is roughly 3.14.")
check("So a ≠ b.", "So a is not equal to b.")
check("So g ≈ 9.8 m/s².", "So g is about 9.8 meters per second squared.")
check("It goes 60 mph or 100 km/h.", "It goes 60 miles per hour or 100 kilometers per hour.")
check("Δx over Δt.", "delta x over delta t.")
check("2 * 3 = 6", "2 times 3 equals 6")
check("5 - 3 = 2", "5 minus 3 equals 2")
check("If x > 3 then stop.", "If x is greater than 3 then stop.")
check("It's -5 degrees.", "It's minus 5 degrees.")
check("A 90° angle.", "A 90 degrees angle.")
check("The answer is ±2.", "The answer is plus or minus 2.")
check("θ is the angle.", "theta is the angle.")

// Code, files, paths, links
check("Call foo_bar() from the main loop.", "Call foo bar from the main loop.")
check("Open ~/Desktop/a.py in your editor.", "Open a dot P Y in your editor.")
check("Check the README.md file first.", "Check the read me dot M D file first.")
check("It's in src/app/main.swift.", "It's in main dot swift.")
check("Look in /usr/local/bin.", "Look in bin.")
check("Type /review in Claude Code.", "Type slash review in Claude Code.")
check("Save it to ~/Documents.", "Save it to Documents.")
check("It's in ./build/app.", "It's in app.")
check("Is it yes/no?", "Is it yes/no?")
check("Edit my_notes.txt now.", "Edit my notes dot text now.")
check("Open the .env file.", "Open the dot env file.")
check("Run npm i -D typescript in the folder.", "Run N P M i dash D typescript in the folder.")
check("Pass --force to it.", "Pass dash dash force to it.")
check("Go to https://example.com/docs/setup for the guide.", "Go to example.com for the guide.")
check("See https://www.apple.com/macos/.", "See apple.com.")
check("Try http://localhost:3000 now.", "Try http://localhost:3000 now.")
check("Set onClick on the button.", "Set on click on the button.")
check("It uses Node.js and C++.", "It uses Node JS and C plus plus.")
check("This is **really** important, use `git status` first.", "This is really important, use git status first.")
check("That's *very* nice.", "That's very nice.")
check("- First, open the file.", "First, open the file.")
check("1. Open the file.", "1, Open the file.")
check("Read [the guide](https://x.com/a) first.", "Read the guide first.")
check("Then a -> b.", "Then a to b.")
check("Wait for it, and/or retry.", "Wait for it, and or retry.")

// Keys
check("Use Cmd+Shift+4 to take a screenshot.", "Use Command Shift 4 to take a screenshot.")
check("Press ⌘C then ⌘V.", "Press Command C then Command V.")
check("Hit Ctrl + C to stop.", "Hit Control C to stop.")
check("Press ⌃⌥ and talk.", "Press Control Option and talk.")

// Numbers, dates, abbreviations
check("The deadline is 2026-11-15 at 10:30.", "The deadline is November 15, 2026 at 10:30.")
check("Version 2.1.280 fixed it.", "Version 2 point 1 point 280 fixed it.")
check("It starts at 9:05.", "It starts at 9 oh 5.")
check("It starts at 9:00 sharp.", "It starts at 9 sharp.")
check("It takes 250ms.", "It takes 250 milliseconds.")
check("Issue #42 is open.", "Issue number 42 is open.")
check("It's ~5 minutes.", "It's about 5 minutes.")
check("Use a short name, e.g. notes, i.e. something simple.", "Use a short name, for example, notes, that is, something simple.")
check("Fruit, e.g., apples.", "Fruit, for example, apples.")
check("Coffee w/ milk, w/o sugar.", "Coffee with milk, without sugar.")
check("Nice work 🎉 that's done!", "Nice work that's done!")
check("Done ✅", "Done")
check("👍", "")
check("Great job! 👏🏽", "Great job!")
check("I ❤️ it.", "I it.")

// Sentence splitting
func checkSplit(_ text: String, _ want: [String], line: UInt = #line) {
    // Stream it in a few characters at a time, like the model does (TalkParser.takeSentences).
    var got: [String] = []
    var emitted = 0
    var body: [Character] = []
    let all = Array(text)
    var i = 0
    while i < all.count {
        body += all[i..<min(all.count, i + 3)]
        i += 3
        let (pieces, next) = SentenceSplit.split(body, from: emitted, first: emitted == 0, closed: i >= all.count)
        got += pieces
        emitted = next
    }
    if got != want {
        failed += 1
        print("FAIL split (line \(line))\n   want: \(want)\n   got:  \(got)")
    }
}
checkSplit("Sure, that's the save button. Click it.", ["Sure, that's the save button.", "Click it."])
checkSplit("Yes, that is right. It works.", ["Yes, that is right.", "It works."])
checkSplit("Good question, let me sketch it out.", ["Good question, let me sketch it out."])
checkSplit("Okay so first, open the file, then save.", ["Okay so first,", "open the file, then save."])
checkSplit("Use a short name, e.g. notes. Then save.", ["Use a short name,", "e.g. notes.", "Then save."])
checkSplit("Short ones work best, i.e. one word. Okay?", ["Short ones work best,", "i.e. one word.", "Okay?"])
checkSplit("It's Python vs. JavaScript here. Fine.", ["It's Python vs. JavaScript here.", "Fine."])
checkSplit("Ask Dr. Smith about it. She knows.", ["Ask Dr. Smith about it.", "She knows."])
checkSplit("It costs 3.5 dollars. Cheap.", ["It costs 3.5 dollars.", "Cheap."])
checkSplit("You need apples, pears, etc. Then bake.", ["You need apples,", "pears, etc.", "Then bake."])
checkSplit("Made in the U.S. by hand. Nice.", ["Made in the U.S. by hand.", "Nice."])
checkSplit("Three steps.\n1. Open it.\n2. Save it.", ["Three steps.", "1. Open it.", "2. Save it."])
checkSplit("Wait... really? Yes!", ["Wait... really?", "Yes!"])
checkSplit("Okay. Done.", ["Okay.", "Done."])

// Whole sentences in another language go to Apple's voice for it
func checkLang(_ text: String, _ want: String?, voice: String = "en-US", line: UInt = #line) {
    let got = SpokenLanguage.foreign(text, voiceLanguage: voice)
    if got != want { failed += 1; print("FAIL language (line \(line)): \(text) want \(want ?? "-") got \(got ?? "-")") }
}
checkLang("Sure, that's the save button.", nil)
checkLang("In Hebrew that's שלום, which means hello.", nil)
checkLang("The word is gracias, which means thank you.", nil)
checkLang("Gracias.", nil)
checkLang("Hasta la vista, baby.", nil)
checkLang("The café is on the Champs-Élysées.", nil)
checkLang("I love the song La Vie en Rose by Edith Piaf.", nil)
checkLang("Yes, the derivative of x squared is 2x.", nil)
checkLang("שלום, מה שלומך היום?", "he")
checkLang("¿Dónde está la estación de tren?", "es")
checkLang("Je ne sais pas où il est.", "fr")
checkLang("Привет, как дела?", "ru")
checkLang("こんにちは、元気ですか？", "ja")
checkLang("שלום, מה שלומך היום?", nil, voice: "he-IL")
checkLang("Open the file and click Save now.", "en", voice: "he-IL")

// Mixed sentences are cut where another script starts
func checkRuns(_ text: String, _ want: [String], line: UInt = #line) {
    let got = SpokenLanguage.runs(text, voiceLanguage: "en-US").map { ($0.lang.map { "[\($0)] " } ?? "") + $0.text }
    if got != want { failed += 1; print("FAIL runs (line \(line))\n   want: \(want)\n   got:  \(got)") }
}
checkRuns("Sure, that's the save button.", ["Sure, that's the save button."])
checkRuns("And in Hebrew, שלום, מה שלומך היום?", ["And in Hebrew, ", "[he] שלום, מה שלומך היום?"])
checkRuns("In Hebrew that's שלום, which means hello.", ["In Hebrew that's ", "[he] שלום, ", "which means hello."])
checkRuns("Hello is 你好 in Chinese.", ["Hello is ", "[zh] 你好 ", "in Chinese."])
checkRuns("In Japanese it's 日本語です.", ["In Japanese it's ", "[ja] 日本語です."])
checkRuns("The angle θ is small.", ["The angle θ is small."])
checkRuns("Привет means hi.", ["[ru] Привет ", "means hi."])

if failed == 0 { print("ok   spoken text: all cases") } else { print("\(failed) failed"); exit(1) }
