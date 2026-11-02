import AVFoundation

/// Tells speech from silence using the microphone level, with a noise floor that adapts to
/// the room. Used to decide when you've actually stopped talking: the transcript alone can
/// pause for a moment while you're still mid-sentence.
final class VoiceActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var noiseFloor: Float = -60      // dBFS, adapts to the room
    private var lastVoice: TimeInterval = 0
    private var measured = false
    private var lastLevel: Float = 0

    /// How loud the voice is right now, 0…1 (relative to the room's noise).
    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return lastLevel
    }

    /// Seconds since the mic last heard a voice, or nil if no audio has been measured yet.
    var secondsSinceVoice: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard measured else { return nil }
        return ProcessInfo.processInfo.systemUptime - lastVoice
    }

    /// Call with each mic buffer (channel 0 is used). Safe to call from the audio thread.
    func process(_ buffer: AVAudioPCMBuffer, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        let window = max(1, Int(buffer.format.sampleRate * 0.02))   // 20 ms
        var voiced = false
        var peak: Float = -120
        lock.lock()
        var i = 0
        while i < n {
            let end = min(n, i + window)
            var sum: Float = 0
            for j in i..<end { sum += ch[j] * ch[j] }
            let db = 20 * log10(max((sum / Float(end - i)).squareRoot(), 1e-7))
            // The floor drops quickly to quiet moments and rises slowly (≈0.5 dB/s) in noisy rooms.
            if db < noiseFloor { noiseFloor = noiseFloor * 0.7 + db * 0.3 } else { noiseFloor += 0.01 }
            if db > max(noiseFloor + 12, -55) { voiced = true }
            peak = max(peak, db)
            i = end
        }
        if voiced { lastVoice = time }
        lastLevel = max(0, min(1, (peak - max(noiseFloor, -70)) / 35))
        if !measured { measured = true; if !voiced { lastVoice = time } }
        lock.unlock()
    }

    func reset() {
        lock.lock(); measured = false; lock.unlock()
    }
}
