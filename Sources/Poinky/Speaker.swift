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

    func attach(_ audio: AudioIO) {
        self.audio = audio
        audio.onRestart = { [weak self] in self?.audioRestarted() }
    }

    private var heard: (String, Int?)?            // the sentence being heard right now
    private var making: (String, Int?)?           // the sentence the voice is making
    private var replaying: [String] = []          // said again after a device change: no new caption
    private var deviceLost = false                // the engine stopped under us: wait for the new one

    // The audio device changed (AirPods connecting, switching between iPhone and Mac, or going into
    // headset mode when the mic opens) and macOS stopped the engine. Everything scheduled on it
    // reports "played" at once without a sound, so the rest of the answer vanished. Notice it on
    // the first such report, keep our place, and continue once AudioIO has a new engine.
    private func lostDevice() {
        guard !deviceLost else { return }
        deviceLost = true
        keepPlace()
        audio?.deviceChanged()      // in case its notification hasn't come (it usually has)
    }

    /// The engine was rebuilt on the new device: say again from the sentence that was cut off.
    private func audioRestarted() {
        if !deviceLost { keepPlace() }   // nothing reported yet: what was scheduled is gone all the same
        deviceLost = false
        pump()
    }

    /// Puts what was playing or about to play back at the front of the queue and drops the rest.
    private func keepPlace() {
        guard turnActive else { return }
        var again: [(String, Int?)] = []
        if let h = heard, buffersPlaying > 0 { again.append(h) }
        again += waitingCaptions
        if synthesizing, let m = making, !again.contains(where: { $0.0 == m.0 && $0.1 == m.1 }) { again.append(m) }
        replaying = heard.map { h in again.contains(where: { $0.0 == h.0 && $0.1 == h.1 }) ? [h.0] : [] } ?? []
        generation += 1                 // callbacks from the old engine and the voice are ignored
        phonon?.cancelPending()
        synth.stopSpeaking(at: .immediate)
        appleCaption = nil
        waitingCaptions.removeAll()
        buffersPlaying = 0
        synthesizing = false
        converter = nil
        resetPacing()
        queue = again + queue
    }

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

    var voiceName: String { usingPhonon ? "Phonon \(phononVoice)" : (voice?.name ?? "default") }

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
            resetPacing()
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
        resetPacing()
        heard = nil
        making = nil
        replaying.removeAll()
        deviceLost = false
        synth.stopSpeaking(at: .immediate)
        phonon?.cancelPending()
        audio?.player.stop()
    }

    // The free local neural voice. When it's running it's used; Apple's voice is the fallback.
    var phonon: PhononVoice?
    var phononVoice = PhononVoice.defaultVoice
    var voiceSpeed = 1.0
    var usingPhonon: Bool { phonon?.isRunning == true }
    /// Audio held back before a sentence starts playing, so a busy moment on the main thread
    /// can't leave a gap mid-word. Phonon makes this much in a few milliseconds.
    private static let prebuffer = 0.1

    private func pump() {
        guard !deviceLost else { return }
        guard turnActive, !synthesizing, !queue.isEmpty else { checkDone(); return }
        let (text, tag) = queue.removeFirst()
        making = (text, tag)
        synthesizing = true
        let gen = generation
        if let p = phonon, p.isRunning {
            speakWithPhonon(p, text, tag: tag, gen: gen)
            return
        }
        speakWithApple(text, tag: tag, gen: gen)
    }

    /// Streams the sentence: chunks are played as they're generated, starting once a little is
    /// buffered. The next sentence is asked for as soon as this one is generated, while it plays.
    /// Its first audio waits at the gate (see `holdNext`) when a 3D step needs time on screen.
    private func speakWithPhonon(_ p: PhononVoice, _ text: String, tag: Int?, gen: Int) {
        var waiting: [AVAudioPCMBuffer] = []
        var waitingSeconds = 0.0
        var started = false, atGate = false, ended = false, endOK = true
        let play: (AVAudioPCMBuffer) -> Void = { [weak self] buf in
            guard let self else { return }
            self.schedule(buf, gen: gen, wholeSentence: false, text: started ? nil : text, tag: tag)
            started = true
        }
        // Generated and (if it had any audio) scheduled: close the sentence and make the next one.
        let finish: () -> Void = { [weak self] in
            guard let self, gen == self.generation else { return }
            if !started {
                if !endOK { self.speakWithApple(text, tag: tag, gen: gen) } else { self.synthesizing = false; self.pump() }
                return
            }
            // A few milliseconds of silence close the sentence: it flushes the resampler's tail and
            // marks where the sentence ends, for the captions.
            if let tail = AVAudioPCMBuffer(pcmFormat: self.format24k, frameCapacity: 240), let d = tail.floatChannelData?[0] {
                d.initialize(repeating: 0, count: 240)
                tail.frameLength = 240
                self.schedule(tail, gen: gen, wholeSentence: true)
            }
            self.synthesizing = false
            self.pump()          // make the next sentence while this one plays
        }
        let release: () -> Void = { [weak self] in
            guard let self, gen == self.generation else { return }
            waiting.forEach(play)
            waiting.removeAll()
            if ended { finish() }
        }
        p.speak(text, voice: phononVoice, speed: voiceSpeed, onChunk: { [weak self] buf in
            guard let self, gen == self.generation else { return }
            if started { play(buf); return }
            waiting.append(buf)
            waitingSeconds += Double(buf.frameLength) / buf.format.sampleRate
            if !atGate, waitingSeconds >= Self.prebuffer {
                atGate = true
                self.gate(release)
            }
        }, onEnd: { [weak self] ok in
            guard let self, gen == self.generation else { return }
            ended = true
            endOK = ok
            if started { finish(); return }
            if atGate { return }                       // release() finishes it
            if waiting.isEmpty { finish(); return }    // no audio at all
            atGate = true
            self.gate(release)                         // a short sentence: less than the prebuffer
        })
    }

    // MARK: Pacing (3D lessons)
    // A 3D step moves the camera, opens things up and adds labels while its sentence is spoken.
    // With short sentences the next step came before people had looked at this one, so the
    // sentence after a step waits until the step has been on screen a while, plus a short breath.

    private var holdUntil: Date?          // the next sentence starts no earlier than this
    private var holdBreath = 0.0          // ...nor sooner than this long after the audio before it ends
    private var awaitingStart: Int?       // a lesson line that's scheduled but not heard yet
    private var audioEndsAt = Date.distantPast   // when the audio scheduled so far finishes (estimate)
    private var parked: (() -> Void)?     // the next sentence's first audio, waiting at the gate
    private var gateTimer: DispatchWorkItem?

    /// A 3D step just started: the next sentence waits until it has been on screen `seconds`,
    /// and starts at least `breath` after the current audio ends.
    func holdNext(for seconds: TimeInterval, breath: TimeInterval) {
        guard turnActive else { return }
        let t = Date().addingTimeInterval(seconds)
        holdUntil = max(holdUntil ?? t, t)
        holdBreath = max(holdBreath, breath)
        reopenGate()
    }

    /// A sentence's first audio goes through here. A lesson line isn't queued behind the one before it
    /// until that one is heard: that's when its step runs, and the step decides how long to hold.
    private func gate(_ go: @escaping () -> Void) {
        parked = go
        reopenGate()
    }

    private func reopenGate() {
        gateTimer?.cancel()
        gateTimer = nil
        guard let go = parked, awaitingStart == nil else { return }
        var at = Date.distantPast
        if let h = holdUntil { at = max(h, audioEndsAt.addingTimeInterval(holdBreath)) }
        let wait = at.timeIntervalSinceNow
        if wait <= 0.005 {
            parked = nil
            clearHold()
            go()
            return
        }
        let gen = generation
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                self.reopenGate()
            }
        }
        gateTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    private func clearHold() {
        holdUntil = nil
        holdBreath = 0
    }

    private func resetPacing() {
        clearHold()
        parked = nil
        awaitingStart = nil
        gateTimer?.cancel()
        gateTimer = nil
        audioEndsAt = .distantPast
    }

    private func sentenceStarted(_ text: String, _ tag: Int?) {
        if tag != nil, tag == awaitingStart { awaitingStart = nil }
        heard = (text, tag)
        if let i = replaying.firstIndex(of: text) {
            replaying.remove(at: i)        // its caption is already up and its step already ran
        } else {
            onSentenceStarted?(text, tag)  // runs this line's steps, which may call holdNext
        }
        reopenGate()
    }
    private let format24k = AVAudioFormat(standardFormatWithSampleRate: PhononVoice.sampleRate, channels: 1)!

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
            if buffersPlaying == 0 {
                sentenceStarted(text, tag)
            } else {
                if tag != nil { awaitingStart = tag }
                waitingCaptions.append((text, tag))
            }
        }
        audioEndsAt = max(Date(), audioEndsAt).addingTimeInterval(Double(out.frameLength) / out.format.sampleRate)
        let endsSentence = wholeSentence
        buffersPlaying += 1
        audio.player.scheduleBuffer(out, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { return }
                    // Reported played, but the engine is stopped: it never was (the device changed).
                    if let audio = self.audio, !audio.engine.isRunning { self.lostDevice(); return }
                    self.buffersPlaying -= 1
                    if (endsSentence || self.buffersPlaying == 0), !self.waitingCaptions.isEmpty {
                        let (t, tg) = self.waitingCaptions.removeFirst()
                        self.sentenceStarted(t, tg)
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
        resetPacing()
        onTurnFinished?()
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, endOfStream: Bool = false) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let conv = converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 512)
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
