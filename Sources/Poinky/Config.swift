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
    var soundVolume = 0.7              // their loudness, 0–1 (Poinky's voice has its own)
    var menuBarIcon = false            // also show ✨ in the menu bar (always shown on screens without a notch)
    var buddyHotkey = "ctrl+option+b"  // hides / shows the buddy
    var typeHotkey = "ctrl+option+t"   // opens a box to type to Poinky (or to the helper under the mouse)
    var buddyAutoHide = 0.0            // hide the buddy after this many idle seconds (0 = never); it's back when you ask something
    var memoryEnabled = true           // remember things about you between sessions (stored only on this Mac)
    var conversationLog = true         // keep what you and Poinky said (conversations/*.jsonl, only on this Mac) so it can look it up later
    var webSearch = true               // the main buddy may do a quick web search itself (Claude Code brain only)
    var frontAppContext = true         // send the front app's selected text, open document and web address with each question
    var computerControl = true         // Poinky may click and type for you when you ask it to do something
    var webPhotos = true               // pin a photo of the real thing (from Wikipedia) next to 3D models and lessons
    var agentPermission = "auto"        // background agents: "auto" (Claude Code's auto mode; falls back to acceptEdits if it can't start), "acceptEdits" (edit the project + run tests, ask for the rest), "plan"
    var agentModel = ""                // background agents' model ("" = your Claude Code default)
    var maxHelpers = 3                 // helpers (background agents) working at once, 1–6; more wait in line
    var awayNotify = false             // away from the Mac: a helper's question goes to your phone (ntfy)
    var ntfyServer = "https://ntfy.sh" // the ntfy server (ntfy.sh, or your own)
    var ntfyTopic = ""                 // a random, private topic (made when away mode is turned on)
    var awayMinutes = 3.0              // no keyboard or mouse for this long counts as away (or the screen locked)
    var awayDetails = true             // the notification says what it wants (the command); off: only that one is waiting
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
        soundVolume = try c.decodeIfPresent(Double.self, forKey: .soundVolume) ?? d.soundVolume
        menuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .menuBarIcon) ?? d.menuBarIcon
        buddyHotkey = try c.decodeIfPresent(String.self, forKey: .buddyHotkey) ?? d.buddyHotkey
        typeHotkey = try c.decodeIfPresent(String.self, forKey: .typeHotkey) ?? d.typeHotkey
        buddyAutoHide = try c.decodeIfPresent(Double.self, forKey: .buddyAutoHide) ?? d.buddyAutoHide
        memoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? d.memoryEnabled
        conversationLog = try c.decodeIfPresent(Bool.self, forKey: .conversationLog) ?? d.conversationLog
        webSearch = try c.decodeIfPresent(Bool.self, forKey: .webSearch) ?? d.webSearch
        frontAppContext = try c.decodeIfPresent(Bool.self, forKey: .frontAppContext) ?? d.frontAppContext
        computerControl = try c.decodeIfPresent(Bool.self, forKey: .computerControl) ?? d.computerControl
        webPhotos = try c.decodeIfPresent(Bool.self, forKey: .webPhotos) ?? d.webPhotos
        agentPermission = try c.decodeIfPresent(String.self, forKey: .agentPermission) ?? d.agentPermission
        agentModel = try c.decodeIfPresent(String.self, forKey: .agentModel) ?? d.agentModel
        maxHelpers = try c.decodeIfPresent(Int.self, forKey: .maxHelpers) ?? d.maxHelpers
        awayNotify = try c.decodeIfPresent(Bool.self, forKey: .awayNotify) ?? d.awayNotify
        ntfyServer = try c.decodeIfPresent(String.self, forKey: .ntfyServer) ?? d.ntfyServer
        ntfyTopic = try c.decodeIfPresent(String.self, forKey: .ntfyTopic) ?? d.ntfyTopic
        awayMinutes = try c.decodeIfPresent(Double.self, forKey: .awayMinutes) ?? d.awayMinutes
        awayDetails = try c.decodeIfPresent(Bool.self, forKey: .awayDetails) ?? d.awayDetails
        excludedApps = try c.decodeIfPresent([String].self, forKey: .excludedApps) ?? d.excludedApps
    }

    static let dir: URL = {
        let fm = FileManager.default
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
