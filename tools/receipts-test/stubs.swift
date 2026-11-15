import Foundation
enum AppConfig { static let dir = URL(fileURLWithPath: "/nonexistent") }
enum Identity {
    static let identityURL = URL(fileURLWithPath: "/a"), userURL = URL(fileURLWithPath: "/b")
    static let identityBudget = 1500, userBudget = 2000
    static func content(_ u: URL, budget: Int) -> String { u.path == "/a" ? String(repeating: "x", count: 1200) : "" }
}
enum Memory { static func facts() -> [String] { ["- likes tea", "- studies biology"] } }
enum DailyNotes { static func text(for d: Date) -> String { "- worked on the lab report" } }
