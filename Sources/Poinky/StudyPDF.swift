import AppKit
import CoreText
import PDFKit

/// The solved homework: one PDF that grows as you go. The sheet's own pages first (copied from its PDF, so
/// they stay sharp), then each question's parts in order, each under a small heading, with the user's own
/// work (their cleaned photos) and/or Poinky's worked papers, as chosen per part. A4, right to left when
/// the sheet is Hebrew. It's written next to the sheet (or on the Desktop) under a stable name, and Poinky
/// only ever replaces a file it made itself.
enum StudyPDF {
    static let a4 = CGSize(width: 595.28, height: 841.89)
    static let margin: CGFloat = 42
    static let creator = "Poinky study"

    /// Where it goes: the file made last time, else "<sheet> – solved.pdf" beside the sheet (or in
    /// POINKY_LESSON_DIR / the Desktop), never over a file Poinky didn't make.
    static func outputURL(_ s: StudySheet) -> URL {
        let fm = FileManager.default
        if let o = s.output, fm.fileExists(atPath: o), madeByPoinky(URL(fileURLWithPath: o)) { return URL(fileURLWithPath: o) }
        let env = ProcessInfo.processInfo.environment["POINKY_LESSON_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let doc = s.document.map { URL(fileURLWithPath: $0) }
        var dir = env ?? doc?.deletingLastPathComponent() ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        if !fm.isWritableFile(atPath: dir.path) { dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop") }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var stem = doc?.deletingPathExtension().lastPathComponent ?? s.title
        stem = stem.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if stem.isEmpty { stem = "Homework" }
        let suffix = s.hebrew ? "פתרון" : "solved"
        var url = dir.appendingPathComponent("\(stem) – \(suffix).pdf")
        var n = 2
        while fm.fileExists(atPath: url.path) && !madeByPoinky(url) {
            url = dir.appendingPathComponent("\(stem) – \(suffix) \(n).pdf"); n += 1
        }
        return url
    }

    static func madeByPoinky(_ url: URL) -> Bool {
        guard let doc = PDFDocument(url: url) else { return false }
        return (doc.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String) == creator
    }

    /// Something to put in it yet?
    static func hasContent(_ s: StudySheet) -> Bool {
        s.questions.contains { $0.parts.contains { p in let c = p.pdfContent; return !c.mine.isEmpty || !c.poinky.isEmpty } }
    }

    /// Builds the PDF and writes it. Returns where it went.
    @discardableResult
    static func build(_ s: StudySheet, to out: URL? = nil) -> URL? {
        let url = out ?? outputURL(s)
        guard let data = render(s) else { return nil }
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        guard (try? data.write(to: tmp)) != nil else { return nil }
        _ = try? FileManager.default.removeItem(at: url)
        guard (try? FileManager.default.moveItem(at: tmp, to: url)) != nil else { return nil }
        return url
    }

    static func render(_ s: StudySheet) -> Data? {
        let out = NSMutableData()
        guard let consumer = CGDataConsumer(data: out as CFMutableData) else { return nil }
        var box = CGRect(origin: .zero, size: a4)
        let title = s.title.isEmpty ? "Homework" : s.title
        let info = [kCGPDFContextTitle: title as CFString, kCGPDFContextCreator: creator as CFString] as CFDictionary
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box, info) else { return nil }
        var pageNo = 0
        func begin(_ size: CGSize = a4) {
            var media = CGRect(origin: .zero, size: size)
            ctx.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            pageNo += 1
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(media)
        }

        // 1. The sheet itself.
        if let path = s.document, StudySource.isPDF(URL(fileURLWithPath: path)), let doc = PDFDocument(url: URL(fileURLWithPath: path)) {
            let wanted = doc.pageCount <= 12 ? Array(0..<doc.pageCount)
                : Array(Set(s.questions.flatMap(\.sourcePages))).sorted()
            for i in wanted {
                guard let page = doc.page(at: i) else { continue }
                let b = page.bounds(for: .mediaBox)
                begin(CGSize(width: b.width, height: b.height))
                ctx.saveGState()
                page.draw(with: .mediaBox, to: ctx)
                ctx.restoreGState()
                ctx.endPDFPage()
            }
        } else {
            for q in s.questions {
                guard let shot = q.shot, let img = image(StudyStore.url(shot, sheet: s.id)) else { continue }
                var y = a4.height - margin
                begin()
                y = heading(questionTitle(q, s), at: y, in: ctx, hebrew: s.hebrew, size: 16)
                _ = place(img, top: y, in: ctx, newPage: { begin(); return a4.height - margin }, endPage: { footer(pageNo, ctx); ctx.endPDFPage() })
                footer(pageNo, ctx); ctx.endPDFPage()
            }
        }

        // 2. Each question's parts, in order.
        for q in s.questions {
            for p in q.parts {
                let c = p.pdfContent
                guard !c.mine.isEmpty || !c.poinky.isEmpty else { continue }
                begin()
                var y = a4.height - margin
                y = heading(partTitle(q, p, s), at: y, in: ctx, hebrew: s.hebrew, size: 17)
                if !p.text.isEmpty { y = paragraph(p.text, at: y, in: ctx, hebrew: s.hebrew) }
                func section(_ label: String, _ files: [String]) {
                    if y < margin + 120 { footer(pageNo, ctx); ctx.endPDFPage(); begin(); y = a4.height - margin }
                    y = heading(label, at: y - 6, in: ctx, hebrew: s.hebrew, size: 12, gray: true)
                    for f in files {
                        guard let img = image(StudyStore.url(f, sheet: s.id)) else { continue }
                        y = place(img, top: y, in: ctx, newPage: { begin(); return a4.height - margin },
                                  endPage: { footer(pageNo, ctx); ctx.endPDFPage() }) - 14
                    }
                }
                if !c.mine.isEmpty { section(s.hebrew ? "הפתרון שלי" : "My solution", c.mine) }
                if !c.poinky.isEmpty {
                    section(c.mine.isEmpty ? (s.hebrew ? "פתרון" : "Solution")
                                           : (s.hebrew ? "פתרון מודרך (Poinky)" : "Worked solution (Poinky)"), c.poinky)
                }
                footer(pageNo, ctx)
                ctx.endPDFPage()
            }
        }
        ctx.closePDF()
        return pageNo == 0 ? nil : out as Data
    }

    static func questionTitle(_ q: StudyQuestion, _ s: StudySheet) -> String {
        s.hebrew ? "שאלה \(q.number)" : "Question \(q.number)"
    }
    static func partTitle(_ q: StudyQuestion, _ p: StudyPart, _ s: StudySheet) -> String {
        if p.label.isEmpty || q.parts.count == 1 && p.label == "" { return questionTitle(q, s) }
        return s.hebrew ? "שאלה \(q.number) · סעיף \(p.label)" : "Question \(q.number) · Part \(p.label)"
    }

    // MARK: Drawing

    static func image(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// A line of text at the top margin, right-aligned for Hebrew. Returns the y under it.
    static func heading(_ text: String, at top: CGFloat, in ctx: CGContext, hebrew: Bool, size: CGFloat, gray: Bool = false) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: gray ? .medium : .semibold)
        return block(text, font: font, color: gray ? NSColor(white: 0.45, alpha: 1) : NSColor(white: 0.1, alpha: 1), top: top, in: ctx, hebrew: hebrew) - (gray ? 8 : 6)
    }

    static func paragraph(_ text: String, at top: CGFloat, in ctx: CGContext, hebrew: Bool) -> CGFloat {
        block(text, font: NSFont.systemFont(ofSize: 11), color: NSColor(white: 0.25, alpha: 1), top: top, in: ctx, hebrew: hebrew) - 10
    }

    static func block(_ text: String, font: NSFont, color: NSColor, top: CGFloat, in ctx: CGContext, hebrew: Bool) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.alignment = hebrew ? .right : .left
        para.baseWritingDirection = hebrew ? .rightToLeft : .leftToRight
        para.lineSpacing = 2
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        let setter = CTFramesetterCreateWithAttributedString(s)
        let width = a4.width - 2 * margin
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
        let h = ceil(fit.height)
        let path = CGPath(rect: CGRect(x: margin, y: top - h, width: width, height: h), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), ctx)
        return top - h
    }

    static func footer(_ n: Int, _ ctx: CGContext) {
        let s = NSAttributedString(string: "\(n)", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(white: 0.55, alpha: 1)])
        let line = CTLineCreateWithAttributedString(s)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (a4.width - CGFloat(w)) / 2, y: 22)
        CTLineDraw(line, ctx)
    }

    /// Draws `img` the page's width wide from `top` down. Taller than what's left: it goes on the next page
    /// if it fits there whole, else it's cut where there's no ink (between lines of writing). Returns the y
    /// under it.
    static func place(_ img: CGImage, top: CGFloat, in ctx: CGContext, newPage: () -> CGFloat, endPage: () -> Void) -> CGFloat {
        let width = a4.width - 2 * margin
        let k = width / CGFloat(img.width)
        let fullH = CGFloat(img.height) * k
        let pageRoom = a4.height - 2 * margin
        var y = top
        if fullH > y - margin, fullH <= pageRoom, y < a4.height - margin - 60 { endPage(); y = newPage() }
        var row = 0   // image pixels done
        let ink = inkRows(img)
        while row < img.height {
            let roomPx = Int((y - margin) / k)
            if roomPx < 40 { endPage(); y = newPage(); continue }
            var end = min(img.height, row + roomPx)
            if end < img.height { end = cutRow(ink, from: row, to: end, height: img.height) }
            guard let slice = img.cropping(to: CGRect(x: 0, y: row, width: img.width, height: end - row)) else { break }
            let h = CGFloat(end - row) * k
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.draw(slice, in: CGRect(x: margin, y: y - h, width: width, height: h))
            ctx.setStrokeColor(CGColor(gray: 0.85, alpha: 1)); ctx.setLineWidth(0.5)
            ctx.stroke(CGRect(x: margin, y: y - h, width: width, height: h))
            ctx.restoreGState()
            y -= h
            row = end
            if row < img.height { endPage(); y = newPage() }
        }
        return y
    }

    /// How much ink each row of the image has (0–1), from a small gray copy.
    static func inkRows(_ img: CGImage) -> [Double] {
        let w = 160, h = img.height
        var px = [UInt8](repeating: 255, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Row 0 of the buffer is the top of the image.
        return (0..<h).map { r in
            var dark = 0
            for c in 0..<w where px[r * w + c] < 150 { dark += 1 }
            return Double(dark) / Double(w)
        }
    }

    /// The best row to cut at, at or above `to`: the cleanest band in the lower quarter of the slice.
    static func cutRow(_ ink: [Double], from: Int, to: Int, height: Int) -> Int {
        guard ink.count == height, to - from > 80 else { return to }
        let lo = max(from + 40, to - (to - from) / 4)
        var best = to, bestScore = Double.infinity
        var r = to
        while r > lo {
            // A band of 6 rows with the least ink; prefer lower rows a little.
            let band = (max(0, r - 6)..<r).reduce(0.0) { $0 + ink[$1] }
            let score = band + Double(to - r) * 0.0004
            if score < bestScore { bestScore = score; best = r }
            r -= 2
        }
        return best
    }
}
