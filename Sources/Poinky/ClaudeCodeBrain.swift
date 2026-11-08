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

        return try await withCheckedThrowingContinuation { cont in
            nextID += 1
            pending = Pending(cont: cont, onText: onText, id: nextID)
            lastOutputAt = ProcessInfo.processInfo.systemUptime
            startWatchdog()
            do {
                try stdin?.write(contentsOf: line)
            } catch {
                pending = nil
                cont.resume(throwing: BrainError("Couldn't talk to Claude Code: \(error.localizedDescription)"))
            }
        }
    }

    /// Interrupt the turn in progress (Claude Code ends it with a result); if it doesn't end soon, restart.
    func cancelCurrent() {
        guard let id = pending?.id, cancelledID != id, let stdin else { return }
        cancelledID = id
        Timeline.log("brain.cancel", ["model": model])
        let req: [String: Any] = ["type": "control_request", "request_id": "cancel-\(id)", "request": ["subtype": "interrupt"]]
        if var line = try? JSONSerialization.data(withJSONObject: req) {
            line.append(0x0A)
            try? stdin.write(contentsOf: line)
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
        try? stdin?.close()
        stdin = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
    }

    func stop() {
        watchdog?.invalidate(); watchdog = nil
        if let p = pending {
            pending = nil
            p.cont.resume(throwing: CancellationError())
        }
        wakeWaiters()
        try? stdin?.close()
        stdin = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
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
    }

    private func processEnded(_ p: Process) {
        guard p === process else { return }
        process = nil
        stdin = nil
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
            guard let pend = pending else { return }
            pending = nil
            if pend.id == cancelledID {
                pend.cont.resume(throwing: CancellationError())
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

        // Last resort: ask a login shell where it is.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fm.isExecutableFile(atPath: path) ? path : nil
    }
}
