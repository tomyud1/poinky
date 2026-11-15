import AppKit

/// Paper or chalkboard: a lesson on a dark screen (a dark-mode app, a code editor, a video) gets a dark
/// chalkboard instead of a bright sheet. The setting `paperLook` can force either one.
enum PaperLook {
    /// "paper" or "chalk", as the overlay's `SB.lessonBegin` frame takes it.
    static func pick(setting: String, brightness: Double?) -> String {
        switch setting {
        case "paper": return "paper"
        case "chalkboard", "chalk": return "chalk"
        default: return (brightness ?? 1) < darkBelow ? "chalk" : "paper"
        }
    }

    /// Average brightness (0 black … 1 white) under which the screen counts as dark.
    static let darkBelow = 0.38

    /// How bright the screenshot is inside `rect` (screen points), grown a little so the paper's
    /// surroundings count too. Nil when the picture can't be read.
    static func brightness(of snapshot: Snapshot, in rect: CGRect) -> Double? {
        guard let data = Data(base64Encoded: snapshot.jpegBase64),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let px = rect.insetBy(dx: -40, dy: -40)
        let r = CGRect(x: px.minX * snapshot.scale, y: px.minY * snapshot.scale,
                       width: px.width * snapshot.scale, height: px.height * snapshot.scale)
        return brightness(of: image, in: r)
    }

    /// Mean luminance of `image` inside `rect` (image pixels, top-left origin), sampled on a 48×48 grid.
    static func brightness(of image: CGImage, in rect: CGRect) -> Double? {
        let r = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard r.width >= 4, r.height >= 4, let crop = image.cropping(to: r) else { return nil }
        let n = 48
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        var sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += (0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])) / 255
        }
        return sum / Double(n * n)
    }
}
