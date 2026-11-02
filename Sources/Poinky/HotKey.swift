import Carbon
import Foundation

/// A system-wide keyboard shortcut (works no matter which app is in front).
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private let hotKeyID: UInt32
    private static var nextID: UInt32 = 1

    init?(spec: String, action: @escaping () -> Void) {
        self.action = action
        self.hotKeyID = HotKey.nextID
        HotKey.nextID += 1
        guard let (keyCode, modifiers) = HotKey.parse(spec) else { return nil }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            // Several shortcuts share the app's event target: only react to our own.
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard err == noErr, id.id == me.hotKeyID else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { me.action() }
            return noErr
        }, 1, &eventType, selfPtr, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x5342_4459), id: hotKeyID) // "SBDY"
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Parses strings like "ctrl+option+space" or "cmd+shift+k".
    static func parse(_ spec: String) -> (UInt32, UInt32)? {
        var mods: UInt32 = 0
        var key: UInt32?
        for raw in spec.lowercased().split(separator: "+") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            switch part {
            case "ctrl", "control": mods |= UInt32(controlKey)
            case "opt", "option", "alt": mods |= UInt32(optionKey)
            case "cmd", "command": mods |= UInt32(cmdKey)
            case "shift": mods |= UInt32(shiftKey)
            default: key = keyCodes[part]
            }
        }
        guard let key else { return nil }
        return (key, mods)
    }

    static func displayString(_ spec: String) -> String {
        spec.lowercased().split(separator: "+").map { part -> String in
            switch part.trimmingCharacters(in: .whitespaces) {
            case "ctrl", "control": return "⌃"
            case "opt", "option", "alt": return "⌥"
            case "cmd", "command": return "⌘"
            case "shift": return "⇧"
            case "space": return "Space"
            case let other: return other.uppercased()
            }
        }.joined()
    }

    /// The name used in shortcut strings for a key code (for the shortcut recorder).
    static func keyName(for code: UInt16) -> String? {
        let preferred = ["space", "return", "tab", "escape"]
        let names = keyCodes.filter { $0.value == UInt32(code) }.map(\.key)
        return names.first(where: { preferred.contains($0) }) ?? names.sorted().first
    }

    private static let keyCodes: [String: UInt32] = {
        var m: [String: UInt32] = [
            "space": UInt32(kVK_Space), "return": UInt32(kVK_Return), "enter": UInt32(kVK_Return),
            "tab": UInt32(kVK_Tab), "escape": UInt32(kVK_Escape), "esc": UInt32(kVK_Escape),
            "`": UInt32(kVK_ANSI_Grave), "/": UInt32(kVK_ANSI_Slash), ".": UInt32(kVK_ANSI_Period),
            ",": UInt32(kVK_ANSI_Comma), ";": UInt32(kVK_ANSI_Semicolon),
        ]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9), ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4),
            ("f5", kVK_F5), ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8), ("f9", kVK_F9),
            ("f10", kVK_F10), ("f11", kVK_F11), ("f12", kVK_F12), ("f13", kVK_F13), ("f14", kVK_F14),
            ("f15", kVK_F15), ("f16", kVK_F16), ("f17", kVK_F17), ("f18", kVK_F18), ("f19", kVK_F19),
        ]
        for (k, v) in letters { m[k] = UInt32(v) }
        return m
    }()
}
