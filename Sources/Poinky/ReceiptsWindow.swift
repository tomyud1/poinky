import AppKit
import SwiftUI

/// "What I saw": the receipts of the last questions (`Receipts`), opened from the notch's lock line
/// or Settings → Privacy. The screenshot that went out, every line sent, and what else was included.
@MainActor
final class ReceiptsModel: ObservableObject {
    @Published var list: [Receipt] = []          // newest first
    @Published var selected: String?
    @Published var on = true
    var onSettings: () -> Void = {}

    func reload() {
        let followNewest = selected == nil || selected == list.first?.id
        list = Receipts.all().reversed()
        on = Receipts.enabled
        if followNewest || !list.contains(where: { $0.id == selected }) { selected = list.first?.id }
    }
    var current: Receipt? { list.first { $0.id == selected } }
}

@MainActor
final class ReceiptsWindow {
    static let shared = ReceiptsWindow()
    let model = ReceiptsModel()
    private var window: NSWindow?

    func show() {
        model.reload()
        model.selected = model.list.first?.id
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: ReceiptsView(m: model)))
            w.title = "What Poinky Saw"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(CGSize(width: 780, height: 540))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Developer check (`--receipts-shot <out.png>`): a picture of the window with what's stored, then quit.
    static func snapshot(to out: String) {
        let m = ReceiptsModel()
        m.reload()
        let host = NSHostingView(rootView: ReceiptsView(m: m).frame(width: 780, height: 560))
        let w = NSWindow(contentRect: CGRect(x: -3000, y: 0, width: 780, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
            NSApp.terminate(nil)
        }
    }
}

struct ReceiptsView: View {
    @ObservedObject var m: ReceiptsModel

    var body: some View {
        VStack(spacing: 0) {
            if m.list.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "lock").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(m.on ? "Nothing sent yet" : "Receipts are off").font(.headline)
                    Text(m.on ? "When you ask something, what went to Claude shows up here: the screenshot and every line."
                              : "Turn them on in Settings → Privacy to see what each question sends.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(selection: $m.selected) {
                        ForEach(m.list) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.question.isEmpty ? "Background update" : "“\(r.question)”")
                                    .font(.system(size: 12, weight: .medium)).lineLimit(2)
                                Text(Self.when(r.at) + " · " + r.summary)
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.vertical, 3)
                            .tag(r.id)
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(width: 250)
                    Divider()
                    if let r = m.current { ReceiptDetail(r: r).id(r.id) } else { Spacer() }
                }
            }
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.system(size: 11))
                Text("Kept only on this Mac (the last \(Receipts.keep)). Poinky looks only when you ask.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Privacy Settings…") { m.onSettings() }
                Button("Clear", role: .destructive) { Receipts.clear(); m.reload() }.disabled(m.list.isEmpty)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: d)
    }
}

private struct ReceiptDetail: View {
    let r: Receipt

    private var who: String {
        let role = r.role == "guide" ? "walking you through it" : r.role == "doer" ? "doing it for you" : "answering"
        return "Sent to Claude (\(r.brain), \(r.model)) for \(role) · \(ReceiptsView.when(r.at))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(r.question.isEmpty ? "A background update (nobody asked)" : "“\(r.question)”")
                        .font(.title3.weight(.semibold)).textSelection(.enabled)
                    Text(who).font(.callout).foregroundStyle(.secondary)
                }
                block("Screenshot") {
                    if let img = NSImage(contentsOf: Receipts.thumbURL(r.id)), img.size.width > 0 {
                        let h = min(260, 460 * img.size.height / img.size.width)
                        Image(nsImage: img).resizable()
                            .frame(width: h * img.size.width / img.size.height, height: h)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.12)))
                    }
                    Text("Your whole screen, \(r.size.replacingOccurrences(of: "x", with: " × ")) pixels\(r.closeUp ? ", plus a sharp close-up of what you marked" : "")\(r.steps > 0 ? ". \(r.steps) more screenshot\(r.steps == 1 ? "" : "s") during this walkthrough (the newest shown)" : ""). Apps excluded in Settings → Privacy are left out.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                block("From the app in front") {
                    if r.front.isEmpty {
                        Text(r.role == "talker" ? "Nothing: the app shared no title, document, page or selection (or it's off in Settings → Privacy)." : "Not sent for walkthroughs.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(r.front.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 12)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.secondary.opacity(0.12)))
                        }
                    }
                }
                block("Also in Claude's instructions this session") {
                    if r.parts.isEmpty {
                        Text("Only Poinky's built-in instructions.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(r.parts.enumerated()), id: \.offset) { _, p in
                            HStack {
                                Text(p.name).font(.callout)
                                Spacer()
                                Text(Self.size(p.chars)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        Text("Read once when the session starts, from your files (Settings → Memory).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !r.lookups.isEmpty || !r.also.isEmpty {
                    block("Also") {
                        ForEach(Array((r.lookups + r.also).enumerated()), id: \.offset) { _, l in
                            Label(l, systemImage: l.hasPrefix("Web") ? "globe" : l.hasPrefix("Looked") ? "clock.arrow.circlepath" : "pencil.and.scribble")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                DisclosureGroup("Everything sent with the screenshot, word for word") {
                    Text(r.message).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                .font(.callout)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func block<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    static func size(_ chars: Int) -> String {
        chars < 1000 ? "\(chars) characters" : String(format: "%.1fk characters", Double(chars) / 1000)
    }
}
