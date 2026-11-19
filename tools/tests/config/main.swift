import Foundation

// Settings → Claude: Quick / Careful (`AppConfig.paces`), and config files from older versions.
// Built with Sources/Poinky/Config.swift by tools/test-talker.sh (a stand-in for PhononVoice below).

enum PhononVoice {
    static let defaultVoice = "Easton"
    static let speedRange = 0.86...1.24
    static func voiceName(_ s: String) -> String? { s.isEmpty ? nil : s }
}

var failed = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { failed += 1 } }
func decode(_ json: String) -> AppConfig? { try? JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)) }
func row(_ c: AppConfig, _ r: PromptRole) -> String { "\(c.model(for: r)) / \(c.effort(for: r).isEmpty ? "auto" : c.effort(for: r))" }

// 1. A new config is Quick, and Quick is exactly today's defaults.
let fresh = AppConfig()
check(fresh.pace == .quick, "a new config is Quick")
var q = fresh; q.use(.quick)
check(AppConfig.paces.allSatisfy { q[role: $0.role] == fresh[role: $0.role] }, "Quick sets exactly the defaults")

// 2. The table, as each part sees it (model / effort), for both brains.
let expected: [(PromptRole, String, String, String, String)] = [
    //            Quick, Claude Code             Careful, Claude Code              Quick, API                      Careful, API
    (.talker, "haiku / auto",  "claude-sonnet-5-5 / auto",   "claude-haiku-5-5 / auto",  "claude-sonnet-5-5 / auto"),
    (.artist, "sonnet / auto", "claude-sonnet-5-5 / medium", "claude-sonnet-5-5 / auto", "claude-sonnet-5-5 / medium"),
    (.guide,  "haiku / auto",  "claude-sonnet-5-5 / auto",   "claude-haiku-5-5 / auto",  "claude-sonnet-5-5 / auto"),
    (.doer,   "sonnet / auto", "claude-opus-5-5 / auto",     "claude-sonnet-5-5 / auto", "claude-opus-5-5 / auto"),
]
for (brain, label) in [(BrainKind.claudeCode, "Claude Code"), (.api, "API")] {
    for pace in AppConfig.Pace.allCases {
        var c = AppConfig(); c.brain = brain; c.agentModel = "claude-opus-5-5"; c.use(pace)
        check(c.pace == pace, "\(label): \(pace) reads back as \(pace)")
        check(c.agentModel == "claude-opus-5-5", "\(label): \(pace) leaves the helpers' model alone")
        for e in expected {
            let want = brain == .claudeCode ? (pace == .quick ? e.1 : e.2) : (pace == .quick ? e.3 : e.4)
            check(row(c, e.0) == want, "\(label), \(pace), \(e.0.rawValue): \(row(c, e.0))\(row(c, e.0) == want ? "" : " (want \(want))")")
        }
    }
}

// 3. Study sessions pick the teacher's model and its effort, or medium when it's automatic
//    (StudySession.swift): Careful must give them the same.
for pace in AppConfig.Pace.allCases {
    var c = AppConfig(); c.use(pace)
    let effort = c.effort(for: .artist).isEmpty ? "medium" : c.effort(for: .artist)
    check(effort == "medium" && c.model(for: .artist).contains("sonnet"), "study sessions under \(pace): \(c.model(for: .artist)), \(effort)")
}

// 4. An older config with its own models per part (and away mode's ntfy keys, which are gone): read without
//    failing, every value kept, shown as custom; unknown keys are dropped when it's saved again.
let old = """
{"brain":"claudeCode","claudeCodeModel":"claude-haiku-5-5","artistModel":"claude-opus-5-5","artistEffort":"high",
 "doerModel":"sonnet","guideModel":"","talkerEffort":"","guideEffort":"","doerEffort":"low","agentModel":"claude-fable-5-1",
 "agentEffort":"max","apiModel":"claude-haiku-5-5","awayNotify":true,"ntfyServer":"https://ntfy.sh","ntfyTopic":"poinky-abc",
 "awayMinutes":10,"awayDetails":false,"kokoroSpeed":1.1,"voice":"Samantha","someFutureKey":[1,2]}
"""
if let c = decode(old) {
    check(true, "an older config with away mode's keys loads")
    check(c.pace == nil, "its own models show as custom")
    check(row(c, .talker) == "claude-haiku-5-5 / auto" && row(c, .artist) == "claude-opus-5-5 / high"
          && row(c, .doer) == "sonnet / low" && row(c, .guide) == "claude-haiku-5-5 / auto", "every part keeps its model and effort")
    check(c.agentModel == "claude-fable-5-1" && c.agentEffort == "max", "helpers keep theirs")
    check(c.voice == "Samantha" && abs(c.voiceSpeed - 1.1) < 1e-9, "other settings are kept (old kokoroSpeed too)")
    let saved = String(data: try! JSONEncoder().encode(c), encoding: .utf8)!
    check(!saved.contains("ntfy") && !saved.contains("away") && !saved.contains("someFutureKey"), "saved again, the unknown keys are gone")
    check(decode(saved).map { row($0, .artist) == "claude-opus-5-5 / high" && $0.pace == nil } == true, "and it reads back the same")
    var back = c; back.use(.careful)
    check(back.pace == .careful && back.agentModel == "claude-fable-5-1", "Careful takes a custom config back, helpers untouched")
} else { check(false, "an older config with away mode's keys loads") }

// 5. An older config that only had the defaults written out is Quick; a near miss is custom.
check(decode(#"{"claudeCodeModel":"haiku","artistModel":"sonnet","doerModel":"sonnet","guideModel":"","awayNotify":false}"#)?.pace == .quick, "an old file with the defaults is Quick")
check(decode(#"{"claudeCodeModel":"claude-haiku-5-5"}"#)?.pace == nil, "a full model name where Quick has the short one is custom")
check(decode(#"{"artistEffort":"medium"}"#)?.pace == nil, "one changed effort is custom")
// Only the connected brain counts: an API model changed while using Claude Code doesn't make it custom.
check(decode(#"{"brain":"claudeCode","apiModel":"claude-opus-5-5"}"#)?.pace == .quick, "the other brain's models don't count")
check(decode(#"{"brain":"api","apiModel":"claude-opus-5-5"}"#)?.pace == nil, "the connected brain's do")
check(decode("{}") != nil && decode(#"{"brain":"nonsense"}"#)?.brain == .claudeCode, "an empty or odd file still loads")

print(failed == 0 ? "PASS" : "FAILED \(failed)")
exit(failed == 0 ? 0 : 1)
