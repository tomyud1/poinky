import Foundation

/// "Check my microphone" (Settings → Voice, or `Poinky --mic-check`): you read eight short sentences, one at a
/// time; each is recorded the way a hold-to-talk question is (the plain mic), then every installed speech engine
/// hears it. The window shows, per sentence, what each engine heard next to what was written and how loud the mic
/// was, then a plain verdict. Results (text and levels) go to `mic-check/<time>/results.json` in the settings
/// folder for a later debugging session; the recordings stay on this Mac in the same folder (never uploaded) until
/// "Delete recordings". `POINKY_MIC_CHECK_WAVS=<dir>` (tests, `--mic-check-shot`): 1.wav … 8.wav instead of the mic.
enum MicCheck {
    struct Sentence: Identifiable {
        let id: Int
        let hint: String
        let text: String
        let language: String   // "en" or "he"
        var soft = false
    }

    static let sentences: [Sentence] = [
        Sentence(id: 1, hint: "Read this the way you'd ask Poinky:", text: "Where is the save button?", language: "en"),
        Sentence(id: 2, hint: "A longer one:", text: "Can you read this paragraph out loud and make it shorter?", language: "en"),
        Sentence(id: 3, hint: "Something technical:", text: "Explain Bernoulli's equation for this pipe.", language: "en"),
        Sentence(id: 4, hint: "Something technical:", text: "Why does the viscosity term vanish for an inviscid flow?", language: "en"),
        Sentence(id: 5, hint: "Names Poinky should know:", text: "Hey Poinky, ask Mint to fix the failing build.", language: "en"),
        Sentence(id: 6, hint: "Now softly, as if someone next to you is asleep:", text: "What does this error message mean?", language: "en", soft: true),
        Sentence(id: 7, hint: "In Hebrew:", text: "איפה כפתור השמירה?", language: "he"),
        Sentence(id: 8, hint: "In Hebrew, with a technical word:", text: "תסביר לי את משוואת ברנולי.", language: "he"),
    ]

    static var folder: URL { AppConfig.dir.appendingPathComponent("mic-check", isDirectory: true) }

    /// Words normalized for comparing what was written with what was heard (case, punctuation, Hebrew points).
    static func words(_ s: String) -> [String] {
        var t = s.lowercased().replacingOccurrences(of: "’", with: "'")
        t = t.unicodeScalars.filter { !(0x0591...0x05C7).contains($0.value) }.map(String.init).joined()
        let cleaned = t.map { c -> Character in (c.isLetter || c.isNumber || c == "'") ? c : " " }
        return String(cleaned).split(separator: " ").map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }.filter { !$0.isEmpty }
    }

    /// Word errors (substitutions + insertions + deletions) between what was written and what was heard.
    static func errors(_ ref: String, _ hyp: String) -> Int {
        let a = words(ref), b = words(hyp)
        var d = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var prev = d[0]; d[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let cur = d[j]
                d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return a.isEmpty ? b.count : d[b.count]
    }
}

