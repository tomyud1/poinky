import Foundation

/// Undo: puts the files a helper changed back the way they were before one of its runs, with Claude
/// Code's own checkpoints. Helpers run with checkpoints on, and each message to them is echoed back with
/// its id (a checkpoint entry in their window). To undo, Poinky opens the helper's session again
/// (`--resume`, no new message, so no model is called) and asks Claude Code to rewind the files to that
/// checkpoint. It works for finished helpers too, also after Poinky restarts.
enum HelperUndo {
    struct Preview: Equatable {
        /// The files it would put back (full paths).
        var files: [String]
        /// Of those, the ones changed after the helper finished (maybe by you): undoing would lose that.
        var changedSince: [String]
    }

    enum Outcome: Equatable {
        case preview(Preview)
        case done([String])
        case failed(String)
    }

    /// The environment that turns Claude Code's checkpoints on for a helper (and for undoing).
    static let checkpointEnv = ("CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING", "true")

    /// Asks Claude Code to put the files back to `checkpoint` (or, with `dryRun`, which files that would
    /// change). Runs in the background; `done` is called on the main thread.
    static func rewind(exe: String, dir: URL, session: String, checkpoint: String, dryRun: Bool, finished: Date?,
                       done: @escaping @MainActor (Outcome) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                       "--resume", session, "--permission-prompt-tool", "stdio"]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        for k in env.keys where k.hasPrefix("CLAUDE_CODE_") || k.hasPrefix("CLAUDE_AGENT_SDK") { env[k] = nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env[checkpointEnv.0] = checkpointEnv.1
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        func finish(_ o: Outcome) { DispatchQueue.main.async { MainActor.assumeIsolated { done(o) } } }
        do { try p.run() } catch { finish(.failed("Claude Code couldn't start.")); return }
        let rid = "undo-\(UUID().uuidString)"
        let req: [String: Any] = ["type": "control_request", "request_id": rid,
                                  "request": ["subtype": "rewind_files", "user_message_id": checkpoint, "dry_run": dryRun]]
        guard var line = try? JSONSerialization.data(withJSONObject: req) else { finish(.failed("Couldn't ask Claude Code.")); return }
        line.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: line)
        // Never hang: give up after 30 seconds.
        let timeout = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            var outcome: Outcome = .failed("Claude Code didn't answer.")
            read: while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let l = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let obj = try? JSONSerialization.jsonObject(with: l) as? [String: Any], obj["type"] as? String == "control_response",
                          let r = obj["response"] as? [String: Any], r["request_id"] as? String == rid else { continue }
                    outcome = parse(r, dryRun: dryRun, finished: finished)
                    break read
                }
            }
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
            finish(outcome)
        }
    }

    /// Claude Code's answer to a rewind request.
    static func parse(_ r: [String: Any], dryRun: Bool, finished: Date?) -> Outcome {
        if r["subtype"] as? String == "error" { return .failed((r["error"] as? String) ?? "Claude Code couldn't undo it.") }
        let body = r["response"] as? [String: Any] ?? [:]
        if body["canRewind"] as? Bool == false {
            return .failed((body["error"] as? String) ?? "There's nothing saved to go back to.")
        }
        let files = (body["filesChanged"] as? [String]) ?? []
        guard dryRun else { return .done(files) }
        // Changed after it finished (give it a few seconds): probably by you.
        let since = files.filter { f in
            guard let finished, let m = (try? FileManager.default.attributesOfItem(atPath: f))?[.modificationDate] as? Date else { return false }
            return m.timeIntervalSince(finished) > 5
        }
        return .preview(Preview(files: files, changedSince: since))
    }

    /// "calc.py and notes.txt", "calc.py, notes.txt and 3 more".
    static func names(_ files: [String]) -> String {
        let n = files.map { ($0 as NSString).lastPathComponent }
        switch n.count {
        case 0: return "no files"
        case 1: return n[0]
        case 2...3: return n.dropLast().joined(separator: ", ") + " and " + n.last!
        default: return n.prefix(2).joined(separator: ", ") + " and \(n.count - 2) more"
        }
    }
}
