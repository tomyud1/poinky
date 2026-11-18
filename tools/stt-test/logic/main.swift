import AVFoundation

// Always-runnable checks of the speech pieces that need no model or mic (tools/stt-test/check.sh; CI):
// picking the language track, context words from screen text, word errors, levels, trimming, VoiceActivity on
// soft speech, and the local engine's audio window.
enum Timeline { static func log(_ ev: String, _ fields: [String: Any] = [:]) {} }
enum Earcons { static let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)! }
struct BrainError: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }
struct AppConfig {
    var language = "en-US"; var otherLanguages: [String]? = nil; var speechEngine = "auto"
    static var dir: URL { URL(fileURLWithPath: NSTemporaryDirectory()) }
    static func load() -> AppConfig { AppConfig() }
}

var failures = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { failures += 1 } }

@MainActor func main() {
    // Language tracks: Hebrew heard by the English recognizer is English-looking nonsense, and the reverse.
    var en = SpeechListener.Track(); en.committed = "The hash covert ha shmira"; en.confidences = [0.4]
    var he = SpeechListener.Track(); he.committed = "איפה כפתור השמירה"; he.confidences = [0.8]
    check(SpeechPick.best(tracks: [en, he], languages: ["en-US", "he-IL"]) == 1, "a Hebrew question goes out in Hebrew")
    var en2 = SpeechListener.Track(); en2.committed = "Where is the save button?"; en2.confidences = [0.9]
    var he2 = SpeechListener.Track(); he2.committed = "ווייר איז דה סייב"; he2.confidences = [0.5]
    check(SpeechPick.best(tracks: [en2, he2], languages: ["en-US", "he-IL"]) == 0, "an English question stays English")
    check(SpeechPick.best(tracks: [en2], languages: ["en-US"]) == 0, "one language: track 0")
    var heEmpty = SpeechListener.Track(); heEmpty.committed = ""
    check(SpeechPick.best(tracks: [en2, heEmpty], languages: ["en-US", "he-IL"]) == 0, "an empty track never wins")

    // Context words from the screen: names, technical and long words; not the everyday ones.
    let words = SpeechContext.interesting(in: "File Edit View  Bernoulli's equation for the pipe\nSpeechListener.swift finishUtterance() the and Navier-Stokes momentum")
    check(words.contains("Bernoulli's") || words.contains("Bernoulli"), "context: Bernoulli (\(words))")
    check(words.contains("SpeechListener.swift"), "context: a file name")
    check(words.contains("finishUtterance"), "context: an identifier")
    check(words.contains("Navier-Stokes"), "context: Navier-Stokes")
    check(!words.contains("File") && !words.contains("the"), "context: no menu words or 'the'")
    let ctx = SpeechContext(words: ["Mint", "mint", "  Poinky ", "x"], recent: [])
    check(ctx.terms() == ["Mint", "Poinky"], "context terms: once each, trimmed, no one-letter words (\(ctx.terms()))")

    // Word errors (the mic check's verdict).
    check(MicCheck.errors("Where is the save button?", "where is the save button") == 0, "errors: case and punctuation don't count")
    check(MicCheck.errors("Ask Mint to fix the failing build.", "Ask meant to fix the failing build") == 1, "errors: one word wrong")
    check(MicCheck.errors("איפה כפתור השמירה?", "\u{200F}איפה כפתור השמירה") == 0, "errors: Hebrew with a direction mark")
    check(SpeechListener.trimmed("\u{200F}. and how") == "and how", "trimmed: a direction mark and a leftover dot")

    // Levels.
    let tone = (0..<16_000).map { Float(0.1 * sin(Double($0) * 0.2)) }
    let l = AudioLevels.measure(tone, rate: 16_000)
    check(abs(l.rms - (-23)) < 1 && abs(l.peak - (-20)) < 0.5, String(format: "levels of a sine at 0.1: rms %.1f, peak %.1f dBFS", l.rms, l.peak))

    // VoiceActivity: a soft voice (-60 dBFS) over a quiet room (-72) counts as voice; the room alone doesn't.
    let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    func buffer(_ f: (Int) -> Float, _ n: Int = 1024) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!; b.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { b.floatChannelData![0][i] = f(i) }
        return b
    }
    let v = VoiceActivity()
    var t = 0.0, roomVoiced = false, softVoiced = false
    for _ in 0..<40 { roomVoiced = v.process(buffer { _ in Float.random(in: -0.00035...0.00035) }, at: t) || roomVoiced; t += 0.021 }
    for k in 0..<20 { softVoiced = v.process(buffer { i in 0.0014 * Float(sin(Double(i + k * 1024) * 0.05)) + Float.random(in: -0.00035...0.00035) }, at: t) || softVoiced; t += 0.021 }
    check(!roomVoiced, "a quiet room isn't a voice")
    check(softVoiced, "a soft voice at -60 dBFS is a voice")

    // The local model's audio window: from 0.4 s before the first voice.
    let a = Audio16k()
    a.add(buffer({ _ in 0 }, 48_000), voiced: false)          // 1 s of silence
    a.add(buffer({ _ in 0.1 }, 24_000), voiced: true)         // 0.5 s of voice
    let got = a.take()
    check(abs(got.count - (6_400 + 8_000)) < 200, "local model gets 0.4 s before the voice and the voice (\(got.count) samples)")
    check(a.take().isEmpty, "and starts over")

    print(failures == 0 ? "PASS" : "FAIL (\(failures))")
    exit(failures == 0 ? 0 : 1)
}
Task { @MainActor in main() }
RunLoop.main.run()
