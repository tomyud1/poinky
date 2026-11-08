import Foundation

/// The swappable "brain". Anything that can take a screenshot + text and stream back text.
/// A call uses two: a fast "talker" that answers out loud, and an "artist" that draws.
@MainActor
protocol Brain: AnyObject {
    var displayName: String { get }
    /// Called when a call starts, so the first question doesn't pay the startup cost.
    func warmUp() async throws
    /// Streams text pieces to `onText` and returns the full reply. Calls are answered one at a time.
    func ask(_ question: BrainQuestion, onText: @escaping (String) -> Void) async throws -> String
    /// Ends the session (called when the call ends).
    func stop()
    /// Nobody wants the reply being written now (you interrupted or asked something else):
    /// end it soon so the next question doesn't wait behind it. Keeps the session.
    func cancelCurrent()
}

extension Brain {
    func cancelCurrent() {}
}

/// Runs `op`, but gives up after `seconds` (for system calls that can hang, like ScreenCaptureKit
/// when its service crashed). The work itself may keep running; its late result is dropped.
enum Deadline {
    struct Expired: LocalizedError {
        let what: String
        var errorDescription: String? { "\(what) didn't respond." }
    }

    private final class Once<T>: @unchecked Sendable {
        let lock = NSLock()
        var cont: CheckedContinuation<T, Error>?
        init(_ c: CheckedContinuation<T, Error>) { cont = c }
        func finish(_ r: Result<T, Error>) {
            lock.lock(); let c = cont; cont = nil; lock.unlock()
            c?.resume(with: r)
        }
    }

    static func run<T>(_ seconds: Double, _ what: String, _ op: @escaping () async throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            let once = Once<T>(c)
            Task { do { once.finish(.success(try await op())) } catch { once.finish(.failure(error)) } }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
                if once.cont != nil { Timeline.log("timeout", ["what": what, "secs": seconds]) }
                once.finish(.failure(Expired(what: what)))
            }
        }
    }
}

struct BrainQuestion {
    let text: String
    /// Nil: text only (a follow-up with what a lookup found, or a web search: the screen was already sent).
    let snapshot: Snapshot?

    /// The screenshot, plus the close-up of what you marked (if any).
    var imageBlocks: [[String: Any]] {
        guard let snapshot else { return [] }
        var blocks: [[String: Any]] = [["type": "image",
                                        "source": ["type": "base64", "media_type": "image/jpeg", "data": snapshot.jpegBase64]]]
        if let f = snapshot.focus {
            blocks.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": f.jpegBase64]])
        }
        return blocks
    }

    /// Lines describing the close-up, for the text part of the message.
    static func focusNotes(_ snap: Snapshot) -> [String] {
        guard let f = snap.focus else { return [] }
        let r = f.rectPx
        var lines = ["THE USER MARKED SOMETHING. The second image is a close-up of the marked area (x \(Int(r.minX))–\(Int(r.maxX)), y \(Int(r.minY))–\(Int(r.maxY)) in the screenshot). Your answer must be about this specific content."]
        if !f.text.isEmpty { lines.append("Text inside the marked area:\n«\(f.text)»") }
        return lines
    }
}

struct BrainError: LocalizedError {
    let message: String
    /// Claude Code said the usage limit was hit; when it resets (if it said).
    var limitResetsAt: Date?
    var limitHit = false
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// What to say out loud when a question fails: one short sentence that says what to do,
/// instead of "something went wrong". The exact error still goes in the caption.
enum SpokenError {
    static func line(for error: Error, now: Date = Date()) -> String {
        if let b = error as? BrainError, b.limitHit { return limitLine(b.limitResetsAt, now: now) }
        if error is Deadline.Expired { return "The screen capture got stuck. Ask again, and if it keeps happening, restart Poinky from the notch." }
        let m = error.localizedDescription.lowercased()
        func has(_ words: String...) -> Bool { words.contains { m.contains($0) } }
        if has("usage limit", "hit your limit", "limit reached", "rate limit", "rate_limit", "api error: 429") { return limitLine(nil, now: now) }
        if has("/login", "not logged in", "invalid api key", "authentication", "api error: 401", "oauth") {
            return "Claude Code isn't signed in. Run claude in Terminal and sign in, then ask me again."
        }
        if has("isn't installed") { return "I can't find Claude Code. Install it, or switch to an API key in Settings." }
        if has("overloaded", "api error: 5") { return "Claude's servers are busy right now. Try again in a moment." }
        if has("connection", "network", "offline", "timed out", "could not resolve", "internet") {
            return "I can't reach Claude. Check your internet connection and ask again."
        }
        if has("stopped answering", "stopped unexpectedly") { return "Claude Code got stuck, so I restarted it. Ask me again." }
        return "Sorry, that didn't work. The details are on screen."
    }

    static func limitLine(_ resets: Date?, now: Date = Date()) -> String {
        guard let r = resets, r > now else { return "You've hit your Claude usage limit. I'll work again once it resets." }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(r, inSameDayAs: now) ? "h:mm a" : "EEEE h:mm a"
        return "You've hit your Claude usage limit. It resets at \(f.string(from: r))."
    }
}

@MainActor
enum BrainFactory {
    static func make(config: AppConfig, role: PromptRole) throws -> Brain {
        var prompt = SystemPrompt.load(role)
        // The talker also knows Poinky itself (to answer "how do I…" about the app) and,
        // like the guide, what it remembers about the user.
        if role == .talker, let url = Bundle.main.url(forResource: "poinky-manual", withExtension: "md"),
           let manual = try? String(contentsOf: url, encoding: .utf8) {
            prompt += "\n\n" + manual
        }
        if role == .talker || role == .guide || role == .doer {
            prompt += Identity.promptSection()
            prompt += Memory.promptSection(enabled: config.memoryEnabled)
        }
        if role == .talker { prompt += LookUp.promptSection(config) }
        switch config.brain {
        case .claudeCode:
            return ClaudeCodeBrain(model: config.model(for: role), effort: config.effort(for: role),
                                   claudePath: config.claudePath, systemPrompt: prompt)
        case .api:
            let key = config.apiKey.isEmpty
                ? (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
                : config.apiKey
            guard !key.isEmpty else {
                throw BrainError("Add your Anthropic API key in ✨ menu → Settings → Claude, or switch back to Claude Code.")
            }
            return APIBrain(model: config.model(for: role), effort: config.effort(for: role),
                            apiKey: key, systemPrompt: prompt,
                            maxTokens: role == .artist ? 32000 : 4000)
        }
    }
}

// MARK: - Talker replies

struct TalkEvents {
    var sentences: [String] = []   // ready to speak
    var draws: [String] = []       // JSON specs for the overlay
    var visual: String?            // a request for the artist
    var guide: String?             // start guide mode toward this goal
    var doTask: String?            // do this task for the user (clicks and types)
    var done: String?              // (guide) the task is finished
    var acts: [String] = []        // (doer) JSON actions to perform: click, type, key, scroll
    var ask: String?               // (doer) a question for the user; wait for their answer
    var end = false                // the user said goodbye: end the session after speaking
    var settings: [String] = []    // JSON objects of settings to change
    var remember: [String] = []    // things to remember about the user
    var forget: [String] = []      // things to forget
    var agents: [AgentRequest] = []
    var tells: [(name: String, text: String)] = []   // a follow-up for a working helper, by name
    var stops: [String] = []                          // helpers to stop, by name
    var undos: [String] = []                          // helpers whose last changes to undo, by name or key
    var recall: String?            // look up earlier conversations, helpers and Claude Code sessions
    var search: String?            // look this up on the web (a separate session with only web tools)

    /// A reply that answers from what a lookup found: web pages and old transcripts are data, so only
    /// speaking, marking the screen and asking the teacher for a sketch count. Nothing that acts
    /// (clicks, helpers, settings, memory, ending the session) and no second lookup.
    func onlySpeech() -> TalkEvents {
        var e = TalkEvents()
        e.sentences = sentences
        e.draws = draws
        e.visual = visual
        return e
    }
    /// Has anything that would act (for logging what a lookup reply tried to do).
    var wouldAct: Bool {
        guide != nil || doTask != nil || !settings.isEmpty || !remember.isEmpty || !forget.isEmpty || !agents.isEmpty
            || !tells.isEmpty || !stops.isEmpty || !undos.isEmpty || end || video != nil || recall != nil || search != nil
    }
    var video: (title: String, brief: String)?        // make a video explainer about this
    var videoCancel = false                           // stop the video being made
    var videoClose = false                            // close the video on screen
    var videoPlay = false                             // continue the paused video
}

/// A background job for a Claude Code agent, asked for by the talker.
struct AgentRequest: Equatable {
    let title: String
    let dir: String?
    let task: String
    /// A model for just this task ("use Opus for this one"): a full model name. Nil: the helpers' setting.
    var model: String? = nil
    /// Make a plan first and wait for the user's go-ahead before changing anything.
    var planFirst = false
    /// The talker's `resume="KEY"`: continue an earlier helper (see `PastHelper.key`).
    var resumeKey: String? = nil
    /// Continuing an earlier helper: its Claude Code session (empty if it never got one), its log, its
    /// name, and what it did (for a fresh start when there's no session to resume).
    var resume: String? = nil
    var continueLog: URL? = nil
    var name: String? = nil
    var earlier: String? = nil
    /// Continuing a helper that worked in its own git worktree: that folder (made again there).
    var worktreePath: String? = nil
    /// Continuing one of the user's own Claude Code sessions: resume a copy of it (`--fork-session`), so
    /// the original stays as it was in their terminal.
    var fork = false

    /// "opus", "Sonnet 5.5", "claude-haiku-5-5" → a full model name Claude Code knows. Nil if it isn't one.
    static func modelName(_ s: String?) -> String? {
        guard let t = s?.lowercased().trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        if t.hasPrefix("claude-") { return t }
        for (word, id) in [("fable", "claude-fable-5-1"), ("opus", "claude-opus-5-5"), ("sonnet", "claude-sonnet-5-5"), ("haiku", "claude-haiku-5-5")]
        where t.contains(word) { return id }
        return nil
    }
}

/// Pulls <say>, <draw> and <visual> out of the talker's reply while it streams in.
/// Speech starts with the first complete sentence, before the reply is finished.
struct TalkParser {
    private(set) var text = ""
    private var sayEmitted = 0       // characters of the <say> body already handed out
    private var sayClosed = false
    private var drew = false
    private var visualDone = false
    private var guideDone = false
    private var doDone = false
    private var doneDone = false

    mutating func feed(_ delta: String) -> TalkEvents {
        text += delta
        var ev = TalkEvents()
        ev.sentences = takeSentences(final: false)
        if !drew, let d = Self.between(text, "<draw>", "</draw>") {
            drew = true
            if let j = JSONRepair.clean(d) { ev.draws.append(j) }
        }
        if !visualDone, let v = Self.between(text, "<visual>", "</visual>") {
            visualDone = true
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { ev.visual = t }
        }
        if !guideDone, let g = Self.between(text, "<guide>", "</guide>") {
            guideDone = true
            let t = g.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { ev.guide = t }
        }
        if !doDone, let g = Self.between(text, "<do>", "</do>") {
            doDone = true
            let t = g.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { ev.doTask = t }
        }
        if !doneDone, let d = Self.between(text, "<done>", "</done>") {
            doneDone = true
            ev.done = d.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ev
    }

    /// Called when the reply is complete; recovers if the format wasn't followed exactly.
    mutating func finish() -> TalkEvents {
        var ev = TalkEvents()
        if text.contains("<say>") {
            ev.sentences = takeSentences(final: true)
        } else if sayEmitted == 0 {
            var s = text
            for tag in ["<draw>", "<visual>", "<guide>", "<do>", "<act", "<ask>", "<done>", "<end", "<set>", "<remember>", "<forget>", "<agent", "<tell", "<stop", "<undo", "<video", "<recall", "<search"] {
                if let r = s.range(of: tag) { s = String(s[..<r.lowerBound]) }
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { ev.sentences = [s] }
            sayEmitted = 1
        }
        if !drew, let r = text.range(of: "<draw>") {
            drew = true
            var body = String(text[r.upperBound...])
            if let e = body.range(of: "</draw>") ?? body.range(of: "<visual>") { body = String(body[..<e.lowerBound]) }
            if let j = JSONRepair.clean(body) { ev.draws.append(j) }
        }
        if !visualDone, let r = text.range(of: "<visual>") {
            visualDone = true
            var t = String(text[r.upperBound...])
            if let e = t.range(of: "</visual>") { t = String(t[..<e.lowerBound]) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { ev.visual = t }
        }
        // The actions that only matter once the reply is complete.
        ev.end = text.range(of: #"<end\s*/?>"#, options: .regularExpression) != nil
        ev.acts = Self.blocks(text, "act").compactMap { JSONRepair.clean($0.body) }
        ev.ask = Self.blocks(text, "ask").first.map(\.body).flatMap { $0.isEmpty ? nil : $0 }
        if !doDone, let g = Self.blocks(text, "do").first?.body, !g.isEmpty { doDone = true; ev.doTask = g }
        ev.settings = Self.blocks(text, "set").compactMap { JSONRepair.clean($0.body) }
        ev.remember = Self.blocks(text, "remember").map(\.body).filter { !$0.isEmpty }
        ev.forget = Self.blocks(text, "forget").map(\.body).filter { !$0.isEmpty }
        ev.agents = Self.blocks(text, "agent").compactMap { b in
            guard !b.body.isEmpty else { return nil }
            let dir = Self.attr("dir", in: b.attrs).flatMap { $0.isEmpty ? nil : $0 }
            return AgentRequest(title: Self.attr("title", in: b.attrs) ?? "Agent", dir: dir, task: b.body,
                                model: AgentRequest.modelName(Self.attr("model", in: b.attrs)),
                                planFirst: ["true", "yes", "1"].contains((Self.attr("plan", in: b.attrs) ?? "").lowercased()),
                                resumeKey: Self.attr("resume", in: b.attrs).flatMap { $0.isEmpty ? nil : $0 })
        }
        ev.tells = Self.blocks(text, "tell").compactMap { b in
            guard let name = Self.attr("agent", in: b.attrs), !name.isEmpty, !b.body.isEmpty else { return nil }
            return (name, b.body)
        }
        if let re = try? NSRegularExpression(pattern: #"<stop\s+agent\s*=\s*"([^"]+)"\s*/?>"#) {
            let ns = text as NSString
            ev.stops = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        }
        ev.videoCancel = text.range(of: #"<video-cancel\s*/?>"#, options: .regularExpression) != nil
        ev.videoClose = text.range(of: #"<video-close\s*/?>"#, options: .regularExpression) != nil
        ev.videoPlay = text.range(of: #"<video-play\s*/?>"#, options: .regularExpression) != nil
        if let b = Self.blocks(text, "video").first, !b.body.isEmpty {
            ev.video = (Self.attr("title", in: b.attrs).flatMap { $0.isEmpty ? nil : $0 } ?? String(b.body.prefix(60)), b.body)
        }
        ev.recall = Self.blocks(text, "recall").first.map(\.body).flatMap { $0.isEmpty ? nil : $0 }
        ev.search = Self.blocks(text, "search").first.map(\.body).flatMap { $0.isEmpty ? nil : $0 }
        if let re = try? NSRegularExpression(pattern: #"<undo\s+agent\s*=\s*"([^"]+)"\s*/?>"#) {
            let ns = text as NSString
            ev.undos = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        }
        return ev
    }

    /// Every <tag attrs>body</tag> in the text.
    static func blocks(_ text: String, _ tag: String) -> [(attrs: String, body: String)] {
        guard let re = try? NSRegularExpression(pattern: "<\(tag)(\\s[^>]*)?>([\\s\\S]*?)</\(tag)>") else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            let attrs = m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1))
            return (attrs, ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func attr(_ name: String, in attrs: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\(name)\\s*=\\s*\"([^\"]*)\""),
              let m = re.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)),
              let r = Range(m.range(at: 1), in: attrs) else { return nil }
        return String(attrs[r])
    }

    /// Everything inside <say> so far, for the live caption.
    var sayPreview: String {
        sayBody().body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// All <say> blocks so far, joined (a long reading sometimes continues in a second block).
    private func sayBody() -> (body: String, closed: Bool) {
        var parts: [String] = []
        var rest = Substring(text)
        var closed = false
        while let open = rest.range(of: "<say>") {
            let after = rest[open.upperBound...]
            if let close = after.range(of: "</say>") {
                parts.append(String(after[..<close.lowerBound]))
                rest = after[close.upperBound...]
                closed = true
            } else {
                var body = String(after)
                // Don't speak half of a closing tag that's still arriving.
                if let lt = body.lastIndex(of: "<"), !body[lt...].contains(">") { body = String(body[..<lt]) }
                parts.append(body)
                closed = false
                break
            }
        }
        return (parts.joined(separator: " "), closed)
    }

    private mutating func takeSentences(final: Bool) -> [String] {
        guard !sayClosed else { return [] }
        let (body, closed) = sayBody()
        let chars = Array(body)
        guard chars.count > sayEmitted else {
            if final { sayClosed = true }
            return []
        }
        var out: [String] = []
        var start = sayEmitted
        var i = sayEmitted
        let enders: Set<Character> = [".", "!", "?", "…", "\n"]
        // The very first piece can also end at a comma (once it has a few words), so the
        // voice starts right away instead of waiting for a whole sentence.
        let softEnders: Set<Character> = [",", ";", ":", "—"]
        while i < chars.count {
            let first = sayEmitted == 0 && out.isEmpty && start == 0
            if first, softEnders.contains(chars[i]),
               String(chars[start...i]).split(separator: " ").count >= 3,
               i + 1 < chars.count, chars[i + 1].isWhitespace {
                out.append(String(chars[start...i]))
                start = i + 1
                i += 1
                continue
            }
            if enders.contains(chars[i]) {
                var j = i + 1
                while j < chars.count, "\"')]”’".contains(chars[j]) { j += 1 }
                // A sentence ends at punctuation followed by a space (or the end, once </say> arrived).
                if j < chars.count, chars[j].isWhitespace {
                    out.append(String(chars[start..<j]))
                    start = j
                    i = j
                    continue
                }
            }
            i += 1
        }
        if closed || final {
            // The block ended: its last words are a sentence too. (More blocks may follow.)
            if start < chars.count { out.append(String(chars[start...])) }
            start = chars.count
            if final { sayClosed = true }
        }
        sayEmitted = start
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func between(_ s: String, _ open: String, _ close: String) -> String? {
        guard let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound])
    }
}

// MARK: - Artist replies

/// Pulls finished <panel …>HTML</panel> and <scene3d …>JS</scene3d> blocks out of the artist's reply.
struct ArtistParser {
    private(set) var text = ""
    private var sent = 0
    private static let blockRegex = try! NSRegularExpression(pattern: #"<(panel|scene3d)\b([^>]*)>([\s\S]*?)</\1>"#)
    private static let attrRegex = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*"([^"]*)""#)

    mutating func feed(_ delta: String) -> [String] {
        text += delta
        let ns = text as NSString
        let matches = Self.blockRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard matches.count > sent else { return [] }
        var out: [String] = []
        for m in matches[sent...] {
            let kind = ns.substring(with: m.range(at: 1))
            let attrs = ns.substring(with: m.range(at: 2))
            let body = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            var item: [String: Any] = ["type": kind]
            item[kind == "panel" ? "html" : "code"] = Self.stripFences(body)
            let ans = attrs as NSString
            for a in Self.attrRegex.matches(in: attrs, range: NSRange(location: 0, length: ans.length)) {
                let key = ans.substring(with: a.range(at: 1))
                let val = ans.substring(with: a.range(at: 2))
                if ["x", "y", "w", "h"].contains(key) { item[key] = Double(val) ?? 0 } else { item[key] = val }
            }
            let spec: [String: Any] = ["items": [item]]
            if let data = try? JSONSerialization.data(withJSONObject: spec),
               let s = String(data: data, encoding: .utf8) { out.append(s) }
        }
        sent = matches.count
        return out
    }

    /// Models sometimes wrap code in ``` fences inside the tag.
    private static func stripFences(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n")
        if let f = lines.first, f.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeFirst() }
        if let l = lines.last, l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - JSON repair

enum JSONRepair {
    /// Returns compact, valid JSON (safe to hand to the overlay page), or nil.
    /// Repairs small bracket slips (an extra or missing `}` / `]`).
    static func clean(_ s: String) -> String? {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return nil }
        let sub = String(s[a...b])
        let keyed = fixMissingKeys(sub)
        for candidate in [sub, balanceBrackets(sub), balanceBrackets(sub, dropStray: true),
                          keyed, balanceBrackets(keyed), balanceBrackets(keyed, dropStray: true)] {
            if let obj = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)),
               obj is [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: obj),
               let out = String(data: data, encoding: .utf8) { return out }
        }
        return nil
    }

    /// Fixes a common slip: `"x":730,192` (the "y" key left out). Same for x1/y1 and x2/y2.
    static func fixMissingKeys(_ s: String) -> String {
        var out = s
        for (x, y) in [("x", "y"), ("x1", "y1"), ("x2", "y2")] {
            let pattern = "(\"\(x)\"\\s*:\\s*-?[0-9.]+\\s*,\\s*)(-?[0-9.]+)(\\s*[,}])"
            if let re = try? NSRegularExpression(pattern: pattern) {
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                  withTemplate: "$1\"\(y)\":$2$3")
            }
        }
        return out
    }

    /// Drops closing brackets that don't match and adds any that are missing.
    /// `dropStray`: a closing bracket that doesn't match is simply dropped (an extra `}` typed by
    /// mistake), instead of closing everything up to its match.
    static func balanceBrackets(_ s: String, dropStray: Bool = false) -> String {
        var out = ""
        var stack: [Character] = []
        var inString = false, escaped = false
        for ch in s {
            if inString {
                out.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true; out.append(ch)
            case "{": stack.append("}"); out.append(ch)
            case "[": stack.append("]"); out.append(ch)
            case "}", "]":
                if stack.last == ch { stack.removeLast(); out.append(ch) }
                else if dropStray { continue }
                else if stack.contains(ch) {
                    while let top = stack.popLast() { out.append(top); if top == ch { break } }
                }
            default: out.append(ch)
            }
        }
        while let top = stack.popLast() { out.append(top) }
        return out
    }
}

// MARK: - Teacher replies (lessons)

/// What the teacher (artist) sends, piece by piece as it streams:
///   <lesson title="…">  <say>…</say>  <step>[ops]</step>  …  </lesson>
/// or a finished <scene3d …>…</scene3d> / <panel …>…</panel> card.
enum ArtistEvent: Equatable {
    case lessonStart(title: String, continuing: Bool)
    case step3d(id: String, code: String, note: String?)   // code to run in an existing 3D model while a line is spoken,
                                                         // and its short note for the list beside the model
    case say(String)
    case step(String)        // {"ops":[…]} JSON
    case lessonEnd
    case card(String)        // {"items":[…]} JSON for a 3D model or panel
    case sceneCode(id: String, code: String)   // more lines of a 3D model that's being written (it builds as they arrive)
    case sceneEnd(id: String)                  // the 3D model's code is complete
    case photo(query: String, forId: String?)  // pin a photo of the real thing (photo="…" on <scene3d> or <lesson>)
}

struct ArtistStream {
    private(set) var text = ""
    private var pos = 0          // UTF-16 offset of what's been handled
    private var cards = ArtistParser()
    private var openScene: String?   // id of the <scene3d> whose code is still arriving
    private var sceneCount = 0

    mutating func feed(_ delta: String) -> [ArtistEvent] {
        text += delta
        var out: [ArtistEvent] = []
        let ns = text as NSString
        while pos < ns.length {
            // Inside a 3D model: pass its code on line by line, so it builds while it's being written.
            if let id = openScene {
                let rest = NSRange(location: pos, length: ns.length - pos)
                let close = ns.range(of: "</scene3d>", options: [], range: rest)
                if close.location != NSNotFound {
                    let code = ns.substring(with: NSRange(location: pos, length: close.location - pos))
                    if !code.isEmpty { out.append(.sceneCode(id: id, code: code)) }
                    out.append(.sceneEnd(id: id))
                    openScene = nil
                    pos = close.location + close.length
                    continue
                }
                // Only whole lines: a partial one might be the start of "</scene3d>".
                let nl = ns.range(of: "\n", options: .backwards, range: rest)
                if nl.location != NSNotFound {
                    let end = nl.location + 1
                    out.append(.sceneCode(id: id, code: ns.substring(with: NSRange(location: pos, length: end - pos))))
                    pos = end
                }
                break
            }
            let lt = ns.range(of: "<", options: [], range: NSRange(location: pos, length: ns.length - pos))
            guard lt.location != NSNotFound else { pos = ns.length; break }
            let tail = ns.substring(from: lt.location)
            let known = ["<lesson", "</lesson>", "<say>", "<step>", "<step3d", "<scene3d", "<panel"]
            // Not enough text yet to tell which tag this is.
            if !known.contains(where: { tail.hasPrefix($0) }), known.contains(where: { $0.hasPrefix(tail) }) { break }

            if tail.hasPrefix("</lesson>") {
                out.append(.lessonEnd)
                pos = lt.location + 9
            } else if tail.hasPrefix("<lesson") {
                guard let gt = tail.firstIndex(of: ">") else { break }
                let attrs = String(tail[tail.startIndex..<gt])
                out.append(.lessonStart(title: Self.attr("title", in: attrs) ?? "",
                                        continuing: Self.attr("continue", in: attrs) == "true"))
                if let p = Self.attr("photo", in: attrs), !p.isEmpty { out.append(.photo(query: p, forId: nil)) }
                pos = lt.location + (tail[tail.startIndex...gt] as Substring).utf16.count
            } else if tail.hasPrefix("<say>") {
                guard let close = tail.range(of: "</say>") else { break }
                let inner = tail[tail.index(tail.startIndex, offsetBy: 5)..<close.lowerBound]
                let s = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { out.append(.say(s)) }
                pos = lt.location + (tail[tail.startIndex..<close.upperBound] as Substring).utf16.count
            } else if tail.hasPrefix("<step>") {
                guard let close = tail.range(of: "</step>") else { break }
                let inner = String(tail[tail.index(tail.startIndex, offsetBy: 6)..<close.lowerBound])
                if let json = JSONRepair.clean("{\"ops\":" + inner.trimmingCharacters(in: .whitespacesAndNewlines) + "}") ?? Self.salvageOps(inner) {
                    out.append(.step(json))
                }
                pos = lt.location + (tail[tail.startIndex..<close.upperBound] as Substring).utf16.count
            } else if tail.hasPrefix("<step3d") {
                guard let gt = Self.tagEnd(tail), let close = tail.range(of: "</step3d>") else { break }
                let attrs = String(tail[tail.startIndex..<gt])
                let code = String(tail[tail.index(after: gt)..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = Self.attr("id", in: attrs), !code.isEmpty {
                    out.append(.step3d(id: id, code: code, note: Self.attr("note", in: attrs).map(Self.unescape)))
                }
                pos = lt.location + (tail[tail.startIndex..<close.upperBound] as Substring).utf16.count
            } else if tail.hasPrefix("<scene3d") {
                // The model appears as soon as its tag opens; its code follows as it's written.
                guard let gt = tail.firstIndex(of: ">") else { break }
                let attrs = String(tail[tail.startIndex..<gt])
                sceneCount += 1
                let id = Self.attr("id", in: attrs) ?? "model\(sceneCount)"
                var item: [String: Any] = ["type": "scene3d", "id": id, "code": "", "stream": true]
                if let title = Self.attr("title", in: attrs) { item["title"] = title }
                if let data = try? JSONSerialization.data(withJSONObject: ["items": [item]]),
                   let spec = String(data: data, encoding: .utf8) { out.append(.card(spec)) }
                if let p = Self.attr("photo", in: attrs), !p.isEmpty { out.append(.photo(query: p, forId: id)) }
                openScene = id
                pos = lt.location + (tail[tail.startIndex...gt] as Substring).utf16.count
            } else if tail.hasPrefix("<panel") {
                let closeTag = "</panel>"
                guard let close = tail.range(of: closeTag) else { break }
                let block = String(tail[tail.startIndex..<close.upperBound])
                for spec in cards.feed(block) { out.append(.card(spec)) }
                pos = lt.location + block.utf16.count
            } else {
                pos = lt.location + 1   // some other "<": skip it
            }
        }
        return out
    }

    /// The reply ended: finish a 3D model whose closing tag never came.
    mutating func finish() -> [ArtistEvent] {
        guard let id = openScene else { return [] }
        openScene = nil
        let ns = text as NSString
        var out: [ArtistEvent] = []
        if pos < ns.length { out.append(.sceneCode(id: id, code: ns.substring(from: pos))) }
        pos = ns.length
        out.append(.sceneEnd(id: id))
        return out
    }

    /// When a step's JSON is broken, keep every operation that is valid on its own.
    static func salvageOps(_ s: String) -> String? {
        var ops: [Any] = []
        var depth = 0, start: String.Index?, inString = false, escaped = false
        for i in s.indices {
            let ch = s[i]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{": if depth == 0 { start = i }; depth += 1
            case "}":
                depth -= 1
                if depth == 0, let st = start {
                    if let obj = try? JSONSerialization.jsonObject(with: Data(s[st...i].utf8)) as? [String: Any] { ops.append(obj) }
                    start = nil
                }
                if depth < 0 { depth = 0 }
            default: break
            }
        }
        guard !ops.isEmpty, let data = try? JSONSerialization.data(withJSONObject: ["ops": ops]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The ">" that ends the opening tag at the start of s, skipping any inside quoted attributes
    /// (a note like "pressure -> flow").
    static func tagEnd(_ s: String) -> String.Index? {
        var quoted = false
        for i in s.indices {
            if s[i] == "\"" { quoted.toggle() } else if s[i] == ">", !quoted { return i }
        }
        return nil
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func attr(_ name: String, in s: String) -> String? {
        // " name=": a whole attribute name (so "id" doesn't match inside another name)
        guard let r = s.range(of: " " + name + "=\"") else { return nil }
        let rest = s[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
