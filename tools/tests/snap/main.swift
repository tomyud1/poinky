import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Marks on real pages: pages rendered by Chrome at 2x (like a Mac screen), scaled down the way the app sends
// screenshots (ScreenCapture.imageScale), read with the app's own OCR (TextIndex), the talker's / teacher's
// marks snapped by MarkSnapper, then each mark's drawn shape (as overlay.html draws it: stroke width, padding,
// the circle's 1.15 stretch, the bracket 12 pt left of its x, the label tag) checked against the target's
// ink in the screenshot:
//   - it doesn't run through the target's ink (an underline or bracket: through any ink at all),
//   - a box / circle / highlight encloses all of it,
//   - an underline is under the right words, below their letters; a bracket left of the block; an arrow
//     ends just outside the target and starts outside it,
//   - the mark and its label are on the screen, and the label doesn't cover the target.
//   snap-test cases.json renders/ [pictures-dir]   (renders/<n>.png + .json from render.mjs)

let args = CommandLine.arguments
let cases = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [[String: Any]]
let dir = args[2]
let picsDir = args.count > 3 ? args[3] : nil
var failures = 0, checks = 0
var slowest = 0.0   // ms for one mark (it runs on the main thread while the reply streams in)
func n(_ v: Any?) -> CGFloat? { (v as? NSNumber).map { CGFloat($0.doubleValue) } }

/// The screenshot's pixels, to find ink (anything that isn't the background around it).
struct Pixels {
    let w: Int, h: Int, data: [UInt8]
    init(_ image: CGImage) {
        w = image.width; h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let (cw, ch) = (w, h)
        buf.withUnsafeMutableBytes { p in
            let ctx = CGContext(data: p.baseAddress, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: cw * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: cw, height: ch))
        }
        data = buf
    }
    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) { let i = (y * w + x) * 4; return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2])) }
    /// Ink pixels inside `r` (differ clearly from the most common color around it).
    func ink(in r: CGRect) -> [CGPoint] {
        let a = r.insetBy(dx: -4, dy: -4).integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !a.isNull, a.width > 0, a.height > 0 else { return [] }
        var counts: [Int: Int] = [:]
        for y in Int(a.minY)..<Int(a.maxY) { for x in Int(a.minX)..<Int(a.maxX) {
            let (p, q, s) = rgb(x, y); counts[(p >> 4) << 8 | (q >> 4) << 4 | (s >> 4), default: 0] += 1 } }
        guard let key = counts.max(by: { $0.value < $1.value })?.key else { return [] }
        let bg = (((key >> 8) & 15) * 16 + 8, ((key >> 4) & 15) * 16 + 8, (key & 15) * 16 + 8)
        let b = r.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !b.isNull, b.width > 0, b.height > 0 else { return [] }
        var out: [CGPoint] = []
        for y in Int(b.minY)..<Int(b.maxY) { for x in Int(b.minX)..<Int(b.maxX) {
            let (p, q, s) = rgb(x, y)
            if abs(p - bg.0) + abs(q - bg.1) + abs(s - bg.2) > 120 { out.append(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) }
        } }
        return out
    }
}

/// A mark as overlay.html draws it, in screenshot pixels: its strokes, half their width, and (box, circle,
/// highlight) the area it encloses.
struct Shape {
    var strokes: [[CGPoint]] = []
    var half: CGFloat = 0
    var inside: ((CGPoint) -> Bool)?
    var label: CGRect?
    var points: [CGPoint] { strokes.flatMap { $0 } }
}
func shape(_ it: [String: Any], k: CGFloat, size: CGSize) -> Shape {
    var s = Shape(half: 2.25 * k)
    let x = n(it["x"]) ?? 0, y = n(it["y"]) ?? 0
    let type = it["type"] as? String ?? ""
    switch type {
    case "circle":
        let r = max(n(it["r"]) ?? 0, 16 * k), rx = n(it["rx"]) ?? r * 1.15, ry = n(it["ry"]) ?? r
        s.strokes = [(0...96).map { i in let a = Double(i) / 96 * 2 * .pi; return CGPoint(x: x + rx * cos(a), y: y + ry * sin(a)) }]
        // The pen's wobble pulls the loop in by up to ~6% at its end.
        s.inside = { p in let dx = (p.x - x) / (rx * 0.94), dy = (p.y - y) / (ry * 0.94); return dx * dx + dy * dy <= 1 }
    case "box", "highlight":
        let pad: CGFloat = type == "box" ? 4 : 3, w = n(it["w"]) ?? 0, h = n(it["h"]) ?? 0
        let r = CGRect(x: x, y: y, width: w, height: h).insetBy(dx: -pad * k, dy: -pad * k)
        s.strokes = [[CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)]]
        if type == "highlight" { s.half = 1 * k }
        // A box's corners wobble by up to 2.5 pt.
        let j = type == "box" ? 2.5 * k + s.half : s.half
        let inner = r.insetBy(dx: j, dy: j)
        s.inside = { inner.contains($0) }
    case "underline":
        let w = n(it["w"]) ?? 0
        s.strokes = [[CGPoint(x: x, y: y), CGPoint(x: x + w, y: y)]]
    case "bracket":
        let h = max(n(it["h"]) ?? 0, 18 * k), bx = x - 12 * k, c = min(10 * k, h / 4)
        s.strokes = [[CGPoint(x: bx + 6 * k, y: y), CGPoint(x: bx, y: y + c), CGPoint(x: bx, y: y + h - c), CGPoint(x: bx + 6 * k, y: y + h)]]
    case "arrow":
        let x1 = n(it["x1"]) ?? 0, y1 = n(it["y1"]) ?? 0, x2 = n(it["x2"]) ?? 0, y2 = n(it["y2"]) ?? 0
        let a = atan2(y2 - y1, x2 - x1), hs = 18 * k
        s.strokes = [[CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2)],
                     [CGPoint(x: x2 - hs * cos(a - 0.5), y: y2 - hs * sin(a - 0.5)), CGPoint(x: x2, y: y2), CGPoint(x: x2 - hs * cos(a + 0.5), y: y2 - hs * sin(a + 0.5))]]
    case "label":
        // A note: the tag's top-left at (x, y − 24 pt).
        let text = (it["text"] as? String) ?? ""
        s.label = CGRect(x: x, y: y - 24 * k, width: (CGFloat(text.count) * 10.5 + 20) * k, height: 34 * k)
        return s
    default: break
    }
    if let text = it["label"] as? String, !text.isEmpty, let lx = n(it["lx"]), let ly = n(it["ly"]) {
        // The tag: handwriting ~10.5 pt a letter plus padding, 34 pt tall, kept on screen by the page.
        let w = (CGFloat(text.count) * 10.5 + 20) * k, h = 34 * k
        var r = CGRect(x: (it["la"] as? String) == "end" ? lx - w : lx, y: ly, width: w, height: h)
        r.origin.x = max(8 * k, min(size.width - w - 8 * k, r.minX)); r.origin.y = max(30 * k, min(size.height - h - 8 * k, r.minY))
        s.label = r
    }
    return s
}
/// Distance from p to the segment ab.
func dist(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y, l = dx * dx + dy * dy
    let t = l == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l))
    return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
}
func crossed(_ ink: [CGPoint], _ s: Shape) -> Int {
    ink.filter { p in s.strokes.contains { line in zip(line, line.dropFirst()).contains { dist(p, $0, $1) <= s.half + 0.5 } } }.count
}
func bounds(_ pts: [CGPoint]) -> CGRect { pts.dropFirst().reduce(CGRect(origin: pts[0], size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) } }

for (ci, c) in cases.enumerated() {
    let screen = c["screen"] as! [Double]
    let size = CGSize(width: screen[0], height: screen[1])
    let k = min(1, 1568 / max(size.width, size.height), (1_150_000 / (size.width * size.height)).squareRoot())
    let W = Int((size.width * k).rounded()), H = Int((size.height * k).rounded())
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: "\(dir)/\(ci).png") as CFURL, nil)!
    let full = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(full, in: CGRect(x: 0, y: 0, width: W, height: H))
    let image = ctx.makeImage()!
    let px = Pixels(image)
    let lines = TextIndex.recognize(image)
    let index = TextIndex(lines: lines, image: image)
    let rects = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(ci).png.json"))) as! [String: Any]
    func rect(_ phrase: String) -> CGRect {
        let a = rects[phrase] as! [Double]
        return CGRect(x: a[0] * k, y: a[1] * k, width: a[2] * k, height: a[3] * k)   // points → screenshot pixels
    }
    let screenRect = CGRect(x: 0, y: 0, width: W, height: H).insetBy(dx: -1, dy: -1)
    print("\(c["page"]!) (\(W)x\(H))")
    var drawn: [(Shape, Bool)] = []
    for m in c["marks"] as! [[String: Any]] {
        let item = m["item"] as! [String: Any]
        var t = rect(m["phrase"] as! String)
        if let to = m["to"] as? String { t = t.union(rect(to)) }
        let t0 = Date()
        let it = MarkSnapper.snapItem(item, lines: lines, size: CGSize(width: W, height: H), scale: k, text: index)
        slowest = max(slowest, Date().timeIntervalSince(t0) * 1000)
        let type = it["type"] as! String
        let sh = shape(it, k: k, size: CGSize(width: W, height: H))
        let ink = px.ink(in: t)
        checks += 1
        guard !ink.isEmpty else { print("  FAIL \(item["id"]!): no ink at the target"); failures += 1; continue }
        let inkBox = bounds(ink)
        var problems: [String] = []
        let tol = max(3, ink.count / 100)
        // On the screen, label too.
        if !sh.points.allSatisfy({ screenRect.contains($0) }) { problems.append("goes off the screen") }
        if let l = sh.label, !screenRect.contains(l) { problems.append("label off the screen") }
        if let l = sh.label, ink.filter({ l.contains($0) }).count > tol { problems.append("label covers the target") }
        // Not through the target's ink (a highlight is meant to lie over it).
        let through = crossed(ink, sh)
        if type != "highlight", through > tol { problems.append("runs through the target's ink (\(through) px)") }
        switch type {
        case "circle", "box", "highlight":
            let out = ink.filter { !(sh.inside?($0) ?? true) }.count
            if out > tol { problems.append("leaves \(out) of \(ink.count) ink px outside") }
        case "underline":
            let x = n(it["x"])!, w = n(it["w"])!, y = n(it["y"])!
            let slack = max(8, inkBox.height)
            if abs(x - inkBox.minX) > slack || abs(x + w - inkBox.maxX) > slack { problems.append("not under these words (x \(Int(x))–\(Int(x + w)), words \(Int(inkBox.minX))–\(Int(inkBox.maxX)))") }
            if y < inkBox.maxY + 1 || y > inkBox.maxY + max(5, inkBox.height * 0.45) { problems.append("not just below the letters (y \(Int(y)), letters end \(Int(inkBox.maxY)))") }
            let any = crossed(px.ink(in: CGRect(x: x, y: y - 4, width: w, height: 8)), sh)
            if any > 2 { problems.append("touches other ink (\(any) px)") }
        case "bracket":
            let bx = n(it["x"])! - 12 * k
            if bx >= inkBox.minX - 2 || bx < inkBox.minX - 30 * k { problems.append("not just left of the block (\(Int(bx)) vs \(Int(inkBox.minX)))") }
            let any = crossed(px.ink(in: bounds(sh.points).insetBy(dx: -4, dy: -4)), sh)
            if any > 2 { problems.append("drawn over ink (\(any) px)") }
        case "arrow":
            let tip = CGPoint(x: n(it["x2"])!, y: n(it["y2"])!), tail = CGPoint(x: n(it["x1"])!, y: n(it["y1"])!)
            let gap = max(0, max(inkBox.minX - tip.x, tip.x - inkBox.maxX)) + max(0, max(inkBox.minY - tip.y, tip.y - inkBox.maxY))
            if gap > 16 * k { problems.append("ends \(Int(gap)) px away from the target") }
            if inkBox.insetBy(dx: -2, dy: -2).contains(tail) { problems.append("starts inside the target") }
        default: break
        }
        let ok = problems.isEmpty
        if !ok { failures += 1 }
        let was = type != (item["type"] as? String ?? "") ? " (was \(item["type"]!))" : ""
        print("  \(ok ? "ok  " : "FAIL") \(item["id"]!) \(type)\(was)\(ok ? "" : ": " + problems.joined(separator: "; "))")
        drawn.append((sh, ok))
    }
    // A picture to look at: the marks (blue; red when off) and their labels over the screenshot.
    if let picsDir {
        let out = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        out.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        out.translateBy(x: 0, y: CGFloat(H)); out.scaleBy(x: 1, y: -1)
        out.setLineCap(.round); out.setLineJoin(.round)
        for (sh, ok) in drawn {
            out.setStrokeColor(ok ? CGColor(red: 0.18, green: 0.42, blue: 1, alpha: 0.8) : CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 0.8))
            out.setLineWidth(sh.half * 2)
            for l in sh.strokes { out.addLines(between: l); out.strokePath() }
            if let l = sh.label { out.setLineWidth(1); out.stroke(l) }
        }
        let url = URL(fileURLWithPath: "\(picsDir)/\(ci).png")
        if let img = out.makeImage(), let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
        }
    }
}
print(String(format: "Slowest mark: %.0f ms (strips read again, ink fitted)", slowest))
print(failures == 0 ? "All \(checks) marks on their targets." : "\(failures) of \(checks) marks are off.")
exit(failures == 0 ? 0 : 1)
