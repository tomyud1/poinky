import AVFoundation
import Speech

// The speech test bench (tools/stt-test/run.sh builds it with the app's SpeechListener and engines).
//
//   bench render <clean.jsonl> <out-dir> [conditions]   makes each condition's audio from the clean clips
//   bench run <manifest.jsonl> <out.jsonl> [--engine apple|parakeet|whisper|hybrid] [--locale en-US] [--context]
//             [--pace 4] [--languages en-US,he-IL]
//
// `run` plays each clip into the real SpeechListener the way a hold does (clear, a moment of room, the words, the
// 0.18 s the app keeps the mic open after you let go, finishUtterance) through AudioIO's MicRelay, at `pace` times
// real time (1 = real time, for timings). Each result line has the text sent and how long the final text took after
// the audio ended. `--context` gives the engine the sentence's own terms plus distractors, the way the app gives it
// the words on screen.

enum Timeline { static func log(_ ev: String, _ fields: [String: Any] = [:]) {} }
enum Earcons { static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)! }
struct AppConfig {   // the bits of the app's settings the listener reads
    var language = "en-US"; var otherLanguages: [String]? = nil
    var speechEngine = ProcessInfo.processInfo.environment["POINKY_STT_ENGINE"] ?? "auto"
    static var dir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["POINKY_SUPPORT_DIR"] ?? NSTemporaryDirectory()) }
    static func load() -> AppConfig { AppConfig() }
}
struct BrainError: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }

let args = CommandLine.arguments
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
func flag(_ name: String) -> Bool { args.contains(name) }
func readJSONL(_ path: String) -> [[String: Any]] {
    (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").compactMap {
        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    } ?? []
}
func writeLine(_ h: FileHandle, _ o: [String: Any]) {
    h.write((try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) + Data("\n".utf8))
}
func load(_ path: String) -> [Float] {
    let f = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
    let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try! f.read(into: b)
    return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
}
let rate = 48_000.0
let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
func save(_ s: [Float], _ path: String) {
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.count))!
    b.frameLength = AVAudioFrameCount(s.count)
    s.withUnsafeBufferPointer { memcpy(b.floatChannelData![0], $0.baseAddress!, s.count * 4) }
    let f = try! AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: fmt.settings)
    try! f.write(from: b)
}

// MARK: Conditions

struct RNG { var s: UInt64; mutating func next() -> Float { s = s &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: s) >> 11) / Float(1 << 52) } }
func white(_ n: Int, _ r: inout RNG) -> [Float] { (0..<n).map { _ in r.next() } }
func pink(_ n: Int, _ r: inout RNG) -> [Float] {   // Paul Kellet's filter
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    return (0..<n).map { _ in
        let w = r.next()
        b0 = 0.99886 * b0 + w * 0.0555179; b1 = 0.99332 * b1 + w * 0.0750759; b2 = 0.96900 * b2 + w * 0.1538520
        b3 = 0.86650 * b3 + w * 0.3104856; b4 = 0.55000 * b4 + w * 0.5329522; b5 = -0.7616 * b5 - w * 0.0168980
        let o = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362; b6 = w * 0.115926
        return o
    }
}
func fan(_ n: Int, _ r: inout RNG) -> [Float] {    // brown rumble + a little broadband hiss + a 110 Hz hum
    var last: Float = 0
    let p = pink(n, &r)
    return (0..<n).map { i in
        last = 0.995 * last + 0.06 * r.next()
        return last * 4 + p[i] * 0.15 + 0.05 * sin(2 * .pi * 110 * Float(i) / Float(rate))
    }
}
func keys(_ n: Int, _ r: inout RNG) -> [Float] {   // key clicks every 90–260 ms
    var out = [Float](repeating: 0, count: n)
    var at = Int(abs(r.next()) * 0.1 * Float(rate))
    while at < n {
        let amp = 0.4 + abs(r.next()) * 0.6, len = Int(0.012 * rate), f = 2500 + abs(r.next()) * 2500
        for j in 0..<len where at + j < n {
            let t = Float(j) / Float(rate)
            out[at + j] += amp * exp(-t * 400) * (0.6 * sin(2 * .pi * f * t) + 0.4 * r.next())
        }
        at += Int((0.09 + abs(r.next()) * 0.17) * Float(rate))
    }
    return out
}
func scaled(_ s: [Float], toDB target: Float, by measure: ([Float]) -> Float) -> [Float] {
    let now = measure(s)
    let g = pow(10, (target - now) / 20)
    return s.map { $0 * g }
}
func speechDB(_ s: [Float]) -> Float { AudioLevels.measure(s, rate: rate).speech }
func rmsDB(_ s: [Float]) -> Float { AudioLevels.measure(s, rate: rate).rms }

/// name → (speech level dBFS, noise kind, SNR dB)
let conditions: [String: (Float, String, Float)] = [
    "clean": (-26, "room", 50), "soft38": (-38, "room", 34), "soft50": (-50, "room", 22), "soft60": (-60, "room", 12),
    "fan15": (-26, "fan", 15), "fan5": (-26, "fan", 5), "room10": (-26, "pink", 10), "room3": (-26, "pink", 3),
    "keys10": (-26, "keys", 10), "babble10": (-26, "babble", 10), "babble5": (-26, "babble", 5),
    "softfan": (-46, "fan", 10),
]

func render() {
    let clean = readJSONL(args[2]), out = args[3]
    let wanted = args.count > 4 && !args[4].hasPrefix("-") ? args[4].split(separator: ",").map(String.init) : Array(conditions.keys).sorted()
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let h = FileHandle(forWritingAtPath: { FileManager.default.createFile(atPath: out + "/manifest.jsonl", contents: nil); return out + "/manifest.jsonl" }())!
    let voicesFor = flag("--all-voices")
    for cond in wanted {
        guard let (level, kind, snr) = conditions[cond] else { print("no condition \(cond)"); continue }
        try? FileManager.default.createDirectory(atPath: out + "/" + cond, withIntermediateDirectories: true)
        var r = RNG(s: 42)
        for (i, c) in clean.enumerated() {
            // Every accent for clean audio; the noise and loudness conditions use the US voice, the Hebrew-accent
            // stand-in and the Hebrew clips (or every voice with --all-voices).
            let voice = c["voice"] as! String
            if cond != "clean", !voicesFor, !["us", "il", "he"].contains(voice) { continue }
            var s = load(c["wav"] as! String)
            s = [Float](repeating: 0, count: Int(0.3 * rate)) + s + [Float](repeating: 0, count: Int(0.18 * rate))
            s = scaled(s, toDB: level, by: speechDB)
            var noise: [Float]
            switch kind {
            case "fan": noise = fan(s.count, &r)
            case "pink": noise = pink(s.count, &r)
            case "keys": noise = keys(s.count, &r)
            case "babble":
                noise = [Float](repeating: 0, count: s.count)
                for k in 1...3 {
                    let other = load(clean[(i + k * 7) % clean.count]["wav"] as! String)
                    for j in 0..<s.count { noise[j] += other[(j + k * 9000) % other.count] }
                }
            default: noise = pink(s.count, &r)
            }
            // The room is never digital silence: a mic's own hiss sits near -72 dBFS.
            let floor = scaled(white(s.count, &r), toDB: -72, by: rmsDB)
            if kind != "room" { noise = scaled(noise, toDB: level - snr, by: rmsDB) } else { noise = [Float](repeating: 0, count: s.count) }
            for j in 0..<s.count { s[j] += noise[j] + floor[j] }
            let path = "\(out)/\(cond)/\(c["id"] as! String).wav"
            save(s, path)
            var m = c; m["wav"] = path; m["cond"] = cond; m["key"] = "\(cond)/\(c["id"] as! String)"
            writeLine(h, m)
        }
        print("rendered \(cond)")
    }
}

// MARK: Running clips through the listener

/// Distractors for --context: terms of other sentences, names, and words that might be on screen.
let distractors = ["Poinky", "Mint", "Coral", "Violet", "Amber", "Rose", "Sky", "Bernoulli", "Reynolds", "Navier-Stokes",
                   "hydrostatic", "viscosity", "SpeechListener", "AudioIO", "finishUtterance", "regex", "laminar", "inviscid"]

@MainActor
func runClips() async {
    let items = readJSONL(args[2]), outPath = args[3]
    FileManager.default.createFile(atPath: outPath, contents: nil)
    let h = FileHandle(forWritingAtPath: outPath)!
    let pace = Double(opt("--pace") ?? "4")!
    let audio = AudioIO()
    let listener = SpeechListener()
    listener.autoEnd = false
    let langs = (opt("--languages") ?? opt("--locale") ?? "en-US").split(separator: ",").map(String.init)
    if let e = opt("--engine") { listener.engineChoice = e }
    do { try await listener.start(audio: audio, languages: langs) } catch { print("FAIL couldn't start: \(error)"); exit(1) }
    try? await Task.sleep(nanoseconds: 500_000_000)
    print("engine: \(listener.engineDescription)")
    for (k, it) in items.enumerated() {
        let s = load(it["wav"] as! String)
        if flag("--context") {
            let terms = (it["terms"] as? [String] ?? [])
            listener.setContext(SpeechContext(words: terms + distractors, recent: []))
        }
        listener.clearText()
        // Play it in 1024-frame pieces like the input tap.
        let tStart = ProcessInfo.processInfo.systemUptime
        var off = 0
        while off < s.count {
            let n = min(1024, s.count - off)
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
            b.frameLength = AVAudioFrameCount(n)
            s.withUnsafeBufferPointer { memcpy(b.floatChannelData![0], $0.baseAddress! + off, n * 4) }
            audio.micRelay.deliver(b)
            off += n
            let due = tStart + Double(off) / rate / pace
            let wait = due - ProcessInfo.processInfo.systemUptime
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        }
        let ended = ProcessInfo.processInfo.systemUptime
        let r = await listener.finishDetailed()
        let ms = (ProcessInfo.processInfo.systemUptime - ended) * 1000
        var o: [String: Any] = ["key": it["key"] ?? it["id"]!, "hyp": r.text, "ms": ms, "engine": r.engine]
        if let a = r.apple { o["apple"] = a }
        if let l = r.language { o["lang"] = l }
        if let x = r.engineMs { o["engineMs"] = x }
        writeLine(h, o)
        if k % 25 == 0 { print("\(k)/\(items.count) \(it["key"] ?? "") → \(r.text) (\(Int(ms)) ms)") }
        try? await Task.sleep(nanoseconds: UInt64(0.15e9 / pace))
    }
    listener.stop()
    print("wrote \(outPath)")
}

@MainActor
func main() async {
    switch args.count > 1 ? args[1] : "" {
    case "render": render()
    case "run": await runClips()
    default: print("bench render|run …"); exit(2)
    }
    exit(0)
}
Task { @MainActor in await main() }
RunLoop.main.run()
