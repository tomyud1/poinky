import AVFoundation
import CoreAudio

/// Loudness of a stretch of audio in dBFS, the way speech recognition cares about it.
struct AudioLevels: Codable, Equatable {
    var peak: Float        // loudest sample
    var rms: Float         // whole stretch
    var speech: Float      // the loudest 30 % of 20 ms windows: how loud the voice itself is
    var floor: Float       // the quietest 10 % of windows: the room
    var seconds: Double

    static let silent = AudioLevels(peak: -120, rms: -120, speech: -120, floor: -120, seconds: 0)

    static func db(_ x: Float) -> Float { 20 * log10(max(x, 1e-6)) }

    static func measure(_ s: UnsafeBufferPointer<Float>, rate: Double) -> AudioLevels {
        guard !s.isEmpty else { return .silent }
        let window = max(1, Int(rate * 0.02))
        var windows: [Float] = []
        windows.reserveCapacity(s.count / window + 1)
        var peak: Float = 0, total: Double = 0
        var i = 0
        while i < s.count {
            let end = min(s.count, i + window)
            var sum: Float = 0
            for j in i..<end { let v = s[j]; sum += v * v; peak = max(peak, abs(v)) }
            total += Double(sum)
            windows.append(sum / Float(end - i))
            i = end
        }
        let sorted = windows.sorted()
        func meanDB(_ part: ArraySlice<Float>) -> Float {
            part.isEmpty ? -120 : db((part.reduce(0, +) / Float(part.count)).squareRoot())
        }
        let top = sorted.suffix(max(1, sorted.count * 3 / 10))
        let bottom = sorted.prefix(max(1, sorted.count / 10))
        return AudioLevels(peak: db(peak), rms: db(Float(total / Double(s.count)).squareRoot()),
                           speech: meanDB(top), floor: meanDB(bottom), seconds: Double(s.count) / rate)
    }

    static func measure(_ samples: [Float], rate: Double) -> AudioLevels {
        samples.withUnsafeBufferPointer { measure($0, rate: rate) }
    }

    var line: String {
        String(format: "speech %.0f dBFS, peak %.0f, room %.0f", speech, peak, floor)
    }
}

/// What the input device is (for logs and the mic check).
enum InputDevice {
    /// The name of the default input device ("MacBook Air Microphone", "AirPods Pro"…).
    static var name: String {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return "?" }
        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        addr.mSelector = kAudioObjectPropertyName
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "?" }
        return n.takeRetainedValue() as String
    }

    /// The input volume macOS applies (System Settings → Sound → Input), 0…1, if the device has one.
    static var volume: Float? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        var v: Float32 = 0
        size = UInt32(MemoryLayout<Float32>.size)
        addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                          mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr { return v }
        addr.mElement = 1
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr { return v }
        return nil
    }
}

/// `POINKY_MIC_WAV=<dir>`: for each question, writes what the mic delivered (`<n>-raw.wav`, every channel, as it
/// came), what the speech engine got (`<n>-engine.wav`, after the channel pick, any gain and the conversion), and
/// `<n>.json`: formats and rates at each hop, the device, whether voice processing / AGC was on, and the levels.
/// For debugging only (it writes on a background queue); never on unless the variable is set.
final class MicDebug: @unchecked Sendable {
    static let shared = MicDebug()
    let dir: URL? = ProcessInfo.processInfo.environment["POINKY_MIC_WAV"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    var enabled: Bool { dir != nil }

    private let queue = DispatchQueue(label: "poinky.micdebug")
    private var n = 0
    private var raw: AVAudioFile?
    private var engine: AVAudioFile?
    private var rawSamples: [Float] = []
    private var engineSamples: [Float] = []
    private var rawRate = 0.0, engineRate = 0.0
    private var info: [String: Any] = [:]
    /// Set by AudioIO when it opens a mic.
    var micInfo: [String: Any] = [:]

    /// A new question starts (the keys went down, or a hands-free question was sent).
    func begin(_ why: String) {
        guard let dir else { return }
        let mic = micInfo
        queue.async { [self] in
            close()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            n += 1
            info = ["why": why, "started": ISO8601DateFormatter().string(from: Date()), "device": InputDevice.name,
                    "inputVolume": InputDevice.volume.map { Double($0) } ?? NSNull()].merging(mic) { a, _ in a }
        }
    }

    /// The question is over: write the levels next to the recordings.
    func end(text: String? = nil) {
        guard enabled else { return }
        queue.async { [self] in
            if let text { info["text"] = text }
            close()
        }
    }

    func note(_ key: String, _ value: Any) {
        guard enabled else { return }
        queue.async { [self] in info[key] = value }
    }

    func raw(_ b: AVAudioPCMBuffer) {
        guard enabled, let copy = b.copy() as? AVAudioPCMBuffer else { return }
        queue.async { [self] in
            guard let dir, n > 0 else { return }
            if raw == nil || raw?.processingFormat != copy.format {
                raw = try? AVAudioFile(forWriting: dir.appendingPathComponent("\(n)-raw.wav"), settings: copy.format.settings,
                                       commonFormat: copy.format.commonFormat, interleaved: copy.format.isInterleaved)
                rawRate = copy.format.sampleRate
                info["rawFormat"] = "\(copy.format)"
            }
            try? raw?.write(from: copy)
            if let ch = copy.floatChannelData?[0] { rawSamples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(copy.frameLength))) }
            if copy.format.channelCount > 1, let data = copy.floatChannelData, info["channels"] == nil {
                // Which channels carry anything (with voice processing, only channel 0 should).
                info["channels"] = (0..<Int(copy.format.channelCount)).map { c in
                    Double(AudioLevels.measure(UnsafeBufferPointer(start: data[c], count: Int(copy.frameLength)), rate: copy.format.sampleRate).rms)
                }
            }
        }
    }

    func engine(_ b: AVAudioPCMBuffer, gain: Float) {
        guard enabled, let copy = b.copy() as? AVAudioPCMBuffer else { return }
        queue.async { [self] in
            guard let dir, n > 0 else { return }
            if engine == nil {
                engine = try? AVAudioFile(forWriting: dir.appendingPathComponent("\(n)-engine.wav"), settings: copy.format.settings,
                                          commonFormat: copy.format.commonFormat, interleaved: copy.format.isInterleaved)
                engineRate = copy.format.sampleRate
                info["engineFormat"] = "\(copy.format)"
            }
            try? engine?.write(from: copy)
            info["gainDB"] = Double(AudioLevels.db(gain))
            if let ch = copy.floatChannelData?[0] {
                engineSamples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(copy.frameLength)))
            } else if let ch = copy.int16ChannelData?[0] {
                engineSamples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(copy.frameLength)).map { Float($0) / 32768 })
            }
        }
    }

    private func close() {
        guard let dir, n > 0, raw != nil || engine != nil || !info.isEmpty else { return }
        func levels(_ l: AudioLevels) -> [String: Double] {
            ["peak": Double(l.peak), "rms": Double(l.rms), "speech": Double(l.speech), "floor": Double(l.floor), "seconds": l.seconds]
        }
        if !rawSamples.isEmpty { info["rawLevels"] = levels(AudioLevels.measure(rawSamples, rate: rawRate)) }
        if !engineSamples.isEmpty { info["engineLevels"] = levels(AudioLevels.measure(engineSamples, rate: engineRate)) }
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("\(n).json"))
        }
        raw = nil; engine = nil; rawSamples = []; engineSamples = []; info = [:]
    }
}
