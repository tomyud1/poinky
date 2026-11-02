import Foundation

/// Helpers (background agents): separate Claude Code sessions that work on the user's projects
/// while the conversation goes on. Each one runs `claude -p` in the project folder with the user's
/// normal Claude Code setup (CLAUDE.md, MCP servers, skills), and reports back when it's done.
///
/// A helper's input stays open while it works, so the user can send it follow-ups (`send`).
/// Its output is turned into plain `HelperEvent`s (steps, notes, its to-do list, refusals) for the
/// screen. At most `maxRunning` work at once; more wait in line and start when one finishes.
///
/// Every helper's progress is kept in ~/Library/Application Support/Poinky/agents/: a readable
/// `.md` log, and the raw stream as `.jsonl` (each line with `_t`, seconds since start), which can
/// be replayed with tools/fake-helper.py.
///
/// For testing without tokens, `POINKY_HELPER_CMD=/path/to/tools/fake-helper.py` runs that instead of Claude Code.
@MainActor
final class AgentManager {
    enum Status: String { case queued, running, done, failed, stopped }

    struct Agent {
        let id: Int
        /// Its name on screen and in conversation ("Mint"); one per helper that's queued or working.
        let name: String
        let title: String
        let task: String
        let dir: URL
        let started: Date
        var finished: Date?
        var status: Status = .running
        var summary = ""
        let log: URL
        var session = ""
        var model = ""
        /// Progress lines, oldest first (the last 40).
        var steps: [String] = []
        /// The newest step or note: what it's doing right now.
        var latest = ""
        var checklist: [HelperTask] = []
        /// Things it tried but isn't allowed to do on its own.
        var blocked: [String] = []
        var followUps: [String] = []
        var turns = 0
    }

    /// Helper names, in the order they're handed out, each with its own color (web/helpers.js).
    /// No "Blue": the main buddy is blue.
    static let names = ["Mint", "Coral", "Violet", "Amber", "Rose", "Sky"]
    /// After a turn ends, how long to wait for more (a follow-up that just arrived) before letting it finish.
    static var turnGrace: TimeInterval = 3

    private(set) var agents: [Agent] = []
    private var processes: [Int: Process] = [:]
    private var inputs: [Int: FileHandle] = [:]
    private var lastTurn: [Int: (ok: Bool, summary: String)] = [:]
    private var closeWork: [Int: DispatchWorkItem] = [:]
    private var waiting: [(id: Int, req: AgentRequest, config: AppConfig)] = []
    private var nextID = 1
    /// How many helpers may work at once (the rest wait in line). From `AppConfig.maxHelpers`.
    var maxRunning = 3

    /// A helper finished (done or failed): the app tells the user.
    var onFinished: ((Agent) -> Void)?
    /// Something changed (for the notch).
    var onChange: (() -> Void)?
    /// A helper made progress (for the screen).
    var onEvent: ((Agent, HelperEvent) -> Void)?

    var running: [Agent] { agents.filter { $0.status == .running } }
    var queued: [Agent] { agents.filter { $0.status == .queued } }

    static let safeTools = [
        "Read", "Glob", "Grep", "Edit", "Write", "MultiEdit", "NotebookEdit", "TodoWrite",
        "Bash(ls:*)", "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)",
        "Bash(python3 -m unittest:*)", "Bash(python3 -m pytest:*)", "Bash(pytest:*)", "Bash(python -m pytest:*)",
        "Bash(npm test:*)", "Bash(npm run test:*)", "Bash(npx vitest:*)", "Bash(npx jest:*)",
        "Bash(swift build:*)", "Bash(swift test:*)", "Bash(cargo test:*)", "Bash(go test:*)",
    ]

    static var logDir: URL {
        if let d = ProcessInfo.processInfo.environment["POINKY_AGENT_LOG_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return AppConfig.dir.appendingPathComponent("agents", isDirectory: true)
    }

    /// Starts a helper, or puts it in line if `maxRunning` are already working.
    /// Returns nil if Claude Code isn't installed.
    func start(_ req: AgentRequest, config: AppConfig) -> Agent? {
        guard let exe = Self.executable(config: config) else { return nil }
        maxRunning = max(1, min(Self.names.count, config.maxHelpers))
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
        var agent = Agent(id: id, name: freeName(), title: req.title, task: req.task, dir: dir, started: Date(), log: log)
        if running.count >= maxRunning {
            agent.status = .queued
            agents.append(agent)
            waiting.append((id, req, config))
            onChange?()
            return agent
        }
        agents.append(agent)
        guard launch(id: id, req: req, config: config, exe: exe) else {
            agents.removeAll { $0.id == id }
            return nil
        }
        onChange?()
        return agent
    }

    /// Sends a follow-up to a working helper. False if it isn't working (finished, stopped, or still in line).
    @discardableResult
    func send(id: Int, text: String) -> Bool {
        guard let input = inputs[id], let i = agents.firstIndex(where: { $0.id == id }), agents[i].status == .running,
              let line = Self.userLine(text) else { return false }
        do { try input.write(contentsOf: line) } catch { return false }
        closeWork[id]?.cancel()
        closeWork[id] = nil
        agents[i].followUps.append(text)
        appendLog(agents[i], "\n## Follow-up\n\n\(text)\n\n")
        onChange?()
        return true
    }

    func stop(id: Int) {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = agents[i].status == .running || agents[i].status == .queued
        if agents[i].status == .running || agents[i].status == .queued {
            agents[i].status = .stopped
            agents[i].finished = Date()
        }
        waiting.removeAll { $0.id == id }
        closeWork[id]?.cancel()
        closeWork[id] = nil
        processes[id]?.terminate()
        processes[id] = nil
        try? inputs[id]?.close()
        inputs[id] = nil
        onChange?()
        if wasActive { startWaiting() }
    }

    func stopAll() {
        for id in waiting.map(\.id) { stop(id: id) }
        for id in Array(processes.keys) { stop(id: id) }
    }

    /// For the talker: what's working, waiting and finished.
    func statusLines() -> [String] {
        agents.suffix(8).map { a in
            let mins = Int(((a.finished ?? Date()).timeIntervalSince(a.started) / 60).rounded())
            let who = "- #\(a.id) \(a.name) \"\(a.title)\""
            switch a.status {
            case .queued:
                return "\(who): waiting for a free slot (at most \(maxRunning) helpers work at once)"
            case .running:
                var s = "\(who): working (\(mins) min so far) in \(a.dir.path)"
                if !a.latest.isEmpty { s += ". Now: \(a.latest)" }
                if !a.checklist.isEmpty {
                    s += ". To-do: \(a.checklist.filter { $0.state == .done }.count) of \(a.checklist.count) done"
                }
                if !a.blocked.isEmpty { s += ". Wasn't allowed to: " + a.blocked.suffix(3).joined(separator: "; ") }
                return s
            case .done: return "\(who): done after \(mins) min. Summary: \(a.summary)"
            case .failed: return "\(who): failed. Last output: \(a.summary)"
            case .stopped: return "\(who): stopped by the user"
            }
        }
    }

    // MARK: - Running one

    private func launch(id: Int, req: AgentRequest, config: AppConfig, exe: String) -> Bool {
        guard let agent = agents.first(where: { $0.id == id }) else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = agent.dir
        let prompt = """
        You were started by Poinky, the user's voice assistant, to do this in the background. On screen you're the helper called \(agent.name).

        \(req.task)

        Notes:
        - The user can't answer questions while you work: make sensible choices and note them. They may send you follow-up messages; fold them into the work.
        - \(req.dir == nil ? "The project's folder wasn't given. Find it under the home folder (look in ~/Desktop, ~/Developer, ~/Documents, ~/Projects, ~/code) by the names mentioned above." : "Work in \(dir.path).")
        - When the task has several distinct parts, keep a short to-do list with TodoWrite: the user sees it as your progress. Skip it for small tasks.
        - Don't commit, push, publish, send anything, or delete files the user made, unless the task says so.
        - Your last message is read aloud exactly as written, so make it only the summary: 2–3 plain sentences (no markdown, no remarks about your process or to-do list) saying what you did and what the user should check.
        """
        guard let first = Self.userLine(prompt) else { return false }
        let mode = config.agentPermission.isEmpty ? "acceptEdits" : config.agentPermission
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--permission-mode", mode, "--name", "Poinky: \(req.title)"]
        // Nobody can approve anything while it runs: pre-approve editing the project and a few
        // safe commands (tests, git status/diff/log, listing files). Everything else is refused.
        if mode != "plan" { args += ["--allowedTools", Self.safeTools.joined(separator: " ")] }
        if !config.agentModel.isEmpty { args += ["--model", config.agentModel] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        // A clean Claude Code environment (not settings inherited from wherever Poinky was started).
        for k in env.keys where k.hasPrefix("CLAUDE_CODE_") || k.hasPrefix("CLAUDE_AGENT_SDK") { env[k] = nil }
        env["PATH"] = ["\(home.path)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        p.environment = env
        let inPipe = Pipe(), out = Pipe()
        p.standardInput = inPipe
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice

        let header = "# \(agent.name): \(req.title)\n\nStarted \(Date())\nFolder: \(dir.path)\n\n## Task\n\n\(req.task)\n\n## Work\n\n"
        try? header.write(to: agent.log, atomically: true, encoding: .utf8)
        let raw = agent.log.deletingPathExtension().appendingPathExtension("jsonl")
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        let rawHandle = try? FileHandle(forWritingTo: raw)

        do { try p.run() } catch { return false }
        processes[id] = p
        inputs[id] = inPipe.fileHandleForWriting
        try? inPipe.fileHandleForWriting.write(contentsOf: first)

        // Read on a background thread until the output closes, then report the exit. Doing both in
        // one place guarantees every event is delivered before the helper counts as finished.
        let handle = out.fileHandleForReading
        let t0 = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var stream = HelperStream()
            var pending = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                // Keep the raw stream, each line stamped with its time.
                pending.append(data)
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<nl]
                    pending.removeSubrange(pending.startIndex...nl)
                    if line.first == UInt8(ascii: "{"), line.count > 2 {
                        let stamp = String(format: "{\"_t\":%.2f,", Date().timeIntervalSince(t0))
                        rawHandle?.write(Data(stamp.utf8) + line.dropFirst() + Data([0x0A]))
                    }
                }
                let events = stream.feed(data)
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(id: id, events: events) } }
            }
            p.waitUntilExit()
            try? rawHandle?.close()
            let status = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(id: id, exitOK: status == 0) } }
        }
        return true
    }

    /// New output from a helper (possibly no events: it's still a sign of life).
    private func received(id: Int, events: [HelperEvent]) {
        // Anything new means the helper is busy again: don't let it finish yet.
        closeWork[id]?.cancel()
        closeWork[id] = nil
        guard let i = agents.firstIndex(where: { $0.id == id }), agents[i].status == .running else { return }
        for e in events {
            switch e {
            case .started(let session, let model):
                agents[i].session = session
                agents[i].model = model
            case .step(let s):
                agents[i].steps.append(s)
                if agents[i].steps.count > 40 { agents[i].steps.removeFirst(agents[i].steps.count - 40) }
                agents[i].latest = s
                appendLog(agents[i], "- \(s)\n")
            case .note(let s):
                agents[i].latest = s
                appendLog(agents[i], "\n\(s)\n\n")
            case .checklist(let list):
                agents[i].checklist = list
                let done = list.filter { $0.state == .done }.count
                appendLog(agents[i], "- To-do: \(done) of \(list.count) done\n")
            case .blocked(let what):
                agents[i].blocked.append(what)
                appendLog(agents[i], "- Wasn't allowed to: \(what)\n")
            case .turnEnded(let ok, let summary, _, _):
                agents[i].turns += 1
                lastTurn[id] = (ok, summary)
                // Done, unless a follow-up arrives in the next moment (then it keeps working).
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.closeWork[id] = nil
                        try? self.inputs[id]?.close()
                        self.inputs[id] = nil
                    }
                }
                closeWork[id] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.turnGrace, execute: work)
            }
            onEvent?(agents[i], e)
        }
    }

    /// The helper's process ended.
    private func ended(id: Int, exitOK: Bool) {
        processes[id] = nil
        try? inputs[id]?.close()
        inputs[id] = nil
        closeWork[id]?.cancel()
        closeWork[id] = nil
        defer { startWaiting() }
        guard let i = agents.firstIndex(where: { $0.id == id }), agents[i].status == .running else { return }
        let turn = lastTurn.removeValue(forKey: id)
        let ok = exitOK && (turn?.ok ?? false)
        agents[i].status = ok ? .done : .failed
        agents[i].finished = Date()
        var s = (turn?.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { s = agents[i].latest.isEmpty ? "It stopped without saying why." : "It stopped while: \(agents[i].latest)" }
        // Keep the summary short enough to be read aloud.
        agents[i].summary = s.count > 900 ? "…" + s.suffix(900) : s
        appendLog(agents[i], "\n## Result (\(agents[i].status.rawValue))\n\n\(agents[i].summary)\n")
        onChange?()
        onFinished?(agents[i])
    }

    /// Starts helpers from the line while there's room.
    private func startWaiting() {
        while running.count < maxRunning, !waiting.isEmpty {
            let next = waiting.removeFirst()
            guard let i = agents.firstIndex(where: { $0.id == next.id }), agents[i].status == .queued else { continue }
            agents[i].status = .running
            if let exe = Self.executable(config: next.config), launch(id: next.id, req: next.req, config: next.config, exe: exe) {
                onChange?()
            } else {
                agents[i].status = .failed
                agents[i].finished = Date()
                agents[i].summary = "It couldn't start: Claude Code wasn't found."
                onChange?()
                onFinished?(agents[i])
            }
        }
    }

    // MARK: - Helpers

    private func freeName() -> String {
        let taken = Set(agents.filter { $0.status == .running || $0.status == .queued }.map(\.name))
        if let n = Self.names.first(where: { !taken.contains($0) }) { return n }
        var k = 2
        while true {
            for n in Self.names where !taken.contains("\(n) \(k)") { return "\(n) \(k)" }
            k += 1
        }
    }

    private func appendLog(_ a: Agent, _ text: String) {
        guard let h = try? FileHandle(forWritingTo: a.log) else { return }
        h.seekToEndOfFile()
        h.write(Data(text.utf8))
        try? h.close()
    }

    static func executable(config: AppConfig) -> String? {
        if let fake = ProcessInfo.processInfo.environment["POINKY_HELPER_CMD"], !fake.isEmpty,
           FileManager.default.isExecutableFile(atPath: fake) { return fake }
        return ClaudeCodeBrain.findClaude(explicit: config.claudePath)
    }

    /// One user message in Claude Code's stream-json input format.
    static func userLine(_ text: String) -> Data? {
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        guard var d = try? JSONSerialization.data(withJSONObject: msg) else { return nil }
        d.append(0x0A)
        return d
    }
}
