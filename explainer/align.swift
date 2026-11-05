// Word timings for an audio file, using Apple's on-device SpeechTranscriber.
// Usage: align <audio file>  → prints a JSON array of {"w": word, "start": s, "end": s}
// The explainer pipeline runs it on its own narration, so visuals can be tied to spoken words.
import AVFoundation
import Foundation
import Speech

@main struct Align {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let t = SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [],
                                  reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) { try await req.downloadAndInstall() }
        let analyzer = SpeechAnalyzer(modules: [t])
        let reader = Task { () -> [[String: Any]] in
            var words: [[String: Any]] = []
            for try await r in t.results {
                for run in r.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let w = String(r.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if w.isEmpty { continue }
                    words.append(["w": w, "start": range.start.seconds, "end": CMTimeRangeGetEnd(range).seconds])
                }
            }
            return words
        }
        let file = try AVAudioFile(forReading: url)
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let words = try await reader.value
        let data = try JSONSerialization.data(withJSONObject: words)
        FileHandle.standardOutput.write(data)
    }
}
