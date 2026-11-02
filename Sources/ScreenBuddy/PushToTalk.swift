import AppKit
import Carbon

/// Hold a modifier combination (⌃⌥ by default) to talk; let go to send.
///
/// It polls the modifier keys instead of using a global key monitor, so it needs no extra
/// permission. If you press another key while holding (a ⌃⌥ shortcut of some app, or our own
/// ⌃⌥Space), it's a shortcut, not talking, and the hold is cancelled.
@MainActor
final class PushToTalk {
    /// The keys went down (start the mic now, so the first word isn't lost).
    var onDown: (() -> Void)?
    /// Held long enough to be on purpose: show that we're listening.
    var onCommit: (() -> Void)?
    /// Let go. `send` is false when the hold was cancelled or too short.
    var onUp: ((_ send: Bool) -> Void)?
    /// A quick press-and-release with no other key (interrupts Claude without asking anything).
    var onTap: (() -> Void)?

    private(set) var combo: NSEvent.ModifierFlags = []
    private(set) var isDown = false
    private(set) var committed = false
    private var cancelled = false
    private var downAt: TimeInterval = 0
    private var timer: Timer?
    private static let commitDelay: TimeInterval = 0.18

    /// "ctrl+option", "ctrl+shift", "option+cmd"…, or "off".
    func configure(_ spec: String) {
        combo = Self.parse(spec)
        if combo.isEmpty { cancel(); stopTimer() } else { startTimer() }
    }

    static func parse(_ spec: String) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for part in spec.lowercased().split(separator: "+") {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "ctrl", "control": f.insert(.control)
            case "opt", "option", "alt": f.insert(.option)
            case "cmd", "command": f.insert(.command)
            case "shift": f.insert(.shift)
            default: break
            }
        }
        // A single modifier would fire all the time while typing: at least two.
        return [NSEvent.ModifierFlags.control, .option, .command, .shift].filter { f.contains($0) }.count >= 2 ? f : []
    }

    static func displayString(_ spec: String) -> String {
        let f = parse(spec)
        guard !f.isEmpty else { return "Off" }
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s
    }

    /// Something else used the keys (e.g. our ⌃⌥Space shortcut fired): drop this hold.
    func cancel() {
        guard isDown, !cancelled else { return }
        cancelled = true
        committed = false
        onUp?(false)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let flags = NSEvent.modifierFlags.intersection([.control, .option, .command, .shift])
        let now = ProcessInfo.processInfo.systemUptime
        if !isDown {
            // Exactly the combination, and no other key: a hold starts.
            guard flags == combo, !Self.otherKeyDown() else { return }
            isDown = true
            committed = false
            cancelled = false
            downAt = now
            onDown?()
            return
        }
        // Let go of any of the keys: the hold ends.
        guard flags.isSuperset(of: combo) else {
            isDown = false
            if !cancelled {
                if !committed, now - downAt < 0.6 { onTap?() }
                onUp?(committed)
            }
            committed = false
            return
        }
        guard !cancelled else { return }
        // An extra modifier or any other key: it's a keyboard shortcut, not talking.
        if flags != combo || Self.otherKeyDown() {
            cancel()
            return
        }
        if !committed, now - downAt >= Self.commitDelay {
            committed = true
            onCommit?()
        }
    }

    /// Is any non-modifier key held right now? (Reading key state needs no permission.)
    private static func otherKeyDown() -> Bool {
        for code in 0..<0x7F where !modifierCodes.contains(code) {
            if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) { return true }
        }
        return false
    }

    private static let modifierCodes: Set<Int> = [
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
    ]
}
