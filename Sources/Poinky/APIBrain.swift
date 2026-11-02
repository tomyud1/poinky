import Foundation

/// Brain #2: calls the Anthropic Messages API directly (streaming). Fastest option,
/// but billed per use to an API key, separate from your Claude subscription.
@MainActor
final class APIBrain: Brain {
    let displayName = "Anthropic API"

    private let model: String
    private let apiKey: String
    private let systemPrompt: String
    private var history: [[String: Any]] = []
    private let session = URLSession(configuration: .ephemeral)
    private let maxTokens: Int
    private var busy = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// How many recent turns keep their screenshot. Older ones are swapped for a short note.
    private let keepImages = 2

    private let effort: String

    /// `effort` "" keeps it fast (low effort, and no thinking on Haiku); a level lets it think that much.
    init(model: String, effort: String = "", apiKey: String, systemPrompt: String, maxTokens: Int) {
        self.effort = AppConfig.efforts.contains(effort) ? effort : ""
        self.maxTokens = maxTokens
        self.model = model
        self.apiKey = apiKey
        self.systemPrompt = systemPrompt
    }

    func warmUp() async throws {}

    func stop() { history.removeAll() }

    func ask(_ question: BrainQuestion, onText: @escaping (String) -> Void) async throws -> String {
        // One question at a time, so the conversation history stays in order.
        while busy {
            await withCheckedContinuation { idleWaiters.append($0) }
            try Task.checkCancellation()
        }
        busy = true
        defer {
            busy = false
            let w = idleWaiters
            idleWaiters.removeAll()
            w.forEach { $0.resume() }
        }
        history.append(["role": "user",
                        "content": question.imageBlocks + [["type": "text", "text": question.text]]])
        trimOldImages()

        do {
            let full = try await stream(onText: onText)
            history.append(["role": "assistant",
                            "content": [["type": "text", "text": full.isEmpty ? "(no reply)" : full]]])
            return full
        } catch {
            history.removeLast() // keep user/assistant turns alternating
            throw error
        }
    }

    private func stream(onText: @escaping (String) -> Void) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": systemPrompt,
            "messages": history,
            "output_config": ["effort": effort.isEmpty ? "low" : effort],
        ]
        // Automatic: Haiku can skip thinking entirely (faster). Other current models don't accept that, so leave it to them.
        if effort.isEmpty && model.contains("haiku") { body["thinking"] = ["type": "disabled"] }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 300

        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw BrainError("No response from the API.") }
        if http.statusCode != 200 {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            throw BrainError("API error \(http.statusCode): \(Self.errorMessage(raw))")
        }

        var full = ""
        var stopReason: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let ev = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            switch ev["type"] as? String {
            case "content_block_delta":
                if let delta = ev["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let t = delta["text"] as? String {
                    full += t
                    onText(t)
                }
            case "message_delta":
                stopReason = (ev["delta"] as? [String: Any])?["stop_reason"] as? String
            case "error":
                let msg = (ev["error"] as? [String: Any])?["message"] as? String
                throw BrainError(msg ?? "The API stream reported an error.")
            default:
                break
            }
        }
        if stopReason == "refusal" && full.isEmpty {
            throw BrainError("Claude declined to answer that one.")
        }
        return full
    }

    private func trimOldImages() {
        var seen = 0
        for i in history.indices.reversed() {
            guard history[i]["role"] as? String == "user",
                  var content = history[i]["content"] as? [[String: Any]] else { continue }
            guard content.contains(where: { $0["type"] as? String == "image" }) else { continue }
            seen += 1
            if seen > keepImages {
                content = content.map { $0["type"] as? String == "image"
                    ? ["type": "text", "text": "[older screenshot removed]"] : $0 }
                history[i]["content"] = content
            }
        }
    }

    private static func errorMessage(_ raw: String) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
           let err = obj["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
        return String(raw.prefix(300))
    }
}
