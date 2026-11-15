import AppKit
import UserNotifications

/// macOS notifications for helpers: one needs you (a permission or a question) while no session runs,
/// or its question was parked unanswered; and (opt-in) one finished while you're away from the Mac.
///
/// The buttons answer exactly like the card's buttons (`onAnswer` → `CallController.phoneAnswer` →
/// `answerAsk` → `AgentManager.answer`), and only for the one request the notification was made for.
/// Allow is an explicit click like the card's Allow, so it may approve a risky ask too, but: it is never
/// "always", the notification says the risky part (the bubble keeps it, the exact command is added), and
/// Allow needs the Mac unlocked (`.authenticationRequired`), so nobody at a locked Mac can approve anything.
/// Permission to show notifications is asked the first time one is actually needed, never at launch.
@MainActor
final class HelperNotifier {
    /// What happened on a notification: the helper, the request, and the button.
    enum Action: String { case allow, deny, open, choose, skip }

    var onAnswer: ((_ agent: Int, _ requestID: String, _ reply: HelperAsk.Reply) -> Void)?
    /// Open the helper's window (a click on the notification itself, or Open on a question).
    var onOpen: ((_ agent: Int) -> Void)?
    /// Away from the Mac (screen locked, or idle): for "finished" notifications.
    var isAway: () -> Bool = { AwayNotifier.userIsAway(minutes: 3) }

    private let poster: NotificationPosting
    private var config = AppConfig()
    /// Shown and still open: notification id → (helper, request). Answered or withdrawn ones are removed.
    private var shown: [String: (agent: Int, requestID: String, ask: HelperAsk)] = [:]

    init(poster: NotificationPosting? = nil) {
        self.poster = poster ?? SystemNotifications()
        self.poster.onAction = { [weak self] id, action in self?.handle(id, action) }
    }

    func settings(_ c: AppConfig) {
        config = c
        isAway = { AwayNotifier.userIsAway(minutes: c.awayMinutes) }
        if !c.helperNotify { withdrawAll() }
    }

    /// The id of the notification for a request (and its current question, for AskUserQuestion).
    static func id(_ ask: HelperAsk) -> String {
        "ask-" + ask.requestID + (ask.questions.firstIndex { ask.answers[$0.text] == nil }.map { "#\($0)" } ?? "")
    }

    /// A helper needs you. `inSession`: you're in a call (then Poinky says it out loud, no notification);
    /// `parked`: it asked and nobody answered (a notification even in a session).
    func asking(_ a: AgentManager.Agent, _ ask: HelperAsk, inSession: Bool, parked: Bool = false) {
        guard config.helperNotify, !inSession || parked else { return }
        let nid = Self.id(ask)
        guard shown[nid] == nil else { return }
        shown[nid] = (a.id, ask.requestID, ask)
        let n = Self.content(a, ask)
        poster.post(id: nid, title: n.title, body: n.body, category: n.category, agent: a.id)
    }

    /// What's still open: notifications for anything answered (here, by voice, on the card) or withdrawn go away.
    func stillOpen(_ asks: [(agent: Int, ask: HelperAsk)]) {
        let open = Set(asks.map { Self.id($0.ask) })
        let gone = shown.keys.filter { !open.contains($0) }
        guard !gone.isEmpty else { return }
        for k in gone { shown[k] = nil }
        poster.remove(ids: gone)
    }

    /// A helper finished: a notification if you're away from the Mac (opt-in).
    func finished(_ a: AgentManager.Agent) {
        guard config.helperNotify, config.helperNotifyDone, isAway() else { return }
        let ok = a.status == .done
        let summary = HelperTalk.firstSentences(a.summary, 2)
        poster.post(id: "done-\(a.id)-\(Int(Date().timeIntervalSince1970))", title: "\(a.name) \(ok ? "finished" : "stopped with a problem"): \(HelperStream.clip(a.title, 60))",
                    body: summary.isEmpty ? (ok ? "It's done." : "It couldn't finish.") : HelperStream.clip(summary, 220), category: Self.doneCategory, agent: a.id)
    }

    private func withdrawAll() {
        guard !shown.isEmpty else { return }
        poster.remove(ids: Array(shown.keys))
        shown.removeAll()
    }

    // MARK: - What it says

    static let askCategory = "poinky.helper.ask", riskyCategory = "poinky.helper.ask.risky", planCategory = "poinky.helper.plan",
               questionCategory = "poinky.helper.question", doneCategory = "poinky.helper.done"

    /// Title: its name and task. Body: the plain question; a risky one also gets the exact command.
    static func content(_ a: AgentManager.Agent, _ ask: HelperAsk) -> (title: String, body: String, category: String) {
        let title = "\(a.name): \(HelperStream.clip(a.title, 60))"
        if ask.kind == .question, let q = ask.currentQuestion {
            let opts = q.options.isEmpty ? "" : "\n" + q.options.prefix(4).joined(separator: " · ")
            return (title, HelperStream.clip(q.text, 200) + opts, questionCategory)
        }
        if ask.isPlan {
            return (title, ask.bubble + (planTitle(ask).map { "\n\($0)" } ?? ""), planCategory)
        }
        var body = ask.bubble
        // The exact command or file when it says more than the bubble (always for a risky one).
        if ask.risky || ask.detail.count <= 120, !ask.detail.isEmpty, !ask.bubble.contains(ask.detail), ask.tool != ask.detail {
            body += "\n" + HelperStream.clip(ask.detail, 240)
        }
        return (title, body, ask.risky ? riskyCategory : askCategory)
    }

    private static func planTitle(_ ask: HelperAsk) -> String? { HelperAsk.planTitle(ask.detail) }

    /// A button's answer, the same as the card's: Allow = yes (never "always"), Don't allow = no,
    /// You choose / Skip for a question. Open (and a click on the notification) answers nothing.
    static func reply(_ action: Action, _ ask: HelperAsk) -> HelperAsk.Reply? {
        switch action {
        case .allow: return ask.kind == .question ? nil : .yes(always: false, extra: "")
        case .deny: return ask.kind == .question ? nil : .no(reason: "")
        case .choose: return ask.kind == .question ? .answer("No preference: you choose.") : nil
        case .skip: return ask.kind == .question ? .no(reason: "") : nil
        case .open: return nil
        }
    }

    // MARK: - A button was clicked

    func handle(_ notificationID: String, _ action: Action) {
        if notificationID.hasPrefix("done-") {
            if let id = Int(notificationID.split(separator: "-").dropFirst().first ?? "") { onOpen?(id) }
            return
        }
        // Only a notification that's still open counts (answered elsewhere or withdrawn: nothing happens).
        guard let s = shown[notificationID] else { return }
        guard let reply = Self.reply(action, s.ask) else { onOpen?(s.agent); return }
        shown[notificationID] = nil
        onAnswer?(s.agent, s.requestID, reply)
    }
}

/// Where notifications go: the system (`SystemNotifications`), or a fake in tests.
@MainActor
protocol NotificationPosting: AnyObject {
    var onAction: ((_ id: String, _ action: HelperNotifier.Action) -> Void)? { get set }
    func post(id: String, title: String, body: String, category: String, agent: Int)
    func remove(ids: [String])
}

/// UNUserNotificationCenter. Nothing touches it until the first notification (so no permission prompt
/// at launch); its delegate is set then, and on launch only if Poinky had shown notifications before
/// (`registered`), so a click on one from before a restart still works.
@MainActor
final class SystemNotifications: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    var onAction: ((String, HelperNotifier.Action) -> Void)?
    private var state: Authorization = .unknown
    private var waiting: [UNNotificationRequest] = []
    private enum Authorization { case unknown, asking, allowed, denied }
    private static let usedKey = "helperNotificationsUsed"

    override init() {
        super.init()
        if UserDefaults.standard.bool(forKey: Self.usedKey), Bundle.main.bundleIdentifier != nil { setUp() }
    }

    private var center: UNUserNotificationCenter?
    private func setUp() {
        guard center == nil else { return }
        let c = UNUserNotificationCenter.current()
        center = c
        c.delegate = self
        // Allow needs the Mac unlocked; a risky one's Allow is shown in red.
        let allow = UNNotificationAction(identifier: "allow", title: "Allow", options: [.authenticationRequired])
        let allowRisky = UNNotificationAction(identifier: "allow", title: "Allow", options: [.authenticationRequired, .destructive])
        let deny = UNNotificationAction(identifier: "deny", title: "Don\u{2019}t Allow", options: [])
        let go = UNNotificationAction(identifier: "allow", title: "Go Ahead", options: [.authenticationRequired])
        let notNow = UNNotificationAction(identifier: "deny", title: "Not Now", options: [])
        let open = UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])
        let choose = UNNotificationAction(identifier: "choose", title: "You Choose", options: [.authenticationRequired])
        let skip = UNNotificationAction(identifier: "skip", title: "Skip", options: [])
        c.setNotificationCategories([
            UNNotificationCategory(identifier: HelperNotifier.askCategory, actions: [allow, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: HelperNotifier.riskyCategory, actions: [allowRisky, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: HelperNotifier.planCategory, actions: [go, notNow, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: HelperNotifier.questionCategory, actions: [open, choose, skip], intentIdentifiers: []),
            UNNotificationCategory(identifier: HelperNotifier.doneCategory, actions: [], intentIdentifiers: []),
        ])
    }

    func post(id: String, title: String, body: String, category: String, agent: Int) {
        guard Bundle.main.bundleIdentifier != nil, state != .denied else { return }
        setUp()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category
        content.threadIdentifier = "helper-\(agent)"
        content.sound = category == HelperNotifier.doneCategory ? nil : .default
        content.interruptionLevel = category == HelperNotifier.doneCategory ? .passive : .active
        content.userInfo = ["agent": agent]
        waiting.append(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        authorizeThenSend()
    }

    func remove(ids: [String]) {
        waiting.removeAll { ids.contains($0.identifier) }
        center?.removeDeliveredNotifications(withIdentifiers: ids)
        center?.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Asks once (the first time one is needed), then sends what waited.
    private func authorizeThenSend() {
        guard let center else { return }
        switch state {
        case .allowed: flush()
        case .denied, .asking: break
        case .unknown:
            state = .asking
            UserDefaults.standard.set(true, forKey: Self.usedKey)
            center.requestAuthorization(options: [.alert, .sound]) { granted, err in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.state = granted ? .allowed : .denied
                        if !granted { NSLog("Poinky: notifications not allowed\(err.map { ": \($0.localizedDescription)" } ?? "")"); self.waiting.removeAll() }
                        else { self.flush() }
                    }
                }
            }
        }
    }

    private func flush() {
        let list = waiting
        waiting.removeAll()
        for r in list { center?.add(r) { err in if let err { NSLog("Poinky: notification failed: \(err.localizedDescription)") } } }
    }

    // Shown even while Poinky is "active" (it's a menu bar app: it often is).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let action: HelperNotifier.Action
        switch response.actionIdentifier {
        case "allow": action = .allow
        case "deny": action = .deny
        case "choose": action = .choose
        case "skip": action = .skip
        default: action = .open   // a click on the notification itself, or Open
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onAction?(id, action) } }
        completionHandler()
    }
}

/// A notification center that only remembers, for tests (`--helper-test`, `--helper-talk-test`).
@MainActor
final class FakeNotifications: NotificationPosting {
    var onAction: ((String, HelperNotifier.Action) -> Void)?
    private(set) var posted: [(id: String, title: String, body: String, category: String, agent: Int)] = []
    private(set) var removed: [String] = []
    var log: ((String) -> Void)?
    func post(id: String, title: String, body: String, category: String, agent: Int) {
        posted.append((id, title, body, category, agent))
        log?("notification \(category.replacingOccurrences(of: "poinky.helper.", with: "")): \"\(title)\" / \"\(body.replacingOccurrences(of: "\n", with: " / "))\"")
    }
    func remove(ids: [String]) {
        removed += ids
        log?("notification removed: \(ids.count)")
    }
    /// Pretend you clicked a button on the last notification for this helper.
    func click(_ action: HelperNotifier.Action, agent: Int) {
        guard let n = posted.last(where: { $0.agent == agent }) else { return }
        onAction?(n.id, action)
    }
}
