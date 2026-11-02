import AVFoundation

/// The audio for a session: Claude's voice, and your microphone.
///
/// Hands-free calls run the mic through Apple's voice processing (the same one FaceTime uses):
/// echo cancellation, noise suppression and automatic gain, so you can talk at a normal volume.
/// Claude's voice plays through the same engine, which is what lets the echo canceller remove
/// it from the mic, so you can interrupt Claude.
///
/// Hold-to-talk sessions play through an engine with no mic at all, and open the mic in a
/// separate engine only while you hold the keys (`startMic` / `stopMic`).
@MainActor
final class AudioIO {
    private(set) var engine = AVAudioEngine()
    private(set) var player = AVAudioPlayerNode()
    private var sfx = AVAudioPlayerNode()     // interface sounds, mixed with the voice
    let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    /// Receives mic audio. Called on the audio thread.
    let micRelay = MicRelay()
    private(set) var running = false
    private var micEngine: AVAudioEngine?
    private var engineHasMic = false
    var micOn: Bool { micEngine != nil }

    /// Whether echo cancellation is active (false if voice processing couldn't start).
    private(set) var voiceProcessing = false

    /// `mic`: also listen through this engine, with echo cancellation (hands-free calls).
    func start(mic: Bool = true) throws {
        guard !running else { return }
        // A fresh engine each time: one that ever had a mic would open it again on start.
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        sfx = AVAudioPlayerNode()
        engineHasMic = mic
        if !mic {
            try configure(voiceProcessing: false, mic: false)
            try engine.start()
            voiceProcessing = false
            running = true
            return
        }
        do {
            try configure(voiceProcessing: true, mic: true)
            try engine.start()
            voiceProcessing = true
        } catch {
            // Some devices (certain headsets, aggregate devices) can't do voice processing:
            // fall back to the plain microphone rather than failing the call.
            NSLog("Poinky: voice processing failed (\(error.localizedDescription)), using the plain microphone")
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            sfx = AVAudioPlayerNode()
            try configure(voiceProcessing: false, mic: true)
            try engine.start()
            voiceProcessing = false
        }
        running = true
    }

    /// Plays an interface sound through this engine (returns false if the engine isn't running).
    @discardableResult
    func playSound(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard running, engine.isRunning else { return false }
        sfx.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !sfx.isPlaying { sfx.play() }
        return true
    }

    /// Opens the microphone (hold-to-talk). Its audio goes to `micRelay`.
    func startMic() throws {
        guard micEngine == nil else { return }
        let e = AVAudioEngine()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw BrainError("No microphone input found.")
        }
        let relay = micRelay
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            relay.deliver(buffer)
        }
        e.prepare()
        try e.start()
        micEngine = e
    }

    func stopMic() {
        guard let e = micEngine else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        micEngine = nil
    }

    private func configure(voiceProcessing: Bool, mic: Bool) throws {
        if mic { _ = engine.inputNode }   // same order as always: input, output, mixer, then voice processing
        // Order matters: create the speaker side of the engine *before* turning on voice
        // processing, and read its format before linking the mixer. Otherwise the engine
        // fails to start (error -10875).
        _ = engine.outputNode
        _ = engine.mainMixerNode
        if voiceProcessing {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            // Don't turn down other apps (videos, music) while we listen.
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: true, duckingLevel: .min)
        }
        let speakerFormat = engine.outputNode.inputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: speakerFormat)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        engine.attach(sfx)
        engine.connect(sfx, to: engine.mainMixerNode, format: Earcons.format)
        guard mic else { engine.prepare(); return }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw BrainError("No microphone input found.")
        }
        let relay = micRelay
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            relay.deliver(buffer)
        }
        engine.prepare()
    }

    func stop() {
        stopMic()
        guard running else { return }
        player.stop()
        sfx.stop()
        if engineHasMic {
            engine.inputNode.removeTap(onBus: 0)
            try? engine.inputNode.setVoiceProcessingEnabled(false)
        }
        engine.stop()
        engineHasMic = false
        micRelay.dropEarly()
        running = false
    }
}

/// Thread-safe hand-off of mic buffers from the audio thread to whoever listens.
/// Audio that arrives before anyone listens (the speech engine is still starting) is kept
/// for a few seconds and handed over when they do, so your first words aren't lost.
final class MicRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var target: ((AVAudioPCMBuffer) -> Void)?
    private var early: [AVAudioPCMBuffer] = []
    private var earlyFrames: AVAudioFrameCount = 0

    func set(_ t: ((AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        target = t
        let backlog = t == nil ? [] : early
        early.removeAll()
        earlyFrames = 0
        lock.unlock()
        if let t { for b in backlog { t(b) } }
    }

    /// Forget audio that was waiting for a listener (it belongs to a session that ended).
    func dropEarly() {
        lock.lock(); early.removeAll(); earlyFrames = 0; lock.unlock()
    }

    func deliver(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let t = target else {
            // Keep up to ~8 s while waiting for a listener.
            if earlyFrames < AVAudioFrameCount(buffer.format.sampleRate * 8), let copy = buffer.copy() as? AVAudioPCMBuffer {
                early.append(copy)
                earlyFrames += buffer.frameLength
            }
            lock.unlock()
            return
        }
        lock.unlock()
        t(buffer)
    }
}
