# Model scorecard

Every score is 0 to 1, higher is better, and each is an average over three deliberately different corpora — the per-corpus numbers are underneath each table. Speed and latency were measured on one machine and do not transfer.

- **Measured on:** Apple M1 Max, 32 GB, macOS 26.5.1
- **Date:** 2026-08-25  
- **Profile:** `fast`, 3.2 hours of audio transcribed in total


## Voice to text

What the ⌘⎋ hotkey produces. Scored as `1 − WER` after Whisper's English normalizer, so a model is not marked down for writing "$25m" where the reference says "twenty five million dollars".

| Model                     | Score    | Clean | Accented | Spontaneous | Failed  | Speed | Typical clip | First use |
|---------------------------|----------|-------|----------|-------------|---------|-------|--------------|-----------|
| Whisper large-v3 turbo    | **0.94** | 0.98  | 0.91     | —           | 0/450   | 5×    | 1.3s         | 4.9s      |
| Whisper large-v3          | **0.94** | 0.98  | 0.91     | —           | 0/392   | 2×    | 3.4s         | 2.8 min   |
| Parakeet TDT 0.6b v3      | **0.93** | 0.98  | 0.89     | —           | 0/450   | 49×   | 0.1s         | 0.3s      |
| Distil-Whisper large-v3 ⚠ | **0.97** | 0.97  | —        | —           | 0/200   | 9×    | 0.8s         | 12.9 min  |
| Parakeet TDT-CTC 110M ⚠   | **0.25** | 0.25  | —        | —           | 176/200 | 75×   | 0.2s         | 0.4s      |

> **Parakeet TDT-CTC 110M crashed on 176 of 200 clips.** A crash is scored as an empty transcript rather than skipped, which is why its score is low: judged only on the clips that survived it would look like one of the best models here.


*Clean* = LibriSpeech, *Accented* = Earnings-22 (27 countries), *Spontaneous* = AMI headset turns. **Typical clip** is the median wall time for one utterance with the model already warm; **First use** is what the first dictation of a session waits for while the weights load.


⚠ marks a model averaged over fewer corpora than the others — usually a run that was interrupted. Its score is not comparable to the rows above it.


## The corpora

| Corpus                    | Track     | Why it is here                                                                                           | Licence      |
|---------------------------|-----------|----------------------------------------------------------------------------------------------------------|--------------|
| AMI meetings              | meeting   | Scenario meetings, non-native English. Has published DER baselines to check ourselves against.           | CC BY 4.0    |
| AMI headset, utterances   | asr       | Short spontaneous speech, ~4s a turn — the register of actually holding the hotkey.                      | CC BY 4.0    |
| AMI abstractive summaries | summarize | Human abstracts with separate action-item and decision fields — the only corpus shaped like our output.  | CC BY 4.0    |
| CHiME-6 dinner party      | meeting   | Overlapping speech, kitchen noise, distant mics — the floor.                                             | CC BY-SA 4.0 |
| Earnings-22               | asr       | Speakers from 27 countries — the accent probe, and full of proper nouns.                                 | CC BY-SA 4.0 |
| ICSI meetings             | summarize | Real research-group meetings rather than a scripted scenario, and five to eight people instead of four.  | CC BY 4.0    |
| LibriSpeech (Argmax 200)  | asr       | Clean read speech — the ceiling. If a model is bad here it is bad everywhere.                            | MIT          |
| NOTSOFAR-1                | meeting   | Real conference rooms, far-field mic — the closest public corpus to what this app records.               | CC BY 4.0    |
| QMSum                     | summarize | AMI, ICSI and parliamentary committees. Real names in the committee half, so speaker naming is scorable. | MIT          |

## Reproducing

```sh
swift build -c release
uv run --project eval eval/run.py --profile fast
uv run --project eval eval/report.py --profile fast
```

