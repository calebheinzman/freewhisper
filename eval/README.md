# eval

Measures the models FreeWhisper offers, so the Settings picker can say something
checkable instead of repeating upstream's marketing.

The result is `docs/MODEL_SCORECARD.md` and a `scorecard.json` bundled into the
app, which is what draws the accuracy and speed badges on each row.

```sh
swift build -c release                              # fweval, which drives the models
uv run --project eval eval/run.py --profile fast    # ~3 hours on an M1 Max
uv run --project eval eval/report.py --profile fast
```

`--profile smoke` runs a handful of items per corpus and takes a few minutes.
Use it when changing the harness.

## How it is split

Swift runs the models, Python scores them.

That division is not arbitrary. The engines live in `FreeWhisperKit`, so running
them anywhere else would mean reimplementing the pipeline and measuring
something the app does not do. Meanwhile every metric worth reporting — WER,
DER, tcpWER — has a canonical Python implementation that took years to get
right, and a Swift reimplementation would buy one binary at the cost of numbers
nobody could check against the literature.

```
Sources/fweval/          runs models, writes one JSON per item, times everything
eval/prepare/            nine corpora → one manifest shape
eval/score/              jiwer, meeteval, pyannote.metrics, and the judge
eval/run.py              orchestrates; resumable
eval/report.py           → docs/MODEL_SCORECARD.md + the bundled scorecard.json
eval/manifests/          committed — pins exactly which clips were scored
eval/results/            committed — the numbers, and the per-item cache
eval/datasets/           gitignored — gigabytes of audio, all re-downloadable
```

Everything resumes. `fweval` skips items that already have a result file, and
the judge caches verdicts, so an interrupted run picks up where it stopped and
adding one model re-runs only that model.

## What is measured

**Voice to text** — `1 − WER` after Whisper's English normalizer, on LibriSpeech
(clean), Earnings-22 (27 countries) and AMI headset turns (spontaneous, ~4s).

**Meeting transcripts** — `1 − tcpWER`, which scores words *and* the speaker they
were attributed to. Reported beside `1 − ORC-WER` (words only) and `1 − DER`
(speakers only), because those two separate an ASR problem from a diarizer
problem. On AMI, NOTSOFAR-1 and CHiME-6.

**Summaries** — four sub-scores from a Gemini Flash rubric against human
summaries: quality, action-item F1, meeting name, and speaker naming. On AMI,
QMSum and ICSI.

Three things about the summary track are worth knowing before reading it:

- **Action items are scored on AMI only.** It is the one public corpus with
  typed action-item annotation. QMSum ships a whole-meeting abstract and nothing
  else; no ICSI summary has an actions section — checked across all 61.
- **Speaker naming credits silence.** Where a speaker's name is never said
  aloud, the correct answer is to leave them as "Speaker 3", and abstaining
  scores as correct. Without that, the metric would pay a model for attaching a
  plausible name to every voice it heard.
- **Read the scores against the boilerplate baseline** the report prints. It is
  what a *different meeting's* human summary scores, and it is not near zero:
  AMI is 140 recordings of four people designing the same remote control, so
  generic plausible text earns partial credit for free.

## Trusting the judge

Every rubric call is made three times and the median taken. Before any of it is
believed, `calibrate()` scores each human summary against itself (must come out
near 1.0) and against a summary from a different corpus (must come out near
0.0). Both anchors are printed at the top of the report, and `run.py` says so
loudly if they fail.

The judge key is read from `GEMINI_API_KEY` in the environment, falling back to
the `.env` named in `score/judge.py`.

## Checking the harness, not the models

```sh
uv run --project eval eval/test_scoring.py    # the scoring rules
uv run --project eval eval/calibrate_der.py   # diarization, against published numbers
```

`test_scoring.py` covers the rules where a wrong answer does not look wrong — it
looks like a model being good or bad, and gets written into the app. The one
worth knowing about: **a crash is scored as an empty transcript, not skipped.**
One engine here crashed on 176 of 200 clips, and judged on the 24 that survived
it was the highest-scoring model in the table.

`calibrate_der.py` runs the real pipeline over AMI and checks the diarizer
against pyannote's published 18.8% on the same condition. It also prints the
diarizer's error rate beside the finished transcript's, which is the more
interesting number: they are currently 0.15 and 0.34, so assembly is losing more
of the speaker accuracy than the diarizer ever gets wrong.

A scoring harness that is quietly wrong looks exactly like one that works, so
both checks compare against numbers somebody else published:

- **Diarization** should land near pyannote's **18.8% DER** on the AMI headset
  mix. It gets 14.8%. That is why the reference RTTMs come from pyannote's AMI
  setup rather than being derived from the word timings — same reference, same
  collar, comparable answer.
- **Whisper on LibriSpeech test-clean** should land in the low single digits of
  WER. It gets 2.04%.

The far-field array is printed for context but does not gate: FluidAudio's 10.6%
is from their own 16-meeting run with their own clustering configuration, and
gating on a number whose conditions we cannot reproduce would fail honest runs.

## Corpora

| Corpus | Track | Licence |
|---|---|---|
| LibriSpeech (Argmax 200) | dictation | MIT |
| Earnings-22 | dictation | CC BY-SA 4.0 |
| AMI headset turns | dictation | CC BY 4.0 |
| AMI meetings | transcript | CC BY 4.0 |
| NOTSOFAR-1 | transcript | CC BY 4.0 |
| CHiME-6 | transcript | CC BY-SA 4.0 |
| AMI abstractive summaries | summary | CC BY 4.0 |
| QMSum | summary | MIT |
| ICSI | summary | CC BY 4.0 |

All are downloadable without registration. ICSI stands in for the ELITR minuting
corpus, which this suite originally aimed at: LINDAT's DSpace front end serves
HTML rather than the archive at every stable URL it advertises, and ELITR is
CC BY-NC-SA, so it could not have shipped with the harness anyway. ICSI is the
same NXT schema as AMI — `nxt.py` reads both — and is real research-group
meetings rather than a scripted scenario, which is what a third corpus is for.
