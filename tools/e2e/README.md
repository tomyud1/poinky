# Real-use runs

Drive this checkout's `build/Poinky.app` with the real models, the way a person would, and keep everything
needed to judge the run afterwards.

```sh
tools/e2e/seed.sh /tmp/sup-student [your config.json]     # a support folder: no tour, Phonon linked in
tools/e2e/show.sh tools/e2e/pages/homework.html            # the page in front (its own Chrome; --close closes it)
POINKY_ASK_WAIT=2 tools/e2e/run.sh /tmp/r01 /tmp/sup-student 150 \
  --ask "is my answer right for number one" --ask "wait why is it wrong" --end-after 140
tools/e2e/raw.py /tmp/r01          # what the talker / teacher actually wrote
tools/e2e/sheet.sh /tmp/r01 1 60 3 # contact sheet of the screenshots
tools/e2e/gaps.py /tmp/r01         # long silences in what was played
```

`run.sh` writes `speech.log`, `speech.f32`, `raw.jsonl`, `timeline/`, `receipts/`, `lessons/` and a
screenshot of the whole screen every second (`shots/`, `E2E_SHOT_EVERY`), and notes new crash reports.

Switches in the app used here (test-only):
- `POINKY_RAW_LOG=file`: every finished Claude Code reply (model, which prompt, the question's text, the raw reply).
- `POINKY_ASK_WAIT=secs`: with several `--ask`s, each waits until the last answer was said and sketched, plus `secs`
  (instead of the fixed `POINKY_ASK_GAP`), so follow-ups like "and why?" come after the answer they refer to.

`pages/` has the screens: a homework sheet with a sign mistake, a bar chart, a budget table, a lecture PDF with a
formula and a free-body diagram, an essay, a Hebrew page, a page with injected instructions, a checkout with
tiny print, a blank page, and `failing/` (a tiny Python project with one failing test, for helpers: copy it into a
scratch git repo first).

Other Poinky test instances on the same Mac draw and speak too: check `raw.jsonl` / `speech.log` before blaming
something on screen on this run.
