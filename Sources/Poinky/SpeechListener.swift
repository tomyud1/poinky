import AVFoundation
import CoreMedia
import Speech

/// Listens for the whole call using Apple's newer on-device speech engine (SpeechAnalyzer).
/// English uses SpeechTranscriber; languages it doesn't cover (like Hebrew) use DictationTranscriber.
/// A question ends after `silenceSeconds` of real silence (measured from the mic level),
/// and a little longer when the sentence sounds unfinished ("…and", "…the", "um").
@MainActor
final class SpeechListener {
    var onPartial: ((String) -> Void)?     // live text of what you're saying
    var onUtterance: ((String) -> Void)?   // you finished talking
    var onStatus: ((String) -> Void)?
    /// The speech engine stopped by itself (an audio device change, a system hiccup): nothing would be heard again.
    var onDied: (() -> Void)?
    var silenceSeconds = 1.0
    /// Hands-free: end the question after a pause. Hold-to-talk turns this off and calls
    /// `finishUtterance()` when you let go.
    var autoEnd = true
    /// The mic level right now, 0…1.
    var level: Float { feeder?.voice.level ?? 0 }

    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var feeder: MicFeeder?
    private weak var audio: AudioIO?

    private var committed = ""            // finished segments since the last question
    private var volatile = ""             // the segment still being recognized
    private var boundary: CMTime = .zero  // audio before this belongs to the previous question
    private var checkTimer: Timer?
    private var lastResultAt: TimeInterval = 0
    private(set) var running = false

    var currentText: String {
        (committed + " " + volatile).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func requestPermissions() async -> Bool {
        let speechOK: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        return speechOK && micOK
    }

    func start(audio: AudioIO, language: String) async throws {
        guard !running else { return }
        self.audio = audio
        let locale = Locale(identifier: language)
        let wanted = locale.identifier(.bcp47).lowercased()

        let module: any SpeechModule
        let transcriberLocales = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47).lowercased() }
        if transcriberLocales.contains(wanted) {
            module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                       reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        } else {
            let dictationLocales = await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47).lowercased() }
            guard dictationLocales.contains(wanted) else {
                throw BrainError("Speech recognition doesn't support “\(language)” on this Mac.")
            }
            module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            onStatus?("Downloading the speech model (one time)…")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw BrainError("Couldn't set up the speech engine's audio format.")
        }

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let feeder = MicFeeder(target: format, continuation: cont)
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        self.continuation = cont
        self.feeder = feeder
        committed = ""; volatile = ""; boundary = .zero
        running = true
        audio.micRelay.set { buffer in feeder.feed(buffer) }
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForEnd() }
        }

        let myAnalyzer = analyzer
        if let t = module as? SpeechTranscriber {
            resultsTask = Task { [weak self] in
                do {
                    for try await r in t.results {
                        self?.handle(text: String(r.text.characters), range: r.range, isFinal: r.isFinal)
                    }
                } catch { NSLog("Poinky: speech engine stopped: \(error.localizedDescription)") }
                self?.died(myAnalyzer)
            }
        } else if let d = module as? DictationTranscriber {
            resultsTask = Task { [weak self] in
                do {
                    for try await r in d.results {
                        self?.handle(text: String(r.text.characters), range: r.range, isFinal: r.isFinal)
                    }
                } catch { NSLog("Poinky: speech engine stopped: \(error.localizedDescription)") }
                self?.died(myAnalyzer)
            }
        }
    }

    /// The results ended while still listening (not by `stop()`): tell the call so it can start over.
    private func died(_ which: SpeechAnalyzer?) {
        guard running, which === analyzer, !Task.isCancelled else { return }
        stop()
        onDied?()
    }

    func stop() {
        guard running else { return }
        running = false
        checkTimer?.invalidate()
        checkTimer = nil
        audio?.micRelay.set(nil)
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let a = analyzer { Task { await a.cancelAndFinishNow() } }
        analyzer = nil
        feeder = nil
    }

    /// Forget whatever is being heard right now (e.g. it was Claude's own voice).
    func discardCurrent() {
        committed = ""
        volatile = ""
        boundary = feeder?.now ?? boundary
    }

    /// You let go of the talk keys: get the final words of what you said, then start fresh.
    func finishUtterance() async -> String {
        guard running, let analyzer, let feeder else { return "" }
        // Ask the engine to settle everything heard so far (with a time limit, just in case).
        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()
        _ = feeder
        // (Finalizing "through: nil" means everything received so far; with a time it could hang.)
        Task { try? await analyzer.finalize(through: nil); await MainActor.run { flag.done = true } }
        let start = ProcessInfo.processInfo.systemUptime
        while !flag.done, ProcessInfo.processInfo.systemUptime - start < 1.2 {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        // The final words arrive just after; wait until nothing new comes for a moment.
        let settleStart = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - settleStart < 0.5,
              ProcessInfo.processInfo.systemUptime - lastResultAt < 0.12 {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        let text = currentText
        clearText()
        return text
    }

    /// Start a new question (hold-to-talk). Unlike `discardCurrent`, nothing that comes next is
    /// dropped: after `finishUtterance` everything earlier has already been settled, and the
    /// engine's final result for new speech can start slightly before the moment you pressed.
    func clearText() {
        committed = ""
        volatile = ""
        boundary = .zero
    }

    private func handle(text: String, range: CMTimeRange, isFinal: Bool) {
        guard running else { return }
        // Results for audio from before the last question already went out with it.
        if CMTimeCompare(range.start, boundary) < 0 { return }
        // Silence sometimes comes back as just "..." or "?": not words.
        let hasWords = text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        if !hasWords {
            if !isFinal { volatile = "" }
            return
        }
        if isFinal {
            committed += " " + text
            volatile = ""
        } else {
            volatile = text
        }
        let current = currentText
        if !current.isEmpty {
            lastResultAt = ProcessInfo.processInfo.systemUptime
            onPartial?(current)
        }
    }

    /// Runs 10× a second: have you really finished talking?
    private func checkForEnd() {
        guard running, autoEnd else { return }
        let text = currentText
        guard !text.isEmpty else { return }
        let stableFor = ProcessInfo.processInfo.systemUptime - lastResultAt
        var needed = silenceSeconds
        if Self.soundsUnfinished(text) { needed += 0.9 }
        if let quietFor = feeder?.voice.secondsSinceVoice {
            // Real silence for long enough, and the transcript has settled.
            // (Background noise that never goes quiet: give up waiting after a while.)
            if (quietFor >= needed && stableFor >= 0.35) || stableFor >= needed + 2.5 { endOfUtterance() }
        } else if stableFor >= needed {
            endOfUtterance()
        }
    }

    private static let continuationWords: Set<String> = [
        "and", "or", "but", "so", "because", "cause", "the", "a", "an", "to", "of", "for", "with", "in",
        "on", "at", "from", "about", "like", "um", "uh", "uhm", "umm", "er", "erm", "hmm", "that", "which",
        "if", "when", "is", "are", "was", "were", "my", "your", "this", "these", "those", "how", "what",
        "why", "where", "who", "then", "also", "just", "can", "could", "would", "should", "will", "i",
        "it's", "its", "it", "do", "does", "did", "than", "as", "into", "onto", "by", "not", "very", "really",
    ]

    /// "…and", "…the", "um", or a trailing comma: you're probably still going.
    static func soundsUnfinished(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(",") || trimmed.hasSuffix("-") || trimmed.hasSuffix("…") { return true }
        guard let last = trimmed.split(separator: " ").last else { return false }
        let word = last.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "'")))
        return continuationWords.contains(word)
    }

    private func endOfUtterance() {
        let text = currentText
        discardCurrent()
        if !text.isEmpty { onUtterance?(text) }
    }
}

/// Converts mic audio into the speech engine's format and timestamps it.
final class MicFeeder: @unchecked Sendable {
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var samples: Int64 = 0
    private let lock = NSLock()

    let voice = VoiceActivity()

    init(target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.target = target
        self.continuation = continuation
    }

    var now: CMTime {
        lock.lock(); defer { lock.unlock() }
        return CMTime(value: samples, timescale: CMTimeScale(target.sampleRate))
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        voice.process(buffer)
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            // With voice processing the mic delivers several channels; channel 0 is the
            // cleaned-up voice (echo removed). Use only that one.
            if buffer.format.channelCount > 1 { converter?.channelMap = [0] }
        }
        guard let conv = converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        lock.lock()
        let start = CMTime(value: samples, timescale: CMTimeScale(target.sampleRate))
        samples += Int64(out.frameLength)
        lock.unlock()
        continuation.yield(AnalyzerInput(buffer: out, bufferStartTime: start))
    }
}
