# Speech recognition test bench

How well Poinky hears you, measured headless through the app's real `SpeechListener` (no mic, no keyboard).

```
tools/stt-test/make-set.sh /tmp/stt/set                       # say: 34 English sentences × 10 voices, 10 Hebrew + 4 mixed
tools/stt-test/run.sh render /tmp/stt/set/clean.jsonl /tmp/stt/r    # loudness and noise conditions → r/manifest.jsonl
tools/stt-test/run.sh run r/manifest.jsonl out.jsonl [--pace 4] [--languages en-US,he-IL] [--context]
tools/stt-test/score.py r/manifest.jsonl apple=out.jsonl other=…  [--by voice|kind] [--show 10]
tools/stt-test/whisper-run.py model.bin manifest.jsonl out.jsonl --lang he     # whisper.cpp, for comparison
tools/stt-test/check.sh                                       # the logic, no models (CI)
```

`run` plays each clip into `AudioIO.micRelay` like a hold (a moment of room, the words, the 0.18 s tail, then
`finishUtterance`), at `--pace` × real time (4× gives the same text as 1×; use 1 for timings). The engine is the
setting's (`POINKY_STT_ENGINE=apple|auto`, `POINKY_STT_DIR=<installed local model>`). `POINKY_STT_LEGACY=1`
runs Apple's engine the way Poinky used it before (one analyzer for the whole session).

Voices: `us` Samantha, `us2` Zoe, `gb` Daniel, `in` Rishi, `au` Karen, `ie` Moira, `za` Tessa, `il` Carmit (the
Hebrew voice reading English: a stand-in for an Israeli accent), `whisper` (a whispered voice), `fast` (Samantha at
280 wpm), `he` Carmit in Hebrew. Conditions (speech level in dBFS, noise, SNR): `clean` −26; `soft38/50/60` −38/−50/−60
over a −72 dBFS mic hiss; `fan15/5` a fan at 15/5 dB SNR; `room10/3` pink noise; `keys10` typing; `babble10/5`
three other voices; `softfan` −46 with a fan at 10 dB. Noise conditions use the `us`, `il` and `he` voices.

Synthetic speech is cleaner and more regular than a person: these numbers are a lower bound on real errors. The
owner's voice in their room is the ground truth: Settings → Voice → Check my microphone (`MicCheck.swift`).

## Results (M3 MacBook, macOS 27.2, 2026-11-18)

Word error rate %, `t` = key terms right % (Bernoulli, Navier-Stokes, Poinky, Mint…), `c` = Hebrew character errors.

**The fix: a fresh analyzer per question** (US voice, clean, 34 questions in a row as holds):

| | WER | terms |
|---|---|---|
| before: one analyzer for the session | 18.2 | 64 |
| a fresh analyzer per question | 2.6 | 85 |
| reference: Apple's engine on each file alone | 3.9 | 79 |

**Before → after, end to end through the listener** (374 holds: US, Hebrew-accented and whispered voices clean,
plus soft, fan and babble for US + Hebrew-accented; "hybrid" = Apple + Parakeet installed, the app's default then):

| condition | before | after (fresh analyzer) | after + on-screen words | hybrid (Parakeet's text) |
|---|---|---|---|---|
| clean | 36.9 t46 | 18.5 t62 | 18.3 t62 | 3.5 t91 |
| soft50 | 34.9 t48 | 15.3 t62 | 12.7 t65 | 4.7 t86 |
| soft60 | 36.2 t45 | 18.4 t56 | 18.4 t58 | 6.4 t79 |
| fan5 | 32.6 t50 | 16.9 t58 | 16.4 t58 | 5.4 t85 |
| babble10 | 41.2 t38 | 27.9 t50 | 28.3 t48 | 11.4 t73 |
| Poinky / Mint / Coral sentences | 34.2 t26 | 27.0 t32 | 26.5 t34 | 14.3 t69 |

Time from the end of the audio (after the app's 0.18 s tail) to the final text, real time, 34 holds:

| speech | Apple (settle) | with Parakeet (its words go as soon as they come) |
|---|---|---|
| ~2 s | 199 ms (max 244) | 66 ms (max 71) |
| ~5 s | 200 ms (max 243) | 65 ms (max 96) |
| ~13 s | 294 ms | 101 ms |

Parakeet's model loads in 0.33 s when the session starts (37 s the very first time: download + Neural Engine
compile, done by the installer), uses ~540 MB of memory while a session runs (the helper quits with the session).

Contextual strings (`AnalysisContext`, given the sentence's own terms among 18 others) barely move
SpeechTranscriber: "Mint" still comes back "meant", "Poinky" "Boinky". They stay on (they cost nothing).

**English, all conditions** (1,088 clips; Apple = fixed path):

| condition | Apple | Parakeet v2 | Parakeet Ultra |
|---|---|---|---|
| clean (10 voices) | 9.3 t71 | 1.8 t92 | 2.2 t90 |
| soft38 | 11.1 t67 | 2.1 t94 | 3.1 t88 |
| soft50 | 15.3 t62 | 4.9 t86 | 5.7 t80 |
| soft60 | 18.4 t56 | 5.5 t82 | 7.8 t77 |
| softfan | 14.0 t61 | 5.0 t85 | 5.9 t79 |
| fan15 | 14.2 t65 | 4.1 t88 | 5.2 t83 |
| fan5 | 16.9 t58 | 5.5 t85 | 6.8 t82 |
| keys10 | 14.0 t64 | 3.3 t91 | 3.3 t88 |
| room10 | 18.2 t56 | 6.5 t85 | 6.5 t80 |
| room3 | 37.6 t39 | 19.5 t55 | 12.4 t64 |
| babble10 | 27.9 t50 | 10.3 t74 | 8.6 t82 |
| babble5 | 58.3 t27 | 40.2 t44 | 35.0 t44 |
| finalize after release (median / p90) | 198 / 404 ms | 53 / 69 ms | 53 / 76 ms |

Clean, by accent: Apple / Parakeet v2 — US 2.6 / 0.7, UK 4.6 / 1.0, Indian 5.9 / 2.3, Australian 7.8 / 1.3,
Irish 4.2 / 1.3, South African 6.8 / 0.7, Hebrew-accented 16.9 / 4.6, whispered 35.8 / 4.9, fast 3.3 / 0.7.

**Hebrew** (168 clips): Apple (DictationTranscriber he-IL) 18.4 % WER / 11 % CER on Hebrew sentences, 13.9 clean;
whisper.cpp large-v3-turbo 12.6 / 5; ivrit.ai's turbo fine-tune 8.5 / 3. Mixed Hebrew + English terms: all ~28–31 %
(English words come back transliterated). But Whisper takes 1.1–1.3 s per question on the M3 GPU whatever its length
(2, 4 or 13 s of speech; the encoder always works on 30 s), Apple 0.14 s.

**Two languages at once** (English + Hebrew recognizers on the same audio, 246 clips): the right language was
picked 244 times (both misses: the Hebrew-accented English voice in fan noise); English and Hebrew accuracy the same
as with one language.

**Input gain** (lifting a soft voice to −26 dBFS before the engine): no effect (soft60 18.2 → 17.8, softfan 14.5 →
16.0), so it's off. **VoiceActivity** at −55 dBFS called a −60 dBFS voice silence in 16 of 34 clips (a call dropped
those words); at "10 dB over the room, above −64" every clip is heard.
