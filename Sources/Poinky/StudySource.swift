import AppKit
import CoreImage
import PDFKit
import Vision

/// Reading the sheet and the user's work: the question's pages straight from the PDF file (sharp text and
/// figures, and a question that runs onto the next page), and photos of handwriting cleaned up (flattened,
/// cropped to the paper, evened out) for the teacher and for the solved PDF.
enum StudySource {
    // MARK: The sheet's PDF

    static func isPDF(_ url: URL?) -> Bool { url?.pathExtension.lowercased() == "pdf" }
    static func isImage(_ url: URL?) -> Bool { ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp"].contains(url?.pathExtension.lowercased() ?? "") }

    /// The pages that hold question `number` (0-based): the page where it starts, and the next one when the
    /// question goes on there (no next-question heading before the page ends). Empty when it can't tell.
    static func questionPages(_ url: URL, number: String?) -> [Int] {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 else { return [] }
        let texts = (0..<doc.pageCount).map { doc.page(at: $0)?.string ?? "" }
        guard let n = number.flatMap({ Int($0) }) else { return doc.pageCount == 1 ? [0] : [] }
        // Headings as PDF text comes out (Hebrew is often stored reversed: "1 הלאש").
        func heads(_ k: Int) -> [String] { ["שאלה \(k)", "שאלה מספר \(k)", "\(k) הלאש", "Question \(k)", "QUESTION \(k)", "Problem \(k)", "Exercise \(k)", "שאלה \(k):", ":\(k) הלאש"] }
        func numbered(_ k: Int, in t: String) -> Bool {
            t.range(of: #"(?m)^\s*\#(k)\s*[.)]\s"#, options: .regularExpression) != nil || t.range(of: #"(?m)\s[.)]\#(k)\s*$"#, options: .regularExpression) != nil
        }
        func starts(_ k: Int, _ t: String) -> Bool { heads(k).contains(where: { t.contains($0) }) || numbered(k, in: t) }
        guard let first = texts.indices.first(where: { starts(n, texts[$0]) }) else { return doc.pageCount == 1 ? [0] : [] }
        var pages = [first]
        if first + 1 < texts.count, !starts(n + 1, texts[first]) { pages.append(first + 1) }
        return pages
    }

    /// Pages that print final answers ("final answers", "תשובות סופיות"), for the solver to compare with.
    static func answerPages(_ url: URL) -> [Int] {
        guard let doc = PDFDocument(url: url) else { return [] }
        let keys = ["final answers", "Final answers", "Answers", "תשובות סופיות", "פתרונות סופיים", "תויפוס תובושת", "םייפוס תונורתפ"]
        return (0..<doc.pageCount).filter { i in
            let t = doc.page(at: i)?.string ?? ""
            return keys.contains(where: { t.contains($0) })
        }
    }

    /// A page drawn sharp for Claude: about 1500 px tall (Claude reads up to ~1568), JPEG base64.
    static func pageImage(_ url: URL, page: Int, longSide: CGFloat = 1560) -> String? {
        guard let doc = PDFDocument(url: url), let p = doc.page(at: page) else { return nil }
        let b = p.bounds(for: .cropBox)
        let k = longSide / max(b.width, b.height)
        let img = p.thumbnail(of: NSSize(width: b.width * k, height: b.height * k), for: .cropBox)
        return jpeg(img, maxSide: longSide).map { $0.base64EncodedString() }
    }

    /// The sheet's own figure, cropped from its PDF page (`box`: pixels of that page as `pageImage` drew it for the
    /// teacher, `longSide` 1560), drawn sharper (2×) and with a little margin: a data URL for the paper, and its
    /// width / height. Nil: no such page, or a box that's not a sensible part of it.
    static func figure(_ url: URL, page: Int, box: CGRect, longSide: CGFloat = 1560) -> (dataURL: String, aspect: CGFloat)? {
        guard let doc = PDFDocument(url: url), let p = doc.page(at: page) else { return nil }
        let b = p.bounds(for: .cropBox)
        let k = longSide / max(b.width, b.height)
        let W = b.width * k, H = b.height * k
        let r = box.insetBy(dx: -8, dy: -8).intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard !r.isNull, r.width > 40, r.height > 40, r.width * r.height < W * H * 0.8 else { return nil }
        let zoom: CGFloat = 2
        let img = p.thumbnail(of: NSSize(width: W * zoom, height: H * zoom), for: .cropBox)
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let kx = CGFloat(cg.width) / W, ky = CGFloat(cg.height) / H
        guard let crop = cg.cropping(to: CGRect(x: r.minX * kx, y: r.minY * ky, width: r.width * kx, height: r.height * ky)),
              let data = jpeg(crop, maxSide: 1400, quality: 0.9) else { return nil }
        return ("data:image/jpeg;base64," + data.base64EncodedString(), r.width / r.height)
    }

    // MARK: Photos of the user's work

    static func jpeg(_ image: NSImage, maxSide: CGFloat, quality: CGFloat = 0.85) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return jpeg(cg, maxSide: maxSide, quality: quality)
    }

    static func jpeg(_ cg: CGImage, maxSide: CGFloat, quality: CGFloat = 0.85) -> Data? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let k = min(1, maxSide / max(w, h))
        let W = Int((w * k).rounded()), H = Int((h * k).rounded())
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// A photo of handwritten work made readable: the sheet of paper found and flattened (perspective),
    /// cropped to it, upright, the light evened out. Falls back to the photo as it is.
    static func cleanPhoto(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4000] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        return clean(cg)
    }

    static func clean(_ cg: CGImage) -> CGImage {
        var image = CIImage(cgImage: cg)
        let size = image.extent.size
        // Find the paper.
        let req = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        if (try? handler.perform([req])) != nil, let doc = req.results?.first, doc.confidence > 0.5 {
            func pt(_ p: CGPoint) -> CIVector { CIVector(x: p.x * size.width, y: p.y * size.height) }
            let area = abs((doc.topRight.x - doc.bottomLeft.x) * (doc.topRight.y - doc.bottomLeft.y))
            // Only when it's really a sheet (not a tiny box inside the page).
            if area > 0.25, let f = CIFilter(name: "CIPerspectiveCorrection") {
                f.setValue(image, forKey: kCIInputImageKey)
                f.setValue(pt(doc.topLeft), forKey: "inputTopLeft")
                f.setValue(pt(doc.topRight), forKey: "inputTopRight")
                f.setValue(pt(doc.bottomLeft), forKey: "inputBottomLeft")
                f.setValue(pt(doc.bottomRight), forKey: "inputBottomRight")
                if let out = f.outputImage { image = out }
            }
        }
        // Even out shadows and make ink dark on light paper (the document enhancer when there is one).
        if let f = CIFilter(name: "CIDocumentEnhancer") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(1.0, forKey: "inputAmount")
            if let out = f.outputImage { image = out }
        } else if let f = CIFilter(name: "CIColorControls") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(1.25, forKey: kCIInputContrastKey)
            f.setValue(0.05, forKey: kCIInputBrightnessKey)
            if let out = f.outputImage { image = out }
        }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(image, from: image.extent.integral) ?? cg
    }
}
