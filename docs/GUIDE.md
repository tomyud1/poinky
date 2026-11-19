# Poinky user guide

The full tour. For a quick start, see the [README](../README.md).

## Privacy

- **Your voice stays on your Mac.** Speech-to-text is Apple's on-device engine; the voice (Phonon or Apple) runs locally.
- **Screenshots and your transcribed question go to Claude** (through Claude Code or the Anthropic API), only when you ask something (and at each step while it's guiding you or acting for you). Nothing is captured in between.
- **See exactly what was sent:** hover the notch and click **What I saw** (or Settings → Privacy → Show What Poinky Saw). Each of the last 20 questions has a receipt: the screenshot, every line about the app in front, which of your files (personality, About me, memory, notes) were in Claude's instructions, and any web search. Receipts stay on your Mac; turn them off (which deletes them) in Settings → Privacy. A quick glint on the buddy shows each time Poinky takes a screenshot.
- **Password managers are never captured** (Passwords, Keychain, 1Password, Bitwarden, LastPass by default; add more in Settings → Privacy).
- Memory, settings and agent logs are plain files in `~/Library/Application Support/Poinky/`.
- **Photos you show Poinky** (from your iPhone, dropped, pasted, or "the photo I just AirDropped") are sent with that one question only. They're deleted from the Mac once sent, except in a homework session, where your work stays in that homework's folder (`study/`, readable only by you). Your own files are never moved or changed. Asking for "the photo I just AirDropped" is the only time Poinky looks in Downloads and on the Desktop (macOS asks you first).
- When a lesson shows a photo of something, Poinky searches Wikipedia for it (only the search words are sent, not your screen).
- No analytics, no accounts, no server of ours.

## Safety when it acts for you

- Asks out loud before anything that sends, posts, buys, deletes or submits; the app itself holds clicks on buttons like *Send* or *Buy* until you say yes.
- Never types into password fields, never signs in, never changes security settings.
- Won't press shortcuts that quit apps or delete things.
- Tap <kbd>⌃</kbd><kbd>⌥</kbd> or press <kbd>Esc</kbd> to stop it instantly; start talking to pause it. Turn it off entirely in Settings → General.
- Background agents can edit the project they're given and run a short list of safe commands; anything else they ask you first, out loud, and wait for your yes.


Hold two keys and talk with Claude about what's on your screen. It answers out loud and marks things on your screen. For anything worth explaining, a paper slides in and a yellow pen sketches the explanation step by step while Claude talks, even reaching out of the paper to circle things on your screen. It can also build interactive 3D models.

## Use it

1. Build: `./build.sh`, then open `build/Poinky.app`. Poinky lives in the **notch**. Idle, it's invisible. Hover it and it grows one slim row of icons (hands-free call, clear drawings, teacher on/off, end session, settings, quit) with the two shortcuts on its sides, plus Claude's last sentence if it spoke in the last minute. On screens without a notch, a ✨ menu bar icon is used instead (you can also turn it on in Settings).
2. **Hold ⌃⌥** (Control + Option) and talk. **Let go** and Claude answers. The mic is on only while you hold the keys.
   - A little blue **buddy** follows your cursor with a springy wobble. While you talk it shows your words next to it; while Claude thinks it turns into three orbiting dots; then Claude's words appear in its bubble as they're spoken, and it **flies over to point** at whatever Claude marks.
   - The **notch grows wings** with a soft glow: Listening (blue, with live mic bars), Thinking (violet dots), Speaking (orange bars). On screens without a notch, a tab appears at the top center.
   - Messages next to the buddy fade 2 s after Claude finishes (in quiet mode they stay until you're done; see "Quiet" below).
   - Soft sounds mark pressing, sending and nothing-heard (turn them off in Settings). They play through Poinky's own audio, so echo cancellation in hands-free calls doesn't swallow them.
   - **Hold again** to cut Claude off and ask something else. Holding again before Claude starts answering adds to your question. A **quick tap** of ⌃⌥ just stops it (nothing is sent).
   - **⌃⌥B** hides the buddy until your next question (also in the notch, and it can hide itself after some idle time: Settings → General).
   - Say **"bye"** and it says goodbye and ends the session.
   - Pressing ⌃⌥ together with another key (an app's shortcut) is ignored.
   - The first hold starts a session (two Claude sessions warm up while you're still talking). It ends by itself after 15 idle minutes, or from the ✨ menu.
3. Prefer hands-free? Press **⌃⌥Space** for a call: the mic stays on, a pause ends your question, and you can interrupt by talking over Claude. Press it again to hang up. During a hold-to-talk session, ⌃⌥Space switches it to a call and keeps everything on screen.
4. Point at things:
   - **Hover** over something and say "what's this?"
   - Claude marks only what helps, at the right size: a slim **bracket** in the margin for a whole paragraph or list item, an underline for a phrase, a circle for a small button. Marks fade 3.5 s after it finishes talking; papers and 3D models stay.
   - Your mouse position is only a hint for "this" or "here". Ask about "the whole message" or "this page" and Claude answers about all of it, wherever the mouse is.
   - When Claude marks text, it names the words it means and the app finds them on screen (with macOS text recognition), so a box around "item 3" covers item 3 exactly. Labels are white handwritten tags placed where they cover the least text.
   - **Drag while holding ⌃⌥** to circle or underline something as you talk (or use **⌥ + click / ⌥ + drag** on its own). A click drops a red pin. Claude also gets a sharp close-up of what you marked (and the text in it), so it answers about *that*, not the whole page.
5. Ask "what does this do?", "how does this work?", "show me", "now in 3D". You get a narrated sketch: a paper opens on the side away from what you asked about, and each drawing step plays as its sentence is spoken.
   - Each new question starts with a clean screen (old marks are removed); papers and 3D models stay until the topic changes. Drawings **build up** within a topic. A follow-up on the same topic **continues on the same paper**, and a follow-up about a 3D model **adds to that model** (e.g. "how do I connect a camera?" adds a camera module and animates the cable plugging in).
   - 3D models are narrated too: as each sentence is spoken, the model zooms to, highlights or animates the part being explained. A **list of steps** opens beside the model, one short note per sentence ("Fuel burns → turbine spins"), so you can catch up on anything you missed. **Click a note** to see that step again: the camera goes back to its view and its labels come back. Each step also gets a couple of seconds on screen before the next sentence starts.
   - **Hover a card** to use it: drag the title bar to move it, **drag a 3D model to rotate it**, scroll to zoom, ✕ to close.
   - Scrolling the page clears the quick marks (they'd no longer line up), but the close-up of what you circled is kept, so you can still ask about it. Cards stay.
   - Drawings belong to the window they're about: they hide when it's minimized, covered or on another desktop, come back with it, and move along when you drag it.
   - The paper is placed (and sized) in the largest free space next to what's being explained; captions move to the top when the bottom is busy, and fade out when Claude is done.

### Quiet: when you can't talk out loud
In a library, a lecture, an open office or a call, turn on **quiet mode**: the speaker button in the notch's row, **⌃⌥Q**, the ✨ menu, Settings → Voice, or just say or type "be quiet" ("you can talk again" turns it off). Then nothing is played: no voice, no interface or helper sounds, videos play muted with subtitles, and helper notifications come without a sound. A slashed speaker beside the notch shows it's on, and while it answers the notch says *Writing*.
- The answer is written in a bubble next to where the buddy was: the whole answer, not just the latest sentence, coming in at about reading speed. It stays where it opened while you move the mouse, scrolls when it's long, and stays until your next question, ✕, or a click somewhere else. **Copy** copies it (or just the rewrite or command in it).
- Drawings work the same: each lesson step is drawn with its sentence, 3D steps get their time on screen.
- You can still ask out loud (whispering works), or type.

### Typed in, text out
A question typed in the box (⌃⌥T) is answered **in the box**, in writing, never out loud: your question, then the answer as it comes, then **Copy** (select part of it and ⌘C works too). Type the next question right there as a follow-up. Esc or a click elsewhere closes it. Marks and papers still appear on screen. "@Mint …" still goes to that helper.

### The last answer doesn't disappear
Hover the notch: the last answer is one line with a copy button; click it to read all of it, with ‹ › for the few before. When a spoken answer has something to paste (a rewrite, a command, a line for an email), the bubble keeps just that part with **Copy** for a few seconds after Poinky stops talking.

### It knows you
Poinky remembers things about you between sessions (your name, what you're working on, what interests you, how you like answers) and uses them to feel like a friend who remembers. It's a plain list stored only on this Mac: read, edit or clear it in Settings → Memory, or say "forget that" / "what do you remember about me?".

### It knows itself
Ask "how do I make you talk faster?" or "what can you do?": it has a built-in manual and sees your current settings. It can change a few safe ones itself ("talk faster", "hide the buddy", "turn off the sounds", "turn the teacher off").

### Background agents: "put an agent on it"
Because it runs on Claude Code, Poinky can start an **agent**: a separate Claude Code session that works on your project in the background (fix a bug, add a feature, write tests, research something) with your normal Claude Code setup. A small dot by the notch shows agents are working. When one finishes, Poinky tells you what it did, waiting until it's done talking (or folding it into your next question). Agents may edit files in the project and run a short list of safe commands (tests, `git status`/`diff`/`log`). For anything else (installing a package, deleting a file, pushing, running a script) the helper raises its hand: it flies to you and Poinky says what it wants ("Mint wants to run npm install left-pad. Is that okay?"). Say yes or no (hold ⌃⌥, or just answer in a hands-free call); "no, use yarn instead" tells it why. A helper can also ask you a question ("Where should I keep the settings?"): answer with one of the choices or "you choose". If you don't answer, it goes back to the edge with a "?" and keeps waiting while the others work; answer it later by name ("Mint, yes"), by pointing at it, or with the Allow / Don't allow buttons on its card. Nothing is ever approved without you, and pushing, deleting and installing always ask, even in auto mode. Settings → Claude can switch agents between auto mode (the default: it asks less often), editing the project and asking for the rest, or making a plan first. Full logs: `~/Library/Application Support/Poinky/agents/`.

**The Helpers window** (click Open on a helper's card, ✨ menu → Helpers…, or a report in the notch) shows each helper's work as it happens: its notes, its steps grouped and collapsed ("Read 3 files, ran 2 commands", click to see each command), its to-do list, what it asked and what you answered, and its summary with how long it worked and what it used. Earlier helpers are listed too, also from before Poinky restarted. Type in the box to send it a message (paste errors and code; Shift-Return for a new line). Type to a finished one, or say "Mint, also update the README", and it picks up where it left off, in its own Claude Code session.

**More you can do with helpers:**
- **Type instead of talk:** ⌃⌥T opens a box by the mouse ("Ask Poinky…"). Over a helper, it types to that helper.
- **Pause and steer:** "Mint, wait" stops what it's doing without ending it; then tell it what to do instead, or "go on". "Mint, actually use yarn" does both at once. The window has Pause / Go on.
- **Plan first:** "make a plan first" (or Settings): the helper comes back with its plan, Poinky says what it's about, and the window shows all of it. "Go ahead" starts it; tell it what to change and it revises the plan; "not now" keeps it a plan.
- **A model for one task:** "use Opus for this one".
- **Undo:** "undo what Mint did" (or Undo these changes in its window) puts back the files it changed in its last run, using Claude Code's checkpoints. If one of them changed after it finished (maybe by you), Poinky doesn't touch anything and the window asks you first.
- **Several at once:** big tasks can be split between helpers. Helpers working in the same git repo at the same time each get their own copy (a git worktree), and their changes come back into your folder when they finish; if they overlap with other changes, they're kept on a branch (`poinky/…`) and the report says so.
- **Your commands and skills:** "run a code review on this", "do a security review": the main agent starts a helper with your command (`/review` …).
- **Git:** "commit this", "open a PR and watch the checks". Pushing and opening a PR always ask you first.
- **The mouse:** a helper that uses your mouse and keyboard (or Chrome) asks the first time; only one uses them at a time, the others wait their turn.
- **Usage:** "how much have the helpers used today?" Each helper's window shows what each run used.
- **Notifications:** a question from a helper while you're not talking to Poinky becomes a Mac notification with Allow / Don't Allow (Settings → Claude → Notifications).

### Demo
`python3 demo/serve.py` opens six realistic, made-up scenes for showing Poinky off: a social feed, a code editor, a notes doc with a checklist, a transit dashboard, an encyclopedia article and a notes app. They all work like the real thing (click, type, check things off), so Poinky can walk you through actions. The code editor shows the real files in `demo/sample-project` live and its terminal really runs the tests, so you can watch a background agent fix the bug. `demo/DEMO-SCRIPT.md` is a recording script.

### Doing it for you: "fill this in", "write an email to Sam…"
Ask Poinky to *do* something and it uses your mouse and keyboard while telling you what it's doing: fill a form, write an email or a note, type a prompt into another AI tool, change a setting. The cursor glides to each spot (a small ring shows each click). It reads the app through macOS accessibility (its buttons, fields and menus), so it clicks the real thing and formats text the way the app expects.

Safety: it asks out loud before anything that sends, posts, buys, deletes or submits (and the app itself holds clicks on buttons like Send or Buy until you say yes); it never types into password fields; it won't press shortcuts that quit apps or delete things. Tap ⌃⌥ or press Esc to stop it instantly; start talking to pause it. It needs Accessibility permission (macOS asks the first time), and you can turn it off in Settings → General.

### Homework together: "let's do this homework together"
Open the problem sheet (a PDF in Preview, a web page) and say "let's do this homework together", "walk me through question 2" or "בוא נפתור את שאלה 1 ביחד". Poinky reads the question, tells you what it's about and sketches the setup (without the parts), then shows part א and waits. From there you lead: ask anything about it, say "a hint" (three, each a little further: the idea, the equations, the next step), "I'll try it myself", "show me" (the full worked solution: assumptions, a figure with axes, the derivation, the result boxed), "next", "skip", "go back to א", "where are we?" or "let's stop for today".
To check your own work on paper, click **📷 My work** on the paper (or say "check my work" while the sheet is on screen, or "I'll take a picture"): a menu opens with your iPhone; pick **Scan Documents** (best for paper: it finds the page and straightens it) or **Take Photo**, and point the phone at your page. A small card shows what came, with Retake and + Page (several pages of one part, in order); after a few seconds it's checked (rest the mouse on the card to look longer, or click Check now). Work that's on screen ("check my work" with your notes app or a photo open in front) is checked from the screen as before. Poinky rewrites your solution on the paper line by line, ticks each right line, and stops at the first wrong one with a red ✗ and a short note, then offers a hint to fix it or the corrected way on. If it can't read a line it asks instead of guessing. Before any hint past the first, a check or a full solution, a stronger model works the question out by itself, so Poinky never judges your work by how it looks.
No iPhone at hand? Drop a photo or a PDF (an iPad export of your notes) on the paper or the notch, paste one into the type box (⌃⌥T, then ⌘V), or AirDrop it to the Mac and say "use the photo I just AirDropped" (Poinky shows you the newest picture in Downloads or on the Desktop and asks before using it). Your photos stay on this Mac in the homework's own folder (original and cleaned-up copy, only readable by you) and the Receipts window says when one was sent.
Everything is saved as you go (Poinky's support folder, `study/`): if the session ends or you come back days later, say "let's continue the homework" and it picks up where you were. After every finished part it rebuilds **the solved PDF** next to your sheet ("<sheet> – solved.pdf", or "– פתרון" for a Hebrew sheet): the sheet's own pages, then each part under its heading with your own work (when you solved it) or Poinky's worked pages. Say "put my work in" / "use yours" / "both" to choose for a part, "open the PDF" or "where is it?", or click PDF on the paper. Poinky only ever replaces a PDF it made itself.

### Show it something on paper: a photo from your iPhone
Outside homework too: click the camera in the notch (or press ⌃⌥P, or say "I'll take a picture of it"), pick your iPhone's **Take Photo** or **Scan Documents** in the menu, and shoot. The picture goes with your next question ("what's wrong with this circuit?"); say the question together with "I'll take a picture of the circuit, what's wrong with it?" and it's asked as soon as the photo arrives. The iPhone needs to be near the Mac, unlocked, signed in to the same Apple ID, with Wi‑Fi and Bluetooth on; when none is found, the card says so and offers the other ways in (drop a picture or PDF on the paper or the notch, paste one into the type box, "use the photo I just AirDropped", or Choose a file).

### Guide mode: "how do I…?"
Ask how to do something in the app you're in ("how do I export this as a PDF?", "where do I change the font?"). Poinky says the first step and circles exactly what to click, then **waits for you to click it**, looks again, and gives the next step until you're done. Hold ⌃⌥ and say "next" after typing something, ask a question any time, or say "stop" to end it. For a one-click task it just points at the button.

Tip: in busy feeds (X, Instagram), circle the post first with ⌥-drag so the guide knows exactly which one you mean.

### First run

- macOS asks for **Microphone** and **Speech Recognition**. **Screen Recording** is turned on by hand in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Poinky.
- The first session may download Apple's speech model (one time).
- **Voice:** Poinky speaks with **Phonon** (Gradium's Phonon 31m), a free neural voice that runs on your Mac, offline (English, 25 voices). Pick a voice in Settings → Voice (▶ plays a preview). If it isn't installed, Settings → Voice → Install adds it (about 75 MB). For other languages it uses Apple's voice from System Settings → Accessibility → **Read & Speak** → System voice.

Poinky is signed with a local certificate ("Poinky Local Signing", created by `build.sh` the first time) or your Apple Development certificate, so macOS keeps the permissions across updates and rebuilds.

## How it works

```
 you talk ──► on-device speech-to-text (Apple SpeechAnalyzer + voice processing)
                      │  real silence
                      ▼
               screenshot + what you said + cursor + your marks + what's already drawn
                      │                         (+ on-device text recognition, to snap marks onto words)
          ┌───────────┴────────────┐
          ▼                        ▼
   TALKER (Haiku, ~1.5 s)    TEACHER (Sonnet, streams in parallel)
   answers or hands over     writes a storyboard: <say> line, <step> drawing, <say>, <step>…
   in one line, marks the    each line is spoken (Phonon) and its step is drawn by the
   screen instantly          yellow pen at the same moment; or builds a 3D model
```

- **Listening:** Apple's newer on-device speech engine. The mic uses the same voice processing as FaceTime (echo cancellation, noise suppression, auto gain), so you don't need to raise your voice, and Claude's own voice is removed from the mic so you can interrupt it.
- **Speaking:** Phonon 31m runs locally in a small helper that stays loaded (`phonon/phonon_server.py`, Phonon's Rust engine through its `ptts` package, 8-bit weights on the performance cores). It streams each sentence in chunks as it's made, so the voice starts about 25 ms after a sentence arrives (Kokoro took about half a second), at roughly 35× real time. The silence Phonon puts around each sentence is trimmed as it streams, so sentences follow each other with a natural pause. Interrupting stops it mid-sentence. If it fails, Apple's voice takes over.
- **Installing Phonon:** The main installer runs `phonon/install.sh` (the app can run it too: Settings → Voice → Install, and it runs by itself for people updating from the old Kokoro voice, which it then removes). It sets up a private Python environment with uv's own Python (installing [uv](https://docs.astral.sh/uv/) into the settings folder if you don't have it), installs the pinned runtime (`ptts==0.6.0`), and downloads the model and 25 voices from Hugging Face at pinned revisions (~75 MB, every file checked against its SHA-256). It makes the helper speak once to check it works. Run it again any time; it only fixes what's missing or damaged.
- **Two Claude sessions** stay open for the whole call, so each question skips the startup cost.
- **Cards** run inside sandboxed frames with no network access. If a 3D model's code crashes, the error goes back to the artist, which fixes it once automatically.

## Settings

✨ menu → **Settings…** (⌘,) opens the settings window: hold-to-talk keys, call shortcut, language and pause length, buddy and sounds, voice picker with ▶ preview and speed, Claude connection and Quick / Careful, **Privacy** (apps that are never captured; password managers are excluded by default), and prompt editing. Everything is stored in `~/Library/Application Support/Poinky/config.json`:

| Key | Default | What it does |
|---|---|---|
| `brain` | `claudeCode` | `claudeCode` (your subscription) or `api` (API key) |
| `artistEnabled` | `true` | Turn the diagram/3D artist on or off (also in the menu) |
| `claudeCodeModel`, `artistModel`, `guideModel`, `doerModel` (and `api…` for the API brain), `talkerEffort`, `artistEffort`, `guideEffort`, `doerEffort` | Quick | Each part's model and effort. Settings → Claude sets them all at once with **Quick** (the defaults: Haiku talks, Sonnet teaches and does things) or **Careful** (Sonnet talks, the teacher thinks first, Opus does things); any other mix shows as Custom and is edited under Settings → Advanced. |
| `apiKey` | | Anthropic API key (API brain only) |
| `language` | `en-US` | e.g. `he-IL` for Hebrew (uses Apple's dictation engine). Claude replies in the language you speak. |
| `voiceEngine` | `phonon` | `phonon` (free local neural voice) or `apple` |
| `phononVoice` | `Easton` | US: Easton, Micah, Trevor, Russell, Preston, Miles (male), Zoey, Juniper, Everly, Harper, Hadley, Delia (female). UK: Alfie, Hugh, Edwin, Spencer, Toby, Teddy (male), Maeve, Freya, Pippa, Elodie-Rose, Imogen, Lottie, Bryony (female). |
| `voiceSpeed` | `1.0` | Natural voice speed (0.86–1.24; Phonon's speed control is reliable in that range) |
| `voice` | your System voice | Apple voice name (used for non-English, or if the natural voice is off) |
| `speechRate` | `0.53` | Apple voice speed, 0–1 |
| `pushToTalk` | `ctrl+option` | Keys to hold while talking: `ctrl+option`, `ctrl+shift`, `option+cmd`, or `off` |
| `buddy` | `true` | The buddy at your cursor (captions appear next to it instead of at the bottom) |
| `sounds` | `true` | Soft interface sounds |
| `quiet` | `false` | Quiet mode: answers are written (with Copy), nothing is played |
| `quietHotkey` | `ctrl+option+q` | Turns quiet mode on / off |
| `menuBarIcon` | `false` | Also show ✨ in the menu bar (always shown when no screen has a notch) |
| `buddyHotkey` | `ctrl+option+b` | Hides / shows the buddy |
| `buddyAutoHide` | `0` | Hide the buddy this many seconds after it finishes (0 = never, 3 = right after it answers); it comes back when you hold ⌃⌥ |
| `memoryEnabled` | `true` | Remember things about you between sessions |
| `agentPermission` | `auto` | Background agents: `auto` (Claude Code's auto mode; falls back to `acceptEdits` if it can't start), `acceptEdits` or `plan` |
| `computerControl` | `true` | Let Poinky click and type for you when you ask it to do something |
| `agentModel` | | Background agents' model (empty = your Claude Code default) |
| `silenceSeconds` | `1.0` | Hands-free calls: how long a pause ends your question |
| `hotkey` | `ctrl+option+space` | Starts / ends a hands-free call, e.g. `cmd+shift+k`, `f13` |

## The prompts (the "skill")

Two prompt files define the behavior and can be edited without rebuilding (✨ menu → **Edit Talker Prompt…** / **Edit Artist Prompt…**, which edit copies in the settings folder; delete a copy to go back to the built-in one):

- `prompts/talker-prompt.md`: how to talk, how to mark the screen, and when to ask the artist for a picture.
- `prompts/artist-prompt.md`: the teacher: the lesson format (narrated `<say>` and `<step>` pairs), the pen's drawing operations (text, box, arrow, line, dot, check, number, mark, screen marks, erase, new page), pacing rules, and the 3D kit reference.

The 3D kit (`web/kit.js`) gives the artist simple building blocks on top of three.js:
- Parts: `body` (fuselages, bottles), `plate` (wings, boards), `fin`, `box`, `cylinder`, `tube` (cables)
- Callouts: `label` (colored tags with leader lines)
- Motion: `arrow` and `flow` (animated forces, air, current), `spin`, `move` (assembly steps)
- Narration: `get` (find a named part), `highlight` (glow and pulse), `focus` (zoom the camera to a part), `remove`. Each spoken line can run a `<step3d note="…">` in the live model; the note is its line in the list of steps beside the model.
- Look and feel: real soft shadows, rounded `box` edges, `ground` (shadow-only floor), `person` and `measure` for scale; parts drop in one by one and the camera swoops in. 3D models are placed by the app in free space beside what's being explained.

## Code map

| File | What it does |
|---|---|
| `CallController.swift` | The session: hold-to-talk and hands-free calls, interrupting, talker + artist, menu bar |
| `PushToTalk.swift` | Detects holding ⌃⌥ (by polling the modifier keys, so no extra permission) |
| `NotchHome.swift` | The notch: status wings with a glow, and the hover panel with controls (SwiftUI) |
| `Earcons.swift` | The interface sounds, synthesized in code |
| `Memory.swift` | What Poinky remembers about you (`memory.md`) |
| `AgentManager.swift` | Background Claude Code agents and their logs: start, follow-ups, pause, answers, resume, undo, the mouse |
| `HelperWindow.swift` + `web/helper-window.html` | The Helpers window: the list, each helper's work live, typing to it, continuing and undoing |
| `HelperTranscript.swift` | What the window shows (`.chat.jsonl` entries) and earlier helpers (`PastHelper`) |
| `HelperUndo.swift` / `HelperWorktree.swift` | Undo with Claude Code's checkpoints; worktrees for helpers sharing a repo |
| `TypeBox.swift` | ⌃⌥T: typing to Poinky or a helper |
| `prompts/poinky-manual.md` | The app's own manual, given to the talker |
| `AudioIO.swift` | Playback, the hold-to-talk mic, and the hands-free mic with voice processing |
| `SpeechListener.swift` | On-device speech-to-text; ends a question on a pause (calls) or when you let go |
| `Speaker.swift` | Sentence-by-sentence voice through the shared engine |
| `Brain.swift` | The swappable `Brain` protocol and the reply parsers |
| `ClaudeCodeBrain.swift` / `APIBrain.swift` | The two brain types |
| `PhononVoice.swift` + `phonon/` | The local neural voice (helper process, streaming, in-app installer) and its install script |
| `VoiceActivity.swift` | Real silence detection from the mic level |
| `ScreenCapture.swift` | Screenshot with your marks, sized so Claude's coordinates line up |
| `Overlay.swift` + `web/overlay.html` | The click-through window, hand-drawn marks and cards |
| `web/lesson.js` | The paper, the yellow pen, and narration-synced drawing |
| `web/buddy.js` | The cursor buddy and its caption bubble, the notch status pill, interface sounds |
| `MarkSnapper.swift` | Text recognition: finds the text Claude names (`find`/`to`), snaps marks onto it, places labels |
| `web/kit.js` | The 3D kit; `vendor/three.min.js` is three.js r160 |

## Known limits

- A brand-new 3D model takes ~20 s for Sonnet to write. The teacher starts talking right away, and the model pops in when it's ready (a "🎨 Drawing…" badge shows meanwhile). Follow-ups on an existing model are quick. `artistModel: "haiku"` is ~3× faster but simpler.
- It draws on one screen at a time. Holding ⌃⌥ on another screen moves the buddy there, unless something is still drawn on the first one.
- The mic switches on the moment you press ⌃⌥, so using another app's ⌃⌥ shortcut can flash the mic indicator briefly (nothing is sent).
- Through laptop speakers, echo cancellation is good but not perfect. Headphones make interrupting most reliable.
