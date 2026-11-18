import CoreGraphics
import CoreText
import Foundation
import Vision

/// A word / line of text found on the screenshot (screenshot pixels, origin top-left).
struct OCRWord { let rect: CGRect; let text: String }
struct OCRLine {
    let rect: CGRect; let text: String; let words: [OCRWord]
    /// A bullet, number or checkbox just left of the line (OCR doesn't read bullets).
    var lead: CGRect? = nil
}

/// Finds where every line and word on the screenshot is, using macOS's built-in text recognition.
/// Starts in the background right after the screenshot; it's done long before Claude replies.
final class TextIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [OCRLine] = []
    private var image: CGImage?
    private var ink: InkMap?
    private var reread: [CGRect: [OCRLine]] = [:]

    var lines: [OCRLine] { lock.withLock { _lines } }
    var words: [CGRect] { lines.flatMap { $0.words.map(\.rect) } }

    init(lines: [OCRLine] = [], image: CGImage? = nil) {
        _lines = lines; self.image = image
        ink = image.flatMap(InkMap.init)
    }

    /// Runs one small recognition in the background (the first one after a restart can take ~30 s).
    static func warmUp() {
        Task.detached(priority: .utility) {
            let w = 360, h = 60
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // Some real text, so the recognizer (not just the detector) loads.
            let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
            let str = NSAttributedString(string: "Poinky warm up", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            ctx.textPosition = CGPoint(x: 12, y: 18)
            CTLineDraw(CTLineCreateWithAttributedString(str), ctx)
            if let img = ctx.makeImage() { _ = recognize(img) }
        }
    }

    func start(_ image: CGImage) {
        lock.withLock { self.image = image }
        Task.detached(priority: .userInitiated) { [weak self] in
            let ink = InkMap(image)
            let found = Self.recognize(image, ink: ink)
            guard let self else { return }
            self.lock.withLock { self._lines = found; self.ink = ink }
        }
    }

    /// The lines Vision reads in a thin strip of the screenshot (screenshot pixels): text it missed on the
    /// whole screenshot (small print often isn't even detected there) is usually read in a strip.
    /// Used when a mark names text that wasn't found. Cached; ~40 ms each.
    func lines(inStrip r: CGRect) -> [OCRLine] {
        guard let image = lock.withLock({ image }) else { return [] }
        let strip = r.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !strip.isNull, strip.width >= 20, strip.height >= 8 else { return [] }
        if let cached = lock.withLock({ reread[strip] }) { return cached }
        let found = image.cropping(to: strip).map { Self.read($0, origin: strip.origin) } ?? []
        lock.withLock { reread[strip] = found }
        return found
    }

    /// The bottom of the letters inside `r` (screenshot pixels): OCR's boxes run well below them.
    func inkBottom(in r: CGRect) -> CGFloat? { inkMap?.bottom(in: r) }
    /// The screenshot's pixels (nil until it's been read, or without an image).
    var inkMap: InkMap? { lock.withLock { ink } }

    /// The text in an image as lines, top to bottom (used for the close-up of what you marked).
    static func readLines(_ image: CGImage, limit: Int = 1200) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequestRevision3
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return "" }
        let lines = results
            .sorted { abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX }
            .compactMap { $0.topCandidates(1).first?.string }
        return String(lines.joined(separator: "\n").prefix(limit))
    }

    static func recognize(_ image: CGImage, ink: InkMap? = nil) -> [OCRLine] {
        var lines = read(image, origin: .zero)
        let ink = ink ?? InkMap(image)
        if let ink { lines = rereadCutLines(lines, image: image, ink: ink) }
        if let ink {
            for i in lines.indices { lines[i].lead = ink.lead(leftOf: lines[i].rect) }
        }
        // Reading order: top to bottom, then left to right.
        return lines.sorted { abs($0.rect.midY - $1.rect.midY) > min($0.rect.height, $1.rect.height) * 0.5
            ? $0.rect.midY < $1.rect.midY : $0.rect.minX < $1.rect.minX }
    }

    /// The lines Vision reads in `image` (a crop placed at `origin` in the screenshot), in screenshot pixels.
    static func read(_ image: CGImage, origin: CGPoint = .zero) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // Revision 3 finds the same text in ~0.1 s; the newest revision took ~30 s on macOS 27.
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        // Vision uses 0–1 coordinates with the origin at the bottom-left.
        func px(_ b: CGRect) -> CGRect {
            CGRect(x: origin.x + b.minX * W, y: origin.y + (1 - b.maxY) * H, width: b.width * W, height: b.height * H)
        }
        var lines: [OCRLine] = []
        for obs in results {
            guard let cand = obs.topCandidates(1).first else { continue }
            let s = cand.string
            var words: [OCRWord] = []
            s.enumerateSubstrings(in: s.startIndex..<s.endIndex, options: .byWords) { sub, range, _, _ in
                guard let sub, let box = try? cand.boundingBox(for: range)?.boundingBox else { return }
                words.append(OCRWord(rect: px(box), text: sub))
            }
            lines.append(OCRLine(rect: px(obs.boundingBox), text: s, words: words))
        }
        return lines
    }

    /// Small print in a long line: on a whole screenshot Vision often reads only its first few words
    /// ("By placing this order you ac" of a 180-character line of 7 px text) and drops the rest, so marks
    /// on the rest had nothing to land on. A line whose ink runs on past its box is read again from a
    /// thin strip of the screenshot around it, where Vision reads the whole line.
    static func rereadCutLines(_ lines: [OCRLine], image: CGImage, ink: InkMap, limit: Int = 24) -> [OCRLine] {
        var out = lines
        var tries = 0
        var i = 0
        while i < out.count, tries < limit {
            let l = out[i]
            let others = out.enumerated().filter { $0.offset != i }.map(\.element.rect)
            guard l.rect.height <= 16, l.rect.height >= 4, let end = ink.runsOn(rightOf: l.rect, skipping: others) else { i += 1; continue }
            tries += 1
            let lh = l.rect.height
            // Just the row (what else is on the screen confuses it): from a little before the line to where its ink ends.
            let stripH = max(24, (lh * 3.5).rounded())
            let x0 = max(0, (l.rect.minX - lh * 2).rounded(.down))
            let y0 = max(0, (l.rect.midY - stripH / 2).rounded(.down))
            let x1 = min(CGFloat(image.width), (end + lh * 2).rounded(.up))
            let strip = CGRect(x: x0, y: y0, width: x1 - x0, height: min(stripH, CGFloat(image.height) - y0))
            guard strip.width > 40, strip.height >= 8, let crop = image.cropping(to: strip) else { i += 1; continue }
            // The longest line read on the same row that starts where this one does.
            let found = read(crop, origin: strip.origin).filter {
                abs($0.rect.midY - l.rect.midY) <= lh * 0.6 && abs($0.rect.minX - l.rect.minX) <= lh * 1.5
                    && $0.rect.width > l.rect.width + lh * 2 && $0.words.count > l.words.count
            }.max { $0.rect.width < $1.rect.width }
            guard let better = found else { i += 1; continue }
            out[i] = better
            // Pieces of the same row that were read on their own are now part of it.
            out.removeAll { o in
                o.rect != better.rect && abs(o.rect.midY - better.rect.midY) <= lh * 0.6
                    && o.rect.minX >= better.rect.minX - 2 && o.rect.maxX <= better.rect.maxX + 2
            }
            i = (out.firstIndex { $0.rect == better.rect } ?? i) + 1
        }
        return out
    }
}

/// The screenshot's pixels, to spot the small marks OCR skips (bullets, checkboxes) left of a line.
struct InkMap {
    let w: Int, h: Int
    private let data: [UInt8]

    init?(_ image: CGImage) {
        w = image.width; h = image.height
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let (cw, ch) = (w, h)
        let ok = buf.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: cw, height: ch))
            return true
        }
        guard ok else { return nil }
        data = buf
    }

    private func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * w + x) * 4
        return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }

    // MARK: Ink geometry (marks enclose the real ink, not OCR's box)

    typealias Color = (Int, Int, Int)
    /// The most common color in `r` (the background there).
    func background(_ r: CGRect) -> Color? {
        let x0 = max(0, Int(r.minX)), x1 = min(w - 1, Int(r.maxX)), y0 = max(0, Int(r.minY)), y1 = min(h - 1, Int(r.maxY))
        guard x1 >= x0, y1 >= y0 else { return nil }
        let step = max(1, min(x1 - x0, y1 - y0) / 40)
        var counts: [Int: Int] = [:]
        for y in stride(from: y0, through: y1, by: step) { for x in stride(from: x0, through: x1, by: step) {
            let (a, b, c) = rgb(x, y); counts[(a >> 4) << 8 | (b >> 4) << 4 | (c >> 4), default: 0] += 1
        } }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return (((key >> 8) & 15) * 16 + 8, ((key >> 4) & 15) * 16 + 8, (key & 15) * 16 + 8)
    }
    func isInk(_ x: Int, _ y: Int, _ bg: Color, _ thr: Int = 90) -> Bool {
        guard x >= 0, y >= 0, x < w, y < h else { return false }
        let (a, b, c) = rgb(x, y); return abs(a - bg.0) + abs(b - bg.1) + abs(c - bg.2) > thr
    }
    /// The box around the ink inside `r` (nil: none), the background judged a little around it.
    func tight(_ r: CGRect, bg: Color? = nil) -> CGRect? {
        guard let bg = bg ?? background(r.insetBy(dx: -6, dy: -6)) else { return nil }
        let x0 = max(0, Int(r.minX)), x1 = min(w - 1, Int(r.maxX.rounded(.up)) - 1), y0 = max(0, Int(r.minY)), y1 = min(h - 1, Int(r.maxY.rounded(.up)) - 1)
        guard x1 >= x0, y1 >= y0 else { return nil }
        var lx = Int.max, ly = Int.max, hx = -1, hy = -1
        for y in y0...y1 { for x in x0...x1 where isInk(x, y, bg) { lx = min(lx, x); hx = max(hx, x); ly = min(ly, y); hy = max(hy, y) } }
        guard hx >= 0 else { return nil }
        return CGRect(x: lx, y: ly, width: hx - lx + 1, height: hy - ly + 1)
    }
    /// `r` grown while ink touches its edges (OCR's boxes clip parentheses, roots, handwriting's loops),
    /// by at most `dx` / `dy` on each side so it doesn't run into the next line.
    func grow(_ r: CGRect, dx: CGFloat, dy: CGFloat, bg: Color? = nil) -> CGRect {
        guard let bg = bg ?? background(r.insetBy(dx: -6, dy: -6)) else { return r }
        var x0 = Int(r.minX), x1 = Int(r.maxX.rounded(.up)) - 1, y0 = Int(r.minY), y1 = Int(r.maxY.rounded(.up)) - 1
        func rowInk(_ y: Int) -> Bool { y >= 0 && y < h && (max(0, x0)...max(0, min(w - 1, x1))).contains { isInk($0, y, bg) } }
        func colInk(_ x: Int) -> Bool { x >= 0 && x < w && (max(0, y0)...max(0, min(h - 1, y1))).contains { isInk(x, $0, bg) } }
        let ly = Int(r.minY - dy), hy = Int(r.maxY + dy), lx = Int(r.minX - dx), hx = Int(r.maxX + dx)
        var changed = true
        while changed {
            changed = false
            if y0 - 1 >= max(0, ly), rowInk(y0 - 1) { y0 -= 1; changed = true }
            if y1 + 1 <= min(h - 1, hy), rowInk(y1 + 1) { y1 += 1; changed = true }
            if x0 - 1 >= max(0, lx), colInk(x0 - 1) { x0 -= 1; changed = true }
            if x1 + 1 <= min(w - 1, hx), colInk(x1 + 1) { x1 += 1; changed = true }
        }
        return CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }
    /// The first row below `y` (within `limit`) with ink between x0 and x1.
    func firstInkRow(below y: CGFloat, x0: CGFloat, x1: CGFloat, limit: CGFloat, bg: Color) -> CGFloat? {
        let a = max(0, Int(x0)), b = min(w - 1, Int(x1))
        guard b >= a else { return nil }
        var yy = Int(y.rounded(.up))
        while CGFloat(yy) < y + limit, yy < h {
            if (a...b).contains(where: { isInk($0, yy, bg) }) { return CGFloat(yy) }
            yy += 1
        }
        return nil
    }
    /// Whether the area has no ink at all.
    func clear(_ r: CGRect, bg: Color) -> Bool {
        let x0 = max(0, Int(r.minX)), x1 = min(w - 1, Int(r.maxX)), y0 = max(0, Int(r.minY)), y1 = min(h - 1, Int(r.maxY))
        guard x1 >= x0, y1 >= y0 else { return true }
        for y in y0...y1 { for x in x0...x1 where isInk(x, y, bg) { return false } }
        return true
    }
    /// The separate shapes of ink in `area` (pixels within 2 of each other belong together), as boxes.
    func blobs(in area: CGRect, bg: Color) -> [CGRect] {
        let x0 = max(0, Int(area.minX)), x1 = min(w - 1, Int(area.maxX)), y0 = max(0, Int(area.minY)), y1 = min(h - 1, Int(area.maxY))
        guard x1 >= x0, y1 >= y0, (x1 - x0) * (y1 - y0) < 400_000 else { return [] }
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        var seen = [Bool](repeating: false, count: bw * bh)
        var ink = [Bool](repeating: false, count: bw * bh)
        for y in 0..<bh { for x in 0..<bw { ink[y * bw + x] = isInk(x0 + x, y0 + y, bg) } }
        var out: [CGRect] = []
        for start in 0..<(bw * bh) where ink[start] && !seen[start] {
            var stack = [start]; seen[start] = true
            var lx = bw, ly = bh, hx = 0, hy = 0
            while let i = stack.popLast() {
                let x = i % bw, y = i / bw
                lx = min(lx, x); hx = max(hx, x); ly = min(ly, y); hy = max(hy, y)
                for ny in max(0, y - 2)...min(bh - 1, y + 2) { for nx in max(0, x - 2)...min(bw - 1, x + 2) {
                    let j = ny * bw + nx
                    if ink[j] && !seen[j] { seen[j] = true; stack.append(j) }
                } }
            }
            out.append(CGRect(x: x0 + lx, y: y0 + ly, width: hx - lx + 1, height: hy - ly + 1))
        }
        return out
    }

    /// The lowest row inside `r` with ink on it (letters, descenders), or nil when `r` has none.
    /// The background is the most common color in `r`.
    func bottom(in r: CGRect) -> CGFloat? {
        let x0 = max(0, Int(r.minX)), x1 = min(w - 1, Int(r.maxX)), y0 = max(0, Int(r.minY)), y1 = min(h - 1, Int(r.maxY))
        guard x1 > x0, y1 > y0 else { return nil }
        var counts: [Int: Int] = [:]
        for y in stride(from: y0, through: y1, by: 2) { for x in stride(from: x0, through: x1, by: 2) {
            let (a, b, c) = rgb(x, y); counts[(a >> 4) << 8 | (b >> 4) << 4 | (c >> 4), default: 0] += 1
        } }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let bg = (((key >> 8) & 15) * 16 + 8, ((key >> 4) & 15) * 16 + 8, (key & 15) * 16 + 8)
        // A row counts when a few pixels in it differ clearly from the background (not one stray pixel).
        let need = max(2, (x1 - x0) / 200)
        for y in stride(from: y1, through: y0, by: -1) {
            var n = 0
            for x in x0...x1 {
                let (a, b, c) = rgb(x, y)
                if abs(a - bg.0) + abs(b - bg.1) + abs(c - bg.2) > 90 { n += 1; if n >= need { return CGFloat(y + 1) } }
            }
        }
        return nil
    }

    /// Where text on `r`'s row really ends when it runs on past `r`'s right edge (within a word gap or two)
    /// outside the `skipping` boxes (other lines already read), or nil: the line was not cut short.
    func runsOn(rightOf r: CGRect, skipping: [CGRect]) -> CGFloat? {
        let lh = r.height
        let y0 = max(0, Int(r.minY + lh * 0.15)), y1 = min(h - 1, Int(r.maxY - lh * 0.15))
        let xa = min(w - 1, Int(r.maxX) + 1)
        guard w - 1 - xa >= 2, y1 > y0 else { return nil }
        // Background: the most common color just right of the line.
        var counts: [Int: Int] = [:]
        for y in y0...y1 { for x in xa...min(w - 1, xa + Int(lh * 4)) {
            let (a, b, c) = rgb(x, y); counts[(a >> 4) << 8 | (b >> 4) << 4 | (c >> 4), default: 0] += 1
        } }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let bg = (((key >> 8) & 15) * 16 + 8, ((key >> 4) & 15) * 16 + 8, (key & 15) * 16 + 8)
        let rows = skipping.filter { $0.maxY > CGFloat(y0) && $0.minY < CGFloat(y1) }
        func inked(_ x: Int) -> Bool {
            for y in y0...y1 {
                let (a, b, c) = rgb(x, y)
                // Small grey print is faint: a smaller difference than for bullets counts.
                if abs(a - bg.0) + abs(b - bg.1) + abs(c - bg.2) > 60 { return true }
            }
            return false
        }
        // Follow the ink to the right until a gap wider than a few spaces (or another line read already).
        let maxGap = Int(lh * 1.5)
        var x = xa, gap = 0, last = -1
        while x < w, gap <= maxGap {
            if rows.contains(where: { CGFloat(x) >= $0.minX - 1 && CGFloat(x) <= $0.maxX + 1 }) { break }
            if inked(x) { last = x; gap = 0 } else { gap += 1 }
            x += 1
        }
        // Only worth it when a real stretch of text was left out (more than a stray pixel or two).
        guard last >= 0, CGFloat(last - xa) >= lh * 1.5 else { return nil }
        return CGFloat(last + 1)
    }

    /// A small separate blob of ink just left of `r` (a text line), or nil.
    func lead(leftOf r: CGRect) -> CGRect? {
        let lh = r.height
        guard lh >= 6 else { return nil }
        let y0 = max(0, Int(r.minY + lh * 0.05)), y1 = min(h - 1, Int(r.maxY - lh * 0.05))
        let xEnd = Int(r.minX) - 2, xStart = max(0, Int(r.minX - lh * 2))
        guard xEnd - xStart > 6, y1 > y0 else { return nil }
        // Background: the most common color in the strip.
        var counts: [Int: Int] = [:]
        for y in stride(from: y0, through: y1, by: 2) { for x in stride(from: xStart, through: xEnd, by: 2) {
            let (a, b, c) = rgb(x, y); counts[(a >> 4) << 8 | (b >> 4) << 4 | (c >> 4), default: 0] += 1
        } }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let bg = (((key >> 8) & 15) * 16 + 8, ((key >> 4) & 15) * 16 + 8, (key & 15) * 16 + 8)
        func ink(_ x: Int, _ y: Int) -> Bool {
            let (a, b, c) = rgb(x, y); return abs(a - bg.0) + abs(b - bg.1) + abs(c - bg.2) > 90
        }
        func column(_ x: Int, _ ya: Int, _ yb: Int) -> Bool {
            guard ya <= yb else { return false }
            for y in ya...yb where ink(x, y) { return true }
            return false
        }
        // OCR's box can start a pixel or two inside the first letter: skip that part of the text.
        var x = xEnd
        while x >= xStart, column(x, y0, y1) { x -= 1 }
        guard CGFloat(xEnd - x) <= lh * 0.4 else { return nil }
        let textLeft = x + 1
        // The nearest run of inked columns, scanning left from the text.
        while x >= xStart, !column(x, y0, y1) { x -= 1 }
        guard x >= xStart else { return nil }
        let right = x
        // Small gaps stay inside one marker ("1." or "12.").
        let maxGap = max(1, Int(lh * 0.25))
        var gap = 0
        while x > xStart, gap <= maxGap { x -= 1; gap = column(x, y0, y1) ? 0 : gap + 1 }
        let left = x + gap
        // Must stand apart from the text, be small, and not run into the strip's edge.
        guard CGFloat(textLeft - right) > lh * 0.15, CGFloat(right - left) <= lh * 1.6, left > xStart + 1 else { return nil }
        // Clear space on its left too (otherwise it's the end of other text on the same row).
        let clearFrom = max(xStart, left - Int(lh * 0.6))
        if clearFrom < left - 1, (clearFrom..<(left - 1)).contains(where: { column($0, y0, y1) }) { return nil }
        var top = y1, bottom = y0
        for yy in y0...y1 { for xx in left...right where ink(xx, yy) { top = min(top, yy); bottom = max(bottom, yy); break } }
        // A vertical rule (a border) runs on above and below the line: not a bullet.
        let above = max(0, y0 - Int(lh * 0.5)), below = min(h - 1, y1 + Int(lh * 0.5))
        let ruleUp = (left...right).contains { column($0, above, max(above, y0 - 2)) }
        let ruleDown = (left...right).contains { column($0, min(below, y1 + 2), below) }
        if ruleUp && ruleDown && top <= y0 + 1 && bottom >= y1 - 1 { return nil }
        return CGRect(x: CGFloat(left), y: CGFloat(top), width: CGFloat(right - left + 1), height: CGFloat(bottom - top + 1))
    }
}

/// Puts Claude's marks exactly on the real text.
///
/// Best case, Claude names the text it means (`"find"`, plus `"to"` for a block that spans lines)
/// and the mark is placed on where that text really is. Otherwise its coordinates (often a few
/// pixels off) are nudged onto nearby words. Labels go where they cover the least text.
enum MarkSnapper {
    /// `size`: the screenshot size; `scale`: screenshot pixels per screen point (labels are sized in points).
    /// `text`: the screenshot's reading, to read a strip again for text named by `find` that the first
    /// reading missed (small print), and to put underlines just under the letters.
    static func snap(_ json: String, lines: [OCRLine], size: CGSize, scale: CGFloat, text: TextIndex? = nil) -> String {
        guard var obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return json }
        obj["items"] = items.map { snapItem($0, lines: lines, size: size, scale: scale, text: text) }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let out = String(data: data, encoding: .utf8) else { return json }
        return out
    }

    static func snapItem(_ item: [String: Any], lines: [OCRLine], size: CGSize, scale: CGFloat,
                         text: TextIndex? = nil) -> [String: Any] {
        var it = item
        var lines = lines
        let type = it["type"] as? String ?? ""
        var target: CGRect?
        if let q = it["find"] as? String {
            target = locate(q, to: it["to"] as? String, hint: hint(it), in: lines)
            // Not found: read thin strips around where the mark was meant to go again.
            if target == nil, let text {
                for strip in strips(around: it, size: size) {
                    let more = merged(lines, with: text.lines(inStrip: strip))
                    if let t = locate(q, to: it["to"] as? String, hint: hint(it), in: more) { target = t; lines = more; break }
                }
            }
        }
        // No text named (or not found): what the mark's own coordinates are around.
        let found = target != nil
        if target == nil { target = nudgeTarget(it, lines: lines, ink: text?.inkMap) }
        if var target {
            if ["box", "highlight", "bracket"].contains(type) { target = withLeads(target, lines) }
            if let ink = text?.inkMap {
                fit(&it, on: target, lines: lines, ink: ink, size: size, scale: scale)
            } else {
                place(&it, on: target)
            }
        } else if !found {
            if type == "underline", let text { it = clearOfLetters(it, text: text) }
        }
        let text_ = text
        if let text = (it["label"] as? String), !text.isEmpty, let mark = bounds(it, scale: scale) {
            placeLabel(&it, text: text, mark: mark, lines: lines, size: size, scale: scale, ink: text_?.inkMap)
        }
        return it
    }

    /// An underline that found no text to sit under (the model's own y) must not run through letters:
    /// when its y is inside a row of ink, it moves just below that row.
    static func clearOfLetters(_ item: [String: Any], text: TextIndex) -> [String: Any] {
        var it = item
        guard let x = num(it["x"]), let y = num(it["y"]), let w = num(it["w"]), w > 4 else { return it }
        // Ink right at the line's height (±2 px)?
        guard text.inkBottom(in: CGRect(x: x, y: y - 2, width: w, height: 4)) != nil else { return it }
        // Follow the ink down (at most ~30 px) to the bottom of that row.
        var bottom = y
        while bottom < y + 30, text.inkBottom(in: CGRect(x: x, y: bottom, width: w, height: 2)) != nil { bottom += 1 }
        guard bottom < y + 30 else { return it }
        it["y"] = bottom + 3
        return it
    }

    /// Strips of the screenshot to read again for a mark whose text wasn't found: around its row (the
    /// model's y is often off by a line or two), as wide as the mark plus some, never the whole screen
    /// (other windows' text in the strip makes Vision skip the small print again).
    static func strips(around it: [String: Any], size: CGSize) -> [CGRect] {
        guard let h = hint(it) else { return [] }
        var x0 = h.x - 450, x1 = h.x + 450
        if let x = num(it["x"]), let w = num(it["w"]), w > 0 { x0 = min(x0, x - 150); x1 = max(x1, x + w + 150) }
        x0 = max(0, x0); x1 = min(size.width, x1)
        guard x1 - x0 >= 40 else { return [] }
        return [40, 72, 120].map { hgt in
            let y0 = max(0, min(size.height - hgt, h.y - hgt / 2))
            return CGRect(x: x0, y: y0, width: x1 - x0, height: min(hgt, size.height))
        }
    }

    /// `lines` with the ones read again in a strip: a line read again replaces what was read of the
    /// same row before (often its first few words).
    static func merged(_ lines: [OCRLine], with more: [OCRLine]) -> [OCRLine] {
        guard !more.isEmpty else { return lines }
        let kept = lines.filter { l in
            !more.contains { m in
                abs(m.rect.midY - l.rect.midY) <= min(m.rect.height, l.rect.height) * 0.6
                    && l.rect.minX >= m.rect.minX - 4 && l.rect.maxX <= m.rect.maxX + 4
            }
        }
        return (kept + more).sorted { abs($0.rect.midY - $1.rect.midY) > min($0.rect.height, $1.rect.height) * 0.5
            ? $0.rect.midY < $1.rect.midY : $0.rect.minX < $1.rect.minX }
    }

    // MARK: Finding text by its words

    private static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private struct Token { let text: String; let rect: CGRect; let line: Int }
    private struct Hit { let rect: CGRect; let line: Int; let endLine: Int; let score: Double; let lineSet: Set<Int> }

    /// Where `query` appears (allowing a misread letter here and there), best matches first.
    private static func hits(_ query: String, in lines: [OCRLine], fromLine: Int = 0) -> [Hit] {
        let q = tokens(query)
        guard !q.isEmpty else { return [] }
        var flat: [Token] = []
        for (i, line) in lines.enumerated() {
            for w in line.words { for t in tokens(w.text) { flat.append(Token(text: t, rect: w.rect, line: i)) } }
        }
        let need: Double = q.count <= 2 ? 1 : (q.count == 3 ? 0.66 : 0.75)
        var out: [Hit] = []
        for i in flat.indices where flat[i].line >= fromLine {
            // Walk the query along the words from here. OCR runs words together ("or x" → "orx") and splits
            // them ("30-day" → "30" "day" is already split the same way on both sides): one word read as two
            // of the query's (or two read as one of its) counts for both.
            var j = 0, p = i, matched: [Token] = [], hitCount = 0
            while j < q.count, p < flat.count, flat[p].line - flat[i].line <= 4 {
                let t = flat[p].text
                if similar(t, q[j]) { matched.append(flat[p]); hitCount += 1; j += 1; p += 1 }
                else if j + 1 < q.count, similar(t, q[j] + q[j + 1]) { matched.append(flat[p]); hitCount += 2; j += 2; p += 1 }
                else if p + 1 < flat.count, flat[p + 1].line == flat[p].line, t + flat[p + 1].text == q[j] {
                    matched.append(flat[p]); matched.append(flat[p + 1]); hitCount += 1; j += 1; p += 2
                } else { j += 1; p += 1 }
            }
            guard j == q.count else { continue }   // ran out of words or lines
            let score = Double(hitCount) / Double(q.count)
            // Only the words that really match count (a misread "3." must not drag in its neighbor).
            guard score >= need, let first = matched.first, similar(flat[i].text, q[0]) || flat[i].text.hasPrefix(q[0]) || q.count >= 4 else { continue }
            let r = matched.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            out.append(Hit(rect: r, line: first.line, endLine: matched.last!.line, score: score, lineSet: Set(matched.map(\.line))))
        }
        return out
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let n = max(a.count, b.count)
        guard n >= 4 else { return false }
        return editDistance(Array(a), Array(b)) <= (n >= 8 ? 2 : 1)
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(1, b.count) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    /// The area of `find` (or, with `to`, of the whole block from `find` to `to`).
    static func locate(_ find: String, to: String?, hint: CGPoint?, in lines: [OCRLine]) -> CGRect? {
        let starts = hits(find, in: lines)
        guard !starts.isEmpty else { return nil }
        func dist(_ r: CGRect) -> CGFloat { hint.map { hypot(r.midX - $0.x, r.midY - $0.y) } ?? 0 }
        let best = starts.max { a, b in a.score != b.score ? a.score < b.score : dist(a.rect) > dist(b.rect) }!
        guard let to, !to.isEmpty else { return best.rect }
        // The block ends at the first match of `to` below the start (within ~14 lines' height; counting
        // OCR lines would also count the other columns' lines on the same rows).
        let reach = best.rect.maxY + max(best.rect.height, 12) * 14
        let ends = hits(to, in: lines, fromLine: best.line)
            .filter { $0.endLine >= best.endLine && $0.rect.minY <= reach && !($0.line == best.line && $0.rect.minX < best.rect.minX) }
        guard let end = ends.min(by: { ($0.line, $0.rect.minX) < ($1.line, $1.rect.minX) }) else { return best.rect }
        // Whole lines from start to end, in the same column.
        // The column: every line the start and end words are on.
        let touched = best.lineSet.union(end.lineSet).map { lines[$0].rect }
        let lo = (touched.map(\.minX).min() ?? best.rect.minX) - 40, hi = (touched.map(\.maxX).max() ?? best.rect.maxX) + 40
        var r = best.rect.union(end.rect)
        let left = touched.map(\.minX).min() ?? best.rect.minX
        for i in best.line...end.endLine {
            // Only lines of that column (not a sidebar that happens to sit next to it): lines that start
            // at its left edge (a long list item can run past it) or sit mostly inside it.
            let l = lines[i].rect
            let overlap = min(l.maxX, hi) - max(l.minX, lo)
            let sameStart = abs(l.minX - left) <= max(l.height, 12) * 1.5
            if sameStart || overlap >= 0.7 * l.width, l.minY >= best.rect.minY - 4, l.maxY <= end.rect.maxY + 4 { r = r.union(l) }
        }
        return r
    }

    private static func num(_ v: Any?) -> CGFloat? {
        (v as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    private static func hint(_ it: [String: Any]) -> CGPoint? {
        let n = { (k: String) in num(it[k]) }
        switch it["type"] as? String {
        case "circle": if let x = n("x"), let y = n("y") { return CGPoint(x: x, y: y) }
        case "box", "highlight": if let x = n("x"), let y = n("y") { return CGPoint(x: x + (n("w") ?? 0) / 2, y: y + (n("h") ?? 0) / 2) }
        case "underline": if let x = n("x"), let y = n("y") { return CGPoint(x: x + (n("w") ?? 0) / 2, y: y - 10) }
        case "arrow": if let x = n("x2"), let y = n("y2") { return CGPoint(x: x, y: y) }
        case "bracket": if let x = n("x"), let y = n("y") { return CGPoint(x: x + 100, y: y + (n("h") ?? 0) / 2) }
        default: break
        }
        return nil
    }

    /// Without `find`: what the mark's coordinates are around, if it's clear (nil: leave the mark as it is).
    static func nudgeTarget(_ it: [String: Any], lines: [OCRLine], ink: InkMap?) -> CGRect? {
        let words = lines.flatMap { $0.words.map(\.rect) }
        switch it["type"] as? String {
        case "underline":
            guard let x = num(it["x"]), let y = num(it["y"]), let w = num(it["w"]), w > 0 else { return nil }
            // Words under the line's span whose bottom edge is close to where Claude put the line.
            let cands = words.filter { r in
                let overlap = min(r.maxX, x + w) - max(r.minX, x)
                return overlap >= 0.5 * min(r.width, w) && abs(r.maxY - y) < max(28, r.height * 1.5)
            }
            guard let best = cands.min(by: { abs($0.maxY - y) < abs($1.maxY - y) }) else { return nil }
            return union(cands.filter { abs($0.midY - best.midY) < best.height * 0.6 })
        case "highlight", "box":
            guard let x = num(it["x"]), let y = num(it["y"]), let w = num(it["w"]), let h = num(it["h"]) else { return nil }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            // Words mostly inside the box (a line the box only grazes stays out).
            func isInside(_ r: CGRect) -> Bool { let i = r.intersection(rect); return !i.isNull && i.width * i.height >= 0.6 * r.width * r.height }
            var found: CGRect?
            for l in lines {
                let inside = l.words.map(\.rect).filter(isInside)
                guard !inside.isEmpty else { continue }
                // Most of the line is in the box: take the whole line (Claude's boxes often stop short).
                let part = Double(inside.count) >= 0.6 * Double(l.words.count) ? union(l.words.map(\.rect)) : union(inside)
                found = found.map { $0.union(part) } ?? part
            }
            // Only when the words fill a good part of the area (otherwise it's probably a picture or button).
            guard let textArea = found, textArea.width * textArea.height >= 0.25 * w * h else { return nil }
            return textArea
        case "bracket":
            guard let x = num(it["x"]), let y = num(it["y"]), let h = num(it["h"]), h > 0 else { return nil }
            let block = words.filter { $0.midY >= y && $0.midY <= y + h && $0.minX >= x - 40 && $0.minX < x + 400 }
            return block.isEmpty ? nil : union(block)
        case "circle":
            guard let x = num(it["x"]), let y = num(it["y"]), let r = num(it["r"]), r > 0 else { return nil }
            let rx = r * 1.15, ry = r
            func inEllipse(_ p: CGPoint, _ f: CGFloat = 1.1) -> Bool { let dx = (p.x - x) / (rx * f), dy = (p.y - y) / (ry * f); return dx * dx + dy * dy <= 1 }
            // Text: the lines most of whose words are inside (a circle the model drew too small still means
            // those whole lines); a line it only clips stays out.
            var text: CGRect?
            for l in lines where !l.words.isEmpty {
                let inside = l.words.filter { inEllipse(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
                if !inside.isEmpty, Double(inside.count) >= 0.5 * Double(l.words.count) { text = text.map { $0.union(l.rect) } ?? l.rect }
            }
            if let t = text, t.width < rx * 4, t.height < ry * 4 { return t }
            // No text: a picture, icon or checkbox. The shapes of ink centered inside the circle (not letters).
            guard let ink = ink, let bg = ink.background(CGRect(x: x - rx * 1.5, y: y - ry * 1.5, width: rx * 3, height: ry * 3)) else { return nil }
            let shapes = ink.blobs(in: CGRect(x: x - rx * 1.4, y: y - ry * 1.4, width: rx * 2.8, height: ry * 2.8), bg: bg).filter { b in
                inEllipse(CGPoint(x: b.midX, y: b.midY), 0.85) && !words.contains { $0.insetBy(dx: -1, dy: -1).contains(CGPoint(x: b.midX, y: b.midY)) }
            }
            guard !shapes.isEmpty else { return nil }
            let u = union(shapes)
            return u.width < rx * 3 && u.height < ry * 3 ? u : nil
        case "arrow":
            guard let x = num(it["x2"]), let y = num(it["y2"]) else { return nil }
            let tip = CGPoint(x: x, y: y)
            // The word or shape the tip is on (or right next to).
            if let w = words.first(where: { $0.insetBy(dx: -4, dy: -4).contains(tip) }) { return w }
            guard let ink = ink, let bg = ink.background(CGRect(x: x - 40, y: y - 40, width: 80, height: 80)) else { return nil }
            let shapes = ink.blobs(in: CGRect(x: x - 30, y: y - 30, width: 60, height: 60), bg: bg)
            return shapes.first { $0.insetBy(dx: -4, dy: -4).contains(tip) && $0.width < 80 && $0.height < 80 }
        default:
            return nil
        }
    }

    /// Fits a mark onto `r` using the screenshot's ink: around all of it (OCR's boxes clip handwriting,
    /// roots and parentheses), never through it, on the screen. Sizes in screenshot pixels; `scale` is
    /// pixels per point (the overlay draws with point-sized pens and padding).
    static func fit(_ it: inout [String: Any], on r: CGRect, lines: [OCRLine], ink: InkMap, size: CGSize, scale k: CGFloat) {
        guard let bg = ink.background(r.insetBy(dx: -8, dy: -8)) else { place(&it, on: r); return }
        // The real ink of the target: shrink to it, then let it grow over what OCR's box clipped.
        let line = min(r.height, (lines.filter { $0.rect.intersects(r) }.map(\.rect.height).min() ?? r.height))
        var t = ink.tight(r, bg: bg) ?? r
        t = ink.grow(t, dx: max(2, line * 0.5), dy: max(2, line * 0.35), bg: bg)
        let screen = CGRect(origin: .zero, size: size)
        let pen = 2.25 * k   // half the overlay's 4.5 pt pen
        // Can't be drawn around it on the screen (it's at the very edge): a highlight over it instead.
        func highlight() {
            let h = t.insetBy(dx: -1, dy: -1)
            let inset = 4 * k   // the highlight's own 3 pt padding and its edge
            let c = h.intersection(screen.insetBy(dx: inset, dy: inset))
            let b = c.isNull ? h : c
            it["type"] = "highlight"
            it["x"] = b.minX; it["y"] = b.minY; it["w"] = b.width; it["h"] = b.height
            it["r"] = nil; it["rx"] = nil; it["ry"] = nil
        }
        /// A number, bullet or checkbox just before the target's first line that OCR skipped (small, on that
        /// line: not a margin rule running down the block).
        func leadLeft(of t: CGRect, from left: CGFloat) -> CGRect? {
            let area = CGRect(x: left - line * 1.5, y: t.minY - 3, width: line * 1.5 - 1, height: min(t.height, line * 1.2) + 6)
            guard let lead = ink.tight(area, bg: bg), left - lead.maxX < line * 0.8,
                  lead.minY > area.minY + 0.5, lead.maxY < area.maxY - 0.5 else { return nil }
            return lead
        }
        switch it["type"] as? String {
        case "box":
            // A checkbox or bullet right before it belongs to it (the box would run through it otherwise).
            if let lead = leadLeft(of: t, from: t.minX) { t = t.union(lead) }
            // The overlay draws 4 pt outside the box, with a 2.5 pt wobble: keep the pen's inside edge off the ink.
            let b = t.insetBy(dx: -(0.75 * k + 2.5), dy: -(0.75 * k + 2.5))
            let outer = b.insetBy(dx: -(4 + 2.5) * k - pen, dy: -(4 + 2.5) * k - pen)
            if !screen.contains(outer) { highlight(); return }
            it["x"] = b.minX; it["y"] = b.minY; it["w"] = b.width; it["h"] = b.height
        case "highlight":
            let b = t.insetBy(dx: -1, dy: -1)
            it["x"] = b.minX; it["y"] = b.minY; it["w"] = b.width; it["h"] = b.height
            if !screen.insetBy(dx: 4 * k, dy: 4 * k).contains(b) { highlight() }
        case "circle":
            // An ellipse around the whole target with room for the pen (its loop ends ~6% inside): wide
            // enough that it isn't much taller than the target.
            let pad = pen + 3
            let a = t.width / 2 + pad, b = t.height / 2 + pad
            // Other text the loop would run through (lines that aren't the target): a flatter, wider loop
            // passes between the lines above and below.
            let near = t.insetBy(dx: -a * 1.6, dy: -60)
            let others = lines.map(\.rect).filter { !$0.intersects(t.insetBy(dx: 2, dy: 2)) && $0.intersects(near) }.map { ink.tight($0, bg: bg) ?? $0 }
            func size(_ m: CGFloat) -> (CGFloat, CGFloat) {
                let rx = max(a * m, a + 4) / 0.94
                return (rx, b / (1 - pow(a / (rx * 0.94), 2)).squareRoot() / 0.94)
            }
            func hits(_ rx: CGFloat, _ ry: CGFloat) -> Int {
                (0..<72).filter { i in
                    let an = Double(i) / 72 * 2 * .pi, p = CGPoint(x: t.midX + rx * CGFloat(cos(an)), y: t.midY + ry * CGFloat(sin(an)))
                    return others.contains { $0.insetBy(dx: -pen, dy: -pen).contains(p) }
                }.count
            }
            // The most compact loop that's on screen, unless a somewhat wider one clears the other text.
            var best: (CGFloat, CGFloat)?
            for m: CGFloat in [1.4, 1.22, 1.7, 2.1] {
                let (rx, ry) = size(m)
                let ell = CGRect(x: t.midX - rx - pen, y: t.midY - ry - pen, width: 2 * (rx + pen), height: 2 * (ry + pen))
                guard screen.contains(ell) else { continue }
                if best == nil { best = (rx, ry) }
                if hits(rx, ry) == 0 { best = (rx, ry); break }
            }
            guard let (rx, ry) = best else { highlight(); return }
            it["x"] = t.midX; it["y"] = t.midY; it["r"] = ry; it["rx"] = rx; it["ry"] = ry
        case "underline":
            // In the gap under the letters, above whatever comes next; no gap: a highlight.
            let bottom = t.maxY
            let next = ink.firstInkRow(below: bottom + 1, x0: t.minX, x1: t.maxX, limit: 40, bg: bg) ?? (bottom + 40)
            var y = bottom + pen + max(1, min(3, t.height * 0.12))
            if y + pen > next - 1 { y = (bottom + next) / 2 }
            if y - pen < bottom - 0.5 || y + pen > next + 0.5 || y + pen > size.height { highlight(); return }
            it["x"] = t.minX; it["w"] = t.width; it["y"] = y
        case "bracket":
            // Left of where the block's lines start (a "2." or a bullet is part of the block), in clear space.
            let rows = lines.filter { $0.rect.midY >= t.minY && $0.rect.midY <= t.maxY && $0.rect.minX <= t.minX + 2 && $0.rect.maxX >= t.minX }
            var left = min(t.minX, rows.map(\.rect.minX).min() ?? t.minX)
            // A number or bullet just before it that OCR skipped (small, on the first line: not a border running down the block).
            if let lead = leadLeft(of: t, from: left) { left = lead.minX }
            // The bracket's stroke runs 12 pt left of x and its curls come back to 6 pt: as close as that allows,
            // then step left past any ink there (a page's margin rule, other text).
            var x = left + 6 * k - pen - 1.5
            func free(_ x: CGFloat) -> Bool { ink.clear(CGRect(x: x - 12 * k - pen - 0.5, y: t.minY - 2, width: 6 * k + pen + 1, height: t.height + 4), bg: bg) }
            var tries = 0
            while !free(x), tries < Int(24 * k) { x -= 1; tries += 1 }
            if !free(x) { x = left + 6 * k - pen - 1.5 }   // no clear spot near: hug the block
            if x - 12 * k - pen < 0 { highlight(); return }
            it["x"] = x; it["y"] = t.minY - 2; it["h"] = t.height + 4
        case "arrow":
            fitArrow(&it, on: t, lines: lines, size: size, scale: k)
        default:
            place(&it, on: t)
        }
    }

    /// An arrow ends just outside its target, pointing at it from where its tail is; a tail inside the target
    /// or off the screen moves to the side with room (toward the middle of the screen when it's at an edge).
    static func fitArrow(_ it: inout [String: Any], on t: CGRect, lines: [OCRLine], size: CGSize, scale k: CGFloat) {
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: 14 * k, dy: 14 * k)
        let keepOut = t.insetBy(dx: -6, dy: -6)
        var tail = CGPoint(x: num(it["x1"]) ?? t.minX - 80 * k, y: num(it["y1"]) ?? t.midY)
        func tip(from p: CGPoint) -> CGPoint {
            let px = min(max(p.x, t.minX), t.maxX), py = min(max(p.y, t.minY), t.maxY)
            let d = max(1, hypot(px - p.x, py - p.y))
            return CGPoint(x: px - (px - p.x) / d * 6, y: py - (py - p.y) / d * 6)
        }
        if keepOut.contains(tail) || !screen.contains(tail) {
            let len = max(70 * k, min(160 * k, hypot((num(it["x2"]) ?? tail.x) - tail.x, (num(it["y2"]) ?? tail.y) - tail.y)))
            let words = lines.flatMap { $0.words.map(\.rect) }
            let toMiddle = CGPoint(x: size.width / 2 - t.midX, y: size.height / 2 - t.midY)
            var best: (CGPoint, CGFloat)?
            for i in 0..<16 {
                let a = Double(i) / 16 * 2 * .pi, dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
                // From the target's edge in that direction, `len` away.
                let ex = dx > 0 ? t.maxX : (dx < 0 ? t.minX : t.midX), ey = dy > 0 ? t.maxY : (dy < 0 ? t.minY : t.midY)
                let p = CGPoint(x: ex + dx * len, y: ey + dy * len)
                guard screen.contains(p), !keepOut.contains(p) else { continue }
                // Less text under the arrow is better; toward the middle of the screen, and close to where the model meant.
                let q = tip(from: p)
                var cost: CGFloat = 0
                for w in words where segmentHits(p, q, w) { cost += 1 }
                cost -= (dx * toMiddle.x + dy * toMiddle.y) / max(1, hypot(toMiddle.x, toMiddle.y)) * 0.5
                cost += hypot(p.x - tail.x, p.y - tail.y) / max(1, size.width) * 0.5
                if best == nil || cost < best!.1 { best = (p, cost) }
            }
            if let b = best { tail = b.0 }
        }
        let q = tip(from: tail)
        it["x1"] = tail.x; it["y1"] = tail.y; it["x2"] = q.x; it["y2"] = q.y
    }

    private static func segmentHits(_ a: CGPoint, _ b: CGPoint, _ r: CGRect) -> Bool {
        for i in 0...12 {
            let u = CGFloat(i) / 12
            if r.contains(CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)) { return true }
        }
        return false
    }

    /// Fits a mark onto `r`, the text it's about.
    private static func place(_ it: inout [String: Any], on r: CGRect) {
        switch it["type"] as? String {
        case "box":
            let b = r.insetBy(dx: -6, dy: -5)
            it["x"] = b.minX; it["y"] = b.minY; it["w"] = b.width; it["h"] = b.height
        case "highlight":
            let b = r.insetBy(dx: -2, dy: -2)
            it["x"] = b.minX; it["y"] = b.minY; it["w"] = b.width; it["h"] = b.height
        case "underline":
            it["x"] = r.minX; it["w"] = r.width; it["y"] = r.maxY + 3
        case "circle":
            it["x"] = r.midX; it["y"] = r.midY
            it["r"] = max(r.height / 2 + 10, r.width / 2.3 + 6)
        case "bracket":
            it["x"] = r.minX; it["y"] = r.minY - 2; it["h"] = r.height + 4
        case "arrow":
            // Point at the edge of the text that faces the arrow's tail, just short of it.
            guard let x1 = num(it["x1"]), let y1 = num(it["y1"]) else {
                it["x2"] = r.minX - 8; it["y2"] = r.midY; return
            }
            let px = min(max(x1, r.minX), r.maxX), py = min(max(y1, r.minY), r.maxY)
            let d = max(1, hypot(px - x1, py - y1))
            it["x2"] = px - (px - x1) / d * 8; it["y2"] = py - (py - y1) / d * 8
        default:
            break
        }
    }

    private static func union(_ rs: [CGRect]) -> CGRect {
        rs.dropFirst().reduce(rs[0]) { $0.union($1) }
    }

    /// Adds the bullets / numbers / checkboxes of the lines that start at the block's left edge.
    static func withLeads(_ r: CGRect, _ lines: [OCRLine]) -> CGRect {
        var out = r
        for l in lines {
            guard let lead = l.lead, abs(l.rect.minX - r.minX) <= max(4, l.rect.height * 0.5),
                  l.rect.midY >= r.minY, l.rect.midY <= r.maxY else { continue }
            out = out.union(lead)
        }
        return out
    }

    // MARK: Labels

    /// The area a mark covers, in screenshot pixels.
    private static func bounds(_ it: [String: Any], scale: CGFloat) -> CGRect? {
        let n = { (k: String) in num(it[k]) }
        switch it["type"] as? String {
        case "circle":
            guard let x = n("x"), let y = n("y"), let r = n("r") else { return nil }
            let rx = n("rx") ?? r * 1.15, ry = n("ry") ?? r
            return CGRect(x: x - rx * 1.04, y: y - ry * 1.05, width: rx * 2.08, height: ry * 2.1)
        case "box", "highlight":
            guard let x = n("x"), let y = n("y"), let w = n("w"), let h = n("h") else { return nil }
            return CGRect(x: x - 5, y: y - 5, width: w + 10, height: h + 10)
        case "underline":
            guard let x = n("x"), let y = n("y"), let w = n("w") else { return nil }
            return CGRect(x: x, y: y - 24 * scale, width: w, height: 24 * scale + 6)
        case "arrow":
            guard let x = n("x1"), let y = n("y1") else { return nil }
            return CGRect(x: x - 4, y: y - 4, width: 8, height: 8)
        case "bracket":
            guard let x = n("x"), let y = n("y"), let h = n("h") else { return nil }
            return CGRect(x: x - 24 * scale, y: y, width: 14 * scale, height: h)
        default:
            return nil
        }
    }

    /// Picks the spot next to the mark where the label covers the least text and stays on screen.
    /// Sets `lx`, `ly` (top-left of the label, screenshot pixels) and `la` ("start" or "end").
    private static func placeLabel(_ it: inout [String: Any], text: String, mark m: CGRect, lines: [OCRLine],
                                   size: CGSize, scale: CGFloat, ink: InkMap? = nil) {
        let k = max(scale, 0.1)
        let w = (CGFloat(text.count) * 10.5 + 22) * k, h = 32 * k, g = 8 * k
        let type = it["type"] as? String ?? ""
        // Candidates in order of preference for this kind of mark.
        var cands: [(CGRect, String)] = [
            (CGRect(x: m.maxX + g, y: m.midY - h / 2, width: w, height: h), "start"),          // right
            (CGRect(x: m.minX, y: m.minY - g - h, width: w, height: h), "start"),              // above
            (CGRect(x: m.minX, y: m.maxY + g, width: w, height: h), "start"),                  // below
            (CGRect(x: m.minX - g - w, y: m.midY - h / 2, width: w, height: h), "end"),        // left
            (CGRect(x: m.maxX - w, y: m.minY - g - h, width: w, height: h), "start"),          // above, right-aligned
            (CGRect(x: m.maxX - w, y: m.maxY + g, width: w, height: h), "start"),              // below, right-aligned
        ]
        if type == "box" || type == "highlight" { cands.swapAt(0, 1) }
        if type == "underline" { cands.swapAt(0, 2) }
        let words = lines.flatMap { $0.words.map { $0.rect.insetBy(dx: -2, dy: -2) } }
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: 6 * k, dy: 6 * k)
        // The page's color around the mark (judged over a wide area: a spot on a chart's bar is not "empty").
        let pageBG = ink?.background(m.insetBy(dx: -220 * k, dy: -160 * k))
        var best: (CGRect, String, CGFloat)?
        for (i, (r, anchor)) in cands.enumerated() {
            var cost = CGFloat(i) * 0.04
            if !screen.contains(r) { cost += 50 }
            let covered = words.reduce(CGFloat(0)) { acc, wr in
                let x = wr.intersection(r); return acc + (x.isNull ? 0 : x.width * x.height)
            }
            cost += covered / (w * h) * 10
            // Pictures count too (a chart's bars, an icon): what share of the spot isn't background.
            if let ink, let bg = pageBG {
                var hit = 0, all = 0
                for yy in stride(from: Int(r.minY), to: Int(r.maxY), by: 3) { for xx in stride(from: Int(r.minX), to: Int(r.maxX), by: 3) {
                    all += 1; if ink.isInk(xx, yy, bg, 60) { hit += 1 }
                } }
                if all > 0 { cost += CGFloat(hit) / CGFloat(all) * 6 }
            }
            let onMark = r.intersection(m)
            if !onMark.isNull { cost += onMark.width * onMark.height / (w * h) * 6 }
            if best == nil || cost < best!.2 { best = (r, anchor, cost) }
        }
        guard let (r, anchor, _) = best else { return }
        it["lx"] = anchor == "end" ? r.maxX : r.minX
        it["ly"] = r.minY
        it["la"] = anchor
    }
}
