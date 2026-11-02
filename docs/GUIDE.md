# Poinky user guide

The full tour. For a quick start, see the [README](../README.md).

## Privacy

- **Your voice stays on your Mac.** Speech-to-text is Apple's on-device engine; the voice (Kokoro or Apple) runs locally.
- **Screenshots and your transcribed question go to Claude** (through Claude Code or the Anthropic API), only when you ask something (and at each step while it's guiding you or acting for you). Nothing is captured in between.
- **Password managers are never captured** (Passwords, Keychain, 1Password, Bitwarden, LastPass by default; add more in Settings → Privacy).
- Memory, settings and agent logs are plain files in `~/Library/Application Support/Poinky/`.
- When a lesson shows a photo of something, Poinky searches Wikipedia for it (only the search words are sent, not your screen).
- No analytics, no accounts, no server of ours.

## Safety when it acts for you

- Asks out loud before anything that sends, posts, buys, deletes or submits; the app itself holds clicks on buttons like *Send* or *Buy* until you say yes.
- Never types into password fields, never signs in, never changes security settings.
- Won't press shortcuts that quit apps or delete things.
- Tap <kbd>⌃</kbd><kbd>⌥</kbd> or press <kbd>Esc</kbd> to stop it instantly; start talking to pause it. Turn it off entirely in Settings → General.
- Background agents can edit the project they're given and run a short list of safe commands; everything else is refused.


Hold two keys and talk with Claude about what's on your screen. It answers out loud and marks things on your screen. For anything worth explaining, a paper slides in and a yellow pen sketches the explanation step by step while Claude talks, even reaching out of the paper to circle things on your screen. It can also build interactive 3D models.

## Use it

1. Build: `./build.sh`, then open `build/Poinky.app`. Poinky lives in the **notch**. Idle, it's invisible. Hover it and it grows one slim row of icons (hands-free call, clear drawings, teacher on/off, end session, settings, quit) with the two shortcuts on its sides, plus Claude's last sentence if it spoke in the last minute. On screens without a notch, a ✨ menu bar icon is used instead (you can also turn it on in Settings).
2. **Hold ⌃⌥** (Control + Option) and talk. **Let go** and Claude answers. The mic is on only while you hold the keys.
   - A little blue **buddy** follows your cursor with a springy wobble. While you talk it shows your words next to it; while Claude thinks it turns into three orbiting dots; then Claude's words appear in its bubble as they're spoken, and it **flies over to point** at whatever Claude marks.
   - The **notch grows wings** with a soft glow: Listening (blue, with live mic bars), Thinking (violet dots), Speaking (orange bars). On screens without a notch, a tab appears at the top center.
   - Messages next to the buddy fade 2 s after Claude finishes.
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
   - 3D models are narrated too: as each sentence is spoken, the model zooms to, highlights or animates the part being explained.
   - **Hover a card** to use it: drag the title bar to move it, **drag a 3D model to rotate it**, scroll to zoom, ✕ to close.
   - Scrolling the page clears the quick marks (they'd no longer line up), but the close-up of what you circled is kept, so you can still ask about it. Cards stay.
   - Drawings belong to the window they're about: they hide when it's minimized, covered or on another desktop, come back with it, and move along when you drag it.
   - The paper is placed (and sized) in the largest free space next to what's being explained; captions move to the top when the bottom is busy, and fade out when Claude is done.

### It knows you
Poinky remembers things about you between sessions (your name, what you're working on, what interests you, how you like answers) and uses them to feel like a friend who remembers. It's a plain list stored only on this Mac: read, edit or clear it in Settings → Memory, or say "forget that" / "what do you remember about me?".

### It knows itself
Ask "how do I make you talk faster?" or "what can you do?": it has a built-in manual and sees your current settings. It can change a few safe ones itself ("talk faster", "hide the buddy", "turn off the sounds", "turn the teacher off").

### Background agents: "put an agent on it"
Because it runs on Claude Code, Poinky can start an **agent**: a separate Claude Code session that works on your project in the background (fix a bug, add a feature, write tests, research something) with your normal Claude Code setup. A small dot by the notch shows agents are working. When one finishes, Poinky tells you what it did, waiting until it's done talking (or folding it into your next question). Agents may edit files in the project and run a short list of safe commands (tests, `git status`/`diff`/`log`); anything else is refused, since nobody is there to approve it. Settings → Claude can switch them to Claude Code's auto mode (if your account has it) or to planning only. Full logs: `~/Library/Application Support/Poinky/agents/`.

### Demo
`python3 demo/serve.py` opens six realistic, made-up scenes for showing Poinky off: a social feed, a code editor, a notes doc with a checklist, a transit dashboard, an encyclopedia article and a notes app. They all work like the real thing (click, type, check things off), so Poinky can walk you through actions. The code editor shows the real files in `demo/sample-project` live and its terminal really runs the tests, so you can watch a background agent fix the bug. `demo/DEMO-SCRIPT.md` is a recording script.

### Doing it for you: "fill this in", "write an email to Sam…"
Ask Poinky to *do* something and it uses your mouse and keyboard while telling you what it's doing: fill a form, write an email or a note, type a prompt into another AI tool, change a setting. The cursor glides to each spot (a small ring shows each click). It reads the app through macOS accessibility (its buttons, fields and menus), so it clicks the real thing and formats text the way the app expects.

Safety: it asks out loud before anything that sends, posts, buys, deletes or submits (and the app itself holds clicks on buttons like Send or Buy until you say yes); it never types into password fields; it won't press shortcuts that quit apps or delete things. Tap ⌃⌥ or press Esc to stop it instantly; start talking to pause it. It needs Accessibility permission (macOS asks the first time), and you can turn it off in Settings → General.

### Guide mode: "how do I…?"
Ask how to do something in the app you're in ("how do I export this as a PDF?", "where do I change the font?"). Poinky says the first step and circles exactly what to click, then **waits for you to click it**, looks again, and gives the next step until you're done. Hold ⌃⌥ and say "next" after typing something, ask a question any time, or say "stop" to end it. For a one-click task it just points at the button.

Tip: in busy feeds (X, Instagram), circle the post first with ⌥-drag so the guide knows exactly which one you mean.

### First run

- macOS asks for **Microphone** and **Speech Recognition**. **Screen Recording** is turned on by hand in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen Poinky.
- The first session may download Apple's speech model (one time).
- **Voice:** Poinky speaks with **Kokoro**, a free neural voice that runs on your Mac (English). Pick a voice in Settings → Voice (each has a ▶ preview). For other languages it uses Apple's voice from System Settings → Accessibility → **Read & Speak** → System voice.

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
   in one line, marks the    each line is spoken (Kokoro) and its step is drawn by the
   screen instantly          yellow pen at the same moment; or builds a 3D model
```

- **Listening:** Apple's newer on-device speech engine. The mic uses the same voice processing as FaceTime (echo cancellation, noise suppression, auto gain), so you don't need to raise your voice, and Claude's own voice is removed from the mic so you can interrupt it.
- **Speaking:** Kokoro, a free neural voice, runs locally in a small helper that stays loaded (`kokoro/kokoro_server.py`), ~0.5 s per sentence. The first sentence starts playing while the rest is still being written, and each next sentence is made while the current one plays. If Kokoro fails, Apple's voice takes over.
- **Installing Kokoro:** The main installer runs `kokoro/install.sh`, which sets up a private Python environment (installing [uv](https://docs.astral.sh/uv/) into the settings folder if you don't have it) and downloads the model (~330 MB, checksum-verified) into the settings folder. It starts the helper once to check it works. Run it again any time; it only adds what's missing.
- **Two Claude sessions** stay open for the whole call, so each question skips the startup cost.
- **Cards** run inside sandboxed frames with no network access. If a 3D model's code crashes, the error goes back to the artist, which fixes it once automatically.

## Settings

✨ menu → **Settings…** (⌘,) opens the settings window: hold-to-talk keys, call shortcut, language and pause length, buddy and sounds, voice picker with ▶ preview and speed, Claude connection and models, **Privacy** (apps that are never captured; password managers are excluded by default), and prompt editing. Everything is stored in `~/Library/Application Support/Poinky/config.json`:

| Key | Default | What it does |
|---|---|---|
| `brain` | `claudeCode` | `claudeCode` (your subscription) or `api` (API key) |
| `claudeCodeModel` | `haiku` | Talker model. Haiku is fastest. |
| `artistEnabled` | `true` | Turn the diagram/3D artist on or off (also in the menu) |
| `artistModel` | `sonnet` | Artist model. `sonnet` gives detailed models (~30 s for 3D); `haiku` is ~8 s but simpler. |
| `apiModel` / `apiArtistModel` | `claude-haiku-5-5` / `claude-sonnet-5-5` | The same two roles for the API brain |
| `apiKey` | | Anthropic API key (API brain only) |
| `language` | `en-US` | e.g. `he-IL` for Hebrew (uses Apple's dictation engine). Claude replies in the language you speak. |
| `voiceEngine` | `kokoro` | `kokoro` (free local neural voice) or `apple` |
| `kokoroVoice` | `am_michael` | Kokoro voice: `am_` American male, `af_` American female, `bm_`/`bf_` British. E.g. `am_adam`, `bm_george`, `af_heart`. |
| `kokoroSpeed` | `1.0` | Kokoro speaking speed (0.5–2) |
| `voice` | your System voice | Apple voice name (used for non-English, or if Kokoro is off) |
| `speechRate` | `0.53` | Apple voice speed, 0–1 |
| `pushToTalk` | `ctrl+option` | Keys to hold while talking: `ctrl+option`, `ctrl+shift`, `option+cmd`, or `off` |
| `buddy` | `true` | The buddy at your cursor (captions appear next to it instead of at the bottom) |
| `sounds` | `true` | Soft interface sounds |
| `menuBarIcon` | `false` | Also show ✨ in the menu bar (always shown when no screen has a notch) |
| `buddyHotkey` | `ctrl+option+b` | Hides / shows the buddy |
| `buddyAutoHide` | `0` | Hide the buddy this many seconds after it finishes (0 = never, 3 = right after it answers); it comes back when you hold ⌃⌥ |
| `memoryEnabled` | `true` | Remember things about you between sessions |
| `agentPermission` | `acceptEdits` | Background agents: `acceptEdits`, `auto` or `plan` |
| `computerControl` | `true` | Let Poinky click and type for you when you ask it to do something |
| `doerModel` / `apiDoerModel` | `sonnet` / `claude-sonnet-5-5` | The model that clicks and types for you |
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
- Narration: `get` (find a named part), `highlight` (glow and pulse), `focus` (zoom the camera to a part), `remove`. Each spoken line can run a `<step3d>` in the live model.
- Look and feel: real soft shadows, rounded `box` edges, `ground` (shadow-only floor), `person` and `measure` for scale; parts drop in one by one and the camera swoops in. 3D models are placed by the app in free space beside what's being explained.

## Code map

| File | What it does |
|---|---|
| `CallController.swift` | The session: hold-to-talk and hands-free calls, interrupting, talker + artist, menu bar |
| `PushToTalk.swift` | Detects holding ⌃⌥ (by polling the modifier keys, so no extra permission) |
| `NotchHome.swift` | The notch: status wings with a glow, and the hover panel with controls (SwiftUI) |
| `Earcons.swift` | The interface sounds, synthesized in code |
| `Memory.swift` | What Poinky remembers about you (`memory.md`) |
| `AgentManager.swift` | Background Claude Code agents and their logs |
| `prompts/poinky-manual.md` | The app's own manual, given to the talker |
| `AudioIO.swift` | Playback, the hold-to-talk mic, and the hands-free mic with voice processing |
| `SpeechListener.swift` | On-device speech-to-text; ends a question on a pause (calls) or when you let go |
| `Speaker.swift` | Sentence-by-sentence voice through the shared engine |
| `Brain.swift` | The swappable `Brain` protocol and the reply parsers |
| `ClaudeCodeBrain.swift` / `APIBrain.swift` | The two brain types |
| `KokoroVoice.swift` + `kokoro/` | The local neural voice helper and its installer |
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
