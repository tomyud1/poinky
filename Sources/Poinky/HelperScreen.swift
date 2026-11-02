import Foundation

/// Shows helpers (background agents) on screen: turns `AgentManager`'s callbacks into the
/// overlay's helper calls (web/helpers-app.js). The overlay does the drawing and the sounds.
@MainActor
final class HelperScreen {
    private let overlay: Overlay

    init(overlay: Overlay) { self.overlay = overlay }

    func settings(_ config: AppConfig) {
        overlay.helperSounds(on: config.sounds, volume: config.soundVolume)
    }

    /// It buds off the main buddy, gets its task and flies to the edge.
    func started(_ a: AgentManager.Agent) {
        overlay.helperSpawn(id: a.id, name: a.name, task: Self.sentence(a.title), note: AgentManager.note(for: a.name))
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

    /// "fix the tip bug" → "Fix the tip bug"
    static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.prefix(1).uppercased() + t.dropFirst()
    }
    static func lowerFirst(_ s: String) -> String { s.prefix(1).lowercased() + s.dropFirst() }
}
