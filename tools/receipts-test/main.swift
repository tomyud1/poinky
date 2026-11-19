import AppKit
@MainActor func run() {
    var fails = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { fails += 1 } }
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POINKY_RECEIPTS_DIR"]!)
    Receipts.clear()
    check(Receipts.all().isEmpty, "starts empty")
    // a tiny JPEG as the screenshot
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1568, pixelsHigh: 980, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let jpg = rep.representation(using: .jpeg, properties: [:])!.base64EncodedString()
    var first = ""
    for i in 0..<25 {
        var r = Receipt(id: "r\(String(format: "%02d", i))", at: Date().addingTimeInterval(Double(i)))
        r.question = "question \(i)"; r.app = "Preview"; r.document = "~/Lecture 5.pdf"; r.selectionChars = i % 2 == 0 ? 40 : 0
        r.front = ["Front app: Preview, window “Lecture 5.pdf”."]
        r.parts = Receipts.parts(memoryEnabled: true)
        r.message = "User said: \"question \(i)\""
        let id = Receipts.add(r, jpegBase64: jpg)
        if i == 0 { first = id ?? "" }
    }
    check(first == "r00", "add returns the id")
    check(Receipts.all().count == Receipts.keep, "keeps the last \(Receipts.keep) (\(Receipts.all().count))")
    check(Receipts.all().first?.id == "r05", "oldest dropped")
    for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    let fm = FileManager.default
    check(fm.fileExists(atPath: Receipts.thumbURL("r24").path), "thumbnail written")
    check(!fm.fileExists(atPath: Receipts.thumbURL("r00").path), "dropped receipt's thumbnail gone")
    if let img = NSImage(contentsOf: Receipts.thumbURL("r24")), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        check(cg.width == 640, "thumbnail is 640 px wide (\(cg.width))")
    } else { check(false, "thumbnail readable") }
    let perm = (try? fm.attributesOfItem(atPath: Receipts.listURL.path)[.posixPermissions] as? Int) ?? 0
    check(perm == 0o600, "receipts.json is 0600 (\(String(perm, radix: 8)))")
    let tperm = (try? fm.attributesOfItem(atPath: Receipts.thumbURL("r24").path)[.posixPermissions] as? Int) ?? 0
    check(tperm == 0o600, "thumbnail is 0600")
    let dperm = (try? fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) ?? 0
    check(dperm == 0o700, "folder is 0700 (\(String(dperm, radix: 8)))")
    check(Receipts.latest?.summary == "Screenshot + Preview: Lecture 5.pdf + your selection", "summary: \(Receipts.latest?.summary ?? "-")")
    Receipts.update("r24") { $0.lookups.append("Web search “x”") }
    check(Receipts.latest?.summary.hasSuffix("+ a web search") == true, "lookup in summary")
    // reads back from disk (fresh cache)
    let data = try! Data(contentsOf: Receipts.listURL)
    check(String(data: data, encoding: .utf8)!.contains("identity.md"), "parts saved by name")
    check(!String(data: data, encoding: .utf8)!.contains("xxxxxxxx"), "part text not saved")
    var p = Receipt(id: "w", at: Date()); p.app = "Safari"; p.page = "https://www.youtube.com/watch?v=abc"
    check(p.summary == "Screenshot + Safari: youtube.com", "page summary: \(p.summary)")
    Receipts.enabled = false
    Receipts.add(Receipt(id: "off", at: Date()), jpegBase64: jpg)
    check(!Receipts.all().contains { $0.id == "off" }, "nothing recorded when off")
    Receipts.clear()
    check(!fm.fileExists(atPath: dir.path) && Receipts.all().isEmpty, "clear removes everything")
    print(fails == 0 ? "ALL PASSED" : "\(fails) FAILED")
    exit(fails == 0 ? 0 : 1)
}
MainActor.assumeIsolated { run() }
