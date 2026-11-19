import AppKit
import ApplicationServices

/// Finding a span of text by its first and last words ("from" / "to"), whitespace and case aside, so
/// `<replace from="This summer I worked" to="able to do.">` can be selected exactly (Foundation only:
/// `tools/tests/text-swap` checks it).
enum TextSpan {
    /// The UTF-16 range in `text` from the start of `from` to the end of `to` (the first `to` that ends after
    /// `from` does), or just `from` when `to` is nil. Runs of spaces and line breaks match any whitespace;
    /// curly quotes match straight ones; case doesn't matter.
    static func find(from: String, to: String?, in text: String) -> NSRange? {
        let (hay, map) = fold(text)
        let a = fold(from).folded.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty, let ra = hay.range(of: a) else { return nil }
        let start = hay.distance(from: hay.startIndex, to: ra.lowerBound)
        var endFolded = hay.distance(from: hay.startIndex, to: ra.upperBound)   // exclusive
        if let to {
            let b = fold(to).folded.trimmingCharacters(in: .whitespaces)
            if !b.isEmpty {
                // The end may overlap the start (a one-sentence span): search from the start.
                guard let rb = hay.range(of: b, range: ra.lowerBound..<hay.endIndex),
                      hay.distance(from: hay.startIndex, to: rb.upperBound) >= endFolded else { return nil }
                endFolded = hay.distance(from: hay.startIndex, to: rb.upperBound)
            }
        }
        let lo = map[start], hi = map[endFolded - 1].upperBound
        return NSRange(location: lo.lowerBound, length: hi - lo.lowerBound)
    }

    /// `text` lowercased with whitespace runs as one space and quotes made straight, plus, for each of its
    /// characters, the UTF-16 range of the original character(s) it came from.
    static func fold(_ text: String) -> (folded: String, map: [Range<Int>]) {
        var out = "", map: [Range<Int>] = []
        var offset = 0, lastSpace = false
        for ch in text {
            let n = ch.utf16.count
            defer { offset += n }
            if ch.isWhitespace {
                if lastSpace, let last = map.last { map[map.count - 1] = last.lowerBound..<(offset + n); continue }
                out.append(" "); map.append(offset..<(offset + n)); lastSpace = true
                continue
            }
            lastSpace = false
            var s = ch.lowercased()
            switch s {
            case "’", "‘", "ʼ": s = "'"
            case "“", "”", "„": s = "\""
            case "–", "—": s = "-"
            default: break
            }
            for c in s { out.append(c); map.append(offset..<(offset + n)) }
        }
        return (out, map)
    }
}

/// Putting new wording into the user's document without the doer: select the span (by accessibility) if
/// it's named, then paste (`Computer.paste`). One ⌘Z undoes it.
@MainActor
enum TextSwap {
    /// The front app's text element: the focused one if it holds text, else the largest text area in its
    /// focused window (a document whose text view isn't focused yet).
    static func textElement() -> AXUIElement? {
        guard let app = AppReader.frontApp() else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        if let f: AXUIElement = attr(ax, kAXFocusedUIElementAttribute), isText(f) { return f }
        guard let win: AXUIElement = attr(ax, kAXFocusedWindowAttribute) else { return nil }
        var best: (AXUIElement, Int)?
        var queue: [AXUIElement] = [win], seen = 0
        while !queue.isEmpty, seen < 1500 {
            let e = queue.removeFirst(); seen += 1
            if isText(e), let v: String = attr(e, kAXValueAttribute), v.count > (best?.1 ?? -1) { best = (e, v.count) }
            if let kids: [AXUIElement] = attr(e, kAXChildrenAttribute) { queue.append(contentsOf: kids) }
        }
        return best?.0
    }

    private static func isText(_ e: AXUIElement) -> Bool {
        let role: String = attr(e, kAXRoleAttribute) ?? ""
        guard ["AXTextArea", "AXTextField", "AXComboBox"].contains(role) else { return false }
        return (attr(e, kAXValueAttribute) as String?) != nil
    }

    private static func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    /// What's selected in the front app's focused text right now ("" when nothing is).
    static func selectedText() -> String {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        guard let f: AXUIElement = attr(system, kAXFocusedUIElementAttribute) else { return "" }
        return attr(f, kAXSelectedTextAttribute) ?? ""
    }

    /// Selects the text from `from` to `to` in the front app's document. Returns the selected text, or why not.
    static func select(from: String, to: String?) -> Result<String, SwapError> {
        guard let el = textElement() else { return .failure(.noText) }
        guard let value: String = attr(el, kAXValueAttribute) else { return .failure(.noText) }
        guard let r = TextSpan.find(from: from, to: to, in: value) else { return .failure(.notFound) }
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        var range = CFRange(location: r.location, length: r.length)
        guard let v = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success else { return .failure(.cantSelect) }
        let want = (value as NSString).substring(with: r)
        let got: String = attr(el, kAXSelectedTextAttribute) ?? ""
        // Some apps don't report the selection back; when they do, it must be the span.
        if !got.isEmpty, TextSpan.fold(got).folded != TextSpan.fold(want).folded { return .failure(.cantSelect) }
        return .success(want)
    }

    enum SwapError: Error, Equatable { case noText, notFound, cantSelect }
}
