import Foundation

enum BrainKind: String, Codable, Hashable {
    case claudeCode   // runs the `claude` CLI in the background, uses your Claude subscription
    case api          // calls the Anthropic API directly, needs an API key
}

/// Settings live in ~/Library/Application Support/Poinky/config.json
struct AppConfig: Codable {
    var brain: BrainKind = .claudeCode
    var claudeCodeModel = "haiku"
    var claudePath = ""            // leave empty to auto-detect
    var apiModel = "claude-haiku-5-5"
    var apiKey = ""                // only used by the "api" brain
    var artistEnabled = true       // a second, stronger model draws rich diagrams and 3D in parallel
    var artistModel = "sonnet"     // artist model for the Claude Code brain
    var apiArtistModel = "claude-sonnet-5-5"
    var doerModel = "sonnet"       // clicks and types for you (needs a model that's good at using apps)
    var apiDoerModel = "claude-sonnet-5-5"
    var guideModel = ""            // walks you through a task ("" = same as the talker)
    var apiGuideModel = ""
    // How hard each one thinks: "" (automatic: Poinky's fast default) or low, medium, high, xhigh, max.
    var talkerEffort = ""
    var artistEffort = ""
    var guideEffort = ""
    var doerEffort = ""
    var agentEffort = ""               // helpers ("" = your Claude Code default)
    var language = "en-US"         // speech recognition + voice language, e.g. "he-IL"
    /// Other languages you speak to Poinky (recognized alongside `language`; the question goes in the one heard
    /// best). Default: macOS's preferred languages that Apple's engine can hear (SpeechLanguages.defaults).
    var otherLanguages: [String]? = nil
    var speechEngine = "auto"      // who writes your words: "auto" (a local model if installed, else Apple), "apple", "parakeet"
    var voice = ""                 // voice name or identifier; empty = best installed voice
    var speechRate: Float = 0.53   // 0.0 – 1.0 (Apple voices)
    var voiceEngine = "phonon"     // "phonon" (free local neural voice) or "apple"
    var phononVoice = PhononVoice.defaultVoice   // e.g. Easton, Miles, Harper, Hugh, Maeve (PhononVoice.voices)
    var voiceSpeed = 1.0           // natural voice speed, 0.86 – 1.24
    var silenceSeconds = 1.0       // seconds of real silence that end your question
    var hotkey = "ctrl+option+space"   // starts / ends a hands-free call
    var pushToTalk = "ctrl+option"     // hold to talk, let go to send ("off" to turn it off)
    var buddy = true                   // the little companion at your cursor (captions appear next to it)
    var sounds = true                  // soft interface sounds
    var quiet = false                  // quiet mode: answers are written, nothing is played (voice, sounds, videos)
    var quietHotkey = "ctrl+option+q"  // turns quiet mode on / off
    var soundVolume = 0.7              // their loudness, 0–1 (Poinky's voice has its own)
    var menuBarIcon = false            // also show ✨ in the menu bar (always shown on screens without a notch)
    var homeShown = false              // the first-run "I live here" moment was shown (FirstRun.swift)
    var buddyHotkey = "ctrl+option+b"  // hides / shows the buddy
    var typeHotkey = "ctrl+option+t"   // opens a box to type to Poinky (or to the helper under the mouse)
    var helpersHotkey = "ctrl+option+h" // opens the Helpers window (on the helper under the mouse)
    var photoHotkey = "ctrl+option+p"   // a photo of your work from your iPhone (Continuity Camera; CallController+Photo.swift)
    var buddyAutoHide = 0.0            // hide the buddy after this many idle seconds (0 = never); it's back when you ask something
    var memoryEnabled = true           // remember things about you between sessions (stored only on this Mac)
    var conversationLog = true         // keep what you and Poinky said (conversations/*.jsonl, only on this Mac) so it can look it up later
    var webSearch = true               // the main buddy may do a quick web search itself (Claude Code brain only)
    var checkForUpdates = true         // look for a new Poinky on GitHub now and then (never installs by itself)
    var frontAppContext = true         // send the front app's selected text, open document and web address with each question
    var receipts = true                // keep a receipt of what each question sent (last 20, receipts/, only on this Mac)
    var computerControl = true         // Poinky may click and type for you when you ask it to do something
    var webPhotos = true               // pin a photo of the real thing (from Wikipedia) next to 3D models and lessons
    var paperLook = "auto"             // lesson paper: "auto" (a chalkboard when the screen behind it is dark), "paper", "chalkboard"
    var minTextSize = 12.0             // smallest text on a lesson paper, in points on screen (long text wraps instead of shrinking under it)
    var agentPermission = "auto"        // background agents: "auto" (Claude Code's auto mode; falls back to acceptEdits if it can't start), "acceptEdits" (edit the project + run tests, ask for the rest), "plan"
    var agentModel = ""                // background agents' model ("" = your Claude Code default)
    var maxHelpers = 3                 // helpers (background agents) working at once, 1–6; more wait in line
    var helperNotify = true            // a Mac notification when a helper needs you and no session runs (or its question went unanswered)
    var helperNotifyDone = false       // also when a helper finishes while you're away from the Mac (screen locked or idle)
    /// Apps left out of every screenshot (password managers by default).
    var excludedApps = ["com.apple.Passwords", "com.apple.keychainaccess", "com.1password.1password", "com.agilebits.onepassword7",
                        "com.bitwarden.desktop", "com.lastpass.LastPass"]

    init() {}

    /// Settings from older versions, read once and then written under their new names.
    private enum LegacyKeys: String, CodingKey { case kokoroSpeed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        brain = (try? c.decodeIfPresent(BrainKind.self, forKey: .brain)) ?? d.brain
        claudeCodeModel = try c.decodeIfPresent(String.self, forKey: .claudeCodeModel) ?? d.claudeCodeModel
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? d.claudePath
        apiModel = try c.decodeIfPresent(String.self, forKey: .apiModel) ?? d.apiModel
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? d.apiKey
        artistEnabled = try c.decodeIfPresent(Bool.self, forKey: .artistEnabled) ?? d.artistEnabled
        artistModel = try c.decodeIfPresent(String.self, forKey: .artistModel) ?? d.artistModel
        apiArtistModel = try c.decodeIfPresent(String.self, forKey: .apiArtistModel) ?? d.apiArtistModel
        doerModel = try c.decodeIfPresent(String.self, forKey: .doerModel) ?? d.doerModel
        apiDoerModel = try c.decodeIfPresent(String.self, forKey: .apiDoerModel) ?? d.apiDoerModel
        guideModel = try c.decodeIfPresent(String.self, forKey: .guideModel) ?? d.guideModel
        apiGuideModel = try c.decodeIfPresent(String.self, forKey: .apiGuideModel) ?? d.apiGuideModel
        talkerEffort = try c.decodeIfPresent(String.self, forKey: .talkerEffort) ?? d.talkerEffort
        artistEffort = try c.decodeIfPresent(String.self, forKey: .artistEffort) ?? d.artistEffort
        guideEffort = try c.decodeIfPresent(String.self, forKey: .guideEffort) ?? d.guideEffort
        doerEffort = try c.decodeIfPresent(String.self, forKey: .doerEffort) ?? d.doerEffort
        agentEffort = try c.decodeIfPresent(String.self, forKey: .agentEffort) ?? d.agentEffort
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        otherLanguages = try c.decodeIfPresent([String].self, forKey: .otherLanguages)
        speechEngine = try c.decodeIfPresent(String.self, forKey: .speechEngine) ?? d.speechEngine
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? d.voice
        speechRate = try c.decodeIfPresent(Float.self, forKey: .speechRate) ?? d.speechRate
        voiceEngine = try c.decodeIfPresent(String.self, forKey: .voiceEngine) ?? d.voiceEngine
        if voiceEngine == "kokoro" { voiceEngine = "phonon" }   // Phonon replaced Kokoro
        phononVoice = (try c.decodeIfPresent(String.self, forKey: .phononVoice)).flatMap(PhononVoice.voiceName) ?? d.phononVoice
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let speed = try c.decodeIfPresent(Double.self, forKey: .voiceSpeed)
            ?? legacy.decodeIfPresent(Double.self, forKey: .kokoroSpeed) ?? d.voiceSpeed
        voiceSpeed = min(PhononVoice.speedRange.upperBound, max(PhononVoice.speedRange.lowerBound, speed))
        silenceSeconds = try c.decodeIfPresent(Double.self, forKey: .silenceSeconds) ?? d.silenceSeconds
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        pushToTalk = try c.decodeIfPresent(String.self, forKey: .pushToTalk) ?? d.pushToTalk
        buddy = try c.decodeIfPresent(Bool.self, forKey: .buddy) ?? d.buddy
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        quiet = try c.decodeIfPresent(Bool.self, forKey: .quiet) ?? d.quiet
        quietHotkey = try c.decodeIfPresent(String.self, forKey: .quietHotkey) ?? d.quietHotkey
        soundVolume = try c.decodeIfPresent(Double.self, forKey: .soundVolume) ?? d.soundVolume
        menuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .menuBarIcon) ?? d.menuBarIcon
        homeShown = try c.decodeIfPresent(Bool.self, forKey: .homeShown) ?? true   // missing: someone who used Poinky before it existed
        buddyHotkey = try c.decodeIfPresent(String.self, forKey: .buddyHotkey) ?? d.buddyHotkey
        typeHotkey = try c.decodeIfPresent(String.self, forKey: .typeHotkey) ?? d.typeHotkey
        helpersHotkey = try c.decodeIfPresent(String.self, forKey: .helpersHotkey) ?? d.helpersHotkey
        photoHotkey = try c.decodeIfPresent(String.self, forKey: .photoHotkey) ?? d.photoHotkey
        buddyAutoHide = try c.decodeIfPresent(Double.self, forKey: .buddyAutoHide) ?? d.buddyAutoHide
        memoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? d.memoryEnabled
        conversationLog = try c.decodeIfPresent(Bool.self, forKey: .conversationLog) ?? d.conversationLog
        webSearch = try c.decodeIfPresent(Bool.self, forKey: .webSearch) ?? d.webSearch
        frontAppContext = try c.decodeIfPresent(Bool.self, forKey: .frontAppContext) ?? d.frontAppContext
        receipts = try c.decodeIfPresent(Bool.self, forKey: .receipts) ?? d.receipts
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? d.checkForUpdates
        computerControl = try c.decodeIfPresent(Bool.self, forKey: .computerControl) ?? d.computerControl
        webPhotos = try c.decodeIfPresent(Bool.self, forKey: .webPhotos) ?? d.webPhotos
        paperLook = try c.decodeIfPresent(String.self, forKey: .paperLook) ?? d.paperLook
        minTextSize = AppConfig.textSize(try c.decodeIfPresent(Double.self, forKey: .minTextSize) ?? d.minTextSize)
        agentPermission = try c.decodeIfPresent(String.self, forKey: .agentPermission) ?? d.agentPermission
        agentModel = try c.decodeIfPresent(String.self, forKey: .agentModel) ?? d.agentModel
        maxHelpers = try c.decodeIfPresent(Int.self, forKey: .maxHelpers) ?? d.maxHelpers
        helperNotify = try c.decodeIfPresent(Bool.self, forKey: .helperNotify) ?? d.helperNotify
        helperNotifyDone = try c.decodeIfPresent(Bool.self, forKey: .helperNotifyDone) ?? d.helperNotifyDone
        excludedApps = try c.decodeIfPresent([String].self, forKey: .excludedApps) ?? d.excludedApps
    }

    /// A test copy (run with `POINKY_SUPPORT_DIR`) doesn't listen to the real keyboard, so it never answers
    /// when the person at the Mac holds the talk keys for their own Poinky. `POINKY_REAL_KEYS=1` turns that off
    /// (a test of the real keys); scripted keys (`PushToTalk.fakeFlags`) always work.
    /// The sizes "Smallest text in sketches" may have.
    static let textSizeRange: ClosedRange<Double> = 9...24
    static func textSize(_ v: Double) -> Double { min(textSizeRange.upperBound, max(textSizeRange.lowerBound, v.rounded())) }

    static let ignoresRealKeys: Bool = {
        let env = ProcessInfo.processInfo.environment
        return !(env["POINKY_SUPPORT_DIR"] ?? "").isEmpty && env["POINKY_REAL_KEYS"] != "1"
    }()

    static let dir: URL = {
        let fm = FileManager.default
        // Tests and pictures (`--settings-shot`, `--welcome-shot`): a scratch folder instead of the real settings.
        if let d = ProcessInfo.processInfo.environment["POINKY_SUPPORT_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let new = base.appendingPathComponent("Poinky", isDirectory: true)
        // Poinky used to be called ScreenBuddy: bring its settings, memory and voice along, once.
        let old = base.appendingPathComponent("ScreenBuddy", isDirectory: true)
        if !fm.fileExists(atPath: new.path),
           (try? fm.attributesOfItem(atPath: old.path)[.type] as? FileAttributeType) == .typeDirectory,
           (try? fm.moveItem(at: old, to: new)) != nil {
            try? fm.createSymbolicLink(at: old, withDestinationURL: new)   // anything still using the old path keeps working
            let memory = new.appendingPathComponent("memory.md")
            if let text = try? String(contentsOf: memory, encoding: .utf8) {
                try? text.replacingOccurrences(of: "What ScreenBuddy remembers", with: "What Poinky remembers")
                    .write(to: memory, atomically: true, encoding: .utf8)
            }
        }
        return new
    }()
    static var fileURL: URL { dir.appendingPathComponent("config.json") }

    static func load() -> AppConfig {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL),
           let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) {
            return cfg
        }
        let cfg = AppConfig()
        cfg.save()
        return cfg
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
        // The file may hold an API key, so keep it private to this user.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.fileURL.path)
    }
}

extension AppConfig {
    /// The model each part of Poinky uses, for the brain that's connected.
    func model(for role: PromptRole) -> String {
        let cc = brain == .claudeCode
        switch role {
        case .talker: return cc ? claudeCodeModel : apiModel
        case .artist: return cc ? artistModel : apiArtistModel
        case .doer: return cc ? doerModel : apiDoerModel
        case .guide:
            let g = cc ? guideModel : apiGuideModel
            return g.isEmpty ? model(for: .talker) : g
        }
    }
    func effort(for role: PromptRole) -> String {
        switch role {
        case .talker: return talkerEffort
        case .artist: return artistEffort
        case .guide: return guideEffort
        case .doer: return doerEffort
        }
    }
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    /// One part's model (for each brain) and effort, as stored in the keys above.
    struct RoleModel: Equatable {
        var claudeCode: String, api: String, effort: String
        init(_ claudeCode: String, _ api: String, _ effort: String) { self.claudeCode = claudeCode; self.api = api; self.effort = effort }
    }
    /// The one choice most people make about models (Settings → Claude). Each sets the per-role keys, which stay
    /// the single source of truth (`model(for:)` / `effort(for:)`); any other combination is custom (Advanced).
    enum Pace: String, CaseIterable { case quick, careful }
    /// What Quick and Careful set. Quick is the defaults. Careful changes what makes answers better:
    /// - talker: Sonnet. Haiku, with no thinking step for speed, drifts from the reply format and gets checks of
    ///   your work wrong; Sonnet on automatic effort still starts talking quickly (it thinks only between tools).
    /// - teacher: thinks first (medium). The talker has already answered, so the wait is the lesson starting a few
    ///   seconds later; checks of your work get it right more often. Study sessions already use medium, so
    ///   Careful leaves them as they are (their hidden solver is Opus on high either way).
    /// - guide: the talker's model, as in Quick.
    /// - doer: Opus. Multi-step app use depends on the model most (Haiku was too weak), and nobody waits on its voice.
    /// Helpers aren't in it: their model is its own choice (`agentModel`).
    static let paces: [(role: PromptRole, quick: RoleModel, careful: RoleModel)] = [
        (.talker, RoleModel("haiku", "claude-haiku-5-5", ""), RoleModel("claude-sonnet-5-5", "claude-sonnet-5-5", "")),
        (.artist, RoleModel("sonnet", "claude-sonnet-5-5", ""), RoleModel("claude-sonnet-5-5", "claude-sonnet-5-5", "medium")),
        (.guide, RoleModel("", "", ""), RoleModel("", "", "")),
        (.doer, RoleModel("sonnet", "claude-sonnet-5-5", ""), RoleModel("claude-opus-5-5", "claude-opus-5-5", "")),
    ]

    /// A role's stored model (both brains) and effort.
    subscript(role role: PromptRole) -> RoleModel {
        get {
            switch role {
            case .talker: return RoleModel(claudeCodeModel, apiModel, talkerEffort)
            case .artist: return RoleModel(artistModel, apiArtistModel, artistEffort)
            case .guide: return RoleModel(guideModel, apiGuideModel, guideEffort)
            case .doer: return RoleModel(doerModel, apiDoerModel, doerEffort)
            }
        }
        set {
            switch role {
            case .talker: claudeCodeModel = newValue.claudeCode; apiModel = newValue.api; talkerEffort = newValue.effort
            case .artist: artistModel = newValue.claudeCode; apiArtistModel = newValue.api; artistEffort = newValue.effort
            case .guide: guideModel = newValue.claudeCode; apiGuideModel = newValue.api; guideEffort = newValue.effort
            case .doer: doerModel = newValue.claudeCode; apiDoerModel = newValue.api; doerEffort = newValue.effort
            }
        }
    }

    /// Quick or Careful, if every part is set the way it sets them (for the brain that's connected); nil: custom.
    var pace: Pace? {
        let cc = brain == .claudeCode
        func same(_ a: RoleModel, _ b: RoleModel) -> Bool { a.effort == b.effort && (cc ? a.claudeCode == b.claudeCode : a.api == b.api) }
        if Self.paces.allSatisfy({ same(self[role: $0.role], $0.quick) }) { return .quick }
        if Self.paces.allSatisfy({ same(self[role: $0.role], $0.careful) }) { return .careful }
        return nil
    }
    /// Sets every part (both brains) the way Quick or Careful does. Helpers keep their own choice.
    mutating func use(_ p: Pace) {
        for row in Self.paces { self[role: row.role] = p == .quick ? row.quick : row.careful }
    }
}

enum PromptRole: String {
    case talker   // answers out loud fast, points at things on screen
    case artist   // draws the rich diagram cards and 3D models
    case guide    // walks you through a task, one click at a time
    case doer     // does a task for you: clicks and types
}

enum SystemPrompt {
    static func overrideURL(_ role: PromptRole) -> URL { AppConfig.dir.appendingPathComponent("\(role.rawValue)-prompt.md") }

    /// Your edited copy wins; otherwise the one bundled with the app.
    static func load(_ role: PromptRole) -> String {
        if let s = try? String(contentsOf: overrideURL(role), encoding: .utf8), !s.isEmpty { return s }
        if let url = Bundle.main.url(forResource: "\(role.rawValue)-prompt", withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return role == .talker
            ? "You are Poinky, a voice assistant that sees the user's screen. Reply as <say>short spoken answer</say><draw>{\"items\":[]}</draw>."
            : "Draw a diagram card as <panel x=\"100\" y=\"100\" w=\"600\" h=\"400\" title=\"...\">HTML</panel>."
    }

    /// Copies the bundled prompt next to the config so the user can edit it.
    static func ensureEditableCopy(_ role: PromptRole) -> URL {
        let url = overrideURL(role)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? load(role).write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}
