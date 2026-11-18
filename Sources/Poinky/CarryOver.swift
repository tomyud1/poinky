import Foundation

/// The end of the previous session, for the first question of a new one (`CallController.talkerText`), so
/// "and the other one?" or "what did you say about it?" still make sense. It must never be mistaken for the
/// screen now: an old answer about a Cursor bug list was repeated about an essay in TextEdit, because the block
/// only said "the end of your previous session". So it's labeled as another moment with what was in front then,
/// and it's left out when the front app or window changed and the question doesn't refer back.
enum CarryOver {
    struct Item {
        var you: String
        var poinky: String
        var app: String?
        var window: String?
        var lesson: String?
    }

    /// "earlier", "you said", "the other one", "continue"…: the question picks up from before.
    static func refersBack(_ question: String) -> Bool {
        let q = " " + question.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        let cues = [" earlier", " before", " last time", " again", " you said", " you told", " you mentioned", " we talked",
                    " we were", " we did", " previous", " where were we", " pick up", " continue", " go on", " keep going",
                    " the other one", " back to", " remind me what", " what did we", " what did you", " what was that",
                    " that thing", " the rest", " next one", " last session", " a minute ago",
                    " a few minutes ago", " just now", " we just",
                    "קודם", "שוב", "אמרת", "דיברנו", "נמשיך", "תמשיך", "המשך"]
        return cues.contains { q.contains($0) }
    }

    static func same(_ a: String?, _ b: String) -> Bool {
        guard let a, !a.isEmpty, !b.isEmpty else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// The lines for the talker (empty: leave it out). `app` / `window`: what's in front now.
    static func lines(_ items: [Item], ago: String, question: String, app: String, window: String) -> [String] {
        guard let last = items.last else { return [] }
        // The same app, and the same window when both are known.
        let sameApp = same(last.app, app)
        let sameWindow = last.window == nil || window.isEmpty || same(last.window, window)
        let sameScreen = sameApp && sameWindow
        guard sameScreen || refersBack(question) else { return [] }
        let then = Array(Set(items.compactMap { $0.app }.filter { !$0.isEmpty })).sorted()
        let thenText = then.isEmpty ? "" : " with \(then.joined(separator: " and ")) in front then"
        var out = ["Your previous session with the user, \(ago)\(thenText): a different moment, NOT the screen now"
                   + (sameScreen ? "" : " (the user is in \(app.isEmpty ? "another app" : app) now)")
                   + ". Use it only if they refer back to it; what's on screen now comes only from the screenshot and the lines above:"]
        for e in items {
            var s = "- " + (e.you.isEmpty ? "(nobody asked)" : "User: \(clip(e.you, 200))")
            if !e.poinky.isEmpty { s += " / You: \(clip(e.poinky, 300))" }
            if let l = e.lesson, !l.isEmpty { s += " / Your sketch: \(clip(l, 200))" }
            if let a = e.app, !a.isEmpty { s += " [in \(a)\(e.window.map { ", “\(clip($0, 50))”" } ?? "")]" }
            out.append(s)
        }
        return out
    }

    static func clip(_ s: String, _ n: Int) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count > n ? String(t.prefix(n - 1)) + "…" : t
    }
}
