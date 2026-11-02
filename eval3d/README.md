# 3D eval

Checks how well the teacher builds and narrates 3D models, across many kinds of questions.

```bash
python3 eval3d/run.py --out eval3d/runs/NAME            # ask the real teacher prompt (claude -p, sonnet) every question
python3 eval3d/shoot.py eval3d/runs/NAME                # replay each reply like the app does and take snapshots
python3 eval3d/grade.py eval3d/runs/NAME                # Claude scores each snapshot sheet (looks, correct, staging, teaching)
python3 eval3d/try.py code.js out.png --views iso,top   # run some kit code and save a picture (for trying kit changes)
```

- `questions.json`: the questions (machines, biology, chemistry, math, astronomy, scale, events; one follow-up).
- `run.py`: one `claude -p` session per question with the same flags as the app. Saves `reply.txt` and `timing.json`
  (time to first text, to the model's opening tag, to its closing tag, total). `--only a,b` runs a few; `--prompt` tries another prompt file.
- `player.html`: plays a reply at the speed it was written: the model's code streams in, lines are "spoken" one after
  another (3 words/s), and each `<step3d>` runs when its line starts, like the app.
- `grade.py`: one `claude -p` per sheet (it reads the image) that scores 1-10 on looks, correct, staging and teaching,
  lists the main problems, and prints the averages. Compare runs by their averages.
- `try.py`: runs a file of kit code in the player and screenshots it from one or more views.
- `shoot.py`: headless Chromium (Playwright). Saves a snapshot at the end of every spoken line, `sheet.png` (all of them in
  a grid) and `errors.txt` (statements that failed).

To compare a kit change on the same replies, copy a run's `reply*.txt` and `timing.json` into a new folder and shoot it again.
`runs/` is not committed.
