import AppKit
import CoreText

/// Keeps a picture of a paper lesson (the paper's Save button), so students can revise from it later.
/// It goes to the Desktop; if that can't be written, to Pictures/Poinky.
enum LessonSaver {
    /// Writes the picture (PNG data URL, or SVG text when the page couldn't make a PNG). Returns where it went.
    static func save(title: String, pngDataURL: String?, svg: String?, now: Date = Date()) -> URL? {
        let data: Data, ext: String
        if let png = pngDataURL, let comma = png.firstIndex(of: ","),
           let d = Data(base64Encoded: String(png[png.index(after: comma)...])) {
            data = d; ext = "png"
        } else if let svg, let d = svg.data(using: .utf8) {
            data = d; ext = "svg"
        } else { return nil }
        return write(data, name: fileName(title: title, now: now, ext: ext), ext: ext)
    }

    /// Writes `data` as `name` in the first folder that takes it (never over an earlier file).
    private static func write(_ data: Data, name: String, ext: String) -> URL? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment["POINKY_LESSON_DIR"].map { URL(fileURLWithPath: $0) }
        let home = fm.homeDirectoryForCurrentUser
        let places = [env, home.appendingPathComponent("Desktop"), home.appendingPathComponent("Pictures/Poinky")].compactMap { $0 }
        for dir in places {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var url = dir.appendingPathComponent(name)
            var n = 2
            while fm.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent(name.replacingOccurrences(of: ".\(ext)", with: " \(n).\(ext)")); n += 1
            }
            if (try? data.write(to: url)) != nil { return url }
        }
        return nil
    }

    // MARK: The session's notebook

    /// Saves every page of a session as one PDF ("Save all", or "save my notes"): each page with its title,
    /// in order, for revising later. `pages`: (title, PNG data URL). Returns where it went.
    static func saveNotebook(pages: [(title: String, png: String)], now: Date = Date()) -> URL? {
        let images = pages.compactMap { p -> (String, CGImage)? in
            guard let comma = p.png.firstIndex(of: ","), let d = Data(base64Encoded: String(p.png[p.png.index(after: comma)...])),
                  let src = CGImageSourceCreateWithData(d as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return (p.title, img)
        }
        guard !images.isEmpty, let data = notebookPDF(images, now: now) else { return nil }
        let first = images.first { !$0.0.isEmpty }?.0 ?? ""
        return write(data, name: fileName(title: first, now: now, ext: "pdf", notes: true), ext: "pdf")
    }

    /// The PDF: one page per paper, each as tall as its drawing, the title and "page 2 of 3" on top.
    static func notebookPDF(_ pages: [(String, CGImage)], now: Date = Date()) -> Data? {
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData) else { return nil }
        let pageW: CGFloat = 612, margin: CGFloat = 36, head: CGFloat = 58
        var box = CGRect(x: 0, y: 0, width: pageW, height: 792)
        let info = [kCGPDFContextTitle: "Poinky notes" as CFString, kCGPDFContextCreator: "Poinky" as CFString] as CFDictionary
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, info) else { return nil }
        let f = DateFormatter(); f.dateFormat = "MMMM d, yyyy"
        for (i, (title, img)) in pages.enumerated() {
            let w = pageW - 2 * margin, h = w * CGFloat(img.height) / CGFloat(max(1, img.width))
            var media = CGRect(x: 0, y: 0, width: pageW, height: head + h + margin)
            ctx.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(media)
            let titleText = title.isEmpty ? "Page \(i + 1)" : title
            draw(titleText, font: NSFont.systemFont(ofSize: 17, weight: .semibold), color: NSColor(white: 0.13, alpha: 1),
                 at: CGPoint(x: margin, y: media.height - 34), in: ctx)
            draw("\(i + 1) of \(pages.count)  ·  \(f.string(from: now))", font: NSFont.systemFont(ofSize: 10), color: NSColor(white: 0.5, alpha: 1),
                 at: CGPoint(x: margin, y: media.height - 50), in: ctx)
            let r = CGRect(x: margin, y: margin, width: w, height: h)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil)); ctx.clip()
            ctx.interpolationQuality = .high
            ctx.draw(img, in: r)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return out as Data
    }

    private static func draw(_ s: String, font: NSFont, color: NSColor, at p: CGPoint, in ctx: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    /// "Poinky – the chain rule – Nov 15.png": the title made safe for a file name.
    static func fileName(title: String, now: Date, ext: String, notes: Bool = false) -> String {
        var t = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }.joined(separator: " ")
        if t.count > 60 { t = String(t.prefix(60)).trimmingCharacters(in: .whitespaces) }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let date = f.string(from: now)
        if notes { return t.isEmpty ? "Poinky notes – \(date).\(ext)" : "Poinky notes – \(t) – \(date).\(ext)" }
        return t.isEmpty ? "Poinky lesson – \(date).\(ext)" : "Poinky – \(t) – \(date).\(ext)"
    }

    /// Where it went, in plain words for the button ("Desktop", "Pictures").
    static func placeName(_ url: URL) -> String {
        let dir = url.deletingLastPathComponent()
        return dir.lastPathComponent == "Poinky" ? "Pictures" : dir.lastPathComponent
    }
}
