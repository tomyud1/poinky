# Poinky demo: recording script

About 6–7 minutes. Every scene is a made-up but realistic screen that works like the real thing (click, type, check things off), so Poinky can walk you through real actions. Everything is fictional and safe to share.

## Before you record
1. Start the demo (it opens your browser):
   ```
   python3 demo/serve.py      # from the Poinky folder
   ```
   Keep that Terminal window open while you record. Make the browser full screen (⌃⌘F) so each scene looks like a real app.
2. Make sure Poinky is running (hover the notch: a row of buttons appears).
3. Turn the volume up so the recording catches the voice and the sounds.
4. The sample project should still have its bug: the code editor's terminal shows `FAILED (failures=2)` when it opens. If an earlier take fixed it, click **Put the bug back for another take** at the bottom of the launcher page.

Tips while recording:
- Hold ⌃⌥ for the whole question, let go when you're done.
- A quick tap of ⌃⌥ stops Poinky mid-sentence (its marks go away too).
- Hover the notch to show the controls and their tooltips.

## 0. Say hi (launcher page)
> "Hey, I'm recording a demo for a friend. What can you do?"

The notch glows, the buddy at your cursor shows your words and then its answer. It knows your name.

## 1. Social feed (`feed.html`)
Hold ⌃⌥ and **drag a circle around the turbine post** while you ask:
> "Why did more blades make less power?"

A short answer, then a paper slides in and the yellow pen sketches the explanation as it talks.
> "Show me in 3D."

A 3D turbine builds up while it's narrated. Drag it to rotate.
> "How do I see the rest of this thread?"

It points at **Show this thread**. Click it; the thread opens. Like the post if you want: everything on the page works.

## 2. Code editor (`editor.html`)
This scene shows the real files in `demo/sample-project`, and its terminal really runs.
> "Why are these tests failing?"

It points at the rounding line and the failing test output.
> "Put an agent on fixing it."

It starts a background agent in that project (the path is in the terminal prompt). A small teal dot by the notch means it's working (hover the notch: "1 agent working"). Carry on with the next scenes. When the agent finishes (1–3 minutes), Poinky tells you what it changed, after it finishes whatever it's saying.

Come back to the editor: the changed lines are highlighted green, with a "changed on disk" notice. Click the terminal, type `python3 -m unittest` and press Return: **OK**. (`git diff` shows exactly what the agent changed.)

## 3. Notes doc (`notes.html`)
> "Mark number 4."

A slim bracket appears next to item 4 only.
> "What's left before we go?"

It reads the unchecked items, wherever your mouse is.
> "I bought the food. Help me check it off."

It points at item 3's checkbox and waits. Click it; it's crossed off. Then:
> "How do I change the status to Booked?"

It points at **Planning**, then at **Booked** in the menu.

## 4. Dashboard (`dashboard.html`)
> "What happened in July?"

It points at the dip and explains the bridge works. Then:
> "How do I see just the Harbor Bridge stop?"

It walks you through **All stops ▾** → **Harbor Bridge**. The chart redraws: July drops to almost zero (the stop was closed).
> "And why the jump in December?"

## 5. Article (`article.html`)
> "Explain how it turns."

A hand-drawn lesson. Then:
> "Now show it in 3D and make it turn left."

Optional: "How would I fix a mistake in this article?" It points at **Edit**; the page goes into edit mode.

## 6. An app (`app.html`)
> "How do I switch this app to dark mode?"

It circles the ⋯ button and waits for your click, then shows Preferences…, then the Appearance tab, then Theme. Do each click; the app turns dark at the end.

## 7. Wrap up
> "Talk a little faster." (it changes its own voice speed)
> "Hide the buddy." (or ⌃⌥B; it comes back on your next question)
> "Thanks, bye!"

It says goodbye and the session ends by itself.

## After the demo
- Another take: on the launcher page click **Put the bug back for another take** (or in Terminal: `git checkout demo/sample-project` in the Poinky folder). Reload a page to reset its clicks.
- Stop the demo: Ctrl+C in the Terminal window running `serve.py`.
- The agent's full log is in `~/Library/Application Support/Poinky/agents/`.
- Prefer a real editor for scene 2? Open `demo/sample-project` in Cursor or VS Code with its terminal; the agent edits the same files.

## If something goes wrong
- The editor shows a yellow "Static copy" note: you opened the file directly. Start `serve.py` and use the page it opens.
- No answer: hover the notch; if it says Listening, let go of ⌃⌥.
- Marks in the wrong place: circle the thing first (drag while holding ⌃⌥), then ask.
- Clear everything: hover the notch → eraser.
