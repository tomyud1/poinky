import AppKit

/// What one question sent to Claude, exactly: so "what does Poinky see?" has a plain answer.
/// The hover panel shows the last one in a line ("Screenshot + Preview: Lecture 5.pdf + your selection");
/// clicking it opens `ReceiptsWindow`. Only on this Mac: `receipts/receipts.json` (0600) plus a small
/// thumbnail per receipt, the last `keep`; nothing at all with the `receipts` setting off.
struct Receipt: Codable, Identifiable, Equatable {
    struct Part: Codable, Equatable {
        var name: String
        var chars: Int
    }

    var id: String
    var at: Date
    var question = ""             // what you said (empty: a background update nobody asked for)
    var role = "talker"           // talker · guide · doer
    var brain = ""                // "Claude Code" / "Anthropic API"
    var model = ""
    var screenshot = true
    var size = ""                 // "1568x980"
    var closeUp = false           // plus a sharp close-up of what you marked
    var app = ""
    var window = ""
    var document = ""             // ~/path
    var page = ""
    var selectionChars = 0
    var front: [String] = []      // the exact front-app lines that went out
    var parts: [Part] = []        // the files read into Claude's instructions this session (names and sizes)
    var lookups: [String] = []    // "Web search “…”" (sent to Claude's web search) · "Looked through …" (on this Mac)
    var also: [String] = []       // "The teacher (model) got the same screenshot to sketch an answer"
    var steps = 0                 // guide / doer: more screenshots in the same walkthrough
    var message = ""              // the whole text message, as sent

    /// "Screenshot + Preview: Lecture 5.pdf + your selection"
    var summary: String {
        var s = [screenshot ? (closeUp ? "Screenshot + close-up" : "Screenshot") : "Text only"]
        if !app.isEmpty {
            if !document.isEmpty { s.append("\(app): \((document as NSString).lastPathComponent)") }
            else if let host = URL(string: page)?.host, !host.isEmpty { s.append("\(app): \(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)") }
            else if !window.isEmpty { s.append("\(app): \(Self.clip(window, 40))") }
            else { s.append(app) }
        }
        if selectionChars > 0 { s.append("your selection") }
        if lookups.contains(where: { $0.hasPrefix("Web search") }) { s.append("a web search") }
        if steps > 0 { s.append("\(steps) more step\(steps == 1 ? "" : "s")") }
        return s.joined(separator: " + ")
    }

    /// For the notch's one line, where "What I saw" already says it's a screenshot: "Preview: Lecture 5.pdf + selection".
    var short: String {
        var s = summary.replacingOccurrences(of: "your selection", with: "selection")
        for p in ["Screenshot + close-up + ", "Screenshot + ", "Screenshot"] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)); break }
        return s.isEmpty ? "Screenshot" : s
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(n - 1)) + "…" : s }
}

@MainActor
enum Receipts {
    static let keep = 20
    static var enabled = true                       // the `receipts` setting
    /// What the talker's instructions read at the start of this session (set by `BrainFactory.make`).
    static var sessionParts: [Receipt.Part] = []
    /// Tells the notch a receipt was added or the list was cleared.
    static var onChange: () -> Void = {}

    static var dir: URL {
        if let d = ProcessInfo.processInfo.environment["POINKY_RECEIPTS_DIR"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return AppConfig.dir.appendingPathComponent("receipts", isDirectory: true)
    }
    static var listURL: URL { dir.appendingPathComponent("receipts.json") }
    static func thumbURL(_ id: String) -> URL { dir.appendingPathComponent(id + ".jpg") }

    private static var cache: [Receipt]?

    /// Newest last.
    static func all() -> [Receipt] {
        if let c = cache { return c }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let list = (try? Data(contentsOf: listURL)).flatMap { try? dec.decode([Receipt].self, from: $0) } ?? []
        cache = list
        return list
    }

    static var latest: Receipt? { all().last }

    /// Adds a receipt (and its thumbnail, made in the background from the screenshot that went out).
    @discardableResult
    static func add(_ r: Receipt, jpegBase64: String?) -> String? {
        guard enabled else { return nil }
        var list = all()
        list.removeAll { $0.id == r.id }
        list.append(r)
        var gone: [Receipt] = []
        if list.count > keep { gone = Array(list.prefix(list.count - keep)); list.removeFirst(list.count - keep) }
        save(list)
        for g in gone { try? FileManager.default.removeItem(at: thumbURL(g.id)) }
        if let b64 = jpegBase64 { writeThumb(b64, id: r.id) }
        onChange()
        return r.id
    }

    /// Changes one receipt (a lookup ran, the teacher got the screenshot too, another guide step).
    static func update(_ id: String?, jpegBase64: String? = nil, _ change: (inout Receipt) -> Void) {
        guard enabled, let id else { return }
        var list = all()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        save(list)
        if let b64 = jpegBase64 { writeThumb(b64, id: id) }
        onChange()
    }

    /// Made off the main thread; if the receipt was dropped or cleared meanwhile, the file goes too.
    private static func writeThumb(_ b64: String, id: String) {
        let url = thumbURL(id)
        DispatchQueue.global(qos: .utility).async {
            guard let data = Data(base64Encoded: b64), let jpg = thumbnail(data, width: 640) else { return }
            write(jpg, to: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !all().contains(where: { $0.id == id }) { try? FileManager.default.removeItem(at: url) }
                    onChange()
                }
            }
        }
    }

    /// The Clear button, and turning the setting off: every receipt and thumbnail goes.
    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        cache = []
        onChange()
    }

    static func newID(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date)
    }

    /// The files that go into Claude's instructions, by name and size (not their text). (The session notes
    /// go with the talker's first question of a session instead; they're listed here all the same.)
    static func parts(memoryEnabled: Bool, now: Date = Date()) -> [Receipt.Part] {
        var p: [Receipt.Part] = []
        let me = Identity.content(Identity.identityURL, budget: Identity.identityBudget)
        if !me.isEmpty { p.append(.init(name: "Poinky's personality (identity.md)", chars: me.count)) }
        let you = Identity.content(Identity.userURL, budget: Identity.userBudget)
        if !you.isEmpty { p.append(.init(name: "About me (user.md)", chars: you.count)) }
        if memoryEnabled {
            let facts = Memory.facts()
            let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
            if !first.isEmpty { p.append(.init(name: "Your Mac account's name", chars: NSFullUserName().count)) }
            if !facts.isEmpty { p.append(.init(name: "What I remember (\(facts.count) fact\(facts.count == 1 ? "" : "s"))", chars: facts.joined(separator: "\n").count)) }
            let today = DailyNotes.text(for: now), yesterday = DailyNotes.text(for: now.addingTimeInterval(-86400))
            if !yesterday.isEmpty { p.append(.init(name: "Yesterday's session notes", chars: yesterday.count)) }
            if !today.isEmpty { p.append(.init(name: "Today's session notes", chars: today.count)) }
        }
        return p
    }

    // MARK: Files

    private static func save(_ list: [Receipt]) {
        cache = list
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(list) else { return }
        write(data, to: listURL)
    }

    nonisolated private static func write(_ data: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    nonisolated static func thumbnail(_ jpeg: Data, width: CGFloat) -> Data? {
        guard let src = NSBitmapImageRep(data: jpeg), let cg = src.cgImage else { return nil }
        let k = min(1, width / CGFloat(cg.width))
        let w = Int(CGFloat(cg.width) * k), h = Int(CGFloat(cg.height) * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
