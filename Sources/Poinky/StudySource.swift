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
    static func cleanPhoto(_ url: URL, flat: Bool = false) -> CGImage? { cleanPhotoInfo(url, flat: flat)?.image }

    /// Also says how much of the photo the paper took up (1: nothing was cropped). `flat`: a scan or a PDF
    /// page (already straight and cropped): only the light is evened out.
    static func cleanPhotoInfo(_ url: URL, flat: Bool = false) -> (image: CGImage, kept: Double)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4000] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        return cleanInfo(cg, flat: flat)
    }

    static func clean(_ cg: CGImage) -> CGImage { cleanInfo(cg).image }

    static func cleanInfo(_ cg: CGImage, flat: Bool = false) -> (image: CGImage, kept: Double) {
        var image = CIImage(cgImage: cg)
        let size = image.extent.size
        var kept = 1.0
        // Find the paper.
        let req = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        if !flat, (try? handler.perform([req])) != nil, let doc = req.results?.first, doc.confidence > 0.5 {
            func pt(_ p: CGPoint) -> CIVector { CIVector(x: p.x * size.width, y: p.y * size.height) }
            let area = abs((doc.topRight.x - doc.bottomLeft.x) * (doc.topRight.y - doc.bottomLeft.y))
            // Only when it's really a sheet (not a tiny box inside the page).
            if area > 0.25, let f = CIFilter(name: "CIPerspectiveCorrection") {
                f.setValue(image, forKey: kCIInputImageKey)
                f.setValue(pt(doc.topLeft), forKey: "inputTopLeft")
                f.setValue(pt(doc.topRight), forKey: "inputTopRight")
                f.setValue(pt(doc.bottomLeft), forKey: "inputBottomLeft")
                f.setValue(pt(doc.bottomRight), forKey: "inputBottomRight")
                if let out = f.outputImage { image = out; kept = Double(area) }
            }
        }
        // Even out the light: the photo divided by the paper alone (the ink taken out by a local maximum, then
        // blurred), so a dim room, a warm lamp and the phone's own hard shadow all come out white paper with the
        // ink as dark as it was against the paper around it. (CIDocumentEnhancer alone left hard shadows gray
        // and dim photos faint: see tools/study/make-hard.py.) Then the ink a little darker.
        image = evenLight(image)
        if let f = CIFilter(name: "CIGammaAdjust") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(1.5, forKey: "inputPower")
            if let out = f.outputImage { image = out }
        }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return (ctx.createCGImage(image, from: image.extent.integral) ?? cg, kept)
    }

    /// The image divided by an estimate of the bare paper under it (flat-field correction).
    static func evenLight(_ image: CIImage) -> CIImage {
        let ext = image.extent
        guard ext.width > 64, ext.height > 64 else { return image }
        // Worked out at a quarter size (fast); the radius is a little wider than a pen stroke.
        let k: CGFloat = 0.25
        let r = max(6, min(ext.width, ext.height) / 110) * k
        let small = image.transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let paper = CIFilter(name: "CIMorphologyMaximum", parameters: [kCIInputImageKey: small.clampedToExtent(), kCIInputRadiusKey: r])?.outputImage,
              let soft = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: paper, kCIInputRadiusKey: r])?.outputImage,
              let f = CIFilter(name: "CIDivideBlendMode") else { return image }
        // (CIDivideBlendMode gives background ÷ input: the photo ÷ the paper.)
        f.setValue(soft.transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k)).cropped(to: ext), forKey: kCIInputImageKey)
        f.setValue(image, forKey: kCIInputBackgroundImageKey)
        return f.outputImage?.cropped(to: ext) ?? image
    }
}
