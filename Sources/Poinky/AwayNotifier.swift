import AppKit

/// Away mode (opt-in): when you're away from the Mac (screen locked, or no keyboard or mouse for a few
/// minutes) and a helper needs your OK or asks a question, a notification goes to your phone through
/// ntfy (the free ntfy app, or your own ntfy server), with buttons to answer.
///
/// The buttons post your answer to a second topic that Poinky listens to while something is waiting.
/// Both topics are random and private to you; each answer must carry a one-time code made for that one
/// request, so it can only answer the request it was sent for.
@MainActor
final class AwayNotifier: NSObject, URLSessionDataDelegate {
    /// Your answer from the phone: the helper, the request, and yes or no (or a choice).
    var onAnswer: ((_ agent: Int, _ requestID: String, _ reply: HelperAsk.Reply) -> Void)?
    /// For tests: pretend you're away.
    var forceAway = false

    private var config = AppConfig()
    /// Sent and not answered yet: request id → (helper, code, the request).
    private var pending: [String: (agent: Int, code: String, ask: HelperAsk)] = [:]
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var since = 0

    func settings(_ c: AppConfig) {
        config = c
        if !c.awayNotify { pending.removeAll(); stopListening() }
    }

    /// Away: the screen is locked, or no key or mouse for `awayMinutes`.
    var isAway: Bool {
        if forceAway { return true }
        if CallController.screenLocked() { return true }
        let idle = [CGEventType.keyDown, .mouseMoved, .leftMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
        return idle > max(1, config.awayMinutes) * 60
    }

    var enabled: Bool { config.awayNotify && !config.ntfyTopic.isEmpty }

    /// A helper needs you: tell your phone if you're away.
    func asking(_ a: AgentManager.Agent, _ ask: HelperAsk) {
        guard enabled, isAway, pending[ask.requestID] == nil else { return }
        let code = Self.randomCode(10)
        pending[ask.requestID] = (a.id, code, ask)
        let reply = replyTopicURL
        var actions: [String] = []
        func action(_ label: String, _ body: String) {
            actions.append("http, \(label.replacingOccurrences(of: ",", with: " ")), \(reply), method=POST, body=\(body), clear=true")
        }
        let title: String, message: String
        if ask.kind == .question, let q = ask.currentQuestion {
            title = "\(a.name) asks"
            message = q.text
            for (k, o) in q.options.prefix(2).enumerated() { action(o, "pick \(ask.requestID) \(code) \(k)") }
            action("You choose", "pick \(ask.requestID) \(code) any")
        } else {
            title = "\(a.name) needs your OK"
            message = ask.bubble + (config.awayDetails && ask.detail != ask.bubble ? "\n\(HelperStream.clip(ask.detail, 300))" : "")
            action(ask.isPlan ? "Go ahead" : "Allow", "yes \(ask.requestID) \(code)")
            action(ask.isPlan ? "Not now" : "Don't allow", "no \(ask.requestID) \(code)")
        }
        guard let url = URL(string: topicURL) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data((config.awayDetails ? message : "A helper is waiting for you.").utf8)
        req.setValue(config.awayDetails ? title : "Poinky", forHTTPHeaderField: "Title")
        req.setValue("raised_hand", forHTTPHeaderField: "Tags")
        req.setValue("high", forHTTPHeaderField: "Priority")
        req.setValue(actions.joined(separator: "; "), forHTTPHeaderField: "Actions")
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err { NSLog("Poinky: phone notification failed: \(err.localizedDescription)") }
            else if let h = resp as? HTTPURLResponse, h.statusCode >= 300 { NSLog("Poinky: phone notification failed: HTTP \(h.statusCode)") }
        }.resume()
        listen()
    }

    /// What's still open (answered here or withdrawn: the phone's buttons no longer count).
    func stillOpen(_ ids: Set<String>) {
        pending = pending.filter { ids.contains($0.key) }
        if pending.isEmpty { stopListening() }
    }

    /// Settings → "Send a test notification".
    func test(_ c: AppConfig, done: @escaping @Sendable (String?) -> Void) {
        guard !c.ntfyTopic.isEmpty, let url = URL(string: c.ntfyServer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + c.ntfyTopic) else { done("Turn it on first."); return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data("This is how Poinky reaches you when a helper needs your OK while you're away.".utf8)
        req.setValue("Poinky test", forHTTPHeaderField: "Title")
        URLSession.shared.dataTask(with: req) { _, resp, err in
            if let err { done(err.localizedDescription); return }
            if let h = resp as? HTTPURLResponse, h.statusCode >= 300 { done("The server said \(h.statusCode).") } else { done(nil) }
        }.resume()
    }

    // MARK: - Listening for answers

    private var base: String { config.ntfyServer.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    private var topicURL: String { base + "/" + config.ntfyTopic }
    private var replyTopicURL: String { base + "/" + config.ntfyTopic + "-reply" }

    private func listen() {
        guard task == nil, let url = URL(string: replyTopicURL + "/json?since=\(Int(Date().timeIntervalSince1970) - 5)") else { return }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 3600
        cfg.timeoutIntervalForResource = 24 * 3600
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        session = s
        buffer.removeAll()
        task = s.dataTask(with: url)
        task?.resume()
    }

    private func stopListening() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated {
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["event"] as? String == "message", let m = obj["message"] as? String else { continue }
                received(m)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard self.session === session else { return }
            self.task = nil
            self.session = nil
            // Dropped while something still waits: listen again in a moment.
            if !pending.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.listen() } }
        }
    }

    /// "yes <request> <code>", "no <request> <code>", "pick <request> <code> <n|any>".
    func received(_ message: String) {
        let w = message.split(separator: " ").map(String.init)
        guard w.count >= 3, let p = pending[w[1]], Self.same(p.code, w[2]) else { return }
        let reply: HelperAsk.Reply
        switch w[0] {
        case "yes": reply = .yes(always: false, extra: "")
        case "no": reply = .no(reason: "")
        case "pick":
            if w.count > 3, let k = Int(w[3]), let q = p.ask.currentQuestion, k < q.options.count { reply = .answer(q.options[k]) }
            else { reply = .answer("No preference: you choose.") }
        default: return
        }
        pending[w[1]] = nil
        if pending.isEmpty { stopListening() }
        onAnswer?(p.agent, w[1], reply)
    }

    static func randomCode(_ n: Int) -> String {
        let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
        var g = SystemRandomNumberGenerator()
        return String((0..<n).map { _ in chars[Int(g.next() % UInt64(chars.count))] })
    }

    /// Compares two codes without stopping at the first difference.
    private static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in 0..<x.count { d |= x[i] ^ y[i] }
        return d == 0
    }
}
