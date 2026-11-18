import AVFoundation
import CoreMedia
import Speech

/// Listens for the whole call using Apple's newer on-device speech engine (SpeechAnalyzer).
/// English uses SpeechTranscriber; languages it doesn't cover (like Hebrew) use DictationTranscriber.
/// A question ends after `silenceSeconds` of real silence (measured from the mic level),
/// and a little longer when the sentence sounds unfinished ("…and", "…the", "um").
///
/// SpeechTranscriber is the better transcript but only updates about once per second of audio, so a short
/// question showed no words at all until you let go. Where DictationTranscriber also covers the language, it
/// runs alongside (same analyzer, same audio) for the live caption while you hold the keys (it updates ~4× a
/// second); what's sent is SpeechTranscriber's text, or the live one if that came back empty though the mic
/// heard a voice. Hands-free calls ignore it (in a quiet room it sometimes hears an "I"). `tools/test-listener.sh`.
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
    private var liveCommitted = ""        // the same from the live-caption module (if there is one)
    private var liveVolatile = ""
    private var closing = 0               // > 0: the last question's segment is being closed; its results are dropped
    private var ending = false            // hands-free: a question is being settled before it's sent
    private var checkTimer: Timer?
    private var lastResultAt: TimeInterval = 0
    private(set) var running = false
    /// Mic audio has reached the speech engine since the last `clearText` (false: the mic never delivered).
    var heardAudio: Bool { heardAudioFlag.isSet }
    private let heardAudioFlag = OnceFlag()
    /// Scripted results instead of the speech engine (`--listen-test`); nothing is recognized from the mic.
    static var fake = false

    var currentText: String { Self.join(committed, volatile) }
    /// The live caption's words (empty without a live-caption module).
    var liveText: String { Self.join(liveCommitted, liveVolatile) }
    /// What's shown while you talk: whichever transcript has got further (the live one, until the main one catches up).
    var shownText: String {
        let main = currentText, live = liveText
        return Self.words(live) > Self.words(main) ? live : main
    }
    private static func join(_ a: String, _ b: String) -> String {
        (a + " " + b).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func words(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }
    /// The words of the question: SpeechTranscriber's, or (holding the keys) the live caption's if that came
    /// back empty though the mic heard a voice (it sometimes finalizes a lone "Yes" as just ".").
    private var questionText: String {
        var text = currentText
        if text.isEmpty, !autoEnd, voicedSinceClear { text = liveText }
        // (A "." left over from the segment before can start the next final: ". and how do I…")
        return String(text.drop { ".,;:!?…-– ".contains($0) })
    }
    private var clearedAt: TimeInterval = 0
    /// The mic heard a voice (not just the room) since the last `clearText`.
    private var voicedSinceClear: Bool {
        if Self.fake { return true }
        guard let quiet = feeder?.voice.secondsSinceVoice else { return false }
        return ProcessInfo.processInfo.systemUptime - quiet > clearedAt
    }

    static func requestPermissions() async -> Bool {
        if fake { return true }   // scripted words: no mic, nothing to ask for
        let speechOK: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        return speechOK && micOK
    }

    func start(audio: AudioIO, language: String) async throws {
        guard !running else { return }
        self.audio = audio
        if Self.fake { startFake(); return }
        let locale = Locale(identifier: language)
        let wanted = locale.identifier(.bcp47).lowercased()

        let module: any SpeechModule
        var live: DictationTranscriber?
        let transcriberLocales = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47).lowercased() }
        let dictationLocales = await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47).lowercased() }
        if transcriberLocales.contains(wanted) {
            module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                       reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
            if dictationLocales.contains(wanted), ProcessInfo.processInfo.environment["POINKY_LIVE_CAPTIONS"] != "0" {
                let d = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
                // Only if it's already on this Mac (no installation request: `status` says "supported" even then):
                // never make the session wait for a download; it's fetched for next time.
                do {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [d]) {
                        Task.detached { try? await request.downloadAndInstall() }
                    } else { live = d }
                } catch { NSLog("Poinky: no live captions: \(error.localizedDescription)") }
            }
        } else {
            guard dictationLocales.contains(wanted) else {
                throw BrainError("Speech recognition doesn't support “\(language)” on this Mac.")
            }
            module = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            onStatus?("Downloading the speech model (one time)…")
            try await request.downloadAndInstall()
        }
        let modules: [any SpeechModule] = [module] + (live.map { [$0] } ?? [])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw BrainError("Couldn't set up the speech engine's audio format.")
        }

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        let feeder = MicFeeder(target: format, continuation: cont)
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        self.continuation = cont
        self.feeder = feeder
        committed = ""; volatile = ""; liveCommitted = ""; liveVolatile = ""; closing = 0; ending = false
        running = true
        heardAudioFlag.reset()
        let flag = heardAudioFlag
        audio.micRelay.set { buffer in feeder.feed(buffer); flag.mark() }
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForEnd() }
        }

        let myAnalyzer = analyzer
        if let t = module as? SpeechTranscriber {
            resultsTask = Task { [weak self] in
                do {
                    for try await r in t.results {
                        self?.handle(text: String(r.text.characters), isFinal: r.isFinal, range: r.range)
                    }
                } catch { NSLog("Poinky: speech engine stopped: \(error.localizedDescription)") }
                self?.died(myAnalyzer)
            }
        } else if let d = module as? DictationTranscriber {
            resultsTask = Task { [weak self] in
                do {
                    for try await r in d.results {
                        self?.handle(text: String(r.text.characters), isFinal: r.isFinal, range: r.range)
                    }
                } catch { NSLog("Poinky: speech engine stopped: \(error.localizedDescription)") }
                self?.died(myAnalyzer)
            }
        }
        if let live {
            liveTask = Task { [weak self] in
                do {
                    for try await r in live.results {
                        self?.handle(text: String(r.text.characters), isFinal: r.isFinal, live: true, range: r.range)
                    }
                } catch { NSLog("Poinky: live captions stopped: \(error.localizedDescription)") }
            }
        }
    }
    private var liveTask: Task<Void, Never>?

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
        liveTask?.cancel()
        liveTask = nil
        if let a = analyzer { Task { await a.cancelAndFinishNow() } }
        analyzer = nil
        feeder = nil
    }

    /// Forget whatever is being heard right now (e.g. it was Claude's own voice): the segment is
    /// closed, and what the engine still says about it is dropped.
    func discardCurrent() {
        clearText()
        closeSegment()
    }

    /// Asks the engine to settle everything heard so far, and drops its results until it has.
    /// (Results can't be told apart by time: a new segment starts where the last final ended,
    /// often before the moment the last question was sent, so new words looked old and were lost.)
    private func closeSegment() {
        guard let analyzer else { return }
        closing += 1
        Task { @MainActor [weak self] in
            await Self.settle(analyzer, lastResult: { self?.lastResultAt ?? 0 })
            if let self, self.closing > 0 { self.closing -= 1 }
        }
    }

    /// Finalize everything received so far ("through: nil"; with a time it could hang), with a time limit,
    /// then wait until the final words have come (nothing new for a moment).
    private static func settle(_ analyzer: SpeechAnalyzer?, lastResult: @MainActor () -> TimeInterval) async {
        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()
        if let analyzer {
            Task { try? await analyzer.finalize(through: nil); await MainActor.run { flag.done = true } }
        } else { flag.done = true }
        let start = ProcessInfo.processInfo.systemUptime
        while !flag.done, ProcessInfo.processInfo.systemUptime - start < 1.2 {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        let settleStart = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - settleStart < 0.5,
              ProcessInfo.processInfo.systemUptime - lastResult() < 0.12 {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// You let go of the talk keys: get the final words of what you said, then start fresh.
    func finishUtterance() async -> String {
        guard running, analyzer != nil || Self.fake else { return "" }
        await Self.settle(analyzer, lastResult: { [weak self] in self?.lastResultAt ?? 0 })
        let text = questionText
        clearText()
        return text
    }

    /// Start a new question (hold-to-talk). Nothing that comes next is dropped: after
    /// `finishUtterance` everything earlier has already been settled, and the engine's final
    /// result for new speech can start slightly before the moment you pressed.
    func clearText() {
        committed = ""
        volatile = ""
        liveCommitted = ""
        liveVolatile = ""
        heardAudioFlag.reset()
        clearedAt = ProcessInfo.processInfo.systemUptime
    }

    private func handle(text: String, isFinal: Bool, live: Bool = false, range: CMTimeRange? = nil) {
        guard running else { return }
        if live, autoEnd { return }   // live captions are for holding the keys
        // Hands-free, a long quiet stretch sometimes comes back as a word ("you.", "to.", "I"), often just as
        // you start the next question: a result about audio where the mic heard no voice is dropped.
        if autoEnd, let range, let feeder, !feeder.hadVoice(in: range) { return }
        // The last question's segment is being closed: what comes now still belongs to it.
        if closing > 0 { return }
        // Silence sometimes comes back as just "..." or "?": not words.
        let hasWords = text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        if !hasWords {
            if !isFinal { if live { liveVolatile = "" } else { volatile = "" } }
            return
        }
        if live {
            if isFinal { liveCommitted += " " + text; liveVolatile = "" } else { liveVolatile = text }
        } else if isFinal {
            committed += " " + text
            volatile = ""
        } else {
            volatile = text
        }
        let shown = shownText
        if !shown.isEmpty {
            lastResultAt = ProcessInfo.processInfo.systemUptime
            onPartial?(shown)
        }
    }

    // MARK: Scripted results (`--listen-test`)

    private func startFake() {
        committed = ""; volatile = ""; liveCommitted = ""; liveVolatile = ""; closing = 0; ending = false
        running = true
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForEnd() }
        }
    }

    /// A scripted result, through the same path as the engine's (`live`: from the live-caption module).
    func fakeResult(_ text: String, isFinal: Bool, live: Bool = false) {
        heardAudioFlag.mark()
        handle(text: text, isFinal: isFinal, live: live)
    }

    /// Runs 10× a second: have you really finished talking?
    private func checkForEnd() {
        guard running, autoEnd, !ending else { return }
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

    /// Hands-free: you stopped talking. The engine settles what it heard first (like letting go of the
    /// keys), so the question is its final text and nothing about it arrives afterwards.
    private func endOfUtterance() {
        ending = true
        Task { @MainActor in
            await Self.settle(analyzer, lastResult: { [weak self] in self?.lastResultAt ?? 0 })
            ending = false
            guard running else { return }
            let text = questionText
            clearText()
            if !text.isEmpty { onUtterance?(text) }
        }
    }
}

/// Set from the audio thread (a buffer arrived), read and reset on the main thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func mark() { lock.lock(); done = true; lock.unlock() }
    func reset() { lock.lock(); done = false; lock.unlock() }
}

/// Converts mic audio into the speech engine's format and timestamps it.
final class MicFeeder: @unchecked Sendable {
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var samples: Int64 = 0
    private let lock = NSLock()

    let voice = VoiceActivity()
    /// Where the mic heard a voice (the engine's sample time), the last few hundred stretches.
    private var voiced: [(start: Int64, end: Int64)] = []

    init(target: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.target = target
        self.continuation = continuation
    }

    var now: CMTime {
        lock.lock(); defer { lock.unlock() }
        return CMTime(value: samples, timescale: CMTimeScale(target.sampleRate))
    }

    /// Did any of this stretch of audio (± a quarter second) have a voice in it?
    func hadVoice(in range: CMTimeRange) -> Bool {
        let rate = target.sampleRate, margin = Int64(rate * 0.25)
        let a = Int64(range.start.seconds * rate) - margin, b = Int64(range.end.seconds * rate) + margin
        lock.lock(); defer { lock.unlock() }
        return voiced.contains { $0.start < b && $0.end > a }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let hasVoice = voice.process(buffer)
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
        if hasVoice {
            if let last = voiced.last, last.end >= samples { voiced[voiced.count - 1].end = samples + Int64(out.frameLength) }
            else { voiced.append((samples, samples + Int64(out.frameLength))); if voiced.count > 400 { voiced.removeFirst(100) } }
        }
        samples += Int64(out.frameLength)
        lock.unlock()
        continuation.yield(AnalyzerInput(buffer: out, bufferStartTime: start))
    }
}
