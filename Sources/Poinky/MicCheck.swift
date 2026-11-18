import AppKit
import AVFoundation
import SwiftUI

/// One engine that can hear a recording (for the check, and for comparing engines).
struct MicCheckEngine: Identifiable, Hashable {
    let id: String      // "apple", "parakeet", "whisper"
    let label: String
}

@MainActor
final class MicCheckModel: ObservableObject {
    enum Phase: Equatable { case intro, recording, waiting, analyzing, done }
    struct Heard: Codable { var engine: String; var text: String; var errors: Int; var ms: Int }
    struct Take: Codable {
        var sentence: Int
        var written: String
        var language: String
        var levels: AudioLevels
        var heard: [Heard]
    }

    @Published var phase = Phase.intro
    @Published var index = 0                     // the sentence being read
    @Published var level: Float = 0              // live meter while recording, 0…1
    @Published var takes: [Take] = []
    @Published var verdict: [String] = []
    @Published var savedFolder: URL?
    @Published var recordingsDeleted = false
    @Published var status = ""
    var engines: [MicCheckEngine] = []

    private var recorder: MicCheckRecorder?
    private var recordings: [Int: [Float]] = [:]   // 16 kHz mono
    private let fakeDir = ProcessInfo.processInfo.environment["POINKY_MIC_CHECK_WAVS"]

    var sentence: MicCheck.Sentence { MicCheck.sentences[min(index, MicCheck.sentences.count - 1)] }

    func begin() {
        engines = [MicCheckEngine(id: "apple", label: "Apple")] + LocalModels.installed.map { MicCheckEngine(id: $0.id, label: $0.label) }
        takes = []; verdict = []; recordings = [:]; index = 0; savedFolder = nil; recordingsDeleted = false
        if fakeDir != nil { Task { await runFake() }; return }
        phase = .waiting
    }

    /// Start recording the current sentence (the button, or Space).
    func record() {
        guard phase == .waiting else { return }
        let r = MicCheckRecorder()
        r.onLevel = { [weak self] l in self?.level = l }
        r.onDone = { [weak self] samples in self?.recorded(samples) }
        do { try r.start(); recorder = r; phase = .recording } catch {
            status = "Couldn't open the microphone: \(error.localizedDescription)"
        }
    }

    func stopRecording() { recorder?.stop() }

    private func recorded(_ samples: [Float]) {
        recorder = nil
        recordings[sentence.id] = samples
        if index + 1 < MicCheck.sentences.count { index += 1; phase = .waiting }
        else { Task { await analyze() } }
    }

    func redoLast() {
        guard phase == .waiting, index > 0 else { return }
        index -= 1
    }

    private func runFake() async {
        guard let dir = fakeDir else { return }
        for s in MicCheck.sentences {
            if let samples = MicCheckRecorder.load16k(URL(fileURLWithPath: dir).appendingPathComponent("\(s.id).wav")) {
                recordings[s.id] = samples
            }
        }
        index = MicCheck.sentences.count - 1
        await analyze()
    }

    private func analyze() async {
        phase = .analyzing
        var out: [Take] = []
        for s in MicCheck.sentences {
            guard let audio = recordings[s.id] else { continue }
            status = "Listening to sentence \(s.id) of \(MicCheck.sentences.count)…"
            let lang = s.language == "he" ? "he-IL" : "en-US"
            var heard: [MicCheckModel.Heard] = []
            for e in engines {
                let t0 = ProcessInfo.processInfo.systemUptime
                let text = await SpeechRun.transcribe(engineID: e.id, samples: audio, rate: 16_000, language: lang) ?? "(can't hear \(s.language == "he" ? "Hebrew" : "English"))"
                let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
                heard.append(Heard(engine: e.label, text: text, errors: MicCheck.errors(s.text, text), ms: ms))
            }
            out.append(Take(sentence: s.id, written: s.text, language: s.language,
                            levels: AudioLevels.measure(audio, rate: 16_000), heard: heard))
            takes = out
        }
        verdict = Self.verdict(out)
        status = ""
        save()
        phase = .done
    }

    /// Plain words about the level and the engines.
    static func verdict(_ takes: [Take]) -> [String] {
        guard !takes.isEmpty else { return ["Nothing was recorded."] }
        var lines: [String] = []
        let normal = takes.filter { t in MicCheck.sentences.first(where: { $0.id == t.sentence })?.soft != true }
        let speech = normal.map(\.levels.speech).sorted()
        let median = speech.isEmpty ? -120 : speech[speech.count / 2]
        let room = takes.map(\.levels.floor).sorted()[takes.count / 2]
        let peak = takes.map(\.levels.peak).max() ?? -120
        if median < -50 {
            lines.append(String(format: "Your mic level is very low (your voice arrives at %.0f dBFS; clear speech is around −35 to −15). Raise Input volume in System Settings → Sound → Input, or pick a closer mic.", median))
        } else if median < -40 {
            lines.append(String(format: "Your mic level is low (your voice arrives at %.0f dBFS; clear speech is around −35 to −15). Poinky boosts it, but raising Input volume in System Settings → Sound → Input helps.", median))
        } else {
            lines.append(String(format: "Your mic level is fine (your voice arrives at %.0f dBFS).", median))
        }
        if peak > -1 { lines.append("Some words were so loud they clipped: lower Input volume a little.") }
        if room > -50 { lines.append(String(format: "The room is noisy for the mic (%.0f dBFS between words): a fan, music or a laptop fan close by makes words harder to hear.", room)) }
        if median - room < 15 { lines.append(String(format: "Your voice is only %.0f dB above the room: move closer to the mic, or try AirPods.", median - room)) }
        // Engines: how many sentences each got right (no word wrong), English and Hebrew apart.
        let names = takes.first?.heard.map(\.engine) ?? []
        var scores: [(String, Int, Int)] = []
        for n in names {
            let right = takes.filter { t in t.heard.first { $0.engine == n }?.errors == 0 }.count
            let close = takes.filter { t in (t.heard.first { $0.engine == n }?.errors ?? 99) <= 1 }.count
            scores.append((n, right, close))
        }
        let sentence = scores.map { "\($0.0) got \($0.1) of \(takes.count) exactly right (\($0.2) with at most one word wrong)" }
        if !sentence.isEmpty { lines.append(sentence.joined(separator: "; ") + ".") }
        if let best = scores.max(by: { ($0.1, $0.2) < ($1.1, $1.2) }), scores.count > 1, best.1 > (scores.map(\.1).min() ?? 0) {
            lines.append("\(best.0) heard you best: choose it in Settings → Voice → Speech recognition.")
        }
        let hebrew = takes.filter { $0.language == "he" }
        if !hebrew.isEmpty, hebrew.allSatisfy({ t in t.heard.allSatisfy { $0.errors >= MicCheck.words(t.written).count } }) {
            lines.append("No engine understood the Hebrew sentences: add Hebrew in Settings → Voice → Languages I speak (Apple downloads its Hebrew model once).")
        }
        if let soft = takes.first(where: { t in MicCheck.sentences.first { $0.id == t.sentence }?.soft == true }),
           soft.heard.allSatisfy({ $0.errors > 0 }), normal.contains(where: { $0.heard.contains { $0.errors == 0 } }) {
            lines.append(String(format: "Soft speech is where it fails (that sentence arrived at %.0f dBFS).", soft.levels.speech))
        }
        return lines
    }

    private func save() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = MicCheck.folder.appendingPathComponent(stamp, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "device": InputDevice.name, "inputVolume": InputDevice.volume.map { Double($0) } ?? NSNull(),
            "verdict": verdict, "engines": engines.map(\.label),
            "takes": takes.map { t in
                ["sentence": t.sentence, "written": t.written, "language": t.language,
                 "levels": ["speech": Double(t.levels.speech), "peak": Double(t.levels.peak), "floor": Double(t.levels.floor), "seconds": t.levels.seconds],
                 "heard": t.heard.map { ["engine": $0.engine, "text": $0.text, "errors": $0.errors, "ms": $0.ms] }] as [String: Any]
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("results.json"))
        }
        for (id, samples) in recordings { MicCheckRecorder.save16k(samples, to: dir.appendingPathComponent("\(id).wav")) }
        savedFolder = dir
    }

    func deleteRecordings() {
        guard let dir = savedFolder else { return }
        for s in MicCheck.sentences { try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(s.id).wav")) }
        recordingsDeleted = true
    }
}

/// Records one sentence from the plain mic (as a hold does): stops 1.2 s after you stop talking, or at 12 s.
@MainActor
final class MicCheckRecorder {
    var onLevel: ((Float) -> Void)?
    var onDone: (([Float]) -> Void)?
    private var engine: AVAudioEngine?
    private let voice = VoiceActivity()
    private let store = SampleStore()
    private var timer: Timer?
    private var started = 0.0
    private var heardVoice = false

    final class SampleStore: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []
        private var converter: AVAudioConverter?
        private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        func add(_ b: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            if converter == nil || converter?.inputFormat != b.format {
                converter = AVAudioConverter(from: b.format, to: target)
                if b.format.channelCount > 1 { converter?.channelMap = [0] }
            }
            guard let c = converter, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(b.frameLength) * 16_000 / b.format.sampleRate + 64)) else { return }
            var used = false
            c.convert(to: out, error: nil) { _, st in if used { st.pointee = .noDataNow; return nil }; used = true; st.pointee = .haveData; return b }
            samples.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        }
        var all: [Float] { lock.lock(); defer { lock.unlock() }; return samples }
    }

    func start() throws {
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw BrainError("No microphone input found.") }
        let store = self.store, voice = self.voice
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { b, _ in
            store.add(b)
            voice.process(b)
        }
        e.prepare()
        try e.start()
        engine = e
        started = ProcessInfo.processInfo.systemUptime
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        onLevel?(voice.level)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if let quiet = voice.secondsSinceVoice, quiet < elapsed - 0.3 { heardVoice = true }
        if heardVoice, let quiet = voice.secondsSinceVoice, quiet > 1.2 { stop() }
        if elapsed > 12 { stop() }
    }

    func stop() {
        guard let e = engine else { return }
        timer?.invalidate(); timer = nil
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        engine = nil
        onDone?(store.all)
    }

    static func load16k(_ url: URL) -> [Float]? {
        guard let f = try? AVAudioFile(forReading: url),
              let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
              (try? f.read(into: b)) != nil else { return nil }
        let s = SampleStore()
        s.add(b)
        return s.all
    }

    static func save16k(_ samples: [Float], to url: URL) {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { memcpy(b.floatChannelData![0], $0.baseAddress!, samples.count * 4) }
        if let f = try? AVAudioFile(forWriting: url, settings: fmt.settings) { try? f.write(from: b) }
    }
}

@MainActor
final class MicCheckWindow {
    static let shared = MicCheckWindow()
    let model = MicCheckModel()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: MicCheckView(m: model)))
            w.title = "Check My Microphone"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(CGSize(width: 680, height: 640))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        if model.phase == .done || model.phase == .intro { model.phase = .intro }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Developer check (`--mic-check-shot <out.png>`, with `POINKY_MIC_CHECK_WAVS=<dir>` of 1.wav … 8.wav):
    /// runs the check on those recordings through every installed engine, saves a picture of the results, quits.
    static func snapshot(to out: String) {
        let m = MicCheckModel()
        let host = NSHostingView(rootView: MicCheckView(m: m).frame(width: 680, height: 900))
        let w = NSWindow(contentRect: CGRect(x: -3000, y: 0, width: 680, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.orderFrontRegardless()
        m.begin()
        func shoot(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if (m.phase != .done && m.phase != .waiting) && tries < 240 { shoot(tries + 1); return }
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                if let dir = m.savedFolder { print("mic check results: \(dir.path)/results.json") }
                NSApp.terminate(nil)
            }
        }
        shoot(0)
    }
}

struct MicCheckView: View {
    @ObservedObject var m: MicCheckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch m.phase {
            case .intro: intro
            case .waiting, .recording: reading
            case .analyzing, .done: results
            }
        }
        .padding(22)
        .frame(minWidth: 600, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check my microphone").font(.title2.bold())
            Text("You'll read \(MicCheck.sentences.count) short sentences, one at a time (about two minutes). Each is recorded the way a question is when you hold the keys, then every speech engine on this Mac listens to it, and you see what each one heard.")
                .foregroundStyle(.secondary)
            Text("Speak as you normally would, from where you usually sit. One sentence asks you to speak softly on purpose; two are in Hebrew.")
                .foregroundStyle(.secondary)
            Label("The recordings stay on this Mac (in Poinky's settings folder), and you can delete them at the end.", systemImage: "lock")
                .font(.callout).foregroundStyle(.secondary)
            Spacer().frame(height: 6)
            Button("Start") { m.begin() }.keyboardShortcut(.defaultAction).controlSize(.large)
        }
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sentence \(m.index + 1) of \(MicCheck.sentences.count)").font(.caption).foregroundStyle(.secondary)
            Text(m.sentence.hint).font(.headline)
            Text(m.sentence.text)
                .font(.system(size: 26, weight: .medium))
                .environment(\.layoutDirection, m.sentence.language == "he" ? .rightToLeft : .leftToRight)
                .frame(maxWidth: .infinity, alignment: m.sentence.language == "he" ? .trailing : .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            HStack(spacing: 14) {
                if m.phase == .recording {
                    Button("Done") { m.stopRecording() }.keyboardShortcut(.defaultAction).controlSize(.large)
                    ProgressView(value: Double(m.level)).frame(width: 180)
                    Text("Recording… it stops by itself when you finish.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Record") { m.record() }.keyboardShortcut(.defaultAction).controlSize(.large)
                    if m.index > 0 { Button("Redo the last one") { m.redoLast() } }
                    Text("Click Record (or press Return), then read it.").font(.callout).foregroundStyle(.secondary)
                }
            }
            if !m.status.isEmpty { Text(m.status).foregroundStyle(.red) }
        }
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(m.phase == .done ? "What each engine heard" : "Listening to your recordings…").font(.title2.bold())
                if !m.status.isEmpty { Text(m.status).foregroundStyle(.secondary) }
                if !m.verdict.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(m.verdict, id: \.self) { Label($0, systemImage: "checkmark.message").fixedSize(horizontal: false, vertical: true) }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                }
                ForEach(m.takes, id: \.sentence) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(t.sentence). \(t.written)").font(.headline)
                            Spacer()
                            Text(String(format: "voice %.0f dBFS · room %.0f", t.levels.speech, t.levels.floor))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(t.levels.speech < -45 ? .orange : .secondary)
                        }
                        ForEach(t.heard, id: \.engine) { h in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: h.errors == 0 ? "checkmark.circle.fill" : "xmark.circle")
                                    .foregroundStyle(h.errors == 0 ? .green : .orange)
                                Text(h.engine).font(.callout.bold()).frame(width: 74, alignment: .leading)
                                Text(h.text.isEmpty ? "(nothing)" : h.text).font(.callout).textSelection(.enabled)
                                Spacer()
                                Text(h.errors == 0 ? "" : "\(h.errors) wrong").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
                if m.phase == .done {
                    HStack {
                        if let dir = m.savedFolder {
                            Button("Show results file") { NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("results.json")]) }
                        }
                        Button(m.recordingsDeleted ? "Recordings deleted" : "Delete recordings") { m.deleteRecordings() }
                            .disabled(m.recordingsDeleted)
                        Spacer()
                        Button("Run again") { m.begin() }
                    }
                    Text("The results file has the text and levels, for a later look at what went wrong; the recordings never leave this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
