import AppKit

/// Keeps drawings attached to the window they're about: they hide when that window is
/// minimized, covered, or on another desktop, and move along when you drag it.
enum WindowTracker {
    struct Window { let id: CGWindowID; let bounds: CGRect }   // bounds: global, origin top-left of the main display

    /// Front-to-back list of normal, visible windows (not ours).
    private static func windows() -> [(id: CGWindowID, bounds: CGRect)] {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? pid_t) != me,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.1,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict), b.width > 40, b.height > 40 else { return nil }
            return (id, b)
        }
    }

    /// The topmost window under a global point.
    static func window(at p: CGPoint) -> Window? {
        windows().first { $0.bounds.contains(p) }.map { Window(id: $0.id, bounds: $0.bounds) }
    }

    /// Where the window is now, or nil if it's minimized, on another desktop, closed,
    /// or mostly covered by another window.
    static func visibleBounds(of id: CGWindowID) -> CGRect? {
        let list = windows()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return nil }
        let b = list[i].bounds
        let area = b.width * b.height
        for above in list[..<i] {
            let x = above.bounds.intersection(b)
            if !x.isNull, x.width * x.height > 0.6 * area { return nil }
        }
        return b
    }

    /// Converts between a screen's local points (origin top-left of that screen) and global window coordinates.
    static func toGlobal(_ p: CGPoint, screen: NSScreen) -> CGPoint {
        let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        return CGPoint(x: p.x + screen.frame.minX, y: p.y + (mainHeight - screen.frame.maxY))
    }
}
