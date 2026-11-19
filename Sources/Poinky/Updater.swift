import AppKit

/// Settings → General → Updates, and the arrow in the notch when there's a new version: gets the newest
/// Poinky from GitHub and builds it on this Mac with build.sh, the way install.sh does, so it's signed
/// with the same certificate and macOS keeps its permissions. Poinky keeps working while it builds;
/// the new version starts when you click Restart (nothing restarts by itself).
///
/// Where the source is: the folder this app was built from (build.sh writes it into Info.plist as
/// `PoinkySource`, with the commit as `PoinkyCommit`), else the installer's copy in
/// `Poinky/source`. The installer's copy is reset to GitHub's version; a folder of your own is only
/// fast-forwarded, and never when it has changes that aren't committed.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle                   // not checked yet
        case checking
        case upToDate
        case available              // `changes` says what's new
        case updating               // `step`, `progress`
        case ready                  // built; restart to use it
        case unavailable(String)    // this copy can't update itself (why)
        case failed(String)
    }
    @Published private(set) var state = State.idle { didSet { if state != oldValue { onChange?() } } }
    @Published private(set) var changes: [String] = []     // commit titles, newest first
    @Published private(set) var step = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var lastChecked: Date?
    /// A folder of your own already has GitHub's version but this build is older: not an update (nothing to
    /// get), just a rebuild. Said in Settings; no arrow in the notch.
    @Published private(set) var rebuildNote: String?
    /// The notch shows an arrow while an update is available or ready.
    var onChange: (() -> Void)?
    /// Why restarting now would interrupt something ("Mint is still working…"), or nil.
    var busyReason: () -> String? = { nil }

    private var target = ""         // the commit to update to
    private var timer: Timer?
    private var newApp: URL?        // a copy waiting to replace the running app on restart

    nonisolated static let log = AppConfig.dir.appendingPathComponent("update.log")
    static let checkEvery: TimeInterval = 6 * 3600

    // MARK: What's running

    struct Running {
        var commit = "", date = "", dirty = false
        var source: URL?
    }
    static let running: Running = {
        let info = Bundle.main.infoDictionary ?? [:]
        var r = Running()
        r.commit = info["PoinkyCommit"] as? String ?? ""
        r.date = info["PoinkyCommitDate"] as? String ?? ""
        r.dirty = (info["PoinkyDirty"] as? String) == "1"
        if let s = info["PoinkySource"] as? String { r.source = URL(fileURLWithPath: s) }
        return r
    }()

    /// "a1b2c3d from 8 Nov 2026" (and "with local changes" for a build of edited source).
    var version: String {
        let r = Self.running
        guard !r.commit.isEmpty else {
            return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "Version \($0)" } ?? "Unknown"
        }
        var s = String(r.commit.prefix(7))
        if let d = ISO8601DateFormatter().date(from: r.date) {
            let f = DateFormatter()
            f.dateStyle = .medium
            s += " from " + f.string(from: d)
        }
        if r.dirty { s += ", with local changes" }
        return s
    }

    nonisolated static var installerSource: URL { AppConfig.dir.appendingPathComponent("source", isDirectory: true) }

    /// The git folder to update from.
    static var source: URL? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        if let s = env["POINKY_UPDATE_SOURCE"] { return URL(fileURLWithPath: s) }
        for u in [running.source, installerSource].compactMap({ $0 }) where fm.fileExists(atPath: u.appendingPathComponent(".git").path) {
            return u
        }
        return nil
    }

    /// The installer's own copy: safe to reset to GitHub's version.
    nonisolated static func isInstallerCopy(_ src: URL) -> Bool {
        if ProcessInfo.processInfo.environment["POINKY_UPDATE_MANAGED"] == "1" { return true }
        return src.standardizedFileURL.resolvingSymlinksInPath().path == installerSource.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: Checking

    /// Checks now and then (first a minute and a half after launch). Never installs anything by itself.
    func autoCheck(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { return }
        let first = lastChecked.map { max(60, Self.checkEvery - Date().timeIntervalSince($0)) } ?? 90
        timer = Timer.scheduledTimer(withTimeInterval: first, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.check()
                self?.timer = Timer.scheduledTimer(withTimeInterval: Self.checkEvery, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check() }
                }
            }
        }
    }

    /// Opening Settings checks if the last check is over an hour old.
    func checkIfStale() {
        if let t = lastChecked, Date().timeIntervalSince(t) < 3600 { return }
        check()
    }

    func check(then: (() -> Void)? = nil) {
        switch state { case .checking, .updating, .ready: return; default: break }
        guard let src = Self.source else {
            state = .unavailable("This copy of Poinky wasn't built from a folder it can find. Run the install command again to get updates.")
            return
        }
        state = .checking
        let base = Self.running.commit
        Task.detached {
            let r = Self.findUpdate(src: src, running: base)
            await MainActor.run {
                self.lastChecked = Date()
                switch r {
                case .failure(let why): self.state = .failed(why.message)
                case .success(let found):
                    self.target = found.target
                    self.changes = found.changes
                    self.rebuildNote = found.rebuild
                    // Newer, but this folder can't take it (uncommitted changes): say why, and don't offer it.
                    if found.newer, let why = found.blocked { self.state = .unavailable(why) }
                    else { self.state = found.newer ? .available : .upToDate }
                }
                Timeline.log("update.check", ["state": "\(self.state)", "changes": "\(self.changes.count)"])
                then?()
            }
        }
    }

    struct Found { var target: String; var newer: Bool; var changes: [String]; var blocked: String? = nil; var rebuild: String? = nil }

    /// Asks GitHub for the branch this copy follows. Runs off the main thread.
    nonisolated static func findUpdate(src: URL, running: String) -> Result<Found, Failure> {
        guard let up = upstream(src) else {
            return .failure(Failure("\(AppContext.tilde(src.path)) doesn't follow a branch on GitHub, so there's nothing to update from."))
        }
        let fetch = git(src, ["fetch", "--quiet", up.remote, up.branch], timeout: 90)
        guard fetch.ok else { return .failure(Failure("Couldn't reach GitHub. Check your internet connection. (\(lastLine(fetch.out)))")) }
        let target = git(src, ["rev-parse", "FETCH_HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return .failure(Failure("Couldn't read the new version.")) }
        let head = git(src, ["rev-parse", "HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let env = ProcessInfo.processInfo.environment
        let running = env["POINKY_UPDATE_RUNNING"] ?? running   // tests: the commit this build pretends to be
        let base = running.isEmpty ? head : running
        // Up to date: the same commit, or this copy is already ahead of GitHub (your own commits).
        if target == base || git(src, ["merge-base", "--is-ancestor", target, base]).ok {
            return .success(Found(target: target, newer: false, changes: []))
        }
        var log = git(src, ["log", "--format=%s", "-n", "30", "\(base)..\(target)"])
        if !log.ok { log = git(src, ["log", "--format=%s", "-n", "30", "\(head)..\(target)"]) }
        let changes = log.ok ? log.out.split(separator: "\n").map(String.init).filter { !$0.isEmpty } : []
        // Your own folder already has GitHub's version (you pulled), only this build is older: there's nothing to
        // get, so it isn't offered as an update.
        if !isInstallerCopy(src), target == head || git(src, ["merge-base", "--is-ancestor", target, head]).ok {
            let n = changes.count == 30 ? "30+" : "\(changes.count)"
            return .success(Found(target: target, newer: false, changes: [],
                                  rebuild: "\(AppContext.tilde(src.path)) has \(n) commit\(changes.count == 1 ? "" : "s") this build doesn't. Rebuild to match your source (./build.sh there)."))
        }
        return .success(Found(target: target, newer: true, changes: changes, blocked: uncommitted(src)))
    }

    /// A folder of your own with changes that aren't committed is never touched: why, or nil. Checked
    /// when looking too, so the notch doesn't offer an update that can only fail.
    nonisolated static func uncommitted(_ src: URL) -> String? {
        guard !isInstallerCopy(src) else { return nil }
        let st = git(src, ["status", "--porcelain", "--untracked-files=no"])
        guard st.ok, !st.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return "There's a new version, but \(AppContext.tilde(src.path)) has changes that aren't committed, so Poinky leaves it alone. Commit or stash them, then click Check Now."
    }

    /// "origin" + "main" for the branch the folder follows.
    nonisolated static func upstream(_ src: URL) -> (remote: String, branch: String)? {
        let r = git(src, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        let s = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, let slash = s.firstIndex(of: "/") else { return nil }
        return (String(s[..<slash]), String(s[s.index(after: slash)...]))
    }

    // MARK: Updating

    func update() {
        switch state { case .available, .failed, .upToDate: break; default: return }
        guard let src = Self.source else { return }
        if target.isEmpty { check { [weak self] in if self?.state == .available { self?.update() } }; return }
        state = .updating
        step = "Getting the new version…"
        progress = 0.03
        let target = self.target
        let dest = Bundle.main.bundleURL
        Timeline.log("update.start")
        Task.detached {
            let r = Self.install(src: src, target: target, runningApp: dest) { step, p in
                Task { @MainActor in
                    if let step { self.step = step }
                    self.progress = max(self.progress, p)
                }
            }
            await MainActor.run {
                switch r {
                case .failure(let why):
                    self.state = .failed(why.message)
                    Timeline.log("update.failed", ["why": String(why.message.prefix(100))])
                case .success(let new):
                    self.newApp = new
                    self.progress = 1
                    self.step = ""
                    self.state = .ready
                    Timeline.log("update.ready")
                }
            }
        }
    }

    /// Gets the source to `target`, builds it, and (when this app runs from somewhere else, like
    /// Applications) copies the new app next to it, ready to swap in. Returns that copy (nil: the
    /// build replaced the running app's own folder, as in a developer checkout).
    nonisolated static func install(src: URL, target: String, runningApp: URL,
                                    progress: @escaping @Sendable (String?, Double) -> Void) -> Result<URL?, Failure> {
        let installer = isInstallerCopy(src)
        let old = git(src, ["rev-parse", "HEAD"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        startLog("Updating \(src.path) from \(old) to \(target)")
        if installer {
            let r = git(src, ["reset", "--quiet", "--hard", target])
            appendLog("reset: \(r.out)")
            guard r.ok else { return .failure(Failure("Couldn't get the new version: \(lastLine(r.out))")) }
        } else {
            if let why = uncommitted(src) {
                appendLog(why)
                return .failure(Failure(why))
            }
            let r = git(src, ["merge", "--quiet", "--ff-only", target])
            appendLog("merge: \(r.out)")
            guard r.ok else {
                return .failure(Failure("\(AppContext.tilde(src.path)) has commits that aren't on GitHub, so it can't simply move ahead. Update it with git, then build."))
            }
        }

        progress("Building (about a minute)…", 0.08)
        let built = build(src: src, progress: progress)
        guard built.ok else {
            if installer, !old.isEmpty { _ = git(src, ["reset", "--quiet", "--hard", old]) }   // keep the source matching the app
            return .failure(Failure("The build didn't finish: \(lastLine(built.out)). The full log is in Settings folder → update.log."))
        }
        let app = src.appendingPathComponent("build/Poinky.app")
        let builtCommit = (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["PoinkyCommit"] as? String) ?? ""
        guard builtCommit == target else {
            return .failure(Failure("The build finished but isn't the new version (\(builtCommit.prefix(7)) instead of \(target.prefix(7)))."))
        }
        if app.standardizedFileURL.resolvingSymlinksInPath().path == runningApp.standardizedFileURL.resolvingSymlinksInPath().path {
            return .success(nil)
        }
        progress("Getting it ready…", 0.96)
        let staged = runningApp.deletingLastPathComponent().appendingPathComponent("Poinky.app.new")
        try? FileManager.default.removeItem(at: staged)
        let copy = run("/usr/bin/ditto", [app.path, staged.path], timeout: 120)
        guard copy.ok else {
            return .failure(Failure("Couldn't put the new version next to this one (\(AppContext.tilde(runningApp.deletingLastPathComponent().path))): \(lastLine(copy.out))"))
        }
        return .success(staged)
    }

    /// Runs build.sh (or `POINKY_UPDATE_BUILD`, for tests); Swift's "[12/80] Compiling…" lines move the bar.
    nonisolated static func build(src: URL, progress: @escaping @Sendable (String?, Double) -> Void) -> (ok: Bool, out: String) {
        let cmd = ProcessInfo.processInfo.environment["POINKY_UPDATE_BUILD"] ?? src.appendingPathComponent("build.sh").path
        return run("/bin/bash", [cmd], dir: src, timeout: 1200) { line in
            appendLog(line)
            if let m = line.firstMatch(of: #/^\[(\d+)/(\d+)\]/#), let a = Double(m.1), let b = Double(m.2), b > 0 {
                progress(nil, 0.08 + 0.85 * a / b)
            } else if line.hasPrefix("Signed") || line.hasPrefix("Creating a local signing") {
                progress("Signing…", 0.94)
            }
        }
    }

    // MARK: Restarting

    var restartWarning: String? { busyReason() }

    /// Quits, swaps in the new app (when it was built elsewhere) and opens it.
    func restart() {
        guard state == .ready else { return }
        let dest = Bundle.main.bundleURL.path
        let env = ProcessInfo.processInfo.environment
        let testOut = env["POINKY_UPDATE_TEST_OUT"] ?? ""
        // A small script that outlives Poinky: waits for it to quit, swaps the app, opens the new one.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if [ -n "$2" ] && [ -d "$2" ]; then rm -rf "$3" && mv "$2" "$3"; fi
        if [ -n "$4" ]; then open -n "$3" --args --update-relaunched "$4"; else open "$3"; fi
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script, "poinky-update", "\(ProcessInfo.processInfo.processIdentifier)", newApp?.path ?? "", dest, testOut]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            state = .failed("Couldn't restart: \(error.localizedDescription). Quit and open Poinky yourself.")
            return
        }
        Timeline.log("update.restart")
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    struct Failure: Error { let message: String; init(_ m: String) { message = m } }

    nonisolated static func git(_ dir: URL, _ args: [String], timeout: TimeInterval = 30) -> (ok: Bool, out: String) {
        run("/usr/bin/git", ["-C", dir.path] + args, timeout: timeout)
    }

    /// Runs a command with a time limit, collecting what it prints (each line also goes to `line`).
    nonisolated static func run(_ exe: String, _ args: [String], dir: URL? = nil, timeout: TimeInterval,
                                line: ((String) -> Void)? = nil) -> (ok: Bool, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"     // never wait for a password
        // Apps start with a bare PATH; build.sh needs swift, xcrun, python3, codesign.
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let buf = Buffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            let lines = buf.add(d)
            if let line { lines.forEach(line) }
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return (false, error.localizedDescription) }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 3)
            return (false, buf.text + "\n(gave up after \(Int(timeout)) s)")
        }
        // The last output can arrive just after the exit.
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        pipe.fileHandleForReading.readabilityHandler = nil
        _ = buf.add(rest)
        return (p.terminationStatus == 0, buf.text)
    }

    /// What a command printed so far, split into lines as it arrives.
    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), partial = Data()
        func add(_ d: Data) -> [String] {
            lock.lock(); defer { lock.unlock() }
            out.append(d); partial.append(d)
            var lines: [String] = []
            while let nl = partial.firstIndex(of: 0x0A) {
                lines.append(String(decoding: partial[partial.startIndex..<nl], as: UTF8.self))
                partial = Data(partial[(nl + 1)...])
            }
            return lines
        }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    }

    nonisolated static func lastLine(_ s: String) -> String {
        let l = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? "no details"
        return AppContext.clip(l, 160)
    }

    nonisolated private static func startLog(_ s: String) {
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "\(Date()) \(s)\n".write(to: log, atomically: true, encoding: .utf8)
    }
    nonisolated private static func appendLog(_ s: String) {
        guard let h = try? FileHandle(forWritingTo: log) else { return }
        h.seekToEndOfFile()
        h.write(Data((s + "\n").utf8))
        try? h.close()
    }

    // MARK: Tests

    /// `Poinky --update-test <out.txt>`: check, update, and (with POINKY_UPDATE_RESTART=1) restart, writing
    /// each state (POINKY_UPDATE_CHECK_ONLY=1: stop after checking). Use with POINKY_UPDATE_SOURCE, POINKY_UPDATE_MANAGED and POINKY_UPDATE_BUILD (see CLAUDE.md).
    func selfTest(out: String) {
        var lines: [String] = ["running \(Self.running.commit.prefix(7)) source \(Self.source?.path ?? "none")"]
        func write() { try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        var seen = ""
        let watch = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let s = "\(self.state) \(self.step) \(Int(self.progress * 100))%"
                if s != seen { seen = s; lines.append("state " + s); write() }
            }
        }
        check { [weak self] in
            guard let self else { return }
            lines.append("checked \(self.state), changes \(self.changes.count): " + self.changes.prefix(5).joined(separator: " | ")
                         + (self.rebuildNote.map { " rebuild: \($0)" } ?? ""))
            write()
            guard self.state == .available, ProcessInfo.processInfo.environment["POINKY_UPDATE_CHECK_ONLY"] != "1" else {
                watch.invalidate(); write(); NSApp.terminate(nil); return
            }
            self.update()
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { t in
                MainActor.assumeIsolated {
                    switch self.state {
                    case .ready:
                        t.invalidate(); watch.invalidate()
                        lines.append("staged \(self.newApp?.path ?? "in place")")
                        write()
                        if ProcessInfo.processInfo.environment["POINKY_UPDATE_RESTART"] == "1" { self.restart() } else { NSApp.terminate(nil) }
                    case .failed:
                        t.invalidate(); watch.invalidate(); write(); NSApp.terminate(nil)
                    default: break
                    }
                }
            }
        }
    }
}
