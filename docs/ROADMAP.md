# Roadmap: making Poinky the everyday way to use AI

`docs/VISION.md` is the product story and the helper phases. This file is the work list after them,
ordered by priority. **Any agent can pick up an item**: each one says why, where in the code, and
what "done" means. When you start an item, set its status to `in progress (branch name)`; when it
lands, set `done (commit or PR)` and add anything the next agent needs under it.

Rules for all items (see CLAUDE.md for the details):
- **Poinky is for everyone**, not only developers: students reading lecture PDFs and doing homework, writers, office work. Pick examples and test cases from Preview, Notes, Pages/Docs, slides and the browser as well as code, and word prompts and UI without developer jargon.
- Build with `./build.sh`; run `tools/test-helpers.sh` before pushing. Ask before restarting the app.
- One commit per area, so each can be reverted alone. Branch first; the repo is public (no personal paths or emails).
- The user has limited usage: keep live `claude -p` tests small, prefer fakes (`tools/fake-helper.py`) and `swiftc` harnesses.

## 0. Already fixed: things that froze Poinky (done, PR tomyud1/poinky#2)
- A stalled Claude reply blocked every later question → `Brain.cancelCurrent()` (interrupt control_request) + 75 s no-output watchdog in `ClaudeCodeBrain`.
- ScreenCaptureKit hung when replayd crashed → `Deadline.run` (6 s) in `ScreenCapture`.
- SpeechAnalyzer died on device changes → `SpeechListener.onDied` → `CallController.restartListener`.
- Spoken errors that say what to do (`SpokenError`), a ↻ reset in the notch (`resetEverything`), the time in every question (`nowLine`).

## 1. Never stuck, and visible when something goes wrong (status: 1a–1c done on `poinky-reliability`; 1d, 1e open)
Why: `CallController.swift` (~2,450 lines, dozens of flags) is where freezes come from, and there was no record of what happened.
- 1a. `Timeline` (`Sources/Poinky/Timeline.swift`): one JSON line per event in `Poinky/timeline/YYYY-MM-DD.jsonl` (0600, 7 days): state changes, keys, capture ms, first token, first sound, cancels, watchdog restarts, timeouts, speech/audio restarts, resets. No words you said unless `conversationLog` is on.
- 1b. Stuck detector: `.thinking` / `.starting` for over 90 s → log the flags, `resetEverything()`, say so.
- 1c. Settings shows the median "keys released → first sound" (last 20) and a "Copy diagnostics" button.
- 1d. (Later, bigger) Replace the flags with one state enum with associated data, so impossible combinations can't exist. Do it in small steps behind the timeline, so regressions show up.
- 1e. (Later) A real `swift test` target for the pure logic (TalkParser, MarkSnapper, HelperTalk, HelperAsk, SpokenError, Recall), run in CI.
Done: a fake stall recovers by itself and the timeline shows why.
Notes for the next agent:
- Test the call loop with no mic and no tokens: `open -n -g --env POINKY_CLAUDE_CMD=$PWD/tools/fake-claude.py --env FAKE_CLAUDE_MODE=hang|deaf|crash|answer --env POINKY_TIMELINE_DIR=/tmp/tl build/Poinky.app --args --ask "question" --quit-after 25`, then read `/tmp/tl/*.jsonl`. `POINKY_STALL_SECS` shortens the watchdog, `POINKY_STUCK_SECS` the stuck detector.
- Measured with the fake: Poinky's own overhead from question to first sound is ~0.1 s (capture 45–75 ms), so real waits are almost all Claude's time to first token. That's item 2.
- Results 2026-11-08: hang → watchdog restart at ~10 s (8 s + 5 s timer tick), error spoken, back to ready. deaf (ignores interrupts) → stuck detector at 12 s, reset, apology, ready.
- Round 3 (2026-11-18, `r3/core`): the owner's 16 Nov timeline ended at "capture" with nothing after for a day: the main thread was blocked writing the question (with its screenshot) to a Claude Code that wasn't reading, right after a reboot. Fixed (writer queue); `tools/test-call-loop.py` now checks that and 10 more scenarios (stuck while starting, a walkthrough's states and a long quiet one, the teacher's order and failures, errors said as "speaking", the API brain after an interrupt). Still open: a session stuck in `.speaking` with nothing playing isn't detected (only `.thinking` / `.starting` are); a lookup keeps the state "speaking" while it's silent.

## 2. Speed and continuity in long sessions (status: talker done on `poinky-reliability`; teacher open)
Why: every question sends a full screenshot into one persistent `claude -p` session and nothing trims it, so after 15–20 questions each answer carries tens of thousands of old image tokens.
- Measure first (harness: 20 turns, time to first token and input tokens per turn).
- After N turns or a token threshold, swap to a warmed-up fresh talker seeded with a short summary (recent exchanges verbatim, older ones summarized by a background Haiku call). Never carry old screenshots.
- Send the commands list / earlier helpers in `talkerText` only when they changed or are asked about. Same check for guide/doer.
- Make "keys released → first word" the headline number (from 1a). Target under 1 s.
Done: flat first-token time and input tokens across 20 turns; follow-ups still work after a swap.
Measured 2026-11-08 (Haiku, real talker prompt, a 1568×1078 screenshot per question):
- Tokens read per answer grow ~2,500 per question: 11.4k at question 1, 39.5k at question 12.
- Time to first word stays ~0.8 s thanks to prompt caching, so the gain is mostly usage, not speed, until sessions get very long.
- A fresh `claude -p` answers its first question in ~3–3.7 s if the process starts with the question, but 0.83 s if it was started a few seconds earlier (the system prompt cache is shared across processes). So the fresh talker must be started ahead of time.
What was built:
- `CallController.prepareFreshTalker` (after `talkerRotateAfter` = 10 questions, warmed in the background) and `swapTalkerIfReady` (at the next question, once it has had 2.5 s): the new talker gets a recap of the last 8 exchanges from `history` (`needsRecap`), never old screenshots. Over 30 questions this roughly halves the tokens read (≈1.4M → ≈0.7M) and keeps the context far from its limit.
- `sendOnce`: the earlier-helpers list and the commands list go to the talker only when they change (or the question is about helpers): 2,141 → 341 characters per question when nothing changed.
- 2026-11-15: the talker was thinking again (Claude Code ignores `MAX_THINKING_TOKENS=0` for Haiku 5.5): first words took 1.7–5.4 s (median 3.5). `CLAUDE_CODE_EXTRA_BODY` turns thinking off: 0.7–1.2 s (median 1.0), measured with `tools/eval-talker/run.py`.
- `ClaudeCodeBrain` logs `usage` (tokens read, cached, written) for every answer in the timeline.
- Test: `POINKY_ROTATE_AFTER=2` with several `--ask`s and `FAKE_CLAUDE_LOG` (the fake logs its pid and each message).
Built (2026-11-15), speed: Claude Code ignored the no-thinking settings for Haiku 5.5 and Sonnet, so the talker thought 1–4 s before every answer. `ClaudeCodeBrain` now sends thinking off through `CLAUDE_CODE_EXTRA_BODY` on Automatic effort (Sonnet: `between_tools`), and retries once without it if the API refuses. Talker first words: median 3.5 s → 1.0 s; doer first act 2.3 s → 1.1 s.
Built (2026-11-15), continuity: `SessionSummary` (after each answer, in the background, ≤1,200 characters: Goal, Facts word for word, Files, Helpers, On screen, Open, Covered) plus the user's own lasting facts pinned the moment they're said (dates, deadlines, names; no model). After a swap: those facts go first in every message ("Still true from earlier in this session"), the recap is the summary + the last 5 exchanges. Swaps happen at ~70k tokens of context (`POINKY_ROTATE_TOKENS`), with 24 questions as a fallback. Test: `tools/eval-talker/continuity.py` (exam fact from question 2 needed at question 12 after a swap: 0/5 before, 15/15 after).
Still open (continuity): the API brain doesn't report its size (it still swaps by count); calibrate 70k from real timeline usage; a way to see the current summary.
Still open: the teacher (`artist`) also keeps every screenshot it was sent (it continues papers, so it needs a recap of what's on the paper); the guide keeps one session per walkthrough (fine for now).

## 3. Identity and long-term memory (status: files, daily notes and archive done on `poinky-reliability`; the daily promotion pass is open)
Why: `Memory.swift` keeps one list capped at 80 facts and silently drops the oldest.
- `identity.md` (Poinky's personality and boundaries), `user.md` (who the user is), `memory.md` (curated facts), daily notes `notes/YYYY-MM-DD.md` written by a cheap call when a session ends (today's and yesterday's load at start).
- A daily idle pass proposes promotions from notes into `memory.md` via `review.md`; merge instead of FIFO eviction.
- Inspired by OpenClaw's SOUL/USER/MEMORY files and daily notes.
Done: the talker uses identity and yesterday's note; nothing important is dropped silently.
What was built (2026-11-08):
- `Identity.swift`: `identity.md` (seeded with a short default personality) and `user.md` ("About me", empty until the user writes it), 0600, `<!-- -->` notes stripped, budgets 1,500 / 2,000 characters. `Identity.promptSection()` goes into the talker, guide and doer prompts before memory, and always counts (they're the user's own words). Settings → Memory: "Edit Poinky's Personality…", "Edit About Me…".
- `DailyNotes`: when a session ends (`endCall`), `CallController.writeDailyNote` asks the talker's model (one call, no tools, 45 s limit) for 1–4 lines about `sessionExchanges` → `notes/YYYY-MM-DD.md` under the time. On quit there's no time, so the plain fallback (`plainNote`) is written. Yesterday's and today's notes go into the prompt (`DailyNotes.promptSection`, 1,200 characters a day); `<recall>` searches every day's notes and the archive.
- `Memory`: when over 80 facts, the oldest move to `memory-archive.md` instead of being deleted.
- Tests: a swiftc harness (budgets, stripping, notes, archive: 10 checks); the app with the fake (`--end-after`, `POINKY_NOTES_DIR`; the fake logs whether its system prompt has identity / about me / notes and answers note requests); one real Haiku check (it answered "what was I working on yesterday?" from the note, briefly as the profile asked).
- Poinky changes both files over time, only in their "## Learned over time" part (the user's own text is never touched): the talker's `<remember about="user">` / `<remember about="poinky">` (and `<forget about=…>`) → `Identity.learn` / `unlearn` (near-duplicates replaced; caps 25 / 12 lines, the oldest go to the archive), and the end-of-session note writer adds up to 2 `ABOUT:` facts to user.md. Lookup replies can't (`onlySpeech`), and the prompt allows identity changes only when the user asks in their own words. Real Haiku check: "stop being polite, be blunt; I build strategy games in Godot in ~/Games" → about="poinky" for the style, about="user" for the projects.
Built (2026-11-18): user.md got trivia every session in a tester's runs ("Uses TextEdit", a page they viewed, a name Poinky called them or read off a homework sheet). Now `UserFacts` guards it in code: the note writer's `ABOUT:` line must quote the user's own words and the quote must be in what they said (not already in memory.md); a talker's `<remember about="user">` must share a word with what they just said. `tools/eval-talker/about-me.py` (six real sessions): the old writer added a line in all five trivia sessions; now 12/12 right over two runs.
Still open: a review step (a weekly look at what was learned, spoken or in Settings), and the same kind of guard for identity.md (`about="poinky"`).

## 4. Context beyond pixels (status: done on `poinky-reliability`; terminal folder open)
Why: "select a paragraph, hold ⌃⌥, say explain this" (or "fix this" on an error), and helpers that start in the right folder with no explaining.
What was built (2026-11-08): `AppContext.swift`. With each question, while the screenshot is taken (no extra wait; 0.5 s limit, 0.25 s per Accessibility call), `AppContextReader.read` gets the front app, its window title, the open document (`AXDocument`: Preview PDFs, TextEdit, Pages, editors), the web page (Safari's `AXDocument`, else a web area's `AXURL`: Chrome/Arc/Edge), and the selected text (`AXSelectedText`, up to 2,000 characters, never from secure fields or excluded apps). `AppContext.lines` go into the talker's message; the document's git repo (`projectFolder`) is named for helpers. URLs: http(s) only, secret-looking query parts removed, the meaningful ones kept (`v=`, `title=`). Setting `frontAppContext` (Settings → Privacy). The talker prompt has "What's in front of them" and non-coding helper examples.
Checked: `--read-context out.txt` (as the signed app) in Preview (lecture PDF + selection, 34 ms), TextEdit (essay + selection, 38 ms), Chrome and Safari (Wikipedia URLs, 53 / 114 ms). The app with the fake: the selection reaches Claude, capture still 69 ms. Real Haiku: "explain this like I'm 15" → a lesson about the selected sentences, marked on screen; "make me flashcards from this whole lecture" → a helper in the PDF's folder that saves Markdown + Anki CSV next to it.
Still open: Terminal/iTerm's working folder (not in Accessibility; maybe from the window title or the shell's process), Google Docs' document title in Chrome (the window title already has it), giving the teacher the selection too.

## 5. Speaking up first, safely (status: reminders + scheduled helpers done on `poinky-reliability`; triggers open)
- Scheduled and recurring tasks ("every morning, summarize my PRs").
- Triggers with opt-in: CI failed, tests broke in the terminal, a helper needs you.
- Everything respects the report rules (not while typing, not while locked).
What was built (2026-11-08): `Reminders.swift` + `CallController.checkReminders` / `deliverReminders`. The talker writes `<remind at="YYYY-MM-DD HH:MM" every="daily|weekdays|weekly|hourly" agent="title" dir="…">text</remind>` and `<remind-cancel>words|all</remind-cancel>`; `reminders.json` (0600, max 50). Checked every 20 s and on wake; due ones are said as a plain line (no model, `sayWhenFree`) when you're free (report rules), or their helper is started (`agent=`). Missed while asleep/off → "Earlier reminder: …". "Weekdays" follow the user's region (Israel: Sun–Thu). App Nap is held off when one is within 15 minutes. The talker sees the list when it changes or the question is about time (`sendOnce`).
Safety: helper reports (`ask(proactive:)`) now may only speak and mark (`lookupReply = proactive`), like lookup replies, since they're built from helper output; found when a fake report re-scheduled reminders.
Tests: swiftc harness (15 checks: times, repeats, due/late, cancel, region weekends), the app with the fake (`POINKY_REMINDER_TICK`, `POINKY_REMINDERS_FILE`; reminder said at 10.9 s for 11 s, scheduled helper started at 14.9 s), real Haiku (one-off, weekdays, daily helper with the folder).
Built (2026-11-15): Settings → General → Reminders lists them (when, repeat, helper) with a button to cancel each; empty, it gives two example phrases.
The notch's hover panel shows the next one within a day ("Reminder: Tomorrow 9:00 Email…").
Still open: triggers (CI failed, a test broke, a file changed, a calendar event soon), and asking before a scheduled helper does anything risky while you're away (it already raises its hand).

## 6. Easy to install (status: signing deferred; in-app Update and first-run tour done)
- Signed + notarized `.dmg` with automatic updates (Sparkle), instead of building from source.
- A 60-second first-run tutorial: hold to talk, tap to stop, point at a helper, ↻.
Decision (2026-11-08): no paid Apple Developer ID ($99/year) for now; it's an open-source app with one user. Revisit when there are users or a sponsor. Without it, a downloaded app is blocked by Gatekeeper and an ad-hoc signed one loses its permissions on every update, so for now:
- Keep `install.sh` (builds from source with the local signing certificate, so permissions survive updates) and make it friendlier: clearer progress, one-line fixes when something's missing, a "Poinky is ready, hold ⌃⌥" ending.
- Do the free parts now: the first-run tutorial, and an in-app "Update" (git pull + build.sh, keeping the certificate).

Built (2026-11-09): the in-app Update (`Updater.swift`). build.sh stamps the commit, its date, "local changes" and the source folder into Info.plist (`PoinkyCommit`, `PoinkyCommitDate`, `PoinkyDirty`, `PoinkySource`). Settings → General → Updates shows the version, checks the branch the source follows (`git fetch`, never a password prompt), lists what's new (commit titles), and Update builds in the background with a progress bar from Swift's `[n/m]` lines (log: `Poinky/update.log`); then "Restart Poinky" (with a warning when a session or helpers would be cut off). The installer's copy (`Poinky/source`) is reset to GitHub's version (and back if the build fails); any other folder is only fast-forwarded, never with uncommitted changes. An app in Applications gets the new copy staged as `Poinky.app.new`, swapped in by a small script after Poinky quits. It checks by itself 90 s after launch and every 6 h (setting `checkForUpdates`), and the notch shows a green arrow while one is available or ready. Nothing installs or restarts by itself.
Test without touching the real install: `tools/fake-build.sh` + `Poinky --update-test out.txt` (see CLAUDE.md → Testing).
Built (2026-11-15): the first-run tour (`Welcome.swift`, see CLAUDE.md): permissions one at a time, Claude Code check with Install / Sign in buttons, a first question on a sample, tap-to-stop / ⌃⌥T / ↻ tips that check off when you do them; replay from Settings → General or the menu bar (which also gained "Start Fresh", so Macs without a notch have the ↻ too). Verified with `--welcome-shot` pictures and launches with a fresh `POINKY_SUPPORT_DIR` (new install opens it, an existing config marks it done silently, quitting keeps it pending).
Built (2026-11-15, round two): a spoken hello at the cursor right after the tour (name from user.md if clearly written), a one-time "This is where I live" (the buddy flies to the notch, or the menu bar icon, the first time a session ends; existing users count as shown), plainer tour words ("control" / "option" under the keycaps). "Why isn't it working?" in Settings runs every tour check with a fix button each; `claude` is found inside the Claude desktop app or the Cursor / VS Code extension when it isn't on PATH.
Still open: rerunning `phonon/install.sh` when an update changes the voice's pinned versions; an automated check that a key press cuts the hello short; showing the notch's controls during "I live here"; the buddy pointing at the tour's sample problem.

## 7. Trust (status: receipts done on `poinky-reliability`; blurring open)
- Show clearly what each question sends.
- Blur secure fields, password managers and banking apps before anything leaves the Mac (OCR + AX, on device).
Built (2026-11-15): receipts (`Receipts.swift`, `ReceiptsWindow.swift`): each question keeps what went out (a thumbnail of the screenshot, the app/document/page/selection lines, which of the user's files went along by name and size, lookups, role and model, time), last 20, on the Mac only (0600), Clear button, setting `receipts` (off deletes them). The notch shows one quiet line "🔒 What I saw · …" only if something was sent in the last 12 h; clicking it opens the receipts window. A soft ring from the buddy after each screenshot sent (`SB.glance`). The notch's ↻ moved to Start Fresh (Settings, the ✨ menu, or saying "start fresh"), to keep the hover panel light.
Still open: blurring secure fields, password managers and banking apps; "don't send this one" (a moment to cancel after the ring); "what did you see?" read from the latest receipt; receipts for helpers and videos.

## 7b. Helpers for power users (status: done on `poinky-reliability`)
Why: coders who run several Claude Code sessions in terminals should find Poinky's helpers at least as capable and nicer.
Built (2026-11-15): a keyboard-first Helpers window (⌃⌥H): needs-you-first overview with each helper's folder, current step and time, Stop all; ⌘N starts a helper by typing (task or /command, folder, model, plan first); ⌘D shows the files it changed and their diff; ⌘T opens its session in Terminal (`claude --resume`); Copy summary; "@Mint …" in the type box; ⌘C/⌘V work in the type box and the window (they did nothing before: no Edit menu).
Built (2026-11-15, round two): no reused names ("Mint 2"), live tokens and a live cost estimate ("~$0.43", `HelperCost`), ⌘D for work kept on a `poinky/<name>-…` branch, talking to "Mint 2" by name ("Mint two", "@Mint2"), and Mac notifications (`HelperNotifier`) when a helper needs you outside a session or its question was parked: Allow / Don't Allow (risky ones in red, never "always", need the Mac unlocked), Go Ahead / Not Now for plans; they go away when answered anywhere; Settings → Claude → Notifications.
Still open: a live check of the real banners (tests use a fake notification center); answering a question's options from the notification; a spending cap per helper; the cost on the on-screen card.

## 7c. How the voice sounds (status: done on `poinky-reliability`)
Done: `SpokenText` (math, symbols, paths, links, dates, markdown, emoji said the way a person would; English voices only), `SentenceSplit` (no cuts after e.g./Dr./list numbers), whole sentences and other-script parts in another language go to Apple's voice for it, captions keep whole sentences. Test: `tools/test-voice.sh`; the voice itself was checked by synthesizing through `phonon_server.py` and transcribing the WAVs with SpeechAnalyzer.
Built (2026-11-15, round two): a short number at the end of a sentence is said in words for Phonon (it read "We need 7." as "7 point"; 30 of 180 test sentences failed, now 0); voice hand-overs mid-sentence keep 40 ms between words / 120 ms at a comma (gaps 240–285 ms → 70–165 ms) and Apple's voice for another script is warmed as soon as that text is seen; a little more pause after headings (0.3 s) and list items (0.22 s), inside the sentence's closing buffer so captions and steps stay in sync.
Still open: an automatic check against real Phonon audio (synthesize + transcribe, as a tool in `tools/`); room and flight numbers digit by digit; no list pause after the last sentence of a turn.

## 7d. Paper lessons (status: done on `poinky-reliability`)
Built (2026-11-15): math (fractions, powers, roots, Greek), `graph` / `plot` / `point` (curves from a math-only parser, never run as code), tables (rows added one sentence at a time), chemistry subscripts, labels beside arrows, text that shrinks to fit; the step being spoken stays in focus and clicking a past step redraws it; a chalkboard paper picked automatically on dark screens (`PaperLook.swift`, setting `paperLook`); Save (PNG) and Save all (one PDF of the session's pages), also by voice (`<save-lesson/>`, `pages="all"`). Test: `tools/tests/lesson-paper.html`, `tools/lesson-player.html`.
Still open: the session notebook lives only in the overlay (gone if Poinky quits; write it to disk as pages are kept); a light print version of chalkboard pages in the PDF; the talker remembering where your notes were saved.

## 7e. 3D models (status: done on `poinky-reliability`)
Built (2026-11-15): coloured cut faces, labels that follow what's left after a cut and hide when zoomed in, Reduce Motion, idle models stop redrawing, hover names; clicking a part names it and tells the talker; a question about a clicked part gets a short narrated close-up on the same model (`PartQuestion.swift`, `kit.run(…, {aside:true})` / `kit.endAside()`), saved as a note to replay; double-click a part for a closer look, Esc to go back. Tests: `tools/tests/kit-*.html`.
Still open: an app test mode that fakes a click (the click → question → spoken answer flow is only tested in parts); pointing at a part while holding ⌃⌥ counts as asking about it; tuning how far the close-up zooms over several models.

## 7f. The talker (status: done on `poinky-reliability`)
Built (2026-11-15): `tools/eval-talker/` (20+ scenarios across students, writers, office, coders, Hebrew, unsafe and injected text; real `claude -p` with the app's own prompt assembly) and `tools/test-talker.sh` in CI (replays 53 saved real replies through the app's `TalkParser`, no tokens). Instant yes: `<offer say="…">…</offer>` keeps a prepared action; a clear yes (English or Hebrew) runs it through `handle()` with the same checks and no model call; no drops it; it expires after 60 s or when the front app, window or selection changes (`Offer.swift`).
Still open: Haiku sometimes puts the email's greeting into a one-sentence rewrite; the doer swapping text in Pages/Mail is untested live; typing over an unchanged selection directly instead of using the doer; offering a fix (with the helper ready) after explaining an error; a scheduled live eval in CI (needs credentials).

## 7g. Quiet, and answers you can read (status: done on `r3/quiet`)
Built (2026-11-18): quiet mode (`quiet`, notch button, ⌃⌥Q, menu, Settings → Voice, "be quiet" / "you can talk again" without a model in `QuietPhrase`, or the talker's `<set>`): nothing is played (voice, earcons, helper sounds, video sound, notification sounds); the voice pipeline runs at reading pace in digital silence (`Speaker.isQuiet`, `QuietPace`), so captions, lesson steps, 3D holds, `<end/>` and reports keep their timing; the bubble shows the whole answer parked where it opened, scrolls, and stays with Copy (`SB.captionMode('read')`, `SB.captionDone`). Typed questions are answered in the type box (never said), with Copy and follow-ups. The notch keeps the last 5 answers with Copy; a spoken answer with a rewrite or command keeps that part in the bubble with Copy for 12 s (`Copyable`). Tests: `tools/quiet-test/run.sh`, `tools/tests/quiet-bubble.html`, call-loop scenarios quiet / quiet-end / quiet-lesson / voice / typed / quiet-words.
Still open: the buddy-off caption strip in quiet mode shows only the latest 240 characters with no Copy; ⌘C on a selection in the bubble (the overlay never takes the keyboard; Copy works); quiet mode doesn't skip Phonon's startup (it stays loaded so switching back is instant); a reading pace setting.

## 8. Later
- Approve helpers from the phone (`AwayNotifier` is the start).
- The user's connectors (calendar, email) through helpers.
- Windows.
