import CoreGraphics
import Foundation
// ScreenChoice with made-up display layouts. Built by tools/test-screens.sh.
var fails = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { fails += 1 } }
// A MacBook (main, 1512×982 points at 2×), a 27" display above and to the left (2560×1440 at 1×), and a
// portrait display on the right that sits lower (1080×1920).
let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
let above = CGRect(x: -1200, y: 982, width: 2560, height: 1440)
let right = CGRect(x: 1512, y: -600, width: 1080, height: 1920)
let frames = [main, above, right]
check(ScreenChoice.index(of: CGPoint(x: 700, y: 500), in: frames) == 0, "a point on the MacBook")
check(ScreenChoice.index(of: CGPoint(x: -1000, y: 2000), in: frames) == 1, "on the display above-left (negative x)")
check(ScreenChoice.index(of: CGPoint(x: 2000, y: -500), in: frames) == 2, "on the portrait display (negative y)")
check(ScreenChoice.index(of: CGPoint(x: 1512, y: 100), in: frames) == 2, "the shared edge belongs to the display on the right")
check(ScreenChoice.index(of: CGPoint(x: 700, y: 982), in: frames) == 0, "the top edge of the MacBook is the MacBook")
check(ScreenChoice.index(of: CGPoint(x: 700, y: 982.5), in: frames) == 1, "just above it is the display above")
check(ScreenChoice.index(of: CGPoint(x: 1450, y: 1600), in: frames) == 1, "off every screen: the nearest one (not the main one)")
check(ScreenChoice.index(of: .zero, in: []) == nil, "no screens: none")
// Local (overlay) coordinates: origin top-left of that screen.
check(ScreenChoice.local(CGPoint(x: -1200, y: 2422), on: above) == CGPoint(x: 0, y: 0), "the top-left corner of the display above is (0, 0)")
check(ScreenChoice.local(CGPoint(x: 1512 + 50, y: 1320 - 10), on: right) == CGPoint(x: 50, y: 10), "a point near the portrait display's top")
check(ScreenChoice.local(CGPoint(x: 700, y: 500), on: above) == nil, "a point on another screen isn't local")
// To CoreGraphics global (y down from the main screen's top) and back.
let h = main.height
check(ScreenChoice.global(CGPoint(x: 10, y: 20), on: main, mainHeight: h) == CGPoint(x: 10, y: 20), "the main screen: the same point")
check(ScreenChoice.global(CGPoint(x: 0, y: 0), on: above, mainHeight: h) == CGPoint(x: -1200, y: -1440), "the display above: its top-left is at y = -1440")
check(ScreenChoice.global(CGPoint(x: 0, y: 0), on: right, mainHeight: h) == CGPoint(x: 1512, y: -338), "the portrait one: its top is 338 points above the MacBook's")
for (f, p) in [(main, CGPoint(x: 300, y: 200)), (above, CGPoint(x: -100, y: 1500)), (right, CGPoint(x: 2000, y: 0))] {
    let l = ScreenChoice.local(p, on: f)!, g = ScreenChoice.global(l, on: f, mainHeight: h)
    check(g == CGPoint(x: p.x, y: h - p.y), "AppKit → overlay → CoreGraphics agrees with flipping the point (\(Int(p.x)), \(Int(p.y)))")
}
check(ScreenChoice.shouldMove(overlay: 0, mouse: 1), "asking from another screen moves the overlay there")
check(!ScreenChoice.shouldMove(overlay: 1, mouse: 1) && !ScreenChoice.shouldMove(overlay: 1, mouse: nil), "the same screen (or none known): it stays")
print(fails == 0 ? "all passed" : "\(fails) failed")
exit(fails == 0 ? 0 : 1)
