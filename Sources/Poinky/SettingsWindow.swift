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
    /// Plays a sample with the local voice (provided by the app, which owns the voice helper).
    var previewKokoro: ((String, Double) -> Void)?

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

    init() { config = AppConfig.load(); loading = true; memoryText = Memory.text(); loading = false }

    func reload() {
        loading = true
        config = AppConfig.load()
        memoryText = Memory.text()
        loading = false
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

    func show() {
        model.reload()
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
}

// MARK: - Views

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
            VoiceTab(model: model).tabItem { Label("Voice", systemImage: "waveform") }
            ClaudeTab(model: model).tabItem { Label("Claude", systemImage: "sparkles") }
            MemoryTab(model: model).tabItem { Label("Memory", systemImage: "brain") }
            PrivacyTab(model: model).tabItem { Label("Privacy", systemImage: "hand.raised") }
            AdvancedTab(model: model).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
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
    var body: some View {
        Form {
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
                Toggle("Menu bar icon (the notch is Poinky's home; hover it for controls)", isOn: $model.config.menuBarIcon)
            }
            Section {
                Toggle("Let Poinky click and type for you", isOn: $model.config.computerControl)
                Text("When you ask it to do something (fill a form, write an email), it uses your mouse and keyboard while it explains. It asks before anything that sends, buys or deletes, and never types into password fields. Tap ⌃⌥ or press Esc to stop it. macOS asks for Accessibility permission the first time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
        }
        .formStyle(.grouped)
    }
}

private let pushOptions: [(String, String)] = [
    ("⌃⌥  Control + Option", "ctrl+option"), ("⌃⇧  Control + Shift", "ctrl+shift"),
    ("⌥⌘  Option + Command", "option+cmd"), ("Off", "off"),
]

private let kokoroVoices: [(String, String)] = [
    ("Michael · US male", "am_michael"), ("Adam · US male", "am_adam"), ("Echo · US male", "am_echo"),
    ("Eric · US male", "am_eric"), ("Liam · US male", "am_liam"), ("Onyx · US male", "am_onyx"),
    ("Puck · US male", "am_puck"), ("Fenrir · US male", "am_fenrir"),
    ("Heart · US female", "af_heart"), ("Bella · US female", "af_bella"), ("Nicole · US female", "af_nicole"),
    ("Nova · US female", "af_nova"), ("Sarah · US female", "af_sarah"), ("Sky · US female", "af_sky"),
    ("Jessica · US female", "af_jessica"), ("River · US female", "af_river"),
    ("George · UK male", "bm_george"), ("Lewis · UK male", "bm_lewis"), ("Daniel · UK male", "bm_daniel"),
    ("Fable · UK male", "bm_fable"), ("Emma · UK female", "bf_emma"), ("Isabella · UK female", "bf_isabella"),
    ("Alice · UK female", "bf_alice"), ("Lily · UK female", "bf_lily"),
]

private struct VoiceTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section {
                Picker("Voice engine", selection: $model.config.voiceEngine) {
                    Text("Natural (Kokoro, on this Mac)").tag("kokoro")
                    Text("Apple voices").tag("apple")
                }
                .pickerStyle(.radioGroup)
                if model.config.voiceEngine == "kokoro" && !model.config.language.lowercased().hasPrefix("en") {
                    Text("The natural voice speaks English only. For other languages, Apple's voice is used.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.config.voiceEngine == "kokoro" {
                Section("Natural voice") {
                    if KokoroVoice.isInstalled {
                        HStack {
                            Picker("Voice", selection: $model.config.kokoroVoice) {
                                ForEach(kokoroVoices, id: \.1) { Text($0.0).tag($0.1) }
                            }
                            Button { model.previewKokoro?(model.config.kokoroVoice, model.config.kokoroSpeed) } label: {
                                Image(systemName: "play.fill")
                            }
                            .help("Hear this voice")
                        }
                        Slider(value: $model.config.kokoroSpeed, in: 0.7...2.0, step: 0.05) {
                            Text("Speed  \(model.config.kokoroSpeed, specifier: "%.2f")×")
                        }
                        Text("1.25 is only a little faster; try 1.4–1.5 for a clearly quicker voice.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Not installed (one-time, about 350 MB). Re-run the Poinky installer to add it:\ncurl -fsSL https://raw.githubusercontent.com/tomyud1/poinky/main/install.sh | bash")
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
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
}

private struct ClaudeTab: View {
    @ObservedObject var model: SettingsModel
    private let models = [("Haiku · fastest", "haiku"), ("Sonnet · balanced", "sonnet"), ("Opus · smartest, slowest", "opus")]
    var body: some View {
        Form {
            Section {
                Picker("Connect with", selection: $model.config.brain) {
                    Text("Claude Code (your subscription)").tag(BrainKind.claudeCode)
                    Text("Anthropic API (API key, billed per use)").tag(BrainKind.api)
                }
                .pickerStyle(.radioGroup)
            }
            if model.config.brain == .claudeCode {
                Section {
                    Picker("Talker (answers out loud)", selection: $model.config.claudeCodeModel) {
                        ForEach(models, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    Toggle("Teacher sketches explanations and 3D models", isOn: $model.config.artistEnabled)
                    Picker("Teacher", selection: $model.config.artistModel) {
                        ForEach(models, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    .disabled(!model.config.artistEnabled)
                }
            } else {
                Section {
                    SecureField("API key", text: $model.config.apiKey, prompt: Text("sk-ant-…"))
                    TextField("Talker model", text: $model.config.apiModel)
                    Toggle("Teacher sketches explanations and 3D models", isOn: $model.config.artistEnabled)
                    TextField("Teacher model", text: $model.config.apiArtistModel)
                        .disabled(!model.config.artistEnabled)
                }
            }
            Section {
                Text("Changes apply from your next call.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Background agents") {
                Picker("Agents may", selection: $model.config.agentPermission) {
                    Text("Edit the project and run its tests").tag("acceptEdits")
                    Text("Auto mode (if your Claude Code has it)").tag("auto")
                    Text("Only plan, change nothing").tag("plan")
                }
                TextField("Model", text: $model.config.agentModel, prompt: Text("your Claude Code default"))
                Text("Ask \"put an agent on it\" to have Claude Code work on a project in the background. Poinky tells you when it's done.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Agent Logs") {
                    try? FileManager.default.createDirectory(at: AgentManager.logDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(AgentManager.logDir)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PrivacyTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
            Section {
                Text("Poinky never sees these apps: they're left out of every screenshot it sends to Claude.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(model.config.excludedApps, id: \.self) { id in
                    HStack {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                            Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                        } else {
                            Text(id).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { model.config.excludedApps.removeAll { $0 == id } } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add App…") { addApp() }
            }
        }
        .formStyle(.grouped)
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
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedTab: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Form {
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
