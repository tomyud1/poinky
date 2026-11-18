import CoreGraphics
import Foundation
import ImageIO

// Snapping test: real pages rendered by Chrome at 2x (like a Mac screen), scaled down the way the app sends
// screenshots (ScreenCapture.imageScale), read with the app's own OCR (TextIndex.recognize), then the
// talker's marks (with "find") snapped by MarkSnapper and checked against where Chrome says the text is.
//   snap-test cases.json renders/   (renders/<n>.png + .json from render.mjs)

let args = CommandLine.arguments
let cases = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [[String: Any]]
let dir = args[2]
var failures = 0, checks = 0
func n(_ v: Any?) -> CGFloat { CGFloat((v as? NSNumber)?.doubleValue ?? .nan) }

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
    let lines = TextIndex.recognize(image)
    let index = TextIndex(lines: lines, image: image)
    let rects = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(ci).png.json"))) as! [String: Any]
    func rect(_ phrase: String) -> CGRect {
        let a = rects[phrase] as! [Double]
        return CGRect(x: a[0] * k, y: a[1] * k, width: a[2] * k, height: a[3] * k)   // points → screenshot pixels
    }
    print("\(c["page"]!) (\(W)x\(H))")
    for m in c["marks"] as! [[String: Any]] {
        let item = m["item"] as! [String: Any]
        var t = rect(m["phrase"] as! String)
        if let to = m["to"] as? String { t = t.union(rect(to)) }
        let s = MarkSnapper.snapItem(item, lines: lines, size: CGSize(width: W, height: H), scale: k, text: index)
        let lh = t.height, tol = max(3, lh * 0.25)
        var ok = true, got = ""
        switch s["type"] as! String {
        case "underline":
            let x = n(s["x"]), w = n(s["w"]), y = n(s["y"])
            got = String(format: "x %.0f–%.0f y %.1f  (text x %.0f–%.0f, bottom %.1f)", x, x + w, y, t.minX, t.maxX, t.maxY)
            // Under these words (not their neighbors), just below the letters: never through them.
            let under = y >= t.maxY - lh * 0.2 && y <= t.maxY + max(4, lh * 0.3)
            ok = m["check"] as? String == "under" ? under : abs(x - t.minX) <= tol * 2 && abs(x + w - t.maxX) <= tol * 2 && under
        case "circle":
            let x = n(s["x"]), y = n(s["y"])
            got = String(format: "center %.0f,%.0f  (text %.0f,%.0f %.0fx%.0f)", x, y, t.minX, t.minY, t.width, t.height)
            ok = t.insetBy(dx: -tol, dy: -tol).contains(CGPoint(x: x, y: y))
        case "bracket":
            let x = n(s["x"]), y = n(s["y"]), h = n(s["h"])
            got = String(format: "x %.0f y %.0f–%.0f  (text x %.0f, %.0f–%.0f)", x, y, y + h, t.minX, t.minY, t.maxY)
            ok = abs(y - t.minY) <= tol * 2 && abs(y + h - t.maxY) <= tol * 2 && x <= t.minX + tol
        default:   // box, highlight: around the text, not much more
            let r = CGRect(x: n(s["x"]), y: n(s["y"]), width: n(s["w"]), height: n(s["h"]))
            got = String(format: "%.0f,%.0f %.0fx%.0f  (text %.0f,%.0f %.0fx%.0f)", r.minX, r.minY, r.width, r.height, t.minX, t.minY, t.width, t.height)
            ok = r.insetBy(dx: -tol, dy: -tol).contains(t) && r.width <= t.width + 40 && r.height <= t.height + 30
        }
        checks += 1
        if !ok { failures += 1 }
        print("  \(ok ? "ok  " : "FAIL") \(item["id"]!) \(s["type"]!): \(got)")
    }
}
print(failures == 0 ? "All \(checks) marks on their text." : "\(failures) of \(checks) marks missed their text.")
exit(failures == 0 ? 0 : 1)
