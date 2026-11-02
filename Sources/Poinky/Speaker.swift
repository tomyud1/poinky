import AVFoundation

/// Speaks Claude's reply sentence by sentence, starting as soon as the first sentence arrives.
/// Audio goes through the shared AudioIO engine so the mic's echo canceller can remove it.
@MainActor
final class Speaker {
    /// Called once everything from the current turn has finished playing.
    var onTurnFinished: (() -> Void)?
    /// Called when a sentence starts being heard (for captions that follow the voice).
    /// The tag is set for lesson lines, so their drawing step can start with them.
    var onSentenceStarted: ((String, Int?) -> Void)?
    private var waitingCaptions: [(String, Int?)] = []   // sentences scheduled behind the one playing

    private let synth = AVSpeechSynthesizer()
    private weak var audio: AudioIO?
    private var voice: AVSpeechSynthesisVoice?
    private var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    private var queue: [(String, Int?)] = []
    private var sources = 0           // who is still adding sentences (the talker, a lesson)
    private var synthesizing = false
    private var buffersPlaying = 0
    private var turnOpen = false      // more sentences may still arrive
    private var turnActive = false
    private var generation = 0
    private var converter: AVAudioConverter?
    private(set) var spokenText = ""  // this turn's text, used to spot our own echo

    var isSpeaking: Bool { turnActive && (synthesizing || buffersPlaying > 0 || !queue.isEmpty) }

    func attach(_ audio: AudioIO) { self.audio = audio }

    /// Picks the voice. Returns false if only the basic, robotic-sounding voices are installed.
    @discardableResult
    func configure(language: String, voiceName: String, rate: Float) -> Bool {
        self.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, rate))
        let all = AVSpeechSynthesisVoice.speechVoices()
        if !voiceName.isEmpty,
           let v = AVSpeechSynthesisVoice(identifier: voiceName)
            ?? all.first(where: { $0.name.lowercased() == voiceName.lowercased() })
            ?? all.first(where: { $0.name.lowercased().hasPrefix(voiceName.lowercased()) && $0.language == language }) {
            voice = v
        } else if let id = Self.systemVoiceID(for: language), let v = AVSpeechSynthesisVoice(identifier: id) {
            // The voice you picked in System Settings → Accessibility → Read & Speak.
            voice = v
        } else {
            let lang = language.lowercased()
            let base = String(lang.prefix(2))
            let matching = all.filter { $0.language.lowercased() == lang }
            let sameLanguage = matching.isEmpty ? all.filter { $0.language.lowercased().hasPrefix(base) } : matching
            // Premium > Enhanced > Default. Skip novelty voices.
            voice = sameLanguage
                .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
                .max(by: { $0.quality.rawValue < $1.quality.rawValue })
                ?? AVSpeechSynthesisVoice(language: language)
        }
        return (voice?.quality ?? .default) != .default
    }

    var voiceName: String { usingKokoro ? "Kokoro \(kokoroVoice)" : (voice?.name ?? "default") }

    /// Reads the "System voice" chosen in Accessibility → Read & Speak for this language.
    /// macOS stores it as [language, {voiceId: …}, language, {…}, …].
    static func systemVoiceID(for language: String) -> String? {
        guard let list = CFPreferencesCopyAppValue("SpokenContentDefaultVoiceSelectionsByLanguage" as CFString,
                                                   "com.apple.Accessibility" as CFString) as? [Any] else { return nil }
        let base = String(language.lowercased().prefix(2))
        var i = 0
        while i + 1 < list.count {
            if let lang = (list[i] as? String)?.lowercased(),
               lang == language.lowercased() || lang == base || lang.hasPrefix(base + "-"),
               let selection = list[i + 1] as? [String: Any],
               let id = selection["voiceId"] as? String {
                return id
            }
            i += 2
        }
        return nil
    }

    /// Start a new reply. Sentences can then be added as they stream in.
    func beginTurn() {
        stop()
        sources = 1
        turnOpen = true
        turnActive = true
        spokenText = ""
    }

    /// Another source (a lesson) will add lines: joins the current turn, or starts one
    /// without cutting off anything playing.
    func openSource() {
        if turnActive {
            sources += 1
        } else {
            sources = 1
            turnActive = true
            spokenText = ""
        }
        turnOpen = true
    }

    func enqueue(_ sentence: String, tag: Int? = nil) {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard turnActive, !s.isEmpty else { return }
        spokenText += " " + s
        queue.append((s, tag))
        pump()
    }

    /// One source is done adding sentences. The turn ends once all are done and the audio finished.
    func endTurn() {
        guard turnActive else { return }
        sources = max(0, sources - 1)
        if sources == 0 { turnOpen = false }
        checkDone()
    }

    /// Stop talking right now (e.g. you interrupted).
    func stop() {
        generation += 1
        queue.removeAll()
        waitingCaptions.removeAll()
        appleCaption = nil
        synthesizing = false
        buffersPlaying = 0
        sources = 0
        turnOpen = false
        turnActive = false
        synth.stopSpeaking(at: .immediate)
        kokoro?.cancelPending()
        audio?.player.stop()
    }

    // The free local neural voice. When it's running it's used; Apple's voice is the fallback.
    var kokoro: KokoroVoice?
    var kokoroVoice = "am_michael"
    var kokoroSpeed = 1.0
    var usingKokoro: Bool { kokoro?.isRunning == true }

    private func pump() {
        guard turnActive, !synthesizing, !queue.isEmpty else { checkDone(); return }
        let (text, tag) = queue.removeFirst()
        synthesizing = true
        let gen = generation
        if let k = kokoro, k.isRunning {
            k.synthesize(text, voice: kokoroVoice, speed: kokoroSpeed) { [weak self] pcm in
                guard let self, gen == self.generation else { return }
                if let pcm {
                    self.schedule(pcm, gen: gen, wholeSentence: true, text: text, tag: tag)
                    self.synthesizing = false
                    self.pump()          // make the next sentence while this one plays
                } else {
                    self.speakWithApple(text, tag: tag, gen: gen)
                }
            }
            return
        }
        speakWithApple(text, tag: tag, gen: gen)
    }

    private func speakWithApple(_ text: String, tag: Int?, gen: Int) {
        appleCaption = (text, tag)
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = rate
        synth.write(u) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(pcm, gen: gen) }
            }
        }
    }

    private func received(_ pcm: AVAudioPCMBuffer, gen: Int) {
        guard gen == generation, let audio, audio.running else { return }
        if pcm.frameLength == 0 {   // end of this sentence
            synthesizing = false
            pump()
            return
        }
        let caption = appleCaption
        appleCaption = nil
        schedule(pcm, gen: gen, wholeSentence: false, text: caption?.0, tag: caption?.1)
    }
    private var appleCaption: (String, Int?)?

    private func schedule(_ pcm: AVAudioPCMBuffer, gen: Int, wholeSentence: Bool, text: String? = nil, tag: Int? = nil) {
        guard let audio, audio.running else { return }
        guard let out = convert(pcm, to: audio.playbackFormat, endOfStream: wholeSentence) else { return }
        // Caption: show this sentence now if nothing is playing, otherwise when the one before it ends.
        if let text {
            if buffersPlaying == 0 { onSentenceStarted?(text, tag) } else { waitingCaptions.append((text, tag)) }
        }
        let endsSentence = wholeSentence
        buffersPlaying += 1
        audio.player.scheduleBuffer(out, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    self.buffersPlaying -= 1
                    if (endsSentence || self.buffersPlaying == 0), !self.waitingCaptions.isEmpty {
                        let (t, tg) = self.waitingCaptions.removeFirst()
                        self.onSentenceStarted?(t, tg)
                    }
                    self.checkDone()
                }
            }
        }
        if !audio.player.isPlaying { audio.player.play() }
    }

    private func checkDone() {
        guard turnActive, !turnOpen, !synthesizing, queue.isEmpty, buffersPlaying == 0 else { return }
        turnActive = false
        onTurnFinished?()
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, endOfStream: Bool = false) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let conv = converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = endOfStream ? .endOfStream : .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        // A whole sentence: flush the converter so its tail isn't cut off or carried into the next one.
        if endOfStream { conv.reset() }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}
