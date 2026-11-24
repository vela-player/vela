# vela roadmap: the "nobody else does this" features

Everything runs **on the Mac**: no accounts, no uploads, no subscriptions. All four build on the
on-device transcript engine that shipped as `vela --ai-subtitles` in 1.0.

| Release | Feature | Needs | Status |
|---|---|---|---|
| 1.1 | Ask the movie + Catch me up | macOS 26, Apple Intelligence on | Prototyped (findings below) |
| 1.2 | Language-learning mode | macOS 26 (speech), Translation languages | Planned |
| 2.0 | Live AI dubbing | macOS 26, Translation languages, system voices | Planned, prototype first |
| 2.x | Find a scene by describing it | macOS 15+ (Vision) | Planned, prototype first |

Shared foundation (do first, used by everything): **in-player AI subtitles** — menu item, progress,
background transcription starting at the current position, cached per file in
`~/Library/Caches/vela/transcripts/`, and the `--to` translation path tested end to end.

---

## 1.1 Ask the movie + Catch me up

**What it is.** Press `?` and ask "who is this guy?", "what did she just say?", "why is he angry?".
Reopen a film days later and get a 2–3 sentence "Previously…" recap. Answers only use what you've
already heard, so they can't spoil the rest.

**Prototype results** (90 s Spider-Man clip, Apple's on-device model, 4,096-token context):
- Speed: **0.5–3 s** per answer or recap. Fine for an interactive feature.
- Spoiler safety from the transcript: **holds**. The model never sees dialogue after "now".
- Quality: **usable but imperfect**. Quoting the supporting line and greedy decoding cut most invented
  details ("Yes, Peter gives up — 'I quit. You win…' (1:00)"). Remaining failures:
  - Treats "not yet" as "no" (at 0:30, "Does Peter give up?" → "No" instead of "not revealed yet").
  - Uses its own world knowledge ("M.J. is Peter's girlfriend"), which can **spoil famous films**.
  - Subtitles have no speaker names, so "who said what" is guesswork.

**Design.**
- Context budget is ~4k tokens; a film is 15–25k words. So: rolling **scene summaries** every ~5 min,
  written in the background while you watch, plus the last ~3 min of exact lines, plus lines that
  match the question's keywords. All capped at the current position.
- Always show the quoted evidence line(s) with clickable timestamps (jump back to hear it).
- Guardrails: a second, cheap check that the answer's claims appear in the quoted lines; otherwise
  answer "That hasn't been revealed yet." Tell the model the film's title is unknown, to reduce
  world-knowledge leaks.
- UI: small floating question panel (`?`), recap card on resume (dismissable, off in config).

**Open risks.** World-knowledge spoilers can be reduced, not eliminated; we should say so in the UI.
Speaker labels would help a lot but need speaker diarization (not in Apple's APIs today).

**Effort.** ~1 week after the shared foundation.

## 1.2 Language-learning mode

**What it is.** Two subtitle lines (original + your language). Hover/click a word for its meaning,
auto-pause after each line (optional), `R` to replay the last line, save words and lines to a list
you can export (CSV / Anki).

**Design.** Original-language cues from AI subtitles (or the file's own subtitle track), translated
with `TranslationSession`; vela draws both lines itself (an overlay, not mpv's single subtitle).
Word lookup: translate the single word in context; dictionary via `NSSpellChecker`/`DCSCopyTextDefinition`.

**Effort.** ~1 week. Prototype check: translation speed and quality for 2–3 language pairs.

## 2.0 Live AI dubbing

**What it is.** Hear a film in another language, offline: the original dialogue is lowered and
translated lines are spoken by an on-device voice, timed to the original lines.

**Why it's possible.** Film dialogue is in the 5.1 center channel (the Clear Voice trick), so vela
can duck just the voices and keep the music and effects.

**Design.** AI subtitles → translation → `AVSpeechSynthesizer` rendered to buffers ahead of time;
speed each line to fit its slot; mix into mpv's output (pre-rendered audio track loaded with
`audio-add`, or a lavfi mix), center channel ducked.

**Risks.** Voices sound synthetic; no lip sync; stereo-only films can't isolate dialogue as cleanly.
Prototype gate: dub 60 s and judge whether it's watchable.

**Effort.** ~2 weeks after prototype.

## 2.x Find a scene by describing it

**What it is.** Type "rooftop at night" or "car chase" and jump there.

**Design.** Sample a frame every ~2 s in the background (headless mpv screenshots), compute image
embeddings on-device, match against the typed text. Apple's Vision framework gives image feature
prints but no text–image matching, so this likely needs a small CLIP-style Core ML model bundled
with vela (adds tens of MB; must check license). Combine with dialogue search for "the scene where
he says …".

**Risks.** Model size vs "ultra-light"; indexing time for a full film. Prototype gate: index one film,
measure time and hit rate on 10 descriptions.

**Effort.** ~2 weeks after prototype.

---

## Order of work
1. In-player AI subtitles (foundation) + test translation.
2. Ask the movie + Catch me up → **1.1**.
3. Language-learning mode → **1.2**.
4. Prototype dubbing and scene search; build whichever passes its gate → **2.0**.

The Windows port (separate effort) gets these later; on Windows the on-device AI pieces would need
different engines (e.g. Whisper, ONNX), which is its own project.
