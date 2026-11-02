import Foundation

/// Background agents: separate Claude Code sessions that work on the user's projects while
/// the conversation goes on. Each one runs `claude -p` in the project folder with the user's
/// normal Claude Code setup (CLAUDE.md, MCP servers, skills), and reports back when it's done.
///
/// Every agent's full output is kept in ~/Library/Application Support/Poinky/agents/.
@MainActor
final class AgentManager {
    enum Status: String { case running, done, failed, stopped }

    struct Agent {
        let id: Int
        let title: String
        let task: String
        let dir: URL
        let started: Date
        var finished: Date?
        var status: Status = .running
        var summary = ""
        let log: URL
    }

    private(set) var agents: [Agent] = []
    private var processes: [Int: Process] = [:]
    private var nextID = 1

    /// An agent finished (done or failed): the app tells the user.
    var onFinished: ((Agent) -> Void)?
    /// Something changed (for the notch).
    var onChange: (() -> Void)?

    var running: [Agent] { agents.filter { $0.status == .running } }

    static let safeTools = [
        "Read", "Glob", "Grep", "Edit", "Write", "MultiEdit", "NotebookEdit", "TodoWrite",
        "Bash(ls:*)", "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)",
        "Bash(python3 -m unittest:*)", "Bash(python3 -m pytest:*)", "Bash(pytest:*)", "Bash(python -m pytest:*)",
        "Bash(npm test:*)", "Bash(npm run test:*)", "Bash(npx vitest:*)", "Bash(npx jest:*)",
        "Bash(swift build:*)", "Bash(swift test:*)", "Bash(cargo test:*)", "Bash(go test:*)",
    ]

    static var logDir: URL { AppConfig.dir.appendingPathComponent("agents", isDirectory: true) }

    func start(_ req: AgentRequest, config: AppConfig) -> Agent? {
        guard let claude = ClaudeCodeBrain.findClaude(explicit: config.claudePath) else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dir = home
        if let d = req.dir {
            let expanded = URL(fileURLWithPath: (d as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded.path, isDirectory: &isDir), isDir.boolValue { dir = expanded }
        }
        let id = nextID
        nextID += 1
        try? FileManager.default.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "")
        let safeTitle = req.title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40)
        let log = Self.logDir.appendingPathComponent("\(stamp)-\(String(safeTitle)).md")
        let agent = Agent(id: id, title: req.title, task: req.task, dir: dir, started: Date(), log: log)

        let prompt = """
        You were started by Poinky, the user's voice assistant, to do this in the background:

        \(req.task)

        Notes:
        - The user can't answer questions while you work: make sensible choices and note them.
        - \(req.dir == nil ? "The project's folder wasn't given. Find it under the home folder (look in ~/Desktop, ~/Developer, ~/Documents, ~/Projects, ~/code) by the names mentioned above." : "Work in \(dir.path).")
        - Don't commit, push, publish, send anything, or delete files the user made, unless the task says so.
        - Finish with a short plain-language summary (2–3 sentences, no markdown) of what you did and what the user should check. It will be read aloud.
        """
        let mode = config.agentPermission.isEmpty ? "acceptEdits" : config.agentPermission
        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose",
                    "--permission-mode", mode, "--name", "Poinky: \(req.title)"]
        // Nobody can approve anything while it runs: pre-approve editing the project and a few
        // safe commands (tests, git status/diff/log, listing files). Everything else is refused.
        if mode != "plan" { args += ["--allowedTools", Self.safeTools.joined(separator: " ")] }
        if !config.agentModel.isEmpty { args += ["--model", config.agentModel] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        // A clean Claude Code environment (not settings inherited from wherever Poinky was started).
        for k in env.keys where k.hasPrefix("CLAUDE_CODE_") || k.hasPrefix("CLAUDE_AGENT_SDK") { env[k] = nil }
        env["PATH"] = ["\(home.path)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()

        let header = "# \(req.title)\n\nStarted \(Date())\nFolder: \(dir.path)\n\n## Task\n\n\(req.task)\n\n## Work\n\n"
        try? header.write(to: log, atomically: true, encoding: .utf8)

        // Read the stream: keep everything in the log, and the final result as the summary.
        final class Reader: @unchecked Sendable { var buffer = Data(); var result = ""; var lastText = ""; var isError = false }
        let reader = Reader()
        let logHandle = try? FileHandle(forWritingTo: log)
        logHandle?.seekToEndOfFile()
        out.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            reader.buffer.append(data)
            while let nl = reader.buffer.firstIndex(of: 0x0A) {
                let line = reader.buffer[reader.buffer.startIndex..<nl]
                reader.buffer.removeSubrange(reader.buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                switch obj["type"] as? String {
                case "system" where obj["subtype"] as? String == "init":
                    if let actual = obj["permissionMode"] as? String, actual != mode {
                        logHandle?.write(Data("_Note: asked for permission mode \(mode), Claude Code started in \(actual)._\n\n".utf8))
                    }
                case "assistant":
                    let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
                    for c in content {
                        if c["type"] as? String == "text", let t = c["text"] as? String {
                            reader.lastText = t
                            logHandle?.write(Data((t + "\n\n").utf8))
                        } else if c["type"] as? String == "tool_use", let name = c["name"] as? String {
                            let input = (c["input"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                            logHandle?.write(Data("- \(name) \(input.prefix(300))\n".utf8))
                        }
                    }
                case "result":
                    reader.result = (obj["result"] as? String) ?? ""
                    reader.isError = (obj["is_error"] as? Bool) ?? false
                default: break
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let text = reader.result.isEmpty ? reader.lastText : reader.result
                    logHandle?.write(Data("\n## Result\n\n\(text)\n".utf8))
                    try? logHandle?.close()
                    self?.finished(id: id, ok: status == 0 && !reader.isError, summary: text)
                }
            }
        }
        do { try p.run() } catch { return nil }
        processes[id] = p
        agents.append(agent)
        onChange?()
        return agent
    }

    private func finished(id: Int, ok: Bool, summary: String) {
        processes[id] = nil
        guard let i = agents.firstIndex(where: { $0.id == id }), agents[i].status == .running else { return }
        agents[i].status = ok ? .done : .failed
        agents[i].finished = Date()
        // Keep the summary short enough to be read aloud.
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        agents[i].summary = s.count > 900 ? "…" + s.suffix(900) : s
        onChange?()
        onFinished?(agents[i])
    }

    func stop(id: Int) {
        processes[id]?.terminate()
        if let i = agents.firstIndex(where: { $0.id == id }), agents[i].status == .running {
            agents[i].status = .stopped
            agents[i].finished = Date()
        }
        processes[id] = nil
        onChange?()
    }

    func stopAll() { for id in processes.keys { stop(id: id) } }

    /// For the talker: what's running and what finished.
    func statusLines() -> [String] {
        agents.suffix(6).map { a in
            let mins = Int(((a.finished ?? Date()).timeIntervalSince(a.started) / 60).rounded())
            switch a.status {
            case .running: return "- #\(a.id) \"\(a.title)\": working (\(mins) min so far) in \(a.dir.path)"
            case .done: return "- #\(a.id) \"\(a.title)\": done after \(mins) min. Summary: \(a.summary)"
            case .failed: return "- #\(a.id) \"\(a.title)\": failed. Last output: \(a.summary)"
            case .stopped: return "- #\(a.id) \"\(a.title)\": stopped by the user"
            }
        }
    }
}
