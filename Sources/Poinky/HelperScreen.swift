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
        case .started, .turnEnded: break
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
        case "stop": agents?.stop(id: id)
        case "log": NSWorkspace.shared.open(a.log)
        case "folder": NSWorkspace.shared.open(a.dir)
        default: break
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
