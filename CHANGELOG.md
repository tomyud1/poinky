# Changelog

All notable changes to Poinky. The format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- Helpers (background agents) get names (Mint, Coral, Violet…), live progress in plain words ("Reading tipsplit.py", "Running the tests"), their to-do lists, and a record of anything they weren't allowed to do. This is the groundwork for seeing them on screen.
- You can send a working helper a follow-up; it folds it into its work.
- At most 3 helpers work at once (Settings → Background agents, 1 to 6); more wait in line and start by themselves.
- Helpers show up on screen: a small colored cursor buds off the buddy, takes its task, flies to the edge of the screen and shows what it's doing, then flies back when it's done. Poinky names it out loud ("I'll have Mint fix that").
- Helpers stay out of your way: they work at the side with more room beside your window, never pile up on each other, and a card fades when your mouse passes over it. Rest the mouse on a helper to see its task, its to-do list and recent steps, how long it's been working, and Stop, Log and Folder buttons.
- Finished helpers wait for you: each celebrates at the edge, then waits with a small badge until you're free (not while you're talking, typing or away). Then it flies to the buddy while Poinky tells you what it did, and merges back in. Rest the mouse on a waiting helper to read its whole summary. Two finishing together don't play their sounds on top of each other.
- Talk to a helper: hold ⌃⌥ while pointing at it and say "also add a test", "what are you doing?" or "stop". Its card opens and listens; a follow-up goes straight into its work, a status question is answered right away from what it's reported, and "stop" stops it. By name works too ("how's Mint doing?", "tell Coral to skip the docs").
- Helpers raise their hand instead of being refused: when one needs something it isn't allowed to do on its own (install a package, delete a file, push, run a script) or has a question for you, it flies to you and Poinky says what it wants ("Mint wants to run npm install left-pad. Is that okay?"). Say yes or no ("no, use yarn instead" tells it why), or answer its question ("the second one", "you choose"). One asks at a time; the others keep working. Unanswered, it goes back to the edge with a "?" and waits: answer later by name ("Mint, yes"), by pointing at it, or with Allow / Don't allow on its card. Nothing is approved without you, and pushing, deleting and installing always ask, even in auto mode.
- Helpers now use Claude Code's auto mode by default, so they ask you less often (installing, deleting and pushing still always ask). If your Claude Code or plan doesn't have auto mode, a helper starts again without it by itself. Settings → Claude → Background agents can switch it.
- The Helpers window: each helper's work as it happens (its notes, its steps grouped and collapsed, its to-do list, what it asked and what you said, its summary and what it used), and earlier helpers too, also from before a restart. Open it from a helper's card, the ✨ menu or a report in the notch.
- Type instead of talking: ⌃⌥T opens a box by the mouse to ask Poinky (or, over a helper, to tell that helper). The Helpers window has a box for each helper too; paste errors and code with Shift-Return for new lines.
- "Mint, wait" pauses a helper without ending it; tell it what to do instead, or "go on". "Mint, actually…" changes its direction right away.
- "Make a plan first": the helper comes back with its plan and waits for "go ahead" (or what to change). Settings can make every helper plan first.
- "Use Opus for this one": a model for a single task.
- Continue a finished helper ("Mint, also update the README", or type to it), in its own Claude Code session, also after Poinky restarts.
- Undo: "undo what Mint did" (or Undo in its window) puts back the files a helper changed, with Claude Code's checkpoints. Files changed since are never overwritten without asking.
- Helpers working in the same git repo at once each get their own worktree, and their changes come back into your folder when they finish (or onto a branch if they overlap).
- Helpers can run your Claude Code commands and skills ("run a code review on this"), and do git work by voice ("commit this", "open a PR and watch the checks").
- Only one helper at a time uses your mouse and keyboard (or Chrome); you're asked once per helper.
- "How much have the helpers used today?", with Claude Code's plan-limit status.
- Away mode (off by default): when you're away from the Mac, a helper's question reaches your phone through the ntfy app, with buttons to answer.
- Choose the model and effort for each part of Poinky (talker, teacher, guide, doer and helpers) in Settings → Claude. Settings also warns when your Claude Code is too old for the newest models, with an Update button.
- The notch keeps the last three helper reports: a colored dot for each one you haven't heard yet, and a list when you hover (click one to open its log).
- A sound volume slider in Settings (next to the sounds switch). It plays a sample when you let go, and you can also say "make the sounds quieter".
- The Agent Lab (`web/agents-lab.html`): a playground for how helpers look, move and sound, with a timeline and sliders, and sounds that can be saved as `.wav` files.
- Each helper's raw output is kept next to its log (`.jsonl`), and `tools/fake-helper.py` can replay it for testing without tokens (`tools/test-helpers.sh`).

## [0.1.0] - 2026-11-02

First public release.

### Added
- Hold ⌃⌥ and ask about your screen; Poinky answers out loud, marks the screen and sketches the explanation with a yellow pen, or builds a narrated 3D model.
- Hands-free calls (⌃⌥Space), guide mode ("how do I…?") and acting mode ("do it for me") with spoken confirmation before risky clicks.
- Background Claude Code agents, memory between sessions, and a settings window.
- Natural on-device voice (Kokoro) with Apple's voices as a fallback.
- One-line installer (`install.sh`) that checks the Mac, builds the app, installs the voice and offers Claude Code. It also supports `--no-voice`, `--uninstall` and `--purge`.
- `build.sh` creates a local "Poinky Local Signing" certificate so macOS keeps permissions across updates, with no Apple Developer account needed.

[0.1.0]: https://github.com/tomyud1/poinky/releases/tag/v0.1.0
