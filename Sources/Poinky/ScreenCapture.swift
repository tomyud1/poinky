import AppKit
import ScreenCaptureKit

/// Something the user drew with ⌥ + click. Points are in screen points, origin top-left.
struct Mark {
    enum Kind { case pin, stroke }
    var kind: Kind
    var points: [CGPoint]
}

/// One screenshot ready to send to Claude.
struct Snapshot {
    let jpegBase64: String
    let width: Int          // image pixels
    let height: Int
    let scale: CGFloat      // image pixels per screen point
    let notes: [String]     // cursor + marks, in image pixels
    let text: TextIndex     // where each word is (filled in the background)
    var focus: FocusCrop? = nil   // a sharp close-up of what you marked
}

/// A close-up of the area you marked, plus the text your Mac read inside it.
struct FocusCrop {
    let jpegBase64: String
    let text: String
    let rectPx: CGRect      // where it is in the full screenshot (pixels)
    var rectPoints: CGRect = .zero   // the same, in screen points
}

enum CaptureError: LocalizedError {
    case noDisplay, encodeFailed
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Couldn't find the display to capture."
        case .encodeFailed: return "Couldn't encode the screenshot."
        }
    }
}

enum ScreenCapture {
    /// Actually tries to list the screen's content: more reliable than CGPreflightScreenCaptureAccess,
    /// which can report "no" on newer macOS even when access is switched on.
    static func hasPermission() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    /// Claude shrinks bigger images before looking at them, which would make its
    /// coordinates come back too small. Staying under both limits keeps them 1:1.
    static let maxEdge: CGFloat = 1568
    static let maxPixels: CGFloat = 1_150_000

    /// Image pixels per screen point for a screenshot of this screen size.
    static func imageScale(for size: CGSize) -> CGFloat {
        min(1, maxEdge / max(size.width, size.height), (maxPixels / (size.width * size.height)).squareRoot())
    }

    /// Apps never captured (Settings → Privacy).
    @MainActor static var excludedBundleIDs: Set<String> = []
    /// Poinky's own windows that screenshots should still show (a video playing full screen).
    @MainActor static var includedWindowNumbers: Set<Int> = []

    /// The whole screen, minus our own overlay and any excluded apps.
    private static func filter(for screen: NSScreen) async throws -> SCContentFilter {
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let excluded = await MainActor.run { excludedBundleIDs }
        let mine = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier || excluded.contains($0.bundleIdentifier)
        }
        let include = await MainActor.run { includedWindowNumbers }
        let keep = content.windows.filter { include.contains(Int($0.windowID)) }
        return SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: keep)
    }

    /// A sharp close-up of what you marked, plus its text. Taken right when you mark it,
    /// so it still works if you scroll before asking.
    static func focusCrop(screen: NSScreen, marks: [Mark]) async -> FocusCrop? {
        let size = screen.frame.size
        guard let r = focusRect(marks: marks, screen: size), let filter = try? await filter(for: screen) else { return nil }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = r
        let k = min(2.0, 1200 / max(r.width, r.height))
        cfg.width = Int(r.width * k)
        cfg.height = Int(r.height * k)
        cfg.showsCursor = false
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg),
              let jpeg = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        let scale = imageScale(for: size)
        let text = await Task.detached { TextIndex.readLines(img) }.value
        return FocusCrop(jpegBase64: jpeg.base64EncodedString(), text: text,
                         rectPx: CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale),
                         rectPoints: r)
    }

    static func capture(screen: NSScreen, marks: [Mark], cursor: CGPoint?, focus: FocusCrop? = nil) async throws -> Snapshot {
        let filter = try await filter(for: screen)
        let size = screen.frame.size
        let scale = imageScale(for: size)
        let w = Int((size.width * scale).rounded())
        let h = Int((size.height * scale).rounded())

        let cfg = SCStreamConfiguration()
        cfg.width = w
        cfg.height = h
        cfg.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureError.encodeFailed
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Draw the user's marks in red so Claude sees exactly what they circled.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setStrokeColor(CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1))
        ctx.setFillColor(CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for m in marks {
            switch m.kind {
            case .stroke:
                ctx.setLineWidth(5)
                ctx.addLines(between: m.points)
                ctx.strokePath()
            case .pin:
                guard let c = m.points.first else { continue }
                ctx.setLineWidth(4)
                ctx.strokeEllipse(in: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28))
                ctx.fillEllipse(in: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
            }
        }

        guard let out = ctx.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
        else { throw CaptureError.encodeFailed }

        let text = TextIndex()
        text.start(out)
        var snap = Snapshot(jpegBase64: jpeg.base64EncodedString(), width: w, height: h, scale: scale,
                            notes: describe(marks: marks, cursor: cursor, scale: scale), text: text)

        // What you marked: the close-up taken when you marked it, or take one now.
        if let f = focus { snap.focus = f } else if !marks.isEmpty { snap.focus = await focusCrop(screen: screen, marks: marks) }
        return snap
    }

    /// The area around your marks (screen points), padded a little.
    static func focusRect(marks: [Mark], screen: CGSize) -> CGRect? {
        guard !marks.isEmpty else { return nil }
        var box = CGRect.null
        for m in marks {
            for p in m.points {
                let grow: CGFloat = m.kind == .pin ? 110 : 0
                box = box.union(CGRect(x: p.x - grow, y: p.y - grow * 0.6, width: grow * 2, height: grow * 1.2))
            }
        }
        box = box.insetBy(dx: -28, dy: -28)
        if box.width < 200 { box = box.insetBy(dx: -(200 - box.width) / 2, dy: 0) }
        if box.height < 120 { box = box.insetBy(dx: 0, dy: -(120 - box.height) / 2) }
        return box.intersection(CGRect(origin: .zero, size: screen)).integral
    }

    private static func describe(marks: [Mark], cursor: CGPoint?, scale: CGFloat) -> [String] {
        func px(_ v: CGFloat) -> Int { Int((v * scale).rounded()) }
        var notes: [String] = []
        if let c = cursor {
            notes.append("Mouse cursor is at (\(px(c.x)), \(px(c.y))) (just where the mouse is: a hint for \"this\"/\"here\", not necessarily the topic).")
        }
        for m in marks {
            switch m.kind {
            case .pin:
                if let p = m.points.first { notes.append("User dropped a red pin at (\(px(p.x)), \(px(p.y))).") }
            case .stroke:
                let xs = m.points.map(\.x), ys = m.points.map(\.y)
                guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
                      let first = m.points.first, let last = m.points.last else { continue }
                let closed = hypot(first.x - last.x, first.y - last.y) < max(40, (maxX - minX + maxY - minY) * 0.25)
                let shape = closed ? "circled an area" : "drew a red line"
                notes.append("User \(shape) spanning x \(px(minX))–\(px(maxX)), y \(px(minY))–\(px(maxY)).")
            }
        }
        return notes
    }
}
