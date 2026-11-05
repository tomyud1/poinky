import AVFoundation
import Darwin

/// The free local neural voice: Phonon 31m (Gradium, Apache 2.0). Keeps a small Python helper
/// (phonon_server.py, running Phonon's Rust engine) loaded, and streams each sentence back in
/// chunks as it's generated, so speech starts a few milliseconds after the text arrives.
@MainActor
final class PhononVoice {
    static var installDir: URL { AppConfig.dir.appendingPathComponent("phonon", isDirectory: true) }
    static var python: URL { installDir.appendingPathComponent("venv/bin/python") }
    static var modelDir: URL { installDir.appendingPathComponent("model", isDirectory: true) }
    /// The voice Poinky used before Phonon. Someone who had it gets Phonon installed automatically.
    static var oldKokoroDir: URL { AppConfig.dir.appendingPathComponent("kokoro", isDirectory: true) }

    nonisolated static let defaultVoice = "Easton"
    /// The installed voices (phonon/install.sh downloads exactly these), for Settings and the talker.
    nonisolated static let voices: [(label: String, name: String)] = [
        ("Easton · US male", "Easton"), ("Micah · US male", "Micah"), ("Trevor · US male", "Trevor"),
        ("Russell · US male", "Russell"), ("Preston · US male", "Preston"), ("Miles · US male", "Miles"),
        ("Zoey · US female", "Zoey"), ("Juniper · US female", "Juniper"), ("Everly · US female", "Everly"),
        ("Harper · US female", "Harper"), ("Hadley · US female", "Hadley"), ("Delia · US female", "Delia"),
        ("Alfie · UK male", "Alfie"), ("Hugh · UK male", "Hugh"), ("Edwin · UK male", "Edwin"),
        ("Spencer · UK male", "Spencer"), ("Toby · UK male", "Toby"), ("Teddy · UK male", "Teddy"),
        ("Maeve · UK female", "Maeve"), ("Freya · UK female", "Freya"), ("Pippa · UK female", "Pippa"),
        ("Elodie-Rose · UK female", "Elodie-Rose"), ("Imogen · UK female", "Imogen"),
        ("Lottie · UK female", "Lottie"), ("Bryony · UK female", "Bryony"),
    ]
    /// Speed (a multiplier) Phonon can do reliably; the helper maps it onto its duration condition.
    nonisolated static let speedRange = 0.86...1.24

    /// The voice name as the helper knows it, from any spelling ("easton" → "Easton").
    nonisolated static func voiceName(_ s: String) -> String? {
        voices.first { $0.name.caseInsensitiveCompare(s.trimmingCharacters(in: .whitespaces)) == .orderedSame }?.name
    }

    /// True when the helper's Python environment and model files are in place.
    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: python.path)
            && ["model.q8.gguf", "config.json", "tokenizer.json"].allSatisfy {
                fm.fileExists(atPath: modelDir.appendingPathComponent($0).path)
            }
            && fm.fileExists(atPath: installDir.appendingPathComponent("installed.json").path)
    }

    /// Performance cores, at most 4: Phonon is slower when it also spreads onto efficiency cores.
    static var threads: Int {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) != 0 || n <= 0 {
            n = Int32(ProcessInfo.processInfo.activeProcessorCount / 2)
        }
        return max(2, min(4, Int(n)))
    }

    nonisolated static let sampleRate = 24_000.0
    nonisolated private static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    private struct Request {
        let onChunk: (AVAudioPCMBuffer) -> Void
        let onEnd: (Bool) -> Void
    }

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var header: [String: Any]?          // waiting for this many audio bytes
    private var pending: [Int: Request] = [:]
    private var nextID = 0
    private(set) var ready = false

    var isRunning: Bool { process?.isRunning == true }

    func start() throws {
        if isRunning { return }
        guard Self.isInstalled else { throw BrainError("The local voice isn't installed.") }
        guard let script = Bundle.main.url(forResource: "phonon_server", withExtension: "py") else {
            throw BrainError("phonon_server.py is missing from the app.")
        }
        let p = Process()
        p.executableURL = Self.python
        p.arguments = ["-I", script.path, Self.modelDir.path, String(Self.threads)]   // -I: isolated, ignores stray files
        p.currentDirectoryURL = Self.installDir
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_OFFLINE"] = "1"
        p.environment = env
        p.qualityOfService = .userInteractive   // keeps it on the performance cores, even when Poinky is in the background
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ingest(data) } }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(p) } }
        }
        buffer.removeAll()
        header = nil
        ready = false
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
    }

    func stop() {
        try? stdin?.close()
        stdin = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        failAll()
    }

    /// Speaks `text`: `onChunk` gets the audio as it's generated (24 kHz mono), then `onEnd(true)`.
    /// `onEnd(false)` means it failed (the caller falls back to Apple's voice). Requests are
    /// answered in order; the helper starts on the next one as soon as this one is generated.
    @discardableResult
    func speak(_ text: String, voice: String, speed: Double,
               onChunk: @escaping (AVAudioPCMBuffer) -> Void, onEnd: @escaping (Bool) -> Void) -> Int {
        guard isRunning, let stdin else { onEnd(false); return 0 }
        nextID += 1
        let id = nextID
        pending[id] = Request(onChunk: onChunk, onEnd: onEnd)
        let req: [String: Any] = ["id": id, "text": text, "voice": voice,
                                  "speed": min(Self.speedRange.upperBound, max(Self.speedRange.lowerBound, speed))]
        guard var line = try? JSONSerialization.data(withJSONObject: req) else { pending[id] = nil; onEnd(false); return 0 }
        line.append(0x0A)
        do { try stdin.write(contentsOf: line) } catch { pending[id] = nil; onEnd(false) }
        return id
    }

    /// The whole sentence as one buffer (for the Settings preview).
    func synthesize(_ text: String, voice: String, speed: Double, done: @escaping (AVAudioPCMBuffer?) -> Void) {
        var chunks: [AVAudioPCMBuffer] = []
        speak(text, voice: voice, speed: speed, onChunk: { chunks.append($0) }) { ok in
            guard ok else { done(nil); return }
            let total = chunks.reduce(0) { $0 + Int($1.frameLength) }
            guard total > 0, let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(total)),
                  let dst = out.floatChannelData?[0] else { done(nil); return }
            var at = 0
            for c in chunks {
                guard let src = c.floatChannelData?[0] else { continue }
                dst.advanced(by: at).update(from: src, count: Int(c.frameLength))
                at += Int(c.frameLength)
            }
            out.frameLength = AVAudioFrameCount(total)
            done(out)
        }
    }

    /// Stops everything asked for so far (you interrupted): the helper drops it mid-sentence
    /// and is free for the next answer right away. Callbacks for it are not called.
    func cancelPending() {
        guard nextID > 0 else { return }
        pending.removeAll()
        if isRunning, let stdin, var line = try? JSONSerialization.data(withJSONObject: ["cancel": nextID]) {
            line.append(0x0A)
            try? stdin.write(contentsOf: line)
        }
    }

    // MARK: - Reading the helper's output

    private func ingest(_ data: Data) {
        buffer.append(data)
        while true {
            if let h = header {
                let need = (h["bytes"] as? Int) ?? 0
                guard buffer.count >= need else { return }
                let audio = buffer.prefix(need)
                buffer = Data(buffer.dropFirst(need))
                header = nil
                chunk(h, audio: Data(audio))
            } else {
                guard let nl = buffer.firstIndex(of: 0x0A) else { return }
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if obj["ready"] as? Bool == true { ready = true; continue }
                if ((obj["bytes"] as? Int) ?? 0) > 0 { header = obj; continue }
                guard let id = obj["id"] as? Int, let req = pending.removeValue(forKey: id) else { continue }
                if let err = obj["error"] as? String { NSLog("Poinky: voice error: \(err)") }
                req.onEnd(obj["end"] as? Bool == true)
            }
        }
    }

    private func chunk(_ h: [String: Any], audio: Data) {
        guard let id = h["id"] as? Int, let req = pending[id] else { return }
        let frames = audio.count / 4
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = pcm.floatChannelData?[0] else { return }
        audio.withUnsafeBytes { raw in
            dst.update(from: raw.bindMemory(to: Float.self).baseAddress!, count: frames)
        }
        pcm.frameLength = AVAudioFrameCount(frames)
        req.onChunk(pcm)
    }

    private func ended(_ p: Process) {
        guard p === process else { return }
        process = nil
        stdin = nil
        ready = false
        failAll()
    }

    private func failAll() {
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { $0.onEnd(false) }
    }
}

/// Runs phonon/install.sh (bundled in the app) in the background, for Settings → Voice → Install
/// and for people updating from the old Kokoro voice. Progress comes from its "@progress" lines.
@MainActor
final class PhononInstaller: ObservableObject {
    static let shared = PhononInstaller()

    enum State: Equatable { case idle, running, failed(String), done }
    @Published private(set) var state = State.idle
    @Published private(set) var progress = 0.0
    @Published private(set) var step = ""
    /// Called on the main thread once the voice is installed and tested.
    var onInstalled: (() -> Void)?

    private var process: Process?
    private var lastLines: [String] = []

    var isRunning: Bool { state == .running }

    func start() {
        guard state != .running else { return }
        guard let script = Bundle.main.url(forResource: "install", withExtension: "sh", subdirectory: "phonon") else {
            state = .failed("The installer is missing from the app. Re-run the Poinky installer.")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["POINKY_PROGRESS"] = "1"
        // Apps start with a bare PATH; add the usual places for uv and Homebrew.
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
        state = .running
        progress = 0
        step = "Starting…"
        lastLines = []
        partial = Data()
        do {
            try p.run()
            process = p
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private var partial = Data()

    private func output(_ data: Data) {
        partial.append(data)
        while let nl = partial.firstIndex(of: 0x0A) {
            line(String(decoding: partial[partial.startIndex..<nl], as: UTF8.self))
            partial = Data(partial[(nl + 1)...])
        }
    }

    private func line(_ raw: String) {
        // Strip terminal colors.
        let s = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        if s.hasPrefix("@progress ") {
            let parts = s.dropFirst(10).split(separator: " ", maxSplits: 1)
            if let f = parts.first.flatMap({ Double($0) }) { progress = f }
            if parts.count > 1 { step = String(parts[1]) }
            return
        }
        lastLines = Array((lastLines + [s]).suffix(4))
    }

    private func finished(_ ok: Bool) {
        process = nil
        if ok && PhononVoice.isInstalled {
            state = .done
            progress = 1
            onInstalled?()
        } else {
            let why = lastLines.last { !$0.hasPrefix("Downloading") && !$0.hasPrefix("Setting up") } ?? "The install didn't finish."
            NSLog("Poinky: voice install failed: \(lastLines.joined(separator: " | "))")
            state = .failed(why)
        }
    }
}
