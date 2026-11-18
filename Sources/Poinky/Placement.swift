import CoreGraphics
import Foundation

/// Decides where the paper and the captions go, so they never cover what's being explained.
/// All rectangles are in screen points, origin top-left.
enum Placement {
    static let minPaperWidth: CGFloat = 480
    static let maxPaperWidth: CGFloat = 760
    static let minPaperHeight: CGFloat = 260
    /// The smallest paper still worth drawing on, used when nothing bigger fits beside what's being
    /// explained: 360 pt is the paper's 800 units at 0.45 (body text ~10 pt, headings ~15 pt), and 240 pt
    /// is the height it opens at. A small paper beside the subject beats a big one on top of it.
    static let smallestPaperWidth: CGFloat = 360
    static let smallestPaperHeight: CGFloat = 240
    static let margin: CGFloat = 24
    static let topInset: CGFloat = 40      // menu bar
    static let bottomInset: CGFloat = 24

    /// What the paper should keep off, in screen points (origin top-left).
    struct Room {
        /// What the question is about (your marks, the talker's marks, the region the talker named, the
        /// teacher's screen marks): never covered while there's any spot of the smallest size beside it.
        var subjects: [CGRect] = []
        /// Around the cursor: avoided when there's room anyway (a hint, not what's asked about).
        var soft: [CGRect] = []
        /// Other cards (a 3D model, an earlier paper).
        var occupied: [CGRect] = []
        /// Lines of text on the screen: an empty part of the screen is better than one full of text.
        var text: [CGRect] = []
        init(subjects: [CGRect] = [], soft: [CGRect] = [], occupied: [CGRect] = [], text: [CGRect] = []) {
            self.subjects = subjects; self.soft = soft; self.occupied = occupied; self.text = text
        }
    }

    /// The best spot for the paper (kept for callers with one focus rect: it's the subject).
    static func paper(screen: CGSize, focus: CGRect?, occupied: [CGRect], maxWidth: CGFloat = maxPaperWidth) -> CGRect {
        let subjects = focus.map { [$0] }?.filter { !$0.isNull && $0.width > 0 } ?? []
        return paper(screen: screen, room: Room(subjects: subjects, occupied: occupied), maxWidth: maxWidth)
    }

    /// The best spot for the paper: the biggest free area (up to a comfortable size) that covers none of
    /// the subjects, preferring empty parts of the screen, away from the cursor and other cards, next to
    /// the subject. Returns the frame; its height is the room the paper may grow into (the paper never
    /// grows past it, so it never slides onto the subject).
    /// `width`: only that width (an open paper being moved keeps its size), at least `minHeight` tall.
    static func paper(screen: CGSize, room: Room, maxWidth: CGFloat = maxPaperWidth,
                      width: CGFloat? = nil, minHeight: CGFloat? = nil) -> CGRect {
        let usable = CGRect(x: 0, y: topInset, width: screen.width, height: screen.height - topInset - bottomInset)
            .insetBy(dx: margin, dy: margin)
        let subjects = room.subjects.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        let blocks = subjects.map { $0.insetBy(dx: -margin * 0.75, dy: -margin * 0.75) }
        let density = TextDensity(screen: screen, lines: room.text)
        let anchor = subjects.isEmpty ? nil : subjects.dropFirst().reduce(subjects[0]) { $0.union($1) }
        let maxW = max(smallestPaperWidth, min(maxWidth, usable.width))

        struct Cand { var frame: CGRect; var score: CGFloat; var covered: CGFloat }
        func candidates(widths: [CGFloat], minH: CGFloat, allowCover: Bool) -> [Cand] {
            var out: [Cand] = []
            let step: CGFloat = 16
            for w in widths where w <= usable.width {
                // A grid, plus the spots right against each subject (the grid can miss a tight fit).
                var xs = Array(stride(from: usable.minX, through: usable.maxX - w, by: step)) + [usable.maxX - w]
                xs += blocks.flatMap { [$0.maxX, $0.minX - w] }.filter { $0 >= usable.minX && $0 <= usable.maxX - w }
                let ys = Array(stride(from: usable.minY, through: usable.maxY - minH, by: step))
                    + blocks.map(\.maxY).filter { $0 >= usable.minY && $0 <= usable.maxY - minH }
                for x in xs {
                    let column = blocks.filter { $0.minX < x + w && $0.maxX > x }
                    for y in ys {
                        var bottom = usable.maxY, covered: CGFloat = 0
                        if !allowCover {
                            // The top can't be inside a subject; the paper may grow down to the next one.
                            if column.contains(where: { $0.minY <= y && $0.maxY > y }) { continue }
                            for b in column where b.minY > y { bottom = min(bottom, b.minY) }
                        }
                        let h = bottom - y
                        guard h >= minH else { continue }
                        let f = CGRect(x: x, y: y, width: w, height: h)
                        if allowCover {
                            // Nothing fits: cover as little of the subject as possible with the paper's first screenful.
                            let seen = CGRect(x: x, y: y, width: w, height: min(h, 420))
                            covered = subjects.reduce(0) { acc, s in let i = s.intersection(seen); return acc + (i.isNull ? 0 : i.width * i.height) }
                        }
                        out.append(Cand(frame: f, score: score(f), covered: covered))
                    }
                }
            }
            return out
        }
        func score(_ f: CGRect) -> CGFloat {
            // What the paper usually shows: its width, and up to ~560 pt of height (it grows as it's drawn on).
            let seen = CGRect(x: f.minX, y: f.minY, width: f.width, height: min(f.height, 560))
            // (Past ~85% of the widest, more width hardly matters: it doesn't outweigh covering the page.)
            var s = min(f.width, maxW * 0.85) * min(f.height, 700)
            for o in room.occupied { let i = o.intersection(seen); if !i.isNull { s -= i.width * i.height * 3 } }
            for o in room.soft { let i = o.intersection(seen); if !i.isNull { s -= i.width * i.height * 2 } }
            s -= density.covered(seen) * 3
            if let a = anchor {
                // Beside the subject, its top level with the subject's: the pen's arrows read naturally.
                let gapX = max(0, max(a.minX - f.maxX, f.minX - a.maxX)), gapY = max(0, max(a.minY - f.maxY, f.minY - a.maxY))
                s -= (gapX + gapY) * 40
                if f.minX >= a.maxX || f.maxX <= a.minX { s -= abs(f.minY - max(usable.minY, a.minY)) * 30 }
            } else {
                s -= (f.minY - usable.minY) * 20
            }
            s += f.minX * 0.5   // ties: the right side, like before
            return s
        }
        var full = Array(stride(from: maxW, through: minPaperWidth, by: -40)) + [minPaperWidth]
        var small = Array(stride(from: min(maxW, minPaperWidth - 40), through: smallestPaperWidth, by: -40)) + [smallestPaperWidth]
        var tiers = [(minPaperHeight, false), (smallestPaperHeight, true)]
        if let w = width {
            full = [min(w, usable.width)]; small = []
            tiers = [(min(minHeight ?? minPaperHeight, usable.height), false)]
        }
        // A comfortable paper beside the subject; else a smaller one beside it; only then one that covers some of it.
        for (minH, withSmall) in tiers {
            if let best = candidates(widths: withSmall ? full + small : full, minH: minH, allowCover: false).max(by: { $0.score < $1.score }) { return best.frame }
        }
        let fallback = candidates(widths: width.map { [min($0, usable.width)] } ?? [smallestPaperWidth, minPaperWidth],
                                  minH: min(minHeight ?? smallestPaperHeight, usable.height), allowCover: true)
        if let best = fallback.min(by: { $0.covered != $1.covered ? $0.covered < $1.covered : $0.score > $1.score }) { return best.frame }
        // A screen too small for any paper: the whole usable area.
        return usable
    }

    /// How much of an area is text, from the screen's OCR lines (a grid with running sums, so each
    /// question about a candidate spot is four lookups).
    struct TextDensity {
        let cell: CGFloat = 8
        let cols: Int, rows: Int
        private var sum: [Float]   // (rows+1) x (cols+1) running sums of text area per cell
        init(screen: CGSize, lines: [CGRect]) {
            cols = max(1, Int((screen.width / cell).rounded(.up))); rows = max(1, Int((screen.height / cell).rounded(.up)))
            var grid = [Float](repeating: 0, count: cols * rows)
            for l in lines where !l.isNull && l.width > 0 {
                let c0 = max(0, Int(l.minX / cell)), c1 = min(cols - 1, Int(l.maxX / cell))
                let r0 = max(0, Int(l.minY / cell)), r1 = min(rows - 1, Int(l.maxY / cell))
                guard c0 <= c1, r0 <= r1 else { continue }
                for r in r0...r1 { for c in c0...c1 {
                    let cr = CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell).intersection(l)
                    if !cr.isNull { grid[r * cols + c] = min(Float(cell * cell), grid[r * cols + c] + Float(cr.width * cr.height)) }
                } }
            }
            sum = [Float](repeating: 0, count: (rows + 1) * (cols + 1))
            for r in 0..<rows { for c in 0..<cols {
                sum[(r + 1) * (cols + 1) + c + 1] = grid[r * cols + c] + sum[r * (cols + 1) + c + 1] + sum[(r + 1) * (cols + 1) + c] - sum[r * (cols + 1) + c]
            } }
        }
        /// Points² of text inside `r` (to the nearest cell).
        func covered(_ r: CGRect) -> CGFloat {
            let c0 = max(0, min(cols, Int((r.minX / cell).rounded()))), c1 = max(0, min(cols, Int((r.maxX / cell).rounded())))
            let r0 = max(0, min(rows, Int((r.minY / cell).rounded()))), r1 = max(0, min(rows, Int((r.maxY / cell).rounded())))
            guard c1 > c0, r1 > r0 else { return 0 }
            let w = cols + 1
            return CGFloat(sum[r1 * w + c1] - sum[r0 * w + c1] - sum[r1 * w + c0] + sum[r0 * w + c0])
        }
    }

    /// Captions go at the bottom unless something important is there; then at the top.
    static func captionsAtTop(screen: CGSize, avoid: [CGRect]) -> Bool {
        let w = min(860, screen.width * 0.8)
        let bottom = CGRect(x: (screen.width - w) / 2, y: screen.height - 44 - 130, width: w, height: 130)
        let top = CGRect(x: (screen.width - w) / 2, y: topInset, width: w, height: 130)
        func overlap(_ r: CGRect) -> CGFloat {
            avoid.reduce(0) { acc, a in let i = a.intersection(r); return acc + (i.isNull ? 0 : i.width * i.height) }
        }
        return overlap(bottom) > 0 && overlap(top) < overlap(bottom)
    }

    /// The place on the screen a teacher brief says it's about, in screenshot pixels: "roughly 110,200
    /// to 800,530" (an area) or "around 570,540" (a point: a thing of unknown size there, so a box of
    /// `pointBox` around it). The talker writes these as the prompt shows ("…, around 300,650"). Nil
    /// when the brief names no place. Only the last place counts (the brief ends with what it relates to).
    static func region(inBrief brief: String, pointBox: CGSize = CGSize(width: 360, height: 260)) -> CGRect? {
        let n = #"(\d{1,4}(?:\.\d+)?)"#, sep = #"\s*,\s*"#
        let area = "\\(?" + n + sep + n + "\\)?\\s*(?:to|through|-|–|—|and)\\s*\\(?" + n + sep + n + "\\)?"
        let point = "(?:around|near|at|about|by|approximately|roughly|~)\\s*(?:x\\s*[=≈]?\\s*)?\\(?" + n + sep + "(?:y\\s*[=≈]?\\s*)?" + n + "\\)?"
        func matches(_ pattern: String) -> [[CGFloat]] {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let ns = brief as NSString
            return re.matches(in: brief, range: NSRange(location: 0, length: ns.length)).map { m in
                (1..<m.numberOfRanges).compactMap { Double(ns.substring(with: m.range(at: $0))).map { CGFloat($0) } }
            }
        }
        if let a = matches(area).last, a.count == 4 {
            let r = CGRect(x: min(a[0], a[2]), y: min(a[1], a[3]), width: abs(a[2] - a[0]), height: abs(a[3] - a[1]))
            if r.width >= 8, r.height >= 8, r.minX >= 0, r.minY >= 0, max(a[0], a[2]) >= 20, max(a[1], a[3]) >= 20 { return r }
        }
        // "around 1,000 tickets" reads as the point (1, 0): numbers like that are counts, not places.
        if let p = matches(point).last, p.count == 2, p[0] >= 20, p[1] >= 20 {
            return CGRect(x: p[0] - pointBox.width / 2, y: p[1] - pointBox.height / 2, width: pointBox.width, height: pointBox.height)
        }
        return nil
    }

    /// The area the teacher's `screen` marks in one lesson step cover ({"ops":[…]} or a bare list), in points.
    static func bounds(ofStep json: String, scale: CGFloat) -> CGRect? {
        guard let data = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let ops = (obj as? [String: Any])?["ops"] as? [[String: Any]] ?? (obj as? [[String: Any]]) ?? []
        let screen = ops.filter { $0["op"] as? String == "screen" }
        guard !screen.isEmpty, let d = try? JSONSerialization.data(withJSONObject: ["items": screen]),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return bounds(ofDraw: s, scale: scale)
    }

    /// The area covered by the talker's marks ({"items":[…]} in screenshot pixels), in points.
    static func bounds(ofDraw json: String, scale: CGFloat) -> CGRect? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return nil }
        func n(_ v: Any?) -> CGFloat { CGFloat((v as? NSNumber)?.doubleValue ?? 0) }
        var box = CGRect.null
        for it in items {
            var r = CGRect.null
            switch it["type"] as? String {
            case "circle": let rad = n(it["r"]); r = CGRect(x: n(it["x"]) - rad * 1.2, y: n(it["y"]) - rad, width: rad * 2.4, height: rad * 2)
            case "box", "highlight": r = CGRect(x: n(it["x"]), y: n(it["y"]), width: n(it["w"]), height: n(it["h"]))
            case "underline": r = CGRect(x: n(it["x"]), y: n(it["y"]) - 24, width: n(it["w"]), height: 28)
            case "bracket": r = CGRect(x: n(it["x"]) - 24, y: n(it["y"]), width: 24, height: n(it["h"]))
            case "arrow":
                let xs = [n(it["x1"]), n(it["x2"])], ys = [n(it["y1"]), n(it["y2"])]
                r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            default: continue
            }
            box = box.union(r)
        }
        guard !box.isNull, scale > 0 else { return nil }
        return CGRect(x: box.minX / scale, y: box.minY / scale, width: box.width / scale, height: box.height / scale)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(hi, v)) }
}
