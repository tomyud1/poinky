import CoreGraphics

/// Which display things happen on, from the screens' frames alone (AppKit global coordinates: origin at the
/// bottom-left of the main screen, y up; other displays can sit left of or above it, with negative x or y).
/// Pure, so it's tested with made-up layouts (tools/tests/screens): mixed sizes, a display above or to the left,
/// a portrait one. Scale factors don't enter: everything here is in points.
enum ScreenChoice {
    /// The screen a point is on, like NSMouseInRect (x from minX up to maxX, y above minY up to maxY); off every
    /// screen (a moment between displays): the nearest one, not whichever is "main".
    static func index(of p: CGPoint, in frames: [CGRect]) -> Int? {
        if let i = frames.firstIndex(where: { p.x >= $0.minX && p.x < $0.maxX && p.y > $0.minY && p.y <= $0.maxY }) { return i }
        func dist(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
            return dx * dx + dy * dy
        }
        return frames.indices.min { dist(frames[$0]) < dist(frames[$1]) }
    }

    /// A point in the overlay's coordinates on that screen (points, origin at its top-left), or nil if it's elsewhere.
    static func local(_ p: CGPoint, on frame: CGRect) -> CGPoint? {
        guard p.x >= frame.minX, p.x < frame.maxX, p.y > frame.minY, p.y <= frame.maxY else { return nil }
        return CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y)
    }

    /// The overlay's point on a screen in CoreGraphics global coordinates (window lists, events: origin at the
    /// top-left of the main screen, y down). `mainHeight`: the main (first) screen's height.
    static func global(_ local: CGPoint, on frame: CGRect, mainHeight: CGFloat) -> CGPoint {
        CGPoint(x: local.x + frame.minX, y: local.y + (mainHeight - frame.maxY))
    }

    /// Asking with the cursor on another screen than the overlay's: the overlay (buddy, your words, the
    /// screenshot) moves there. What's drawn on the old screen can't come along (one overlay, one screen), so it goes.
    static func shouldMove(overlay: Int?, mouse: Int?) -> Bool {
        guard let m = mouse else { return false }
        return overlay != m
    }
}
