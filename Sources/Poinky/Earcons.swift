import AVFoundation

/// The soft interface sounds, made in code (no sound files): a deep "bloop" when you start
/// talking, a two-note ping when your question is sent, and so on.
///
/// During a session they play through the session's own audio engine. That matters in
/// hands-free calls: echo cancellation reconfigures the audio device, and sounds played by
/// anything else at that moment can get lost. Outside a session they use a plain player.
@MainActor
enum Earcons {
    enum Sound: String { case open, send, cancel, start, end }

    static let sampleRate = 48_000.0
    static var format: AVAudioFormat { AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)! }

    private static var cache: [Sound: AVAudioPCMBuffer] = [:]
    private static var players: [AVAudioPlayer] = []

    static func buffer(_ s: Sound) -> AVAudioPCMBuffer? {
        if let b = cache[s] { return b }
        let samples = render(s)
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in b.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
        cache[s] = b
        return b
    }

    /// Plays without an engine (before a session starts, or after it ended).
    static func playStandalone(_ s: Sound) {
        guard let b = buffer(s) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poinky-\(s.rawValue).caf")
        if !FileManager.default.fileExists(atPath: url.path) {
            guard let f = try? AVAudioFile(forWriting: url, settings: format.settings) else { return }
            try? f.write(from: b)
        }
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        players.removeAll { !$0.isPlaying }
        players.append(p)
        p.play()
    }

    // MARK: - Synthesis

    private struct Note { let at: Double; let f0: Double; let f1: Double; let dur: Double; let gain: Double; let triangle: Bool }

    private static func notes(_ s: Sound) -> [Note] {
        switch s {
        case .open:   // a soft, deep "bloop" up
            return [Note(at: 0, f0: 196, f1: 294, dur: 0.28, gain: 0.30, triangle: false),
                    Note(at: 0, f0: 392, f1: 588, dur: 0.18, gain: 0.07, triangle: false)]
        case .send:   // a gentle two-note ping, with a low body under it
            return [Note(at: 0, f0: 587, f1: 587, dur: 0.35, gain: 0.11, triangle: true),
                    Note(at: 0.075, f0: 880, f1: 880, dur: 0.5, gain: 0.10, triangle: true),
                    Note(at: 0, f0: 147, f1: 147, dur: 0.3, gain: 0.14, triangle: false)]
        case .cancel: // nothing was heard: a soft step down
            return [Note(at: 0, f0: 330, f1: 220, dur: 0.25, gain: 0.12, triangle: false)]
        case .start:  // a call started
            return [Note(at: 0, f0: 196, f1: 196, dur: 0.7, gain: 0.20, triangle: false),
                    Note(at: 0.06, f0: 392, f1: 392, dur: 0.55, gain: 0.09, triangle: true),
                    Note(at: 0.12, f0: 784, f1: 784, dur: 0.6, gain: 0.05, triangle: true)]
        case .end:    // the session ended
            return [Note(at: 0, f0: 523, f1: 523, dur: 0.3, gain: 0.08, triangle: true),
                    Note(at: 0.09, f0: 262, f1: 196, dur: 0.5, gain: 0.17, triangle: false)]
        }
    }

    private static func render(_ s: Sound) -> [Float] {
        let ns = notes(s)
        let tail = 0.35   // room for the echo
        let total = (ns.map { $0.at + $0.dur }.max() ?? 0.5) + tail
        var out = [Float](repeating: 0, count: Int(total * sampleRate))
        for n in ns {
            let start = Int(n.at * sampleRate), count = Int(n.dur * sampleRate)
            let glide = min(0.12, n.dur * 0.4)
            var phase = 0.0
            for i in 0..<count where start + i < out.count {
                let t = Double(i) / sampleRate
                // Pitch glides exponentially from f0 to f1, then holds.
                let f = t < glide ? n.f0 * pow(n.f1 / n.f0, t / glide) : n.f1
                phase += 2 * .pi * f / sampleRate
                let wave = n.triangle ? (2 / .pi) * asin(sin(phase)) : sin(phase)
                // Quick (12 ms) attack, exponential fade to silence by the end.
                let env = t < 0.012 ? t / 0.012 : pow(0.0001, (t - 0.012) / max(0.01, n.dur - 0.012))
                out[start + i] += Float(wave * env * n.gain)
            }
        }
        // A soft room: a few quiet, darker echoes.
        let d = Int(0.085 * sampleRate)
        var echo = out
        for tap in 1...3 {
            let g = Float(pow(0.28, Double(tap)) * 0.9)
            var lp: Float = 0
            for i in (d * tap)..<out.count {
                lp += (out[i - d * tap] - lp) * 0.25   // gentle low-pass
                echo[i] += lp * g
            }
        }
        // Keep it from clipping.
        let peak = echo.map { abs($0) }.max() ?? 1
        if peak > 0.9 { let k = 0.9 / peak; for i in echo.indices { echo[i] *= k } }
        return echo
    }
}
