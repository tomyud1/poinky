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

    var lines: [OCRLine] { lock.withLock { _lines } }
    var words: [CGRect] { lines.flatMap { $0.words.map(\.rect) } }

    init(lines: [OCRLine] = []) { _lines = lines }

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
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = Self.recognize(image)
            guard let self else { return }
            self.lock.withLock { self._lines = found }
        }
    }

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

    static func recognize(_ image: CGImage) -> [OCRLine] {
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
        func px(_ b: CGRect) -> CGRect { CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H) }
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
        if let ink = InkMap(image) {
            for i in lines.indices { lines[i].lead = ink.lead(leftOf: lines[i].rect) }
        }
        // Reading order: top to bottom, then left to right.
        return lines.sorted { abs($0.rect.midY - $1.rect.midY) > min($0.rect.height, $1.rect.height) * 0.5
            ? $0.rect.midY < $1.rect.midY : $0.rect.minX < $1.rect.minX }
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
    static func snap(_ json: String, lines: [OCRLine], size: CGSize, scale: CGFloat) -> String {
        guard var obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return json }
        obj["items"] = items.map { snapItem($0, lines: lines, size: size, scale: scale) }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let out = String(data: data, encoding: .utf8) else { return json }
        return out
    }

    static func snapItem(_ item: [String: Any], lines: [OCRLine], size: CGSize, scale: CGFloat) -> [String: Any] {
        var it = item
        let type = it["type"] as? String ?? ""
        if let q = it["find"] as? String, var target = locate(q, to: it["to"] as? String, hint: hint(it), in: lines) {
            if ["box", "highlight", "bracket"].contains(type) { target = withLeads(target, lines) }
            place(&it, on: target)
        } else {
            it = nudge(it, lines: lines)
        }
        if let text = (it["label"] as? String), !text.isEmpty, let mark = bounds(it, scale: scale) {
            placeLabel(&it, text: text, mark: mark, lines: lines, size: size, scale: scale)
        }
        return it
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
        var i = 0
        while i + q.count <= flat.count {
            if flat[i].line >= fromLine {
                let span = flat[i..<(i + q.count)]
                if span.last!.line - span.first!.line <= 4 {
                    // Only the words that really match count (a misread "3." must not drag in its neighbor).
                    let matched = span.enumerated().filter { similar($0.element.text, q[$0.offset]) }.map(\.element)
                    let score = Double(matched.count) / Double(q.count)
                    if score >= need, let first = matched.first, similar(span.first!.text, q[0]) || q.count >= 4 {
                        let r = matched.dropFirst().reduce(first.rect) { $0.union($1.rect) }
                        out.append(Hit(rect: r, line: first.line, endLine: matched.last!.line, score: score,
                                       lineSet: Set(matched.map(\.line))))
                    }
                }
            }
            i += 1
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

    /// Without `find`: nudge the mark onto the words near Claude's coordinates.
    static func nudge(_ item: [String: Any], lines: [OCRLine]) -> [String: Any] {
        var it = item
        let words = lines.flatMap { $0.words.map(\.rect) }
        guard !words.isEmpty else { return it }
        switch it["type"] as? String {
        case "underline":
            guard let x = num(it["x"]), let y = num(it["y"]), let w = num(it["w"]), w > 0 else { return it }
            // Words under the line's span whose bottom edge is close to where Claude put the line.
            let cands = words.filter { r in
                let overlap = min(r.maxX, x + w) - max(r.minX, x)
                return overlap >= 0.5 * min(r.width, w) && abs(r.maxY - y) < max(28, r.height * 1.5)
            }
            guard let best = cands.min(by: { abs($0.maxY - y) < abs($1.maxY - y) }) else { return it }
            let row = cands.filter { abs($0.midY - best.midY) < best.height * 0.6 }
            let u = union(row)
            it["x"] = u.minX; it["w"] = u.width; it["y"] = u.maxY + 3

        case "highlight", "box":
            guard let x = num(it["x"]), let y = num(it["y"]), let w = num(it["w"]), let h = num(it["h"]) else { return it }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            // Words mostly inside the box (a line the box only grazes stays out).
            func isInside(_ r: CGRect) -> Bool {
                let i = r.intersection(rect)
                return !i.isNull && i.width * i.height >= 0.6 * r.width * r.height
            }
            var found: CGRect?
            for l in lines {
                let inside = l.words.map(\.rect).filter(isInside)
                guard !inside.isEmpty else { continue }
                // Most of the line is in the box: take the whole line (Claude's boxes often stop short).
                let part = Double(inside.count) >= 0.6 * Double(l.words.count) ? union(l.words.map(\.rect)) : union(inside)
                found = found.map { $0.union(part) } ?? part
            }
            guard let textArea = found else { return it }
            // Only snap when the words fill a good part of the area (otherwise it's probably a picture or button).
            guard textArea.width * textArea.height >= 0.25 * w * h else { return it }
            let u = withLeads(textArea, lines)
            let pad: CGFloat = it["type"] as? String == "box" ? 6 : 2
            let r = u.insetBy(dx: -pad, dy: -pad)
            it["x"] = r.minX; it["y"] = r.minY; it["w"] = r.width; it["h"] = r.height

        case "bracket":
            guard let x = num(it["x"]), let y = num(it["y"]), let h = num(it["h"]), h > 0 else { return it }
            // The block of words to its right, from its top to its bottom.
            let block = words.filter { $0.midY >= y && $0.midY <= y + h && $0.minX >= x - 40 && $0.minX < x + 400 }
            guard !block.isEmpty else { return it }
            let u = withLeads(union(block), lines)
            it["x"] = u.minX; it["y"] = u.minY - 2; it["h"] = u.height + 4

        case "circle":
            guard let x = num(it["x"]), let y = num(it["y"]), let r = num(it["r"]), r > 0 else { return it }
            // Only when the circle is clearly centered on some text (it could be around an icon).
            guard let nearest = words.min(by: { hypot($0.midX - x, $0.midY - y) < hypot($1.midX - x, $1.midY - y) }),
                  hypot(nearest.midX - x, nearest.midY - y) < r * 0.6 else { return it }
            let row = words.filter { w in
                abs(w.midY - nearest.midY) < nearest.height * 0.6 && hypot(w.midX - x, w.midY - y) < r
            }
            let u = union(row)
            guard u.width < r * 3.5 else { return it }
            it["x"] = u.midX; it["y"] = u.midY
            it["r"] = max(u.height / 2 + 10, u.width / 2.3 + 6)

        default:
            break
        }
        return it
    }

    // MARK: Labels

    /// The area a mark covers, in screenshot pixels.
    private static func bounds(_ it: [String: Any], scale: CGFloat) -> CGRect? {
        let n = { (k: String) in num(it[k]) }
        switch it["type"] as? String {
        case "circle":
            guard let x = n("x"), let y = n("y"), let r = n("r") else { return nil }
            return CGRect(x: x - r * 1.2, y: y - r * 1.05, width: r * 2.4, height: r * 2.1)
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
                                   size: CGSize, scale: CGFloat) {
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
        var best: (CGRect, String, CGFloat)?
        for (i, (r, anchor)) in cands.enumerated() {
            var cost = CGFloat(i) * 0.04
            if !screen.contains(r) { cost += 50 }
            let covered = words.reduce(CGFloat(0)) { acc, wr in
                let x = wr.intersection(r); return acc + (x.isNull ? 0 : x.width * x.height)
            }
            cost += covered / (w * h) * 10
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
