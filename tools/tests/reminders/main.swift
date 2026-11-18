import Foundation
var fails = 0
func check(_ name: String, _ ok: Bool, _ info: String = "") { print((ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  " + info)); if !ok { fails += 1 } }
func cal(_ z: String) -> Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: z)!; return c }
func d(_ s: String, _ z: String) -> Date {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: z); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: s)!
}
func show(_ x: Date?, _ z: String) -> String {
    guard let x else { return "nil" }
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: z); f.dateFormat = "yyyy-MM-dd HH:mm EEE"; return f.string(from: x)
}
let NY = "America/New_York", JR = "Asia/Jerusalem", LON = "Europe/London", KOL = "Asia/Kolkata"
struct Case { let name: String; let every: Reminder.Repeat; let at: String; let setZone: String; let now: String; let nowZone: String; let want: String }
let cases: [Case] = [
    // daily across DST: keeps 9:00 wall time
    .init(name: "daily over spring forward (NY)", every: .daily, at: "2026-03-07 09:00", setZone: NY, now: "2026-03-08 10:00", nowZone: NY, want: "2026-03-09 09:00 Mon"),
    .init(name: "daily over fall back (NY)", every: .daily, at: "2026-10-31 09:00", setZone: NY, now: "2026-11-01 09:30", nowZone: NY, want: "2026-11-02 09:00 Mon"),
    .init(name: "daily in the skipped hour (NY 02:30)", every: .daily, at: "2026-03-07 02:30", setZone: NY, now: "2026-03-07 03:00", nowZone: NY, want: "2026-03-08 03:00 Sun"),
    .init(name: "weekly over DST (Jerusalem)", every: .weekly, at: "2026-10-19 08:00", setZone: JR, now: "2026-10-26 08:01", nowZone: JR, want: "2026-11-02 08:00 Mon"),
    .init(name: "weekdays Friday → Monday", every: .weekdays, at: "2026-11-13 08:00", setZone: JR, now: "2026-11-13 08:00", nowZone: JR, want: "2026-11-16 08:00 Mon"),
    .init(name: "weekdays after a weekend off", every: .weekdays, at: "2026-11-13 08:00", setZone: JR, now: "2026-11-15 12:00", nowZone: JR, want: "2026-11-16 08:00 Mon"),
    // hourly: 60 minutes apart, after 100 days off too (the old loop stopped after 2000 steps, ~83 days)
    .init(name: "hourly after 100 days off", every: .hourly, at: "2026-01-01 10:15", setZone: JR, now: "2026-04-11 13:20", nowZone: JR, want: "2026-04-11 14:15 Sat"),
    .init(name: "daily after a year off", every: .daily, at: "2025-11-01 07:30", setZone: LON, now: "2026-11-18 12:00", nowZone: LON, want: "2026-11-19 07:30 Thu"),
    // time zone changes: the time of day stays where it was set
    .init(name: "daily set in Jerusalem, now in London", every: .daily, at: "2026-11-10 09:00", setZone: JR, now: "2026-11-12 10:00", nowZone: LON, want: "2026-11-13 09:00 Fri"),
    .init(name: "weekly set in NY, now in Kolkata", every: .weekly, at: "2026-11-02 18:00", setZone: NY, now: "2026-11-12 10:00", nowZone: KOL, want: "2026-11-16 18:00 Mon"),
    // not started yet: its own first time
    .init(name: "weekdays starting next Monday", every: .weekdays, at: "2026-11-23 08:00", setZone: JR, now: "2026-11-19 12:00", nowZone: JR, want: "2026-11-23 08:00 Mon"),
]
for c in cases {
    var r = Reminder(text: "x", at: d(c.at, c.setZone), every: c.every)
    r.zone = c.setZone
    let n = r.next(after: d(c.now, c.nowZone), calendar: cal(c.nowZone))
    check(c.name, show(n, c.nowZone) == c.want, "got \(show(n, c.nowZone)), want \(c.want)")
}
// hourly over fall back: 1:15 EDT, then 1:15 EST (an hour later), then 2:15
do {
    var r = Reminder(text: "x", at: d("2026-11-01 00:15", NY), every: .hourly); r.zone = NY
    var t = d("2026-11-01 00:15", NY); var seen: [TimeInterval] = []
    for _ in 0..<4 { let n = r.next(after: t, calendar: cal(NY))!; seen.append(n.timeIntervalSince(t)); t = n }
    check("hourly over fall back is every 60 minutes", seen == [3600, 3600, 3600, 3600], "\(seen)")
}
// takeDue: a Mac asleep across several occurrences says it once; then it isn't due again
setenv("POINKY_REMINDERS_FILE", NSTemporaryDirectory() + "rem-test-\(getpid()).json", 1)
func fresh(_ list: [Reminder]) { Reminders.save(list) }
do {
    var r = Reminder(text: "Stretch", at: Date().addingTimeInterval(-100 * 86400), every: .hourly); r.zone = TimeZone.current.identifier
    fresh([r])
    let now = Date()
    let first = Reminders.takeDue(now: now)
    let again = Reminders.takeDue(now: now.addingTimeInterval(20))
    let next = Reminders.all().first?.at
    check("asleep 100 days (hourly): once", first.count == 1 && again.isEmpty, "first \(first.count), again \(again.count)")
    check("…and its next time is within the hour", next.map { $0 > now && $0.timeIntervalSince(now) <= 3600 } ?? false, "\(String(describing: next))")
}
do {
    let r = Reminder(text: "Water", at: Date().addingTimeInterval(-5 * 86400 - 60), every: .daily)
    fresh([r])
    let now = Date()
    check("asleep 5 days (daily): once", Reminders.takeDue(now: now).count == 1 && Reminders.takeDue(now: now.addingTimeInterval(60)).isEmpty)
}
do {
    // Clock set back 3 days after it came due: it comes back to its next time after the new now, not 4 days on.
    let now = Date()
    let r = Reminder(text: "Pills", at: now.addingTimeInterval(-60), every: .daily)
    fresh([r])
    _ = Reminders.takeDue(now: now)
    let back = now.addingTimeInterval(-3 * 86400)
    check("clock back 3 days: nothing due right away", Reminders.takeDue(now: back).isEmpty)
    let at = Reminders.all().first!.at
    check("clock back 3 days: next within a day", at > back && at.timeIntervalSince(back) <= 86400 + 3600, "\(at.timeIntervalSince(back) / 3600) h")
    // Back 30 minutes: it doesn't fire the same one twice.
    let r2 = Reminder(text: "Call", at: now.addingTimeInterval(-60), every: .daily)
    fresh([r2]); _ = Reminders.takeDue(now: now)
    check("clock back 30 min: not again", Reminders.takeDue(now: now.addingTimeInterval(-1800)).isEmpty && Reminders.all().first!.at.timeIntervalSince(now) > 86000)
}
do {
    // An older file (no zone, no lastDue) still loads.
    let json = #"[{"id":"a","text":"Old","at":"2026-11-01T07:00:00Z","every":"daily"}]"#
    try! json.data(using: .utf8)!.write(to: Reminders.url)
    check("an older reminders.json loads", Reminders.all().count == 1 && Reminders.all()[0].zone == nil)
}
try? FileManager.default.removeItem(at: Reminders.url)
print(fails == 0 ? "all passed" : "\(fails) failed")
exit(fails == 0 ? 0 : 1)
