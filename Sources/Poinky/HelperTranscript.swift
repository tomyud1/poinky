import Foundation

/// One line of a helper's window: its task, what it wrote, each step, its to-do list, what it asked
/// and what you answered, and how it ended. Kept next to its log as `<log>.chat.jsonl` (one entry per
/// line), so a past helper's window can be shown again.
struct HelperEntry: Codable, Equatable {
    struct Item: Codable, Equatable { var text: String; var state: String }

    /// task, note, step, todo, blocked, ask, answer, you, end, info, session (its Claude Code session id, in
    /// `id`), checkpoint (the files just before a message to it, in `id`), undone (a run's changes were put back),
    /// worktree (its own copy of the repo: `detail` the folder, `text` your repo, `id` the commit it started
    /// from), merged (its changes were brought back into your folder: `detail` the patch)
    var k: String
    var text: String = ""
    /// step: the exact command, file or query. ask: the exact command or question. task: the folder.
    var detail: String?
    /// step: read, edit, run, test, search, web, agent, skill, other. ask: permission, question.
    /// end: done, failed, stopped. task: the helper's name.
    var kind: String?
    /// ask and answer: the request it belongs to.
    var id: String?
    var items: [Item]?
    /// Seconds since the helper started.
    var t: Double = 0
    /// end: the cost Claude Code reported (dollars), and how long it worked.
    var cost: Double?
    var seconds: Double?
    /// task: the helper's title.
    var title: String?
    /// end: when it finished (seconds since 1970), to tell whether a file changed after that.
    var at: Double?

    /// Its entries split into runs (each ends with its `end`; the last may still be going).
    static func runs(_ entries: [HelperEntry]) -> [[HelperEntry]] {
        var out: [[HelperEntry]] = [], cur: [HelperEntry] = []
        for e in entries {
            cur.append(e)
            if e.k == "end" { out.append(cur); cur = [] }
        }
        if cur.contains(where: { $0.k != "you" && $0.k != "session" }) || (!cur.isEmpty && out.isEmpty) { out.append(cur) }
        return out
    }

    /// The checkpoint at the start of each run (a run ends with an `end`), oldest first: what "undo" puts
    /// the files back to. A run with no checkpoint (an older Claude Code) can't be undone.
    static func runStarts(_ entries: [HelperEntry]) -> [String?] {
        var out: [String?] = [], current: String?
        for e in entries {
            if e.k == "checkpoint", current == nil { current = e.id }
            if e.k == "end" { out.append(current); current = nil }
        }
        if current != nil { out.append(current) }   // still working
        return out
    }

    var json: String {
        guard let d = try? JSONEncoder().encode(self), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    static func read(_ url: URL) -> [HelperEntry] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return s.split(separator: "\n").compactMap { try? dec.decode(HelperEntry.self, from: Data($0.utf8)) }
    }

    /// The kind of step a tool call is (for grouping: "Read 2 files, ran 3 commands").
    static func stepKind(tool: String, input: [String: Any]) -> String {
        switch tool {
        case "Read": return "read"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "edit"
        case "Glob", "Grep": return "search"
        case "WebSearch", "WebFetch": return "web"
        case "Task", "Agent": return "agent"
        case "Skill": return "skill"
        case "Bash": return HelperStream.isTestCommand((input["command"] as? String) ?? "") ? "test" : "run"
        default: return "other"
        }
    }

    /// The exact thing a step works on: a command, a file, a pattern, a page.
    static func stepDetail(tool: String, input: [String: Any]) -> String? {
        let s = { (k: String) -> String? in
            guard let v = input[k] as? String, !v.isEmpty else { return nil }
            return v
        }
        switch tool {
        case "Bash": return s("command")
        case "Read", "Edit", "MultiEdit", "Write": return s("file_path")
        case "NotebookEdit": return s("notebook_path")
        case "Grep", "Glob": return s("pattern")
        case "WebFetch": return s("url")
        case "WebSearch": return s("query")
        case "Task", "Agent": return s("prompt").map { HelperStream.clip($0, 400) }
        default: return nil
        }
    }
}

/// An earlier helper, from its saved window (`.chat.jsonl`): what it was asked, how it ended, and its
/// Claude Code session, so it can be shown again and continued, also after Poinky restarts.
struct PastHelper: Equatable {
    let chat: URL
    let log: URL
    let name: String
    let title: String
    let task: String
    let dir: URL
    /// Its Claude Code session (empty if it never got one: then it starts fresh, told what it did).
    let session: String
    /// It worked in its own copy of the repo (a git worktree) at this folder: continuing it makes it again there.
    var worktree: String? = nil
    /// done, failed, stopped ("stopped" too if Poinky quit while it worked).
    let status: String
    let summary: String
    let started: Date

    /// A short key the main agent uses to continue it (`<agent resume="KEY">`).
    var key: String { session.isEmpty ? chat.deletingPathExtension().deletingPathExtension().lastPathComponent : String(session.prefix(8)) }

    /// From its saved window. Nil if it isn't a helper's window.
    static func load(chat: URL) -> PastHelper? {
        let entries = HelperEntry.read(chat)
        guard let task = entries.first(where: { $0.k == "task" }) else { return nil }
        let end = entries.last(where: { $0.k == "end" })
        // Continued later: the last instruction is what it worked on most recently.
        let lastAsk = entries.last(where: { $0.k == "you" })?.text
        let session = entries.last(where: { $0.k == "session" })?.id ?? ""
        let base = chat.deletingPathExtension().deletingPathExtension()
        let started = (try? FileManager.default.attributesOfItem(atPath: chat.path)[.creationDate] as? Date) ?? Date.distantPast
        return PastHelper(chat: chat, log: base.appendingPathExtension("md"), name: task.kind ?? "Helper",
                          title: task.title ?? HelperStream.clip(task.text, 50), task: lastAsk ?? task.text,
                          dir: URL(fileURLWithPath: task.detail ?? NSHomeDirectory()), session: session,
                          worktree: entries.last(where: { $0.k == "worktree" })?.detail,
                          status: end?.kind ?? "stopped", summary: end?.text ?? "", started: started)
    }

    /// The most recent helpers in a folder of logs, newest first.
    static func list(in dir: URL, limit: Int = 40, excluding: Set<String> = []) -> [PastHelper] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let chats = files.filter { $0.lastPathComponent.hasSuffix(".chat.jsonl") && !excluding.contains($0.place) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
        return chats.compactMap { load(chat: $0.0) }
    }
}

extension URL {
    /// The same file whichever way its path was written (/tmp and /private/tmp, "a/../b").
    var place: String { resolvingSymlinksInPath().standardizedFileURL.path }
}
