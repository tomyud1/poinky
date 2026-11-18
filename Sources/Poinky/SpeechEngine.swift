import AVFoundation
import CoreMedia
import Speech

/// Words the recognizer should expect for the next question: what's on screen (OCR lines, the window title,
/// selected text), helper names, the user's name and terms from memory, and words from the last exchanges.
struct SpeechContext: Equatable {
    var words: [String] = []
    /// Short phrases from the last few exchanges (Whisper takes them as its prompt).
    var recent: [String] = []

    var isEmpty: Bool { words.isEmpty && recent.isEmpty }

    /// The words, each once, longest-lived first, at most `limit`. Apple's engine takes a list of strings;
    /// Whisper takes a prompt of at most ~200 tokens.
    func terms(limit: Int = 100) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for w in words {
            let t = w.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard t.count >= 2, t.count <= 40, seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
            if out.count >= limit { break }
        }
        return out
    }

    /// Words worth biasing toward from a stretch of screen text: names, technical words, identifiers.
    /// Common words are left out (Apple's engine knows them already, and a long list dilutes the bias).
    static func interesting(in text: String, limit: Int = 60) -> [String] {
        var out: [String] = [], seen = Set<String>()
        let tokens = text.split(whereSeparator: { $0.isWhitespace || ",;:()[]{}\"“”<>|/\\".contains($0) })
        for raw in tokens {
            let w = raw.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "-_.'")))
                .trimmingCharacters(in: CharacterSet(charactersIn: ".'"))
            guard w.count >= 3, w.count <= 32, w.rangeOfCharacter(from: .letters) != nil else { continue }
            let lower = w.lowercased()
            if SpeechContext.common.contains(lower) { continue }
            let capital = w.first?.isUppercase == true
            let code = w.contains("_") || w.contains(".") || w.dropFirst().contains(where: \.isUppercase)
            let long = w.count >= 8
            let nonLatin = w.unicodeScalars.contains { $0.value > 0x24F }
            guard capital || code || long || nonLatin else { continue }
            if seen.insert(lower).inserted { out.append(w) }
            if out.count >= limit { break }
        }
        return out
    }

    private static let common: Set<String> = [
        "the", "and", "for", "you", "your", "with", "this", "that", "from", "have", "are", "was", "were", "will", "can",
        "not", "but", "all", "any", "our", "out", "use", "new", "one", "two", "file", "edit", "view", "window", "help",
        "open", "save", "close", "settings", "search", "home", "share", "more", "about", "what", "when", "where",
        "which", "there", "their", "they", "them", "then", "than", "into", "also", "just", "like", "only", "some",
        "other", "these", "those", "would", "could", "should", "today", "yesterday", "tomorrow", "monday", "tuesday",
        "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april", "june",
        "july", "august", "september", "october", "november", "december", "untitled", "document", "page", "pages",
    ]
}

/// One speech recognizer behind `SpeechListener`. Apple's engine streams words while you talk; the others
/// (`LocalModelEngine`) only answer `finish()` with the text of everything fed since the last finish.
@MainActor
protocol SpeechEngine: AnyObject {
    var name: String { get }
    /// Words while you talk (volatile and final results). Engines that can't stream never call it.
    var onResult: ((SpeechEngineResult) -> Void)? { get set }
    /// The engine stopped by itself (a system hiccup): nothing would be heard again.
    var onDied: (() -> Void)? { get set }
    func start(languages: [String]) async throws
    /// Mic audio as it came (any format; the engine converts). Called on the audio thread.
    nonisolated func feed(_ buffer: AVAudioPCMBuffer, voiced: Bool)
    func setContext(_ context: SpeechContext)
    /// Settle everything heard so far and return its text (nil: the words already came through `onResult`).
    func finish() async -> String?
    /// Forget what's being heard right now (it was Claude's own voice, or a shortcut).
    func discard()
    func stop()
}

struct SpeechEngineResult {
    var text: String
    var isFinal: Bool
    /// From the live-caption module (DictationTranscriber running next to SpeechTranscriber).
    var live: Bool
    var range: CMTimeRange?
    /// Which of the languages it's for (index into the languages given to `start`).
    var track = 0
    /// Mean word confidence 0…1, when the module reports it.
    var confidence: Double?
}

/// Apple's on-device engine (SpeechAnalyzer). For each language you speak, SpeechTranscriber where it covers
/// the language (English), else DictationTranscriber (Hebrew, Arabic, Russian…). Where DictationTranscriber also
/// covers the first language, it runs alongside for the live caption (it updates ~4× a second; SpeechTranscriber
/// only about once per second of audio).
///
/// Every question gets a fresh analyzer. One analyzer kept for a whole session, with `finalize` between
/// questions, garbled the questions after the first ("Does this sentence sound too formal…" came back as
/// "to............."): 18 % word errors on clean speech against 4 % for a fresh analyzer on the same audio
/// (tools/stt-test). A spare analyzer is started ahead of time (~10 ms with the model kept loaded), so the next
/// question never waits for one; audio that arrives before it's ready is kept and handed over.
@MainActor
final class AppleSpeechEngine: SpeechEngine {
    var onResult: ((SpeechEngineResult) -> Void)?
    var onDied: (() -> Void)?
    private(set) var name = "Apple"
    /// Did the mic hear a voice in this stretch? Set for calls: words outside any voice are dropped.
    var wordFilter: ((CMTimeRange) -> Bool)?

    /// One analyzer and its modules, for one question.
    private final class Gen {
        let id: Int
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        var tasks: [Task<Void, Never>] = []
        var base = 0.0                 // session seconds where its audio starts
        var lastResultAt: TimeInterval = 0
        var unsettled: [Int: Bool] = [:]   // per language track (not the live caption): its last words aren't final yet
        init(id: Int, analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation) {
            self.id = id; self.analyzer = analyzer; self.continuation = continuation
        }
    }

    private struct Spec {
        enum Kind { case speech, dictation }
        let kind: Kind
        let locale: Locale
        let track: Int
        let live: Bool
    }

    private var specs: [Spec] = []
    private var format: AVAudioFormat?
    private var current: Gen?
    private var settling: Gen?           // the last question's analyzer while it settles
    private var spare: Gen?
    private var preparing = false
    private var nextID = 0
    /// Results for the new question that came while the last one settled: delivered by `nextQuestion()`.
    private var held: [SpeechEngineResult] = []
    private let input = AppleInput()
    private var running = false
    private var context = SpeechContext()
    /// What each track is (for logs and the bench).
    private(set) var modulesDescription = ""

    /// Test hooks (`tools/stt-test`): `POINKY_STT_MAIN=dictation` uses DictationTranscriber for English too;
    /// `POINKY_STT_LEGACY=1` sets it up as before the bench (one analyzer for the session, fast results,
    /// no confidence, default resampler).
    private let env = ProcessInfo.processInfo.environment
    nonisolated static let legacy = ProcessInfo.processInfo.environment["POINKY_STT_LEGACY"] == "1"

    func start(languages: [String]) async throws {
        guard !running else { return }
        let transcriberLocales = Set(await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47).lowercased() })
        let dictationLocales = Set(await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47).lowercased() })

        var wanted: [(Spec, String)] = []
        for (track, language) in languages.enumerated() {
            let locale = Locale(identifier: language)
            let id = locale.identifier(.bcp47).lowercased()
            let useDictation = env["POINKY_STT_MAIN"] == "dictation" && dictationLocales.contains(id)
            if transcriberLocales.contains(id), !useDictation {
                wanted.append((Spec(kind: .speech, locale: locale, track: track, live: false), "SpeechTranscriber \(id)"))
                if track == 0, dictationLocales.contains(id), env["POINKY_LIVE_CAPTIONS"] != "0" {
                    wanted.append((Spec(kind: .dictation, locale: locale, track: 0, live: true), "live: DictationTranscriber \(id)"))
                }
            } else if dictationLocales.contains(id) {
                wanted.append((Spec(kind: .dictation, locale: locale, track: track, live: false), "DictationTranscriber \(id)"))
            } else if track == 0 {
                throw BrainError("Speech recognition doesn't support “\(language)” on this Mac.")
            } else {
                NSLog("Poinky: speech recognition doesn't support \(language); listening without it")
            }
        }
        // The first language's model is needed now (one time). Any other model (a second language, the live
        // caption) is used only if it's already on this Mac: it's fetched in the background for next time.
        var ready: [(Spec, String)] = []
        for (i, (spec, what)) in wanted.enumerated() {
            let probe = makeModule(spec)
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    if i == 0 {
                        SpeechStatus.shared.post("Downloading the speech model (one time)…")
                        try await request.downloadAndInstall()
                    } else {
                        NSLog("Poinky: downloading a speech model for next time: \(what)")
                        Task.detached { try? await request.downloadAndInstall() }
                        continue
                    }
                }
                ready.append((spec, what))
            } catch {
                if i == 0 { throw error }
                NSLog("Poinky: \(what) unavailable: \(error.localizedDescription)")
            }
        }
        specs = ready.map(\.0)
        modulesDescription = ready.map(\.1).joined(separator: " + ")
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: specs.map(makeModule)) else {
            throw BrainError("Couldn't set up the speech engine's audio format.")
        }
        self.format = format
        input.reset(target: format)
        running = true
        let first = try await makeGen()
        use(first)
        prepareSpare()
    }

    private func makeModule(_ spec: Spec) -> any SpeechModule {
        switch spec.kind {
        case .speech:
            // `.fastResults`: without it SpeechTranscriber holds its words back for seconds, and a hands-free call
            // only knows you've finished once some words have come (tools/test-listener.sh). It costs no accuracy
            // on a fresh analyzer (tools/stt-test).
            var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
            if Self.legacy || env["POINKY_STT_FAST"] != "0" { reporting.insert(.fastResults) }
            return SpeechTranscriber(locale: spec.locale, transcriptionOptions: [], reportingOptions: reporting,
                                     attributeOptions: Self.legacy ? [] : [.transcriptionConfidence, .audioTimeRange])
        case .dictation where spec.live:
            return DictationTranscriber(locale: spec.locale, preset: .progressiveLongDictation)
        case .dictation:
            let p = DictationTranscriber.Preset.progressiveLongDictation
            return DictationTranscriber(locale: spec.locale, contentHints: p.contentHints, transcriptionOptions: p.transcriptionOptions,
                                        reportingOptions: p.reportingOptions, attributeOptions: p.attributeOptions.union([.transcriptionConfidence]))
        }
    }

    private func makeGen() async throws -> Gen {
        guard let format else { throw BrainError("The speech engine isn't set up.") }
        nextID += 1
        let modules = specs.map(makeModule)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        // `lingering`: the model stays loaded a while after an analyzer ends, so the next one starts in ~10 ms.
        let analyzer = SpeechAnalyzer(modules: modules, options: .init(priority: .userInitiated, modelRetention: .lingering))
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        let gen = Gen(id: nextID, analyzer: analyzer, continuation: cont)
        let ctx = contextObject()
        if let ctx { try? await analyzer.setContext(ctx) }
        for (module, spec) in zip(modules, specs) {
            let track = spec.track, live = spec.live
            gen.tasks.append(Task { [weak self, weak gen] in
                do {
                    if let t = module as? SpeechTranscriber {
                        for try await r in t.results { guard let gen else { break }; self?.emit(gen, r.text, r.isFinal, live, r.range, track) }
                    } else if let d = module as? DictationTranscriber {
                        for try await r in d.results { guard let gen else { break }; self?.emit(gen, r.text, r.isFinal, live, r.range, track) }
                    }
                } catch { NSLog("Poinky: speech engine stopped: \(error.localizedDescription)") }
                // The current question's main module ended by itself (not by a rotation or `stop()`): start over.
                if !live, track == 0, let gen { self?.died(gen) }
            })
        }
        return gen
    }

    /// Starts feeding `gen` (audio kept meanwhile goes to it first).
    private func use(_ gen: Gen) {
        current = gen
        gen.base = input.attach(gen.continuation)
    }

    private func prepareSpare() {
        guard running, spare == nil, !preparing, !Self.legacy else { return }
        preparing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let gen = try? await self.makeGen()
            self.preparing = false
            guard self.running, let gen else { if let gen { Self.end(gen) }; return }
            if self.current == nil { self.use(gen) } else { self.spare = gen }
        }
    }

    /// The next question's analyzer: the spare, or (if it isn't ready) none yet: audio waits in `input`.
    private func rotate() -> Gen? {
        guard !Self.legacy else { return nil }
        let old = current
        current = nil
        input.detach()
        if let s = spare { spare = nil; use(s) }
        prepareSpare()
        return old
    }

    private static func end(_ gen: Gen) {
        gen.continuation.finish()
        for t in gen.tasks { t.cancel() }
        let a = gen.analyzer
        Task { await a.cancelAndFinishNow() }
    }

    private func emit(_ gen: Gen, _ text: AttributedString, _ isFinal: Bool, _ live: Bool, _ range: CMTimeRange, _ track: Int) {
        guard running else { return }
        var plain = String(text.characters)
        var confidences: [Double] = []
        for run in text.runs { if let c = run.transcriptionConfidence { confidences.append(c) } }
        // Words about audio where the mic heard no voice (a call's long quiet stretch comes back as "Okay." or
        // "you." in front of the next question) are dropped, word by word.
        if let heard = wordFilter {
            var kept = ""
            var dropped = false
            for run in text.runs {
                let piece = String(text[run.range].characters)
                if let r = run.audioTimeRange, piece.contains(where: \.isLetter) {
                    let shiftedRun = CMTimeRange(start: r.start + CMTime(seconds: gen.base, preferredTimescale: 16_000), duration: r.duration)
                    if !heard(shiftedRun) { dropped = true; continue }
                }
                kept += piece
            }
            if dropped { plain = kept }
        }
        if plain.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
            gen.lastResultAt = ProcessInfo.processInfo.systemUptime
            if !live { gen.unsettled[track] = !isFinal }
        } else if !live, isFinal, gen.unsettled[track] == true { gen.unsettled[track] = false }
        let shifted = CMTimeRange(start: range.start + CMTime(seconds: gen.base, preferredTimescale: 16_000), duration: range.duration)
        let r = SpeechEngineResult(text: plain, isFinal: isFinal, live: live, range: shifted, track: track,
                                   confidence: confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count))
        if gen === settling || (Self.legacy && gen === current) { onResult?(r) }
        else if gen === current { if settling != nil { held.append(r) } else { onResult?(r) } }
        // (A result from an analyzer that was dropped or has settled is old words: ignored.)
    }

    private func died(_ gen: Gen) {
        guard running, gen === current || gen === settling, !Task.isCancelled else { return }
        stop()
        onDied?()
    }

    nonisolated func feed(_ buffer: AVAudioPCMBuffer, voiced: Bool) { input.feed(buffer) }

    func setContext(_ c: SpeechContext) {
        guard c != context else { return }
        context = c
        // For the question being heard now, and for the spare (the next one).
        let ctx = contextObject() ?? AnalysisContext()
        for gen in [current, spare].compactMap({ $0 }) {
            let a = gen.analyzer
            Task { try? await a.setContext(ctx) }
        }
    }

    private func contextObject() -> AnalysisContext? {
        let terms = context.terms()
        guard !terms.isEmpty, env["POINKY_STT_CONTEXT"] != "0" else { return nil }
        let ctx = AnalysisContext()
        ctx.contextualStrings[.general] = terms
        return ctx
    }

    /// Settles what was heard so far: the question's analyzer finishes its audio while new audio goes to the
    /// next one. Returns nil: the words came through `onResult`.
    func finish() async -> String? {
        guard running else { return nil }
        guard let old = rotate() else {
            // Legacy: one analyzer for the session.
            if let gen = current { await Self.settle(gen.analyzer, lastResult: { gen.lastResultAt }) }
            return nil
        }
        settling = old
        // Holding the keys: finalize hands back the last words just before it returns, and then nothing more is
        // coming for them, so the 0.12 s wait for quiet after them only made you wait (measured: the final arrives
        // with finalize's return). With words still unsettled, or in a call, it waits as before.
        let early = settleEarly && Self.settleEarlyOn
        await Self.settle(old.analyzer, lastResult: { old.lastResultAt },
                          final: { early && !old.unsettled.isEmpty && !old.unsettled.values.contains(true) })
        if settling === old { settling = nil }
        Self.end(old)
        return nil
    }

    /// A whole recording was fed at once (the mic check, the bench): let the analyzer read all of it, then settle.
    func finishInput() async {
        guard running, let gen = current else { return }
        current = nil
        input.detach()
        settling = gen
        gen.continuation.finish()
        let a = gen.analyzer
        let done = Task { try? await a.finalizeAndFinishThroughEndOfInput() }
        _ = await SpeechDeadline.value(seconds: 8, done)
        await Self.settle(nil, lastResult: { gen.lastResultAt })
        settling = nil
        Self.end(gen)
    }

    /// The question went with another engine's words: what the settling analyzer still says is dropped.
    func abandonSettling() { settling = nil }

    /// The listener has taken the last question's words: results about the new one may come now.
    func nextQuestion() {
        let pending = held
        held = []
        for r in pending { onResult?(r) }
    }

    /// Finalize everything received so far ("through: nil"; with a time it could hang), with a time limit,
    /// then wait until the final words have come (nothing new for a moment).
    /// The listener sets it while you hold the keys (see `finish`). `POINKY_SETTLE_EARLY=0`: always wait for quiet.
    var settleEarly = false
    static let settleEarlyOn = ProcessInfo.processInfo.environment["POINKY_SETTLE_EARLY"] != "0"

    static func settle(_ analyzer: SpeechAnalyzer?, lastResult: @MainActor () -> TimeInterval,
                       final: @MainActor () -> Bool = { false }) async {
        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()
        if let analyzer {
            Task { try? await analyzer.finalize(through: nil); await MainActor.run { flag.done = true } }
        } else { flag.done = true }
        let start = ProcessInfo.processInfo.systemUptime
        while !flag.done, ProcessInfo.processInfo.systemUptime - start < 1.2 {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        if flag.done, analyzer != nil, final() { return }
        let settleStart = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - settleStart < 0.5,
              ProcessInfo.processInfo.systemUptime - lastResult() < 0.12 {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    /// Forget what's being heard (Claude's own voice): its analyzer is dropped, the next one takes over.
    func discard() {
        held = []
        if let old = rotate() { Self.end(old) }
    }

    func stop() {
        guard running else { return }
        running = false
        input.detach()
        for gen in [current, settling, spare].compactMap({ $0 }) { Self.end(gen) }
        current = nil; settling = nil; spare = nil; held = []
    }
}

/// Converts mic audio into the analyzer's format and timestamps it. Audio that arrives while no analyzer is
/// attached (between two) is kept, a few seconds at most, and handed to the next one.
final class AppleInput: @unchecked Sendable {
    private let lock = NSLock()
    private var target: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var total: Int64 = 0          // samples converted this session
    private var genStart: Int64 = 0       // where the attached analyzer's audio starts
    private var waiting: [AVAudioPCMBuffer] = []

    func reset(target: AVAudioFormat) {
        lock.lock(); defer { lock.unlock() }
        self.target = target; continuation = nil; converter = nil; total = 0; genStart = 0; waiting = []
    }

    /// Hands audio to a new analyzer; returns the session time (seconds) its audio starts at.
    func attach(_ c: AsyncStream<AnalyzerInput>.Continuation) -> Double {
        lock.lock()
        let backlog = waiting
        waiting = []
        let start = total - backlog.reduce(0) { $0 + Int64($1.frameLength) }
        genStart = start
        continuation = c
        var t = Int64(0)
        for b in backlog {
            c.yield(AnalyzerInput(buffer: b, bufferStartTime: CMTime(value: t, timescale: CMTimeScale(target?.sampleRate ?? 16_000))))
            t += Int64(b.frameLength)
        }
        let rate = target?.sampleRate ?? 16_000
        lock.unlock()
        return Double(start) / rate
    }

    func detach() {
        lock.lock(); continuation = nil; waiting = []; lock.unlock()
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let target else { lock.unlock(); return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            // With voice processing the mic delivers several channels; channel 0 is the
            // cleaned-up voice (echo removed). Use only that one.
            if buffer.format.channelCount > 1 { converter?.channelMap = [0] }
            if !AppleSpeechEngine.legacy { converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue }
        }
        guard let conv = converter else { lock.unlock(); return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { lock.unlock(); return }
        var consumed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { lock.unlock(); return }
        let start = CMTime(value: total - genStart, timescale: CMTimeScale(target.sampleRate))
        total += Int64(out.frameLength)
        let c = continuation
        if c == nil {
            waiting.append(out)
            // Keep ~8 s at most.
            while waiting.reduce(0, { $0 + Int($1.frameLength) }) > Int(target.sampleRate * 8) { waiting.removeFirst() }
        }
        lock.unlock()
        MicDebug.shared.engine(out, gain: 1)
        c?.yield(AnalyzerInput(buffer: out, bufferStartTime: start))
    }
}

/// Status lines from the engines ("Downloading the speech model…"), shown by the listener's owner.
@MainActor
final class SpeechStatus {
    static let shared = SpeechStatus()
    var onStatus: ((String) -> Void)?
    func post(_ s: String) { onStatus?(s) }
}

/// Waits for a task's value at most `seconds` (nil past that; the task is cancelled).
enum SpeechDeadline {
    static func value<T: Sendable>(seconds: Double, _ task: Task<T, Never>) async -> T? {
        await withTaskGroup(of: T?.self) { g in
            g.addTask { await task.value }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            if first == nil { task.cancel() }
            return first
        }
    }
}

/// Runs one engine over a recording (the mic check, the bench): start, feed it all, finish, the text.
@MainActor
enum SpeechRun {
    static func transcribe(engineID: String, samples: [Float], rate: Double, language: String,
                           context: SpeechContext = SpeechContext()) async -> String? {
        let engine: any SpeechEngine
        if engineID == "apple" { engine = AppleSpeechEngine() }
        else if let e = LocalModels.make(engineID) { engine = e }
        else { return nil }
        var committed = "", volatile = ""
        engine.onResult = { r in
            guard !r.live, r.track == 0 else { return }
            if r.isFinal { committed += " " + r.text; volatile = "" } else { volatile = r.text }
        }
        do { try await engine.start(languages: [language]) } catch {
            NSLog("Poinky: \(engineID) can't hear \(language): \(error.localizedDescription)")
            return nil
        }
        engine.setContext(context)
        if let local = engine as? LocalModelEngine { await local.waitReady(seconds: 30) }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let lead = [Float](repeating: 0, count: Int(rate * 0.2))
        let all = lead + samples + lead
        var off = 0
        while off < all.count {
            let n = min(1600, all.count - off)
            guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { break }
            b.frameLength = AVAudioFrameCount(n)
            all.withUnsafeBufferPointer { memcpy(b.floatChannelData![0], $0.baseAddress! + off, n * 4) }
            engine.feed(b, voiced: true)
            off += n
            if off % 16_000 < 1600 { try? await Task.sleep(nanoseconds: 2_000_000) }
        }
        var text: String?
        if let apple = engine as? AppleSpeechEngine { await apple.finishInput() } else { text = await engine.finish() }
        engine.stop()
        let out = text ?? SpeechListener.join(committed, volatile)
        return SpeechListener.trimmed(out)
    }
}

/// The languages a session listens for: the main one, then the others you speak.
enum SpeechLanguages {
    static func list(_ c: AppConfig) -> [String] {
        var out = [c.language]
        for l in c.otherLanguages ?? defaults(main: c.language) where !out.contains(where: { $0.prefix(2) == l.prefix(2) }) {
            out.append(l)
        }
        return Array(out.prefix(2))   // two at most: each one is another recognizer running while you talk
    }

    /// macOS's preferred languages other than the main one ("he-IL" for someone whose Mac lists Hebrew).
    static func defaults(main: String) -> [String] {
        let regions = ["he": "he-IL", "ar": "ar-SA", "ru": "ru-RU", "uk": "uk-UA", "es": "es-ES", "fr": "fr-FR", "de": "de-DE",
                       "it": "it-IT", "pt": "pt-BR", "ja": "ja-JP", "ko": "ko-KR", "zh": "zh-CN", "nl": "nl-NL", "tr": "tr-TR",
                       "pl": "pl-PL", "en": "en-US", "iw": "he-IL"]
        var out: [String] = []
        for p in Locale.preferredLanguages {
            let base = String(p.prefix(2)).lowercased()
            guard base != String(main.prefix(2)).lowercased(), let l = regions[base], !out.contains(l) else { continue }
            out.append(l)
        }
        return out
    }
}
