import AppKit
import SwiftUI

/// Poinky's home at the camera notch.
///
/// Idle, it's a black shape exactly the size of the notch (invisible). While you talk or Claude
/// answers, it grows wings with the status and a glow. Hover the notch and it opens into a small
/// panel with the status, the last thing Claude said, and controls.
/// Screens without a notch get the same thing as a tab at the top center, shown only while active.
@MainActor
final class NotchModel: ObservableObject {
    @Published var phase = "off"            // off · starting · ready · listening · thinking · speaking
    @Published var guide = false
    @Published var level: Double = 0        // mic level while listening, 0…1
    @Published var expanded = false
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 32
    @Published var hasNotch = false
    @Published var inCall = false
    @Published var teacherOn = true
    @Published var holdKeys = "⌃⌥"
    @Published var callKeys = "⌃⌥Space"
    @Published var lastLine = "" { didSet { lastLineAt = Date() } }
    @Published var hoverButton: String?
    @Published var tip: String?             // the tooltip being shown
    @Published var tipX: CGFloat = 0        // its center, in the notch shape's coordinates
    var tipXs: [String: CGFloat] = [:]      // where each element is (reported by the layout)
    private var tipWork: DispatchWorkItem?

    /// Tooltips: a short delay before the first one, then they follow the mouse instantly.
    func hover(_ id: String, tip text: String, inside: Bool) {
        if inside {
            hoverButton = id
            tipWork?.cancel()
            let x = tipXs[id] ?? 0
            if tip != nil { tip = text; tipX = x; return }
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.hoverButton == id else { return }
                self.tipX = self.tipXs[id] ?? x
                self.tip = text
            }
            tipWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
        } else if hoverButton == id {
            hoverButton = nil
            tipWork?.cancel()
            // A moment's grace, so moving from one element to the next doesn't blink.
            let w = DispatchWorkItem { [weak self] in if self?.hoverButton == nil { self?.tip = nil } }
            tipWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: w)
        }
    }

    func clearTip() { tipWork?.cancel(); hoverButton = nil; tip = nil }
    @Published var buddyHidden = false
    @Published var agentsRunning = 0
    private(set) var lastLineAt = Date.distantPast

    var onCall: () -> Void = {}
    var onEnd: () -> Void = {}
    var onClear: () -> Void = {}
    var onTeacher: () -> Void = {}
    var onBuddy: () -> Void = {}
    var onSettings: () -> Void = {}
    var onQuit: () -> Void = {}

    static let wing: CGFloat = 80
    var sessionOn: Bool { phase != "off" }
    var active: Bool { ["starting", "listening", "thinking", "speaking"].contains(phase) || (guide && sessionOn) }

    // Every size has a job:
    //  idle      exactly the notch: invisible, no distraction
    //  active    + wings: what's happening, at a glance
    //  hover     + one slim row of icon buttons below, same width: quick actions, nothing to read
    //  recent    + one line with Claude's last sentence, only if it spoke in the last minute: re-read what you missed
    //  working   (idle, agents running) a small dot beside the notch: work is happening in the background
    static let buttonRow: CGFloat = 40
    static let lineRow: CGFloat = 22
    var showsLastLine: Bool { (!lastLine.isEmpty && Date().timeIntervalSince(lastLineAt) < 60) || agentsRunning > 0 }
    var infoLine: String {
        let agents = agentsRunning == 0 ? "" : (agentsRunning == 1 ? "1 agent working" : "\(agentsRunning) agents working")
        let recent = !lastLine.isEmpty && Date().timeIntervalSince(lastLineAt) < 60 ? lastLine : ""
        return [agents, recent].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    static let dotWing: CGFloat = 26

    var shapeSize: CGSize {
        let wide = notchWidth + 2 * Self.wing
        if expanded {
            return CGSize(width: max(wide, 300), height: notchHeight + Self.buttonRow + (showsLastLine ? Self.lineRow : 0) + 6)
        }
        if active { return CGSize(width: wide, height: notchHeight) }
        if agentsRunning > 0 { return CGSize(width: notchWidth + 2 * Self.dotWing, height: notchHeight) }
        return CGSize(width: max(notchWidth, 1), height: notchHeight)
    }
    var visible: Bool { hasNotch || active || expanded || agentsRunning > 0 }
}

// MARK: - Views

private let sbBlue = Color(red: 0.23, green: 0.51, blue: 1.0)
private let sbOrange = Color(red: 1.0, green: 0.55, blue: 0.24)
private let sbViolet = Color(red: 0.56, green: 0.48, blue: 1.0)
private let sbTeal = Color(red: 0.2, green: 0.8, blue: 0.75)

struct NotchView: View {
    @ObservedObject var m: NotchModel

    private var glow: Color {
        if m.guide && m.phase == "ready" { return sbTeal }
        switch m.phase {
        case "listening": return sbBlue
        case "speaking": return sbOrange
        case "thinking", "starting": return sbViolet
        default: return .clear
        }
    }

    private var label: String {
        switch m.phase {
        case "listening": return "Listening"
        case "thinking": return "Thinking"
        case "speaking": return "Speaking"
        case "starting": return "Waking up"
        default: return m.guide && m.sessionOn ? "Your turn" : "Buddy"
        }
    }

    var body: some View {
        let size = m.shapeSize
        let radius: CGFloat = m.expanded ? 18 : 13
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
                .fill(Color.black)
                .shadow(color: glow.opacity(m.active ? 0.55 + 0.4 * m.level : 0), radius: 14, y: 3)
                .shadow(color: glow.opacity(m.active ? 0.35 : 0), radius: 4, y: 1)
            VStack(spacing: 0) {
                wings.frame(height: m.notchHeight)
                if m.expanded {
                    VStack(spacing: 0) {
                        if m.showsLastLine {
                            Text(m.infoLine)
                                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1).truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .frame(height: NotchModel.lineRow)
                                .notchTip(m, "info", infoTip)
                        }
                        buttons.frame(height: NotchModel.buttonRow)
                    }
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "notch")
        .onPreferenceChange(TipFrames.self) { m.tipXs = $0 }
        .overlay(alignment: .top) {
            if let tip = m.tip, m.expanded {
                // Centered under the hovered element (kept within reach of the notch), just below the shape.
                let x = min(max(m.tipX, -40), size.width + 40) - size.width / 2
                NotchTip(text: tip)
                    .offset(x: x, y: size.height + 8)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .opacity(m.visible ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: m.expanded)
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: m.active)
        .animation(.easeOut(duration: 0.25), value: m.phase)
        .animation(.easeOut(duration: 0.15), value: m.hoverButton)
        .animation(.easeOut(duration: 0.15), value: m.tip)
    }

    /// The two sides of the notch. Active: status and a visualizer. Hovered while idle: the two shortcuts.
    @ViewBuilder private var wings: some View {
        if !m.active && !m.expanded && m.agentsRunning > 0 {
            HStack {
                Spacer()
                TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
                    let u = 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 3)
                    Circle().fill(sbTeal).frame(width: 6, height: 6).opacity(0.45 + 0.55 * u)
                        .shadow(color: sbTeal.opacity(0.9), radius: 3 + 2 * u)
                }
                .frame(width: NotchModel.dotWing)
            }
            .transition(.opacity)
        } else if m.active || m.expanded {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    BuddyGlyph().frame(width: 10, height: 10)
                    Text(m.active ? label : "\(m.holdKeys) talk")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                }
                .frame(width: NotchModel.wing, alignment: .center)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .notchTip(m, "left", leftTip)
                Spacer(minLength: m.notchWidth)
                ZStack {
                    Visualizer(phase: m.guide && m.phase == "ready" ? "guide" : m.phase, level: m.level, color: glow)
                        .opacity(m.active ? 1 : 0)
                    if !m.active {
                        Text(m.inCall ? "in a call" : "\(m.callKeys.replacingOccurrences(of: "Space", with: "␣")) call")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                }
                .frame(width: NotchModel.wing)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .notchTip(m, "right", rightTip)
            }
            .transition(.opacity)
        }
    }

    // MARK: Tooltips

    private var leftTip: String {
        let h = m.holdKeys
        if m.guide && m.phase == "ready" { return "Guide mode: do the step I circled, I'll watch for your click. Hold \(h) to ask or say stop." }
        switch m.phase {
        case "listening": return "Listening. Let go of \(h) to send, or keep talking."
        case "thinking": return "Thinking about your question. Tap \(h) to cancel."
        case "speaking": return "Speaking. Hold \(h) to cut in with a new question, or tap it to stop."
        case "starting": return "Waking up the Claude sessions…"
        default: return "Hold \(h) and talk, let go to send. Drag while holding to mark things. A quick tap stops me."
        }
    }

    private var rightTip: String {
        if m.inCall { return "In a hands-free call: the mic is on. \(m.callKeys) or say bye to end it." }
        switch m.phase {
        case "listening": return "Your voice level"
        case "speaking": return "My voice"
        case "thinking", "starting": return "Working on it"
        default: return "\(m.callKeys) starts a hands-free call: the mic stays on and a pause ends each question."
        }
    }

    private var infoTip: String {
        var parts: [String] = []
        if m.agentsRunning > 0 { parts.append("Background agents are working on your projects. I'll tell you when they finish.") }
        if !m.lastLine.isEmpty { parts.append("The last thing I said.") }
        return parts.joined(separator: " ")
    }

    /// One row of icons: what you'd reach for, nothing to read.
    private var buttons: some View {
        HStack(spacing: 4) {
            NotchIcon(m: m, id: "call", icon: m.inCall ? "phone.down.fill" : "phone.fill",
                      tip: m.inCall ? "End the call (\(m.callKeys))" : "Hands-free call (\(m.callKeys))",
                      tint: m.inCall ? Color.red : nil, action: m.onCall)
            NotchIcon(m: m, id: "clear", icon: "eraser", tip: "Clear everything drawn: marks, papers and 3D models", action: m.onClear)
            NotchIcon(m: m, id: "buddy", icon: m.buddyHidden ? "eye.slash" : "eye",
                      tip: m.buddyHidden ? "Show the buddy (⌃⌥B)" : "Hide the buddy until you ask something (⌃⌥B)",
                      dim: m.buddyHidden, action: m.onBuddy)
            NotchIcon(m: m, id: "teacher", icon: "pencil.and.scribble", tip: m.teacherOn ? "Teacher on: explanations get a hand-drawn sketch or a 3D model. Click to turn off." : "Teacher off: voice and quick marks only. Click to turn on.",
                      tint: m.teacherOn ? sbBlue : nil, dim: !m.teacherOn, action: m.onTeacher)
            if m.sessionOn && !m.inCall {
                NotchIcon(m: m, id: "end", icon: "stop.circle", tip: "End the session (clears the screen; the next \(m.holdKeys) starts a new one)", action: m.onEnd)
            }
            NotchIcon(m: m, id: "settings", icon: "gearshape", tip: "Settings: voice, shortcuts, Claude models, memory, privacy", action: m.onSettings)
            NotchIcon(m: m, id: "quit", icon: "power", tip: "Quit Poinky (stops background agents too)", action: m.onQuit)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

/// A round icon button that lights up under the mouse.
struct NotchIcon: View {
    @ObservedObject var m: NotchModel
    let id: String
    let icon: String
    let tip: String
    var tint: Color? = nil
    var dim = false
    let action: () -> Void

    var body: some View {
        let hot = m.hoverButton == id
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint ?? Color.white.opacity(dim ? 0.4 : 0.85))
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(Capsule().fill(Color.white.opacity(hot ? 0.16 : 0.07)))
                .scaleEffect(hot ? 1.06 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .notchTip(m, id, tip)
    }
}

/// The buddy's little blue pointer.
struct BuddyGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            p.move(to: CGPoint(x: 0.08 * size.width, y: 0.08 * size.height))
            p.addLine(to: CGPoint(x: 0.95 * size.width, y: 0.42 * size.height))
            p.addLine(to: CGPoint(x: 0.42 * size.width, y: 0.95 * size.height))
            p.closeSubpath()
            ctx.fill(p, with: .color(sbBlue))
            ctx.stroke(p, with: .color(sbBlue), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        }
        .shadow(color: sbBlue.opacity(0.8), radius: 3)
    }
}

/// Bars that follow your voice, dance while Claude speaks, or dots while it thinks.
struct Visualizer: View {
    let phase: String
    let level: Double
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !["listening", "speaking", "thinking", "starting", "guide"].contains(phase))) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                if phase == "thinking" || phase == "starting" || phase == "guide" {
                    ForEach(0..<3, id: \.self) { i in
                        let u = 0.5 + 0.5 * sin(t * 6 - Double(i) * 1.1)
                        Circle().fill(color).frame(width: 5, height: 5)
                            .opacity(0.35 + 0.65 * u).offset(y: -3 * u)
                    }
                } else {
                    ForEach(0..<5, id: \.self) { i in
                        let wave = abs(sin(t * (phase == "speaking" ? 7 : 9) + Double(i) * 1.3))
                        let amp = phase == "speaking" ? 0.35 + 0.65 * wave : level * (0.5 + 0.5 * wave)
                        Capsule()
                            .fill(phase == "speaking"
                                  ? AnyShapeStyle(LinearGradient(colors: [Color(red: 1, green: 0.82, blue: 0.55), sbOrange], startPoint: .top, endPoint: .bottom))
                                  : AnyShapeStyle(Color.white))
                            .frame(width: 3, height: 4 + 11 * amp)
                            .shadow(color: phase == "speaking" ? sbOrange.opacity(0.8) : .clear, radius: 3)
                    }
                }
            }
            .frame(height: 16)
        }
    }
}

/// Where each element with a tooltip is, so its tooltip can sit right under it.
struct TipFrames: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Gives an element of the notch a tooltip (shown below the notch while you hover it).
    func notchTip(_ m: NotchModel, _ id: String, _ text: String) -> some View {
        self.background(GeometryReader { g in
            Color.clear.preference(key: TipFrames.self, value: [id: g.frame(in: .named("notch")).midX])
        })
        .onHover { inside in m.hover(id, tip: text, inside: inside) }
    }
}

/// The tooltip itself: a small dark label with a soft shadow.
struct NotchTip: View {
    let text: String
    var body: some View {
        // The text wraps at 230 pt and keeps its full height; the box hugs it (short tips stay small).
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(white: 0.13)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .frame(width: 250)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Lets a click on a button work right away, without first activating the panel.
private final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - The window

@MainActor
final class NotchHome {
    let model = NotchModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var hoverSince: TimeInterval?
    private var awaySince: TimeInterval?
    private weak var screen: NSScreen?
    private static let panelSize = CGSize(width: 680, height: 240)

    /// The built-in display with a camera notch, if any.
    static var notchScreen: NSScreen? { NSScreen.screens.first { $0.safeAreaInsets.top > 0 } }

    func show() {
        if panel == nil { build() }
        place()
        panel?.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        }
    }

    private func build() {
        let p = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)   // above the drawings and the menu bar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = FirstClickHostingView(rootView: NotchView(m: model))
        host.layer?.backgroundColor = .clear
        p.contentView = host
        panel = p
    }

    /// Sits centered on the notch (or the top center of the main screen).
    private func place() {
        guard let panel else { return }
        let s = Self.notchScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let s else { return }
        screen = s
        let top = s.safeAreaInsets.top
        if top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            model.hasNotch = true
            model.notchWidth = s.frame.width - l.width - r.width
            model.notchHeight = top
            let mid = s.frame.minX + l.width + model.notchWidth / 2
            panel.setFrame(CGRect(x: mid - Self.panelSize.width / 2, y: s.frame.maxY - Self.panelSize.height,
                                  width: Self.panelSize.width, height: Self.panelSize.height), display: true)
        } else {
            model.hasNotch = false
            model.notchWidth = 0
            model.notchHeight = max(24, s.frame.maxY - s.visibleFrame.maxY)
            panel.setFrame(CGRect(x: s.frame.midX - Self.panelSize.width / 2, y: s.frame.maxY - Self.panelSize.height,
                                  width: Self.panelSize.width, height: Self.panelSize.height), display: true)
        }
    }

    /// Hovering the notch opens the panel; moving away closes it.
    private func poll() {
        guard let panel, let s = screen else { return }
        let mouse = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        let midX = panel.frame.midX
        let shape = model.shapeSize
        let hot: CGRect
        if model.expanded {
            // (+4 above the top: the mouse can sit exactly on the screen's top edge.)
            hot = CGRect(x: midX - shape.width / 2 - 12, y: s.frame.maxY - shape.height - 14, width: shape.width + 24, height: shape.height + 18)
        } else {
            // The notch itself (a bit wider), or its wings when they're out.
            let w = max(model.hasNotch ? model.notchWidth + 16 : 160, model.active ? shape.width : 0)
            hot = CGRect(x: midX - w / 2, y: s.frame.maxY - model.notchHeight, width: w, height: model.notchHeight + 4)
        }
        let inside = hot.contains(mouse)
        if inside {
            awaySince = nil
            if !model.expanded {
                if hoverSince == nil { hoverSince = now }
                if now - hoverSince! > (model.hasNotch ? 0.12 : 0.3) { setExpanded(true) }
            }
        } else {
            hoverSince = nil
            if model.expanded {
                if awaySince == nil { awaySince = now }
                if now - awaySince! > 0.3 { setExpanded(false) }
            }
        }
    }

    private func setExpanded(_ on: Bool) {
        guard model.expanded != on else { return }
        model.expanded = on
        if !on { model.clearTip() }
        panel?.ignoresMouseEvents = !on
    }

    /// Closes the panel (after one of its buttons was used).
    func collapse() { setExpanded(false); hoverSince = Double.greatestFiniteMagnitude }
}
