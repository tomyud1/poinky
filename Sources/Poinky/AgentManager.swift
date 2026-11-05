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
        /// You told it to wait: its current step was interrupted and it waits for what to do next.
        var paused = false
        /// What it's waiting for you to answer (permission or a question), oldest first. Shown one at a time.
        var asks: [HelperAsk] = []
        /// Everything for its window, oldest first (also saved as `chat`).
        var entries: [HelperEntry] = []
        /// What Claude Code says it cost so far (dollars), from its last answer.
        var cost: Double?

        /// Its window's record, next to the log.
        var chat: URL { log.deletingPathExtension().appendingPathExtension("chat.jsonl") }
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
    /// Helpers making a plan first: the mode each one works in once you say go ahead.
    private var afterPlan: [Int: String] = [:]
    /// Continued helpers whose new instructions are already in their window (not again on a restart).
    private var introduced: Set<Int> = []
    // The real mouse and keyboard: one helper at a time. You say yes once per helper; after that it
    // gets them whenever they're free, and gives them back when it finishes or stops using them.
    private var handsAllowed: Set<Int> = []
    private(set) var handsHolder: Int?
    private var handsLast = Date.distantPast
    private var handsWaiting: [(id: Int, ask: HelperAsk)] = []
    private var handsTimer: Timer?
    /// Who has the mouse changed (nil: nobody).
    var onHands: ((Int?) -> Void)?
    /// How long a helper keeps the mouse without using it.
    static var handsIdle: TimeInterval = 15

    /// Helpers working in their own copy of a repo (another helper works in the same one).
    private var worktrees: [Int: HelperWorktree.Info] = [:]
    /// The repo each working helper is in (its top folder), to tell when two share one.
    private var repos: [Int: URL] = [:]
    /// How each helper was started, to start it again without auto mode if that mode isn't available.
    private var launched: [Int: (req: AgentRequest, config: AppConfig, exe: String)] = [:]
    private var nextID = 1
    /// The last word from Claude Code on the user's plan limits (from any helper).
    private(set) var limit: (status: String, resetsAt: Date?, window: String, at: Date)?

    /// For the main agent: what the helpers used today, and where the plan's limit stands.
    func usageLine() -> String {
        let cal = Calendar.current
        var runs = 0, cost = 0.0, helpers = 0
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: Self.logDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for f in files where f.lastPathComponent.hasSuffix(".chat.jsonl") {
                guard let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, cal.isDateInToday(m) else { continue }
                let ends = HelperEntry.read(f).filter { e in e.k == "end" && e.at.map { cal.isDateInToday(Date(timeIntervalSince1970: $0)) } ?? false }
                if !ends.isEmpty { helpers += 1 }
                runs += ends.count
                cost += ends.compactMap(\.cost).reduce(0, +)
            }
        }
        var s = "Helpers today: \(helpers) helper\(helpers == 1 ? "" : "s"), \(runs) run\(runs == 1 ? "" : "s"), about $\(String(format: "%.2f", cost)) of usage (Claude Code's estimate; on a subscription it counts toward the plan's limits, not a bill)."
        if let l = limit {
            let when = l.resetsAt.map { DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short) } ?? "later"
            let window = l.window == "five_hour" ? "5-hour" : l.window.replacingOccurrences(of: "_", with: " ")
            switch l.status {
            case "allowed": s += " Plan limits: fine (the \(window) window resets at \(when))."
            case "allowed_warning": s += " Plan limits: getting close (the \(window) window resets at \(when))."
            default: s += " Plan limits: reached; helpers can't work until \(when)."
            }
        }
        return s
    }

    /// The settings helpers were last started with (for undo, which runs Claude Code too).
    var lastConfig = AppConfig()
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
    /// A new line for a helper's window.
    var onEntry: ((Agent, HelperEntry) -> Void)?

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

    /// The user's slash commands and skills, as Claude Code listed them when a helper last started
    /// ("review", "security-review"…). Kept between runs, for the main agent.
    static var commands: [String] {
        get { (try? JSONDecoder().decode([String].self, from: Data(contentsOf: commandsFile))) ?? [] }
        set { try? JSONEncoder().encode(newValue).write(to: commandsFile) }
    }
    private static var commandsFile: URL { AppConfig.dir.appendingPathComponent("commands.json") }

    static var logDir: URL {
        // Resolved, so paths from here and from a listing of the folder compare equal (/tmp is /private/tmp).
        if let d = ProcessInfo.processInfo.environment["POINKY_AGENT_LOG_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true).resolvingSymlinksInPath() }
        return AppConfig.dir.appendingPathComponent("agents", isDirectory: true)
    }

    /// Starts a helper, or puts it in line if `maxRunning` are already working.
    /// Returns nil if Claude Code isn't installed.
    func start(_ req: AgentRequest, config: AppConfig) -> Agent? {
        guard let exe = Self.executable(config: config) else { return nil }
        lastConfig = config
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
        let log = req.continueLog ?? Self.logDir.appendingPathComponent("\(stamp)-\(String(safeTitle)).md")
        // Continuing an earlier helper: its old name if it's free, and everything it did so far.
        let taken = Set(agents.filter { $0.status == .running || $0.status == .queued }.map(\.name))
        let name = req.name.flatMap { taken.contains($0) ? nil : $0 } ?? freeName()
        var agent = Agent(id: id, name: name, title: req.title, task: req.task, dir: dir, started: Date(), log: log)
        if req.continueLog != nil { agent.entries = HelperEntry.read(agent.chat) }
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
            waiting[w].req = AgentRequest(title: r.title, dir: r.dir, task: r.task + "\n\nAlso: " + text, model: r.model, planFirst: r.planFirst,
                                          resume: r.resume, continueLog: r.continueLog, name: r.name, earlier: r.earlier, worktreePath: r.worktreePath)
            agents[i].followUps.append(text)
            record(id, HelperEntry(k: "you", text: text))
            onChange?()
            return true
        }
        guard let input = inputs[id], let i = agents.firstIndex(where: { $0.id == id }), agents[i].status == .running,
              let line = Self.userLine(text) else { return false }
        do { try input.write(contentsOf: line) } catch { return false }
        closeWork[id]?.cancel()
        closeWork[id] = nil
        agents[i].paused = false
        agents[i].followUps.append(text)
        appendLog(agents[i], "\n## Follow-up\n\n\(text)\n\n")
        record(id, HelperEntry(k: "you", text: text))
        onChange?()
        return true
    }

    /// Continues an earlier (finished) helper with something new to do: the same Claude Code session if
    /// it had one (it remembers everything it did), the same window, and its old name if that's free.
    func resume(_ past: PastHelper, text: String, config: AppConfig) -> Agent? {
        let earlier = "Earlier, a helper worked on this task: \(past.task)\n\nWhat it reported: \(past.summary.isEmpty ? "(nothing)" : past.summary)"
        let req = AgentRequest(title: past.title, dir: past.dir.path, task: text, resume: past.session, continueLog: past.log,
                               name: past.name, earlier: earlier, worktreePath: past.worktree)
        // The finished one it continues isn't listed anymore.
        agents.removeAll { $0.log.place == past.log.place && $0.status != .running && $0.status != .queued }
        return start(req, config: config)
    }

    /// A finished helper still in memory, as an earlier one (to continue it).
    func past(_ a: Agent) -> PastHelper {
        PastHelper(chat: a.chat, log: a.log, name: a.name, title: a.title, task: a.task, dir: a.dir, session: a.session,
                   worktree: a.entries.last(where: { $0.k == "worktree" })?.detail,
                   status: a.status.rawValue, summary: a.summary, started: a.started)
    }

    // MARK: - Undo

    /// Puts back what a helper changed in one of its runs (the latest if `run` is nil). With `dryRun`, only
    /// says which files that would change (and which of them changed after it finished). A helper that's
    /// still working is stopped first.
    func undo(_ past: PastHelper, run: Int? = nil, dryRun: Bool, done: @escaping @MainActor (HelperUndo.Outcome) -> Void) {
        let entries = agents.last(where: { $0.chat.place == past.chat.place })?.entries ?? HelperEntry.read(past.chat)
        let starts = HelperEntry.runStarts(entries)
        let k = run ?? starts.count - 1
        // A run in its own worktree: its changes came back as a patch, so undo takes that patch out again.
        let runs = HelperEntry.runs(entries)
        if k >= 0, k < runs.count, runs[k].contains(where: { $0.k == "worktree" }) || runs[k].contains(where: { $0.k == "merged" }) {
            guard let m = runs[k].last(where: { $0.k == "merged" }), let patch = m.detail,
                  let top = entries.last(where: { $0.k == "worktree" })?.text else {
                done(.failed("Its changes were never brought into your folder, so there's nothing to undo there.")); return
            }
            let outcome = HelperWorktree.unapply(patch: URL(fileURLWithPath: patch), in: URL(fileURLWithPath: top), dryRun: dryRun)
            if dryRun { done(outcome) } else { undone(past, checkpoint: starts.indices.contains(k) ? (starts[k] ?? "run\(k)") : "run\(k)", outcome, done: done) }
            return
        }
        guard !past.session.isEmpty, k >= 0, k < starts.count, let checkpoint = starts[k] else {
            done(.failed("\(past.name) didn't keep a checkpoint, so there's nothing to go back to.")); return
        }
        guard let exe = Self.executable(config: lastConfig) else { done(.failed("Claude Code isn't installed.")); return }
        let ends = entries.filter { $0.k == "end" }
        let finished = k < ends.count ? ends[k].at.map { Date(timeIntervalSince1970: $0) } : nil
        let go = { [weak self] in
            // Claude Code only lists the files when asked first (a dry run), so undoing asks that too.
            HelperUndo.rewind(exe: exe, dir: past.dir, session: past.session, checkpoint: checkpoint, dryRun: true, finished: finished) { preview in
                guard !dryRun, case .preview(let pv) = preview else { done(preview); return }
                HelperUndo.rewind(exe: exe, dir: past.dir, session: past.session, checkpoint: checkpoint, dryRun: false, finished: finished) { result in
                    var outcome = result
                    if case .done = result { outcome = .done(pv.files) }
                    self?.undone(past, checkpoint: checkpoint, outcome, done: done)
                }
            }
        }
        // Working: stop it, and undo once it has really ended.
        if let a = agents.last(where: { $0.chat.place == past.chat.place }), a.status == .running || a.status == .queued {
            stop(id: a.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { go() }
        } else {
            go()
        }
    }

    /// After undoing: its window says so.
    private func undone(_ past: PastHelper, checkpoint: String, _ outcome: HelperUndo.Outcome, done: @MainActor (HelperUndo.Outcome) -> Void) {
        if case .done(let files) = outcome {
            let e = HelperEntry(k: "undone", text: files.isEmpty ? "You undid its changes (no files had changed)." : "You undid its changes: put back \(HelperUndo.names(files)).", id: checkpoint)
            if let a = agents.last(where: { $0.chat.place == past.chat.place }) { record(a.id, e) } else { Self.append(e, to: past.chat) }
            onChange?()
        }
        done(outcome)
    }

    private static func append(_ e: HelperEntry, to chat: URL) {
        guard let h = try? FileHandle(forWritingTo: chat) else { return }
        h.seekToEndOfFile()
        h.write(Data((e.json + "\n").utf8))
        try? h.close()
    }

    /// "Mint, wait": interrupts what it's doing right now, without ending it. It waits for what to do next
    /// (`send`), or `resume`. False if it isn't working (or is still in line, or already paused).
    @discardableResult
    func pause(id: Int) -> Bool {
        guard let i = agents.firstIndex(where: { $0.id == id }), agents[i].status == .running, !agents[i].paused,
              write(id, ["type": "control_request", "request_id": "pause-\(UUID().uuidString)", "request": ["subtype": "interrupt"]])
        else { return false }
        closeWork[id]?.cancel()
        closeWork[id] = nil
        agents[i].paused = true
        agents[i].latest = "Paused"
        appendLog(agents[i], "- (The user paused it.)\n")
        record(id, HelperEntry(k: "info", text: "You paused it. It waits for what to do next."))
        onChange?()
        return true
    }

    /// Picks up where it was paused.
    @discardableResult
    func resume(id: Int) -> Bool {
        guard agents.first(where: { $0.id == id })?.paused == true else { return false }
        return send(id: id, text: "Go on with what you were doing.")
    }

    /// "Mint, actually use yarn": stops what it's doing right now and gives it the new direction.
    @discardableResult
    func redirect(id: Int, text: String) -> Bool {
        guard let a = agents.first(where: { $0.id == id }), a.status == .running else { return send(id: id, text: text) }
        if !a.paused, a.asks.isEmpty { pause(id: id) }
        return send(id: id, text: text)
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
            record(id, HelperEntry(k: "answer", text: "You answered: \(a)", id: ask.requestID))
            onChange?()
            return .next(next)
        }
        // The mouse: your yes counts for this helper from now on, but it waits its turn.
        if ask.isHands, case .yes = reply {
            handsAllowed.insert(id)
            agents[i].asks.remove(at: k)
            appendLog(agents[i], "- The user said it may use the mouse and keyboard\n")
            record(id, HelperEntry(k: "answer", text: "You said yes", kind: "yes", id: ask.requestID))
            if handsHolder == nil || handsHolder == id { grantHands(id, ask) }
            else {
                handsWaiting.append((id, ask))
                agents[i].latest = "Waiting for the mouse"
                let other = agents.first { $0.id == handsHolder }?.name ?? "another helper"
                record(id, HelperEntry(k: "info", text: "Waiting for the mouse and keyboard (\(other) is using them)."))
            }
            onChange?()
            return .sent
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
        record(id, HelperEntry(k: "answer", text: "You " + (said.hasPrefix("answered") ? said : "said " + said), kind: {
            if case .no = reply { return "no" }
            return "yes"
        }(), id: ask.requestID))
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
            record(id, HelperEntry(k: "end", text: "You stopped it.", kind: "stopped", cost: agents[i].cost,
                                   seconds: Date().timeIntervalSince(agents[i].started)))
        }
        agents[i].asks.removeAll()
        waiting.removeAll { $0.id == id }
        releaseHands(id)
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
            case .running where a.paused:
                return "\(who): PAUSED by the user in \(a.dir.path), waiting to be told what to do next (a <tell> message, or the user says go on)"
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
            case .done: return "\(who): done after \(mins) min (key \(past(a).key)). Summary: \(a.summary)"
            case .failed: return "\(who): failed (key \(past(a).key)). Last output: \(a.summary)"
            case .stopped: return "\(who): stopped by the user (key \(past(a).key))"
            }
        }
    }

    // MARK: - Running one

    private func launch(id: Int, req: AgentRequest, config: AppConfig, exe: String) -> Bool {
        guard let agent = agents.first(where: { $0.id == id }) else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = agent.dir
        let notes = """
        Notes:
        - Make sensible choices yourself and note them; the user may send you follow-up messages, so fold those into the work. Ask the user (AskUserQuestion: one short question, 2–4 options) only when a choice really changes the result and you can't undo it. They hear it out loud while doing other things.
        - If you need something you aren't allowed to do on your own, just do it: the user is asked out loud and can say yes or no. If they say no, find another way or explain in your summary.
        - Each request interrupts the user, so keep commands simple: one at a time, from the project folder (no `cd … &&`, no `| tail`), and prefer the ones that need no OK (the project's tests, git status/diff/log, ls).
        - \(req.dir == nil ? "The project's folder wasn't given. Find it under the home folder (look in ~/Desktop, ~/Developer, ~/Documents, ~/Projects, ~/code) by the names mentioned above." : "Work in \(dir.path).")
        - When the task has several distinct parts, keep a short to-do list with TodoWrite: the user sees it as your progress. Skip it for small tasks.
        - Don't commit, push, publish, send anything, or delete files the user made, unless the task says so.
        - Your last message is read aloud exactly as written, so make it only the summary: 2–3 plain sentences (no markdown, no remarks about your process or to-do list) saying what you did and what the user should check.
        """
        // Who it is and how to work go in the system prompt, so the message is just the task (and a task
        // can be one of the user's commands, like "/review").
        // Continuing an earlier helper: its own session if it had one (it remembers everything), or a fresh
        // one told what was done before.
        let resuming = !(req.resume ?? "").isEmpty
        var newWorktree = false
        // Another helper works in the same repo: this one gets its own copy (a git worktree). Continuing one
        // that had a worktree: made again at the same folder (Claude Code finds its session by folder).
        if worktrees[id] == nil, req.dir != nil {
            let top = repos[id] ?? HelperWorktree.top(of: dir)
            repos[id] = top
            let shared = top != nil && repos.contains { other in other.key != id && other.value == top && agents.contains { $0.id == other.key && $0.status == .running } }
            if let path = req.worktreePath {
                worktrees[id] = HelperWorktree.make(for: dir, name: agent.name, at: URL(fileURLWithPath: path))
            } else if shared {
                worktrees[id] = HelperWorktree.make(for: dir, name: agent.name)
            }
            newWorktree = worktrees[id] != nil
        }
        let worktreeNote = worktrees[id].map { w in
            "\n- You're working in your own copy of the project (a git worktree at \(w.workDir.path)) because another helper works in \(w.top.path) at the same time. Work only in your copy and don't commit: when you're done, Poinky brings your changes into the user's folder."
        } ?? ""
        let system = "You were started by Poinky, the user's voice assistant, to do a task in the background. On screen you're the helper called \(agent.name).\n\n\(notes)\(worktreeNote)"
        let prompt: String
        if resuming {
            prompt = req.name == agent.name ? req.task : "(On screen you're the helper called \(agent.name) now.)\n\n\(req.task)"
        } else if let earlier = req.earlier {
            prompt = "\(earlier)\n\nNow the user wants: \(req.task)"
        } else {
            prompt = req.task
        }
        guard let first = Self.userLine(prompt) else { return false }
        launched[id] = (req, config, exe)
        let setting = config.agentPermission.isEmpty ? "auto" : config.agentPermission
        // "Make a plan first" (asked for, or the setting): plan mode, then the usual mode once you say go ahead.
        let planFirst = req.planFirst || setting == "plan"
        let mode = planFirst ? "plan" : setting
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    // Each message comes back with its id: a checkpoint to undo to.
                    "--replay-user-messages",
                    "--permission-mode", mode, "--name", "Poinky: \(req.title)",
                    // Anything it isn't allowed to do on its own comes to Poinky (a control_request on its
                    // output), and it waits until the user says yes or no.
                    "--permission-prompt-tool", "stdio"]
        if planFirst { afterPlan[id] = setting == "plan" ? "auto" : setting } else {
            // Editing the project and a few safe commands (tests, git status/diff/log, listing files) need no OK.
            args += ["--allowedTools", Self.safeTools.joined(separator: " ")]
        }
        // Pushing, deleting and installing always ask, even in auto mode.
        if let data = try? JSONSerialization.data(withJSONObject: ["permissions": ["ask": HelperAsk.askRules]]),
           let json = String(data: data, encoding: .utf8) { args += ["--settings", json] }
        if !resuming { args += ["--append-system-prompt", system] }   // a resumed session keeps its own
        if let m = req.model ?? (config.agentModel.isEmpty ? nil : config.agentModel) { args += ["--model", m] }
        if resuming, let session = req.resume { args += ["--resume", session] }
        if AppConfig.efforts.contains(config.agentEffort) { args += ["--effort", config.agentEffort] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = worktrees[id]?.workDir ?? dir
        var env = ProcessInfo.processInfo.environment
        // A clean Claude Code environment (not settings inherited from wherever Poinky was started).
        for k in env.keys where k.hasPrefix("CLAUDE_CODE_") || k.hasPrefix("CLAUDE_AGENT_SDK") { env[k] = nil }
        env["PATH"] = ["\(home.path)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        // Claude Code keeps checkpoints of the files it changes, so they can be put back (undo).
        env[HelperUndo.checkpointEnv.0] = HelperUndo.checkpointEnv.1
        p.environment = env
        let inPipe = Pipe(), out = Pipe()
        p.standardInput = inPipe
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice

        let raw = agent.log.deletingPathExtension().appendingPathExtension("jsonl")
        if req.continueLog != nil, FileManager.default.fileExists(atPath: agent.log.path) {
            // Continuing: the same log and window, with what you asked for now.
            if introduced.insert(id).inserted {
                appendLog(agent, "\n## Continued \(Date())\n\n\(req.task)\n\n## Work\n\n")
                record(id, HelperEntry(k: "you", text: req.task))
            }
        } else {
            let header = "# \(agent.name): \(req.title)\n\nStarted \(Date())\nFolder: \(dir.path)\n\n## Task\n\n\(req.task)\n\n## Work\n\n"
            try? header.write(to: agent.log, atomically: true, encoding: .utf8)
            if agent.entries.isEmpty {
                FileManager.default.createFile(atPath: agent.chat.path, contents: nil)
                record(id, HelperEntry(k: "task", text: req.task, detail: dir.path, kind: agent.name, title: req.title))
            }
        }
        if newWorktree, let w = worktrees[id] {
            record(id, HelperEntry(k: "worktree", text: w.top.path, detail: w.path.path, id: w.base))
            appendLog(agent, "- (Working in its own copy of the repo, \(w.path.path), because another helper works in \(w.top.path).)\n")
        }
        if !FileManager.default.fileExists(atPath: raw.path) || req.continueLog == nil { FileManager.default.createFile(atPath: raw.path, contents: nil) }
        let rawHandle = try? FileHandle(forWritingTo: raw)
        rawHandle?.seekToEndOfFile()

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
                var entries = stream.takeEntries()
                let now = Date().timeIntervalSince(t0)
                for k in entries.indices { entries[k].t = now }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(id: id, events: events, entries: entries) } }
            }
            p.waitUntilExit()
            try? rawHandle?.close()
            let status = p.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(id: id, exitOK: status == 0) } }
        }
        return true
    }

    /// New output from a helper (possibly no events: it's still a sign of life).
    private func received(id: Int, events: [HelperEvent], entries: [HelperEntry] = []) {
        // Anything new means the helper is busy again: don't let it finish yet.
        closeWork[id]?.cancel()
        closeWork[id] = nil
        guard let i = agents.firstIndex(where: { $0.id == id }), agents[i].status == .running else { return }
        // Requests for the mouse that Poinky answers itself (you already said yes) aren't shown as questions.
        let handled = Set(events.compactMap { e -> String? in
            if case .asking(let a) = e, a.isHands, handsAllowed.contains(id) { return a.requestID }
            return nil
        })
        for e in entries where !(e.k == "ask" && handled.contains(e.id ?? "")) { record(id, e) }
        for e in events {
            switch e {
            case .limit(let status, let resets, let window):
                limit = (status, resets, window, Date())
            case .started(let session, let model, let commands):
                if !commands.isEmpty, commands != Self.commands { Self.commands = commands }
                if agents[i].session != session { record(id, HelperEntry(k: "session", detail: model, id: session)) }
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
            case .asking(let ask) where ask.isHands && handsAllowed.contains(id):
                // It may use the mouse: now if it's free, or when the helper using it is done.
                if handsHolder == nil || handsHolder == id { grantHands(id, ask) }
                else {
                    handsWaiting.append((id, ask))
                    let other = agents.first { $0.id == handsHolder }?.name ?? "another helper"
                    agents[i].latest = "Waiting for the mouse"
                    record(id, HelperEntry(k: "info", text: "Waiting for the mouse and keyboard (\(other) is using them)."))
                    onChange?()
                }
                onEvent?(agents[i], e)
                continue
            case .asking(var ask):
                // Its plan: once you say go ahead, it works in the helpers' usual mode.
                if ask.isPlan {
                    let setting = launched[id]?.config.agentPermission ?? ""
                    ask.afterPlan = afterPlan[id] ?? (setting.isEmpty || setting == "plan" ? "auto" : setting)
                    ask.afterPlanTools = Self.safeTools
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
            case .turnEnded(let ok, let summary, _, let cost):
                agents[i].turns += 1
                if let cost { agents[i].cost = cost }
                // Paused: the interrupted turn ended; it waits for what you say next.
                if agents[i].paused { onEvent?(agents[i], e); continue }
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
        afterPlan.removeValue(forKey: id)
        let how = launched.removeValue(forKey: id)
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        defer { repos.removeValue(forKey: id); releaseHands(id) }
        // Stopped: its own copy of the repo (if it had one) is kept on a branch.
        if agents[i].status != .running {
            if let w = worktrees.removeValue(forKey: id) { _ = finishWorktree(i, w, ok: false) }
            return
        }
        // Auto mode isn't available (older Claude Code, or not on this plan): it ended before it even
        // started. Start it again editing the project and asking for the rest.
        if !exitOK, agents[i].session.isEmpty, agents[i].steps.isEmpty, let how, how.config.agentPermission == "auto" || how.config.agentPermission.isEmpty {
            var cfg = how.config
            cfg.agentPermission = "acceptEdits"
            if launch(id: id, req: how.req, config: cfg, exe: how.exe) {
                appendLog(agents[i], "- (Auto mode isn't available here, so it started again without it.)\n")
                record(id, HelperEntry(k: "info", text: "Auto mode isn't available here, so it started again without it."))
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
        // Its own copy of the repo: its changes come back into your folder (or onto a branch).
        if let w = worktrees.removeValue(forKey: id), let note = finishWorktree(i, w, ok: ok) { s += " " + note }
        // Keep the summary short enough to be read aloud.
        agents[i].summary = s.count > 900 ? "…" + s.suffix(900) : s
        appendLog(agents[i], "\n## Result (\(agents[i].status.rawValue))\n\n\(agents[i].summary)\n")
        record(id, HelperEntry(k: "end", text: s, kind: ok ? "done" : "failed", cost: agents[i].cost,
                               seconds: agents[i].finished!.timeIntervalSince(agents[i].started)))
        onChange?()
        onFinished?(agents[i])
    }

    // MARK: - The mouse and keyboard

    private func grantHands(_ id: Int, _ ask: HelperAsk) {
        guard let response = ask.response(.yes(always: false, extra: "")), write(id, response) else { return }
        let first = handsHolder != id
        handsHolder = id
        handsLast = Date()
        if first, let i = agents.firstIndex(where: { $0.id == id }) {
            agents[i].latest = "Using your mouse and keyboard"
            record(id, HelperEntry(k: "info", text: "Using your mouse and keyboard."))
            onChange?()
            onHands?(id)
        }
        if handsTimer == nil {
            handsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let h = self.handsHolder else { return }
                    if Date().timeIntervalSince(self.handsLast) > Self.handsIdle { self.releaseHands(h) }
                }
            }
        }
    }

    /// It's done with the mouse (finished, stopped, or hasn't used it for a while): the next one gets it.
    private func releaseHands(_ id: Int) {
        handsWaiting.removeAll { $0.id == id }
        guard handsHolder == id else { return }
        handsHolder = nil
        while !handsWaiting.isEmpty {
            let next = handsWaiting.removeFirst()
            guard agents.contains(where: { $0.id == next.id && $0.status == .running }) else { continue }
            grantHands(next.id, next.ask)
            return
        }
        handsTimer?.invalidate()
        handsTimer = nil
        onHands?(nil)
    }

    /// Brings a helper's changes back from its worktree. Returns a sentence for its report when there's
    /// something the user should know (its changes are on a branch).
    private func finishWorktree(_ i: Int, _ w: HelperWorktree.Info, ok: Bool) -> String? {
        let a = agents[i]
        let run = a.entries.filter { $0.k == "end" }.count
        let patch = a.log.deletingPathExtension().appendingPathExtension("run\(run + 1).patch")
        switch HelperWorktree.finish(w, name: a.name, title: a.title, keepOnly: !ok, patchTo: patch) {
        case .nothing:
            return nil
        case .merged(let files, let patch):
            record(a.id, HelperEntry(k: "merged", text: "Brought its changes into \(w.top.lastPathComponent): \(HelperUndo.names(files)).", detail: patch.path))
            appendLog(a, "- Brought its changes into \(w.top.path): \(files.joined(separator: ", "))\n")
            return nil
        case .kept(let branch, let files):
            let why = ok ? "they overlap with other changes in \(w.top.lastPathComponent)" : "it didn't finish"
            record(a.id, HelperEntry(k: "info", text: "Its changes to \(HelperUndo.names(files)) are on the git branch \(branch), because \(why)."))
            appendLog(a, "- Kept its changes on the branch \(branch) (\(why)).\n")
            return ok ? "Its changes overlap with other changes in the folder, so they're on the git branch \(branch)." : nil
        case .failed(let why):
            record(a.id, HelperEntry(k: "info", text: "Couldn't bring its changes back: \(why). They're in \(w.path.path)."))
            return "Its changes couldn't be brought back (\(why))."
        }
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

    /// Names in use by helpers that aren't agents (a video being made).
    var reservedNames: Set<String> = []

    private func freeName() -> String {
        let taken = Set(agents.filter { $0.status == .running || $0.status == .queued }.map(\.name)).union(reservedNames)
        if let n = Self.names.first(where: { !taken.contains($0) }) { return n }
        var k = 2
        while true {
            for n in Self.names where !taken.contains("\(n) \(k)") { return "\(n) \(k)" }
            k += 1
        }
    }

    /// A new line for its window: kept, saved, and shown if its window is open.
    private func record(_ id: Int, _ entry: HelperEntry) {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        var e = entry
        if e.t == 0 { e.t = Date().timeIntervalSince(agents[i].started) }
        if e.k == "end" { e.at = Date().timeIntervalSince1970 }
        agents[i].entries.append(e)
        if let h = try? FileHandle(forWritingTo: agents[i].chat) {
            h.seekToEndOfFile()
            h.write(Data((e.json + "\n").utf8))
            try? h.close()
        }
        onEntry?(agents[i], e)
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
