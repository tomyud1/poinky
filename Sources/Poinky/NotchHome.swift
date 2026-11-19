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
    @Published var lookingUp = false        // "thinking" is a web search or a look through earlier conversations
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
    /// First run ("I live here", FirstRun.swift): home opens a little and glows while the buddy shows you where it is.
    @Published var beckon = false
    @Published var agentsRunning = 0
    @Published var update = ""             // "" · available · ready (shows the update arrow)
    /// What helpers did, newest last: the hover panel lists the latest few, and the ones you haven't
    /// heard yet show as colored dots beside the notch.
    @Published private(set) var reports: [HelperReport] = []
    var onOpenReport: (HelperReport) -> Void = { _ in }
    private(set) var lastLineAt = Date.distantPast

    struct HelperReport: Identifiable {
        let id: Int
        let name: String
        let ok: Bool
        let summary: String
        let log: URL
        let at: Date
        var heard = false
    }
    func addReport(_ r: HelperReport) {
        reports.removeAll { $0.id == r.id }
        reports.append(r)
        if reports.count > 12 { reports.removeFirst(reports.count - 12) }
    }
    func markHeard(_ ids: [Int]) {
        for i in reports.indices where ids.contains(reports[i].id) { reports[i].heard = true }
    }
    var waitingReports: [HelperReport] { reports.filter { !$0.heard } }
    /// The last three, from the last few hours.
    var recentReports: [HelperReport] { Array(reports.filter { Date().timeIntervalSince($0.at) < 4 * 3600 }.suffix(3).reversed()) }
    /// Dots beside the notch while idle: one per helper waiting to tell you, plus one for work going on.
    var dotCount: Int { min(3, waitingReports.count) + (agentsRunning > 0 ? 1 : 0) }

    var onCall: () -> Void = {}
    var onEnd: () -> Void = {}
    var onClear: () -> Void = {}
    var onTeacher: () -> Void = {}
    var onBuddy: () -> Void = {}
    var onSettings: () -> Void = {}
    var onUpdate: () -> Void = {}
    var onQuit: () -> Void = {}
    var onReceipts: () -> Void = {}
    var onQuiet: () -> Void = {}
    var onCopy: (String) -> Void = { _ in }
    var onPhoto: () -> Void = {}                    // a photo of your work from your iPhone (CallController+Photo.swift)
    var onPhotoFiles: ([URL]) -> Void = { _ in }    // pictures dropped on the notch

    /// Quiet mode (answers are written, nothing is played): a slashed speaker beside the idle notch, so it's never
    /// a surprise that Poinky doesn't talk. `writing`: the answer being given now is written, not said.
    @Published var quiet = false
    @Published var writing = false
    var quietGlyph: Bool { quiet && hasNotch }

    /// The last few answers (this run), newest last: the hover panel shows the latest as one line, and opens it
    /// in full with Copy (‹ › for the ones before). Nothing is lost when a caption fades.
    struct Answer: Identifiable {
        let id: Int            // the turn it answered
        let question: String
        var text: String
        var copy: String?      // the part meant to be pasted (a rewrite, a command), if any
        var at: Date
    }
    @Published private(set) var answers: [Answer] = []
    @Published var answerOpen = false
    @Published var answerBack = 0          // 0: the newest, 1: the one before…
    @Published var copiedAt = Date.distantPast
    func noteAnswer(turn: Int, question: String, text: String) {
        if let i = answers.lastIndex(where: { $0.id == turn }) {
            answers[i].text = text
            answers[i].at = Date()
        } else {
            answers.append(Answer(id: turn, question: question, text: text, copy: nil, at: Date()))
            if answers.count > 5 { answers.removeFirst(answers.count - 5) }
            answerBack = 0
        }
    }
    func finishAnswer(turn: Int, copy: String?) {
        if let i = answers.lastIndex(where: { $0.id == turn }) { answers[i].copy = copy }
    }
    var shownAnswer: Answer? { answers.isEmpty ? nil : answers[max(0, answers.count - 1 - min(answerBack, answers.count - 1))] }
    var showsAnswer: Bool { answers.last.map { Date().timeIntervalSince($0.at) < 12 * 3600 } ?? false }
    func copyShown() {
        guard let a = shownAnswer else { return }
        onCopy(a.copy ?? a.text)
        copiedAt = Date()
    }
    static let answerFont = NSFont.systemFont(ofSize: 12)
    var expandedWidth: CGFloat { max(notchWidth + 2 * Self.wing, answerOpen && showsAnswer ? 440 : 300) }
    /// The open answer's text, measured the way it's drawn (capped: longer ones scroll).
    var answerTextHeight: CGFloat {
        guard let a = shownAnswer else { return 0 }
        let r = (a.text as NSString).boundingRect(with: NSSize(width: expandedWidth - 34, height: 10_000),
                                                  options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: Self.answerFont])
        return min(210, ceil(r.height) + 4)
    }
    var answerBlockHeight: CGFloat { !showsAnswer ? 0 : answerOpen ? 18 + answerTextHeight + 32 + 6 : Self.lineRow }

    /// The last question's receipt, in a few words ("Screenshot + Preview: Lecture 5.pdf + your selection").
    /// Shown as one quiet line at the bottom of the hover panel; nothing until something was sent.
    @Published var receiptLine = ""
    @Published var receiptAt = Date.distantPast
    var receiptDetail = ""                  // the longer summary, for its tooltip
    var showsReceipt: Bool { !receiptLine.isEmpty && Date().timeIntervalSince(receiptAt) < 12 * 3600 }
    static let receiptRow: CGFloat = 20

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
    /// The next reminder within a day ("9:00 Email Professor Lee"), refreshed when the panel opens.
    @Published var nextReminder = ""
    // (The last answer has its own row now: `AnswerRow`.)
    var showsLastLine: Bool { agentsRunning > 0 || !nextReminder.isEmpty || (!showsAnswer && !lastLine.isEmpty && Date().timeIntervalSince(lastLineAt) < 60) }
    var infoLine: String {
        let agents = agentsRunning == 0 ? "" : (agentsRunning == 1 ? "1 agent working" : "\(agentsRunning) agents working")
        let recent = !showsAnswer && !lastLine.isEmpty && Date().timeIntervalSince(lastLineAt) < 60 ? lastLine : ""
        let reminder = nextReminder.isEmpty ? "" : "Reminder: " + nextReminder
        return [agents, reminder, recent].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    static let dotWing: CGFloat = 26

    var shapeSize: CGSize {
        let wide = notchWidth + 2 * Self.wing
        if expanded {
            return CGSize(width: expandedWidth, height: notchHeight + Self.buttonRow + (showsLastLine ? Self.lineRow : 0)
                          + answerBlockHeight
                          + CGFloat(recentReports.count) * Self.lineRow + (recentReports.isEmpty ? 0 : 4)
                          + (showsReceipt ? Self.receiptRow : 0) + 6)
        }
        if active { return CGSize(width: wide, height: notchHeight) }
        if beckon && hasNotch { return CGSize(width: max(notchWidth, 150) + 44, height: notchHeight + 6) }
        if dotCount > 0 || quietGlyph { return CGSize(width: notchWidth + 2 * (Self.dotWing + CGFloat(max(0, dotCount - 1)) * 10), height: notchHeight) }
        return CGSize(width: max(notchWidth, 1), height: notchHeight)
    }
    var visible: Bool { hasNotch || active || expanded || dotCount > 0 || (beckon && hasNotch) }

    /// Each helper's color (web/helpers.js has the same ones).
    static func color(of name: String) -> Color {
        switch name {
        case "Mint": return Color(red: 0.20, green: 0.79, blue: 0.56)
        case "Coral": return Color(red: 1.0, green: 0.48, blue: 0.35)
        case "Violet": return Color(red: 0.61, green: 0.42, blue: 1.0)
        case "Amber": return Color(red: 1.0, green: 0.69, blue: 0.13)
        case "Rose": return Color(red: 1.0, green: 0.36, blue: 0.60)
        case "Sky": return Color(red: 0.22, green: 0.74, blue: 0.97)
        default: return Color(red: 0.2, green: 0.8, blue: 0.75)
        }
    }
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
        if m.beckon && !m.active { return sbBlue }
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
        case "thinking": return m.lookingUp ? "Looking it up" : "Thinking"
        case "speaking": return m.writing ? "Writing" : "Speaking"
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
                .shadow(color: glow.opacity(m.active ? 0.55 + 0.4 * m.level : m.beckon ? 0.8 : 0), radius: 14, y: 3)
                .shadow(color: glow.opacity(m.active || m.beckon ? 0.35 : 0), radius: 4, y: 1)
            VStack(spacing: 0) {
                wings.frame(height: m.notchHeight)
                if m.expanded {
                    VStack(spacing: 0) {
                        if !m.recentReports.isEmpty {
                            VStack(spacing: 0) {
                                ForEach(m.recentReports) { r in ReportRow(m: m, r: r) }
                            }
                            .padding(.top, 4)
                        }
                        if m.showsAnswer { AnswerRow(m: m) }
                        if m.showsLastLine {
                            Text(m.infoLine)
                                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.62))
                                // A sentence keeps its end (what was just said); a reminder alone keeps its start.
                                .lineLimit(1).truncationMode(m.infoLine.hasPrefix("Reminder: ") ? .tail : .head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .frame(height: NotchModel.lineRow)
                                .notchTip(m, "info", infoTip)
                        }
                        buttons.frame(height: NotchModel.buttonRow)
                        if m.showsReceipt { ReceiptLine(m: m) }
                    }
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
        }
        .frame(width: size.width, height: size.height)
        // A picture dropped on the notch (it opens under the drag): the same as one from the phone.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            let m = m
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, PhotoFiles.isPicture(url) else { return }
                    DispatchQueue.main.async { m.onPhotoFiles([url]) }
                }
            }
            return !providers.isEmpty
        }
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
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: m.answerOpen)
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: m.quiet)
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: m.active)
        .animation(.spring(response: 0.4, dampingFraction: 0.72), value: m.beckon)
        .animation(.easeOut(duration: 0.25), value: m.phase)
        .animation(.easeOut(duration: 0.15), value: m.hoverButton)
        .animation(.easeOut(duration: 0.15), value: m.tip)
    }

    /// The two sides of the notch. Active: status and a visualizer. Hovered while idle: the two shortcuts.
    @ViewBuilder private var wings: some View {
        if !m.active && !m.expanded && (m.dotCount > 0 || m.quietGlyph) {
            HStack(spacing: 4) {
                if m.quietGlyph {
                    // Quiet mode, at a glance: a slashed speaker left of the notch.
                    Image(systemName: "speaker.slash.fill").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.leading, 9)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("Quiet mode is on")
                }
                Spacer()
                // Helpers that finished and are waiting to tell you, in their colors.
                ForEach(m.waitingReports.suffix(3)) { r in
                    Circle().fill(r.ok ? NotchModel.color(of: r.name) : Color.gray).frame(width: 6, height: 6)
                        .shadow(color: NotchModel.color(of: r.name).opacity(0.8), radius: 3)
                        .transition(.scale.combined(with: .opacity))
                }
                if m.agentsRunning > 0 {
                    TimelineView(.animation(minimumInterval: 1.0 / 20)) { tl in
                        let u = 0.5 + 0.5 * sin(tl.date.timeIntervalSinceReferenceDate * 3)
                        Circle().fill(sbTeal).frame(width: 6, height: 6).opacity(0.45 + 0.55 * u)
                            .shadow(color: sbTeal.opacity(0.9), radius: 3 + 2 * u)
                    }
                    .frame(width: 6, height: 6)
                }
            }
            .padding(.trailing, 10)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: m.dotCount)
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
                    if m.writing && m.phase == "speaking" {
                        // Answering in writing: no voice bars, a slashed speaker (the second cue besides the label).
                        Image(systemName: "speaker.slash.fill").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(glow).shadow(color: glow.opacity(0.7), radius: 3)
                    } else {
                        Visualizer(phase: m.guide && m.phase == "ready" ? "guide" : m.phase, level: m.level, color: glow)
                            .opacity(m.active ? 1 : 0)
                    }
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
        case "thinking": return m.lookingUp ? "Looking it up for you. Tap \(h) to cancel." : "Thinking about your question. Tap \(h) to cancel."
        case "speaking": return m.writing ? "Writing the answer (quiet: nothing is said). Hold \(h) to cut in, or tap it to stop." : "Speaking. Hold \(h) to cut in with a new question, or tap it to stop."
        case "starting": return "Waking up the Claude sessions…"
        default: return "Hold \(h) and talk, let go to send. Drag while holding to mark things. A quick tap stops me."
        }
    }

    private var rightTip: String {
        if m.inCall { return "In a hands-free call: the mic is on. \(m.callKeys) or say bye to end it." }
        switch m.phase {
        case "listening": return "Your voice level"
        case "speaking": return m.writing ? "Quiet: written, not said" : "My voice"
        case "thinking", "starting": return "Working on it"
        default: return "\(m.callKeys) starts a hands-free call: the mic stays on and a pause ends each question."
        }
    }

    private var infoTip: String {
        var parts: [String] = []
        if m.agentsRunning > 0 { parts.append("Background agents are working on your projects. I'll tell you when they finish.") }
        if !m.nextReminder.isEmpty { parts.append("Your next reminder (see them all in Settings → General).") }
        if !m.showsAnswer, !m.lastLine.isEmpty { parts.append("The last thing I said.") }
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
            NotchIcon(m: m, id: "quiet", icon: m.quiet ? "speaker.slash.fill" : "speaker.wave.2",
                      tip: m.quiet ? "Quiet mode is on: I write my answers and play no sounds. Click to talk out loud again (⌃⌥Q)."
                                   : "Quiet mode: write answers instead of saying them, for a library, a lecture or a call (⌃⌥Q)",
                      tint: m.quiet ? sbOrange : nil, action: m.onQuiet)
            NotchIcon(m: m, id: "photo", icon: "camera",
                      tip: "Show me something on paper: a photo from your iPhone (⌃⌥P). Or drop a picture or PDF here.", action: m.onPhoto)
            NotchIcon(m: m, id: "teacher", icon: "pencil.and.scribble", tip: m.teacherOn ? "Teacher on: explanations get a hand-drawn sketch or a 3D model. Click to turn off." : "Teacher off: voice and quick marks only. Click to turn on.",
                      tint: m.teacherOn ? sbBlue : nil, dim: !m.teacherOn, action: m.onTeacher)
            if m.sessionOn && !m.inCall {
                NotchIcon(m: m, id: "end", icon: "stop.circle", tip: "End the session (clears the screen; the next \(m.holdKeys) starts a new one)", action: m.onEnd)
            }
            if !m.update.isEmpty {
                NotchIcon(m: m, id: "update", icon: m.update == "ready" ? "arrow.down.circle.fill" : "arrow.down.circle",
                          tip: m.update == "ready" ? "The new version of Poinky is ready: click to restart into it" : "A new version of Poinky is available: click to see what's new and update",
                          tint: Color.green, action: m.onUpdate)
            }
            NotchIcon(m: m, id: "settings", icon: "gearshape", tip: "Settings: voice, shortcuts, Claude models, memory, privacy", action: m.onSettings)
            NotchIcon(m: m, id: "quit", icon: "power", tip: "Quit Poinky (stops background agents too)", action: m.onQuit)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
}

/// One finished helper in the hover panel: its name in its color and what it did. Click to read its log.
struct ReportRow: View {
    @ObservedObject var m: NotchModel
    let r: NotchModel.HelperReport

    var body: some View {
        let hot = m.hoverButton == "report\(r.id)"
        Button { m.onOpenReport(r) } label: {
            HStack(spacing: 6) {
                Circle().fill(r.ok ? NotchModel.color(of: r.name) : Color.gray).frame(width: 6, height: 6)
                Text(r.name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(NotchModel.color(of: r.name))
                Text((r.ok ? "" : "Couldn’t finish · ") + Self.firstSentence(r.summary))
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(Self.ago(r.at)).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.38)).monospacedDigit()
            }
            .padding(.horizontal, 10)
            .frame(height: NotchModel.lineRow)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hot ? 0.09 : 0)))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPress())
        .notchTip(m, "report\(r.id)", r.summary.count > 170 ? String(r.summary.prefix(169)) + "… (click for the full log)" : r.summary + " (click for the full log)")
    }

    static func firstSentence(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: #"^.{12,}?[.!?](\s|$)"#, options: .regularExpression) { return String(t[r]).trimmingCharacters(in: .whitespaces) }
        return t
    }
    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        return s < 60 ? "now" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h"
    }
}

/// The last answer: one line (click to read all of it), with Copy right there. Open, it shows the whole answer
/// (scrolling when long), what it answered, Copy, and ‹ › for the few before it.
struct AnswerRow: View {
    @ObservedObject var m: NotchModel

    private static func rtl(_ s: String) -> Bool {
        for u in s.unicodeScalars {
            if (0x0590...0x08FF).contains(u.value) { return true }
            if CharacterSet.letters.contains(u) { return false }
        }
        return false
    }

    var body: some View {
        if let a = m.shownAnswer {
            let copied = Date().timeIntervalSince(m.copiedAt) < 1.5
            if m.answerOpen {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(a.question.isEmpty ? "Poinky said" : "You: \u{2068}" + a.question.replacingOccurrences(of: "\n", with: " ") + "\u{2069}")
                            .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(ReportRow.ago(a.at)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.38)).monospacedDigit()
                    }
                    .frame(height: 14)
                    ScrollView(.vertical) {
                        Text(a.text)
                            .font(Font(NotchModel.answerFont)).foregroundStyle(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.layoutDirection, Self.rtl(a.text) ? .rightToLeft : .leftToRight)
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: m.answerTextHeight)
                    HStack(spacing: 6) {
                        if m.answers.count > 1 {
                            NotchSmallButton(m: m, id: "ansPrev", icon: "chevron.left", tip: "The answer before", disabled: m.answerBack >= m.answers.count - 1) { m.answerBack += 1 }
                            Text("\(m.answers.count - m.answerBack) of \(m.answers.count)").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).monospacedDigit()
                            NotchSmallButton(m: m, id: "ansNext", icon: "chevron.right", tip: "The next answer", disabled: m.answerBack == 0) { m.answerBack -= 1 }
                        }
                        Spacer()
                        NotchSmallButton(m: m, id: "ansClose", icon: "chevron.up", tip: "Show less") { m.answerOpen = false }
                        Button { m.copyShown() } label: {
                            Text(copied ? "Copied ✓" : (a.copy != nil ? "Copy text" : "Copy"))
                                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 11).frame(height: 24)
                                .background(Capsule().fill(sbBlue.opacity(m.hoverButton == "ansCopy" ? 1 : 0.8)))
                                .overlay(Capsule().stroke(Color.white.opacity(m.hoverButton == "ansCopy" ? 0.4 : 0), lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(NotchPress())
                        .pointerStyle(.link)
                        .notchTip(m, "ansCopy", a.copy != nil ? "Copy just the text to use: \(Recall.clip(a.copy ?? "", 90))" : "Copy the whole answer")
                    }
                    .frame(height: 26)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .frame(height: m.answerBlockHeight)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                    Text(a.text.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(m.hoverButton == "answer" ? 0.85 : 0.62))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    NotchSmallButton(m: m, id: "ansCopyRow", icon: copied ? "checkmark" : "doc.on.doc",
                                     tip: a.copy != nil ? "Copy the text to use" : "Copy the last answer") { m.copyShown() }
                }
                .padding(.horizontal, 10)
                .frame(height: NotchModel.lineRow)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(m.hoverButton == "answer" ? 0.09 : 0)))
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
                .onTapGesture { m.answerOpen = true }
                .pointerStyle(.link)
                .notchTip(m, "answer", "My last answer. Click to read all of it.")
            }
        }
    }
}

/// A small icon button in the hover panel (‹ › and Copy beside the answer).
struct NotchSmallButton: View {
    @ObservedObject var m: NotchModel
    let id: String
    let icon: String
    let tip: String
    var disabled = false
    let action: () -> Void
    var body: some View {
        let hot = m.hoverButton == id && !disabled
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(disabled ? 0.2 : hot ? 0.95 : 0.6))
                .frame(width: 24, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(hot ? 0.12 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchPress())
        .pointerStyle(.link)
        .disabled(disabled)
        .notchTip(m, id, tip)
    }
}

/// "What I saw": the last question's receipt in one quiet line. Click for the full receipt.
struct ReceiptLine: View {
    @ObservedObject var m: NotchModel

    var body: some View {
        let hot = m.hoverButton == "receipt"
        Button { m.onReceipts() } label: {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.system(size: 8, weight: .semibold))
                Text("What I saw").font(.system(size: 10.5, weight: .semibold))
                Text(m.receiptLine).font(.system(size: 10.5)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(ReportRow.ago(m.receiptAt)).font(.system(size: 10)).monospacedDigit()
            }
            .foregroundStyle(.white.opacity(hot ? 0.75 : 0.4))
            .padding(.horizontal, 10)
            .frame(height: NotchModel.receiptRow - 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(hot ? 0.07 : 0)))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchPress())
        .padding(.bottom, 2)
        .notchTip(m, "receipt", "Your last question sent Claude: \(m.receiptDetail). Click to see the screenshot, every line, and earlier questions. Kept only on this Mac.")
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
        .buttonStyle(NotchPress())
        .pointerStyle(.link)
        .notchTip(m, id, tip)
    }
}

/// Pressed: a touch smaller and dimmer, so a click is felt (hover is `hoverButton`, from `.onHover`).
struct NotchPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
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
    private static let panelSize = CGSize(width: 680, height: 520)   // room for an opened answer (it's click-through outside the shape)

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
        if on { model.nextReminder = Reminders.nextLine() ?? "" }
        model.expanded = on
        if !on { model.clearTip(); model.answerOpen = false; model.answerBack = 0 }
        panel?.ignoresMouseEvents = !on
    }

    /// Developer check (`--notch-shot <out.png>`): the hover panel, opened, with sample content, then quit.
    static func snapshot(to out: String) {
        let m = NotchModel()
        m.hasNotch = true; m.notchWidth = 190; m.notchHeight = 32; m.expanded = true
        m.nextReminder = Reminders.nextLine() ?? "9:00 Email Professor Lee about the lab report"
        if let r = Receipts.latest { m.receiptLine = r.short; m.receiptDetail = r.summary; m.receiptAt = r.at }
        else if ProcessInfo.processInfo.environment["POINKY_SHOT_RECEIPT"] != "0" {
            m.receiptLine = "Preview: Lecture 5.pdf + selection"; m.receiptAt = Date().addingTimeInterval(-120)
        }
        // POINKY_SHOT_ANSWER=row|open|long|hebrew (the last answer), POINKY_SHOT_QUIET=1 (quiet mode), POINKY_SHOT_IDLE=1 (closed).
        let env = ProcessInfo.processInfo.environment
        m.quiet = env["POINKY_SHOT_QUIET"] == "1"
        if env["POINKY_SHOT_IDLE"] == "1" { m.expanded = false }
        if let kind = env["POINKY_SHOT_ANSWER"] {
            m.noteAnswer(turn: 1, question: "what does mitochondria mean", text: "Mitochondria are the parts of a cell that turn food into energy the cell can use.")
            let text: String
            switch kind {
            case "long": text = (1...14).map { "Step \($0): this part of the answer explains one more thing in a full sentence, so it runs long." }.joined(separator: " ")
            case "hebrew": text = "המיטוכונדריה היא החלק בתא שהופך מזון לאנרגיה. בלעדיה התא לא יכול לעבוד."
            default: text = "Here's a punchier version: We ship Friday, tested and ready. Want me to swap it in?"
            }
            m.noteAnswer(turn: 2, question: kind == "hebrew" ? "מה זה מיטוכונדריה?" : "make this paragraph punchier", text: text)
            if kind == "open" { m.finishAnswer(turn: 2, copy: "We ship Friday, tested and ready.") }
            m.answerOpen = kind != "row"
        }
        let size = CGSize(width: max(420, m.shapeSize.width + 40), height: max(140, m.shapeSize.height + 20))
        let host = NSHostingView(rootView: NotchView(m: m).frame(width: size.width, height: size.height).background(Color.gray.opacity(0.35)))
        let w = NSWindow(contentRect: CGRect(x: -3000, y: 0, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
            NSApp.terminate(nil)
        }
    }

    /// Closes the panel (after one of its buttons was used).
    func collapse() { setExpanded(false); hoverSince = Double.greatestFiniteMagnitude }
}
