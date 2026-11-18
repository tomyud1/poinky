import Foundation

/// Brain #1: runs Claude Code (`claude -p`) in the background and keeps ONE session open
/// for the whole call. Uses your Claude subscription login, no API key needed.
@MainActor
final class ClaudeCodeBrain: Brain {
    let displayName = "Claude Code (subscription)"

    private let model: String
    private let explicitPath: String
    private let systemPrompt: String

    private var process: Process?
    private var stdin: FileHandle?
    /// Writes to Claude Code's input happen here, never on the main thread: a message with a screenshot is
    /// bigger than the pipe holds, and a Claude Code that isn't reading (hung while starting) blocked the
    /// main thread forever, with the watchdog and the stuck detector frozen too. One queue per process.
    private var writer: DispatchQueue?
    private var buffer = Data()
    private var stderrTail = ""

    private struct Pending {
        let cont: CheckedContinuation<String, Error>
        let onText: (String) -> Void
        let id: Int
        var text = ""
        var gotDeltas = false
    }
    private var nextID = 0
    private var lastOutputAt: TimeInterval = 0
    private var watchdog: Timer?
    private var limit: (rejected: Bool, resetsAt: Date?) = (false, nil)   // from the last rate_limit_event
    /// How much the last answer had to read (the whole conversation so far): grows with every screenshot.
    private(set) var lastInputTokens = 0
    var contextTokens: Int { lastInputTokens }
    private var cancelledID: Int?   // its result (an "error_during_execution") is a cancellation, not an error
    /// No output at all for this long while answering: Claude Code is stuck, so it's restarted.
    /// (Any line counts, thinking included, so long answers never trip it.)
    static let stallSeconds: TimeInterval = ProcessInfo.processInfo.environment["POINKY_STALL_SECS"].flatMap(Double.init) ?? 75
    private var pending: Pending? {
        didSet { if pending == nil { wakeWaiters() } }
    }
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    private func wakeWaiters() {
        let w = idleWaiters
        idleWaiters.removeAll()
        w.forEach { $0.resume() }
    }

    private let effort: String
    /// Automatic effort: ask the API for no thinking step before the answer. Claude Code itself never sends
    /// it for Haiku 5.5 / Sonnet 5.5 (it treats them as models that can't turn thinking off, so
    /// `alwaysThinkingEnabled:false` / `MAX_THINKING_TOKENS=0` are ignored): Haiku then thought 1–4 s before
    /// the talker's first word, and Sonnet ~1.5 s before the doer's first act. So it goes in through
    /// `CLAUDE_CODE_EXTRA_BODY` (with no context edits, since Claude Code's `clear_thinking` edit requires
    /// thinking): `disabled` for Haiku, `between_tools` for Sonnet (the API's "no thinking before
    /// responding" for it). Other models, and any chosen effort level, keep thinking as it is. If the API
    /// or a later Claude Code refuses it, the turn is retried once without it and it stays off for that model.
    private var noThinkingBody: String? {
        guard effort.isEmpty, !Self.keepThinking, !Self.thinkingBodyBroken.contains(model) else { return nil }
        if let test = ProcessInfo.processInfo.environment["POINKY_NO_THINKING_BODY"] { return test }   // (tests: a body the API refuses)
        return Self.noThinkingBody(for: model)
    }
    static func noThinkingBody(for model: String) -> String? {
        let m = model.lowercased()
        let kind = m.contains("haiku") ? "disabled" : m.contains("sonnet") ? "between_tools" : nil
        return kind.map { #"{"thinking":{"type":""# + $0 + #""},"context_management":{"edits":[]}}"# }
    }
    private var skipThinking: Bool { noThinkingBody != nil }
    /// Models whose no-thinking request was refused (all of them with POINKY_KEEP_THINKING).
    private static var thinkingBodyBroken: Set<String> = []
    private static let keepThinking = ProcessInfo.processInfo.environment["POINKY_KEEP_THINKING"] != nil
    private var lastLine: Data?
    private var lastQuestion = ""
    /// Tests: `POINKY_RAW_LOG=file` appends every finished reply (model, which prompt, the question's text, the raw reply).
    private static let rawLog = ProcessInfo.processInfo.environment["POINKY_RAW_LOG"]
    private func logRaw(_ reply: String, error: String? = nil) {
        guard let path = Self.rawLog else { return }
        var o: [String: Any] = ["t": Date().timeIntervalSince1970, "model": model,
                                "prompt": String(systemPrompt.prefix(60)), "q": lastQuestion, "reply": reply]
        if let error { o["error"] = error }
        guard var d = try? JSONSerialization.data(withJSONObject: o) else { return }
        d.append(0x0A)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(d); try? h.close() }
    }
    private var retriedID: Int?
    /// Claude Code tools it may use (none for the talker, teacher, guide and doer; WebSearch and WebFetch
    /// for the web searcher). Each one is also pre-approved, since nobody is there to say yes.
    private let tools: [String]
    /// Where it runs (default: the settings folder). The web searcher gets an empty folder of its own.
    private let workDir: URL?

    /// `effort` "" keeps it fast (no thinking step); a level lets it think that much.
    init(model: String, effort: String = "", claudePath: String, systemPrompt: String,
         tools: [String] = [], workDir: URL? = nil) {
        self.model = model
        self.effort = AppConfig.efforts.contains(effort) ? effort : ""
        self.explicitPath = claudePath
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.workDir = workDir
    }

    func warmUp() async throws { try launchIfNeeded() }

    func ask(_ question: BrainQuestion, onText: @escaping (String) -> Void) async throws -> String {
        // One question at a time: wait for the previous answer to finish first.
        while pending != nil {
            await withCheckedContinuation { idleWaiters.append($0) }
            try Task.checkCancellation()
        }
        try launchIfNeeded()
        let msg: [String: Any] = [
            "type": "user",
            "message": ["role": "user",
                        "content": question.imageBlocks + [["type": "text", "text": question.text]]],
        ]
        var line = try JSONSerialization.data(withJSONObject: msg)
        line.append(0x0A)
        lastLine = line
        lastQuestion = question.text

        return try await withCheckedThrowingContinuation { cont in
            nextID += 1
            pending = Pending(cont: cont, onText: onText, id: nextID)
            lastOutputAt = ProcessInfo.processInfo.systemUptime
            startWatchdog()
            send(line, failing: nextID)
        }
    }

    /// Writes a line to Claude Code off the main thread. If it can't be written, the question `failing`
    /// (if it's still the one waiting) fails; a write that never finishes is caught by the watchdog.
    private func send(_ line: Data, failing id: Int? = nil) {
        guard let h = stdin, let q = writer else {
            if let id { fail(id, BrainError("Couldn't talk to Claude Code: it isn't running.")) }
            return
        }
        let model = self.model
        q.async {
            do {
                try h.write(contentsOf: line)
                // (Timeline: when the question was handed to Claude Code, for the stages of the wait.)
                if id != nil { Timeline.log("brain.sent", ["model": model, "kb": line.count / 1024]) }
            } catch {
                guard let id else { return }
                let why = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.fail(id, BrainError("Couldn't talk to Claude Code: \(why)")) }
                }
            }
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        guard let p = pending, p.id == id else { return }
        pending = nil
        p.cont.resume(throwing: error)
    }

    /// Ends the process and its input. The input is closed on its writer queue (after any write still
    /// in progress, which ends once the process is gone); one that ignores SIGTERM is killed.
    private func endProcess() {
        let h = stdin, p = process
        stdin = nil
        process = nil
        if let h { (writer ?? DispatchQueue.global()).async { try? h.close() } }
        writer = nil
        guard let p, p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { kill(pid, SIGKILL) } }
    }

    /// Interrupt the turn in progress (Claude Code ends it with a result); if it doesn't end soon, restart.
    func cancelCurrent() {
        guard let id = pending?.id, cancelledID != id, stdin != nil else { return }
        cancelledID = id
        Timeline.log("brain.cancel", ["model": model])
        let req: [String: Any] = ["type": "control_request", "request_id": "cancel-\(id)", "request": ["subtype": "interrupt"]]
        if var line = try? JSONSerialization.data(withJSONObject: req) {
            line.append(0x0A)
            send(line)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pending?.id == id else { return }
                self.restart(CancellationError())
            }
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.pending != nil else { self.watchdog?.invalidate(); self.watchdog = nil; return }
                if ProcessInfo.processInfo.systemUptime - self.lastOutputAt > Self.stallSeconds {
                    self.restart(BrainError("Claude Code stopped answering, so I restarted it. Ask again?"))
                }
            }
        }
    }

    /// Kill a stuck process: the waiting question fails with `reason`, the next one starts a fresh process.
    private func restart(_ error: Error) {
        Timeline.log("brain.restart", ["model": model, "why": error is CancellationError ? "didn't stop when interrupted" : error.localizedDescription])
        NSLog("Poinky: restarting claude (\(error is CancellationError ? "didn't stop when interrupted" : error.localizedDescription))")
        if let p = pending {
            pending = nil
            p.cont.resume(throwing: error)
        }
        endProcess()
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        if let p = pending {
            pending = nil
            p.cont.resume(throwing: CancellationError())
        }
        wakeWaiters()
        endProcess()
    }

    // MARK: - Process

    private func launchIfNeeded() throws {
        if let p = process, p.isRunning { return }
        guard let path = Self.findClaude(explicit: explicitPath) else {
            throw BrainError("Claude Code isn't installed. Install it from claude.com/claude-code and sign in (run `claude` once in Terminal), or switch to an API key: ✨ menu → Settings → Claude.")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",   // stream words as they're written
            "--model", model,
            "--tools", tools.joined(separator: ","),   // "": no file/bash tools, it only looks and talks
            "--strict-mcp-config",          // skip loading MCP servers (faster startup)
            "--disable-slash-commands",
            "--setting-sources", "",        // ignore project/user hooks & settings
            "--no-session-persistence",
            "--system-prompt", systemPrompt,
        ]
        if !tools.isEmpty { p.arguments! += ["--allowedTools"] + tools }
        if effort.isEmpty {
            p.arguments! += ["--settings", #"{"alwaysThinkingEnabled":false}"#]
        } else {
            p.arguments! += ["--effort", effort]
        }
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        if effort.isEmpty { env["MAX_THINKING_TOKENS"] = "0" }   // skip the thinking step: faster replies
        if let body = noThinkingBody, env["CLAUDE_CODE_EXTRA_BODY"] == nil { env["CLAUDE_CODE_EXTRA_BODY"] = body }
        p.environment = env
        let dir = workDir ?? AppConfig.dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        p.currentDirectoryURL = dir

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            // (A process that was restarted can still flush output: it must not answer the next question.)
            DispatchQueue.main.async { MainActor.assumeIsolated { guard let self, self.process === p else { return }; self.ingest(data) } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stderrTail = String((self.stderrTail + s).suffix(1500))
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.processEnded(p) } }
        }

        buffer.removeAll()
        stderrTail = ""
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        writer = DispatchQueue(label: "poinky.claude.stdin")
    }

    private func processEnded(_ p: Process) {
        guard p === process else { return }
        endProcess()
        if let pend = pending {
            pending = nil
            let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            pend.cont.resume(throwing: BrainError("Claude Code stopped unexpectedly. \(detail)"))
        }
    }

    private func ingest(_ data: Data) {
        lastOutputAt = ProcessInfo.processInfo.systemUptime
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer = Data(buffer[(nl + 1)...])
            if !lineData.isEmpty { handleLine(Data(lineData)) }
        }
    }

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "stream_event":
            guard let event = obj["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let t = delta["text"] as? String else { return }
            pending?.text += t
            pending?.gotDeltas = true
            pending?.onText(t)

        case "assistant":
            // Fallback if partial streaming wasn't delivered.
            guard var pend = pending, !pend.gotDeltas,
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { return }
            let t = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            guard !t.isEmpty else { return }
            pend.text += t
            pending = pend
            pend.onText(t)

        case "result":
            if let u = obj["usage"] as? [String: Any] {
                func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                let fresh = n("input_tokens"), cached = n("cache_read_input_tokens"), written = n("cache_creation_input_tokens")
                lastInputTokens = fresh + cached + written
                // (Claude Code's own split of the wait: its time before the request went out, then the model's first token.)
                Timeline.log("usage", ["model": model, "in": lastInputTokens, "cached": cached, "out": n("output_tokens"),
                                       "ms": (obj["duration_ms"] as? NSNumber)?.intValue ?? 0,
                                       "ttftMs": (obj["ttft_stream_ms"] as? NSNumber)?.intValue ?? -1,
                                       "requestMs": (obj["time_to_request_ms"] as? NSNumber)?.intValue ?? -1])
            }
            guard let pend = pending else { return }
            pending = nil
            logRaw(pend.text, error: pend.id == cancelledID ? "cancelled" : obj["is_error"] as? Bool == true ? ((obj["result"] as? String) ?? "error") : nil)
            if pend.id == cancelledID {
                pend.cont.resume(throwing: CancellationError())
            } else if obj["is_error"] as? Bool == true, retryWithThinking(pend, error: (obj["result"] as? String) ?? "") {
                return
            } else if obj["is_error"] as? Bool == true {
                let msg = (obj["result"] as? String) ?? "Claude Code returned an error."
                var err = BrainError(msg)
                if limit.rejected { err.limitHit = true; err.limitResetsAt = limit.resetsAt }
                pend.cont.resume(throwing: err)
            } else {
                let final = pend.text.isEmpty ? ((obj["result"] as? String) ?? "") : pend.text
                pend.cont.resume(returning: final)
            }

        case "rate_limit_event":
            guard let info = obj["rate_limit_info"] as? [String: Any], let status = info["status"] as? String else { return }
            limit = (status == "rejected", (info["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })

        default:
            break
        }
    }

    /// The API (or a newer Claude Code) refused the no-thinking request: turn it off for good, restart
    /// without it and send the same question again, once. Returns false if this error is something else.
    private func retryWithThinking(_ pend: Pending, error: String) -> Bool {
        let e = error.lowercased()
        guard skipThinking, retriedID != pend.id, let line = lastLine,
              e.contains("400") || e.contains("invalid_request"),
              e.contains("thinking") || e.contains("context_management") || e.contains("extra") else { return false }
        Self.thinkingBodyBroken.insert(model)
        retriedID = pend.id
        Timeline.log("brain.thinking", ["model": model, "why": String(error.prefix(160))])
        NSLog("Poinky: no-thinking request refused (\(error.prefix(160))); retrying with thinking")
        endProcess()
        pending = Pending(cont: pend.cont, onText: pend.onText, id: pend.id)
        do {
            try launchIfNeeded()
            send(line, failing: pend.id)
        } catch {
            pending = nil
            pend.cont.resume(throwing: BrainError("Couldn't talk to Claude Code: \(error.localizedDescription)"))
        }
        return true
    }

    // MARK: - Finding `claude`

    static func findClaude(explicit: String) -> String? {
        // Tests: a fake `claude` (tools/fake-claude.py) that answers, hangs or crashes without tokens.
        if let fake = ProcessInfo.processInfo.environment["POINKY_CLAUDE_CMD"], !fake.isEmpty { return fake }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [explicit,
                          "\(home)/.local/bin/claude",
                          "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude",
                          "/usr/local/bin/claude"].filter { !$0.isEmpty }
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }

        // Last resort: ask a login shell where it is (e.g. an npm install under nvm). This runs on the main
        // thread for every Claude Code session started, and a login shell can be slow or hang: so a found
        // path is kept, and the shell gets a few seconds at most.
        if let p = shellFound, fm.isExecutableFile(atPath: p) { return p }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        guard (try? p.run()) != nil else { return nil }
        if done.wait(timeout: .now() + 5) == .timedOut {
            p.terminate()
            Timeline.log("timeout", ["what": "Finding claude with a login shell", "secs": 5])
            return bundledClaude(home: home)
        }
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard fm.isExecutableFile(atPath: path) else { return bundledClaude(home: home) }
        shellFound = path
        return path
    }
    private static var shellFound: String?

    /// No `claude` on the PATH: the copy that comes with the Claude desktop app, or with the Claude Code
    /// extension in Cursor / VS Code (newest version first). Same CLI, same sign-in (~/.claude).
    nonisolated static func bundledClaude(home: String) -> String? {
        let fm = FileManager.default
        func newestFirst(_ names: [String], version: (String) -> String) -> [String] {
            names.sorted { a, b in
                let x = version(a).split(separator: ".").compactMap { Int($0) }, y = version(b).split(separator: ".").compactMap { Int($0) }
                return y.lexicographicallyPrecedes(x)
            }
        }
        var found: [String] = []
        let desktop = "\(home)/Library/Application Support/Claude/claude-code"
        for v in newestFirst((try? fm.contentsOfDirectory(atPath: desktop)) ?? [], version: { $0 }) {
            for h in (try? fm.contentsOfDirectory(atPath: "\(desktop)/\(v)")) ?? [] {
                found.append("\(desktop)/\(v)/\(h)/claude.app/Contents/MacOS/claude")
            }
        }
        for editor in [".cursor", ".vscode", ".windsurf"] {
            let dir = "\(home)/\(editor)/extensions"
            let exts = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("anthropic.claude-code-") }
            let version: (String) -> String = { String($0.dropFirst("anthropic.claude-code-".count).split(separator: "-").first ?? "") }
            for e in newestFirst(exts, version: version) { found.append("\(dir)/\(e)/resources/native-binary/claude") }
        }
        return found.first { fm.isExecutableFile(atPath: $0) }
    }
}
