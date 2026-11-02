# Contributing

Thanks for helping. Poinky is a small Swift Package plus a web overlay, so getting started is quick.

## Build

```bash
./build.sh && open build/Poinky.app
```

Restart after a rebuild: `pkill -f "Poinky.app/Contents/MacOS/Poinky"; open build/Poinky.app`.

`build.sh` signs with your Apple Development certificate if you have one, otherwise with a local "Poinky Local Signing" certificate it creates in your login keychain the first time, so macOS remembers the Microphone, Screen Recording and Accessibility permissions between builds. (If both fail it signs ad hoc, and macOS asks again after each build.)

For the natural voice, run `kokoro/install.sh`. To test the installer, run `./install.sh` (it builds from the repo on GitHub; set `POINKY_REF=your-branch` to try a branch).

## Where things are

[CLAUDE.md](CLAUDE.md) has the architecture, the gotchas we learned the hard way, and how things are tested. Most behavior lives in the prompts in [`prompts/`](prompts/), and you can often fix or improve something there without touching Swift.

## Testing

There's no test target. Logic is checked with small `swiftc` harnesses that compile the relevant source files, the `web/` pages are tested in a browser with a mocked `window.webkit`, and prompt changes are tried against the real model with `claude -p`. Please describe how you checked your change in the pull request.

## Pull requests

- Keep each pull request to one change, and explain what it does from the user's side.
- Match the existing style: plain words in user-facing text, short comments that say why.
- Changes to what Poinky can do on its own (clicking, typing, agents) need extra care. Keep the safety checks in [`CallController.swift`](Sources/Poinky/CallController.swift) and [`Computer.swift`](Sources/Poinky/Computer.swift) intact.
