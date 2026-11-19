import AppKit

/// Pictures of something on paper, one path, two destinations (PhonePhoto.swift has the devices and files):
///
///   from your iPhone (the paper's "📷 My work", the notch's camera, ⌃⌥P, "I'll take a picture"), a drop on the
///   paper / the notch / the type box, a paste in the type box, "use the photo I just AirDropped", an iPad's PDF
///   → a small card shows what came (Retake, + Page, Check now; a few seconds' countdown)
///   → a study session checks it as your work on the current part (`StudySession.checkWork(files:)`), or else it
///     goes with your next question to the talker and the teacher (`photoClaim`), e.g. "what's wrong with this circuit?"
///
/// The pictures stay in Poinky's support folder (0600) until used: a study session keeps them (original and cleaned)
/// in its sheet's folder; a question sends them and they're deleted. Receipts say "a photo from your phone".
@MainActor
final class PhotoInbox {
    static let shared = PhotoInbox()
    enum Phase: String { case idle, menu, waiting, review, confirm, ready }

    var phase: Phase = .idle { didSet { if phase != oldValue { Timeline.log("photo.phase", ["phase": phase.rawValue]) } } }
    lazy var device: PhotoDevice = PhotoDevices.make()
    var pages: [(url: URL, flat: Bool)] = []
    var origin: PhotoOrigin = .phone
    var he = false
    var heldQuestion: String?        // asked together with "I'll take a picture of it": asked once the picture is here
    var byVoice = false              // the capture was asked for out loud (say what's happening, not only show it)
    var timeout: DispatchWorkItem?
    var countdown: DispatchWorkItem?
    var anchor: NSPoint?
    /// Pictures waiting for the next question (no study session): JPEG base64, and how to describe them.
    var forQuestion: (images: [String], note: String, receipt: String, call: Int, at: Date)?
    /// What a question took (its turn): the teacher gets the same pictures.
    var claimed: (turn: Int, images: [String], note: String)?
    var hotKey: HotKey?
    var cardGen = 0

    var files: [URL] { pages.map(\.url) }
    /// The menu is open or a picture is on its way (tests wait for it before the next step).
    var capturing: Bool { phase == .menu || phase == .waiting }
    func discard() {
        PhotoFiles.remove(files)
        pages = []
        heldQuestion = nil
        countdown?.cancel(); countdown = nil
        timeout?.cancel(); timeout = nil
    }
}

extension CallController {
    private var inbox: PhotoInbox { PhotoInbox.shared }
    static var photoCountdown: Double { ProcessInfo.processInfo.environment["POINKY_PHOTO_COUNTDOWN"].flatMap(Double.init) ?? 4 }

    // MARK: Hooks

    /// Once at launch (from setupHome): the buttons, the drop targets, ⌃⌥P.
    func photoSetUp() {
        ContinuityCamera.register()
        PhotoFiles.sweep()
        overlay.onWorkPhoto = { [weak self] msg in self?.photoCardAction(msg) }
        photoHome.model.onPhoto = { [weak self] in
            self?.photoHome.collapse()
            self?.photoCapture(at: NSEvent.mouseLocation, said: nil)
        }
        photoHome.model.onPhotoFiles = { [weak self] urls in self?.photoReceived(urls.compactMap(PhotoFiles.copyIn), origin: .drop) }
        photoTypeBox.onPhotos = { [weak self] urls, origin in self?.photoReceived(urls, origin: origin) }
        ContinuityCamera.shared.onLate = { [weak self] urls in self?.photoReceived(urls, origin: .phone) }
        inbox.hotKey = HotKey(spec: photoHotkeySpec) { [weak self] in self?.photoCapture(at: NSEvent.mouseLocation, said: nil) }
    }

    func photoSessionEnded() {
        inbox.device.cancel()
        inbox.discard()
        inbox.forQuestion = nil
        inbox.claimed = nil
        inbox.phase = .idle
        photoHideCard()
    }

    /// What you said, before the study session and the talker see it. True when it was about the pictures.
    func photoHeard(_ text: String) -> Bool {
        // A photo already handed to the study session is being checked: not ours.
        if !StudySession.shared.pendingPhotos.isEmpty { return false }
        // Pictures are waiting for this question (asked by you, or by `photoAsk`): `ask` takes them.
        if inbox.phase == .ready, inbox.forQuestion != nil { return false }
        let intent = PhotoIntent.classify(text)
        let n = StudyIntent.norm(text)
        let cancelWords = ["never mind", "nevermind", "cancel", "forget it", "no photo", "לא משנה", "בטל", "עזוב"]
        switch inbox.phase {
        case .confirm:
            switch OfferReply.classify(text) {
            case .yes: photoUse(said: ""); return true
            case .no:
                inbox.discard(); inbox.phase = .idle
                photoHideCard()
                photoSay(inbox.he ? "בסדר." : "Okay.")
                return true
            default: break
            }
        case .review:
            if intent == .retake { photoRetake(); return true }
            if intent == .addPage { photoCapture(at: inbox.anchor ?? NSEvent.mouseLocation, said: text, append: true); return true }
            if cancelWords.contains(where: { n.contains($0) }) { photoCancel(); return true }
            if case .yes = OfferReply.classify(text) { photoUse(said: ""); return true }
            // Anything else: the pictures go now, with what you said (a note to the teacher, or the question).
            photoUse(said: text)
            return true
        case .menu, .waiting:
            if cancelWords.contains(where: { n.contains($0) }) { photoCancel(); return true }
            if intent != nil { return true }   // already on it
            if StudySession.shared.isActive(call: photoCall) { return false }   // a hint, a question… while the photo comes
            // A question asked meanwhile is asked with the picture, once it's here.
            inbox.heldQuestion = text
            photoSay(inbox.he ? "אשאל את זה כשהתמונה תגיע." : "I'll answer that once the photo's here.")
            return true
        case .idle, .ready: break
        }
        switch intent {
        case .capture?:
            inbox.he = Self.language(of: text) == "he"
            let question = Self.photoQuestionPart(text)
            photoCapture(at: NSEvent.mouseLocation, said: text, held: question)
            return true
        case .recent?:
            photoRecent(said: text)
            return true
        default:
            return false
        }
    }

    /// "Check my work" in a study session when the sheet itself is what's on screen: the work is on paper, so the
    /// phone is asked for it (instead of checking the screenshot).
    func photoInsteadOfScreen(_ text: String) -> Bool {
        guard let sheet = StudySession.shared.sheet, inbox.phase == .idle else { return false }
        let f = photoFront
        if let d = f.document, StudySource.isImage(d) { return false }    // a picture of it is open: that's the work
        let front = StudyStore.id(document: f.document, page: f.page, window: f.window)
        guard front == sheet.id || ProcessInfo.processInfo.environment["POINKY_PHOTO_SHEET_IN_FRONT"] == "1" else { return false }
        inbox.he = sheet.userLanguage == "he"
        photoCapture(at: NSEvent.mouseLocation, said: text)
        return true
    }

    /// For a question: the pictures waiting for it (none: nil). The teacher gets the same ones (`photoImages`).
    func photoClaim(turn: Int) -> (images: [String], note: String, receipt: String)? {
        guard let q = inbox.forQuestion, q.call == photoCall, Date().timeIntervalSince(q.at) < 15 * 60 else {
            if inbox.forQuestion != nil { inbox.forQuestion = nil }
            return nil
        }
        inbox.forQuestion = nil
        inbox.claimed = (turn, q.images, q.note)
        if inbox.phase == .ready { inbox.phase = .idle }
        photoCard(state: "sent", text: inbox.he ? "✓ נשלח עם השאלה" : "✓ Sent with your question", buttons: [])
        Timeline.log("photo.claimed", ["turn": turn, "images": q.images.count])
        return (q.images, q.note, q.receipt)
    }

    /// The teacher's job for `turn`: the same pictures, and a line saying what they are.
    func photoImages(turn: Int) -> (images: [String], note: String) {
        guard let c = inbox.claimed, c.turn == turn else { return ([], "") }
        return (c.images, "\n" + c.note.replacingOccurrences(of: "the image after the screenshot", with: "the last image")
                                     .replacingOccurrences(of: "the images after the screenshot", with: "the last images"))
    }

    // MARK: Capturing

    /// Shows the device menu (your iPhone's Take Photo / Scan Documents, plus a file or the newest download).
    func photoCapture(at point: NSPoint, said: String?, append: Bool = false, held: String? = nil) {
        let i = inbox
        if i.phase == .menu || i.phase == .waiting { return }
        if !append { i.discard() }
        if let held { i.heldQuestion = held }
        i.byVoice = said != nil
        if let said, !said.isEmpty { i.he = Self.language(of: said) == "he" } else if let s = StudySession.shared.sheet, StudySession.shared.isActive(call: photoCall) { i.he = s.userLanguage == "he" }
        i.anchor = point
        i.countdown?.cancel()
        photoStartSession()   // the card lives on the overlay
        i.phase = .menu
        photoCard(state: "waiting", text: PhotoWords.pickLine(i.he), buttons: [])
        if i.byVoice { photoSay(PhotoWords.pickLine(i.he)) }
        let extras = photoMenuExtras()
        Timeline.log("photo.capture", ["append": append, "voice": i.byVoice])
        // (After the card and the line are on their way: the menu takes the main thread while it's open.)
        DispatchQueue.main.async { [weak self] in
            guard let self, i.phase == .menu else { return }
            i.device.capture(at: point, extras: extras, waiting: { [weak self] in self?.photoWaiting() },
                             done: { [weak self] outcome in self?.photoCaptured(outcome) })
        }
    }

    private func photoMenuExtras() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let file = PhotoMenuItem(title: inbox.he ? "בחר תמונה או PDF…" : "Choose a Photo or PDF…") { [weak self] in self?.photoChooseFile() }
        items.append(file)
        let recent = PhotoMenuItem(title: inbox.he ? "התמונה האחרונה מההורדות או משולחן העבודה" : "Newest Picture in Downloads or Desktop") { [weak self] in
            self?.photoRecent(said: "")
        }
        items.append(recent)
        if PhotoFiles.hasPicture(.general) {
            items.append(PhotoMenuItem(title: inbox.he ? "הדבק תמונה" : "Paste Picture") { [weak self] in
                self?.photoReceived(PhotoFiles.fromPasteboard(.general, origin: .paste), origin: .paste)
            })
        }
        return items
    }

    private func photoWaiting() {
        let i = inbox
        i.phase = .waiting
        photoCard(state: "waiting", text: PhotoWords.waitingCard(i.he), buttons: [("cancel", i.he ? "ביטול" : "Cancel", false)])
        if i.byVoice { photoSay(PhotoWords.pointLine(i.he)) }
        i.timeout?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, i.phase == .waiting else { return }
            i.device.cancel()
            self.photoCaptured(.timedOut)
        }
        i.timeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + PhotoDevices.timeout, execute: w)
    }

    private func photoCaptured(_ outcome: CaptureOutcome) {
        let i = inbox
        i.timeout?.cancel(); i.timeout = nil
        Timeline.log("photo.outcome", ["outcome": { switch outcome { case .files(let f): return "files:\(f.count)"; case .noDevice: return "noDevice"
            case .cancelled: return "cancelled"; case .timedOut: return "timedOut"; case .failed(let m): return "failed:\(m)" } }()])
        switch outcome {
        case .files(let urls):
            photoReceived(urls, origin: .phone)
        case .noDevice where !i.pages.isEmpty, .timedOut where !i.pages.isEmpty, .failed where !i.pages.isEmpty:
            // Another page didn't come: back to the pages there are.
            i.phase = .review
            photoShowReview()
            if i.byVoice { photoSay(outcome == .noDevice ? PhotoWords.noDevice(i.he) : PhotoWords.timedOut(i.he)) }
        case .noDevice:
            i.phase = .idle
            photoCard(state: "error", text: PhotoWords.noDeviceCard(i.he),
                      buttons: [("retry", i.he ? "נסה שוב" : "Try again", false), ("file", i.he ? "בחר קובץ…" : "Choose a file…", true)],
                      title: i.he ? "לא נמצא אייפון" : "No iPhone nearby")
            if i.byVoice { photoSay(PhotoWords.noDevice(i.he)) }
        case .cancelled:
            // One of the menu's own items (a file, the newest download, paste) carries on by itself.
            if i.phase == .menu {
                i.phase = i.pages.isEmpty ? .idle : .review
                if i.pages.isEmpty { photoHideCard() } else { photoShowReview() }
            }
        case .timedOut, .failed:
            i.phase = .idle
            photoCard(state: "error", text: PhotoWords.timedOut(i.he),
                      buttons: [("retry", i.he ? "נסה שוב" : "Try again", true), ("file", i.he ? "בחר קובץ…" : "Choose a file…", false)])
            if i.byVoice { photoSay(PhotoWords.timedOut(i.he)) }
        }
    }

    /// Pictures arrived (any way in). They're added to what's there (pages of one piece of work, in order).
    func photoReceived(_ urls: [URL], origin: PhotoOrigin) {
        let i = inbox
        guard !urls.isEmpty else { return }
        photoStartSession()
        i.origin = origin
        if i.phase != .review && i.phase != .menu && i.phase != .waiting { i.discard() }
        i.pages += PhotoFiles.pages(urls, maxPages: max(1, 8 - i.pages.count))
        i.phase = .review
        Timeline.log("photo.received", ["origin": origin.rawValue, "pages": i.pages.count])
        photoShowReview()
    }

    private func photoShowReview() {
        let i = inbox
        let study = StudySession.shared.isActive(call: photoCall)
        let he = i.he
        var buttons: [(String, String, Bool)] = []
        if i.origin == .phone { buttons.append(("retake", he ? "צלם שוב" : "Retake", false)) }
        buttons.append(("add", he ? "+ עמוד" : "+ Page", false))
        buttons.append(("use", study ? (he ? "בדוק עכשיו" : "Check now") : (he ? "השתמש" : "Use"), true))
        let n = i.pages.count
        let text = study ? (he ? "בודק \(n == 1 ? "את זה" : "את \(n) העמודים") בעוד רגע. עוד עמוד? ״+ עמוד״." : "I'll check \(n == 1 ? "this" : "these \(n) pages") in a moment. More pages? + Page.")
                         : i.heldQuestion != nil ? (he ? "שולח עם השאלה שלך…" : "Sending it with your question…")
                         : (he ? "מה תרצה לדעת עליה? תשאל, והיא תצטרף לשאלה." : "Ask me about it: it goes with your next question.")
        let auto = study || i.heldQuestion != nil
        photoCard(state: "got", text: text, buttons: buttons, countdown: auto ? Self.photoCountdown : 0)
        if !auto {
            // No study session and nothing asked yet: it waits for your question.
            photoUse(said: "")
            return
        }
        photoArmCountdown(Self.photoCountdown)
    }

    private func photoArmCountdown(_ secs: Double) {
        let i = inbox
        i.countdown?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, i.phase == .review else { return }
            self.photoUse(said: "")
        }
        i.countdown = w
        DispatchQueue.main.asyncAfter(deadline: .now() + secs, execute: w)
    }

    /// The pictures go where they belong: the study session's check, or the next question.
    func photoUse(said: String) {
        let i = inbox
        i.countdown?.cancel(); i.countdown = nil
        let pages = i.pages
        guard !pages.isEmpty else { i.phase = .idle; return }
        if StudySession.shared.isActive(call: photoCall) {
            i.pages = []
            i.phase = .idle
            photoCard(state: "sent", text: i.he ? "✓ בודק" : "✓ Checking", buttons: [])
            Timeline.log("photo.use", ["to": "study", "pages": pages.count])
            StudySession.shared.driver = self
            StudySession.shared.checkWork(files: pages.map(\.url), note: said.isEmpty ? Self.photoNote(i.origin) : "\(Self.photoNote(i.origin)); they said: \"\(said)\"",
                                          flat: pages.allSatisfy(\.flat))
            return
        }
        // A question: the pictures as Claude reads them, then the files go.
        let images = pages.compactMap { PhotoFiles.forClaude($0.url) }
        let thumbs = pages.compactMap { PhotoFiles.thumbnail($0.url) }
        let held = i.heldQuestion
        i.discard()
        let n = images.count
        let what = Self.photoWhat(i.origin, n)
        let note = "(The user \(what) with this question: \(n == 1 ? "the image after the screenshot" : "the \(n) images after the screenshot, pages in order"). Their question is about \(n == 1 ? "it" : "them"), not the screen, unless they say otherwise.)"
        let receipt = Self.photoReceipt(i.origin, n)
        i.forQuestion = (images, note, receipt, photoCall, Date())
        Timeline.log("photo.use", ["to": "question", "pages": n])
        let q = said.isEmpty ? held : said
        if let q, !q.isEmpty {
            i.phase = .ready
            photoAsk(q)
        } else {
            i.phase = .ready
            photoCard(state: "ready", text: i.he ? "מה תרצה לדעת עליה? החזק ⌃⌥ ושאל." : "Ask me about it: hold ⌃⌥ and ask, or type it (⌃⌥T).",
                      buttons: [], countdown: 0, thumbs: thumbs)
            if i.byVoice { photoSay(PhotoWords.askAboutIt(i.he)) }
        }
    }

    func photoRetake() {
        let i = inbox
        i.discard()
        photoCapture(at: i.anchor ?? NSEvent.mouseLocation, said: nil)
    }

    func photoCancel() {
        let i = inbox
        i.device.cancel()
        i.discard()
        i.forQuestion = nil
        i.phase = .idle
        photoHideCard()
        Timeline.log("photo.cancel")
    }

    /// "Use the photo I just AirDropped": the newest picture in Downloads or on the Desktop, shown to confirm.
    func photoRecent(said: String) {
        let i = inbox
        if !said.isEmpty { i.he = Self.language(of: said) == "he" }
        photoStartSession()
        guard let r = PhotoFiles.newestRecent(), let copy = PhotoFiles.copyIn(r.url) else {
            i.phase = .idle
            photoCard(state: "error", text: PhotoWords.noRecent(i.he), buttons: [("file", i.he ? "בחר קובץ…" : "Choose a file…", true)], title: i.he ? "לא נמצאה תמונה" : "No new picture")
            photoSay(PhotoWords.noRecent(i.he))
            return
        }
        i.discard()
        i.origin = .recent
        i.pages = PhotoFiles.pages([copy])
        i.phase = .confirm
        let line = PhotoWords.recentFound(r.folder, ago: PhotoWords.ago(r.at), he: i.he)
        photoCard(state: "confirm", text: r.url.lastPathComponent, buttons: [("no", i.he ? "לא זאת" : "Not this", false), ("yes", i.he ? "כן, זאת" : "Use it", true)],
                  title: i.he ? "זאת התמונה?" : "Is this the one?")
        photoSay(line)
        Timeline.log("photo.recent", ["folder": r.folder])
    }

    func photoChooseFile() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.image, .pdf]
        p.message = inbox.he ? "בחר תמונה או PDF של העבודה שלך" : "Choose a photo or PDF of your work"
        NSApp.activate()
        p.level = .floating
        guard p.runModal() == .OK else { if inbox.phase == .menu { inbox.phase = .idle }; return }
        photoReceived(p.urls.compactMap(PhotoFiles.copyIn), origin: .file)
    }

    // MARK: The card

    func photoCardAction(_ msg: [String: Any]) {
        let action = msg["action"] as? String ?? ""
        let i = inbox
        let point: NSPoint? = {
            guard let x = (msg["x"] as? NSNumber)?.doubleValue, let y = (msg["y"] as? NSNumber)?.doubleValue, let s = overlay.screen else { return nil }
            return NSPoint(x: s.frame.minX + x, y: s.frame.maxY - y)
        }()
        Timeline.log("photo.click", ["action": action])
        switch action {
        case "capture": photoCapture(at: point ?? NSEvent.mouseLocation, said: nil)
        case "retake": photoRetake()
        case "add": photoCapture(at: point ?? i.anchor ?? NSEvent.mouseLocation, said: nil, append: true)
        case "use", "yes": photoUse(said: "")
        case "cancel", "no": photoCancel()
        case "retry": photoCapture(at: point ?? i.anchor ?? NSEvent.mouseLocation, said: nil)
        case "file": photoChooseFile()
        case "hold":
            // The mouse rests on the card: look as long as you like ("Check now" sends it).
            i.countdown?.cancel(); i.countdown = nil
        case "drop":
            let files = (msg["files"] as? [[String: Any]] ?? []).compactMap { f -> URL? in
                guard let s = f["data"] as? String, let comma = s.firstIndex(of: ","), let data = Data(base64Encoded: String(s[s.index(after: comma)...])) else { return nil }
                let name = (f["name"] as? String ?? "").lowercased()
                let ext = name.hasSuffix(".pdf") || (f["type"] as? String) == "application/pdf" ? "pdf"
                    : (URL(fileURLWithPath: name).pathExtension.isEmpty ? "jpg" : URL(fileURLWithPath: name).pathExtension)
                return PhotoFiles.write(data, ext: ext)
            }
            photoReceived(files, origin: .drop)
        default: break
        }
    }

    private func photoCard(state: String, text: String, buttons: [(String, String, Bool)], countdown: Double = 0,
                           title: String? = nil, thumbs: [String]? = nil) {
        let i = inbox
        let he = i.he
        let pics = thumbs ?? (state == "got" || state == "confirm" ? i.pages : []).compactMap { PhotoFiles.thumbnail($0.url) }
        let t = title ?? {
            switch (state, i.origin) {
            case ("waiting", _): return he ? "מהאייפון שלך" : "From your iPhone"
            case (_, .phone): return he ? "מהאייפון שלך" : "From your iPhone"
            case (_, .recent): return he ? "מההורדות" : "Your latest picture"
            case (_, .paste): return he ? "הודבק" : "Pasted"
            default: return he ? "התמונה שלך" : "Your picture"
            }
        }()
        let o: [String: Any] = ["state": state, "title": t, "text": text, "thumbs": pics, "countdown": countdown,
                                "icon": i.origin == .phone || state == "waiting" ? "📱" : "🖼",
                                "buttons": buttons.map { ["id": $0.0, "label": $0.1, "primary": $0.2] }]
        guard let data = try? JSONSerialization.data(withJSONObject: o), let json = String(data: data, encoding: .utf8) else { return }
        i.cardGen += 1
        photoShowCard(json, gen: i.cardGen)
    }

    /// The overlay is there once the session is up: until then the card waits (a newer card replaces it).
    private func photoShowCard(_ json: String, gen: Int, tries: Int = 0) {
        guard gen == inbox.cardGen else { return }
        if !photoOverlayReady, tries < 60 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.photoShowCard(json, gen: gen, tries: tries + 1) }
            return
        }
        overlay.evaluateForTest("SB.workPhoto && SB.workPhoto(\(json))")
    }

    private func photoHideCard() {
        inbox.cardGen += 1
        overlay.evaluateForTest("SB.workPhoto && SB.workPhoto(null)")
    }

    // MARK: Words

    static func photoWhat(_ o: PhotoOrigin, _ n: Int) -> String {
        let pics = n == 1 ? "a photo" : "\(n) photos"
        switch o {
        case .phone: return "took \(pics) with their iPhone"
        case .recent: return "pointed to \(pics) they just saved or AirDropped"
        case .paste: return "pasted \(n == 1 ? "a picture" : "\(n) pictures")"
        case .drop, .file: return "gave \(n == 1 ? "a picture" : "\(n) pictures") (a file)"
        }
    }
    static func photoNote(_ o: PhotoOrigin) -> String {
        switch o {
        case .phone: return "a photo from their iPhone"
        case .recent: return "a photo they AirDropped or saved"
        default: return "a picture they gave as a file"
        }
    }
    static func photoReceipt(_ o: PhotoOrigin, _ n: Int) -> String {
        let pics = n == 1 ? "A photo" : "\(n) photos"
        switch o {
        case .phone: return "\(pics) from your phone went with it (sent, then deleted from this Mac)"
        case .recent: return "\(pics) from Downloads/Desktop went with it (your file stays where it is)"
        default: return "\(n == 1 ? "A picture" : "\(n) pictures") you gave went with it"
        }
    }

    /// The question in "I'll take a picture of the circuit, what's wrong with it?" (nil: nothing asked yet).
    static func photoQuestionPart(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = StudyIntent.norm(t).split(separator: " ").count
        let asks = t.contains("?") || ["what", "why", "how", "is it", "is this", "can you", "check", "explain", "מה", "למה", "איך", "תבדוק", "תסביר"]
            .contains { StudyIntent.norm(t).contains($0) }
        return asks && words >= 6 ? t : nil
    }
}

/// A menu item that runs a closure (the photo menu's own lines).
final class PhotoMenuItem: NSMenuItem {
    private let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { DispatchQueue.main.async { [run] in run() } }
}
