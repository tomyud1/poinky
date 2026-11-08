# Roadmap: making Poinky the everyday way to use AI

`docs/VISION.md` is the product story and the helper phases. This file is the work list after them,
ordered by priority. **Any agent can pick up an item**: each one says why, where in the code, and
what "done" means. When you start an item, set its status to `in progress (branch name)`; when it
lands, set `done (commit or PR)` and add anything the next agent needs under it.

Rules for all items (see CLAUDE.md for the details):
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

## 2. Speed that stays fast in long sessions (status: talker done on `poinky-reliability`; teacher and guide open)
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
- `ClaudeCodeBrain` logs `usage` (tokens read, cached, written) for every answer in the timeline.
- Test: `POINKY_ROTATE_AFTER=2` with several `--ask`s and `FAKE_CLAUDE_LOG` (the fake logs its pid and each message).
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
Still open: a review step (a weekly look at what was learned, spoken or in Settings), and a guard in code (not only the prompt) against identity changes suggested by on-screen text.

## 4. Context beyond pixels (status: proposed)
Why: power users want "select the error, hold ⌃⌥, say fix this" and helpers that start in the right project with no explaining.
- Send the selected text (AX `kAXSelectedTextAttribute` via `AppReader`), the browser tab's URL, the editor's open file path, the terminal's working folder.
- Use them to pick a helper's `dir` automatically.
Done: "fix this" with a selected stack trace starts a helper in the right repo.

## 5. Speaking up first, safely (status: proposed)
- Scheduled and recurring tasks ("every morning, summarize my PRs").
- Triggers with opt-in: CI failed, tests broke in the terminal, a helper needs you.
- Everything respects the report rules (not while typing, not while locked).

## 6. Easy to install (status: proposed)
- Signed + notarized `.dmg` with automatic updates (Sparkle), instead of building from source.
- A 60-second first-run tutorial: hold to talk, tap to stop, point at a helper, ↻.

## 7. Trust (status: proposed)
- Show clearly what each question sends.
- Blur secure fields, password managers and banking apps before anything leaves the Mac (OCR + AX, on device).

## 8. Later
- Approve helpers from the phone (`AwayNotifier` is the start).
- The user's connectors (calendar, email) through helpers.
- Windows.
