import AVFoundation
import CoreMedia
import Speech

/// Listens for the whole call. The words come from Apple's on-device engine (`AppleSpeechEngine`, SpeechAnalyzer):
/// live while you talk, and the final text when you let go. With a local model installed (`LocalModelEngine`,
/// Settings → Voice → Speech recognition), that model hears the same audio and its text is sent instead, if it
/// answers in time; Apple's text is the fallback, so a missing or stuck model never costs a question.
///
/// A question ends after `silenceSeconds` of real silence (measured from the mic level), and a little longer when
/// the sentence sounds unfinished ("…and", "…the", "um"). Holding the keys, `finishUtterance()` ends it.
///
/// Several languages (`start(languages:)`, "Languages I speak"): Apple's engine runs one recognizer per language on
/// the same audio and the question goes out in the one that heard it best (`SpeechPick`).
/// `tools/test-listener.sh`, `tools/stt-test/run.sh`.
@MainActor
final class SpeechListener {
    var onPartial: ((String) -> Void)?     // live text of what you're saying
    var onUtterance: ((String) -> Void)?   // you finished talking
    var onStatus: ((String) -> Void)? {
        didSet { SpeechStatus.shared.onStatus = onStatus }
    }
    /// The speech engine stopped by itself (an audio device change, a system hiccup): nothing would be heard again.
    var onDied: (() -> Void)?
    var silenceSeconds = 1.0
    /// Hands-free: end the question after a pause. Hold-to-talk turns this off and calls
    /// `finishUtterance()` when you let go.
    var autoEnd = true
    /// The mic level right now, 0…1.
    var level: Float { feeder?.voice.level ?? 0 }
    /// "apple", or a local model's id ("parakeet", "whisper"); set before `start`. Default: the setting.
    var engineChoice: String?
    /// What's listening, for logs and the bench ("Apple: SpeechTranscriber en-us + …; final: Parakeet").
    var engineDescription: String {
        "Apple: \(apple?.modulesDescription ?? "-")" + (local.map { "; final: \($0.name)" } ?? "")
    }
    /// The engine that wrote the last question's text, and how long it took (`finishDetailed`).
    private(set) var lastPick: SpeechPick.Result?

    private var apple: AppleSpeechEngine?
    private var local: (any SpeechEngine)?
    private var feeder: MicFeeder?
    private weak var audio: AudioIO?
    private var languages: [String] = ["en-US"]

    /// The words of each language's recognizer since the last question (track 0: the first language).
    private var tracks: [Track] = [Track()]
    private var liveCommitted = ""        // the same from the live-caption module (if there is one)
    private var liveVolatile = ""
    private var ending = false            // hands-free: a question is being settled before it's sent
    private var checkTimer: Timer?
    private var lastResultAt: TimeInterval = 0
    private(set) var running = false
    /// Mic audio has reached the speech engine since the last `clearText` (false: the mic never delivered).
    var heardAudio: Bool { heardAudioFlag.isSet }
    private let heardAudioFlag = OnceFlag()
    /// Scripted results instead of the speech engine (`--listen-test`); nothing is recognized from the mic.
    static var fake = false

    struct Track {
        var committed = ""
        var volatile = ""
        var confidences: [Double] = []
        var text: String { SpeechListener.join(committed, volatile) }
    }

    var currentText: String { tracks[best].text }
    /// The live caption's words (empty without a live-caption module).
    var liveText: String { Self.join(liveCommitted, liveVolatile) }
    /// What's shown while you talk: whichever transcript has got further (the live one, until the main one catches up).
    var shownText: String {
        let main = currentText, live = liveText
        return best == 0 && Self.words(live) > Self.words(main) ? live : main
    }
    /// The track that's heard you best so far (with one language, always 0).
    private var best: Int { SpeechPick.best(tracks: tracks, languages: languages) }
    nonisolated static func join(_ a: String, _ b: String) -> String {
        (a + " " + b).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    private static func words(_ s: String) -> Int { s.split(whereSeparator: \.isWhitespace).count }
    /// The words of the question: SpeechTranscriber's, or (holding the keys) the live caption's if that came
    /// back empty though the mic heard a voice (it sometimes finalizes a lone "Yes" as just ".").
    private var questionText: String {
        var text = currentText
        if text.isEmpty, !autoEnd, best == 0, voicedSinceClear { text = liveText }
        return Self.trimmed(text)
    }
    /// (A "." left over from the segment before can start the next final: ". and how do I…")
    static func trimmed(_ text: String) -> String {
        // (Apple's Hebrew results start with a right-to-left mark.)
        String(text.replacingOccurrences(of: "\u{200F}", with: "").drop { ".,;:!?…-– ".contains($0) }).trimmingCharacters(in: .whitespaces)
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
        try await start(audio: audio, languages: [language])
    }

    /// `languages`: the languages you speak, the one you speak most first (e.g. ["en-US", "he-IL"]).
    func start(audio: AudioIO, languages: [String]) async throws {
        guard !running else { return }
        self.audio = audio
        self.languages = languages.isEmpty ? ["en-US"] : languages
        if Self.fake { startFake(); return }

        let apple = AppleSpeechEngine()
        try await apple.start(languages: self.languages)
        apple.onResult = { [weak self] r in self?.handle(r) }
        let myApple = apple
        apple.onDied = { [weak self] in
            guard let self, self.running, self.apple === myApple else { return }
            self.stop()
            self.onDied?()
        }
        self.apple = apple
        // A local model for the final text (never blocks listening: no model or a failed load → Apple's alone).
        local = LocalModels.engine(choice: engineChoice, languages: self.languages)
        if let local {
            do { try await local.start(languages: self.languages) } catch {
                NSLog("Poinky: \(local.name) didn't start (\(error.localizedDescription)); Apple's engine only")
                Timeline.log("stt.local.fail", ["engine": local.name])
                self.local = nil
            }
        }
        let feeder = MicFeeder(engines: [apple] + (local.map { [$0] } ?? []))
        self.feeder = feeder
        apple.wordFilter = { [weak self, weak feeder] r in
            guard let self, self.autoEnd, let feeder else { return true }
            return feeder.hadVoice(in: r, margin: 0.1)
        }
        tracks = Array(repeating: Track(), count: self.languages.count)
        liveCommitted = ""; liveVolatile = ""; ending = false
        running = true
        heardAudioFlag.reset()
        let flag = heardAudioFlag
        audio.micRelay.set { buffer in feeder.feed(buffer); flag.mark() }
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForEnd() }
        }
        NSLog("Poinky: listening with \(engineDescription)")
    }

    func stop() {
        guard running else { return }
        running = false
        checkTimer?.invalidate()
        checkTimer = nil
        audio?.micRelay.set(nil)
        apple?.stop()
        apple = nil
        local?.stop()
        local = nil
        feeder = nil
    }

    /// Words to expect in the next question (what's on screen, names, recent words). Cheap; call before each one.
    func setContext(_ context: SpeechContext) {
        apple?.setContext(context)
        local?.setContext(context)
    }

    /// Forget whatever is being heard right now (e.g. it was Claude's own voice): its analyzer is dropped
    /// (what it still says about it never arrives) and the next one listens.
    func discardCurrent() {
        clearText()
        apple?.discard()
        local?.discard()
    }

    /// You let go of the talk keys: get the final words of what you said, then start fresh.
    func finishUtterance() async -> String {
        await finishDetailed().text
    }

    /// The same, with which engine's text was used and how long each took (for the timeline and the bench).
    func finishDetailed() async -> SpeechPick.Result {
        guard running, apple != nil || Self.fake else { return SpeechPick.Result(text: "", engine: "none") }
        let r = await settleQuestion()
        clearText()
        return r
    }

    /// Settles Apple's engine and (if there is one) the local model on the same audio, and picks the text.
    private func settleQuestion() async -> SpeechPick.Result {
        let started = ProcessInfo.processInfo.systemUptime
        let voiced = voicedSinceClear
        // The local model starts on the audio right away, while Apple's engine settles.
        var localTask: Task<String?, Never>?
        if let local, voiced { localTask = Task { await local.finish() } } else { local?.discard() }
        _ = await apple?.finish()
        let appleText = questionText
        let appleMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        let pickedTrack = best
        var result = SpeechPick.Result(text: appleText, engine: "apple", apple: appleText,
                                       language: languages.indices.contains(pickedTrack) ? languages[pickedTrack] : nil,
                                       appleMs: appleMs)
        if let localTask, let local, LocalModels.speaks(local, result.language) {
            // Never wait without a way out: past the deadline, Apple's text goes.
            let deadline = max(0.25, LocalModels.deadline - (ProcessInfo.processInfo.systemUptime - started))
            let text = await SpeechDeadline.value(seconds: deadline, localTask) ?? nil
            let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
            result.engineMs = ms
            // In a call the model also hears what came before the question; if it heard far more than Apple's
            // engine did, that was probably the room or Claude's own voice: Apple's text goes.
            let tooLong = autoEnd && !appleText.isEmpty && Self.words(text ?? "") > 2 * Self.words(appleText) + 4
            if let text = text.map(Self.trimmed), !text.isEmpty, !tooLong {
                result.text = text
                result.engine = local.name
                if let lang = LocalModels.lastLanguage(local) { result.language = lang }
            } else if text == nil {
                Timeline.log("stt.local.timeout", ["engine": local.name, "ms": Int(ms)])
            }
        }
        Timeline.log("stt.final", ["engine": result.engine, "appleMs": Int(appleMs), "ms": Int(result.engineMs ?? appleMs),
                                   "lang": result.language ?? "", "same": result.text == appleText])
        MicDebug.shared.end(text: result.text)
        lastPick = result
        return result
    }

    /// Start a new question (hold-to-talk). Nothing that comes next is dropped: after
    /// `finishUtterance` everything earlier has already been settled, and the engine's final
    /// result for new speech can start slightly before the moment you pressed.
    func clearText() {
        tracks = Array(repeating: Track(), count: max(1, languages.count))
        liveCommitted = ""
        liveVolatile = ""
        heardAudioFlag.reset()
        clearedAt = ProcessInfo.processInfo.systemUptime
        apple?.nextQuestion()
        if !autoEnd { local?.discard() }   // holding the keys: the model hears from the moment you pressed
        MicDebug.shared.begin(autoEnd ? "hands-free" : "hold")
    }

    private func handle(_ r: SpeechEngineResult) {
        guard running else { return }
        let text = r.text, isFinal = r.isFinal, live = r.live
        if live, autoEnd { return }   // live captions are for holding the keys
        // Hands-free, a long quiet stretch sometimes comes back as a word ("you.", "to.", "I"), often just as
        // you start the next question: a result about audio where the mic heard no voice is dropped.
        if autoEnd, let range = r.range, let feeder, !feeder.hadVoice(in: range) { return }
        guard tracks.indices.contains(r.track) else { return }
        // Silence sometimes comes back as just "..." or "?": not words.
        let hasWords = text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        if !hasWords {
            if !isFinal { if live { liveVolatile = "" } else { tracks[r.track].volatile = "" } }
            return
        }
        if live {
            if isFinal { liveCommitted += " " + text; liveVolatile = "" } else { liveVolatile = text }
        } else if isFinal {
            tracks[r.track].committed += " " + text
            tracks[r.track].volatile = ""
            if let c = r.confidence { tracks[r.track].confidences.append(c) }
        } else {
            tracks[r.track].volatile = text
        }
        let shown = shownText
        if !shown.isEmpty {
            lastResultAt = ProcessInfo.processInfo.systemUptime
            onPartial?(shown)
        }
    }

    // MARK: Scripted results (`--listen-test`)

    private func startFake() {
        tracks = [Track()]; liveCommitted = ""; liveVolatile = ""; ending = false
        running = true
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForEnd() }
        }
    }

    /// A scripted result, through the same path as the engine's (`live`: from the live-caption module).
    func fakeResult(_ text: String, isFinal: Bool, live: Bool = false) {
        heardAudioFlag.mark()
        handle(SpeechEngineResult(text: text, isFinal: isFinal, live: live, range: nil))
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
            let r = await settleQuestion()
            ending = false
            guard running else { return }
            clearText()
            if !r.text.isEmpty { onUtterance?(r.text) }
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

/// Hands mic audio to the engines and keeps track of where the mic heard a voice.
final class MicFeeder: @unchecked Sendable {
    private let engines: [any SpeechEngine]
    private let lock = NSLock()
    private var seconds = 0.0          // audio fed so far (all engines see the same timeline)

    let voice = VoiceActivity()
    /// Where the mic heard a voice (seconds of fed audio), the last few hundred stretches.
    private var voiced: [(start: Double, end: Double)] = []

    init(engines: [any SpeechEngine]) { self.engines = engines }

    /// Did any of this stretch of audio (± a quarter second) have a voice in it?
    func hadVoice(in range: CMTimeRange, margin: Double = 0.25) -> Bool {
        let a = range.start.seconds - margin, b = range.end.seconds + margin
        lock.lock(); defer { lock.unlock() }
        return voiced.contains { $0.start < b && $0.end > a }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        MicDebug.shared.raw(buffer)
        let hasVoice = voice.process(buffer)
        let dur = Double(buffer.frameLength) / buffer.format.sampleRate
        lock.lock()
        if hasVoice {
            if let last = voiced.last, last.end >= seconds - 1e-6 { voiced[voiced.count - 1].end = seconds + dur }
            else { voiced.append((seconds, seconds + dur)); if voiced.count > 400 { voiced.removeFirst(100) } }
        }
        seconds += dur
        lock.unlock()
        let out = gain.apply(buffer)
        for e in engines { e.feed(out, voiced: hasVoice) }
    }

    let gain = InputGain()
}

/// Brings a quiet voice up to a level the recognizers like (only up, at most +24 dB, never clipping). The plain
/// built-in mic (holding the keys has no voice processing, so no automatic gain) gives a soft voice at -50 to
/// -60 dBFS, where Apple's engine made twice the word errors it makes at -38 (tools/stt-test).
/// `POINKY_STT_GAIN=0` turns it off.
final class InputGain: @unchecked Sendable {
    private let lock = NSLock()
    private var gainDB: Float = 0
    private var voiceDB: Float?
    private var floorDB: Float = -70
    private let enabled = ProcessInfo.processInfo.environment["POINKY_STT_GAIN"] != "0"
    static let target: Float = -26

    var currentDB: Float { lock.lock(); defer { lock.unlock() }; return gainDB }

    func apply(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard enabled, let data = b.floatChannelData, b.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return b }
        out.frameLength = b.frameLength
        let n = Int(b.frameLength), channels = Int(b.format.channelCount)
        let window = max(1, Int(b.format.sampleRate * 0.02))
        let src = data[0]
        lock.lock()
        var i = 0
        while i < n {
            let end = min(n, i + window)
            var sum: Float = 0
            for j in i..<end { sum += src[j] * src[j] }
            let db = AudioLevels.db((sum / Float(end - i)).squareRoot())
            if db < floorDB { floorDB = floorDB * 0.7 + db * 0.3 } else { floorDB += 0.01 }
            if db > floorDB + 10, db > -66 {
                // The voice's level: quick to rise, slow to fall.
                voiceDB = voiceDB.map { db > $0 ? $0 * 0.7 + db * 0.3 : $0 * 0.995 + db * 0.005 } ?? db
            }
            if let v = voiceDB {
                // Don't lift the room above -60 dBFS either (that's just louder hiss).
                let want = max(0, min(24, InputGain.target - v, -60 - floorDB))
                gainDB += max(-1.5, min(0.25, want - gainDB))   // up slowly (12 dB/s), down fast
            }
            let g = powf(10, gainDB / 20)
            for c in 0..<channels {
                let s = data[c], d = out.floatChannelData![c]
                for j in i..<end {
                    var y = s[j] * g
                    let a = abs(y)
                    if a > 0.7 { y = (y < 0 ? -1 : 1) * (0.7 + 0.3 * tanhf((a - 0.7) / 0.3)) }
                    d[j] = y
                }
            }
            i = end
        }
        lock.unlock()
        return out
    }
}

/// Which recognizer's words to send.
enum SpeechPick {
    struct Result {
        var text: String
        var engine: String
        var apple: String? = nil
        var language: String? = nil
        var appleMs: Double? = nil
        var engineMs: Double? = nil
    }

    /// With several languages, the track whose words are most likely what you said: written in its own script
    /// (Hebrew heard by the English recognizer comes out as English-looking nonsense, and the reverse), then the
    /// higher word confidence. One language: track 0.
    static func best(tracks: [SpeechListener.Track], languages: [String]) -> Int {
        guard tracks.count > 1 else { return 0 }
        var bestIndex = 0, bestScore = -Double.infinity
        for (i, t) in tracks.enumerated() {
            let text = t.text
            guard !text.isEmpty else { continue }
            let lang = languages.indices.contains(i) ? languages[i] : "en"
            let conf = t.confidences.isEmpty ? 0.5 : t.confidences.reduce(0, +) / Double(t.confidences.count)
            let script = SpeechScript.share(of: SpeechScript.of(lang), in: text)
            let score = conf + (script > 0.5 ? 0.5 : 0) - (i == 0 ? 0 : 0.05)
            if score > bestScore { bestScore = score; bestIndex = i }
        }
        return bestIndex
    }
}

enum SpeechScript: Equatable {
    case latin, hebrew, arabic, cyrillic, cjk, other

    static func of(_ language: String) -> SpeechScript {
        switch String(language.prefix(2)).lowercased() {
        case "he", "iw", "yi": return .hebrew
        case "ar", "fa", "ur": return .arabic
        case "ru", "uk", "bg", "sr": return .cyrillic
        case "zh", "ja", "ko", "yu": return .cjk
        case "th", "hi", "bn", "ta", "te", "gu", "kn", "ml", "mr", "pa", "or", "ne": return .other
        default: return .latin
        }
    }

    static func of(scalar u: Unicode.Scalar) -> SpeechScript? {
        switch u.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: return .latin
        case 0x0590...0x05FF, 0xFB1D...0xFB4F: return .hebrew
        case 0x0600...0x06FF, 0x0750...0x077F: return .arabic
        case 0x0400...0x04FF: return .cyrillic
        case 0x3040...0x30FF, 0x4E00...0x9FFF, 0xAC00...0xD7AF: return .cjk
        default: return CharacterSet.letters.contains(u) ? .other : nil
        }
    }

    /// The share of letters in `text` written in `script`.
    static func share(of script: SpeechScript, in text: String) -> Double {
        var n = 0, hit = 0
        for u in text.unicodeScalars { if let s = of(scalar: u) { n += 1; if s == script { hit += 1 } } }
        return n == 0 ? 0 : Double(hit) / Double(n)
    }
}
