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
        /// What it's waiting for you to answer (permission or a question), oldest first. Shown one at a time.
        var asks: [HelperAsk] = []
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
    private var planOnly: Set<Int> = []
    /// How each helper was started, to start it again without auto mode if that mode isn't available.
    private var launched: [Int: (req: AgentRequest, config: AppConfig, exe: String)] = [:]
    private var nextID = 1
    /// How many helpers may work at once (the rest wait in line). From `AppConfig.maxHelpers`.
    var maxRunning = 3

    /// A helper finished (done or failed): the app tells the user.
    var onFinished: ((Agent) -> Void)?
    /// Something changed (for the notch).
    var onChange: (() -> Void)?
    /// A helper made progress (for the screen).
    var onEvent: ((Agent, HelperEvent) -> Void)?
    /// A helper started working (right away, or later from the line).
    var onStarted: ((Agent) -> Void)?
    /// The user stopped a helper.
    var onStopped: ((Agent) -> Void)?
    /// A helper needs an answer (its first open one), or its open requests changed (answered or withdrawn).
    var onAsksChanged: ((Agent) -> Void)?

    /// The name the next helper will get (so Poinky can say "I'll have Mint do that").
    var nextName: String { freeName() }
    /// Its place in the name list (each helper has its own note in the sounds).
    static func note(for name: String) -> Int { names.firstIndex(of: name.components(separatedBy: " ")[0]) ?? 0 }

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
        onStarted?(agent)
        return agent
    }

    /// Sends a follow-up to a working helper. False if it isn't working (finished, stopped, or still in line).
    @discardableResult
    func send(id: Int, text: String) -> Bool {
        // Still waiting for a free spot: add it to the task it will start with.
        if let w = waiting.firstIndex(where: { $0.id == id }), let i = agents.firstIndex(where: { $0.id == id }) {
            let r = waiting[w].req
            waiting[w].req = AgentRequest(title: r.title, dir: r.dir, task: r.task + "\n\nAlso: " + text)
            agents[i].followUps.append(text)
            onChange?()
            return true
        }
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

    enum AnswerResult: Equatable {
        case sent          // the helper has its answer and goes on
        case next(HelperAsk)   // recorded; it has another question for you (the same request)
        case failed        // not waiting for that anymore (or it couldn't be sent)
    }

    /// Your answer to a helper's open request (the first one unless `requestID` says otherwise).
    /// Only ever called with what the user said or clicked: nothing else approves anything.
    @discardableResult
    func answer(id: Int, requestID: String? = nil, _ reply: HelperAsk.Reply) -> AnswerResult {
        guard let i = agents.firstIndex(where: { $0.id == id }), agents[i].status == .running,
              let k = requestID.map({ rid in agents[i].asks.firstIndex { $0.requestID == rid } }) ?? (agents[i].asks.isEmpty ? nil : 0)
        else { return .failed }
        let ask = agents[i].asks[k]
        // A question with more to ask: keep the answer and ask the next one.
        if case .answer(let a) = reply, let next = ask.recording(a) {
            agents[i].asks[k] = next
            appendLog(agents[i], "- The user answered: \(a)\n")
            onChange?()
            return .next(next)
        }
        guard let response = ask.response(reply), write(id, response) else { return .failed }
        agents[i].asks.remove(at: k)
        let said: String
        switch reply {
        case .yes(let always, let extra): said = "yes" + (always && !ask.risky ? " (always, for this session)" : "") + (extra.isEmpty ? "" : ". \(extra)")
        case .no(let reason): said = "no" + (reason.isEmpty ? "" : ": \(reason)")
        case .answer(let a): said = "answered: \(a)"
        case .unclear: said = "?"
        }
        appendLog(agents[i], "- The user \(said.hasPrefix("answered") ? said : "said " + said)\n")
        if case .yes(_, let extra) = reply, !extra.isEmpty { _ = send(id: id, text: extra) }
        onChange?()
        return .sent
    }

    /// One line on a helper's input (a control response). False if it can't be sent.
    @discardableResult
    private func write(_ id: Int, _ obj: [String: Any]) -> Bool {
        guard let input = inputs[id], var d = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        d.append(0x0A)
        do { try input.write(contentsOf: d) } catch { return false }
        return true
    }

    func stop(id: Int) {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = agents[i].status == .running || agents[i].status == .queued
        if agents[i].status == .running || agents[i].status == .queued {
            agents[i].status = .stopped
            agents[i].finished = Date()
        }
        agents[i].asks.removeAll()
        waiting.removeAll { $0.id == id }
        closeWork[id]?.cancel()
        closeWork[id] = nil
        processes[id]?.terminate()
        processes[id] = nil
        try? inputs[id]?.close()
        inputs[id] = nil
        onChange?()
        if wasActive { onStopped?(agents[i]); startWaiting() }
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
                if let ask = a.asks.first {
                    s += ask.kind == .question ? ". WAITING for the user to answer its question: \(ask.currentQuestion?.text ?? ask.detail)"
                                               : ". WAITING for the user's OK to: \(ask.detail)"
                }
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
        - Make sensible choices yourself and note them; the user may send you follow-up messages, so fold those into the work. Ask the user (AskUserQuestion: one short question, 2–4 options) only when a choice really changes the result and you can't undo it. They hear it out loud while doing other things.
        - If you need something you aren't allowed to do on your own, just do it: the user is asked out loud and can say yes or no. If they say no, find another way or explain in your summary.
        - Each request interrupts the user, so keep commands simple: one at a time, from the project folder (no `cd … &&`, no `| tail`), and prefer the ones that need no OK (the project's tests, git status/diff/log, ls).
        - \(req.dir == nil ? "The project's folder wasn't given. Find it under the home folder (look in ~/Desktop, ~/Developer, ~/Documents, ~/Projects, ~/code) by the names mentioned above." : "Work in \(dir.path).")
        - When the task has several distinct parts, keep a short to-do list with TodoWrite: the user sees it as your progress. Skip it for small tasks.
        - Don't commit, push, publish, send anything, or delete files the user made, unless the task says so.
        - Your last message is read aloud exactly as written, so make it only the summary: 2–3 plain sentences (no markdown, no remarks about your process or to-do list) saying what you did and what the user should check.
        """
        guard let first = Self.userLine(prompt) else { return false }
        launched[id] = (req, config, exe)
        let mode = config.agentPermission.isEmpty ? "auto" : config.agentPermission
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--permission-mode", mode, "--name", "Poinky: \(req.title)",
                    // Anything it isn't allowed to do on its own comes to Poinky (a control_request on its
                    // output), and it waits until the user says yes or no.
                    "--permission-prompt-tool", "stdio"]
        if mode == "plan" { planOnly.insert(id) } else {
            // Editing the project and a few safe commands (tests, git status/diff/log, listing files) need no OK.
            args += ["--allowedTools", Self.safeTools.joined(separator: " ")]
            // Pushing, deleting and installing always ask, even in auto mode.
            if let data = try? JSONSerialization.data(withJSONObject: ["permissions": ["ask": HelperAsk.askRules]]),
               let json = String(data: data, encoding: .utf8) { args += ["--settings", json] }
        }
        if !config.agentModel.isEmpty { args += ["--model", config.agentModel] }
        if AppConfig.efforts.contains(config.agentEffort) { args += ["--effort", config.agentEffort] }

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
            case .asking(let ask):
                // Plan only: it reports the plan instead of starting on it.
                if planOnly.contains(id), ask.tool == "ExitPlanMode" {
                    write(id, ["type": "control_response", "response": ["subtype": "success", "request_id": ask.requestID, "response":
                        ["behavior": "deny", "message": "The user asked for a plan only. Give the plan as your final summary."]] as [String: Any]])
                    continue
                }
                agents[i].asks.append(ask)
                appendLog(agents[i], "- Asks the user: \(ask.kind == .question ? ask.detail : ask.bubble + " (" + ask.detail + ")")\n")
                onChange?()
                if agents[i].asks.count == 1 { onAsksChanged?(agents[i]) }
            case .askCancelled(let rid):
                guard let k = agents[i].asks.firstIndex(where: { $0.requestID == rid }) else { break }
                agents[i].asks.remove(at: k)
                appendLog(agents[i], "- (It withdrew the question.)\n")
                onChange?()
                onAsksChanged?(agents[i])
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
        planOnly.remove(id)
        let how = launched.removeValue(forKey: id)
        guard let i = agents.firstIndex(where: { $0.id == id }), agents[i].status == .running else { return }
        // Auto mode isn't available (older Claude Code, or not on this plan): it ended before it even
        // started. Start it again editing the project and asking for the rest.
        if !exitOK, agents[i].session.isEmpty, agents[i].steps.isEmpty, let how, how.config.agentPermission == "auto" || how.config.agentPermission.isEmpty {
            var cfg = how.config
            cfg.agentPermission = "acceptEdits"
            if launch(id: id, req: how.req, config: cfg, exe: how.exe) {
                appendLog(agents[i], "- (Auto mode isn't available here, so it started again without it.)\n")
                return
            }
        }
        agents[i].asks.removeAll()
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
                onStarted?(agents[i])
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
