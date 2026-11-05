import AppKit

/// A video explainer: made by `explainer/pipeline.py` (a storyboard, scenes written in parallel and
/// checked, a local voice), shown on screen as a helper while it cooks, then played in `VideoWindow`.
///
/// The pipeline publishes its progress in `<dir>/manifest.json` (scenes as they become playable, and a
/// forecast of when playback can start and run straight through); this polls it twice a second.
@MainActor
final class VideoJob {
    struct Sentence { let text: String; let start: Double; let end: Double }
    struct Scene { let id: String; let start: Double; let end: Double; let ready: Bool; var idea = ""; var sentences: [Int] = [] }
    enum Status: Equatable { case cooking, done, failed(String), cancelled }

    /// Where videos are kept (each in its own folder with its transcript), and the pipeline's measurements.
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Poinky/videos", isDirectory: true)

    let id: Int            // its helper's id on screen
    let name: String       // its helper's name
    let title: String
    let brief: String
    let dir: URL
    let startedAt = Date()
    private(set) var status: Status = .cooking
    private(set) var sentences: [Sentence] = []
    private(set) var scenes: [Scene] = []
    private(set) var duration: Double = 0
    private(set) var playAt: Date?
    private(set) var stage = "storyboard"
    private(set) var manifestJSON = ""      // the latest manifest, as text (for the player)
    private var lastStep = ""
    /// Something changed (progress, a scene, the forecast).
    var onChange: (() -> Void)?
    /// It ended: done, failed or cancelled.
    var onEnd: (() -> Void)?

    private var process: Process?
    private var input: Pipe?
    private var timer: Timer?
    private var lastData: Data?
    private var errorTail = ""

    init(id: Int, name: String, title: String, brief: String) {
        self.id = id
        self.name = name
        self.title = title
        self.brief = brief
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
            .replacingOccurrences(of: ":", with: "")
        let slug = title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(6).joined(separator: "-")
        dir = Self.root.appendingPathComponent("\(stamp)-\(slug.isEmpty ? "video" : slug)", isDirectory: true)
    }

    /// A video made earlier (its folder), to play again.
    init(existing dir: URL, id: Int, name: String) {
        self.id = id
        self.name = name
        self.dir = dir
        self.brief = ""
        let m = (try? Data(contentsOf: dir.appendingPathComponent("manifest.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        self.title = m?["title"] as? String ?? dir.lastPathComponent
        poll()
        if !scenes.isEmpty, scenes.allSatisfy(\.ready) { status = .done }
    }

    // MARK: - Running the pipeline

    func start(model: String) throws {
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("explainer"),
              FileManager.default.fileExists(atPath: res.appendingPathComponent("pipeline.py").path) else {
            throw NSError(domain: "Poinky", code: 1, userInfo: [NSLocalizedDescriptionKey: "The video maker isn't in this build."])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Tests: POINKY_VIDEO_CMD=tools/fake-video.py replays a finished video instead (no tokens).
        let script = ProcessInfo.processInfo.environment["POINKY_VIDEO_CMD"] ?? res.appendingPathComponent("pipeline.py").path
        p.arguments = [script, "--topic", brief, "--out", dir.path,
                       "--model", model, "--watch-stdin"]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env["EXPLAINER_HISTORY"] = Self.root.appendingPathComponent("history.json").path
        env["EXPLAINER_BUILD"] = Self.root.appendingPathComponent(".build").path
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let input = Pipe(), out = Pipe(), err = Pipe()
        p.standardInput = input
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }   // the end (or it would spin)
            guard let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.logged(s) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }   // the end (or it would spin)
            guard let s = String(data: d, encoding: .utf8) else { return }
            Task { @MainActor in self?.errorTail = String(((self?.errorTail ?? "") + s).suffix(1200)) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.exited(code) }
        }
        try p.run()
        process = p
        self.input = input
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        Self.log("cooking \"\(title)\" in \(dir.lastPathComponent)")
    }

    /// Stops it and everything it started (the pipeline leads its own process group and stops it all
    /// when its input closes).
    func cancel() {
        guard status == .cooking else { return }
        status = .cancelled
        Self.log("cancelled \"\(title)\"")
        try? input?.fileHandleForWriting.close()
        let p = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p?.isRunning == true { p?.terminate() } }
        timer?.invalidate()
        onEnd?()
    }

    private func exited(_ code: Int32) {
        poll()
        timer?.invalidate()
        timer = nil
        guard status == .cooking else { return }
        if code == 0, !scenes.isEmpty, scenes.allSatisfy(\.ready) {
            status = .done
            Self.log("made \"\(title)\" in \(Int(Date().timeIntervalSince(startedAt))) s")
        } else {
            let why = errorTail.split(separator: "\n").last.map(String.init) ?? "it stopped (code \(code))"
            status = .failed(why)
            Self.log("failed (code \(code)): \(errorTail.suffix(400))")
        }
        onChange?()
        onEnd?()
    }

    private func logged(_ text: String) {
        for line in text.split(separator: "\n") {
            let l = String(line)
            if l.contains("failed") || l.contains("error") { NSLog("Poinky: video: \(l)") }
        }
    }

    /// Video events, for checking what happened (`videos/poinky-video.log`).
    static func log(_ line: String) {
        let url = root.appendingPathComponent("poinky-video.log")
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
        let text = "[\(stamp)] \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close() }
        else { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }

    // MARK: - Progress

    private func poll() {
        let url = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url), data != lastData,
              let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lastData = data
        manifestJSON = String(data: data, encoding: .utf8) ?? ""
        stage = m["status"] as? String ?? stage
        duration = m["duration"] as? Double ?? duration
        if let ss = m["sentences"] as? [[String: Any]] {
            sentences = ss.compactMap { s in
                guard let t = s["text"] as? String, let a = s["start"] as? Double, let b = s["end"] as? Double else { return nil }
                return Sentence(text: t, start: a, end: b)
            }
        }
        let ideas = storyboardIdeas()
        if let sc = m["scenes"] as? [[String: Any]] {
            scenes = sc.compactMap { s in
                guard let id = s["id"] as? String, let a = s["start"] as? Double, let b = s["end"] as? Double else { return nil }
                var scene = Scene(id: id, start: a, end: b, ready: s["file"] != nil)
                if let i = ideas[id] { scene.idea = i.idea; scene.sentences = i.sentences }
                return scene
            }.sorted { $0.start < $1.start }
        }
        if let f = m["forecast"] as? [String: Any], let at = f["playAt"] as? Double { playAt = Date(timeIntervalSince1970: at) }
        onChange?()
    }

    private var ideasCache: [String: (idea: String, sentences: [Int])]?
    private func storyboardIdeas() -> [String: (idea: String, sentences: [Int])] {
        if let c = ideasCache { return c }
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("storyboard.json")),
              let b = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sc = b["scenes"] as? [[String: Any]] else { return [:] }
        var out: [String: (idea: String, sentences: [Int])] = [:]
        for s in sc { if let id = s["id"] as? String { out[id] = (s["idea"] as? String ?? "", s["sentences"] as? [Int] ?? []) } }
        ideasCache = out
        return out
    }

    /// Can it play from the start without stopping? (The first scene is ready and the forecast says the
    /// rest will arrive in time, or everything is ready.)
    var canStart: Bool {
        guard let first = scenes.first, first.ready, !sentences.isEmpty else { return false }
        if stage == "done" || status == .done { return scenes.allSatisfy(\.ready) }
        guard let playAt else { return false }
        return Date() >= playAt
    }

    /// The helper card's line: what it's doing right now.
    var stepLine: String {
        switch status {
        case .cancelled: return "Stopped"
        case .failed: return "Couldn't make the video"
        case .done: return "Video ready"
        case .cooking: break
        }
        if stage == "research" { return "Looking up the facts" }
        if sentences.isEmpty { return "Writing the story" }
        let ready = scenes.filter(\.ready).count
        if scenes.isEmpty || ready == 0 { return "Drawing the scenes" }
        if let playAt, stage != "done" {
            let s = Int(playAt.timeIntervalSinceNow.rounded(.up))
            if s > 1 { return "\(ready) of \(scenes.count) scenes ready · starts in \(s) s" }
        }
        return "\(ready) of \(scenes.count) scenes ready"
    }

    /// The card's to-do list: one line per scene.
    var checklist: [HelperTask] {
        scenes.enumerated().map { i, s in
            HelperTask(text: "Scene \(i + 1)", state: s.ready ? .done : (i == scenes.firstIndex { !$0.ready } ? .active : .pending))
        }
    }

    /// A step line only when it changed (the card types each new one out).
    func takeStep() -> String? {
        let s = stepLine
        guard s != lastStep else { return nil }
        // The countdown changes every second; only retype it every 5 s.
        if s.contains("starts in"), lastStep.contains("starts in"), lastStep.hasPrefix(s.components(separatedBy: " · ")[0]),
           let n = Int(s.split(separator: " ").dropLast().last ?? ""), n % 5 != 0 { return nil }
        lastStep = s
        return s
    }

    // MARK: - For the talker

    /// The sentence being spoken at `t` (or the last one before it).
    func sentenceIndex(at t: Double) -> Int? {
        guard !sentences.isEmpty else { return nil }
        return sentences.lastIndex { $0.start <= t + 0.05 } ?? 0
    }

    func scene(at t: Double) -> Scene? { scenes.last { $0.start <= t } ?? scenes.first }

    /// What the talker needs to answer questions about it: the transcript with times, and where you are.
    func context(at t: Double?, open: Bool) -> String {
        var lines: [String] = []
        let fmt = { (x: Double) in String(format: "%.1f", x) }
        if open, let t {
            lines.append("A video explainer you made is open full screen, PAUSED at \(fmt(t)) s of \(fmt(duration)) s: \"\(title)\".")
        } else {
            lines.append("The last video explainer you showed (\(CallController.ago(startedAt))): \"\(title)\", \(fmt(duration)) s.")
        }
        lines.append("Its narration (what was said, with times in seconds):")
        for (i, s) in sentences.enumerated() { lines.append("  [\(fmt(s.start))–\(fmt(s.end))] \(i + 1). \(s.text)") }
        // What it was based on: the facts checked on the web, with their sources.
        if let notes = try? String(contentsOf: dir.appendingPathComponent("research.md"), encoding: .utf8), !notes.isEmpty {
            lines.append("The facts it was based on (checked with a web search when it was made; cite the source if asked where a number comes from):")
            lines.append(notes.count > 3000 ? String(notes.prefix(3000)) + "…" : notes)
        }
        if open, let t {
            if let i = sentenceIndex(at: t) { lines.append("When the user paused, this was being said: \"\(sentences[i].text)\"") }
            if let sc = scene(at: t), !sc.idea.isEmpty { lines.append("The scene on screen is meant to show: \(sc.idea)") }
            lines.append("The screenshot shows the paused video frame. Answer their question about it briefly (you can mark the frame). "
                         + "Don't start another video for a question about this one. It stays paused; they press Space to continue.")
        }
        return lines.joined(separator: "\n")
    }
}
