import AVFoundation

/// Local speech models that can write the final text of a question (Settings → Voice → Speech recognition),
/// installed by `stt/install.sh` into `<support>/stt`: the helper (`bin/poinky-stt`, built from `stt/`) and the
/// models (`models/<folder>`). Apple's engine always runs too (live words, hands-free pauses, other languages);
/// the local model's text replaces Apple's when it answers in time (`deadline`).
@MainActor
enum LocalModels {
    struct Info: Equatable {
        let id: String
        let label: String
        let folder: String
        let version: String
        /// Language prefixes it understands.
        let languages: [String]
        let megabytes: Int
    }

    /// Parakeet TDT 0.6B v2 (NVIDIA, CC-BY-4.0; Core ML conversion by FluidInference), English only. On this
    /// Mac's test set it made 4× fewer word errors than Apple's engine, in ~55 ms (tools/stt-test/README.md).
    static let known = [
        Info(id: "parakeet", label: "Parakeet", folder: "parakeet-tdt-0.6b-v2", version: "v2", languages: ["en"], megabytes: 465),
    ]

    /// How long a question may wait for the local model after you let go, before Apple's text goes instead.
    static var deadline: Double = 1.2

    static var root: URL {
        if let d = ProcessInfo.processInfo.environment["POINKY_STT_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return AppConfig.dir.appendingPathComponent("stt", isDirectory: true)
    }
    static var helper: URL { root.appendingPathComponent("bin/poinky-stt") }

    /// The models installed on this Mac (the helper is built and the model's files were checked).
    static var installed: [Info] {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: helper.path) else { return [] }
        return known.filter { fm.fileExists(atPath: root.appendingPathComponent("models/\($0.folder)/.verified").path) }
    }

    static func make(_ id: String) -> (any SpeechEngine)? {
        installed.first { $0.id == id }.map { LocalModelEngine(info: $0) }
    }

    /// The engine for a session: `choice` "apple" (none), "auto" (an installed model that understands the first
    /// language), or a model's id.
    static func engine(choice: String?, languages: [String]) -> (any SpeechEngine)? {
        let choice = choice ?? AppConfig.load().speechEngine
        guard choice != "apple" else { return nil }
        let first = String((languages.first ?? "en").prefix(2)).lowercased()
        let candidates = installed.filter { choice == "auto" || $0.id == choice }
        guard let info = candidates.first(where: { $0.languages.contains(first) }) else { return nil }
        return LocalModelEngine(info: info)
    }

    /// Does this engine understand that language ("en-US")?
    static func speaks(_ engine: any SpeechEngine, _ language: String?) -> Bool {
        guard let e = engine as? LocalModelEngine else { return false }
        return e.info.languages.contains(String((language ?? "en").prefix(2)).lowercased())
    }

    static func lastLanguage(_ engine: any SpeechEngine) -> String? { nil }
}

/// A local model behind the helper process (`poinky-stt`, JSON lines + raw float32 audio over stdin/stdout).
/// It keeps the question's audio (16 kHz mono) and transcribes it all when you let go; it can't stream words.
/// Never blocks: starting returns at once (the model loads in the background, ~0.4 s once it's been used), and
/// a question asked before it's ready, or one it doesn't answer, goes with Apple's text.
@MainActor
final class LocalModelEngine: SpeechEngine {
    let info: LocalModels.Info
    var name: String { info.label }
    var onResult: ((SpeechEngineResult) -> Void)?
    var onDied: (() -> Void)?

    private let audio = Audio16k()
    private var process: Process?
    private var stdin: FileHandle?
    private var ready = false
    private var nextID = 0
    private var waiting: [Int: CheckedContinuation<String?, Never>] = [:]
    private var lineBuffer = Data()
    /// For one-shot runs (the mic check): wait for the model before the first question.
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    init(info: LocalModels.Info) { self.info = info }

    func start(languages: [String]) async throws {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = LocalModels.helper
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.output(d) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited() } }
        }
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        let folder = LocalModels.root.appendingPathComponent("models/\(info.folder)").path
        write(["load": folder, "version": info.version])
    }

    /// Waits (at most `seconds`) for the model to be loaded.
    func waitReady(seconds: Double) async {
        guard !ready, process != nil else { return }
        let t = Task { @MainActor in
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in readyWaiters.append(c) }
        }
        _ = await SpeechDeadline.value(seconds: seconds, t)
    }

    private func write(_ o: [String: Any], then bytes: Data? = nil) {
        guard let stdin, var d = try? JSONSerialization.data(withJSONObject: o) else { return }
        d.append(0x0A)
        if let bytes { d.append(bytes) }
        do { try stdin.write(contentsOf: d) } catch { NSLog("Poinky: \(name) helper isn't listening: \(error.localizedDescription)") }
    }

    private func output(_ d: Data) {
        lineBuffer.append(d)
        while let i = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer[lineBuffer.startIndex..<i]
            lineBuffer = Data(lineBuffer[(i + 1)...])
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if o["ready"] != nil {
                ready = true
                Timeline.log("stt.local.ready", ["engine": name, "ms": o["ms"] as? Int ?? 0])
                for c in readyWaiters { c.resume() }
                readyWaiters = []
            } else if let id = o["id"] as? Int, let c = waiting.removeValue(forKey: id) {
                c.resume(returning: o["text"] as? String)
            } else if let e = o["error"] as? String {
                NSLog("Poinky: \(name): \(e)")
            }
        }
    }

    private func exited() {
        ready = false
        process = nil
        stdin = nil
        for (_, c) in waiting { c.resume(returning: nil) }
        waiting = [:]
        for c in readyWaiters { c.resume() }
        readyWaiters = []
    }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer, voiced: Bool) { audio.add(buffer, voiced: voiced) }

    func setContext(_ context: SpeechContext) {}

    func finish() async -> String? {
        let samples = audio.take()
        guard ready, process != nil, !samples.isEmpty else { return nil }
        nextID += 1
        let id = nextID
        let bytes = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                waiting[id] = c
                write(["id": id, "samples": samples.count], then: bytes)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiting.removeValue(forKey: id)?.resume(returning: nil) }
        }
    }

    func discard() { _ = audio.take() }

    func stop() {
        try? stdin?.close()
        stdin = nil
        let p = process
        process = nil
        ready = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p?.isRunning == true { p?.terminate() } }
        for (_, c) in waiting { c.resume(returning: nil) }
        waiting = [:]
        for c in readyWaiters { c.resume() }
        readyWaiters = []
    }
}

/// The question's audio at 16 kHz mono (channel 0), from a little before the mic first heard a voice, 30 s at most.
final class Audio16k: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var firstVoice: Int?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func add(_ b: AVAudioPCMBuffer, voiced: Bool) {
        lock.lock(); defer { lock.unlock() }
        if converter == nil || converter?.inputFormat != b.format {
            converter = AVAudioConverter(from: b.format, to: target)
            if b.format.channelCount > 1 { converter?.channelMap = [0] }
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
        guard let c = converter,
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(b.frameLength) * 16_000 / b.format.sampleRate + 64))
        else { return }
        var used = false
        c.convert(to: out, error: nil) { _, st in if used { st.pointee = .noDataNow; return nil }; used = true; st.pointee = .haveData; return b }
        if voiced, firstVoice == nil { firstVoice = samples.count }
        samples.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        if samples.count > 16_000 * 30 {
            let drop = samples.count - 16_000 * 30
            samples.removeFirst(drop)
            firstVoice = firstVoice.map { max(0, $0 - drop) }
        }
    }

    /// The audio so far (from 0.4 s before the first voice), and start over.
    func take() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let from = max(0, (firstVoice ?? 0) - 6_400)
        let out = Array(samples[min(from, samples.count)...])
        samples = []; firstVoice = nil
        return out
    }
}

/// Installs the local recognizer (`stt/install.sh`, bundled in the app) with progress, like the natural voice.
@MainActor
final class SpeechModelInstaller: ObservableObject {
    static let shared = SpeechModelInstaller()
    enum State: Equatable { case idle, running, failed(String), done }
    @Published private(set) var state = State.idle
    @Published private(set) var progress = 0.0
    @Published private(set) var step = ""
    private var process: Process?
    private var lastLines: [String] = []
    private var partial = Data()

    func start() {
        guard state != .running else { return }
        guard let script = Bundle.main.url(forResource: "install", withExtension: "sh", subdirectory: "stt") else {
            state = .failed("The installer is missing from the app. Re-run the Poinky installer.")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["POINKY_PROGRESS"] = "1"
        env["POINKY_STT_DIR"] = LocalModels.root.path
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.output(data) } }
        }
        p.terminationHandler = { [weak self] proc in
            let ok = proc.terminationStatus == 0
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(ok) } }
        }
        state = .running; progress = 0; step = "Starting…"; lastLines = []; partial = Data()
        do { try p.run(); process = p } catch { state = .failed(error.localizedDescription) }
    }

    private func output(_ data: Data) {
        partial.append(data)
        while let nl = partial.firstIndex(of: 0x0A) {
            let s = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            partial = Data(partial[(nl + 1)...])
            guard !s.isEmpty else { continue }
            if s.hasPrefix("@progress ") {
                let parts = s.dropFirst(10).split(separator: " ", maxSplits: 1)
                if let f = parts.first.flatMap({ Double($0) }) { progress = f }
                if parts.count > 1 { step = String(parts[1]) }
            } else { lastLines = Array((lastLines + [s]).suffix(4)) }
        }
    }

    private func finished(_ ok: Bool) {
        process = nil
        if ok, !LocalModels.installed.isEmpty { state = .done; progress = 1 }
        else {
            NSLog("Poinky: speech model install failed: \(lastLines.joined(separator: " | "))")
            state = .failed(lastLines.last { $0.hasPrefix("error") } ?? lastLines.last ?? "The install didn't finish.")
        }
    }
}
