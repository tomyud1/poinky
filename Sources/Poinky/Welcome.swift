import AppKit
import AVFoundation
import Speech
import SwiftUI

/// The first-run tour (about a minute): what Poinky is, the permissions one at a time with plain
/// reasons, Claude Code (installed? signed in?), a first question on a sample, and the three things
/// worth knowing (tap to stop, ⌃⌥T to type, ↻ in the notch). Skippable; replayed from
/// Settings → General. `welcome.json` remembers where you are (a restart for Screen Recording
/// comes back to the same page) and that it's done.
/// Pictures without a call: `Poinky --welcome-shot <outdir>` (with POINKY_SUPPORT_DIR set to a scratch folder).
@MainActor
final class WelcomeModel: ObservableObject {
    enum Page: Int, CaseIterable { case hello, permissions, claude, tryIt, tips }
    enum Access { case unknown, allowed, notAsked, denied }
    enum ClaudeState: Equatable { case checking, missing, signedOut, ready(String), unsure(String) }
    enum Event { case asked, answered, tapped, typed, reset }

    @Published var page: Page = .hello
    @Published var mic: Access = .unknown
    @Published var speech: Access = .unknown
    @Published var screen: Access = .unknown
    @Published var hands: Access = .unknown
    @Published var askedScreen = false        // Allow was clicked: macOS sent you to System Settings
    @Published var claude: ClaudeState = .checking
    @Published var asked = false
    @Published var answered = false
    @Published var tapped = false
    @Published var typed = false
    var hasNotch = NotchHome.notchScreen != nil
    var holdKeys = "⌃⌥"
    var typeKeys = "⌃⌥T"

    var onFinish: () -> Void = {}
    var onOpenSettings: (String) -> Void = { _ in }

    /// The next permission to ask for (one at a time); nil when the needed ones are allowed.
    var nextNeeded: String? {
        if mic != .allowed { return "mic" }
        if speech != .allowed { return "speech" }
        if screen != .allowed { return "screen" }
        return nil
    }

    func refreshAccess() {
        mic = Self.map(AVCaptureDevice.authorizationStatus(for: .audio))
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = .allowed
        case .notDetermined: speech = .notAsked
        default: speech = .denied
        }
        if CGPreflightScreenCaptureAccess() { screen = .allowed }
        else if screen != .allowed { screen = askedScreen ? .denied : .notAsked }
        hands = AXIsProcessTrusted() ? .allowed : .notAsked
    }

    private static func map(_ s: AVAuthorizationStatus) -> Access {
        switch s {
        case .authorized: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    func allow(_ which: String) {
        switch which {
        case "mic":
            if mic == .denied { openPrivacy("Privacy_Microphone"); return }
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refreshAccess() } }
        case "speech":
            if speech == .denied { openPrivacy("Privacy_SpeechRecognition"); return }
            SFSpeechRecognizer.requestAuthorization { _ in DispatchQueue.main.async { self.refreshAccess() } }
        case "screen":
            // The first time macOS shows its own prompt; after that only System Settings can turn it on.
            if askedScreen { openPrivacy("Privacy_ScreenCapture") } else { _ = CGRequestScreenCaptureAccess() }
            askedScreen = true
            saveProgress()
            checkScreenSoon()
        case "hands":
            if hands == .notAsked, !Computer.trusted { Computer.requestAccess() } else { openPrivacy("Privacy_Accessibility") }
        default: break
        }
    }

    /// Screen Recording often isn't seen until Poinky reopens; this tries the real capture once.
    func checkScreenSoon() {
        Task { @MainActor in
            if await ScreenCapture.hasPermission() { screen = .allowed }
        }
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    /// Restarts Poinky (Screen Recording takes effect only after that); the tour reopens on this page.
    func restartApp() {
        saveProgress()
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Claude Code

    func checkClaude() {
        claude = .checking
        let explicit = AppConfig.load().claudePath
        if AppConfig.load().brain == .api, !AppConfig.load().apiKey.isEmpty { claude = .ready("API key"); return }
        let path = ClaudeCodeBrain.findClaude(explicit: explicit)
        DispatchQueue.global().async {
            let state = Self.claudeState(path: path)
            DispatchQueue.main.async { self.claude = state; Timeline.log("welcome.claude", ["state": "\(state)"]) }
        }
    }

    nonisolated static func claudeState(path: String?) -> ClaudeState {
        guard let path else { return .missing }
        let version = run(path, ["--version"], timeout: 10)?.split(separator: " ").first.map(String.init) ?? ""
        guard let status = run(path, ["auth", "status"], timeout: 10) else { return .unsure(version) }
        let s = status.lowercased().replacingOccurrences(of: " ", with: "")
        if s.contains("\"loggedin\":true") { return .ready(version) }
        if s.contains("\"loggedin\":false") || s.contains("notloggedin") || s.contains("notsignedin") { return .signedOut }
        return .unsure(version)
    }

    nonisolated private static func run(_ path: String, _ args: [String], timeout: Double) -> String? {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return String(data: data, encoding: .utf8)
    }

    /// Opens Terminal with one command (installing or signing in to Claude Code), then checks again
    /// whenever you come back to Poinky.
    func runInTerminal(_ command: String, title: String) {
        let url = AppConfig.dir.appendingPathComponent("poinky-\(title).command")
        let script = "#!/bin/zsh -l\nclear\necho 'Poinky: \(title.replacingOccurrences(of: "-", with: " "))…'\n\(command)\necho\necho 'All set. You can close this window and go back to Poinky.'\n"
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
    func installClaude() { runInTerminal("curl -fsSL https://claude.ai/install.sh | bash && ~/.local/bin/claude", title: "install-claude") }
    func signIn() {
        let path = ClaudeCodeBrain.findClaude(explicit: AppConfig.load().claudePath) ?? "claude"
        runInTerminal("'\(path)'", title: "sign-in")
    }

    // MARK: What you did (from CallController)

    func did(_ e: Event) {
        switch e {
        case .asked: asked = true
        case .answered: if asked { answered = true }
        case .tapped: tapped = true
        case .typed: typed = true
        case .reset: break
        }
    }

    // MARK: Progress

    static var stateURL: URL { AppConfig.dir.appendingPathComponent("welcome.json") }
    private struct Saved: Codable { var done: Bool; var page: Int; var askedScreen: Bool? }

    /// Should the tour open at launch, and where? A brand-new install (no settings yet) or a tour
    /// that was left halfway (e.g. restarted for Screen Recording). Call before the settings are created.
    static func pageToResume(configExisted: Bool) -> Page? {
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            return s.done ? nil : Page(rawValue: s.page) ?? .hello
        }
        if configExisted { markDone(); return nil }   // someone who used Poinky before this tour existed
        return .hello
    }

    func saveProgress() { if fixing { return }; Self.write(Saved(done: false, page: page.rawValue, askedScreen: askedScreen)) }
    static func markDone() { write(Saved(done: true, page: 0, askedScreen: nil)) }
    private static func write(_ s: Saved) {
        try? FileManager.default.createDirectory(at: AppConfig.dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: stateURL, options: .atomic) }
    }
    func loadSaved() {
        if let data = try? Data(contentsOf: Self.stateURL), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            askedScreen = s.askedScreen ?? false
        }
    }

    /// Opened to fix one thing (a permission, Claude Code) instead of as the tour: one page, then Done.
    @Published var fixing = false
    /// The natural voice isn't installed and you speak English (the only language it has).
    var wantsVoice: Bool {
        let cfg = AppConfig.load()
        return cfg.voiceEngine == "phonon" && cfg.language.lowercased().hasPrefix("en")
            && (!PhononVoice.isInstalled || PhononInstaller.shared.state != .idle)
    }

    func go(_ p: Page) {
        page = p
        if !fixing { saveProgress() }
        if p == .permissions { refreshAccess() }
        if p == .claude, claude == .checking || claude == .missing || claude == .signedOut { checkClaude() }
    }
    func next() {
        if fixing { onFinish(); return }
        if let n = Page(rawValue: page.rawValue + 1) { go(n) } else { finish() }
    }
    func back() { if let p = Page(rawValue: page.rawValue - 1) { go(p) } }
    func finish() { Self.markDone(); onFinish() }
}

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    let model = WelcomeModel()
    private var window: NSWindow?
    private var poll: Timer?
    private var activeObserver: Any?

    var isOpen: Bool { window?.isVisible == true }

    func show(at page: WelcomeModel.Page = .hello, fixing: Bool = false) {
        model.fixing = fixing
        model.loadSaved()
        keys()
        model.onOpenSettings = { SettingsWindowController.shared.show(tab: $0) }
        model.page = page
        model.refreshAccess()
        model.checkClaude()
        model.asked = false; model.answered = false; model.tapped = false; model.typed = false
        model.onFinish = { [weak self] in self?.close() }
        if window == nil {
            let host = NSHostingController(rootView: WelcomeView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Poinky"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        model.saveProgress()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        ScreenCapture.tourWindowNumber = window?.windowNumber
        // Permissions change in System Settings: keep the checkmarks current while the tour is open.
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.page == .permissions || self.model.page == .tryIt else { return }
                self.model.refreshAccess()
                if self.model.askedScreen, self.model.screen != .allowed { self.model.checkScreenSoon() }
            }
        }
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isOpen, self.model.page == .claude, self.model.claude != .checking else { return }
                    if case .ready = self.model.claude { return }
                    self.model.checkClaude()
                }
            }
        }
    }

    /// The keys as you set them (Settings → General), for the keycaps.
    private func keys() {
        let cfg = AppConfig.load()
        let hold = PushToTalk.displayString(cfg.pushToTalk)
        model.holdKeys = hold == "Off" ? HotKey.displayString(cfg.hotkey) : hold
        model.typeKeys = HotKey.displayString(cfg.typeHotkey)
    }

    /// Something a new user can't get past without help: open the page that fixes it. Mid-tour, it just
    /// turns to that page.
    func offerFix(_ page: WelcomeModel.Page, askedScreen: Bool = false) {
        Timeline.log("welcome.fix", ["page": "\(page)", "open": isOpen])
        if isOpen {
            if model.fixing { model.page = page } else { model.go(page) }
            if askedScreen { model.askedScreen = true }
            model.refreshAccess()
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
            return
        }
        show(at: page, fixing: true)
        if askedScreen { model.askedScreen = true; model.refreshAccess() }
    }
    /// A question failed: Claude Code missing or not signed in opens its page with the button that fixes it.
    func offerFix(for error: Error) {
        let line = SpokenError.line(for: error)
        if line == SpokenError.notSignedIn || line == SpokenError.notInstalled { offerFix(.claude) }
    }

    func close() {
        poll?.invalidate(); poll = nil
        window?.close()
    }

    /// Closing the window yourself counts as skipping: it won't open by itself again. (Quitting doesn't:
    /// macOS's "Quit & Reopen" after Screen Recording comes back to the tour.)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        WelcomeModel.markDone()
        return true
    }
    func windowWillClose(_ notification: Notification) {
        poll?.invalidate(); poll = nil
        ScreenCapture.tourWindowNumber = nil
    }

    /// `--welcome-shot <outdir>`: every page as a picture (welcome-1-hello.png …), plus the Claude page
    /// in each state and the permissions page with everything allowed, then quit.
    func snapshot(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let m = model
        keys()
        m.refreshAccess()
        var shots: [(String, () -> Void)] = []
        for p in WelcomeModel.Page.allCases {
            shots.append(("\(p.rawValue + 1)-\(p)", { m.page = p; m.claude = .missing }))
        }
        shots.append(("2a-permissions-new", { m.page = .permissions; m.mic = .notAsked; m.speech = .notAsked; m.screen = .notAsked; m.hands = .notAsked }))
        shots.append(("2b-permissions-allowed", { m.page = .permissions; m.mic = .allowed; m.speech = .allowed; m.screen = .denied; m.hands = .allowed; m.askedScreen = true }))
        shots.append(("2c-permissions-done", { m.page = .permissions; m.mic = .allowed; m.speech = .allowed; m.screen = .allowed }))
        shots.append(("3b-claude-signed-out", { m.page = .claude; m.claude = .signedOut }))
        shots.append(("3c-claude-ready", { m.page = .claude; m.claude = .ready("2.1.300") }))
        shots.append(("4b-try-done", { m.page = .tryIt; m.asked = true; m.answered = true }))
        shots.append(("5b-tips-done", { m.page = .tips; m.tapped = true; m.typed = true }))
        shots.append(("6-fix-claude", { m.fixing = true; m.page = .claude; m.claude = .signedOut }))
        let host = NSHostingView(rootView: WelcomeView(model: m).background(Color(nsColor: .windowBackgroundColor)))
        let w = NSWindow(contentRect: CGRect(x: -3000, y: 0, width: 560, height: 480),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        // POINKY_SHOT_DARK=1: the dark-mode version.
        w.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["POINKY_SHOT_DARK"] == "1" ? .darkAqua : .aqua)
        w.contentView = host
        w.orderFrontRegardless()
        func shoot(_ i: Int) {
            guard i < shots.count else { NSApp.terminate(nil); return }
            shots[i].1()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: outDir).appendingPathComponent("welcome-\(shots[i].0).png"))
                }
                shoot(i + 1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { shoot(0) }
    }
}

// MARK: - Views

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.page {
                case .hello: HelloPage(model: model)
                case .permissions: PermissionsPage(model: model)
                case .claude: ClaudePage(model: model)
                case .tryIt: TryPage(model: model)
                case .tips: TipsPage(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .transition(.opacity)
            .id(model.page)
            Divider()
            HStack {
                if model.fixing {
                    EmptyView()
                } else if model.page == .hello {
                    Button("Skip the tour") { model.finish() }.buttonStyle(.link)
                } else {
                    Button("Back") { withAnimation(.spring(duration: 0.35)) { model.back() } }
                }
                Spacer()
                if !model.fixing { HStack(spacing: 6) {
                    ForEach(WelcomeModel.Page.allCases, id: \.rawValue) { p in
                        Circle().fill(p == model.page ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                .accessibilityLabel("Step \(model.page.rawValue + 1) of \(WelcomeModel.Page.allCases.count)") }
                Spacer()
                Button(nextTitle) { withAnimation(.spring(duration: 0.35)) { model.next() } }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 480)
    }

    private var nextTitle: String {
        if model.fixing { return "Done" }
        switch model.page {
        case .hello: return "Let's start"
        case .permissions: return model.nextNeeded == nil ? "Continue" : "Later"
        case .claude: if case .ready = model.claude { return "Continue" }; return "Later"
        case .tryIt: return model.asked ? "Continue" : "Skip"
        case .tips: return "Done"
        }
    }
}

private struct PageTitle: View {
    let symbol: String, title: String, text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 30, weight: .medium)).foregroundStyle(Color.accentColor)
            Text(title).font(.system(size: 22, weight: .semibold))
            Text(text).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 14)
    }
}

/// Keys drawn as little keycaps: "⌃⌥" → [⌃] [⌥].
struct KeyCaps: View {
    let keys: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Self.split(keys).enumerated()), id: \.offset) { _, k in
                Text(k).font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
            }
        }
    }
    static func split(_ s: String) -> [String] {
        var out: [String] = [], word = ""
        for ch in s {
            if "⌃⌥⇧⌘".contains(ch) { if !word.isEmpty { out.append(word); word = "" }; out.append(String(ch)) } else { word.append(ch) }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }
}

private struct HelloPage: View {
    @ObservedObject var model: WelcomeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(symbol: "sparkles", title: "Hi, I'm Poinky.",
                      text: "Ask me about anything on your screen: a lecture slide, a confusing paragraph, a math problem, an email you're writing. I answer out loud and point at things or sketch on the screen while I explain.")
            HStack(spacing: 10) {
                KeyCaps(keys: model.holdKeys)
                Text("Hold these two keys, ask, and let go. That's all.").font(.callout)
            }
            Text("This tour takes about a minute: a few permissions, then you'll ask me your first question.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct AccessRow: View {
    let symbol: String, title: String, why: String
    let access: WelcomeModel.Access
    let isNext: Bool
    var optional = false
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 26).foregroundStyle(access == .allowed ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title + (optional ? " (optional)" : "")).font(.headline)
                Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if access == .allowed {
                Label("Allowed", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green).font(.callout)
            } else if isNext || optional {
                Button(access == .denied ? "Open Settings" : "Allow…", action: action)
                    .buttonStyle(.borderedProminent).tint(optional ? .gray : .accentColor)
            } else {
                Text("Next").font(.callout).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .opacity(isNext || access == .allowed || optional ? 1 : 0.55)
    }
}

private struct PermissionsPage: View {
    @ObservedObject var model: WelcomeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PageTitle(symbol: "lock.shield", title: "A few permissions",
                      text: "macOS asks before an app can hear or see. Everything stays on your Mac until you ask a question.")
            AccessRow(symbol: "mic", title: "Microphone", why: "To hear your question. It's on only while you hold the keys.",
                      access: model.mic, isNext: model.nextNeeded == "mic") { model.allow("mic") }
            AccessRow(symbol: "waveform", title: "Speech Recognition", why: "Turns what you say into words, on this Mac.",
                      access: model.speech, isNext: model.nextNeeded == "speech") { model.allow("speech") }
            AccessRow(symbol: "rectangle.dashed", title: "Screen Recording",
                      why: model.askedScreen && model.screen != .allowed
                        ? "In System Settings, turn Poinky on in the list. If it's already on, restart Poinky."
                        : "So I can see what you're asking about. I take one picture when you ask, never a video.",
                      access: model.screen, isNext: model.nextNeeded == "screen") { model.allow("screen") }
            AccessRow(symbol: "cursorarrow.click", title: "Accessibility",
                      why: "Only if you want me to click and type for you. You can turn this on later.",
                      access: model.hands, isNext: false, optional: true) { model.allow("hands") }
            if model.askedScreen, model.screen != .allowed {
                HStack {
                    Text("Turned Screen Recording on? macOS needs Poinky to reopen.").font(.callout)
                    Spacer()
                    Button("Restart Poinky") { model.restartApp() }
                }
                .padding(.top, 8)
            }
        }
    }
}

private struct ClaudePage: View {
    @ObservedObject var model: WelcomeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(symbol: "brain", title: "My brain is Claude",
                      text: "I use Claude Code, which comes with a Claude subscription (Pro or Max). It runs quietly in the background; you never need to open it.")
            HStack(alignment: .top, spacing: 12) {
                icon
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if hasButtons { HStack(spacing: 10) {
                        switch model.claude {
                        case .missing:
                            Button("Install Claude Code") { model.installClaude() }.buttonStyle(.borderedProminent)
                            Button("Check again") { model.checkClaude() }
                        case .signedOut:
                            Button("Sign in…") { model.signIn() }.buttonStyle(.borderedProminent)
                            Button("Check again") { model.checkClaude() }
                        case .unsure:
                            Button("Sign in…") { model.signIn() }
                            Button("Check again") { model.checkClaude() }
                        default: EmptyView()
                        }
                    }
                    .padding(.top, 4) }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
            if model.claude != .checking, !isReady {
                Button("I have an Anthropic API key instead") { model.onOpenSettings("claude") }.buttonStyle(.link).font(.callout)
            }
            if !model.fixing, model.wantsVoice { VoiceRow() }
        }
    }

    private var isReady: Bool { if case .ready = model.claude { return true }; return false }
    private var hasButtons: Bool { !isReady && model.claude != .checking }

    @ViewBuilder private var icon: some View {
        switch model.claude {
        case .checking: ProgressView().controlSize(.small).frame(width: 26)
        case .ready: Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green).frame(width: 26)
        case .unsure: Image(systemName: "questionmark.circle").font(.title2).foregroundStyle(.secondary).frame(width: 26)
        default: Image(systemName: "exclamationmark.circle.fill").font(.title2).foregroundStyle(.orange).frame(width: 26)
        }
    }
    private var headline: String {
        switch model.claude {
        case .checking: return "Looking for Claude Code…"
        case .missing: return "Claude Code isn't installed yet"
        case .signedOut: return "Claude Code needs you to sign in"
        case .ready(let v): return v == "API key" ? "Using your API key" : "Claude Code is ready" + (v.isEmpty ? "" : " (version \(v))")
        case .unsure: return "Claude Code is installed"
        }
    }
    private var detail: String {
        switch model.claude {
        case .checking: return "This takes a second."
        case .missing: return "The button opens Terminal and installs it (about a minute). When it asks, sign in with your Claude account in the browser, then come back here."
        case .signedOut: return "The button opens Terminal. Choose to sign in with your Claude account, finish in the browser, then come back here."
        case .ready: return "All set."
        case .unsure: return "I couldn't tell if it's signed in. If your first question doesn't get an answer, click Sign in."
        }
    }
}

/// The natural voice, if it isn't installed yet (English only): it downloads in the background while
/// you finish the tour. Same installer as Settings → Voice.
private struct VoiceRow: View {
    @ObservedObject var installer = PhononInstaller.shared
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: installer.state == .done ? "checkmark.circle.fill" : "waveform.circle")
                .font(.title2).foregroundStyle(installer.state == .done ? .green : .secondary).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text("A more natural voice (optional)").font(.headline)
                switch installer.state {
                case .running:
                    ProgressView(value: installer.progress)
                    Text(installer.step.isEmpty ? "Downloading…" : installer.step).font(.caption).foregroundStyle(.secondary)
                case .done:
                    Text("Installed. I'll use it from your next question.").font(.callout).foregroundStyle(.secondary)
                case .failed:
                    Text("The download didn't finish. You can try again here or in Settings → Voice.").font(.callout).foregroundStyle(.secondary)
                case .idle:
                    Text("Sounds much more human than the built-in voice. A 75 MB download that runs on this Mac; it keeps going while you finish.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if installer.state == .idle { Button("Install") { installer.start() } }
            if case .failed = installer.state { Button("Try again") { installer.start() } }
        }
        .padding(.horizontal, 14)
    }
}

private struct TryPage: View {
    @ObservedObject var model: WelcomeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(symbol: "hand.point.up.left", title: "Ask your first question",
                      text: "Here's something to ask about. Hold the keys, say your question, and let go.")
            HStack(alignment: .center, spacing: 18) {
                Sample()
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) { KeyCaps(keys: model.holdKeys); Text("hold").font(.callout).foregroundStyle(.secondary) }
                    Text("“How do I solve this?”").font(.title3.italic())
                    Text("then let go").font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Check(done: model.asked, text: "I heard you")
                Check(done: model.answered, text: "I answered (and pointed at the screen)")
            }
            if model.screen != .allowed || model.mic != .allowed {
                Text("I still need the Microphone and Screen Recording permissions for this. Go Back to allow them.")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }
}

/// A small homework problem to ask about, drawn here so the screenshot has something real to explain.
private struct Sample: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Homework, question 3").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("2x + 3 = 11").font(.system(size: 30, weight: .medium, design: .serif))
            Text("Find x.").font(.system(size: 15, design: .serif))
        }
        .padding(18)
        .frame(width: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.3), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

private struct Check: View {
    let done: Bool, text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary)
                .contentTransition(.symbolEffect(.replace))
            Text(text).foregroundStyle(done ? .primary : .secondary)
        }
        .font(.callout)
        .animation(.spring(duration: 0.35), value: done)
    }
}

private struct TipsPage: View {
    @ObservedObject var model: WelcomeModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(symbol: "lightbulb", title: "Three things worth knowing",
                      text: "Try them now if you like; the circles fill in when you do.")
            Tip(done: model.tapped, keys: model.holdKeys, title: "Tap to stop me",
                text: "A quick tap of the same keys stops me mid-sentence. Hold them again to ask something else.")
            Tip(done: model.typed, keys: model.typeKeys, title: "Type instead of talking",
                text: "In a library or on a call? This opens a little box to type your question.")
            Tip(done: false, keys: nil, title: model.hasNotch ? "Your notch is my home" : "I live in the menu bar",
                text: model.hasNotch
                    ? "Move the mouse onto the notch at the top of the screen for my controls and Settings. If I ever get stuck, ↻ there starts me fresh."
                    : "Click ✨ in the menu bar for my controls and Settings. If I ever get stuck, Start Fresh there fixes it.",
                showCircle: false)
        }
    }
}

private struct Tip: View {
    let done: Bool, keys: String?, title: String, text: String
    var showCircle = true
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: showCircle ? (done ? "checkmark.circle.fill" : "circle") : "macbook")
                .font(.title3).foregroundStyle(done ? .green : .secondary).frame(width: 26)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) { Text(title).font(.headline); if let keys { KeyCaps(keys: keys) } }
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.spring(duration: 0.35), value: done)
    }
}
