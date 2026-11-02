import Foundation

/// What a helper (a background Claude Code session) is doing, as a few plain events the app can
/// show, animate and speak. Made from Claude Code's `stream-json` output, without any model calls.
enum HelperEvent: Equatable {
    /// The session is up.
    case started(session: String, model: String)
    /// A short progress line, like "Reading tipsplit.py" or "Running the tests".
    case step(String)
    /// The first sentence of something it wrote between steps ("Two tests fail, confirming the bug.").
    case note(String)
    /// Its to-do list changed.
    case checklist([HelperTask])
    /// It tried something it isn't allowed to do on its own ("Run curl -sI https://example.com").
    case blocked(String)
    /// It needs your OK, or asked you a question: it waits for your answer.
    case asking(HelperAsk)
    /// Claude Code withdrew a request (by its id): no answer needed anymore.
    case askCancelled(String)
    /// It finished answering. More may follow if a follow-up arrived while it worked.
    case turnEnded(ok: Bool, summary: String, seconds: Double, costUSD: Double?)
}

struct HelperTask: Equatable {
    enum State: String { case pending, active, done }
    let text: String
    let state: State
}

/// Turns the raw stream into `HelperEvent`s. Feed it bytes as they arrive (any chunk size).
struct HelperStream {
    private var buffer = Data()
    /// Tool calls waiting for their result, to explain a refusal: id → what it tried.
    private var calls: [String: String] = [:]
    /// The last progress line, so the same step isn't shown twice in a row.
    private var lastStep = ""

    mutating func feed(_ data: Data) -> [HelperEvent] {
        buffer.append(data)
        var events: [HelperEvent] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                events += parse(obj)
            }
        }
        return events
    }

    mutating func parse(_ obj: [String: Any]) -> [HelperEvent] {
        switch obj["type"] as? String {
        case "system" where obj["subtype"] as? String == "init":
            return [.started(session: obj["session_id"] as? String ?? "", model: obj["model"] as? String ?? "")]

        case "assistant":
            // Work done by its own sub-agents counts as progress, but their chatter doesn't.
            let nested = !(obj["parent_tool_use_id"] is NSNull) && obj["parent_tool_use_id"] != nil
            let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            var out: [HelperEvent] = []
            for c in content {
                switch c["type"] as? String {
                case "text":
                    // Short asides ("Good.") aren't worth showing.
                    if !nested, let t = c["text"] as? String, let s = Self.firstSentence(t), s.split(separator: " ").count >= 3 {
                        out.append(.note(s))
                    }
                case "tool_use":
                    let name = c["name"] as? String ?? ""
                    let input = c["input"] as? [String: Any] ?? [:]
                    if let id = c["id"] as? String { calls[id] = Self.attempt(tool: name, input: input) }
                    if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
                        let list = todos.compactMap(Self.task)
                        out.append(.checklist(list))
                        if let active = todos.first(where: { $0["status"] as? String == "in_progress" }),
                           let form = (active["activeForm"] as? String) ?? (active["content"] as? String) {
                            out.append(.step(Self.clip(form)))
                        }
                    } else if let s = Self.describe(tool: name, input: input) {
                        out.append(.step(s))
                    }
                default: break   // thinking
                }
            }
            return out.filter { e in
                guard case .step(let s) = e else { return true }
                defer { lastStep = s }
                return s != lastStep
            }

        case "user":
            // Tool results: we only care about refusals.
            let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            var out: [HelperEvent] = []
            for c in content where c["type"] as? String == "tool_result" && c["is_error"] as? Bool == true {
                let text = Self.text(of: c["content"])
                if Self.isRefusal(text), let id = c["tool_use_id"] as? String, let tried = calls[id] {
                    out.append(.blocked(tried))
                }
                if let id = c["tool_use_id"] as? String { calls[id] = nil }
            }
            return out

        case "control_request":
            // Permission for something it isn't allowed to do on its own, or a question for you.
            if let ask = HelperAsk.from(obj) { return [.asking(ask)] }
            return []

        case "control_cancel_request":
            if let id = obj["request_id"] as? String { return [.askCancelled(id)] }
            return []

        case "result":
            let ok = !((obj["is_error"] as? Bool) ?? false) && (obj["subtype"] as? String ?? "success") == "success"
            let summary = (obj["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let ms = (obj["duration_ms"] as? NSNumber)?.doubleValue ?? 0
            return [.turnEnded(ok: ok, summary: summary, seconds: ms / 1000, costUSD: (obj["total_cost_usd"] as? NSNumber)?.doubleValue)]

        default:
            return []
        }
    }

    // MARK: - Plain words for what it's doing

    /// "Reading tipsplit.py", "Running the tests", "Searching the web for “swift springs”".
    static func describe(tool: String, input: [String: Any]) -> String? {
        let s = { (k: String) in (input[k] as? String) ?? "" }
        let file = { (k: String) in (s(k) as NSString).lastPathComponent }
        switch tool {
        case "Read": return "Reading \(file("file_path"))"
        case "Edit", "MultiEdit": return "Editing \(file("file_path"))"
        case "Write": return "Writing \(file("file_path"))"
        case "NotebookEdit": return "Editing \(file("notebook_path"))"
        case "Glob": return "Looking through the files"
        case "Grep": return s("pattern").isEmpty ? "Searching the code" : "Searching for “\(clip(s("pattern"), 40))”"
        case "Bash":
            let cmd = s("command")
            if isTestCommand(cmd) { return "Running the tests" }
            if !s("description").isEmpty { return clip(gerund(s("description"))) }
            return "Running \(clip(cmd.components(separatedBy: "\n")[0], 50))"
        case "WebSearch": return "Searching the web for “\(clip(s("query"), 50))”"
        case "WebFetch": return "Reading \(URL(string: s("url"))?.host ?? "a web page")"
        case "Task", "Agent":
            return s("description").isEmpty ? "Handing part of it to a sub-agent" : "Sub-agent: \(clip(s("description"), 60))"
        case "Skill": return "Using the \(s("skill").isEmpty ? "a" : s("skill")) skill"
        case "TodoWrite", "ToolSearch", "TaskOutput", "BashOutput": return nil
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.components(separatedBy: "__")
                return "Using \(parts.last ?? tool)" + (parts.count > 2 ? " (\(parts[1]))" : "")
            }
            return "Using \(tool)"
        }
    }

    /// What it tried, for a refusal: "Run curl -sI https://example.com", "Edit config.json".
    static func attempt(tool: String, input: [String: Any]) -> String {
        if tool == "Bash", let c = input["command"] as? String { return "Run " + clip(c.components(separatedBy: "\n")[0], 80) }
        if let d = describe(tool: tool, input: input) { return d }
        return tool
    }

    static func isTestCommand(_ cmd: String) -> Bool {
        let c = cmd.lowercased()
        return ["pytest", "unittest", "npm test", "npm run test", "vitest", "jest", "swift test", "cargo test", "go test", "rspec", "xcodebuild test"]
            .contains { c.contains($0) }
    }

    static func isRefusal(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["requires approval", "require approval", "requested permissions", "haven't granted", "permission to use", "was blocked", "not allowed", "permission denied by"]
            .contains { t.contains($0) }
    }

    /// "Run existing tests" → "Running existing tests". Already-continuous phrases stay as they are.
    static func gerund(_ phrase: String) -> String {
        var words = phrase.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first, !first.lowercased().hasSuffix("ing") else { return phrase }
        let irregular = ["run": "running", "get": "getting", "set": "setting", "stop": "stopping", "put": "putting",
                         "cut": "cutting", "plan": "planning", "list": "listing", "make": "making", "write": "writing",
                         "remove": "removing", "use": "using", "create": "creating", "update": "updating", "move": "moving",
                         "see": "seeing", "be": "being", "do": "doing", "go": "going", "lint": "linting", "debug": "debugging"]
        let lower = first.lowercased()
        var g: String
        if let i = irregular[lower] { g = i }
        else if lower.hasSuffix("ie") { g = String(lower.dropLast(2)) + "ying" }
        else if lower.hasSuffix("e") && !lower.hasSuffix("ee") && lower.count > 2 { g = String(lower.dropLast()) + "ing" }
        else { g = lower + "ing" }
        if first.first?.isUppercase == true { g = g.prefix(1).uppercased() + g.dropFirst() }
        words[0] = g
        return words.joined(separator: " ")
    }

    // MARK: - Text helpers

    static func task(_ t: [String: Any]) -> HelperTask? {
        guard let text = t["content"] as? String, !text.isEmpty else { return nil }
        let state: HelperTask.State
        switch t["status"] as? String {
        case "completed": state = .done
        case "in_progress": state = .active
        default: state = .pending
        }
        return HelperTask(text: clip(text, 80), state: state)
    }

    /// The first sentence, without Markdown, short enough for a progress line.
    static func firstSentence(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        t = t.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? t
        for mark in ["**", "`", "__", "#"] { t = t.replacingOccurrences(of: mark, with: "") }
        t = t.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"[.!?…:](\s|$)"#, options: .regularExpression) {
            t = String(t[..<r.lowerBound]) + (t[r.lowerBound] == ":" ? "" : String(t[r.lowerBound]))
        }
        return t.isEmpty ? nil : clip(t, 110)
    }

    /// Lowercase words and spaces only ("How's it going?" → "how s it going").
    static func plain(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    static func clip(_ s: String, _ n: Int = 70) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] { return parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return ""
    }
}
