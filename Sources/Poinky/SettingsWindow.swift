import AppKit
import AVFoundation
import SwiftUI

/// The Settings window (✨ menu → Settings…). Edits the same config.json the app reads;
/// changes are saved automatically and most apply on your next call.
@MainActor
final class SettingsModel: ObservableObject {
    @Published var config: AppConfig {
        didSet { if !loading { scheduleSave() } }
    }
    /// Called after saving, so the app can pick up changes (e.g. a new shortcut).
    var onSaved: ((AppConfig) -> Void)?
    /// Which tab is showing (the notch's update arrow opens General).
    @Published var tab = "general"
    /// Settings → Advanced: each part's model and effort, shown (for developers; closed until opened).
    @Published var showRoleModels = false
    /// Plays a sample with the local voice (provided by the app, which owns the voice helper).
    var previewVoice: ((String, Double) -> Void)?
    /// "Start Fresh" (Settings → General → Why isn't it working?): the app's `resetEverything`.
    var startFresh: (() -> Void)?

    private var loading = false
    private var saveWork: DispatchWorkItem?
    private let synth = AVSpeechSynthesizer()

    /// What Poinky remembers about you (Settings → Memory), saved as you edit it.
    @Published var memoryText = "" {
        didSet { if !loading { memoryWork?.cancel(); let t = memoryText
            let w = DispatchWorkItem { Memory.save(text: t) }; memoryWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w) } }
    }
    private var memoryWork: DispatchWorkItem?

    /// Claude Code's version ("2.1.119"), for the Claude tab.
    @Published var claudeVersion: String?
    @Published var updatingClaude = false
    @Published var claudeUpdateResult: String?

    func checkClaudeVersion() {
        let path = ClaudeCodeBrain.findClaude(explicit: config.claudePath)
        DispatchQueue.global().async {
            let v = Self.runClaude(path, ["--version"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self.claudeVersion = v.map { String($0.split(separator: " ").first ?? "") } }
        }
    }

    /// Runs `claude update` (the button in the Claude tab).
    func updateClaude() {
        updatingClaude = true
        claudeUpdateResult = nil
        let path = ClaudeCodeBrain.findClaude(explicit: config.claudePath)
        DispatchQueue.global().async {
            let out = Self.runClaude(path, ["update"]) ?? "Couldn't run Claude Code."
            let last = out.split(separator: "\n").last.map(String.init) ?? ""
            DispatchQueue.main.async {
                self.updatingClaude = false
                self.claudeUpdateResult = last
                self.checkClaudeVersion()
            }
        }
    }

    nonisolated private static func runClaude(_ path: String?, _ args: [String]) -> String? {
        guard let path else { return nil }
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    init() { config = AppConfig.load(); loading = true; memoryText = Memory.text(); reminders = Reminders.all(); loading = false }

    func reload() {
        loading = true
        config = AppConfig.load()
        memoryText = Memory.text()
        reminders = Reminders.all()
        loading = false
    }

    /// Settings → General → Reminders: what Poinky will say (or start) by itself, and when.
    @Published var reminders: [Reminder] = []
    func cancelReminder(_ id: String) {
        let left = Reminders.all().filter { $0.id != id }
        Reminders.save(left)
        reminders = left
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.config.save()
            self.onSaved?(self.config)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func previewApple() {
        synth.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: "Hi! This is how I'll sound when I explain things.")
        let all = AVSpeechSynthesisVoice.speechVoices()
        u.voice = config.voice.isEmpty
            ? Speaker.systemVoiceID(for: config.language).flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            : all.first { $0.name == config.voice }
        u.rate = config.speechRate
        synth.speak(u)
    }

    var appleVoices: [String] {
        let base = String(config.language.prefix(2)).lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(base) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
            .map(\.name)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    let model = SettingsModel()
    private var window: NSWindow?

    func show(tab: String? = nil) {
        model.reload()
        if let tab { model.tab = tab }
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Poinky Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Developer check (`--settings-shot <out.png> [voice|general|privacy|advanced]`): a picture of the Claude (or
    /// another) tab, then quit. `POINKY_SHOT_DARK=1`: in dark mode. The advanced tab is shown with its sections open.
    func snapshotTab(to out: String, tab name: String = "claude") {
        model.reload()
        let voice = name == "voice"
        if name == "advanced" { model.showRoleModels = true }
        let tab = voice ? AnyView(VoiceTab(model: model)) : name == "general" ? AnyView(GeneralTab(model: model))
            : name == "privacy" ? AnyView(PrivacyTab(model: model)) : name == "advanced" ? AnyView(AdvancedTab(model: model))
            : AnyView(ClaudeTab(model: model))
        let h: CGFloat = voice ? 560 : name == "general" ? 1600 : name == "privacy" ? 620 : 900
        let host = NSHostingView(rootView: tab.frame(width: 620, height: h))
        let w = NSWindow(contentRect: CGRect(x: -3000, y: 0, width: 620, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["POINKY_SHOT_DARK"] == "1" ? .darkAqua : .aqua)
        w.contentView = host
        w.orderFrontRegardless()
        let delay = Double(ProcessInfo.processInfo.environment["POINKY_SHOT_DELAY"] ?? "") ?? 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.tab) {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            VoiceTab(model: model).tabItem { Label("Voice", systemImage: "waveform") }.tag("voice")
            ClaudeTab(model: model).tabItem { Label("Claude", systemImage: "sparkles") }.tag("claude")
            MemoryTab(model: model).tabItem { Label("Memory", systemImage: "brain") }.tag("memory")
            PrivacyTab(model: model).tabItem { Label("Privacy", systemImage: "hand.raised") }.tag("privacy")
            AdvancedTab(model: model).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }.tag("advanced")
        }
        .frame(width: 580, height: 460)
        .padding(.top, 6)
    }
}

private let languages: [(String, String)] = [
    ("English (US)", "en-US"), ("English (UK)", "en-GB"), ("English (Australia)", "en-AU"), ("Hebrew", "he-IL"),
    ("Spanish", "es-ES"), ("French", "fr-FR"), ("German", "de-DE"), ("Italian", "it-IT"),
    ("Portuguese (Brazil)", "pt-BR"), ("Japanese", "ja-JP"), ("Chinese (Mandarin)", "zh-CN"),
]

private struct GeneralTab: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var updater = Updater.shared
    /// An update waiting, building or ready goes first (the notch's arrow opens this tab).
    private var updateFirst: Bool { [.available, .updating, .ready].contains(updater.state) }
    var body: some View {
        Form {
            if updateFirst { UpdateSection(model: model) }
            Section {
                Picker("Hold to talk", selection: $model.config.pushToTalk) {
                    ForEach(pushOptions, id: \.1) { Text($0.0).tag($0.1) }
                    if !pushOptions.contains(where: { $0.1 == model.config.pushToTalk }) {
                        Text(PushToTalk.displayString(model.config.pushToTalk)).tag(model.config.pushToTalk)
                    }
                }
                Text("Hold the keys and talk, let go to send. Drag while holding to mark things on screen.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Hands-free call (start / end)") { HotkeyRecorder(spec: $model.config.hotkey) }
                Picker("Language you speak", selection: $model.config.language) {
                    ForEach(languages, id: \.1) { Text($0.0).tag($0.1) }
                    if !languages.contains(where: { $0.1 == model.config.language }) {
                        Text(model.config.language).tag(model.config.language)
                    }
                }
            }
            Section {
                Toggle("Buddy at your cursor (captions appear next to it)", isOn: $model.config.buddy)
                LabeledContent("Hide / show the buddy") { HotkeyRecorder(spec: $model.config.buddyHotkey) }
                LabeledContent("Type instead of talking") { HotkeyRecorder(spec: $model.config.typeHotkey) }
                LabeledContent("Helpers window") { HotkeyRecorder(spec: $model.config.helpersHotkey) }
                Picker("Hide the buddy", selection: $model.config.buddyAutoHide) {
                    Text("Never (always at your cursor)").tag(0.0); Text("Right after it answers").tag(3.0)
                    Text("After 10 seconds idle").tag(10.0); Text("After 30 seconds idle").tag(30.0)
                    Text("After 1 minute idle").tag(60.0); Text("After 5 minutes idle").tag(300.0)
                    if ![0.0, 3, 10, 30, 60, 300].contains(model.config.buddyAutoHide) {
                        Text("\(Int(model.config.buddyAutoHide)) seconds").tag(model.config.buddyAutoHide)
                    }
                }
                .disabled(!model.config.buddy)
                Toggle("Interface sounds", isOn: $model.config.sounds)
                LabeledContent("Sound volume") {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary).font(.caption)
                        // Plays a sample when you let go, so you hear the new level.
                        Slider(value: $model.config.soundVolume, in: 0...1) { editing in
                            if !editing { Earcons.playStandalone(.send, volume: Float(model.config.soundVolume)) }
                        }
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).font(.caption)
                    }
                }
                .disabled(!model.config.sounds)
                Toggle("Menu bar icon (the notch is Poinky's home; hover it for controls)", isOn: $model.config.menuBarIcon)
            }
            Section {
                Toggle("Let Poinky click and type for you", isOn: $model.config.computerControl)
                Text("When you ask it to do something (fill a form, write an email), it uses your mouse and keyboard while it explains. It asks before anything that sends, buys or deletes, and never types into password fields. Tap ⌃⌥ or press Esc to stop it. macOS asks for Accessibility permission the first time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            RemindersSection(model: model)
            Section("Hands-free calls") {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $model.config.silenceSeconds, in: 0.5...2.5, step: 0.1) {
                        Text("Pause before answering")
                    }
                    Text("In a hands-free call, Claude answers after \(model.config.silenceSeconds, specifier: "%.1f") s of silence. Raise it if it cuts you off.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Hold ⌥ Option and click or drag to mark things on screen any time Poinky is active.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SetupCheckSection(settings: model)
            if !updateFirst { UpdateSection(model: model) }
        }
        .formStyle(.grouped)
    }
}

/// Settings → General → Reminders: the list, with a button to cancel each one.
private struct RemindersSection: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Section("Reminders") {
            if model.reminders.isEmpty {
                Text("None yet. Ask me something like “remind me tomorrow at 9 to email my teacher” or “every weekday at 8, remind me to review my flashcards”.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.reminders, id: \.id) { r in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: r.agentTitle != nil ? "person.crop.circle.badge.clock" : r.every != nil ? "repeat" : "bell")
                        .foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.agentTitle.map { "Helper: \($0)" } ?? r.text).lineLimit(2)
                        Text(Self.when(r) + (r.agentTitle != nil ? " · " + r.text : "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { model.cancelReminder(r.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help("Cancel this reminder")
                        .accessibilityLabel("Cancel reminder: \(r.text)")
                }
            }
        }
        .onAppear { model.reminders = Reminders.all() }   // one may have been said or added since the window opened
    }

    /// "Tomorrow at 9:00 AM, then every weekday".
    static func when(_ r: Reminder, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = r.at.formatted(date: .omitted, time: .shortened)
        let day: String
        if cal.isDateInToday(r.at) { day = "Today" }
        else if cal.isDateInTomorrow(r.at) { day = "Tomorrow" }
        else if let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: r.at)).day, days > 0, days < 7 {
            day = r.at.formatted(.dateTime.weekday(.wide))
        } else { day = r.at.formatted(date: .abbreviated, time: .omitted) }
        let again: String
        switch r.every {
        case .daily: again = ", then every day"
        case .weekdays: again = ", then every weekday"
        case .weekly: again = ", then every week"
        case .hourly: again = ", then every hour"
        case nil: again = ""
        }
        return "\(day) at \(time)\(again)"
    }
}

/// Settings → General → Updates: this version, what's new, Update, then Restart.
private struct UpdateSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var updater = Updater.shared

    var body: some View {
        Section("Updates") {
            LabeledContent("This version") { Text(updater.version).textSelection(.enabled) }
            switch updater.state {
            case .available:
                VStack(alignment: .leading, spacing: 4) {
                    Text(updater.changes.isEmpty ? "A new version is available." :
                         "A new version is available (\(updater.changes.count == 30 ? "30+" : "\(updater.changes.count)") change\(updater.changes.count == 1 ? "" : "s")):")
                    ForEach(Array(updater.changes.prefix(6).enumerated()), id: \.offset) { _, c in
                        Text("• " + c).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if updater.changes.count > 6 { Text("and \(updater.changes.count - 6) more").font(.caption).foregroundStyle(.secondary) }
                }
                HStack {
                    Text("Poinky keeps working while it builds (about a minute).").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Update") { updater.update() }.keyboardShortcut(.defaultAction)
                }
            case .updating:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: updater.progress)
                    Text(updater.step).font(.caption).foregroundStyle(.secondary)
                }
            case .ready:
                VStack(alignment: .leading, spacing: 4) {
                    Text("The new version is ready. Restart Poinky to use it.")
                    if let w = updater.restartWarning { Text(w).font(.caption).foregroundStyle(.orange) }
                }
                HStack { Spacer(); Button("Restart Poinky") { updater.restart() }.keyboardShortcut(.defaultAction) }
            default:
                HStack {
                    Text(status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Spacer()
                    Button(updater.state == .checking ? "Checking…" : "Check Now") { updater.check() }
                        .disabled(updater.state == .checking)
                }
            }
            Toggle("Check for updates automatically", isOn: $model.config.checkForUpdates)
        }
        .onAppear { if model.config.checkForUpdates { updater.checkIfStale() } }
    }

    private var status: String {
        let at = updater.lastChecked.map { " (checked at \($0.formatted(date: .omitted, time: .shortened)))" } ?? ""
        switch updater.state {
        case .upToDate: return "Poinky is up to date with GitHub\(at)." + (updater.rebuildNote.map { " " + $0 } ?? "")
        case .failed(let why), .unavailable(let why): return why
        case .checking: return "Looking for a new version…"
        default: return "Gets the newest Poinky from GitHub and builds it on this Mac."
        }
    }
}

private let pushOptions: [(String, String)] = [
    ("⌃⌥  Control + Option", "ctrl+option"), ("⌃⇧  Control + Shift", "ctrl+shift"),
    ("⌥⌘  Option + Command", "option+cmd"), ("Off", "off"),
]

private struct VoiceTab: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var installer = PhononInstaller.shared
    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.config.quiet) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quiet mode: write, don't talk")
                        Text("For a library, a lecture or a call. Answers are written next to the buddy (with Copy) and nothing is played: no voice, no sounds, videos muted with subtitles. You can still ask out loud. Also in the notch, or \(HotKey.displayString(model.config.quietHotkey)), or say \u{201C}be quiet\u{201D}.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Questions you type (\(HotKey.displayString(model.config.typeHotkey))) are always answered in writing, in the box.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Voice engine", selection: $model.config.voiceEngine) {
                    Text("Natural (Phonon, on this Mac)").tag("phonon")
                    Text("Apple voices").tag("apple")
                }
                .pickerStyle(.radioGroup)
                if model.config.voiceEngine == "phonon" && !model.config.language.lowercased().hasPrefix("en") {
                    Text("The natural voice speaks English only. For other languages, Apple's voice is used.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.config.voiceEngine == "phonon" {
                Section("Natural voice") {
                    if PhononVoice.isInstalled {
                        HStack {
                            Picker("Voice", selection: $model.config.phononVoice) {
                                ForEach(PhononVoice.voices, id: \.name) { Text($0.label).tag($0.name) }
                            }
                            Button { model.previewVoice?(model.config.phononVoice, model.config.voiceSpeed) } label: {
                                Image(systemName: "play.fill")
                            }
                            .help("Hear this voice")
                        }
                        Slider(value: $model.config.voiceSpeed, in: PhononVoice.speedRange, step: 0.02) {
                            Text("Speed  \(model.config.voiceSpeed, specifier: "%.2f")×")
                        }
                    } else {
                        installRow
                    }
                }
            }
            SpeechRecognitionSection(model: model)
            Section("Apple voice (used for other languages, or if the natural voice is off)") {
                HStack {
                    Picker("Voice", selection: $model.config.voice) {
                        Text("Your System voice").tag("")
                        ForEach(model.appleVoices, id: \.self) { Text($0).tag($0) }
                    }
                    Button { model.previewApple() } label: { Image(systemName: "play.fill") }
                        .help("Hear this voice")
                }
                Slider(value: Binding(get: { Double(model.config.speechRate) }, set: { model.config.speechRate = Float($0) }),
                       in: 0.35...0.7, step: 0.01) {
                    Text("Speed")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Not installed yet: one click downloads it (~75 MB) and tests it.
    @ViewBuilder private var installRow: some View {
        switch installer.state {
        case .running:
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: installer.progress)
                Text(installer.step).font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 6) {
                Text("The install didn't finish: \(why)").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Button("Try again") { installer.start() }
            }
        case .idle, .done:
            HStack {
                Text("Not installed yet. A one-time download of about 75 MB; it runs on this Mac, offline.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Install") { installer.start() }
            }
        }
    }
}

private struct ClaudeTab: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let cc = model.config.brain == .claudeCode
        let pace = model.config.pace
        Form {
            Section {
                Picker("Connect with", selection: $model.config.brain) {
                    Text("Claude Code (your subscription)").tag(BrainKind.claudeCode)
                    Text("Anthropic API (API key, billed per use)").tag(BrainKind.api)
                }
                .pickerStyle(.radioGroup)
                if !cc {
                    SecureField("API key", text: $model.config.apiKey, prompt: Text("sk-ant-…"))
                }
            }
            Section {
                Picker("Answers", selection: Binding(get: { pace?.rawValue ?? "custom" },
                                                     set: { if let p = AppConfig.Pace(rawValue: $0) { model.config.use(p) } })) {
                    Text("Quick").tag("quick")
                    Text("Careful").tag("careful")
                    if pace == nil { Text("Custom").tag("custom") }
                }
                .pickerStyle(.segmented)
                switch pace {
                case .quick?:
                    Text("Answers start right away. Best for most questions.").font(.caption).foregroundStyle(.secondary)
                case .careful?:
                    Text("Stronger models where they make answers better: the teacher thinks before it explains or checks your work, and a stronger model clicks and types for you. A little slower to start, and uses more of your plan.")
                        .font(.caption).foregroundStyle(.secondary)
                case nil:
                    HStack {
                        Text("You picked each part's model yourself. Choose Quick or Careful to go back.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show Models…") { model.showRoleModels = true; model.tab = "advanced" }
                    }
                }
                LabeledContent {
                    ModelPicker(value: $model.config.agentModel, sameAs: "Your Claude Code default").frame(width: 230)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Helpers' model")
                        Text("background agents doing longer work").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Models")
            } footer: {
                Text("Changes apply from your next call (helpers: from the next one you start).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Teacher sketches explanations and 3D models", isOn: $model.config.artistEnabled)
                Picker("Sketches are drawn on", selection: $model.config.paperLook) {
                    Text("Paper, or a chalkboard on dark screens").tag("auto")
                    Text("Always paper").tag("paper")
                    Text("Always a chalkboard").tag("chalkboard")
                }
                .disabled(!model.config.artistEnabled)
                Picker("Smallest text in sketches", selection: $model.config.minTextSize) {
                    // (a size written into config.json by hand shows too)
                    ForEach(Array(Set([10.0, 12, 14, 16, 18, 20] + [model.config.minTextSize])).sorted(), id: \.self) { v in
                        Text(v == 10 ? "10 pt (small)" : v == 20 ? "20 pt (large)" : "\(Int(v)) pt").tag(v)
                    }
                }
                .help("Text on the paper is never smaller than this on your screen. Long lines wrap instead of shrinking, and the paper is made wide enough.")
                .disabled(!model.config.artistEnabled)
                Toggle("Quick web search (the talker looks things up itself, with web tools only)", isOn: $model.config.webSearch)
                    .disabled(!cc)
            }
            if cc, let v = model.claudeVersion {
                Section {
                    HStack {
                        if ClaudeVersion.isOlder(v, than: ClaudeVersion.newestModels) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Your Claude Code (\(v)) is too old for Opus 5.5 and Fable 5.1, and its short names (haiku, sonnet, opus) pick older models.")
                                .font(.callout)
                        } else {
                            Text("Claude Code \(v)").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(model.updatingClaude ? "Updating…" : "Update Claude Code") { model.updateClaude() }
                            .disabled(model.updatingClaude)
                    }
                    if let r = model.claudeUpdateResult { Text(r).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Background agents") {
                Picker("Agents may", selection: $model.config.agentPermission) {
                    Text("Auto mode (recommended)").tag("auto")
                    Text("Edit the project, ask for the rest").tag("acceptEdits")
                    Text("Make a plan first, ask me before starting").tag("plan")
                }
                Picker("Working at once", selection: $model.config.maxHelpers) {
                    ForEach(1...6, id: \.self) { n in Text(n == 3 ? "3 (recommended)" : "\(n)").tag(n) }
                }
                Text("Ask \"put an agent on it\" to have Claude Code work on a project in the background. Poinky tells you when it's done. Anything else an agent wants to do (install, delete, push, run a script) comes to you as a question: say yes or no, or click its card. Auto mode asks less often. More agents than this wait in line; each one uses your Claude plan.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Agent Logs") {
                    try? FileManager.default.createDirectory(at: AgentManager.logDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AgentManager.logDir)
                }
            }
            Section("Notifications") {
                Toggle("Notify me when a helper needs me", isOn: $model.config.helperNotify)
                Toggle("Also when a helper finishes while I'm away", isOn: $model.config.helperNotifyDone)
                    .disabled(!model.config.helperNotify)
                Text("A Mac notification when a helper asks for your OK or asks a question while you're not talking to Poinky, or when nobody answered it out loud. Allow and Don't Allow work like the buttons on its card (Allow needs your Mac unlocked). macOS asks you once, the first time one is needed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.checkClaudeVersion() }
    }
}

/// One part of Poinky: its model and how hard it thinks (Settings → Advanced). nil model: effort only.
private struct RoleRow: View {
    let title: String, about: String
    let model: Binding<String>?
    let effort: Binding<String>
    var sameAs: String? = nil
    var automatic = "Automatic"

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let model { ModelPicker(value: model, sameAs: sameAs).frame(width: 205) }
                Picker("Effort", selection: effort) {
                    Text(automatic).tag("")
                    Divider()
                    ForEach(EffortChoice.all, id: \.1) { Text($0.0).tag($0.1) }
                }
                .labelsHidden().frame(width: 118)
            }
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(about).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

enum EffortChoice {
    static let all = [("Low", "low"), ("Medium", "medium"), ("High", "high"), ("Extra high", "xhigh"), ("Max", "max")]
}

/// The current Claude models by full name (short names like "sonnet" depend on your Claude Code version),
/// anything else you type, and optionally "same as …" (an empty value).
private struct ModelPicker: View {
    @Binding var value: String
    var sameAs: String?
    static let known = [("Haiku 5.5 · fastest", "claude-haiku-5-5"), ("Sonnet 5.5 · balanced", "claude-sonnet-5-5"),
                        ("Opus 5.5 · smarter, slower", "claude-opus-5-5"), ("Fable 5.1 · smartest, slowest", "claude-fable-5-1")]
    static let short = ["haiku": "Haiku (auto version)", "sonnet": "Sonnet (auto version)", "opus": "Opus (auto version)"]
    private static let other = "\u{1}other"

    var body: some View {
        let isKnown = Self.known.contains { $0.1 == value } || Self.short[value] != nil || (value.isEmpty && sameAs != nil)
        VStack(alignment: .leading, spacing: 4) {
            Picker("Model", selection: Binding(get: { isKnown ? value : Self.other },
                                               set: { value = $0 == Self.other ? "claude-" : $0 })) {
                if let sameAs { Text(sameAs).tag(""); Divider() }
                ForEach(Self.known, id: \.1) { Text($0.0).tag($0.1) }
                if let s = Self.short[value] { Text(s).tag(value) }
                Divider()
                Text("Other…").tag(Self.other)
            }
            .labelsHidden()
            if !isKnown {
                TextField("Model name", text: $value, prompt: Text("claude-…")).textFieldStyle(.roundedBorder).font(.caption)
            }
        }
    }
}

enum ClaudeVersion {
    /// Opus 5.5 and Fable 5.1 need at least this Claude Code.
    static let newestModels = "2.1.280"
    static func parts(_ v: String) -> [Int] {
        (v.split(separator: " ").first ?? "").split(separator: ".").map { Int($0) ?? 0 }
    }
    static func isOlder(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q }
        }
        return false
    }
}

private struct PrivacyTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section {
                Toggle("Also send the text I selected, the open document's name and the web page's address", isOn: $model.config.frontAppContext)
                Text("So \"explain this paragraph\" or \"summarize this lecture\" works on exactly what you selected, and helpers start in the right folder. Read through Accessibility, never from password fields or the apps below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep a receipt of what each question sends", isOn: $model.config.receipts)
                    .onChange(of: model.config.receipts) { _, on in Receipts.enabled = on; if !on { Receipts.clear() } else { Receipts.onChange() } }
                Text("The screenshot, the lines about the app in front, and which of your files were included, for the last \(Receipts.keep) questions. Kept only on this Mac; hover the notch and click What I saw. Turning this off deletes them.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Show What Poinky Saw…") { ReceiptsWindow.shared.show() }
                    Spacer()
                    Button("Clear Receipts", role: .destructive) { Receipts.clear() }
                }
            }
            Section {
                Text("Poinky never sees these apps: they're left out of every screenshot it sends to Claude.")
                    .font(.callout).foregroundStyle(.secondary)
                // Installed ones by name and icon; the password managers listed in advance that aren't installed
                // are one quiet line (they were raw bundle IDs).
                ForEach(model.config.excludedApps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }, id: \.self) { id in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                            Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                        }
                        Spacer()
                        Button(role: .destructive) { model.config.excludedApps.removeAll { $0 == id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                let absent = model.config.excludedApps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) == nil }
                if !absent.isEmpty {
                    Text("Also left out if you install them: " + Self.appNames(absent).joined(separator: ", ") + ".")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Add App…") { addApp() }
            }
        }
        .formStyle(.grouped)
    }

    /// Names for apps that aren't installed: the password managers Poinky leaves out by default, else the
    /// bundle ID's last part ("com.example.Notes" → "Notes").
    static func appNames(_ ids: [String]) -> [String] {
        let known = ["com.apple.Passwords": "Passwords", "com.apple.keychainaccess": "Keychain Access",
                     "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
                     "com.bitwarden.desktop": "Bitwarden", "com.lastpass.LastPass": "LastPass"]
        var seen = Set<String>()
        return ids.map { known[$0] ?? ($0.split(separator: ".").last.map(String.init) ?? $0) }.filter { seen.insert($0).inserted }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !model.config.excludedApps.contains(id) {
                model.config.excludedApps.append(id)
            }
        }
    }
}

private struct MemoryTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section {
                Toggle("Remember things about me between sessions", isOn: $model.config.memoryEnabled)
                Text("Your name, what you're working on, what interests you, how you like answers. Poinky uses it to feel personal. It's stored only on this Mac. You can also say \"forget that\" or \"what do you remember about me?\".")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Who Poinky is, and who you are") {
                HStack {
                    Button("Edit Poinky's Personality…") { Identity.ensureFiles(); NSWorkspace.shared.open(Identity.identityURL) }
                    Button("Edit About Me…") { Identity.ensureFiles(); NSWorkspace.shared.open(Identity.userURL) }
                }
                Text("Two short files read at the start of every session: Poinky's personality, and what it should always know about you (your role, your projects and where they live, how you like answers). They count even with memory turned off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("What Poinky remembers (you can edit this)") {
                TextEditor(text: $model.memoryText)
                    .font(.system(size: 12))
                    .frame(minHeight: 200)
                    .disabled(!model.config.memoryEnabled)
                HStack {
                    Button("Forget Everything", role: .destructive) { Memory.clear(); model.reload() }
                    Spacer()
                    Button("Show File") { NSWorkspace.shared.activateFileViewerSelecting([Memory.url]) }
                }
                HStack {
                    Button("Show Daily Notes") {
                        try? FileManager.default.createDirectory(at: DailyNotes.dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(DailyNotes.dir)
                    }
                    Spacer()
                }
                Text("After each session Poinky writes a few lines about it (today's and yesterday's are read at the start of the next session; older ones are found when you ask). When the list above is full, the oldest facts move to an archive instead of being deleted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Conversation history") {
                Toggle("Keep what we said, so Poinky can look it up later", isOn: $model.config.conversationLog)
                Text("Lets you ask \"what did you tell me yesterday about the router?\" or \"what was I doing in Claude Code this morning?\". Poinky keeps what you said and what it answered (no screenshots), one file per day, only on this Mac. When you ask, it also looks through your earlier helpers and the titles and last prompts of your own Claude Code sessions.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Forget Today") { ConversationLog.clearToday() }
                    Button("Forget All Conversations", role: .destructive) { ConversationLog.clear() }
                    Spacer()
                    Button("Show Folder") {
                        try? FileManager.default.createDirectory(at: ConversationLog.dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([ConversationLog.dir])
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        let cc = model.config.brain == .claudeCode
        Form {
            Section(isExpanded: $model.showRoleModels) {
                RoleRow(title: "Talker", about: "answers out loud, marks the screen",
                        model: cc ? $model.config.claudeCodeModel : $model.config.apiModel, effort: $model.config.talkerEffort)
                RoleRow(title: "Teacher", about: "sketches and 3D models",
                        model: cc ? $model.config.artistModel : $model.config.apiArtistModel, effort: $model.config.artistEffort)
                RoleRow(title: "Guide", about: "walks you through, step by step",
                        model: cc ? $model.config.guideModel : $model.config.apiGuideModel, effort: $model.config.guideEffort,
                        sameAs: "Same as the talker")
                RoleRow(title: "Doer", about: "clicks and types for you",
                        model: cc ? $model.config.doerModel : $model.config.apiDoerModel, effort: $model.config.doerEffort)
                RoleRow(title: "Helpers", about: "their model is in Settings → Claude", model: nil,
                        effort: $model.config.agentEffort, automatic: "Default")
                Text("Quick and Careful (Settings → Claude) set these for you; anything else shows there as Custom. Effort is how long each one thinks before answering: Automatic keeps the voice quick (no thinking step), higher is smarter but slower and uses more of your plan.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Each part's model and effort (for developers)")
            }
            Section("How Claude talks and draws") {
                HStack {
                    Button("Edit Talker Prompt…") { NSWorkspace.shared.open(SystemPrompt.ensureEditableCopy(.talker)) }
                    Button("Edit Teacher Prompt…") { NSWorkspace.shared.open(SystemPrompt.ensureEditableCopy(.artist)) }
                }
                Button("Reset Prompts to Default") {
                    for role in [PromptRole.talker, .artist] { try? FileManager.default.removeItem(at: SystemPrompt.overrideURL(role)) }
                }
            }
            Section("Files") {
                Button("Open Settings Folder") { NSWorkspace.shared.open(AppConfig.dir) }
                LabeledContent("Claude Code path") {
                    TextField("auto-detect", text: $model.config.claudePath).frame(width: 260)
                }
            }
            Section("Diagnostics") {
                LabeledContent("Typical wait for an answer") {
                    Text(Timeline.medianLatency().map { String(format: "%.1f s (last 20 questions)", $0) } ?? "no questions yet")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Copy Diagnostics") {
                        // What Poinky did lately (states, timings, errors, restarts), never what was said.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Timeline.recent(200).joined(separator: "\n"), forType: .string)
                    }
                    Button("Open Timeline Folder") {
                        try? FileManager.default.createDirectory(at: Timeline.dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Timeline.dir)
                    }
                }
                Text("If Poinky gets stuck it restarts itself and writes down why. Paste the diagnostics into a bug report or a Claude chat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Click, then press the shortcut you want (Esc cancels).
private struct HotkeyRecorder: View {
    @Binding var spec: String
    @StateObject private var rec = Recorder()

    var body: some View {
        Button(rec.recording ? "Press a shortcut…" : HotKey.displayString(spec)) {
            rec.recording ? rec.stop() : rec.start { spec = $0 }
        }
        .frame(minWidth: 150)
    }
}

@MainActor
private final class Recorder: ObservableObject {
    @Published var recording = false
    private var monitor: Any?

    func start(_ done: @escaping (String) -> Void) {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stop(); return nil }   // Esc
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let key = HotKey.keyName(for: event.keyCode) else { return nil }
            var parts: [String] = []
            if flags.contains(.control) { parts.append("ctrl") }
            if flags.contains(.option) { parts.append("option") }
            if flags.contains(.command) { parts.append("cmd") }
            if flags.contains(.shift) { parts.append("shift") }
            // A plain letter would get in the way of typing: require a modifier (F-keys are fine alone).
            guard !parts.isEmpty || key.hasPrefix("f") else { return nil }
            done((parts + [key]).joined(separator: "+"))
            self.stop()
            return nil
        }
    }

    func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}
