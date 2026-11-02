import CoreGraphics
import Foundation

/// Decides where the paper and the captions go, so they never cover what's being explained.
/// All rectangles are in screen points, origin top-left.
enum Placement {
    static let minPaperWidth: CGFloat = 480
    static let maxPaperWidth: CGFloat = 760
    static let minPaperHeight: CGFloat = 260
    static let margin: CGFloat = 24
    static let topInset: CGFloat = 40      // menu bar
    static let bottomInset: CGFloat = 24

    /// The best spot for the paper: the largest free area beside, above or below the focus,
    /// avoiding other cards. Returns the frame (its height is the room it may grow into).
    static func paper(screen: CGSize, focus: CGRect?, occupied: [CGRect], maxWidth: CGFloat = maxPaperWidth) -> CGRect {
        let maxPaperWidth = maxWidth
        let usable = CGRect(x: 0, y: topInset, width: screen.width, height: screen.height - topInset - bottomInset)
        guard let focus, !focus.isNull, focus.width > 0 else {
            // Nothing in particular to avoid: the right side.
            let w = min(maxPaperWidth, max(minPaperWidth, screen.width * 0.42))
            return CGRect(x: usable.maxX - w - margin, y: usable.minY + margin, width: w, height: usable.height - 2 * margin)
        }
        let f = focus.insetBy(dx: -margin, dy: -margin).intersection(usable)
        let regions: [(String, CGRect)] = [
            ("left", CGRect(x: usable.minX, y: usable.minY, width: max(0, f.minX - usable.minX), height: usable.height)),
            ("right", CGRect(x: f.maxX, y: usable.minY, width: max(0, usable.maxX - f.maxX), height: usable.height)),
            ("above", CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: max(0, f.minY - usable.minY))),
            ("below", CGRect(x: usable.minX, y: f.maxY, width: usable.width, height: max(0, usable.maxY - f.maxY))),
        ]
        var best: (CGRect, CGFloat)?
        for (side, region) in regions {
            let w = min(maxPaperWidth, region.width - 2 * margin)
            let h = region.height - 2 * margin
            guard w >= minPaperWidth, h >= minPaperHeight else { continue }
            var frame: CGRect
            switch side {
            case "left":
                frame = CGRect(x: region.maxX - margin - w, y: 0, width: w, height: h)
                frame.origin.y = clamp(f.minY, region.minY + margin, region.maxY - margin - min(h, 520))
                frame.size.height = region.maxY - margin - frame.minY
            case "right":
                frame = CGRect(x: region.minX + margin, y: 0, width: w, height: h)
                frame.origin.y = clamp(f.minY, region.minY + margin, region.maxY - margin - min(h, 520))
                frame.size.height = region.maxY - margin - frame.minY
            default: // above / below: centered on the focus
                frame = CGRect(x: clamp(focus.midX - w / 2, region.minX + margin, region.maxX - margin - w),
                               y: region.minY + margin, width: w, height: h)
            }
            // Bigger is better (up to a comfortable size); overlapping other cards is bad.
            var score = min(frame.width, maxPaperWidth) * min(frame.height, 820)
            for o in occupied {
                let i = o.intersection(frame)
                if !i.isNull { score -= i.width * i.height * 3 }
            }
            if best == nil || score > best!.1 { best = (frame, score) }
        }
        if let best { return best.0 }
        // No free area is big enough (the focus is huge): use the wider side, overlapping a little.
        let leftW = f.minX - usable.minX, rightW = usable.maxX - f.maxX
        let w = max(minPaperWidth, min(maxPaperWidth, max(leftW, rightW) - 2 * margin))
        let x = leftW > rightW ? max(usable.minX + margin, f.minX - margin - w) : min(usable.maxX - margin - w, f.maxX + margin)
        return CGRect(x: x, y: usable.minY + margin, width: w, height: usable.height - 2 * margin)
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
