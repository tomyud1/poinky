import AppKit

/// Video explainers (docs/VISION.md, Phase 9): the talker's `<video>` starts one; a helper cooks it at
/// the edge; it opens full screen when it can play straight through and you're free; tapping ⌃⌥ while
/// it cooks cancels it; questions about it get its transcript and where you paused.
extension CallController {
    /// One video at a time; a new one replaces one that's still cooking.
    func startVideo(title: String, brief: String) {
        if video.job != nil, !video.window.isOpen { cancelVideo(say: false) }
        let name = agents.nextName
        agents.reservedNames.insert(name)
        let job = VideoJob(id: video.nextID, name: name, title: title, brief: brief)
        video.nextID += 1
        job.onChange = { [weak self, weak job] in if let self, let job { self.videoProgress(job) } }
        job.onEnd = { [weak self, weak job] in if let self, let job { self.videoEnded(job) } }
        do {
            try job.start(model: "claude-opus-5-5")
        } catch {
            agents.reservedNames.remove(name)
            overlay.setClaudeCaption("⚠️ Couldn't start the video: \(error.localizedDescription)")
            return
        }
        video.job = job
        video.checklist = []
        video.waitLogged = false
        overlay.helperSpawn(id: job.id, name: name, task: "Making a video: \(title)", note: AgentManager.note(for: name),
                            detail: brief.count > 220 ? String(brief.prefix(219)) + "…" : brief, folder: "")
    }

    /// Tap ⌃⌥ while it cooks, the stop button on its card, or "cancel the video".
    func cancelVideo(say: Bool) {
        guard let job = video.job, job.status == .cooking, !video.window.isOpen else { return }
        job.cancel()   // → videoEnded
        if say { sayWhenFree("Okay, no video.") }
    }

    private func videoProgress(_ job: VideoJob) {
        guard video.job === job else { return }
        if video.window.isOpen, video.window.job === job { video.window.update(); return }
        guard job.status == .cooking || job.status == .done else { return }
        if let s = job.takeStep() { overlay.helperStep(id: job.id, text: s) }
        let list = job.checklist
        if list != video.checklist { video.checklist = list; overlay.helperChecklist(id: job.id, items: list) }
        if job.canStart { openVideoWhenFree(job) }
    }

    private func videoEnded(_ job: VideoJob) {
        guard video.job === job else { return }
        switch job.status {
        case .cancelled:
            overlay.helperStop(id: job.id)
            agents.reservedNames.remove(job.name)
            video.job = nil
        case .failed(let why):
            if video.window.isOpen { return }   // it plays what it has
            overlay.helperDone(id: job.id, ok: false, summary: "Couldn't make the video")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.overlay.helperRelease(ids: [job.id]) }
            agents.reservedNames.remove(job.name)
            video.job = nil
            NSLog("Poinky: video failed: \(why)")
            sayWhenFree("Sorry, I couldn't make that video.")
        case .done, .cooking:
            break   // opens when you're free (videoProgress)
        }
    }

    /// Opens it, but never over Claude talking, you holding the keys or typing, a walkthrough, or a locked screen.
    private func openVideoWhenFree(_ job: VideoJob) {
        guard !video.window.isOpen, !video.checkPending, video.job === job else { return }
        func later(_ secs: Double) {
            video.checkPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
                guard let self else { return }
                self.video.checkPending = false
                if self.video.job === job, job.canStart { self.openVideoWhenFree(job) }
            }
        }
        if !video.waitLogged { video.waitLogged = true; VideoJob.log("ready to play \(Int(Date().timeIntervalSince(job.startedAt))) s after asking") }
        if Self.screenLocked() { later(2); return }
        if pttDown || callState == .thinking || callState == .speaking || callState == .starting || guideActive { later(1); return }
        if Self.secondsSinceTyping() < 2 { later(1); return }
        if handsFreeHearing { later(1); return }
        openVideo(job)
    }

    private func openVideo(_ job: VideoJob) {
        guard let screen = overlay.screen ?? NSScreen.main else { return }
        overlay.helperCard(id: job.id) { [weak self] rect in
            guard let self, self.video.job === job, !self.video.window.isOpen else { return }
            self.overlay.helperVanish(id: job.id)
            self.agents.reservedNames.remove(job.name)
            let color = HelperWindows.colors[job.name.components(separatedBy: " ")[0]] ?? "#34c98e"
            let pan = rect.map { Double($0.midX / max(1, screen.frame.width)) * 2 - 1 } ?? 0.8
            self.overlay.setClaudeCaption(nil)
            self.overlay.setYouCaption(nil)
            self.video.window.open(job, on: screen, from: rect, color: color, pan: pan, sound: (self.soundsOn, self.soundsVolume))
            VideoJob.log("opened \"\(job.title)\" \(Int(Date().timeIntervalSince(job.startedAt))) s after asking, from the card at \(rect.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "?")")
            if let n = self.video.window.windowNumber { ScreenCapture.includedWindowNumbers = [n] }
            self.video.last = job
        }
    }

    /// Esc, or the end of the video: it folds back into the buddy.
    func closeVideo() {
        guard video.window.isOpen else { return }
        overlay.buddyPosition { [weak self] p in self?.video.window.close(to: p) }
    }

    func videoClosed(_ job: VideoJob) {
        VideoJob.log("closed at \(String(format: "%.1f", video.window.time)) s")
        ScreenCapture.includedWindowNumbers = []
        overlay.evaluateForTest("SB.buddyReact && SB.buddyReact('absorb')")
        if video.job === job { video.job = nil }
    }

    /// The keys went down: a playing video pauses right away (a tap stops it; holding asks about it).
    func videoKeysDown() {
        if video.window.isOpen { video.window.pause() }
    }

    /// For the talker: the open (or last) video's transcript and where you paused, and one being made.
    var videoContext: [String] {
        var lines: [String] = []
        if video.window.isOpen, let job = video.window.job {
            lines.append(job.context(at: video.window.time, open: true))
            lines.append("(To close the video write <video-close/>; to continue playing it, <video-play/>.)")
        } else if let v = video.last {
            lines.append(v.context(at: nil, open: false))
        }
        if let job = video.job, job.status == .cooking, !video.window.isOpen {
            lines.append("(\(job.name) is making the video \"\(job.title)\"; it opens by itself when it's ready. If the user asks to cancel or stop it, write <video-cancel/>.)")
        }
        return lines
    }

    func handleVideoTags(_ ev: TalkEvents) {
        if ev.videoCancel { cancelVideo(say: false) }
        if ev.videoClose { closeVideo() }
        if ev.videoPlay { video.window.resume() }
        if let v = ev.video, !video.window.isOpen { startVideo(title: v.title, brief: v.brief) }
    }
}

extension CallController {
    /// Developer checks. `Poinky --video "topic"` makes one as if the talker had asked;
    /// `Poinky --play-video <folder>` opens one made earlier.
    func devVideo(topic: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startVideo(title: String(topic.prefix(48)), brief: topic)
        }
    }

    func devPlayVideo(dir: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let job = VideoJob(existing: URL(fileURLWithPath: dir), id: self.video.nextID, name: self.agents.nextName)
            self.video.nextID += 1
            guard job.status == .done else { NSLog("Poinky: no finished video in \(dir)"); return }
            self.video.job = job
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
            let w = screen.frame.width
            self.video.window.open(job, on: screen, from: CGRect(x: w - 290, y: 90, width: 236, height: 52), color: "#34c98e", pan: 0.8,
                                   sound: (self.soundsOn, self.soundsVolume))
            if let n = self.video.window.windowNumber { ScreenCapture.includedWindowNumbers = [n] }
            self.video.last = job
        }
    }
}

/// The video state CallController keeps.
@MainActor
final class VideoState {
    let window = VideoWindow()
    var job: VideoJob?          // being made, or open
    var last: VideoJob?         // the last one shown (its transcript stays for questions)
    var nextID = 9001           // helper ids for videos (agents count up from 1)
    var checkPending = false
    var checklist: [HelperTask] = []
    var waitLogged = false
}
