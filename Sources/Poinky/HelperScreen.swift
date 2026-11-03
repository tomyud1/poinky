import AppKit

/// Shows helpers (background agents) on screen: turns `AgentManager`'s callbacks into the
/// overlay's helper calls (web/helpers-app.js). The overlay does the drawing and the sounds.
///
/// While helpers are on screen it also tells them where the window you're using is (they work
/// at the edge with more room beside it), and handles the buttons on their cards.
@MainActor
final class HelperScreen {
    private let overlay: Overlay
    private weak var agents: AgentManager?
    private var windowTimer: Timer?
    /// The request each helper is showing (its hand is up for it), by helper id.
    private var shownAsk: [Int: String] = [:]
    /// A click on a helper card's Allow / Don't allow (or You choose / Skip) button: id, yes.
    var onCardAnswer: ((Int, Bool) -> Void)?
    /// Open on its card: its window.
    var onOpen: ((Int) -> Void)?

    init(overlay: Overlay, agents: AgentManager) {
        self.overlay = overlay
        self.agents = agents
        overlay.onHelperAction = { [weak self] id, action in self?.action(id: id, action) }
    }

    func settings(_ config: AppConfig) {
        overlay.helperSounds(on: config.sounds, volume: config.soundVolume)
    }

    /// It buds off the main buddy, gets its task and flies to the edge.
    func started(_ a: AgentManager.Agent) {
        let task = a.task.trimmingCharacters(in: .whitespacesAndNewlines)
        overlay.helperSpawn(id: a.id, name: a.name, task: Self.sentence(a.title), note: AgentManager.note(for: a.name),
                            detail: task.count > 220 ? String(task.prefix(219)) + "…" : task,
                            folder: a.dir.path == FileManager.default.homeDirectoryForCurrentUser.path ? "" : a.dir.lastPathComponent)
        watchWindows()
    }

    func event(_ a: AgentManager.Agent, _ e: HelperEvent) {
        switch e {
        case .step(let s), .note(let s): overlay.helperStep(id: a.id, text: s)
        case .checklist(let items): overlay.helperChecklist(id: a.id, items: items)
        case .blocked(let what): overlay.helperStep(id: a.id, text: "Not allowed to " + Self.lowerFirst(what))
        case .started, .turnEnded, .asking, .askCancelled, .limit: break   // asks: see asksChanged
        }
    }

    /// Done (celebrates and flies back), failed (droops and flies back) or stopped (a small puff).
    func finished(_ a: AgentManager.Agent) {
        switch a.status {
        case .done: overlay.helperDone(id: a.id, ok: true, summary: a.summary)
        case .failed: overlay.helperDone(id: a.id, ok: false, summary: a.summary)
        case .stopped: overlay.helperStop(id: a.id)
        case .queued, .running: break
        }
    }

    func stopped(id: Int) { overlay.helperStop(id: id) }

    /// A button on a helper's card.
    func action(id: Int, _ action: String) {
        guard let a = agents?.agents.first(where: { $0.id == id }) else { return }
        switch action {
        case "allow": onCardAnswer?(id, true)
        case "deny": onCardAnswer?(id, false)
        case "stop": agents?.stop(id: id)
        case "log", "open": onOpen?(id)
        case "folder": NSWorkspace.shared.open(a.dir)
        default: break
        }
    }

    // MARK: - Raising its hand

    /// Its open requests changed: it raises its hand for the first one (one at a time), or lowers it.
    func asksChanged(_ a: AgentManager.Agent) {
        guard let first = a.asks.first else {
            if shownAsk.removeValue(forKey: a.id) != nil { overlay.helperAnswered(id: a.id, ok: false) }
            return
        }
        let key = Self.key(first)
        guard shownAsk[a.id] != key else { return }
        if shownAsk[a.id] == nil {
            overlay.helperAsk(id: a.id, question: first.bubble, detail: first.detail, kind: Self.kind(first))
        } else {
            overlay.helperAnswered(id: a.id, ok: true, next: (first.bubble, first.detail, Self.kind(first)))
        }
        shownAsk[a.id] = key
    }

    /// You answered its request: "Thanks!" (or "Okay, skipping it"), then its next one if it has more.
    func answered(_ a: AgentManager.Agent, ok: Bool) {
        if let next = a.asks.first {
            shownAsk[a.id] = Self.key(next)
            overlay.helperAnswered(id: a.id, ok: ok, next: (next.bubble, next.detail, Self.kind(next)))
        } else {
            shownAsk[a.id] = nil
            overlay.helperAnswered(id: a.id, ok: ok)
        }
    }

    /// No answer for a while: back to work at the edge, hand still up.
    func park(id: Int) { overlay.helperPark(id: id) }

    /// Which waiting helper you answered, and what you meant, or nil (then it's for the talker).
    /// Pointing at a helper (`pointing`) or saying its name answers it; otherwise it's for the one next to
    /// the buddy (`asking`). Only ever given what the user said: nothing else can approve anything.
    func askReply(_ text: String, pointing: Int?, asking: Int?) -> (id: Int, reply: HelperAsk.Reply)? {
        let waiting = (agents?.running ?? []).filter { !$0.asks.isEmpty }
        guard !waiting.isEmpty else { return nil }
        // Pointing at it ("stop" still stops it).
        if let id = pointing {
            guard let a = waiting.first(where: { $0.id == id }), let ask = a.asks.first, HelperTalk.intent(text) != .stop else { return nil }
            let r = ask.reply(to: text, addressed: true)
            return r == .unclear ? nil : (id, r)
        }
        // By name: "Mint, yes", "tell Coral no, use yarn", "yes Violet".
        for a in waiting {
            guard let ask = a.asks.first, let rest = HelperTalk.without(name: a.name, in: text) else { continue }
            if HelperTalk.intent(rest) == .stop { return nil }
            let r = ask.reply(to: rest, addressed: true)
            if r != .unclear { return (a.id, r) }
        }
        // The one next to the buddy, which just asked.
        if let id = asking, let a = waiting.first(where: { $0.id == id }), let ask = a.asks.first {
            let r = ask.reply(to: text, addressed: false)
            return r == .unclear ? nil : (id, r)
        }
        return nil
    }

    /// Sends your answer: it thanks you and goes on, or asks its next question.
    @discardableResult
    func answer(_ id: Int, _ reply: HelperAsk.Reply) -> AgentManager.AnswerResult {
        guard let agents else { return .failed }
        let result = agents.answer(id: id, reply)
        guard let a = agents.agents.first(where: { $0.id == id }) else { return result }
        switch result {
        case .next: asksChanged(a)   // its next question (the same request)
        case .sent:
            if case .no = reply { answered(a, ok: false) } else { answered(a, ok: true) }
        case .failed: break
        }
        return result
    }

    private static func key(_ ask: HelperAsk) -> String { ask.requestID + "#" + (ask.currentQuestion?.text ?? "") }
    private static func kind(_ ask: HelperAsk) -> String { ask.kind == .question ? "question" : ask.isPlan ? "plan" : "permission" }

    // MARK: - Talking to a helper

    enum TalkResult: Equatable {
        case say(String)                       // speak this (a status, or "Okay, I stopped Mint.")
        case passed(String)                    // the follow-up went to this helper
        case askTalker(context: String)        // it already finished: the main agent takes it, with this context
        case resume(PastHelper, String)        // it already finished: continue it with this
        case undo(PastHelper)                  // put back what it changed in its last run
    }

    /// Names you can talk to: helpers working or waiting, and ones that finished in the last 15 minutes.
    func names() -> [String] {
        let recent = (agents?.agents ?? []).filter { a in
            a.status == .running || a.status == .queued || Date().timeIntervalSince(a.finished ?? .distantPast) < 15 * 60
        }
        return Array(Set(recent.map(\.name)))
    }

    /// The newest helper with that name (names come back after a helper is done).
    func helper(named name: String) -> AgentManager.Agent? {
        agents?.agents.last { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Stop, a status answer, or a follow-up for its work: quick, from what the helper has reported.
    func talk(to id: Int, _ intent: HelperTalk.Intent) -> TalkResult? {
        guard let agents, let a = agents.agents.first(where: { $0.id == id }) else { return nil }
        let working = a.status == .running || a.status == .queued
        switch intent {
        case .stop:
            if working { agents.stop(id: id) }
            return .say(working ? "Okay, I stopped \(a.name)." : "\(a.name) already \(a.status == .stopped ? "stopped" : "finished").")
        case .status:
            overlay.helperHeard(id: id, kind: "status")
            return .say(HelperTalk.status(a))
        case .pause:
            if a.status == .running, agents.pause(id: id) {
                overlay.helperStep(id: id, text: "Paused")
                return .say("Okay, \(a.name) is waiting. What should it do?")
            }
            return .say(a.paused ? "\(a.name) is already waiting for you." : working ? "\(a.name) hasn't started yet." : "\(a.name) already finished.")
        case .undo:
            return .undo(agents.past(a))
        case .resume:
            if agents.resume(id: id) { overlay.helperHeard(id: id, kind: "message"); return .passed(a.name) }
            return .say(working ? "\(a.name) is still working." : "\(a.name) already finished.")
        case .message(let m):
            if working, a.status == .running, HelperTalk.isRedirect(m), agents.redirect(id: id, text: m) {
                overlay.helperHeard(id: id, kind: "message")
                return .passed(a.name)
            }
            if working, agents.send(id: id, text: m) {
                overlay.helperHeard(id: id, kind: "message")
                return .passed(a.name)
            }
            // Finished: it picks up where it left off, with what you said.
            if !working { return .resume(agents.past(a), m) }
            let how = a.status == .done ? "finished" : a.status == .failed ? "couldn't finish" : "was stopped before finishing"
            return .askTalker(context: "(The user is pointing at the helper \(a.name), which \(how) its task \"\(a.title)\" in \(a.dir.path). Its summary: \(a.summary.isEmpty ? "(none)" : a.summary). If they want more work on it, start a new agent and include that context.)")
        }
    }

    // MARK: - The window you're using

    /// While helpers are on screen, check twice a second which window is in front.
    private func watchWindows() {
        guard windowTimer == nil else { return }
        windowTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let busy = (self.agents?.running.isEmpty == false) || self.overlay.helperCount > 0
                guard busy else { self.windowTimer?.invalidate(); self.windowTimer = nil; return }
                guard let screen = self.overlay.screen else { return }
                self.overlay.helperAvoid(Self.frontWindowRect(on: screen))
            }
        }
    }

    /// The front app's frontmost window, in `screen`'s points (top-left origin), or nil.
    /// Window positions don't need Screen Recording permission (only their titles would).
    static func frontWindowRect(on screen: NSScreen) -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        for w in list {   // front to back
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: dict as CFDictionary),
                  r.width > 120, r.height > 80 else { continue }
            // Global window coordinates start at the top-left of the main display.
            let local = CGRect(x: r.minX - screen.frame.minX, y: r.minY - (primaryHeight - screen.frame.maxY),
                               width: r.width, height: r.height)
            let visible = local.intersection(bounds)
            return visible.isNull || visible.width < 60 ? nil : visible
        }
        return nil
    }

    /// "fix the tip bug" → "Fix the tip bug"
    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.prefix(1).uppercased() + t.dropFirst()
    }
    static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }
}
