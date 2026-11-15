import Foundation

/// "What's this?" right after clicking a part of a 3D model: the teacher answers with a short narrated
/// step on that same model (the camera moves in, the part is opened or shown working, then the model
/// goes back to the lesson's view), and the talker only names the part.
enum PartQuestion {
    /// Whether a question asked right after a click is about the clicked part. A click is a strong hint,
    /// so anything that asks something counts, unless it's clearly about something else (closing the model,
    /// a new topic, thanks, a helper).
    static func isAbout(_ question: String, part name: String) -> Bool {
        let q = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !q.isEmpty else { return false }
        let away = ["close", "clear", "remove", "get rid", "hide", "stop", "thank", "never mind", "nevermind", "forget it",
                    "something else", "another topic", "new topic", "different", "go back", "agent", "helper", "remind",
                    "search", "look up", "open ", "screen", "email", "video", "תודה", "תסגור", "עזוב"]
        if away.contains(where: { q.contains($0) }) { return false }
        let words = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.count <= 3 { return true }   // "this", "and this?", "what's that"
        let pointing: Set<String> = ["this", "that", "it", "it's", "its", "here", "these", "those", "part", "one", "thing", "piece",
                                     "זה", "זאת", "הזה", "הזאת", "esto", "eso", "ça", "das", "dies"]
        if words.contains(where: { pointing.contains($0) }) { return true }
        let named = name.lowercased().split(whereSeparator: { !$0.isLetter }).filter { $0.count > 3 }
        return !named.isEmpty && named.contains(where: { q.contains($0) })
    }

    /// The teacher's brief: continue the model on screen with a step about that part.
    static func brief(modelId: String, name: String, part: String) -> String {
        let what = name.isEmpty ? "one of its parts" : "the part “\(name)”"
        let code = part.isEmpty ? "" : " (in your code: `kit.get('\(part)')`)"
        return "The user clicked \(what)\(code) on the 3D model id=\"\(modelId)\" and asked about it. "
            + "Answer ON THAT MODEL, don't build a new one: 1–3 `<say>` lines, each with a `<step3d id=\"\(modelId)\">` (only the first with a `note`: the part and its job) "
            + "that shows the answer on the part: `const p = kit.clicked();` then move in (`kit.focus(p)`), make it "
            + "clear (a temp label, `kit.highlight`, a `cut`/`xray` to see inside) and show what it does (a flow, a move, a squeeze). "
            + "The model goes back to the lesson's view by itself when you're done. "
            + "Started in parallel with the talker, who only says the part's name in one short line: start with what it does, don't name it again."
    }

    /// What the talker is told instead of the usual hand-over line.
    static func talkerLine(name: String) -> String {
        let say = name.isEmpty ? "“Ah, this part.”" : "“That's the \(name.lowercased()).”"
        return "(The user clicked a part of the 3D model and asked about it. The teacher is ALREADY showing a short narrated step about that part on the model. "
            + "Say ONE short line, in the user's language, that only names it, like \(say) Don't explain what it does (the teacher will, right after you), "
            + "no marks, and do NOT write <visual>.)"
    }
}
