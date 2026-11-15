import Foundation

/// Keeps a picture of a paper lesson (the paper's Save button), so students can revise from it later.
/// It goes to the Desktop; if that can't be written, to Pictures/Poinky.
enum LessonSaver {
    /// Writes the picture (PNG data URL, or SVG text when the page couldn't make a PNG). Returns where it went.
    static func save(title: String, pngDataURL: String?, svg: String?, now: Date = Date()) -> URL? {
        let data: Data, ext: String
        if let png = pngDataURL, let comma = png.firstIndex(of: ","),
           let d = Data(base64Encoded: String(png[png.index(after: comma)...])) {
            data = d; ext = "png"
        } else if let svg, let d = svg.data(using: .utf8) {
            data = d; ext = "svg"
        } else { return nil }
        let name = fileName(title: title, now: now, ext: ext)
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment["POINKY_LESSON_DIR"].map { URL(fileURLWithPath: $0) }
        let home = fm.homeDirectoryForCurrentUser
        let places = [env, home.appendingPathComponent("Desktop"), home.appendingPathComponent("Pictures/Poinky")].compactMap { $0 }
        for dir in places {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var url = dir.appendingPathComponent(name)
            var n = 2
            while fm.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent(name.replacingOccurrences(of: ".\(ext)", with: " \(n).\(ext)")); n += 1
            }
            if (try? data.write(to: url)) != nil { return url }
        }
        return nil
    }

    /// "Poinky – the chain rule – Nov 15.png": the title made safe for a file name.
    static func fileName(title: String, now: Date, ext: String) -> String {
        var t = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.whitespacesAndNewlines))
            .filter { !$0.isEmpty }.joined(separator: " ")
        if t.count > 60 { t = String(t.prefix(60)).trimmingCharacters(in: .whitespaces) }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let date = f.string(from: now)
        return t.isEmpty ? "Poinky lesson – \(date).\(ext)" : "Poinky – \(t) – \(date).\(ext)"
    }

    /// Where it went, in plain words for the button ("Desktop", "Pictures").
    static func placeName(_ url: URL) -> String {
        let dir = url.deletingLastPathComponent()
        return dir.lastPathComponent == "Poinky" ? "Pictures" : dir.lastPathComponent
    }
}
