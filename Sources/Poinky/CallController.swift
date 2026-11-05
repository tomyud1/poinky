import AppKit
import AVFoundation

/// Runs a session with Claude, in one of two modes:
///   - hold-to-talk (default): hold ⌃⌥ and talk, let go to send. The mic is on only while you hold.
///   - hands-free call (⌃⌥Space): the mic stays on; a pause ends your question, talk over Claude to interrupt.
/// Either way: you talk → screenshot → the talker answers out loud (sentence by sentence) and marks the screen
///                                   → if a picture helps, the artist draws a card or 3D model in parallel.
@MainActor
final class CallController: NSObject, NSMenuDelegate {
    enum State { case idle, starting, ready, listening, thinking, speaking }
    enum Mode { case handsFree, push }

    private var config = AppConfig.load()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let audio = AudioIO()
    private let listener = SpeechListener()
    private let speaker = Speaker()
    private let phonon = PhononVoice()      // stays loaded between calls so it starts instantly
    private let overlay = Overlay()
    private lazy var helperScreen = HelperScreen(overlay: overlay, agents: agents)   // helpers (agents) on screen
    private let home = NotchHome()            // the status + controls at the notch
    private let agents = AgentManager()       // background Claude Code agents
    private let helperWindows = HelperWindows()   // each helper's own window (its transcript and a box to type to it)
    private let typeBox = TypeBox()               // typing to Poinky instead of talking (⌃⌥T)
    private let away = AwayNotifier()             // away from the Mac: helpers' questions go to your phone (opt-in)
    private var typeHotKey: HotKey?
    private var typedAfterStart: (text: String, helper: Int?)?   // typed while no session was running
    private var pendingLine: String?              // a short line to say once a session is up
    private var agentReports: [(id: Int, text: String)] = []   // finished agents the user hasn't heard about yet
    private var reportingIDs: [Int] = []       // helpers next to the buddy while Poinky tells you what they did
    private var reportAfterStart = false      // a session is starting just to tell the user about an agent
    private var reportCheckPending = false    // waiting for a pause in typing
    private var talkTarget: Int?              // the helper you're pointing at while holding the keys (you're talking to it)
    private var helperContext: String?        // for the talker: you asked a finished helper something
    private var askingNow: Int?               // the helper next to the buddy with its hand up, waiting for your answer
    private var askSpoken: String?            // its request that Poinky already said out loud
    private var askAfterStart = false         // a session is starting just to say a helper's question
    private var askCheckPending = false
    private var parkWork: DispatchWorkItem?   // no answer for a while: it goes back to the edge
    private var endAfterSpeaking = false      // the user said goodbye
    private var buddyHidden = false           // ⌃⌥B or auto-hide: hidden until the next question
    private var buddyHotKey: HotKey?
    private var talker: Brain?
    private var artist: Brain?
    private var hotKey: HotKey?
    private var goodVoice = true
    private var mode: Mode = .handsFree
    private let ptt = PushToTalk()
    private var pushCommitted = false         // you're holding the talk keys (past the short delay)
    private var pushGen = 0                   // changes with every hold
    private var lastActivity: TimeInterval = 0
    private static let idleTimeout: TimeInterval = 15 * 60   // a hold-to-talk session ends after this long unused
    /// Where the session rests between questions.
    private var restingState: State { mode == .push ? .ready : .listening }

    private var callID = 0               // changes every call, so late results from an old call are ignored
    private var turn = 0                 // changes every question, so interrupted replies are ignored
    private var talkTask: Task<Void, Never>?
    private var parser = TalkParser()
    private var replyScale: CGFloat = 1
    private var lastQuestion = ""
    private var lastSnapshot: Snapshot?
    private var mergeNext = false        // you kept talking: add the next words to the last question
    private var lastAskAt: TimeInterval = 0
    private var spokenCaption = ""
    private var history: [(user: String, assistant: String)] = []

    private struct ArtistJob { let text: String; let snapshot: Snapshot }
    private var artistBusy = false
    private var artistWaiting: ArtistJob?    // only the newest waiting request is kept
    private var artistRetries: [String: Int] = [:]
    private var artistGen = 0                // changes when an artist job is cancelled

    // Lessons: each spoken line gets a tag; its drawing step waits until that line is heard.
    private var lessonToken = 0              // changes when a lesson is interrupted
    private var lessonOpen = false
    private var nextTag = 0
    private var currentTag: Int?
    private var startedTags: Set<Int> = []
    private enum PendingStep { case paper(String), model(id: String, code: String) }
    private var pendingSteps: [Int: [PendingStep]] = [:]
    private var narrationOpen = false        // the teacher is adding spoken lines to the voice
    private var lessonScale: CGFloat = 1
    private var focusRegion: CGRect?          // what's being explained (screen points): the paper and captions avoid it
    private var pendingFocus: FocusCrop?      // close-up of what you marked, taken when you marked it
    private var focusTask: Task<Void, Never>?
    private var anchor: (id: CGWindowID, origin: CGPoint)?   // the window the drawings belong to
    private var anchorTick = 0
    private var lastShift = CGPoint.zero
    private var clearedForUtterance = false
    private var teacherStartedTurn = -1       // the teacher was started in parallel for this turn
    private var captionFade: DispatchWorkItem?
    private var markFade: DispatchWorkItem?   // quick marks fade once Claude is done explaining

    // Guide mode: one step at a time, waiting for your click.
    private struct Guide {
        var goal: String; var context: [String] = []; var steps: [String] = []; var target: CGRect?
        var acting = false            // Poinky clicks and types itself (otherwise it shows you and you click)
        var acts: [String] = []       // this step's actions, run when the reply is complete
        var ask: String?              // this step's question; wait for the answer
        var waiting = false           // waiting for you to answer
        var riskyTarget: String?      // a click that needs your OK ("Send")
        var confirmed = false         // you said yes: the next step may do it
        var count = 0                 // steps taken (a runaway stops at 40)
        var ui = AppReader.Reading()  // (acting) the front app's buttons, fields and menus at the last look
    }
    private var guide: Guide?
    private var guideBrain: Brain?
    private var doerBrain: Brain?
    private var guideBusy = false
    private var guideRerun: String?           // something happened while a step was being prepared
    private var guideLine = ""
    private var clickMonitor: Any?
    private var guideClickWork: DispatchWorkItem?

    private var mouseTimer: Timer?
    private var scrollMonitor: Any?

    private var state: State = .idle { didSet { updateUI() } }

    // MARK: - Setup

    func setup() {
        listener.onPartial = { [weak self] text in self?.heard(partial: text) }
        listener.onUtterance = { [weak self] text in self?.heard(utterance: text) }
        listener.onStatus = { [weak self] msg in self?.overlay.setClaudeCaption(msg) }
        speaker.onTurnFinished = { [weak self] in self?.finishedSpeaking() }
        // Captions follow the voice: each sentence appears as it's spoken.
        speaker.onSentenceStarted = { [weak self] sentence, tag in
            guard let self, self.state != .idle else { return }
            self.spokenCaption = self.spokenCaption.isEmpty ? sentence : self.spokenCaption + " " + sentence
            self.home.model.lastLine = sentence
            self.overlay.setClaudeCaption(self.spokenCaption)
            // A lesson line just started: draw what goes with it.
            if let tag {
                self.startedTags.insert(tag)
                for step in self.pendingSteps.removeValue(forKey: tag) ?? [] { self.play(step) }
            }
        }
        overlay.onCardError = { [weak self] id, type, message in self?.cardFailed(id: id, type: type, message: message) }
        overlay.onClear = { [weak self] in self?.clearAll() }
        // Take the close-up of what you circled right away, so it still works if you scroll before asking.
        overlay.onMarkAdded = { [weak self] in
            guard let self, self.state != .idle, let screen = self.overlay.screen else { return }
            self.focusTask?.cancel()
            let marks = self.overlay.marks
            self.focusTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)   // wait in case you add another mark
                guard !Task.isCancelled else { return }
                if let crop = await ScreenCapture.focusCrop(screen: screen, marks: marks), !Task.isCancelled {
                    self.pendingFocus = crop
                }
            }
        }

        registerHotKey()
        ptt.onDown = { [weak self] in self?.pushDown() }
        ptt.onCommit = { [weak self] in self?.pushCommit() }
        ptt.onUp = { [weak self] send in self?.pushUp(send: send) }
        ptt.onTap = { [weak self] in self?.pushTap() }
        agents.onFinished = { [weak self] a in self?.helperScreen.finished(a); self?.askEnded(a.id); self?.agentFinished(a) }
        agents.onChange = { [weak self] in self?.refreshAgentsInHome(); self?.helperWindows.updateAll() }
        agents.onEntry = { [weak self] a, e in self?.helperWindows.entry(a, e) }
        agents.onHands = { [weak self] id in
            guard let self, let id else { return }
            self.overlay.helperStep(id: id, text: "Using your mouse and keyboard")
        }
        helperWindows.agents = agents
        helperWindows.onAnswer = { [weak self] id, rid, yes in self?.windowAnswer(id, rid, yes) }
        helperWindows.onTypedAnswer = { [weak self] id, reply, _ in self?.answerAsk(id, reply, said: nil) }
        helperWindows.onPause = { [weak self] id in _ = self?.helperScreen.talk(to: id, .pause) }
        helperWindows.onResume = { [weak self] past, text in
            guard let self else { return nil }
            return self.agents.resume(past, text: text, config: self.config)
        }
        helperScreen.onOpen = { [weak self] id in self?.helperWindows.show(id) }
        typeBox.onSend = { [weak self] text, helper in self?.typed(text, helper: helper) }
        agents.onStarted = { [weak self] a in self?.helperScreen.started(a) }
        agents.onEvent = { [weak self] a, e in self?.helperScreen.event(a, e) }
        agents.onStopped = { [weak self] a in self?.helperScreen.stopped(id: a.id); self?.askEnded(a.id) }
        agents.onAsksChanged = { [weak self] a in
            guard let self else { return }
            self.helperScreen.asksChanged(a)
            if a.asks.isEmpty { self.askEnded(a.id) }
            self.away.stillOpen(Set(self.agents.agents.flatMap { $0.asks.map(\.requestID) }))
            if let first = a.asks.first { self.away.asking(a, first) }
        }
        away.settings(config)
        away.onAnswer = { [weak self] id, rid, reply in self?.phoneAnswer(id, rid, reply) }
        overlay.onHelperAsking = { [weak self] id in self?.helperAsking(id) }
        helperScreen.onCardAnswer = { [weak self] id, yes in self?.cardAnswer(id, yes) }
        helperScreen.settings(config)
        ptt.configure(config.pushToTalk)
        ScreenCapture.excludedBundleIDs = Set(config.excludedApps)
        let settings = SettingsWindowController.shared.model
        settings.onSaved = { [weak self] cfg in self?.settingsChanged(cfg) }
        settings.previewVoice = { [weak self] voice, speed in self?.previewVoice(voice: voice, speed: speed) }
        // Load the local voice in the background now, so the first call doesn't wait for it.
        if wantsPhonon(config) { try? phonon.start() }
        PhononInstaller.shared.onInstalled = { [weak self] in self?.voiceInstalled() }
        // Updating from the old Kokoro voice: it's replaced by Phonon, which installs itself in the
        // background (~75 MB; Apple's voice speaks until it's ready).
        if config.voiceEngine == "phonon", !PhononVoice.isInstalled,
           FileManager.default.fileExists(atPath: PhononVoice.oldKokoroDir.path) {
            PhononInstaller.shared.start()
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        setupHome()
        TextIndex.warmUp()   // the first text recognition after a restart can be slow: get it out of the way
        updateUI()
    }

    /// The notch: status while active, controls when you hover it.
    private func setupHome() {
        let m = home.model
        m.onCall = { [weak self] in self?.home.collapse(); self?.toggleCall() }
        m.onEnd = { [weak self] in self?.home.collapse(); self?.endCall() }
        m.onClear = { [weak self] in self?.clearAll() }
        m.onTeacher = { [weak self] in self?.toggleArtist() }
        m.onBuddy = { [weak self] in self?.toggleBuddy() }
        m.onSettings = { [weak self] in self?.home.collapse(); self?.openSettings() }
        m.onQuit = { NSApp.terminate(nil) }
        m.onOpenReport = { [weak self] r in
            self?.home.collapse()
            self?.helperWindows.show(log: r.log)
        }
        refreshHomeLabels()
        home.show()
    }

    private func refreshHomeLabels() {
        let m = home.model
        m.holdKeys = PushToTalk.displayString(config.pushToTalk)
        m.callKeys = HotKey.displayString(config.hotkey)
        m.teacherOn = config.artistEnabled
        statusItem.isVisible = config.menuBarIcon || NotchHome.notchScreen == nil
    }

    private func registerHotKey() {
        buddyHotKey = HotKey(spec: config.buddyHotkey) { [weak self] in
            MainActor.assumeIsolated {
                self?.ptt.cancel()
                self?.toggleBuddy()
            }
        }
        typeHotKey = HotKey(spec: config.typeHotkey) { [weak self] in
            MainActor.assumeIsolated {
                self?.ptt.cancel()   // ⌃⌥T starts with ⌃⌥: that wasn't talking
                self?.openTypeBox()
            }
        }
        hotKey = HotKey(spec: config.hotkey) { [weak self] in
            MainActor.assumeIsolated {
                self?.ptt.cancel()   // ⌃⌥Space starts with ⌃⌥: that wasn't talking
                self?.toggleCall()
            }
        }
        if hotKey == nil {
            showAlert("Couldn't register the shortcut “\(config.hotkey)”.",
                      info: "Another app may be using it. Change \"hotkey\" in the settings file, then quit and reopen Poinky.")
        }
    }

    // MARK: - Call lifecycle

    @objc func toggleCall() {
        if state == .idle { startSession(.handsFree) }
        else if mode == .push { switchToHandsFree() }
        else { endCall() }
    }

    func startCall() { startSession(.handsFree) }

    /// Quitting: stop background agents too (nothing would hear their results).
    func shutdown() {
        agents.stopAll()
        endCall(quietly: true)
    }

    func startSession(_ newMode: Mode) {
        guard state == .idle else { return }
        mode = newMode
        state = .starting
        callID += 1
        lastActivity = ProcessInfo.processInfo.systemUptime
        let myCall = callID
        Task { @MainActor in
            guard await SpeechListener.requestPermissions() else {
                state = .idle
                showAlert("Poinky needs Microphone and Speech Recognition access.",
                          info: "Turn both on for Poinky in System Settings → Privacy & Security.",
                          settingsPane: "Privacy_Microphone")
                return
            }
            guard await ScreenCapture.hasPermission() else {
                state = .idle
                ScreenCapture.requestPermission()
                showAlert("Poinky needs Screen Recording access to see your screen.",
                          info: "Turn it on in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Poinky.",
                          settingsPane: "Privacy_ScreenCapture")
                return
            }

            config = AppConfig.load()
            goodVoice = speaker.configure(language: config.language, voiceName: config.voice, rate: config.speechRate)
            // The free local neural voice (English only); Apple's voice is the fallback.
            speaker.phonon = nil
            if wantsPhonon(config) {
                do {
                    try phonon.start()
                    speaker.phonon = phonon
                    speaker.phononVoice = config.phononVoice
                    speaker.voiceSpeed = config.voiceSpeed
                    goodVoice = true
                } catch {
                    NSLog("Poinky: local voice failed to start: \(error.localizedDescription)")
                }
            }
            listener.silenceSeconds = config.silenceSeconds
            do {
                talker = try BrainFactory.make(config: config, role: .talker)
                artist = config.artistEnabled ? try BrainFactory.make(config: config, role: .artist) : nil
            } catch {
                state = .idle
                showAlert("Couldn't start the brain.", info: error.localizedDescription)
                return
            }

            overlay.show(on: screenWithMouse())
            overlay.setBuddy(config.buddy)
            overlay.setCaption(you: nil, claude: nil)
            updateUI()
            speaker.attach(audio)
            let startedWithMic = mode == .handsFree
            listener.autoEnd = startedWithMic
            do {
                try audio.start(mic: startedWithMic)
                try await listener.start(audio: audio, language: config.language)
            } catch {
                endCall()
                showAlert("Couldn't start listening.", info: error.localizedDescription)
                return
            }
            guard myCall == callID, state == .starting else { return }

            // Start both Claude sessions in the background while you begin talking.
            for brain in [talker, artist].compactMap({ $0 }) {
                Task { @MainActor in
                    do { try await brain.warmUp() } catch {
                        guard myCall == self.callID else { return }
                        self.overlay.setClaudeCaption("⚠️ \(error.localizedDescription)")
                    }
                }
            }
            startWatchers()
            if mode == .handsFree && !startedWithMic {
                enableHandsFreeAudio()   // ⌃⌥Space was pressed while a hold-to-talk session was starting
                return
            }
            if mode == .handsFree { playSound(.start) }
            state = mode == .push && pushCommitted ? .listening : restingState
            if reportAfterStart {
                reportAfterStart = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.deliverReports() }
            }
            if askAfterStart {
                askAfterStart = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.deliverAsk() }
            }
            if let t = typedAfterStart {
                typedAfterStart = nil
                deliverTyped(t.text, helper: t.helper)
            }
            if let line = pendingLine {
                pendingLine = nil
                sayQuick(line, said: "")
            }
            if !goodVoice {
                overlay.setClaudeCaption("Tip: for a natural voice, download a Premium voice: ✨ menu → Get a Better Voice…")
            }
        }
    }

    func endCall(quietly: Bool = false) {
        guard state != .idle else { return }
        callID += 1
        turn += 1
        talkTask?.cancel()
        talkTask = nil
        pushCommitted = false
        endAfterSpeaking = false
        buddyHidden = false
        releaseReports()
        // A helper asking you goes back to the edge with its hand up (answer it later from its card or by name).
        if let id = askingNow { helperScreen.park(id: id); askingNow = nil; askSpoken = nil }
        parkWork?.cancel(); parkWork = nil
        askAfterStart = false
        typedAfterStart = nil
        pendingLine = nil
        listener.stop()
        speaker.stop()
        audio.stop()
        talker?.stop()
        artist?.stop()
        talker = nil
        artist = nil
        artistBusy = false
        artistWaiting = nil
        artistRetries.removeAll()
        lessonOpen = false
        narrationOpen = false
        pendingSteps.removeAll()
        startedTags.removeAll()
        anchor = nil
        pendingFocus = nil
        focusRegion = nil
        endGuide()
        guideBrain?.stop()
        guideBrain = nil
        doerBrain?.stop()
        doerBrain = nil
        overlay.bakeContent()
        overlay.setContentVisible(true)
        currentTag = nil
        history.removeAll()
        mergeNext = false
        stopWatchers()
        if !quietly, config.sounds {
            // After the audio engine stopped (and echo cancellation let go of the speakers).
            let volume = Float(config.soundVolume)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Earcons.playStandalone(.end, volume: volume) }
        }
        let o = overlay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard self?.state == .idle else { return }   // a new session started meanwhile
            o.hide()
        }
        state = .idle
    }

    /// ⌃⌥Space during a hold-to-talk session: keep everything on screen, turn the mic on for good.
    private func switchToHandsFree() {
        guard mode == .push else { return }
        mode = .handsFree
        // Still starting up: the session picks up the new mode when it gets to the audio.
        guard state != .starting else { return }
        speaker.stop()
        turn += 1
        enableHandsFreeAudio()
    }

    private func enableHandsFreeAudio() {
        audio.stop()
        do {
            try audio.start(mic: true)
        } catch {
            endCall()
            showAlert("Couldn't start listening.", info: error.localizedDescription)
            return
        }
        listener.autoEnd = true
        listener.discardCurrent()
        playSound(.start)
        state = .listening
    }

    private func playSound(_ sound: Earcons.Sound) {
        guard config.sounds, config.soundVolume > 0, let b = Earcons.buffer(sound) else { return }
        let volume = Float(min(1, max(0, config.soundVolume)))
        if !audio.playSound(b, volume: volume) { Earcons.playStandalone(sound, volume: volume) }
    }

    // MARK: - Hold to talk

    private var finishingPush = false   // a released question is still being turned into text

    /// The talk keys went down: open the mic right away (so your first word isn't cut off).
    private func pushDown() {
        // In a hands-free call the mic is already on (⌥ still marks).
        guard !(mode == .handsFree && state != .idle) else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            // First time: ask for the permissions instead of recording.
            if state == .idle { startSession(.push) }
            return
        }
        pushGen += 1
        if !finishingPush { listener.clearText() }
        do { try audio.startMic() } catch {
            NSLog("Poinky: mic failed: \(error.localizedDescription)")
        }
    }

    /// A quick tap of the talk keys: stop Claude (nothing is sent).
    private func pushTap() {
        guard state != .idle, mode == .push else { return }
        // A walkthrough or "doing it for you" stops completely (not just the sentence).
        if guide != nil {
            endGuide()
            speaker.stop()
            overlay.setClaudeCaption(nil)
            state = restingState
            playSound(.cancel)
            return
        }
        switch state {
        case .speaking:
            interrupt(maybeMore: false)
            state = restingState
        case .thinking:
            turn += 1
            speaker.stop()
            clearMarksOnInterrupt()
            stopLesson()
            state = restingState
        default:
            return
        }
        endAfterSpeaking = false
        overlay.setClaudeCaption(nil)
        playSound(.cancel)
    }

    /// Held on purpose (no other key): show that we're listening, and stop Claude if it was talking.
    private func pushCommit() {
        guard audio.micOn else { return }
        lastActivity = ProcessInfo.processInfo.systemUptime
        if state == .idle { startSession(.push) }
        guard mode == .push, state != .idle else { return }
        // Talking on another screen: bring the buddy over (if nothing is drawn on the old one).
        let here = screenWithMouse()
        if here != overlay.screen, overlay.occupiedRects.isEmpty { overlay.show(on: here) }
        pushCommitted = true
        captionFade?.cancel()
        if buddyHidden { setBuddyHidden(false) }
        playSound(.open)
        stopActing(pause: true)
        switch state {
        case .speaking:
            interrupt(maybeMore: false)
        case .thinking:
            // Claude hasn't answered yet: what you say now is the rest of that question.
            turn += 1
            speaker.stop()
            mergeNext = true
            state = .listening
        case .starting:
            break   // becomes .listening when the session is ready
        default:
            state = .listening
        }
        overlay.setYouCaption(nil)
        overlay.setClaudeCaption(nil)
        // Pointing at a helper: what you say goes to it.
        if let id = overlay.pointedHelper, agents.agents.contains(where: { $0.id == id }) {
            talkTarget = id
            overlay.helperListen(id: id, on: true)
        }
    }

    private func endHelperListen() {
        guard let id = talkTarget else { return }
        talkTarget = nil
        overlay.helperListen(id: id, on: false)
    }

    /// Let go: send what you said (or drop it if it was a shortcut or too short).
    private func pushUp(send: Bool) {
        if mode == .handsFree && state != .idle { return }   // a hands-free call hears you anyway
        let myPush = pushGen
        pushCommitted = false
        guard send, mode == .push, state != .idle else {
            audio.stopMic()
            // Settle and throw away whatever was heard (it was a shortcut, not a question).
            if !finishingPush, listener.running { Task { _ = await self.listener.finishUtterance() } }
            if mode == .push, state == .listening { state = restingState }
            endHelperListen()
            return
        }
        finishingPush = true
        Task { @MainActor in
            defer { self.finishingPush = false }
            // Keep the mic a moment longer so the end of your last word isn't clipped.
            try? await Task.sleep(nanoseconds: 180_000_000)
            if myPush == self.pushGen, !self.ptt.isDown { self.audio.stopMic() }
            // The very first hold also started the session: wait for it to be ready.
            var waited = 0
            while self.state == .starting, waited < 100 {
                try? await Task.sleep(nanoseconds: 100_000_000); waited += 1
            }
            guard self.state != .idle, self.mode == .push else { return }
            let text = await self.listener.finishUtterance()
            guard self.state != .idle, self.mode == .push else { return }
            if self.state == .listening, !self.pushCommitted { self.state = self.restingState }
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                self.playSound(.cancel)
                self.overlay.setYouCaption(nil)
                self.mergeNext = false   // nothing was said: don't glue the next question to the last one
                self.endHelperListen()
                return
            }
            self.playSound(.send)
            self.heard(utterance: text)
        }
    }

    // MARK: - Hearing you

    private func heard(partial text: String) {
        guard state != .idle, state != .starting else { return }
        if state == .speaking && isEcho(text) { return }
        // You started talking while it's clicking for you: pause and listen.
        if guide?.acting == true, guide?.waiting == false, text.split(whereSeparator: \.isWhitespace).count >= 2 { stopActing(pause: true) }
        overlay.setYouCaption(text)
        captionFade?.cancel()
        // A new question is starting: clear the last answer's marks right away.
        if state == .listening, !clearedForUtterance, !mergeNext {
            clearedForUtterance = true
            overlay.clearAnnotations()
        }
        let words = text.split(whereSeparator: \.isWhitespace).count
        if state == .speaking && words >= 2 {
            interrupt()
        } else if state == .thinking && words >= 2 {
            // You weren't done: drop the answer in progress and wait for the rest.
            turn += 1
            speaker.stop()
            mergeNext = true
            state = .listening
        }
    }

    private func heard(utterance text: String) {
        guard state != .idle, state != .starting else { return }
        if state == .speaking {
            if isEcho(text) { return }
            interrupt()
        } else if state == .thinking {
            turn += 1
            speaker.stop()
            mergeNext = true
        }
        // A helper is waiting for your answer: a clear yes or no (or a pick) goes straight to it.
        if guide == nil, let (id, reply) = helperScreen.askReply(text, pointing: talkTarget, asking: askingNow) {
            if let t = talkTarget { talkTarget = nil; overlay.helperListen(id: t, on: false) }
            mergeNext = false
            answerAsk(id, reply, said: text)
            return
        }
        // Said to a helper (pointing at it, or by name): handled right here, without the talker.
        if let id = talkTarget {
            talkTarget = nil
            overlay.helperListen(id: id, on: false)
            mergeNext = false
            talkToHelper(id, HelperTalk.intent(text), said: text)
            return
        }
        if guide == nil, let (name, intent) = HelperTalk.byName(text, names: helperNames()),
           let a = helper(named: name) {
            mergeNext = false
            talkToHelper(a.id, intent, said: text)
            return
        }
        let question = mergeNext && !lastQuestion.isEmpty ? lastQuestion + " " + text : text
        mergeNext = false
        clearedForUtterance = false
        if guide != nil {
            // While guiding, what you say goes to the guide ("next", "I did it", a question, "stop").
            let t = text.lowercased()
            let stopWords = ["stop", "cancel", "never mind", "nevermind", "quit", "that's enough", "end the guide", "forget it"]
            if stopWords.contains(where: { t.contains($0) }) {
                endGuide()
                speaker.beginTurn(); speaker.enqueue("Okay, I stopped."); speaker.endTurn()
            } else if let risky = guide?.riskyTarget {
                // The answer to "Should I click Send?"
                let yes = ["yes", "yeah", "yep", "sure", "ok", "okay", "go ahead", "do it", "send it", "please", "confirm", "go for it"]
                    .contains { t.contains($0) } && !["no", "don't", "do not", "wait", "not yet"].contains { t.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
                guide?.confirmed = yes
                guide?.riskyTarget = yes ? risky : nil
                guideStep(action: yes ? "The user said: \"\(text)\". They confirmed: you may now click \(risky)."
                                      : "The user said: \"\(text)\". They did NOT confirm clicking \(risky); don't click it.")
            } else {
                guideStep(action: "The user said: \"\(text)\"")
            }
            return
        }
        ask(question)
    }

    @objc func openHelpers() { helperWindows.showList() }

    /// "Undo what Mint did": puts back the files it changed in its last run, unless one of them changed
    /// after it finished (maybe you did that): then it's left for its window, where you can confirm.
    private func undoHelper(_ past: PastHelper, said: String?) {
        let name = past.name
        func say(_ line: String) {
            if let said { sayQuick(line, said: said) }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.sayWhenFree(line) } }
        }
        agents.undo(past, dryRun: true) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .failed(let why): say("I couldn't undo what \(name) did. \(why)")
            case .done: break
            case .preview(let p):
                if p.files.isEmpty { say("\(name) didn't change any files, so there's nothing to undo."); return }
                if !p.changedSince.isEmpty {
                    say("\(HelperUndo.names(p.changedSince)) changed after \(name) finished, so I didn't undo anything. You can still do it from \(name)'s window.")
                    return
                }
                self.agents.undo(past, dryRun: false) { [weak self] result in
                    switch result {
                    case .done(let files): self?.sayWhenFree("Okay, I put back \(HelperUndo.names(files)) the way \(files.count == 1 ? "it was" : "they were") before \(name) started.")
                    case .failed(let why): self?.sayWhenFree("I couldn't undo what \(name) did. \(why)")
                    case .preview: break
                    }
                }
            }
        }
        if said != nil { overlay.setClaudeCaption("Undoing what \(name) did…") }
    }

    /// A short line now if a session is up, or in a quiet one.
    private func sayWhenFree(_ line: String) {
        if state == .idle {
            pendingLine = line
            startSession(.push)
        } else {
            sayQuick(line, said: "")
        }
    }

    // MARK: - Earlier helpers

    /// Finished helpers, from this run and earlier ones (their saved windows), newest first.
    /// `fromThisRun`: also the finished ones still in memory (the talker already sees those in its list).
    private func pastHelpers(limit: Int, fromThisRun: Bool = true) -> [PastHelper] {
        let finished = agents.agents.filter { $0.status != .running && $0.status != .queued }.reversed().map { agents.past($0) }
        let skip = Set(agents.agents.map(\.chat.place))
        return Array(((fromThisRun ? Array(finished) : []) + PastHelper.list(in: AgentManager.logDir, limit: limit, excluding: skip)).prefix(limit))
    }

    private func pastHelper(key: String) -> PastHelper? {
        pastHelpers(limit: 40).first { $0.key == key || $0.session == key }
    }

    /// "5 minutes ago", "yesterday".
    static func ago(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 90 { return "just now" }
        if s < 3600 { return "\(Int(s / 60)) minutes ago" }
        if s < 2 * 3600 { return "an hour ago" }
        if s < 86400 { return "\(Int(s / 3600)) hours ago" }
        if s < 2 * 86400 { return "yesterday" }
        return "\(Int(s / 86400)) days ago"
    }

    // MARK: - Typing instead of talking

    /// ⌃⌥T: the box to type in, for the helper under the mouse if there is one.
    @objc func openTypeBox() {
        if typeBox.isOpen { typeBox.close(); return }
        if let id = overlay.pointedHelper, let a = agents.agents.first(where: { $0.id == id }),
           a.status == .running || a.status == .queued {
            let hex = HelperWindows.colors[a.name.components(separatedBy: " ")[0]] ?? "#34c98e"
            typeBox.open(helper: (id, a.name, NSColor(hex: hex)))
        } else {
            typeBox.open()
        }
    }

    /// What you typed: the same as saying it (a session starts if none is running).
    private func typed(_ text: String, helper: Int?) {
        lastActivity = ProcessInfo.processInfo.systemUptime
        switch state {
        case .idle:
            typedAfterStart = (text, helper)
            startSession(.push)
        case .starting:
            typedAfterStart = (text, helper)
        default:
            deliverTyped(text, helper: helper)
        }
    }

    private func deliverTyped(_ text: String, helper: Int?) {
        overlay.setYouCaption(text.count > 160 ? String(text.prefix(159)) + "…" : text)
        if let helper, agents.agents.contains(where: { $0.id == helper }) { talkTarget = helper }
        heard(utterance: text)
    }

    /// You started talking while Claude was speaking: stop and listen.
    private func interrupt(maybeMore: Bool = true) {
        turn += 1
        speaker.stop()
        // Talking again within a few seconds of asking usually means you weren't done:
        // treat what you say next as the rest of the same question.
        if maybeMore, ProcessInfo.processInfo.systemUptime - lastAskAt < 6 { mergeNext = true }
        overlay.setClaudeCaption(nil)
        clearMarksOnInterrupt()
        stopLesson()
        state = .listening
    }

    /// Cutting Claude off also takes its marks away (a walkthrough keeps its target).
    private func clearMarksOnInterrupt() {
        markFade?.cancel()
        if guide == nil { overlay.fadeAnnotations() }
    }

    /// You talked over a lesson: stop drawing (what's drawn stays) and free the artist for your next question.
    private func stopLesson() {
        guard lessonOpen || narrationOpen || !pendingSteps.isEmpty || artistBusy else { return }
        lessonToken += 1
        lessonOpen = false
        narrationOpen = false
        pendingSteps.removeAll()
        currentTag = nil
        overlay.lessonStop()
        if artistBusy, let old = artist {
            // Restart the artist so it doesn't keep writing a lesson nobody is listening to.
            artistGen += 1
            artistBusy = false
            artistWaiting = nil
            overlay.setArtistBusy(false)
            old.stop()
            if let fresh = try? BrainFactory.make(config: config, role: .artist) {
                artist = fresh
                Task { @MainActor in try? await fresh.warmUp() }
            }
        }
    }

    /// Is this Claude's own voice leaking into the mic? (Rare with echo cancellation, common on speakers.)
    private func isEcho(_ text: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
        }
        let heard = words(text)
        guard !heard.isEmpty else { return true }
        let spoken = Set(words(speaker.spokenText))
        let overlap = Double(heard.filter { spoken.contains($0) }.count) / Double(heard.count)
        return overlap >= 0.7
    }

    // MARK: - Answering

    /// `proactive`: nobody asked; Poinky has something to tell the user (an agent finished).
    private func ask(_ question: String, proactive: Bool = false) {
        guard let talker, let screen = overlay.screen else { return }
        releaseReports()   // a new question cut a report short
        turn += 1
        let myTurn = turn
        lastActivity = ProcessInfo.processInfo.systemUptime
        if buddyHidden { setBuddyHidden(false) }
        if !proactive { lastQuestion = question }
        lastAskAt = ProcessInfo.processInfo.systemUptime
        markFade?.cancel()
        // Each question starts with a clean screen: the previous answer's marks go away.
        // (Papers and 3D models stay until the talker clears them or the topic changes.)
        overlay.clearAnnotations()
        state = .thinking
        overlay.setCaption(you: proactive ? nil : question, claude: nil)
        parser = TalkParser()
        spokenCaption = ""
        speaker.beginTurn()

        let marks = overlay.marks
        let cursor = localCursor(on: screen)
        let focusCrop = pendingFocus
        pendingFocus = nil
        // What's being asked about: your marks, else what you marked before scrolling, else around the cursor.
        if let r = ScreenCapture.focusRect(marks: marks, screen: screen.frame.size) {
            focusRegion = r
        } else if let f = focusCrop {
            focusRegion = f.rectPoints
        } else if let c = cursor {
            focusRegion = CGRect(x: c.x - 140, y: c.y - 70, width: 280, height: 140)
        } else {
            focusRegion = nil
        }
        anchorDrawings(to: focusRegion, on: screen)
        placeCaptions()
        let sketchNow = !proactive && artist != nil && Self.wantsSketch(question, marked: !marks.isEmpty || focusCrop != nil)
        talkTask = Task { @MainActor in
            do {
                let snap = try await ScreenCapture.capture(screen: screen, marks: marks, cursor: cursor, focus: focusCrop)
                guard myTurn == self.turn else { return }
                self.lastSnapshot = snap
                self.replyScale = snap.scale
                // Clearly a "explain / show me" question: start the teacher now, alongside the talker.
                if sketchNow {
                    self.teacherStartedTurn = myTurn
                    self.requestVisual("Explain this to the user (2D lesson, or a 3D model if they asked for 3D). Started in parallel with the talker; the talker only says a short hand-over line.")
                }
                let q = BrainQuestion(text: self.talkerText(question, snap, proactive: proactive), snapshot: snap)
                _ = try await talker.ask(q) { delta in self.received(delta, turn: myTurn) }
                guard myTurn == self.turn else { return }
                self.handle(self.parser.finish())
                if !proactive { self.history.append((question, self.parser.sayPreview)) }
                if self.history.count > 6 { self.history.removeFirst() }
            } catch {
                guard myTurn == self.turn, !(error is CancellationError) else { return }
                self.overlay.setClaudeCaption("⚠️ \(error.localizedDescription)")
                self.speaker.enqueue("Sorry, something went wrong.")
            }
            guard myTurn == self.turn else { return }
            self.overlay.clearMarks()   // your marks were for this question
            self.speaker.endTurn()      // → finishedSpeaking() once the audio is done
        }
    }

    private func talkerText(_ question: String, _ snap: Snapshot, proactive: Bool = false) -> String {
        var lines = [proactive ? "(Nobody asked anything: this is a background update for you to pass on.) \(question)"
                               : "User said: \"\(question)\"",
                     "Screenshot size: \(snap.width)x\(snap.height) px (coordinates use this size)."]
        lines.append(contentsOf: snap.notes)
        lines.append(contentsOf: BrainQuestion.focusNotes(snap))
        lines.append(overlay.sceneDescription(scale: snap.scale))
        // Questions about Poinky itself get the current settings.
        let q = question.lowercased()
        let aboutApp = ["poinky", "poinky", "setting", "voice", "speed", "faster", "slower", "buddy", "shortcut",
                        "sound", "teacher", "notch", "memory", "remember", "forget", "hotkey", "keyboard"].contains { q.contains($0) }
        if aboutApp && !proactive { lines.append("Current Poinky settings: " + settingsSummary()) }
        // Background agents, and any results the user hasn't heard yet.
        let status = agents.statusLines()
        if !status.isEmpty { lines.append("Background agents:\n" + status.joined(separator: "\n")) }
        let earlier = pastHelpers(limit: 6, fromThisRun: false).map { p in
            "- \(p.name) \"\(p.title)\" in \(p.dir.path), \(p.status) \(Self.ago(p.started)) (key \(p.key)): \(HelperStream.clip(p.summary, 220))"
        }
        if !earlier.isEmpty {
            lines.append("Earlier agents (to continue one, `<agent resume=\"KEY\">what to do now</agent>`; it remembers its work):\n" + earlier.joined(separator: "\n"))
        }
        lines.append("If you start an agent now, it will be called \(agents.nextName).")
        let commands = AgentManager.commands
        if !commands.isEmpty {
            lines.append("The user's commands and skills an agent can run (start one whose task begins with it, like `/review`): " + commands.prefix(40).map { "/" + $0 }.joined(separator: ", "))
        }
        if ["usage", "used", "cost", "spent", "limit", "tokens", "how much", "plan"].contains(where: { q.contains($0) }), !agents.agents.isEmpty || !pastHelpers(limit: 1).isEmpty {
            lines.append(agents.usageLine())
        }
        if let c = helperContext { lines.append(c); helperContext = nil }
        if let h = agents.handsHolder, let a = agents.agents.first(where: { $0.id == h }) {
            lines.append("(\(a.name) is using the mouse and keyboard right now. Don't click or type for the user until it's done; if they ask you to, say \(a.name) is using them.)")
        }
        if agents.running.contains(where: { !$0.asks.isEmpty }) {
            lines.append("(Only the user can answer a helper that is WAITING: they say yes or no, or click its card. You can't approve anything for them, and <tell> doesn't answer it. If they ask what it wants, explain it plainly.)")
        }
        if !proactive, !agentReports.isEmpty {
            lines.append("Also tell the user briefly, after answering: " + agentReports.map(\.text).joined(separator: " "))
            startReporting(agentReports.map(\.id))
            agentReports.removeAll()
        }
        if teacherStartedTurn == turn {
            lines.append("(The teacher is ALREADY preparing a narrated sketch for this question. Say ONE short hand-over line, mark what it's about, and do NOT write <visual>.)")
        } else if artistBusy {
            lines.append("(The teacher is still drawing your last visual request.)")
        }
        return lines.joined(separator: "\n")
    }

    private func received(_ delta: String, turn myTurn: Int) {
        guard myTurn == turn, state != .idle else { return }
        handle(parser.feed(delta))
    }

    private func handle(_ ev: TalkEvents) {
        for s in ev.sentences {
            speaker.enqueue(s)
            state = .speaking
        }
        if !ev.sentences.isEmpty, spokenCaption.isEmpty { overlay.setClaudeCaption("…") }
        let lines = lastSnapshot?.text.lines ?? []
        let shotSize = lastSnapshot.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        for d in ev.draws {
            let snapped = MarkSnapper.snap(d, lines: lines, size: shotSize, scale: replyScale)
            overlay.apply(snapped, scale: replyScale)
            // What the talker marked is what's being explained: keep the paper and captions off it.
            if let b = Placement.bounds(ofDraw: snapped, scale: replyScale) {
                focusRegion = focusRegion.map { $0.union(b) } ?? b
                placeCaptions()
            }
        }
        if let brief = ev.visual, teacherStartedTurn != turn, ev.guide == nil { requestVisual(brief) }
        if let goal = ev.guide { startGuide(goal) }
        if let task = ev.doTask { startGuide(task, acting: true) }
        for json in ev.settings { applyVoiceSettings(json) }
        if config.memoryEnabled {
            for f in ev.remember { Memory.remember(f) }
            for f in ev.forget { Memory.forget(f) }
        }
        for (name, text) in ev.tells {
            if let a = helper(named: name), a.status == .running || a.status == .queued, agents.send(id: a.id, text: text) {
                overlay.helperHeard(id: a.id, kind: "message")
            }
        }
        for name in ev.stops {
            if let a = helper(named: name) { agents.stop(id: a.id) }
        }
        for who in ev.undos {
            if let a = helper(named: who) { undoHelper(agents.past(a), said: nil) }
            else if let p = pastHelper(key: who) ?? pastHelpers(limit: 40).first(where: { $0.name.lowercased() == who.lowercased() }) { undoHelper(p, said: nil) }
        }
        for req in ev.agents {
            // Continuing an earlier helper ("continue the login fix"): found by its key.
            if let key = req.resumeKey {
                if let past = pastHelper(key: key), agents.resume(past, text: req.task, config: config) != nil { continue }
                NSLog("Poinky: no earlier helper with the key \(key); starting a new one")
            }
            if agents.start(req, config: config) == nil {
                overlay.setClaudeCaption("⚠️ Couldn't start the agent: background agents need Claude Code installed")
            }
        }
        if ev.end { endAfterSpeaking = true }
    }

    private func finishedSpeaking() {
        // Steps whose line was never heard (e.g. the voice failed) still get drawn.
        for tag in pendingSteps.keys.sorted() {
            for step in pendingSteps[tag] ?? [] { play(step) }
        }
        pendingSteps.removeAll()
        lastActivity = ProcessInfo.processInfo.systemUptime
        releaseReports()   // the helpers that were reported merge into the buddy
        guard state == .speaking || state == .thinking else { return }
        state = restingState
        if endAfterSpeaking {
            endAfterSpeaking = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.endCall() }
            return
        }
        // A helper came to ask while Claude was talking: its question comes first.
        if askingNow != nil, askSpoken == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.deliverAsk() }
        }
        // An agent finished while Claude was talking: now's the time to say so.
        if !agentReports.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.deliverReports() }
        }
        // Let the captions fade a few seconds after Claude stops talking.
        captionFade?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == self.restingState else { return }
            self.overlay.fadeCaptions()
        }
        captionFade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        // The marks did their job while Claude talked: clear them a moment later (a walkthrough keeps its target).
        markFade?.cancel()
        let fade = DispatchWorkItem { [weak self] in
            guard let self, self.state == self.restingState, self.guide == nil else { return }
            self.overlay.fadeAnnotations()
        }
        markFade = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: fade)
    }

    // MARK: - The artist

    private func requestVisual(_ brief: String) {
        guard artist != nil, let snap = lastSnapshot else { return }
        var lines = ["Brief from the talker: \(brief)",
                     "User said: \"\(lastQuestion)\"",
                     "Talker said: \"\(parser.sayPreview)\"",
                     "Screenshot size: \(snap.width)x\(snap.height) px (coordinates use this size)."]
        lines.append(contentsOf: snap.notes)
        lines.append(contentsOf: BrainQuestion.focusNotes(snap))
        lines.append(overlay.sceneDescription(scale: snap.scale))
        let room = paperFrame()
        let units = Int((room.height - 32) / room.width * 800)
        lines.append("Paper room: 800 units wide, about \(max(300, units)) units tall before it runs out of space. Keep the lesson within that (use newpage for more).")
        if history.count > 0 {
            lines.append("Earlier in the conversation:")
            for h in history.suffix(3) { lines.append("- User: \(h.user) / Talker: \(h.assistant)") }
        }
        runArtist(ArtistJob(text: lines.joined(separator: "\n"), snapshot: snap))
    }

    private func runArtist(_ job: ArtistJob) {
        guard let artist else { return }
        if artistBusy { artistWaiting = job; return }
        artistBusy = true
        overlay.setArtistBusy(true)
        currentTag = nil
        let myCall = callID, myGen = artistGen, myLesson = lessonToken
        final class Box { var stream = ArtistStream() }
        let box = Box()
        Task { @MainActor in
            do {
                _ = try await artist.ask(BrainQuestion(text: job.text, snapshot: job.snapshot)) { delta in
                    guard myCall == self.callID, myGen == self.artistGen, myLesson == self.lessonToken else { return }
                    for ev in box.stream.feed(delta) { self.handleArtist(ev, snapshot: job.snapshot) }
                }
                if myCall == self.callID, myGen == self.artistGen, myLesson == self.lessonToken {
                    for ev in box.stream.finish() { self.handleArtist(ev, snapshot: job.snapshot) }
                }
            } catch {
                if myCall == self.callID, myGen == self.artistGen, !(error is CancellationError) {
                    self.overlay.setClaudeCaption("⚠️ Artist: \(error.localizedDescription)")
                }
            }
            guard myCall == self.callID, myGen == self.artistGen else { return }
            self.finishTeacherOutput()   // closes the paper/narration even if it forgot to
            self.artistBusy = false
            if let next = self.artistWaiting {
                self.artistWaiting = nil
                self.runArtist(next)
            } else {
                self.overlay.setArtistBusy(false)
            }
        }
    }

    private func handleArtist(_ ev: ArtistEvent, snapshot: Snapshot) {
        guard state != .idle else { return }
        lessonScale = snapshot.scale
        switch ev {
        case .lessonStart(let title, let continuing):
            openPaper(title: title, continuing: continuing)
        case .say(let line):
            openNarration()
            nextTag += 1
            currentTag = nextTag
            pendingSteps[nextTag] = []
            speaker.enqueue(line, tag: nextTag)
            state = .speaking
        case .step(let json):
            if !lessonOpen { openPaper(title: "", continuing: true) }
            schedule(.paper(snapScreenMarks(json, snapshot: snapshot)))
        case .step3d(let id, let code):
            schedule(.model(id: id, code: code))
        case .lessonEnd:
            lessonOpen = false
        case .card(let spec):
            overlay.apply(placeCards(spec, scale: snapshot.scale), scale: snapshot.scale)
        case .sceneCode(let id, let code):
            overlay.feed3d(id: id, code: code)
        case .sceneEnd(let id):
            overlay.end3d(id: id)
        case .photo(let query, let forId):
            guard config.webPhotos else { return }
            let myCall = callID
            Task { @MainActor in
                guard let photo = await WikiPhoto.find(query), myCall == self.callID, self.state != .idle else { return }
                self.overlay.showPhoto(forId: forId, src: photo.dataURL, caption: query)
            }
        }
    }

    /// 3D models go where the app decides (free space beside what's being explained), not where
    /// the model guessed, and get a generous size since they float on the screen without a card.
    private func placeCards(_ json: String, scale: CGFloat) -> String {
        guard var obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              var items = obj["items"] as? [[String: Any]] else { return json }
        let size = overlay.screen?.frame.size ?? CGSize(width: 1440, height: 900)
        for i in items.indices where items[i]["type"] as? String == "scene3d" {
            let room = Placement.paper(screen: size, focus: focusRegion, occupied: [], maxWidth: 900)
            let w = room.width, h = min(room.height, w * 0.85)
            items[i]["x"] = room.minX * scale; items[i]["y"] = room.minY * scale
            items[i]["w"] = w * scale; items[i]["h"] = h * scale
        }
        obj["items"] = items
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let out = String(data: data, encoding: .utf8) else { return json }
        return out
    }

    private func openPaper(title: String, continuing: Bool) {
        lessonOpen = true
        currentTag = nil
        let frame = paperFrame()
        overlay.lessonBegin(frame: frame, title: title, continuing: continuing, avoid: focusRegion)
        placeCaptions(extra: [frame])
    }

    /// The teacher's lines join the voice queue (after anything the talker is still saying).
    private func openNarration() {
        guard !narrationOpen else { return }
        narrationOpen = true
        speaker.openSource()
    }

    /// The teacher finished writing: no more lines are coming.
    private func finishTeacherOutput() {
        lessonOpen = false
        if narrationOpen {
            narrationOpen = false
            speaker.endTurn()
        }
    }

    /// A step waits for its line to be spoken; if that line is already playing (or there is none), it runs now.
    private func schedule(_ step: PendingStep) {
        if let tag = currentTag, !startedTags.contains(tag) {
            pendingSteps[tag, default: []].append(step)
        } else {
            play(step)
        }
    }

    private func play(_ step: PendingStep) {
        switch step {
        case .paper(let json): overlay.lessonStep(json, scale: lessonScale)
        case .model(let id, let code): overlay.run3d(id: id, code: code)
        }
    }

    /// Screen marks inside a lesson step also snap to the real text.
    private func snapScreenMarks(_ json: String, snapshot: Snapshot) -> String {
        let lines = snapshot.text.lines
        let size = CGSize(width: snapshot.width, height: snapshot.height)
        guard !lines.isEmpty,
              var obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let ops = obj["ops"] as? [[String: Any]] else { return json }
        obj["ops"] = ops.map { op in op["op"] as? String == "screen" ? MarkSnapper.snapItem(op, lines: lines, size: size, scale: snapshot.scale) : op }
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let out = String(data: data, encoding: .utf8) else { return json }
        return out
    }

    /// Where the paper goes: the largest free space beside, above or below what's being explained.
    private func paperFrame() -> CGRect {
        let size = overlay.screen?.frame.size ?? CGSize(width: 1440, height: 900)
        let others = overlay.scene.filter { $0.type != "lesson" }.compactMap { item -> CGRect? in
            guard let b = item.box, b.count == 4 else { return nil }
            return CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
        }
        return Placement.paper(screen: size, focus: focusRegion, occupied: others)
    }

    /// Captions move to the top when the bottom has what's being explained (or the paper).
    private func placeCaptions(extra: [CGRect] = []) {
        let size = overlay.screen?.frame.size ?? CGSize(width: 1440, height: 900)
        var avoid = extra + overlay.occupiedRects
        if let f = focusRegion { avoid.append(f) }
        overlay.captionsAtTop(Placement.captionsAtTop(screen: size, avoid: avoid))
    }

    /// Questions that deserve a sketch right away (so the teacher can start with the talker).
    static func wantsSketch(_ q: String, marked: Bool) -> Bool {
        let s = q.lowercased()
        // "How do I…" / "where do I…" questions get a step-by-step guide instead.
        let howTo = ["how do i", "how can i", "how to ", "where do i", "where can i", "help me ", "walk me through", "show me how to"]
        if howTo.contains(where: { s.contains($0) }) { return false }
        let strong = ["explain", "how does", "how do ", "how is ", "how are", "how it works", "show me", "draw", "sketch",
                      "diagram", "in 3d", "3d model", "teach me", "visualize", "what's the difference",
                      "what is the difference", "compare"]
        if strong.contains(where: { s.contains($0) }) { return true }
        // Marked something and asked what/why about it.
        let soft = ["what does", "what is", "what's", "what are", "why ", "mean"]
        return marked && soft.contains(where: { s.contains($0) }) && s.split(separator: " ").count >= 3
    }

    // MARK: - Guide mode

    private func startGuide(_ goal: String, acting wantsToAct: Bool = false) {
        endGuide()
        var acting = wantsToAct && config.computerControl
        if acting && !Computer.trusted {
            // macOS has to allow it first; meanwhile, show the steps instead.
            Computer.requestAccess()
            acting = false
            speaker.beginTurn()
            speaker.enqueue("To click and type for you, I need Accessibility permission. Turn on Poinky in the window that just opened. For now, I'll show you the steps.")
            speaker.endTurn()
        } else if wantsToAct && !config.computerControl {
            speaker.beginTurn()
            speaker.enqueue("Clicking for you is turned off in Settings, so I'll show you the steps.")
            speaker.endTurn()
        }
        // Remember what you were pointing at when you asked ("this tweet"), for every step.
        var context: [String] = []
        if let snap = lastSnapshot {
            context = snap.notes.filter { !$0.hasPrefix("Mouse cursor") }.map { "When asking, " + $0.prefix(1).lowercased() + $0.dropFirst() }
            if let c = snap.notes.first(where: { $0.hasPrefix("Mouse cursor") }) { context.append("When asking, the " + c.prefix(1).lowercased() + c.dropFirst()) }
            if let f = snap.focus {
                context.append("The user had marked this area (x \(Int(f.rectPx.minX))–\(Int(f.rectPx.maxX)), y \(Int(f.rectPx.minY))–\(Int(f.rectPx.maxY))).")
                if !f.text.isEmpty { context.append("Text in it: «\(f.text.prefix(300))»") }
            }
            context.append("The user's question: \"\(lastQuestion)\"")
        }
        guide = Guide(goal: goal, context: context, acting: acting)
        if acting { doerBrain?.stop(); doerBrain = nil }
        updateUI()
        // Showing: your clicks anywhere on screen move the guide to the next step.
        if !acting {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated { self?.guideClicked() }
            }
        }
        guideStep(action: nil)
    }

    private func endGuide() {
        guard guide != nil || clickMonitor != nil else { return }
        Computer.token += 1          // stop any click or typing in progress
        guide = nil
        guideRerun = nil
        guideClickWork?.cancel()
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        overlay.clearAnnotations()
        updateUI()
    }

    private func guideClicked() {
        guard let g = guide, let screen = overlay.screen, let p = localCursor(on: screen) else { return }
        let k = ScreenCapture.imageScale(for: screen.frame.size)
        let onTarget = g.target.map { $0.insetBy(dx: -14, dy: -14).contains(p) } ?? false
        let action = "Clicked at (\(Int(p.x * k)), \(Int(p.y * k))): \(onTarget ? "on the marked target" : "NOT on the marked target")."
        // Give the app a moment to react (menus opening, pages loading) before looking again.
        guideClickWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.guide != nil else { return }
            self.overlay.clearAnnotations()
            self.guideStep(action: action)
        }
        guideClickWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    /// Looks at the screen and gives the next step (or finishes).
    private func guideStep(action: String?) {
        guard var g = guide, let screen = overlay.screen else { return }
        if guideBusy { guideRerun = action ?? guideRerun ?? "(the screen changed)"; return }
        g.count += 1
        if g.count > 40 {
            endGuide()
            speaker.beginTurn(); speaker.enqueue("That's taking too many steps, so I stopped. Tell me where you'd like to pick up."); speaker.endTurn()
            return
        }
        g.acts = []; g.ask = nil; g.waiting = false
        guide = g
        let brain: Brain?
        if g.acting {
            if doerBrain == nil { doerBrain = try? BrainFactory.make(config: config, role: .doer) }
            brain = doerBrain
        } else {
            if guideBrain == nil { guideBrain = try? BrainFactory.make(config: config, role: .guide) }
            brain = guideBrain
        }
        guard let brain else { return }
        guideBusy = true
        guideLine = ""
        let myCall = callID
        state = .thinking
        Task { @MainActor in
            do {
                let snap = try await ScreenCapture.capture(screen: screen, marks: [], cursor: self.localCursor(on: screen))
                guard myCall == self.callID, self.guide != nil else { self.guideBusy = false; return }
                self.replyScale = snap.scale
                self.lastSnapshot = snap
                var lines = ["Goal: \(g.goal)", "Screenshot size: \(snap.width)x\(snap.height) px (coordinates use this size)."]
                lines.append(g.steps.isEmpty ? "This is the first step."
                             : "Steps so far:\n" + g.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
                if g.steps.isEmpty { lines.append(contentsOf: g.context) }
                if let a = action { lines.append("What the user just did: \(a)") }
                lines.append(contentsOf: snap.notes)
                if g.acting {
                    // The app's real buttons, fields and menus, so clicks land on the right thing.
                    let ui = AppReader.read(screen: screen, scale: snap.scale)
                    self.guide?.ui = ui
                    lines.append(contentsOf: ui.lines)
                }
                final class Box { var parser = TalkParser() }
                let box = Box()
                self.speaker.openSource()
                _ = try await brain.ask(BrainQuestion(text: lines.joined(separator: "\n"), snapshot: snap)) { delta in
                    guard myCall == self.callID, self.guide != nil else { return }
                    self.handleGuide(box.parser.feed(delta), snap: snap)
                }
                if myCall == self.callID, self.guide != nil { self.handleGuide(box.parser.finish(), snap: snap) }
                self.speaker.endTurn()
                if !self.guideLine.isEmpty { self.guide?.steps.append(self.guideLine) }
            } catch {
                if myCall == self.callID, !(error is CancellationError) {
                    self.overlay.setClaudeCaption("⚠️ Guide: \(error.localizedDescription)")
                }
                self.speaker.endTurn()
            }
            self.guideBusy = false
            if self.state == .thinking { self.state = self.restingState }
            if let next = self.guideRerun, self.guide != nil {
                self.guideRerun = nil
                self.guideStep(action: next)
            } else if self.guide?.acting == true, myCall == self.callID {
                await self.doerAct()
            }
        }
    }

    private func handleGuide(_ ev: TalkEvents, snap: Snapshot) {
        for s in ev.sentences {
            guideLine += (guideLine.isEmpty ? "" : " ") + s
            speaker.enqueue(s)
            state = .speaking
        }
        for d in ev.draws {
            let snapped = MarkSnapper.snap(d, lines: snap.text.lines, size: CGSize(width: snap.width, height: snap.height), scale: snap.scale)
            overlay.clearAnnotations()
            overlay.apply(snapped, scale: snap.scale)
            guide?.target = Placement.bounds(ofDraw: snapped, scale: snap.scale)
        }
        if !ev.acts.isEmpty { guide?.acts += ev.acts }
        if let a = ev.ask { guide?.ask = a }
        if let done = ev.done {
            if !done.isEmpty { speaker.enqueue(done); state = .speaking }
            endGuide()
        }
    }

    // MARK: - Doing it for you (clicks and typing)

    private enum ActResult { case did(String), needsOK(String), failed(String), stopped }

    /// Words on a button or link that mean "this can't be undone": Poinky asks you first.
    private static let riskyWords = try! NSRegularExpression(
        pattern: #"\b(send|submit|post|publish|pay|buy|purchase|order|checkout|check out|delete|remove|trash|transfer|unsubscribe|subscribe|merge|deploy|confirm|sign up|book|reserve)\b"#,
        options: [.caseInsensitive])

    private func says(_ line: String) {
        speaker.openSource(); speaker.enqueue(line); speaker.endTurn()
        state = .speaking
    }

    /// Runs this step's actions, then looks at the screen again for the next step.
    private func doerAct() async {
        guard var g = guide, g.acting, !g.waiting, let screen = overlay.screen, let snap = lastSnapshot else { return }
        if let q = g.ask {
            // A question for you (what to write, which one, OK to send?): wait for your answer.
            g.waiting = true; guide = g
            says(q)
            return
        }
        guard !g.acts.isEmpty else {
            guideStep(action: "(No action was taken. Do the next action, or write <done> if the goal is reached.)")
            return
        }
        let my = Computer.token
        var did: [String] = []
        for json in g.acts {
            guard my == Computer.token, guide != nil else { return }
            guard let a = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { continue }
            switch await perform(a, snap: snap, screen: screen) {
            case .did(let d): did.append(d)
            case .failed(let why): did.append("FAILED: \(why)")
            case .stopped: return
            case .needsOK(let target):
                // Something that sends, buys or deletes: say what's about to happen and wait for a yes.
                guide?.riskyTarget = target
                guide?.waiting = true
                if !did.isEmpty { guide?.steps.append("Did: " + did.joined(separator: "; ")) }
                says("Should I click \(target)?")
                return
            }
        }
        guard my == Computer.token, guide != nil else { return }
        if guide?.confirmed == true { guide?.confirmed = false; guide?.riskyTarget = nil }
        // Let the app react (menus open, pages load) before looking again.
        try? await Task.sleep(nanoseconds: 700_000_000)
        guard my == Computer.token, guide != nil, guide?.waiting == false else { return }
        guideStep(action: "You did: " + did.joined(separator: "; "))
    }

    private func perform(_ a: [String: Any], snap: Snapshot, screen: NSScreen) async -> ActResult {
        func num(_ k: String) -> CGFloat? { (a[k] as? NSNumber).map { CGFloat($0.doubleValue) } }
        let ui = guide?.ui ?? AppReader.Reading()
        // Where to act: a listed element ("el"), the text named by "find" if it's on screen, else x/y (screenshot pixels).
        func target() -> (px: CGPoint, label: String)? {
            if let n = (a["el"] as? NSNumber)?.intValue, let e = ui.elements[n] {
                return (CGPoint(x: e.rectPx.midX, y: e.rectPx.midY), e.label)
            }
            var p: CGPoint? = nil
            if let x = num("x"), let y = num("y") { p = CGPoint(x: x, y: y) }
            let find = (a["find"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            if !find.isEmpty, let r = MarkSnapper.locate(find, to: nil, hint: p, in: snap.text.lines) { p = CGPoint(x: r.midX, y: r.midY) }
            guard let px = p else { return nil }
            return (px, find.isEmpty ? textNear(px, snap.text.lines) : find)
        }
        func onScreen(_ px: CGPoint) -> CGPoint {
            let local = CGPoint(x: px.x / snap.scale, y: px.y / snap.scale)
            overlay.ripple(at: local)
            return WindowTracker.toGlobal(local, screen: screen)
        }
        let kind = (a["do"] as? String ?? "").lowercased()
        switch kind {
        case "click":
            guard let t = target() else { return .failed("no x/y for the click") }
            if !(guide?.confirmed ?? false), isRisky(t.label) { return .needsOK("“\(t.label)”") }
            let n = (a["double"] as? Bool) == true ? 2 : 1
            guard await Computer.click(at: onScreen(t.px), count: n, right: (a["right"] as? Bool) == true) else { return .stopped }
            return .did("clicked \(t.label.isEmpty ? "" : "“\(t.label)” ")at (\(Int(t.px.x)), \(Int(t.px.y)))")
        case "type":
            guard let text = a["text"] as? String, !text.isEmpty else { return .failed("nothing to type") }
            if let t = target() {
                guard await Computer.click(at: onScreen(t.px)) else { return .stopped }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            if Computer.focusIsSecure() {
                says("That's a password field. I don't type passwords, so please type it yourself.")
                return .failed("the field is a password field; the user must type it")
            }
            if (a["replace"] as? Bool) == true { _ = await Computer.press("cmd+a") }
            // New lines: new paragraphs, except in chat boxes where Return would send.
            let nl = (a["newline"] as? String)?.lowercased()
            let soft = nl == "shift" || (nl == nil && Computer.chatApps.contains(ui.bundleID))
            guard await Computer.type(text, softBreaks: soft) else { return .stopped }
            return .did("typed “\(text.count > 60 ? String(text.prefix(60)) + "…" : text)”")
        case "key":
            guard let keys = a["keys"] as? String else { return .failed("no keys") }
            if let why = await Computer.press(keys) { return .failed(why) }
            return .did("pressed \(keys)")
        case "scroll":
            let lines = Int(num("dy") ?? num("lines") ?? 5)
            let at = target().map { onScreen($0.px) }
            guard await Computer.scroll(lines: lines, at: at) else { return .stopped }
            return .did("scrolled \(lines > 0 ? "down" : "up") \(abs(lines)) lines")
        case "open":
            if let u = a["url"] as? String, let url = URL(string: u), ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                return .did("opened \(u)")
            }
            if let app = a["app"] as? String, !app.isEmpty {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-a", app]
                do { try p.run(); p.waitUntilExit() } catch { return .failed("couldn't open \(app)") }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                return p.terminationStatus == 0 ? .did("opened \(app)") : .failed("there's no app called \(app)")
            }
            return .failed("open needs an app name or an http/mailto url")
        case "menu":
            // Picks a menu item by name, e.g. "Format > Checklist" (works in any Mac app).
            let raw = (a["path"] as? String) ?? ((a["path"] as? [String])?.joined(separator: ">") ?? "")
            let path = raw.components(separatedBy: CharacterSet(charactersIn: ">›→")).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !path.isEmpty else { return .failed("menu needs a path like \"Format > Checklist\"") }
            guard let app = AppReader.frontApp() else { return .failed("no app in front") }
            let last = path.last ?? ""
            if last.range(of: #"^(quit|log ?out|shut ?down|restart|empty trash|force quit)"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return .failed("“\(last)” is blocked (it could close apps or lose work)")
            }
            if !(guide?.confirmed ?? false), isRisky(last) { return .needsOK("“\(last)”") }
            if let why = AppReader.pickMenu(path, pid: app.processIdentifier) { return .failed(why) }
            try? await Task.sleep(nanoseconds: 250_000_000)
            return .did("picked menu \(path.joined(separator: " > "))")
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64(min(3, max(0.1, Double(num("s") ?? 1))) * 1_000_000_000))
            return .did("waited")
        default:
            return .failed("unknown action \(kind)")
        }
    }

    private func isRisky(_ label: String) -> Bool {
        let ns = label as NSString
        return Self.riskyWords.firstMatch(in: label, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// The words on screen right at a point (a button's label).
    private func textNear(_ p: CGPoint, _ lines: [OCRLine]) -> String {
        if let l = lines.first(where: { $0.rect.insetBy(dx: -6, dy: -6).contains(p) }) {
            let near = l.words.filter { abs($0.rect.midX - p.x) < max(70, $0.rect.width) }
            if !near.isEmpty { return near.map(\.text).joined(separator: " ") }
            return l.text.count <= 40 ? l.text : ""
        }
        let w = lines.flatMap(\.words).min { hypot($0.rect.midX - p.x, $0.rect.midY - p.y) < hypot($1.rect.midX - p.x, $1.rect.midY - p.y) }
        if let w, hypot(w.rect.midX - p.x, w.rect.midY - p.y) < 30 { return w.text }
        return ""
    }

    /// You interrupted, pressed Esc, or started talking: stop clicking and typing right away.
    private func stopActing(pause: Bool) {
        guard guide?.acting == true else { return }
        Computer.token += 1
        if pause { guide?.waiting = true; guide?.acts = [] } else { endGuide() }
    }

    // MARK: - Drawings stay with their window

    /// The drawings for this question belong to the window under the focus.
    private func anchorDrawings(to focus: CGRect?, on screen: NSScreen) {
        overlay.bakeContent()
        overlay.setContentVisible(true)
        anchor = nil
        lastShift = .zero
        guard let f = focus else { return }
        let p = WindowTracker.toGlobal(CGPoint(x: f.midX, y: f.midY), screen: screen)
        if let w = WindowTracker.window(at: p) { anchor = (w.id, w.bounds.origin) }
    }

    /// Runs ~7×/s: hide drawings when their window is away, move them when it moves.
    private func followAnchor() {
        guard let a = anchor else { return }
        if let b = WindowTracker.visibleBounds(of: a.id) {
            overlay.setContentVisible(true)
            let shift = CGPoint(x: b.minX - a.origin.x, y: b.minY - a.origin.y)
            if abs(shift.x - lastShift.x) > 0.5 || abs(shift.y - lastShift.y) > 0.5 {
                lastShift = shift
                overlay.shiftContent(dx: shift.x, dy: shift.y)
            }
        } else {
            overlay.setContentVisible(false)
        }
    }

    /// A card's code crashed: ask the artist to fix it once.
    private func cardFailed(id: String, type: String, message: String) {
        guard state != .idle, let snap = lastSnapshot, artistRetries[id, default: 0] < 1 else { return }
        artistRetries[id, default: 0] += 1
        let text = type == "scene3d"
            ? "Part of your 3D model id=\"\(id)\" failed: \(message)\nThe rest of the model is on screen. Reply with only a <step3d id=\"\(id)\"> that does that part correctly (no <say>)."
            : "Your <\(type)> with id=\"\(id)\" failed with this error: \(message)\nReply with a corrected block that uses the same id."
        runArtist(ArtistJob(text: text, snapshot: snap))
    }

    // MARK: - Mouse: ⌥ marking, hovering cards, scrolling

    private func startWatchers() {
        // Polling needs no extra permissions (unlike a global key monitor).
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state != .idle else { return }
                let f = NSEvent.modifierFlags
                // ⌥ alone marks; ⌃⌥ (holding to talk) marks too, so you can point while you talk.
                self.overlay.setMarking(f.contains(.option) && !f.contains(.command))
                self.overlay.trackMouse()
                if let screen = self.overlay.screen {
                    let listening = self.state == .listening
                    let level = listening ? self.listener.level : 0
                    self.overlay.tick(cursor: self.localCursor(on: screen), level: level)
                    if abs(Double(level) - self.home.model.level) > 0.04 { self.home.model.level = Double(level) }
                }
                // Esc stops Poinky clicking and typing for you.
                if self.guide?.acting == true, Computer.escapePressed {
                    self.stopActing(pause: false)
                    self.speaker.stop()
                    self.says("Okay, I stopped.")
                }
                self.anchorTick += 1
                if self.anchorTick % 6 == 0 { self.followAnchor() }
                if self.anchorTick % 60 == 0 { self.checkIdle() }
                // Auto-hide: idle time counts from when Poinky finished (not from your question),
                // and never while it's listening, talking, guiding you or acting for you.
                if self.state != self.restingState || self.guide != nil || self.speaker.isSpeaking {
                    self.lastActivity = ProcessInfo.processInfo.systemUptime
                } else if self.anchorTick % 15 == 0, self.config.buddyAutoHide > 0, !self.buddyHidden,
                          ProcessInfo.processInfo.systemUptime - self.lastActivity > self.config.buddyAutoHide {
                    self.setBuddyHidden(true)
                }
            }
        }
        // Marks on the screen stay put while content scrolls away, so clear them. Cards stay.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard abs(event.scrollingDeltaY) + abs(event.scrollingDeltaX) > 2 else { return }
            MainActor.assumeIsolated {
                // Marks no longer line up once the page scrolls, so they go. The close-up of
                // what you circled is kept, so you can still ask about it.
                self?.overlay.clearAnnotations()
                self?.overlay.clearMarks()
            }
        }
    }

    // MARK: - Buddy, settings by voice, agents

    private func setBuddyHidden(_ hidden: Bool) {
        buddyHidden = hidden
        overlay.showBuddy(!hidden)
        home.model.buddyHidden = hidden
    }

    /// ⌃⌥B or the notch button: hide the buddy until the next question (or bring it back).
    private func toggleBuddy() {
        if !config.buddy {
            // The buddy is off in Settings: turn it on.
            var cfg = config; cfg.buddy = true; cfg.save(); settingsChanged(cfg)
            setBuddyHidden(false)
            return
        }
        setBuddyHidden(!buddyHidden)
        lastActivity = ProcessInfo.processInfo.systemUptime
    }

    /// "Talk faster", "hide the buddy"…: Claude changes a few safe settings itself.
    private func applyVoiceSettings(_ json: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return }
        var cfg = AppConfig.load()
        func num(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue }
        func flag(_ k: String) -> Bool? { obj[k] as? Bool }
        if let v = num("voiceSpeed") ?? num("kokoroSpeed") {
            cfg.voiceSpeed = min(PhononVoice.speedRange.upperBound, max(PhononVoice.speedRange.lowerBound, v))
        }
        if let v = (obj["phononVoice"] ?? obj["voice"]) as? String, let name = PhononVoice.voiceName(v) { cfg.phononVoice = name }
        if let v = flag("buddy") { cfg.buddy = v }
        if let v = num("buddyAutoHide") { cfg.buddyAutoHide = max(0, min(3600, v)) }
        if let v = flag("sounds") { cfg.sounds = v }
        if let v = num("soundVolume") { cfg.soundVolume = min(1, max(0, v)); if v > 0 { cfg.sounds = true } }
        if let v = flag("artistEnabled") { cfg.artistEnabled = v }
        if let v = num("silenceSeconds") { cfg.silenceSeconds = min(2.5, max(0.5, v)) }
        if let v = obj["pushToTalk"] as? String, ["ctrl+option", "ctrl+shift", "option+cmd", "off"].contains(v) { cfg.pushToTalk = v }
        if let v = flag("memoryEnabled") { cfg.memoryEnabled = v }
        cfg.save()
        SettingsWindowController.shared.model.reload()
        settingsChanged(cfg)
        if cfg.artistEnabled != (artist != nil), state != .idle {
            artist?.stop()
            artist = cfg.artistEnabled ? try? BrainFactory.make(config: cfg, role: .artist) : nil
        }
    }

    private func settingsSummary() -> String {
        let c = config
        return "voice \(c.phononVoice) at speed \(String(format: "%.2f", c.voiceSpeed)) (engine \(c.voiceEngine)\(c.voiceEngine == "phonon" && !PhononVoice.isInstalled ? ", not installed yet: Apple's voice is speaking" : "")); buddy \(c.buddy ? "on" : "off")"
            + (c.buddyAutoHide > 0 ? ", auto-hides after \(Int(c.buddyAutoHide)) s" : "") + "; sounds \(c.sounds ? "on at \(Int((c.soundVolume * 100).rounded()))% volume" : "off")"
            + "; teacher \(c.artistEnabled ? "on" : "off"); hold to talk \(PushToTalk.displayString(c.pushToTalk))"
            + "; hands-free call \(HotKey.displayString(c.hotkey)); hide buddy \(HotKey.displayString(c.buddyHotkey)); type instead of talking \(HotKey.displayString(c.typeHotkey))"
            + "; pause before answering (calls) \(c.silenceSeconds) s; language \(c.language); memory \(c.memoryEnabled ? "on" : "off")"
            + "; models (effort): talker \(c.model(for: .talker)) (\(c.talkerEffort.isEmpty ? "auto" : c.talkerEffort)), teacher \(c.model(for: .artist)) (\(c.artistEffort.isEmpty ? "auto" : c.artistEffort)), guide \(c.model(for: .guide)), doer \(c.model(for: .doer)), helpers \(c.agentModel.isEmpty ? "Claude Code default" : c.agentModel) (\(c.agentEffort.isEmpty ? "default" : c.agentEffort))"
    }

    // MARK: - Talking to a helper

    private func helperNames() -> [String] { helperScreen.names() }
    private func helper(named name: String) -> AgentManager.Agent? { helperScreen.helper(named: name) }

    /// Said to a helper: stop it, answer its status, or pass a follow-up on (no talker needed).
    private func talkToHelper(_ id: Int, _ intent: HelperTalk.Intent, said: String) {
        lastActivity = ProcessInfo.processInfo.systemUptime
        overlay.setYouCaption(said)
        switch helperScreen.talk(to: id, intent) {
        case .say(let line)?:
            sayQuick(line, said: said)
        case .passed(let name)?:
            overlay.setClaudeCaption("\(name) got it")
            history.append((said, "(passed to \(name))"))
            if history.count > 6 { history.removeFirst() }
            state = restingState
            captionFade?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.overlay.fadeCaptions() }
            captionFade = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        case .undo(let past)?:
            undoHelper(past, said: said)
        case .resume(let past, let text)?:
            if let a = agents.resume(past, text: text, config: config) {
                sayQuick("Okay, \(a.name) will pick it up.", said: said)
            } else {
                ask(said)
            }
        case .askTalker(let context)?:
            helperContext = context
            if case .message(let m) = intent { ask(m) } else { ask(said) }
        case nil:
            ask(said)
        }
    }

    /// A short spoken line without asking the talker.
    private func sayQuick(_ text: String, said: String) {
        turn += 1
        speaker.stop()
        speaker.beginTurn()
        speaker.enqueue(text)
        speaker.endTurn()
        state = .speaking
        if !said.isEmpty {
            history.append((said, text))
            if history.count > 6 { history.removeFirst() }
        }
    }

    // MARK: - A helper raises its hand

    /// A helper reached the buddy with its question: say it out loud as soon as you're free.
    private func helperAsking(_ id: Int) {
        guard agents.agents.first(where: { $0.id == id })?.asks.isEmpty == false else { return }
        askingNow = id
        askSpoken = nil
        deliverAsk()
    }

    /// Says the question of the helper next to the buddy, but never over Claude talking, you holding the
    /// keys or typing (like reports). In a hands-free call you just answer; otherwise hold the keys and say yes or no.
    private func deliverAsk() {
        guard let id = askingNow, let a = agents.agents.first(where: { $0.id == id }), let ask = a.asks.first else { return }
        let key = ask.requestID + "#" + (ask.currentQuestion?.text ?? "")
        guard askSpoken != key, !askCheckPending else { return }
        func later(_ secs: Double) {
            askCheckPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
                self?.askCheckPending = false
                self?.deliverAsk()
            }
        }
        if Self.screenLocked() { later(2); return }
        switch state {
        case .idle:
            if Self.secondsSinceTyping() < 2 { later(1); return }
            askAfterStart = true
            startSession(.push)
        case .ready where !ptt.isDown:
            if Self.secondsSinceTyping() < 2 { later(1); return }
            sayAsk(a, ask, key: key)
        case .listening where mode == .handsFree && listener.currentText.isEmpty && !ptt.isDown:
            sayAsk(a, ask, key: key)
        case .starting:
            askAfterStart = true
        default:
            later(1)   // Claude is talking or you are: right after
        }
    }

    private func sayAsk(_ a: AgentManager.Agent, _ ask: HelperAsk, key: String) {
        askSpoken = key
        lastActivity = ProcessInfo.processInfo.systemUptime
        captionFade?.cancel()
        overlay.setYouCaption(nil)
        overlay.setClaudeCaption(nil)
        sayQuick("\(a.name) \(ask.spoken)", said: "")
        schedulePark(a.id, after: 30)
    }

    /// Nobody answered: it goes back to work at the edge, its hand still up, and the next one gets a turn.
    private func schedulePark(_ id: Int, after secs: Double) {
        parkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.askingNow == id else { return }
            // You're answering (or Poinky is still talking): give it a moment.
            if self.ptt.isDown || self.pushCommitted || self.state == .thinking || self.state == .speaking
                || (self.mode == .handsFree && !self.listener.currentText.isEmpty) {
                self.schedulePark(id, after: 6); return
            }
            self.askingNow = nil
            self.askSpoken = nil
            self.helperScreen.park(id: id)
        }
        parkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + secs, execute: work)
    }

    /// It's not waiting anymore (answered everything, withdrew, finished or was stopped).
    private func askEnded(_ id: Int) {
        guard askingNow == id, agents.agents.first(where: { $0.id == id })?.asks.isEmpty != false else { return }
        askingNow = nil
        askSpoken = nil
        parkWork?.cancel(); parkWork = nil
    }


    /// Your answer goes to the helper, which thanks you and goes on (or asks its next question).
    private func answerAsk(_ id: Int, _ reply: HelperAsk.Reply, said: String?) {
        guard let before = agents.agents.first(where: { $0.id == id }), let ask = before.asks.first else { return }
        lastActivity = ProcessInfo.processInfo.systemUptime
        let wasNext = askingNow == id
        let result = helperScreen.answer(id, reply)
        guard let a = agents.agents.first(where: { $0.id == id }) else { return }
        if let said { overlay.setYouCaption(said) }
        var line: String?
        switch result {
        case .failed:
            line = "\(a.name) isn't waiting for that anymore."
        case .next:
            if wasNext { askSpoken = nil }
        case .sent:
            var ok = true
            if case .no = reply { ok = false }
            if a.asks.isEmpty, wasNext { askingNow = nil; askSpoken = nil; parkWork?.cancel(); parkWork = nil }
            else if wasNext { askSpoken = nil }   // its next one: said when it's up
            if case .yes(true, _) = reply, ask.risky { line = "Okay. \(a.name) will still ask each time for that." }
            else if !wasNext, said != nil {   // answered from afar (by name or pointing at its edge)
                line = ok ? "Okay, \(a.name) can go ahead." : "Okay, I told \(a.name) no."
            }
        }
        if let said, line == nil {
            history.append((said, "(answered \(a.name)'s request)"))
            if history.count > 6 { history.removeFirst() }
        }
        if let line { sayQuick(line, said: said ?? "") }
        else if state == .listening || state == .thinking { state = restingState }
    }

    /// Allow / Don't allow (or You choose / Skip) in a helper's window, for one request.
    private func windowAnswer(_ id: Int, _ requestID: String, _ yes: Bool) {
        guard let asks = agents.agents.first(where: { $0.id == id })?.asks else { return }
        if asks.first?.requestID == requestID { cardAnswer(id, yes); return }
        guard let ask = asks.first(where: { $0.requestID == requestID }) else { return }
        let reply: HelperAsk.Reply = ask.kind == .question ? (yes ? .answer("No preference: you choose.") : .no(reason: ""))
                                                           : (yes ? .yes(always: false, extra: "") : .no(reason: ""))
        agents.answer(id: id, requestID: requestID, reply)
    }

    /// An answer from your phone (away mode), for one request.
    private func phoneAnswer(_ id: Int, _ requestID: String, _ reply: HelperAsk.Reply) {
        guard let asks = agents.agents.first(where: { $0.id == id })?.asks else { return }
        if asks.first?.requestID == requestID { answerAsk(id, reply, said: nil) }
        else if asks.contains(where: { $0.requestID == requestID }) { agents.answer(id: id, requestID: requestID, reply) }
    }

    /// Allow / Don't allow (or You choose / Skip) on a helper's card.
    private func cardAnswer(_ id: Int, _ yes: Bool) {
        guard let ask = agents.agents.first(where: { $0.id == id })?.asks.first else { return }
        let reply: HelperAsk.Reply = ask.kind == .question ? (yes ? .answer("No preference: you choose.") : .no(reason: ""))
                                                           : (yes ? .yes(always: false, extra: "") : .no(reason: ""))
        answerAsk(id, reply, said: nil)
    }

    /// A helper finished (its own celebration and sound happen on screen). It waits at the edge with a
    /// badge until you're free, then flies to the buddy while Poinky says what it did.
    private func agentFinished(_ a: AgentManager.Agent) {
        let what = a.status == .done ? "finished" : "stopped with a problem"
        agentReports.append((a.id, "The background agent \(a.name) (\"\(a.title)\") \(what). Its summary: \(a.summary.isEmpty ? "(none)" : a.summary) (Full log: \(a.log.path))"))
        home.model.addReport(.init(id: a.id, name: a.name, ok: a.status == .done, summary: a.summary, log: a.log, at: Date()))
        // Let it celebrate at the edge first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.deliverReports() }
    }

    /// Tells the user about finished agents, but never over Claude talking, the user holding the keys
    /// or typing. Until then they wait at the edge of the screen.
    private func deliverReports() {
        guard !agentReports.isEmpty, !reportCheckPending else { return }
        func later(_ secs: Double) {
            reportCheckPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
                self?.reportCheckPending = false
                self?.deliverReports()
            }
        }
        // Away (screen locked): nobody to tell. They wait at the edge until you're back.
        if Self.screenLocked() { later(2); return }
        switch state {
        case .idle:
            // Typing: wait for a pause, so a voice doesn't start mid-sentence.
            if Self.secondsSinceTyping() < 2 { later(1); return }
            // No session: start a quiet one just to say it.
            reportAfterStart = true
            startSession(.push)
        case .ready:
            sayReports()
        case .listening where mode == .handsFree && listener.currentText.isEmpty && !ptt.isDown:
            sayReports()
        default:
            break   // after the current answer (finishedSpeaking), or with the user's next question
        }
    }

    private func sayReports() {
        guard talker != nil, overlay.screen != nil else { return }
        let reports = agentReports
        agentReports.removeAll()
        ask(reports.map(\.text).joined(separator: " ") + " Tell the user in one or two short sentences per agent what was done and anything they should check. Don't mark anything.", proactive: true)
        startReporting(reports.map(\.id))
    }

    /// These helpers fly to the buddy and stay there while Poinky talks about them.
    private func startReporting(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        reportingIDs += ids
        overlay.helperReport(ids: ids)
        home.model.markHeard(ids)
    }

    /// Done talking about them (or cut off): they merge into the buddy.
    private func releaseReports() {
        guard !reportingIDs.isEmpty else { return }
        overlay.helperRelease(ids: reportingIDs)
        reportingIDs.removeAll()
    }

    static func screenLocked() -> Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Seconds since the last key press anywhere (no permission needed for this).
    static func secondsSinceTyping() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
    }

    private func refreshAgentsInHome() {
        home.model.agentsRunning = agents.running.count
    }

    /// A hold-to-talk session that hasn't been used for a while ends by itself (frees the Claude sessions).
    private func checkIdle() {
        guard mode == .push, state == .ready, guide == nil, !artistBusy, !ptt.isDown, agentReports.isEmpty, reportingIDs.isEmpty,
              askingNow == nil else { return }
        if ProcessInfo.processInfo.systemUptime - lastActivity > Self.idleTimeout { endCall(quietly: true) }
    }

    private func stopWatchers() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
    }

    // MARK: - Helpers

    private func screenWithMouse() -> NSScreen {
        let loc = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(loc, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Cursor in the overlay's coordinates (points, origin top-left of that screen).
    private func localCursor(on screen: NSScreen) -> CGPoint? {
        let loc = NSEvent.mouseLocation
        guard NSMouseInRect(loc, screen.frame, false) else { return nil }
        return CGPoint(x: loc.x - screen.frame.minX, y: screen.frame.maxY - loc.y)
    }

    private func showAlert(_ text: String, info: String, settingsPane: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = text
        a.informativeText = info
        if settingsPane != nil { a.addButton(withTitle: "Open System Settings") }
        a.addButton(withTitle: "OK")
        let res = a.runModal()
        if let pane = settingsPane, res == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Menu bar

    private func updateUI() {
        let (symbol, baseStatus): (String, String) = {
            switch state {
            case .idle: return ("sparkles", "off")
            case .starting: return ("ellipsis.circle", "starting")
            case .ready: return ("sparkles", "ready")
            case .listening: return ("waveform", "listening")
            case .thinking: return ("ellipsis.bubble", "thinking")
            case .speaking: return ("speaker.wave.2", "speaking")
            }
        }()
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Poinky")
        img?.isTemplate = true
        statusItem.button?.image = img
        if state != .idle { overlay.setPhase(baseStatus, guide: guide != nil) }
        home.model.phase = baseStatus
        home.model.guide = guide != nil
        home.model.inCall = state != .idle && mode == .handsFree
        if state != .listening { home.model.level = 0 }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector?, key: String = "", indent: Int = 0, on: Bool? = nil, rep: Any? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = action == nil ? nil : self
            item.isEnabled = action != nil
            item.indentationLevel = indent
            if let on { item.state = on ? .on : .off }
            item.representedObject = rep
            menu.addItem(item)
        }
        let shortcut = HotKey.displayString(config.hotkey)
        let hold = PushToTalk.displayString(config.pushToTalk)
        if hold != "Off" { add("Hold \(hold) to talk, let go to send", nil) }
        add("Type to Poinky…  (\(HotKey.displayString(config.typeHotkey)))", #selector(openTypeBox))
        add("Helpers…", #selector(openHelpers))
        switch (state, mode) {
        case (.idle, _):
            add("Start Hands-Free Call  (\(shortcut))", #selector(toggleCall))
        case (_, .push):
            add("Switch to Hands-Free Call  (\(shortcut))", #selector(toggleCall))
            add("End Session", #selector(endSessionFromMenu))
        default:
            add("End Call  (\(shortcut))", #selector(toggleCall))
        }
        menu.addItem(.separator())

        add("Brain", nil)
        add("Claude Code (your subscription)", #selector(pickBrain(_:)), indent: 1, on: config.brain == .claudeCode, rep: BrainKind.claudeCode.rawValue)
        add("Anthropic API (API key)", #selector(pickBrain(_:)), indent: 1, on: config.brain == .api, rep: BrainKind.api.rawValue)
        add("Teacher: sketches & 3D", #selector(toggleArtist), on: config.artistEnabled)
        menu.addItem(.separator())

        add("Clear Drawings", #selector(clearAll))
        add("Settings…", #selector(openSettings), key: ",")
        add("Get More Apple Voices…", #selector(openVoiceSettings))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Poinky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func endSessionFromMenu() { endCall() }

    @objc private func pickBrain(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = BrainKind(rawValue: raw) else { return }
        config = AppConfig.load()
        config.brain = kind
        config.save()
        if state != .idle { overlay.setClaudeCaption("Brain switched. It takes effect on your next call.") }
    }

    @objc private func toggleArtist() {
        config = AppConfig.load()
        config.artistEnabled.toggle()
        config.save()
        home.model.teacherOn = config.artistEnabled
        if state != .idle { overlay.setClaudeCaption("Artist \(config.artistEnabled ? "on" : "off") from your next call.") }
    }

    @objc private func clearAll() {
        overlay.clearAll()
        overlay.clearMarks()
    }

    @objc private func openVoiceSettings() {
        let urls = ["x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
                    "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent"]
        for s in urls { if let u = URL(string: s), NSWorkspace.shared.open(u) { break } }
        showAlert("Download a Premium voice",
                  info: "In Accessibility → Read & Speak (called “Spoken Content” on older macOS), click the ⓘ next to “System voice”, choose your language (e.g. English), and download a voice marked Premium, like “Zoe (Premium)” or “Ava (Premium)”. For Hebrew, look for “Carmit (Enhanced)”.\n\nPoinky picks the best installed voice automatically on your next call.")
    }

    @objc private func openSettings() {
        config.save() // make sure the file exists with every option listed
        SettingsWindowController.shared.show()
    }

    /// The Settings window saved: pick up what can change right away.
    private func settingsChanged(_ cfg: AppConfig) {
        away.settings(cfg)
        let hotkeyChanged = cfg.hotkey != config.hotkey || cfg.buddyHotkey != config.buddyHotkey || cfg.typeHotkey != config.typeHotkey
        config = cfg
        ScreenCapture.excludedBundleIDs = Set(cfg.excludedApps)
        if hotkeyChanged {
            hotKey = nil
            buddyHotKey = nil
            typeHotKey = nil
            registerHotKey()
        }
        ptt.configure(cfg.pushToTalk)
        overlay.setBuddy(cfg.buddy)
        helperScreen.settings(cfg)
        refreshHomeLabels()
        if wantsPhonon(cfg) { try? phonon.start() } else { phonon.stop() }
        // Voice changes apply right away, even in the middle of a call.
        speaker.phononVoice = cfg.phononVoice
        speaker.voiceSpeed = cfg.voiceSpeed
        speaker.configure(language: cfg.language, voiceName: cfg.voice, rate: cfg.speechRate)
        listener.silenceSeconds = cfg.silenceSeconds
        if state != .idle {
            speaker.phonon = wantsPhonon(cfg) ? phonon : nil
        }
    }

    private var previewPlayer: AVAudioPlayer?

    /// Plays a short sample in the chosen natural voice (Settings → Voice → ▶).
    private func previewVoice(voice: String, speed: Double) {
        guard PhononVoice.isInstalled else { return }
        try? phonon.start()
        phonon.synthesize("Hi! This is how I'll sound when I explain things.", voice: voice, speed: speed) { [weak self] pcm in
            guard let self, let pcm else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("poinky-preview.caf")
            try? FileManager.default.removeItem(at: url)
            do {
                let file = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
                try file.write(from: pcm)
            } catch { return }
            self.previewPlayer = try? AVAudioPlayer(contentsOf: url)
            self.previewPlayer?.play()
        }
    }

    /// The natural voice speaks English; other languages use Apple's voice.
    private func wantsPhonon(_ cfg: AppConfig) -> Bool {
        cfg.voiceEngine == "phonon" && cfg.language.lowercased().hasPrefix("en") && PhononVoice.isInstalled
    }

    /// The voice finished installing (Settings, or the update from Kokoro): use it from the next sentence.
    private func voiceInstalled() {
        config = AppConfig.load()
        guard wantsPhonon(config) else { return }
        try? phonon.start()
        if state != .idle {
            speaker.phonon = phonon
            speaker.phononVoice = config.phononVoice
            speaker.voiceSpeed = config.voiceSpeed
        }
    }

    

}
