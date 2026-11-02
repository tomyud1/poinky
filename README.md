<p align="center"><img src="docs/media/logo.png" alt="Poinky logo" width="128"></p>

<h1 align="center">Poinky</h1>

<p align="center"><b>Ask about anything on your screen. It answers out loud and draws the explanation.</b></p>

<p align="center">
  <img src="docs/media/demo.gif" alt="Demo: holding Control and Option, the user asks &quot;How does it turn left?&quot; about a drone article. Poinky answers out loud next to the cursor, boxes the matching table row, and a yellow pen sketches the drone on a paper beside it." width="900">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-black?style=flat-square&logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/runs%20on-Claude-d97757?style=flat-square" alt="Runs on Claude">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT license"></a>
</p>

Poinky lives in your Mac's notch. Hold <kbd>⌃ Control</kbd> <kbd>⌥ Option</kbd>, ask out loud, let go. A little buddy at your cursor points at the answer while a yellow pen sketches it for you, like a friend explaining at your shoulder.

- **Explains by drawing.** Step-by-step sketches in sync with its voice, or a 3D model you can spin.
- **Shows you the way.** "How do I export this?" It circles each click and waits for you.
- **Does it for you.** "Write an email to Sam" or "fill this in". It types, and asks before sending anything.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/tomyud1/poinky/main/install.sh | bash
```

You need a Mac with **macOS 26** and **[Claude Code](https://claude.com/claude-code)** (signed in) OR an Anthropic API key. The installer builds the app and puts it in Applications; the first time, macOS asks to allow the microphone and screen recording.

## Use it

| Do this | To |
|---|---|
| Hold <kbd>⌃</kbd><kbd>⌥</kbd> and talk | Ask about your screen |
| Hold <kbd>⌃</kbd><kbd>⌥</kbd> and drag with the mouse | Circle what you mean |
| Tap <kbd>⌃</kbd><kbd>⌥</kbd> | Stop it |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>Space</kbd> | Hands-free conversation |

**Private by design:** your voice is turned into text on your Mac, and screenshots go only to Claude, only when you ask. No accounts, no tracking. [More on privacy and safety →](docs/GUIDE.md#privacy)

## Learn more

[User guide](docs/GUIDE.md) · [How it works](CLAUDE.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)

Inspired by [Clicky](https://github.com/farzaa/clicky). MIT © 2026 Tomer Yudovic.
