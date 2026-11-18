import CoreGraphics
import Foundation

// Where the paper goes (Placement.paper): it must never cover what's being explained when there's a
// spot of at least the smallest useful size beside it, and should be full size when one fits.
// Built by tools/test-screen.sh with Placement.swift. Cases from real runs, then many random screens.

var failures = 0, checks = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String) {
    checks += 1
    if !ok { failures += 1; print("  FAIL \(what())") }
}
func px(_ r: CGRect, _ k: CGFloat) -> CGRect { CGRect(x: r.minX / k, y: r.minY / k, width: r.width / k, height: r.height / k) }
func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
func fmt(_ r: CGRect) -> String { String(format: "%.0f,%.0f %.0fx%.0f", r.minX, r.minY, r.width, r.height) }

// MARK: - Real runs (screenshot pixels as the models wrote them; 1333x863 shots of a 1710x1107 screen)

let k: CGFloat = 1333.0 / 1710.0
struct Real { let name: String; let subjects: [CGRect]; let text: [CGRect]; let cursor: CGPoint }
// A page's text lines (px): the lecture slide, the homework sheet, the chart page (from the runs' OCR).
let lecture = [CGRect(x: 75, y: 92, width: 360, height: 26), CGRect(x: 230, y: 135, width: 260, height: 32),
               CGRect(x: 90, y: 175, width: 420, height: 18), CGRect(x: 90, y: 197, width: 400, height: 18),
               CGRect(x: 90, y: 218, width: 135, height: 18), CGRect(x: 320, y: 255, width: 20, height: 14),
               CGRect(x: 360, y: 280, width: 60, height: 14)]
// The homework sheet: a centered column (Georgia, 820 px wide in CSS) with four questions and the student's work.
let homework = [CGRect(x: 294, y: 45, width: 525, height: 34), CGRect(x: 862, y: 44, width: 204, height: 16)]
    + [(130, 334), (164, 190), (201, 178), (286, 496), (320, 266), (358, 178), (396, 186), (466, 520), (500, 300), (599, 525), (640, 120)]
        .map { CGRect(x: 312, y: CGFloat($0.0), width: CGFloat($0.1), height: 26) }
let chart = [CGRect(x: 60, y: 60, width: 420, height: 30), CGRect(x: 60, y: 110, width: 860, height: 50)]
let reals = [
    // "why is it 6 newtons and not 14": the talker underlined the net-force line and named the diagram
    // ("around 570,540"); the teacher circled it (536,538 r150). The paper covered the diagram.
    Real(name: "lecture: why 6 and not 14", subjects: [
        CGRect(x: 140, y: 308, width: 600, height: 28),
        Placement.region(inBrief: "Relates to the free-body diagram on screen, around 570,540.")!,
        CGRect(x: 536 - 180, y: 538 - 150, width: 360, height: 300)], text: lecture, cursor: CGPoint(x: 1017, y: 376)),
    // "is my answer right for number one": a bracket on question 1. The paper covered questions 2–4.
    Real(name: "homework: number one", subjects: [CGRect(x: 226, y: 142, width: 600, height: 110)], text: homework, cursor: CGPoint(x: 675, y: 395)),
    // "can you show it as a line instead": the whole chart. The paper went on the chart.
    Real(name: "chart: as a line", subjects: [Placement.region(inBrief: "Relates to the bar chart on screen, roughly 110,200 to 800,530, and the existing lesson paper.")!],
         text: chart, cursor: CGPoint(x: 812, y: 537)),
]
let screen = CGSize(width: 1710, height: 1107)
print("Real runs (1710x1107):")
for r in reals {
    let subjects = r.subjects.map { px($0, k) }
    let c = CGPoint(x: r.cursor.x / k, y: r.cursor.y / k)
    let room = Placement.Room(subjects: subjects, soft: [CGRect(x: c.x - 140, y: c.y - 70, width: 280, height: 140)], text: r.text.map { px($0, k) })
    let f = Placement.paper(screen: screen, room: room)
    let covered = subjects.reduce(0) { $0 + area($1.intersection(f)) }
    let textCovered = r.text.map { px($0, k) }.reduce(0) { $0 + area($1.intersection(CGRect(x: f.minX, y: f.minY, width: f.width, height: min(f.height, 560)))) }
    print(String(format: "  %@: paper %@, covers %.0f pt² of the subject, %.0f pt² of text", r.name, fmt(f), covered, textCovered))
    check(covered == 0, "\(r.name): the paper covers the subject")
    check(f.width >= Placement.minPaperWidth, "\(r.name): a full-size paper fits beside it, got \(fmt(f))")
}

// MARK: - Random screens

struct RNG { var s: UInt64; mutating func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((s >> 33) % 1_000_000) / 1_000_000 } }
var rng = RNG(s: 42)
let screens: [(String, CGSize)] = [("13\" laptop", CGSize(width: 1440, height: 900)), ("14\"", CGSize(width: 1512, height: 982)),
                                    ("16\"", CGSize(width: 1728, height: 1117)), ("1080p", CGSize(width: 1920, height: 1080)),
                                    ("27\"", CGSize(width: 2560, height: 1440)), ("small", CGSize(width: 1280, height: 800))]
/// Is there a spot of `w`×`h` in the usable area that keeps the same distance from every subject as the app does?
func spotExists(_ size: CGSize, _ subjects: [CGRect], w: CGFloat, h: CGFloat) -> Bool {
    let usable = CGRect(x: 0, y: Placement.topInset, width: size.width, height: size.height - Placement.topInset - Placement.bottomInset)
        .insetBy(dx: Placement.margin, dy: Placement.margin)
    let blocks = subjects.map { $0.insetBy(dx: -Placement.margin, dy: -Placement.margin) }   // a little more room than the app needs
    var y = usable.minY
    while y + h <= usable.maxY {
        var x = usable.minX
        while x + w <= usable.maxX {
            let r = CGRect(x: x, y: y, width: w, height: h)
            if !blocks.contains(where: { $0.intersects(r) }) { return true }
            x += 8
        }
        y += 8
    }
    return false
}
var times: [Double] = []
var counts = (spots: 0, full: 0, none: 0)
for (name, size) in screens {
    var bad = 0
    for i in 0..<150 {
        // 1–3 subjects (a word, a paragraph, a chart, a diagram), sometimes in a narrow window in the middle.
        let narrow = i % 3 == 0
        let win = narrow ? CGRect(x: size.width * (0.3 + 0.1 * rng.next()), y: 80, width: 560, height: size.height - 140)
                         : CGRect(x: 0, y: 40, width: size.width, height: size.height - 40)
        var subjects: [CGRect] = []
        for _ in 0..<(1 + Int(rng.next() * 3)) {
            let w = 40 + rng.next() * min(win.width, 760), h = 16 + rng.next() * 380
            subjects.append(CGRect(x: win.minX + rng.next() * max(1, win.width - w), y: win.minY + rng.next() * max(1, win.height - h), width: w, height: h))
        }
        // Text: lines of the window's column.
        var text: [CGRect] = []
        var ty = win.minY + 20
        while ty < win.maxY - 30 { if rng.next() > 0.2 { text.append(CGRect(x: win.minX + 30, y: ty, width: (win.width - 60) * (0.5 + 0.5 * rng.next()), height: 18)) }; ty += 30 }
        let cursor = CGPoint(x: subjects[0].midX, y: subjects[0].midY)
        let room = Placement.Room(subjects: subjects, soft: [CGRect(x: cursor.x - 140, y: cursor.y - 70, width: 280, height: 140)], text: text)
        let t0 = Date()
        let f = Placement.paper(screen: size, room: room)
        times.append(Date().timeIntervalSince(t0) * 1000)
        let what = "\(name) #\(i): subjects \(subjects.map(fmt)) → paper \(fmt(f))"
        let before = failures
        check(f.minY >= Placement.topInset && f.maxY <= size.height && f.minX >= 0 && f.maxX <= size.width, "\(what): off the screen or under the menu bar")
        check(f.width >= Placement.smallestPaperWidth && f.height >= Placement.smallestPaperHeight, "\(what): smaller than the smallest paper")
        if spotExists(size, subjects, w: Placement.smallestPaperWidth, h: Placement.smallestPaperHeight) {
            counts.spots += 1
            check(!subjects.contains(where: { $0.intersects(f) }), "\(what): covers a subject although a spot beside it exists")
            if spotExists(size, subjects, w: Placement.minPaperWidth, h: Placement.minPaperHeight) {
                counts.full += 1
                check(f.width >= Placement.minPaperWidth && f.height >= Placement.minPaperHeight, "\(what): a full-size spot exists, got a small paper")
            }
        } else {
            counts.none += 1
        }
        if failures > before { bad += 1 }
        if bad > 5 { break }
    }
}
let sorted = times.sorted()
print("Random screens: \(times.count) (\(counts.spots) with room beside the subject, \(counts.full) with room for a full paper, \(counts.none) with none)")
print(String(format: "Time per placement: median %.1f ms, worst %.1f ms", sorted[sorted.count / 2], sorted.last ?? 0))
print(failures == 0 ? "All \(checks) placement checks passed." : "\(failures) of \(checks) placement checks failed.")
exit(failures == 0 ? 0 : 1)
