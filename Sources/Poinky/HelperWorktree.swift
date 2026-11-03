import Foundation

/// Helpers working in the same git repo at the same time each get their own copy of it (a git worktree),
/// so they don't step on each other. The first one works in your folder as usual; the next ones get a
/// worktree made from your folder exactly as it is now (uncommitted changes included). When one finishes,
/// its changes are brought back into your folder (as uncommitted changes, like any helper's), and the
/// worktree is removed. If they don't fit (someone changed the same lines meanwhile), they're kept on a
/// branch instead, and the helper's report says which.
enum HelperWorktree {
    struct Info: Equatable {
        /// Your repo (its top folder), and the worktree's folder.
        let top: URL
        let path: URL
        /// The commit it started from (your folder as it was, uncommitted changes included).
        let base: String
        /// Where the helper works: the same subfolder of the worktree as the one it was given.
        let workDir: URL
    }

    enum Merge: Equatable {
        case nothing                         // it changed nothing
        case merged(files: [String], patch: URL)
        case kept(branch: String, files: [String])
        case failed(String)
    }

    static var root: URL { AppConfig.dir.appendingPathComponent("worktrees", isDirectory: true) }

    /// The repo a folder is in (its top folder), or nil.
    static func top(of dir: URL) -> URL? {
        let r = git(["rev-parse", "--show-toplevel"], in: dir)
        guard r.ok, !r.out.isEmpty else { return nil }
        return URL(fileURLWithPath: r.out, isDirectory: true).resolvingSymlinksInPath()
    }

    /// Makes a worktree of `dir`'s repo for the helper `name`, from your folder as it is now. Nil if the
    /// repo has no commits yet or git fails (then it works in your folder, as before).
    static func make(for dir: URL, name: String, at path: URL? = nil) -> Info? {
        guard let top = top(of: dir) else { return nil }
        // Your folder exactly as it is (uncommitted changes too), without touching it.
        var base = git(["stash", "create"], in: top).out
        if base.isEmpty { base = git(["rev-parse", "HEAD"], in: top).out }
        guard !base.isEmpty else { return nil }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "")
        let safe = { (s: String) in String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }) }
        let wt = path ?? root.appendingPathComponent("\(safe(top.lastPathComponent))-\(safe(name))-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: wt.path) { remove(wt, top: top) }
        guard git(["worktree", "add", "--detach", wt.path, base], in: top).ok else { return nil }
        // Untracked files you made aren't in a commit: copy the ones git doesn't ignore.
        let untracked = git(["ls-files", "--others", "--exclude-standard", "-z"], in: top).out
        for rel in untracked.split(separator: "\0").map(String.init) where !rel.isEmpty {
            let from = top.appendingPathComponent(rel), to = wt.appendingPathComponent(rel)
            try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: from, to: to)
        }
        // Commit those too, so they're part of the base (and not the helper's own changes).
        if !untracked.isEmpty {
            _ = git(["add", "-A"], in: wt)
            _ = git(["-c", "user.name=Poinky", "-c", "user.email=poinky@localhost", "commit", "-q", "--no-verify", "-m", "Poinky: start"], in: wt)
            base = git(["rev-parse", "HEAD"], in: wt).out
        }
        let rel = dir.resolvingSymlinksInPath().path.dropFirst(top.path.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Info(top: top, path: wt, base: base, workDir: rel.isEmpty ? wt : wt.appendingPathComponent(rel, isDirectory: true))
    }

    /// Brings a finished helper's changes back into your folder (`keepOnly`: keep them on a branch, for a
    /// helper that failed or was stopped), then removes its worktree.
    static func finish(_ w: Info, name: String, title: String, keepOnly: Bool, patchTo: URL) -> Merge {
        defer { remove(w.path, top: w.top) }
        _ = git(["add", "-A"], in: w.path)
        let diff = git(["diff", "--cached", "--binary", w.base], in: w.path, keepWhitespace: true)
        guard diff.ok else { return .failed("git couldn't read its changes") }
        if diff.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .nothing }
        let files = git(["diff", "--cached", "--name-only", w.base], in: w.path).out.split(separator: "\n").map(String.init)
        try? diff.out.write(to: patchTo, atomically: true, encoding: .utf8)
        if !keepOnly, git(["apply", "--check", "--binary", patchTo.path], in: w.top).ok, git(["apply", "--binary", patchTo.path], in: w.top).ok {
            return .merged(files: files, patch: patchTo)
        }
        // Doesn't fit (or it didn't finish): keep its work on a branch.
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "").lowercased()
        let branch = "poinky/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))-\(stamp)"
        guard git(["-c", "user.name=Poinky", "-c", "user.email=poinky@localhost", "commit", "-q", "--no-verify", "-m", "Poinky helper \(name): \(title)"], in: w.path).ok,
              git(["branch", branch, "HEAD"], in: w.path).ok else { return .failed("git couldn't keep its changes on a branch") }
        return .kept(branch: branch, files: files)
    }

    /// Undoing a helper whose changes were brought back from its worktree: the saved patch, in reverse.
    /// With `dryRun`, only checks it (and lists the files).
    static func unapply(patch: URL, in top: URL, dryRun: Bool) -> HelperUndo.Outcome {
        let files = git(["apply", "--numstat", patch.path], in: top).out.split(separator: "\n")
            .compactMap { $0.split(separator: "\t").last.map { top.appendingPathComponent(String($0)).path } }
        guard git(["apply", "-R", "--check", "--binary", patch.path], in: top).ok else {
            return .failed("Those files changed since, so its changes can't be taken out cleanly.")
        }
        if dryRun { return .preview(HelperUndo.Preview(files: files, changedSince: [])) }
        return git(["apply", "-R", "--binary", patch.path], in: top).ok ? .done(files) : .failed("git couldn't take its changes out.")
    }

    static func remove(_ path: URL, top: URL) {
        if !git(["worktree", "remove", "--force", path.path], in: top).ok { try? FileManager.default.removeItem(at: path) }
        _ = git(["worktree", "prune"], in: top)
    }

    /// Runs git in a folder; its output, trimmed.
    @discardableResult
    static func git(_ args: [String], in dir: URL, keepWhitespace: Bool = false) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (false, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(data: data, encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, keepWhitespace ? s : s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
