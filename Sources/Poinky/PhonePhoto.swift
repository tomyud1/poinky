import AppKit
import PDFKit
import UniformTypeIdentifiers

// Pictures of something on paper (your handwritten work, a circuit, a page of notes), from your iPhone
// (Continuity Camera), a dropped or pasted image, a photo you just AirDropped, or an iPad export (PNG / PDF).
// This file: where they come from and how they're kept. The flow (the card, where they go) is in
// CallController+Photo.swift.

/// Where pictures came from (said and shown: "from your iPhone", "from Downloads").
enum PhotoOrigin: String {
    case phone, drop, paste, recent, file
}

/// How a capture ended.
enum CaptureOutcome: Equatable {
    case files([URL])        // in page order
    case noDevice            // no iPhone or iPad offered (none nearby, or Continuity Camera is off)
    case cancelled           // the menu was closed without picking anything (or one of our own items was picked)
    case timedOut            // a device was picked, but no picture came
    case failed(String)
}

/// Something that can bring a picture from a phone. The real one is Continuity Camera (a menu with the
/// nearby devices' Take Photo / Scan Documents / Add Sketch); tests use `FakePhone` (POINKY_FAKE_PHONE).
@MainActor
protocol PhotoDevice: AnyObject {
    /// Shows the device menu at `point` (screen coordinates, bottom-left origin) with `extras` under the device
    /// items. `waiting`: a device was picked and the picture is being taken. `done`: called once.
    func capture(at point: NSPoint, extras: [NSMenuItem], waiting: @escaping () -> Void, done: @escaping (CaptureOutcome) -> Void)
    func cancel()
}

enum PhotoDevices {
    @MainActor static func make() -> PhotoDevice {
        if let spec = ProcessInfo.processInfo.environment["POINKY_FAKE_PHONE"], !spec.isEmpty { return FakePhone(spec: spec) }
        return ContinuityCamera.shared
    }
    /// How long a picked device has to send its picture.
    static var timeout: Double { ProcessInfo.processInfo.environment["POINKY_PHONE_TIMEOUT"].flatMap(Double.init) ?? 180 }
}

// MARK: - Continuity Camera

/// AppKit's Continuity Camera: a contextual menu shown for a view whose responder chain accepts images gets the
/// nearby iPhones and iPads, each with Take Photo / Scan Documents / Add Sketch; the picture arrives later on a
/// pasteboard through `readSelection(from:)` (the Services mechanism). Poinky's overlay and notch can't become
/// key, so a 2-point invisible panel at the menu's spot is made key (a non-activating panel: the app in front
/// stays in front) and its view is the requestor. It stays alive until the picture comes or the wait ends.
@MainActor
final class ContinuityCamera: NSObject, PhotoDevice, NSMenuDelegate {
    static let shared = ContinuityCamera()

    /// What the last menu looked like (for the log, and for tests of the real menu): our items, AppKit's items.
    private(set) var lastMenu: [String] = []
    private var host: CaptureHostPanel?
    private var view: CaptureView?
    private var done: ((CaptureOutcome) -> Void)?
    private var picked: NSMenuItem?
    private var ours = Set<ObjectIdentifier>()
    private var placeholder: NSMenuItem?
    private var actionObserver: Any?

    /// Image and PDF return types, registered once, so AppKit asks the responder chain for them.
    static let returnTypes: [NSPasteboard.PasteboardType] = [.pdf, .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"),
                                                             NSPasteboard.PasteboardType("public.heic"), NSPasteboard.PasteboardType("public.image")]
    private static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        NSApp.registerServicesMenuSendTypes([], returnTypes: returnTypes)
    }

    func capture(at point: NSPoint, extras: [NSMenuItem], waiting: @escaping () -> Void, done: @escaping (CaptureOutcome) -> Void) {
        Self.register()
        cancel()
        self.done = done
        picked = nil
        let panel = host ?? makeHost()
        panel.setFrame(NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(view)

        let menu = NSMenu(title: "Poinky photo")
        menu.delegate = self
        menu.autoenablesItems = false
        // Replaced by the devices when AppKit finds any (menuWillOpen takes it out then).
        let none = NSMenuItem(title: PhotoWords.noDeviceMenu, action: nil, keyEquivalent: "")
        none.isEnabled = false
        placeholder = none
        menu.addItem(none)
        if !extras.isEmpty {
            menu.addItem(.separator())
            for e in extras { menu.addItem(e) }
        }
        ours = Set(([none] + extras).map(ObjectIdentifier.init))
        actionObserver = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: nil) { [weak self] n in
            let item = n.userInfo?["MenuItem"] as? NSMenuItem
            MainActor.assumeIsolated { if let item { self?.picked = item } }
        }
        // Tests of the real menu (`POINKY_PHONE_MENU_CLOSE=<secs>`): it closes by itself after looking.
        if let s = ProcessInfo.processInfo.environment["POINKY_PHONE_MENU_CLOSE"].flatMap(Double.init) {
            let t = Timer(timeInterval: s, repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(t, forMode: .common)
        }
        guard let view, let event = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 1, y: 1), modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            finish(.failed("couldn't show the menu")); return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: view)   // returns when the menu closes
        if let o = actionObserver { NotificationCenter.default.removeObserver(o); actionObserver = nil }
        let devices = menu.items.filter { !ours.contains(ObjectIdentifier($0)) && !$0.isSeparatorItem }
        lastMenu = menu.items.map { $0.isSeparatorItem ? "—" : $0.title + ($0.submenu.map { " ▸ " + $0.items.map(\.title).joined(separator: " / ") } ?? "") }
        Timeline.log("phone.menu", ["devices": devices.count, "picked": picked.map { ours.contains(ObjectIdentifier($0)) ? "ours" : "device" } ?? "none"])
        if let p = picked, !ours.contains(ObjectIdentifier(p)) {
            waiting()   // the picture is being taken on the device; `readSelection` brings it
            host?.orderOut(nil)
            return
        }
        finish(devices.isEmpty && picked == nil ? .noDevice : .cancelled)
    }

    func cancel() {
        guard done != nil else { return }
        done = nil
        host?.orderOut(nil)
    }

    private func finish(_ o: CaptureOutcome) {
        host?.orderOut(nil)
        let d = done
        done = nil
        d?(o)
    }

    func menuWillOpen(_ menu: NSMenu) {
        // AppKit has put the devices in by now: the "none nearby" line goes when there are any.
        let others = menu.items.filter { !ours.contains(ObjectIdentifier($0)) && !$0.isSeparatorItem }
        if !others.isEmpty, let p = placeholder, let i = menu.items.firstIndex(of: p) {
            menu.removeItem(at: i)
            if menu.items.indices.contains(i), menu.items[i].isSeparatorItem, i == 0 { menu.removeItem(at: i) }
        }
    }

    private func makeHost() -> CaptureHostPanel {
        let p = CaptureHostPanel(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2), styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let v = CaptureView(frame: NSRect(x: 0, y: 0, width: 2, height: 2))
        v.onRead = { [weak self] pb in
            MainActor.assumeIsolated {
                let files = PhotoFiles.fromPasteboard(pb, origin: .phone)
                Timeline.log("phone.received", ["files": files.count, "types": (pb.types ?? []).prefix(4).map(\.rawValue).joined(separator: ",")])
                guard !files.isEmpty else { return false }
                self?.finish(.files(files))
                return true
            }
        }
        p.contentView = v
        host = p
        view = v
        return p
    }
}

final class CaptureHostPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The responder AppKit asks for an image requestor; Continuity Camera's picture comes back to it.
final class CaptureView: NSView, NSServicesMenuRequestor {
    var onRead: ((NSPasteboard) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let r = returnType, PhotoFiles.isPictureType(r) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }
    func readSelection(from pboard: NSPasteboard) -> Bool { onRead?(pboard) ?? false }
}

// MARK: - The fake phone (tests)

/// POINKY_FAKE_PHONE: "<file>[,<file>…]" (the picture(s) it "takes"), "none" (no device), "cancel" (the menu is
/// closed), "timeout" (picked, nothing comes). POINKY_FAKE_PHONE_DELAY: seconds from the pick to the picture.
/// Each capture uses the next ";"-separated spec, so a test can script a retake ("a.jpg;b.jpg").
@MainActor
final class FakePhone: PhotoDevice {
    private var specs: [String]
    private var work: DispatchWorkItem?
    private(set) var captures = 0
    init(spec: String) { specs = spec.split(separator: ";").map(String.init) }

    func capture(at point: NSPoint, extras: [NSMenuItem], waiting: @escaping () -> Void, done: @escaping (CaptureOutcome) -> Void) {
        let spec = specs.isEmpty ? "none" : (specs.count > 1 ? specs.removeFirst() : specs[0])
        captures += 1
        Timeline.log("phone.fake", ["spec": URL(fileURLWithPath: spec).lastPathComponent, "n": captures])
        let delay = ProcessInfo.processInfo.environment["POINKY_FAKE_PHONE_DELAY"].flatMap(Double.init) ?? 1.5
        switch spec {
        case "none": DispatchQueue.main.async { done(.noDevice) }
        case "cancel": DispatchQueue.main.async { done(.cancelled) }
        case "timeout": DispatchQueue.main.async { waiting() }   // and nothing comes (the inbox's own wait ends it)
        default:
            DispatchQueue.main.async { waiting() }
            let w = DispatchWorkItem {
                let files = spec.split(separator: ",").map { PhotoFiles.copyIn(URL(fileURLWithPath: String($0))) }.compactMap { $0 }
                done(files.isEmpty ? .failed("no such file") : .files(files))
            }
            work = w
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
        }
    }

    func cancel() { work?.cancel(); work = nil }
}

// MARK: - Files

/// Pictures are kept only in Poinky's support folder (0700 folders, 0600 files): `photos/inbox` until they're
/// used (a question takes them, or a study session moves them into its sheet's folder), then deleted.
enum PhotoFiles {
    static var inbox: URL {
        if let d = ProcessInfo.processInfo.environment["POINKY_PHOTO_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return AppConfig.dir.appendingPathComponent("photos/inbox", isDirectory: true)
    }

    static let imageExtensions = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp"]
    static func isPicture(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) || url.pathExtension.lowercased() == "pdf" }
    static func isPictureType(_ t: NSPasteboard.PasteboardType) -> Bool {
        if t == .pdf || t == .tiff || t == .png { return true }
        guard let u = UTType(t.rawValue) else { return false }
        return u.conforms(to: .image) || u.conforms(to: .pdf)
    }

    @discardableResult
    static func write(_ data: Data, ext: String) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = inbox.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6)).\(ext)")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    /// A copy of a file you gave Poinky, in the inbox (so deleting it later never touches yours).
    static func copyIn(_ url: URL) -> URL? {
        guard isPicture(url), let data = try? Data(contentsOf: url) else { return nil }
        return write(data, ext: url.pathExtension.lowercased())
    }

    /// Pictures on a pasteboard (Continuity Camera's answer, a paste, a drop): files first, then a PDF, then an image.
    static func fromPasteboard(_ pb: NSPasteboard, origin: PhotoOrigin) -> [URL] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let files = urls.filter(isPicture).compactMap(copyIn)
            if !files.isEmpty { return files }
        }
        if let d = pb.data(forType: .pdf), let u = write(d, ext: "pdf") { return [u] }
        for (t, ext) in [("public.jpeg", "jpg"), ("public.heic", "heic"), ("public.png", "png")] {
            if let d = pb.data(forType: NSPasteboard.PasteboardType(t)), let u = write(d, ext: ext) { return [u] }
        }
        if let img = NSImage(pasteboard: pb), let d = StudySource.jpeg(img, maxSide: 4000, quality: 0.9), let u = write(d, ext: "jpg") { return [u] }
        return []
    }

    static func hasPicture(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], urls.contains(where: isPicture) { return true }
        return (pb.types ?? []).contains { isPictureType($0) }
    }

    /// Each page as its own picture: a PDF's pages drawn (at most `maxPages`), images as they are.
    /// Returns the pages and whether they came flat (a PDF: a scan or an export, nothing to straighten).
    static func pages(_ urls: [URL], maxPages: Int = 8) -> [(url: URL, flat: Bool)] {
        var out: [(URL, Bool)] = []
        for u in urls {
            guard out.count < maxPages else { break }
            if u.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: u) {
                for i in 0..<min(doc.pageCount, maxPages - out.count) {
                    guard let p = doc.page(at: i) else { continue }
                    let b = p.bounds(for: .cropBox)
                    let k = 2200 / max(b.width, b.height)
                    let img = p.thumbnail(of: NSSize(width: b.width * k, height: b.height * k), for: .cropBox)
                    if let d = StudySource.jpeg(img, maxSide: 2200, quality: 0.9), let w = write(d, ext: "jpg") { out.append((w, true)) }
                }
                if u.path.hasPrefix(inbox.path) { try? FileManager.default.removeItem(at: u) }
            } else {
                out.append((u, false))
            }
        }
        return out
    }

    /// The picture upright, at most `maxSide` (EXIF orientation applied).
    static func image(_ url: URL, maxSide: CGFloat = 4000) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let o = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, o)
    }

    /// JPEG base64 for Claude (≤1568 px, what it reads at full detail).
    static func forClaude(_ url: URL) -> String? {
        image(url, maxSide: 1568).flatMap { StudySource.jpeg($0, maxSide: 1568, quality: 0.85) }?.base64EncodedString()
    }

    /// A small picture for the card.
    static func thumbnail(_ url: URL, side: CGFloat = 360) -> String? {
        image(url, maxSide: side).flatMap { StudySource.jpeg($0, maxSide: side, quality: 0.75) }.map { "data:image/jpeg;base64," + $0.base64EncodedString() }
    }

    static func remove(_ urls: [URL]) {
        for u in urls where u.path.hasPrefix(inbox.path) { try? FileManager.default.removeItem(at: u) }
    }

    /// Anything left in the inbox from an earlier run (a crash, a quit mid-capture) goes.
    static func sweep(olderThan secs: Double = 3600) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: inbox.path)) ?? [] {
            let u = inbox.appendingPathComponent(name)
            let d = (try? fm.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast
            if Date().timeIntervalSince(d) > secs { try? fm.removeItem(at: u) }
        }
    }

    // MARK: Recent files ("the photo I just AirDropped")

    /// Where AirDrop, a Photos export and an iPad export land (POINKY_RECENT_DIRS for tests, ":"-separated).
    static var recentFolders: [URL] {
        if let s = ProcessInfo.processInfo.environment["POINKY_RECENT_DIRS"] { return s.split(separator: ":").map { URL(fileURLWithPath: String($0)) } }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Downloads", "Desktop"].map { home.appendingPathComponent($0) }
    }

    /// The newest picture or PDF in those folders from the last `within` seconds (screenshots left out: Poinky
    /// sees the screen anyway). Asking macOS for Downloads/Desktop happens only here, when you ask for it.
    static func newestRecent(within: Double = 15 * 60) -> (url: URL, at: Date, folder: String)? {
        let fm = FileManager.default
        var best: (URL, Date, String)?
        for dir in recentFolders {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.addedToDirectoryDateKey, .contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            for u in items where isPicture(u) {
                let name = u.lastPathComponent.lowercased()
                if name.hasPrefix("screenshot") || name.hasPrefix("screen shot") || name.hasPrefix("צילום מסך") { continue }
                let v = try? u.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
                let d = [v?.addedToDirectoryDate, v?.contentModificationDate].compactMap { $0 }.max() ?? .distantPast
                guard Date().timeIntervalSince(d) < within else { continue }
                if best == nil || d > best!.1 { best = (u, d, dir.lastPathComponent) }
            }
        }
        return best
    }
}

// MARK: - What Poinky says and shows (no model)

enum PhotoWords {
    static let noDeviceMenu = "No iPhone or iPad found nearby"
    static func waitingCard(_ he: Bool) -> String { he ? "צלם באייפון. ״סרוק מסמכים״ מיישר את הדף." : "Take it on your iPhone. Scan Documents straightens the page." }
    static func pickLine(_ he: Bool) -> String { he ? "בחר את האייפון שלך, ואז כוון אותו לדף." : "Pick your iPhone in the menu, then point it at the page." }
    static func pointLine(_ he: Bool) -> String { he ? "כוון את האייפון לדף." : "Point your iPhone at the page." }
    static func noDevice(_ he: Bool) -> String {
        he ? "לא מצאתי אייפון בקרבת מקום. הוא צריך להיות לידך, פתוח, עם וויי פיי ובלוטות׳ ועם אותו חשבון אפל. אפשר גם לגרור תמונה לנייר."
           : "I can't find your iPhone. It needs to be nearby and unlocked, with Wi-Fi and Bluetooth on and the same Apple ID. You can also drop a photo on the paper."
    }
    static func noDeviceCard(_ he: Bool) -> String {
        he ? "אין אייפון בקרבת מקום (אותו Apple ID, וויי פיי ובלוטות׳ דלוקים, פתוח). אפשר גם: לגרור תמונה או PDF לכאן, להדביק בתיבת ההקלדה (⌃⌥T ואז ⌘V), או לשלוח באיירדרופ ולהגיד ״התמונה ששלחתי״."
           : "No iPhone or iPad nearby (same Apple ID, Wi-Fi and Bluetooth on, unlocked). Other ways: drop a photo or PDF here, paste one in the type box (⌃⌥T, then ⌘V), or AirDrop it and say \u{201C}use the photo I just sent\u{201D}."
    }
    static func timedOut(_ he: Bool) -> String { he ? "לא הגיעה תמונה. ננסה שוב?" : "No photo came through. Want to try again?" }
    static func gotIt(_ n: Int, he: Bool) -> String {
        he ? (n == 1 ? "קיבלתי את התמונה." : "קיבלתי \(n) עמודים.") : (n == 1 ? "Got your photo." : "Got \(n) pages.")
    }
    static func askAboutIt(_ he: Bool) -> String { he ? "קיבלתי. מה תרצה לדעת עליה?" : "Got it. What would you like to know about it?" }
    static func recentFound(_ folder: String, ago: String, he: Bool) -> String {
        he ? "מצאתי תמונה ב-\(folder), מלפני \(ago). זאת?" : "I found a picture in \(folder) from \(ago) ago. Is this the one?"
    }
    static func noRecent(_ he: Bool) -> String {
        he ? "לא מצאתי תמונה חדשה בהורדות או בשולחן העבודה. אפשר לגרור אותה לנייר."
           : "I don't see a new picture in Downloads or on the Desktop. You can drop it on the paper."
    }
    static func ago(_ d: Date) -> String {
        let s = max(1, Int(Date().timeIntervalSince(d)))
        if s < 60 { return "\(s) seconds" }
        let m = s / 60
        return m == 1 ? "a minute" : "\(m) minutes"
    }
}

/// What was said about pictures, read in code (English and Hebrew). Only clear shapes.
enum PhotoIntent: Equatable {
    case capture         // "I'll take a picture", "let me send you a photo from my phone"
    case recent          // "use the photo I just AirDropped"
    case retake, addPage, cancel

    static func classify(_ s: String) -> PhotoIntent? {
        let n = StudyIntent.norm(s)
        let padded = " " + n + " "
        func has(_ list: [String]) -> Bool {
            list.contains { w in w.unicodeScalars.contains { $0.value >= 0x0590 && $0.value <= 0x05FF } ? n.contains(w) : padded.contains(" " + w + " ") }
        }
        let picture = has(["photo", "picture", "pic", "image", "scan", "snapshot", "תמונה", "צילום", "סריקה", "התמונה"])
        if picture, has(["airdrop", "airdropped", "air dropped", "just sent", "i just sent", "just took", "i just took", "just saved",
                          "in downloads", "in my downloads", "on my desktop", "the one i sent", "איירדרופ", "ששלחתי", "שצילמתי", "בהורדות", "ששמרתי"]) {
            return .recent
        }
        if has(["retake", "take it again", "another photo", "take another", "צלם שוב", "תמונה חדשה", "שוב תמונה"]) { return .retake }
        if has(["another page", "add a page", "one more page", "next page too", "there's a second page", "there's another page", "עוד עמוד", "עמוד נוסף", "יש עוד דף", "עוד דף"]) { return .addPage }
        let taking = has(["i'll take", "ill take", "let me take", "i will take", "i'm taking", "im taking", "take a", "i'll send", "ill send",
                          "let me send", "i'll show you", "let me show you", "i'll snap", "from my phone", "from my iphone", "with my phone",
                          "with my iphone", "on my phone", "using my phone", "my camera", "show you on paper",
                          "אצלם", "אני אצלם", "אשלח", "אני אשלח", "אראה לך", "מהטלפון", "מהאייפון", "בטלפון", "באייפון", "תצלם", "לצלם"])
        if taking && (picture || has(["my phone", "my iphone", "מהטלפון", "מהאייפון", "באייפון", "בטלפון", "אצלם", "לצלם", "תצלם"])) { return .capture }
        return nil
    }
}

// MARK: - Developer check of the real menu

extension ContinuityCamera {
    /// `Poinky --phone-menu-test <out.txt>`: shows the real Continuity Camera menu (no fake) at the screen's center,
    /// closes it after POINKY_PHONE_MENU_CLOSE seconds (default 3) unless something is picked, waits for a picture
    /// (POINKY_PHONE_TIMEOUT) and writes what the menu held and how it ended. Then quits.
    static func devMenuTest(out: String) {
        setenv("POINKY_PHONE_MENU_CLOSE", ProcessInfo.processInfo.environment["POINKY_PHONE_MENU_CLOSE"] ?? "3", 0)
        var lines: [String] = []
        func write() { try? (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        let s = NSScreen.main ?? NSScreen.screens[0]
        let start = Date()
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let extras = [PhotoMenuItem(title: "Choose a Photo or PDF…") {}]
        shared.capture(at: NSPoint(x: s.frame.midX, y: s.frame.midY), extras: extras, waiting: {
            lines.append(String(format: "%.1fs: a device item was picked: waiting for the picture", Date().timeIntervalSince(start)))
            write()
            DispatchQueue.main.asyncAfter(deadline: .now() + PhotoDevices.timeout) { lines.append("timed out"); write(); NSApp.terminate(nil) }
        }, done: { o in
            lines.append("menu: " + shared.lastMenu.joined(separator: " | "))
            lines.append(String(format: "%.1fs: outcome %@", Date().timeIntervalSince(start), "\(o)"))
            if case .files(let f) = o { lines.append("files: " + f.map { "\($0.lastPathComponent) \((try? Data(contentsOf: $0).count) ?? 0) bytes" }.joined(separator: ", ")) }
            write()
            NSApp.terminate(nil)
        })
        lines.append("menu (after it closed): " + shared.lastMenu.joined(separator: " | "))
        write()
    }
}
