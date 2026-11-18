import AVFoundation
import FluidAudio
import Foundation

// Poinky's local speech recognizer, a helper process (like the voice, phonon_server.py): JSON lines in and out.
//
//   in:  {"load": "<model folder>", "version": "v2"}           → {"ready": true, "ms": 330}   (or {"error": "…"})
//   in:  {"id": 7, "samples": N}  then N float32 samples (16 kHz mono, little-endian)
//                                                               → {"id": 7, "text": "…", "ms": 52, "conf": 0.93}
//   in:  {"ping": 1}                                            → {"pong": 1}
// It exits when its input closes (Poinky quit or ended the session).

final class Input {
    private let h = FileHandle.standardInput
    private var buf = Data()
    func fill() -> Bool {
        let d = h.availableData
        if d.isEmpty { return false }
        buf.append(d)
        return true
    }
    func line() -> Data? {
        while true {
            if let i = buf.firstIndex(of: 0x0A) {
                let l = buf[buf.startIndex..<i]
                buf = Data(buf[(i + 1)...])
                return Data(l)
            }
            if !fill() { return nil }
        }
    }
    func bytes(_ n: Int) -> Data? {
        while buf.count < n { if !fill() { return nil } }
        let d = buf.prefix(n)
        buf = Data(buf.dropFirst(n))
        return Data(d)
    }
}

func send(_ o: [String: Any]) {
    var d = (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
    d.append(0x0A)
    FileHandle.standardOutput.write(d)
}

func run() async {
    let input = Input()
    var asr: AsrManager?
    while let line = input.line() {
        guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
        if msg["ping"] != nil { send(["pong": 1]); continue }
        if let folder = msg["load"] as? String {
            let t = Date()
            do {
                let version: AsrModelVersion = (msg["version"] as? String) == "v3" ? .v3 : .v2
                let models = try await AsrModels.load(from: URL(fileURLWithPath: folder), version: version)
                let m = AsrManager()
                try await m.loadModels(models)
                // Warm the Neural Engine once, so the first question isn't slower.
                var st = TdtDecoderState.make(decoderLayers: await m.decoderLayerCount)
                _ = try? await m.transcribe([Float](repeating: 0, count: 16_000), decoderState: &st)
                asr = m
                send(["ready": true, "ms": Int(Date().timeIntervalSince(t) * 1000)])
            } catch {
                send(["error": "\(error.localizedDescription)"])
            }
            continue
        }
        if let n = msg["samples"] as? Int {
            let id = msg["id"] ?? 0
            guard let data = input.bytes(n * 4) else { break }
            guard let asr else { send(["id": id, "error": "no model loaded"]); continue }
            var samples = [Float](repeating: 0, count: n)
            _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            // Parakeet needs at least a second of audio: pad short answers ("yes") with silence.
            if samples.count < 16_000 { samples += [Float](repeating: 0, count: 16_000 - samples.count) }
            let t = Date()
            do {
                var st = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
                let r = try await asr.transcribe(samples, decoderState: &st)
                send(["id": id, "text": r.text, "ms": Int(Date().timeIntervalSince(t) * 1000), "conf": Double(r.confidence)])
            } catch {
                send(["id": id, "error": "\(error.localizedDescription)"])
            }
        }
    }
}

await run()
