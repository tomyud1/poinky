import AVFoundation

/// The free local neural voice. Keeps a small Python helper (kokoro_server.py) running that
/// holds the Kokoro model in memory and turns each sentence into audio in well under a second.
@MainActor
final class KokoroVoice {
    static var installDir: URL { AppConfig.dir.appendingPathComponent("kokoro", isDirectory: true) }
    static var python: URL { installDir.appendingPathComponent("venv/bin/python") }

    /// True when the helper's Python environment and model files are in place.
    static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: python.path)
            && fm.fileExists(atPath: installDir.appendingPathComponent("models/kokoro-v1.0.onnx").path)
            && fm.fileExists(atPath: installDir.appendingPathComponent("models/voices-v1.0.bin").path)
    }

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var header: [String: Any]?          // waiting for this many audio bytes
    private var pending: [Int: (AVAudioPCMBuffer?) -> Void] = [:]
    private var nextID = 0
    private(set) var ready = false

    var isRunning: Bool { process?.isRunning == true }

    func start() throws {
        if isRunning { return }
        guard Self.isInstalled else { throw BrainError("The local voice isn't installed.") }
        guard let script = Bundle.main.url(forResource: "kokoro_server", withExtension: "py") else {
            throw BrainError("kokoro_server.py is missing from the app.")
        }
        let p = Process()
        p.executableURL = Self.python
        p.arguments = ["-I", script.path, Self.installDir.path]   // -I: isolated, ignores stray files
        p.currentDirectoryURL = Self.installDir
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
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

    /// Turns `text` into audio. `done` gets nil if it failed (the caller falls back to Apple's voice).
    func synthesize(_ text: String, voice: String, speed: Double, done: @escaping (AVAudioPCMBuffer?) -> Void) {
        guard isRunning, let stdin else { done(nil); return }
        nextID += 1
        let id = nextID
        pending[id] = done
        let req: [String: Any] = ["id": id, "text": text, "voice": voice, "speed": speed]
        guard var line = try? JSONSerialization.data(withJSONObject: req) else { pending[id] = nil; done(nil); return }
        line.append(0x0A)
        do { try stdin.write(contentsOf: line) } catch { pending[id] = nil; done(nil) }
    }

    /// Requests not yet answered are dropped (e.g. you interrupted).
    func cancelPending() { failAll() }

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
                deliver(h, audio: Data(audio))
            } else {
                guard let nl = buffer.firstIndex(of: 0x0A) else { return }
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if obj["ready"] as? Bool == true { ready = true; continue }
                if ((obj["bytes"] as? Int) ?? 0) > 0 { header = obj } else { deliver(obj, audio: Data()) }
            }
        }
    }

    private func deliver(_ h: [String: Any], audio: Data) {
        guard let id = h["id"] as? Int, let done = pending.removeValue(forKey: id) else { return }
        let sr = (h["sr"] as? Double) ?? Double((h["sr"] as? Int) ?? 24_000)
        let frames = audio.count / 4
        guard frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = pcm.floatChannelData?[0] else { done(nil); return }
        audio.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float.self)
            for i in 0..<frames { dst[i] = src[i] }
        }
        pcm.frameLength = AVAudioFrameCount(frames)
        done(pcm)
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
        callbacks.forEach { $0(nil) }
    }
}
