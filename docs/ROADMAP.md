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

## 1. Never stuck, and visible when something goes wrong (status: in progress, branch `poinky-reliability`)
Why: `CallController.swift` (~2,450 lines, dozens of flags) is where freezes come from, and there was no record of what happened.
- 1a. `Timeline` (`Sources/Poinky/Timeline.swift`): one JSON line per event in `Poinky/timeline/YYYY-MM-DD.jsonl` (0600, 7 days): state changes, keys, capture ms, first token, first sound, cancels, watchdog restarts, timeouts, speech/audio restarts, resets. No words you said unless `conversationLog` is on.
- 1b. Stuck detector: `.thinking` / `.starting` for over 90 s → log the flags, `resetEverything()`, say so.
- 1c. Settings shows the median "keys released → first sound" (last 20) and a "Copy diagnostics" button.
- 1d. (Later, bigger) Replace the flags with one state enum with associated data, so impossible combinations can't exist. Do it in small steps behind the timeline, so regressions show up.
- 1e. (Later) A real `swift test` target for the pure logic (TalkParser, MarkSnapper, HelperTalk, HelperAsk, SpokenError, Recall), run in CI.
Done: a fake stall recovers by itself and the timeline shows why.

## 2. Speed that stays fast in long sessions (status: proposed)
Why: every question sends a full screenshot into one persistent `claude -p` session and nothing trims it, so after 15–20 questions each answer carries tens of thousands of old image tokens.
- Measure first (harness: 20 turns, time to first token and input tokens per turn).
- After N turns or a token threshold, swap to a warmed-up fresh talker seeded with a short summary (recent exchanges verbatim, older ones summarized by a background Haiku call). Never carry old screenshots.
- Send the commands list / earlier helpers in `talkerText` only when they changed or are asked about. Same check for guide/doer.
- Make "keys released → first word" the headline number (from 1a). Target under 1 s.
Done: flat first-token time and input tokens across 20 turns; follow-ups still work after a swap.

## 3. Identity and long-term memory (status: proposed)
Why: `Memory.swift` keeps one list capped at 80 facts and silently drops the oldest.
- `identity.md` (Poinky's personality and boundaries), `user.md` (who the user is), `memory.md` (curated facts), daily notes `notes/YYYY-MM-DD.md` written by a cheap call when a session ends (today's and yesterday's load at start).
- A daily idle pass proposes promotions from notes into `memory.md` via `review.md`; merge instead of FIFO eviction.
- Inspired by OpenClaw's SOUL/USER/MEMORY files and daily notes.
Done: the talker uses identity and yesterday's note; nothing important is dropped silently.

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
