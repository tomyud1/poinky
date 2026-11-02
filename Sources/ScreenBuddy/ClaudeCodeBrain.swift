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
        var text = ""
        var gotDeltas = false
    }
    private var pending: Pending? {
        didSet { if pending == nil { wakeWaiters() } }
    }
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    private func wakeWaiters() {
        let w = idleWaiters
        idleWaiters.removeAll()
        w.forEach { $0.resume() }
    }

    init(model: String, claudePath: String, systemPrompt: String) {
        self.model = model
        self.explicitPath = claudePath
        self.systemPrompt = systemPrompt
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
            pending = Pending(cont: cont, onText: onText)
            do {
                try stdin?.write(contentsOf: line)
            } catch {
                pending = nil
                cont.resume(throwing: BrainError("Couldn't talk to Claude Code: \(error.localizedDescription)"))
            }
        }
    }

    func stop() {
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
            throw BrainError("Couldn't find the `claude` command. Set \"claudePath\" in the settings file.")
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
            "--tools", "",                  // no file/bash tools: it only looks and talks
            "--strict-mcp-config",          // skip loading MCP servers (faster startup)
            "--disable-slash-commands",
            "--setting-sources", "",        // ignore project/user hooks & settings
            "--settings", #"{"alwaysThinkingEnabled":false}"#,
            "--no-session-persistence",
            "--system-prompt", systemPrompt,
        ]
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")
        env["MAX_THINKING_TOKENS"] = "0"   // skip the thinking step: faster replies
        p.environment = env
        try? FileManager.default.createDirectory(at: AppConfig.dir, withIntermediateDirectories: true)
        p.currentDirectoryURL = AppConfig.dir

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ingest(data) } }
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
            if obj["is_error"] as? Bool == true {
                let msg = (obj["result"] as? String) ?? "Claude Code returned an error."
                pend.cont.resume(throwing: BrainError(msg))
            } else {
                let final = pend.text.isEmpty ? ((obj["result"] as? String) ?? "") : pend.text
                pend.cont.resume(returning: final)
            }

        default:
            break
        }
    }

    // MARK: - Finding `claude`

    static func findClaude(explicit: String) -> String? {
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
