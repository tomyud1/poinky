import AVFoundation
import Speech

// Drives the app's real SpeechListener (and AudioIO's MicRelay) with speech made by `say`, at real-time pace,
// the way the mic would: holds (clearText → audio → finishUtterance) and a hands-free call (pauses end questions).
// No microphone, no permissions dialog. Built and run by tools/test-listener.sh.

enum Timeline { static func log(_ ev: String, _ fields: [String: Any] = [:]) {} }
enum Earcons { static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)! }
struct BrainError: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }

let dir = CommandLine.arguments[1]
var failures = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { failures += 1 } }
func norm(_ s: String) -> String {
    s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
}
func load(_ name: String) -> AVAudioPCMBuffer {
    let f = try! AVAudioFile(forReading: URL(fileURLWithPath: dir + "/" + name + ".wav"))
    let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try! f.read(into: b)
    return b
}

@MainActor
final class Run {
    let audio = AudioIO()
    let listener = SpeechListener()
    var partials: [(t: TimeInterval, text: String)] = []
    var utterances: [(t: TimeInterval, text: String)] = []
    let t0 = ProcessInfo.processInfo.systemUptime
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime - t0 }
    let format: AVAudioFormat

    init(like b: AVAudioPCMBuffer) {
        format = b.format
        listener.onPartial = { [unowned self] t in partials.append((now, t)) }
        listener.onUtterance = { [unowned self] t in utterances.append((now, t)) }
    }

    /// Plays a buffer into the mic relay in 1024-frame pieces, in real time (like the input tap).
    func play(_ b: AVAudioPCMBuffer) async {
        var off: AVAudioFrameCount = 0
        while off < b.frameLength {
            let n = min(1024, b.frameLength - off)
            let chunk = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: n)!
            chunk.frameLength = n
            memcpy(chunk.floatChannelData![0], b.floatChannelData![0] + Int(off), Int(n) * 4)
            off += n
            audio.micRelay.deliver(chunk)
            try? await Task.sleep(nanoseconds: UInt64(Double(n) / b.format.sampleRate * 1e9))
        }
    }
    func quiet(_ secs: Double) async {
        let n = AVAudioFrameCount(secs * format.sampleRate)
        let s = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
        s.frameLength = n
        for i in 0..<Int(n) { s.floatChannelData![0][i] = Float.random(in: -0.0004...0.0004) }   // room noise
        await play(s)
    }

    /// One hold: press, a moment, the words, the 0.18 s the app keeps the mic open after you let go, then finish.
    func hold(_ name: String, expect: String) async {
        listener.clearText()
        partials.removeAll()
        await quiet(0.25)
        let speechAt = now
        await play(load(name))
        let releasedAt = now
        await quiet(0.18)
        let text = await listener.finishUtterance()
        let before = partials.filter { $0.t < releasedAt }
        let first = before.first.map { String(format: "%.2f s", $0.t - speechAt) } ?? "never"
        print("     \(name): \(before.count) live updates while holding, first \(first) after speaking; sent \"\(text)\" \(String(format: "%.2f", now - releasedAt)) s after letting go")
        if name == "yes" {
            // One short word is over before any engine has a result: it shows as you let go.
            let shownAt = partials.first.map { $0.t - releasedAt } ?? 99
            check(shownAt < 0.4, "hold “\(expect)”: a one-word answer shows as you let go (\(String(format: "%.2f", shownAt)) s)")
        } else {
            check(!before.isEmpty, "hold “\(expect)”: your words show while you hold the keys")
            check(before.count >= 3, "hold “\(expect)”: the words keep up while you talk (\(before.count) updates)")
            check((before.first?.t ?? 99) - speechAt < 0.9, "hold “\(expect)”: the first words show within 0.9 s (\(first))")
        }
        check(text.first?.isLetter == true && norm(text) == norm(expect), "hold “\(expect)”: the question sent is what was said (\"\(text)\")")
        try? await Task.sleep(nanoseconds: 1_200_000_000)   // between holds the mic is off
    }
}

@MainActor
func main() async {
    let q1 = load("q1")
    // Hold to talk.
    do {
        let r = Run(like: q1)
        r.listener.autoEnd = false
        do { try await r.listener.start(audio: r.audio, language: "en-US") } catch { print("FAIL couldn't start: \(error)"); exit(1) }
        print("— hold to talk")
        await r.hold("q1", expect: "What is this button for?")
        await r.hold("yes", expect: "Yes")
        await r.hold("q2", expect: "And how do I turn it off?")
        r.listener.stop()
    }
    // A hands-free call: a pause ends each question; the next question comes after Claude's answer (silence here).
    for gap in [1.2, 5.0] {
        let r = Run(like: q1)
        r.listener.autoEnd = true
        r.listener.silenceSeconds = 0.7
        do { try await r.listener.start(audio: r.audio, language: "en-US") } catch { print("FAIL couldn't start: \(error)"); exit(1) }
        print("— hands-free, \(gap) s between questions")
        await r.quiet(0.3)
        await r.play(q1)
        await r.quiet(gap)
        let q2At = r.now
        await r.play(load("q2"))
        await r.quiet(2.5)
        let said = r.utterances.map { $0.text }
        print("     questions: \(said)")
        check(said.count == 2, "hands-free (\(gap) s): two questions")
        check(said.first.map(norm) == norm("What is this button for?"), "hands-free (\(gap) s): the first question")
        check(said.count > 1 && said[1].first?.isLetter == true && norm(said[1]) == norm("And how do I turn it off?"), "hands-free (\(gap) s): the second question is heard too")
        let live = r.partials.filter { $0.t > q2At && $0.t < (r.utterances.dropFirst().first?.t ?? 99) && norm($0.text).contains("how") }
        check(!live.isEmpty, "hands-free (\(gap) s): the second question's words show while you talk")
        r.listener.stop()
    }
    print(failures == 0 ? "PASS" : "FAIL (\(failures))")
    exit(failures == 0 ? 0 : 1)
}

Task { @MainActor in await main() }
RunLoop.main.run()
