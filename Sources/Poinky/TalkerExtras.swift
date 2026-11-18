import Foundation

/// Parts of the talker's instructions that only some questions need, sent with those questions instead of in
/// the system prompt: the app manual (questions about Poinky), the helpers' finer tags (when helpers exist or
/// the question is about them), and the video section (when a video is asked for, being made or open).
/// A small no-thinking model follows each tag less reliably the more tags it's told about, and the system
/// prompt stays fixed for the life of the `claude -p` session, so these go in the message (first, before
/// the question) and the system prompt stays one stable prefix that prompt caching keeps hitting.
/// Once sent, a part stays in the conversation: it's sent again only after `resendAfter` questions.
enum TalkerExtras {
    enum Part: String, CaseIterable { case app, helpers, video }
    static let resendAfter = 10

    static func file(_ part: Part) -> String {
        switch part {
        case .app: return "poinky-manual"
        case .helpers: return "talker-helpers"
        case .video: return "talker-video"
        }
    }

    /// Your edited copy in the settings folder wins (like the prompts); otherwise the one in the app.
    static func text(_ part: Part) -> String {
        let name = file(part)
        let own = AppConfig.dir.appendingPathComponent(name + ".md")
        if let s = try? String(contentsOf: own, encoding: .utf8), !s.isEmpty { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let url = Bundle.main.url(forResource: name, withExtension: "md"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
