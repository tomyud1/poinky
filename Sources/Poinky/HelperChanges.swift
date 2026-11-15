import AppKit

/// What a helper changed, for its window: the files it edited (from its steps) and their diff right now
/// (`git diff` against the last commit, new files in full), and a way to open its session in Terminal
/// (`claude --resume`), for when you want Claude Code's own screen.
enum HelperChanges {
    /// The files it edited or wrote, in the order it first touched them (absolute paths). A helper that
    /// worked in its own worktree whose changes came back: the same files in your folder.
    static func files(_ entries: [HelperEntry]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        let wt = entries.last(where: { $0.k == "worktree" })
        for e in entries where e.k == "step" && e.kind == "edit" {
            guard var p = e.detail, p.hasPrefix("/") else { continue }
            if let wt, let copy = wt.detail, !wt.text.isEmpty, p.hasPrefix(copy + "/"),
               !FileManager.default.fileExists(atPath: copy) {
                p = wt.text + p.dropFirst(copy.count)
            }
            if seen.insert(p).inserted { out.append(p) }
        }
        return out
    }

    /// The folder its changes are in now: its worktree while that still exists, else its own folder.
    static func folder(_ entries: [HelperEntry], dir: URL) -> URL {
        if let copy = entries.last(where: { $0.k == "worktree" })?.detail, FileManager.default.fileExists(atPath: copy) {
            return URL(fileURLWithPath: copy)
        }
        return dir
    }

    /// Where its changes start: your folder as it was when it started (`git stash create` keeps your
    /// uncommitted changes out of its diff without touching anything; a clean folder: HEAD). Nil outside a repo.
    static func startPoint(_ dir: URL) -> String? {
        guard git(["rev-parse", "--show-toplevel"], in: dir, timeout: 3) != nil else { return nil }
        if let s = git(["stash", "create"], in: dir, timeout: 3)?.out.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        let h = git(["rev-parse", "HEAD"], in: dir, timeout: 3)?.out.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return h.isEmpty ? nil : h
    }

    /// The commit its changes start from: recorded when it started (`base`), or its worktree's.
    static func base(_ entries: [HelperEntry]) -> String? {
        entries.last(where: { $0.k == "base" })?.id ?? entries.last(where: { $0.k == "worktree" })?.id
    }

    /// Its work kept on a git branch (its worktree's changes didn't fit your folder): the diff of that
    /// branch from where it started, starting with "#@branch <name>". Nil if there's no such branch (any more).
    static func branchDiff(_ entries: [HelperEntry]) -> String? {
        guard let b = entries.last(where: { $0.k == "branch" }), let branch = b.id, !b.text.isEmpty else { return nil }
        let repo = URL(fileURLWithPath: b.text)
        guard let r = git(["rev-parse", "--verify", "--quiet", "refs/heads/" + branch], in: repo), r.code == 0, !r.out.isEmpty else {
            return "# Its changes were on the git branch \(branch), which isn't there any more (merged or deleted?)."
        }
        let from = base(entries).flatMap { c in git(["cat-file", "-e", c + "^{commit}"], in: repo)?.code == 0 ? c : nil } ?? (branch + "^")
        let d = git(["diff", "--no-color", "--no-ext-diff", from, "refs/heads/" + branch], in: repo)?.out ?? ""
        return "#@branch \(branch)\n" + (d.isEmpty ? "# No changes on it." : d)
    }

    /// The diff of those files (unified, no color): from `base` (where it started, so what it committed
    /// counts too) when that's known, else from the last commit. Not in a git repo: says so.
    /// Starts with "#@since-start" when it's from where it started.
    static func diff(files: [String], in dir: URL, base: String? = nil) -> String {
        guard !files.isEmpty else { return "" }
        guard let gitTop = git(["rev-parse", "--show-toplevel"], in: dir)?.out.trimmingCharacters(in: .whitespacesAndNewlines), !gitTop.isEmpty else {
            return "# Not in a git repository, so there's no diff to show. Files it changed:\n" + files.map { "#   " + $0 }.joined(separator: "\n")
        }
        // Paths as git sees them (/var is /private/var, a symlinked home folder…).
        let real = { (p: String) -> String in
            let r = URL(fileURLWithPath: p).resolvingSymlinksInPath().path
            if r != p { return r }
            let parent = URL(fileURLWithPath: p).deletingLastPathComponent().resolvingSymlinksInPath()   // a deleted file
            return parent.appendingPathComponent((p as NSString).lastPathComponent).path
        }
        let top = real(gitTop)
        let root = URL(fileURLWithPath: top)
        let inRepo = files.map(real).filter { $0.hasPrefix(top + "/") }
        let outside = files.filter { !real($0).hasPrefix(top + "/") }
        var parts: [String] = []
        if !inRepo.isEmpty {
            let rel = inRepo.map { String($0.dropFirst(top.count + 1)) }
            let untracked = Set((git(["ls-files", "--others", "--exclude-standard", "--"] + rel, in: root)?.out ?? "")
                .split(separator: "\n").map(String.init))
            let tracked = rel.filter { !untracked.contains($0) }
            let from = base.flatMap { b in b.allSatisfy(\.isHexDigit) && git(["cat-file", "-e", b + "^{commit}"], in: root)?.code == 0 ? b : nil }
            if from != nil { parts.append("#@since-start") }
            if !tracked.isEmpty, let d = git(["diff", "--no-color", "--no-ext-diff", from ?? "HEAD", "--"] + tracked, in: root)?.out, !d.isEmpty { parts.append(d) }
            for f in rel where untracked.contains(f) {
                if let d = git(["diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", f], in: root)?.out, !d.isEmpty { parts.append(d) }
            }
            let shown = Set(parts.filter { $0 != "#@since-start" }.joined(separator: "\n").components(separatedBy: "\n")
                .compactMap { $0.hasPrefix("+++ b/") ? String($0.dropFirst(6)) : nil })
            let same = rel.filter { !shown.contains($0) }
            if !same.isEmpty {
                parts.append("# No changes now (committed, undone, or deleted since):\n" + same.map { "#   " + $0 }.joined(separator: "\n"))
            }
        }
        if !outside.isEmpty { parts.append("# Outside the repository:\n" + outside.map { "#   " + $0 }.joined(separator: "\n")) }
        return parts.joined(separator: "\n")
    }

    /// Lines added and removed in a diff.
    static func counts(_ diff: String) -> (added: Int, removed: Int) {
        var a = 0, r = 0
        for l in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if l.hasPrefix("+++") || l.hasPrefix("---") { continue }
            if l.hasPrefix("+") { a += 1 } else if l.hasPrefix("-") { r += 1 }
        }
        return (a, r)
    }

    private static func git(_ args: [String], in dir: URL, timeout: TimeInterval = 8) -> (out: String, code: Int32)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        var data = Data()
        let reader = DispatchQueue(label: "poinky.git")
        let done = DispatchSemaphore(value: 0)
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        p.waitUntilExit()
        // --no-index exits 1 when the files differ; other git errors print nothing to stdout.
        guard p.terminationStatus == 0 || p.terminationStatus == 1 else { return nil }
        return (String(decoding: data.prefix(2_000_000), as: UTF8.self), p.terminationStatus)
    }

    // MARK: - Its session in Terminal

    /// A double-clickable script that opens its Claude Code session in Terminal, in its folder. While it's
    /// still working here, Terminal gets a copy of the session (`--fork-session`), so the two don't collide.
    static func terminalScript(claude: String, dir: URL, session: String, fork: Bool) -> String {
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let safe = session.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return "#!/bin/bash\n# Opened from Poinky's Helpers window.\ncd \(q(dir.path)) || exit 1\nrm -f \"$0\"\nexec \(q(claude)) --resume \(safe ? session : q(session))\(fork ? " --fork-session" : "")\n"
    }

    /// Writes the script and opens it in Terminal. Returns its path (nil if it couldn't).
    @discardableResult
    static func openInTerminal(claude: String, dir: URL, session: String, fork: Bool, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poinky-\(name.lowercased())-\(UUID().uuidString.prefix(6)).command")
        do {
            try terminalScript(claude: claude, dir: dir, session: session, fork: fork).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { return nil }
        if ProcessInfo.processInfo.environment["POINKY_TEST_NO_TERMINAL"] == nil {
            guard NSWorkspace.shared.open(url) else { return nil }   // Terminal, or the app you open .command files with
        }
        return url
    }
}
