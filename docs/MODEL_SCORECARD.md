# Model scorecard

Every score is 0 to 1, higher is better, and each is an average over three deliberately different corpora — the per-corpus numbers are underneath each table. Speed and latency were measured on one machine and do not transfer.

- **Measured on:** Apple M1 Max, 32 GB, macOS 26.5.1
- **Date:** 2026-08-26  
- **Profile:** `fast`, 13.5 hours of audio transcribed in total


## Voice to text

What the ⌘⎋ hotkey produces. Scored as `1 − WER` after Whisper's English normalizer, so a model is not marked down for writing "$25m" where the reference says "twenty five million dollars".

| Model                   | Score    | Clean | Accented | Spontaneous | Failed  | Speed | Typical clip | First use |
|-------------------------|----------|-------|----------|-------------|---------|-------|--------------|-----------|
| Parakeet TDT 0.6b v3    | **0.87** | 0.98  | 0.89     | 0.76        | 0/849   | 44×   | 0.1s         | 0.3s      |
| Whisper large-v3 turbo  | **0.83** | 0.98  | 0.91     | 0.60        | 0/849   | 4×    | 1.3s         | 4.1s      |
| Distil-Whisper large-v3 | **0.82** | 0.97  | 0.88     | 0.60        | 0/849   | 8×    | 0.7s         | 4.5s      |
| Whisper large-v3        | **0.81** | 0.98  | 0.90     | 0.57        | 1/849   | 2×    | 2.8s         | 4.3s      |
| Parakeet TDT-CTC 110M   | **0.08** | 0.25  | 0.00     | 0.00        | 825/849 | 75×   | 0.2s         | 0.2s      |

> **Parakeet TDT-CTC 110M crashed on 825 of 849 clips.** A crash is scored as an empty transcript rather than skipped, which is why its score is low: judged only on the clips that survived it would look like one of the best models here.


*Clean* = LibriSpeech, *Accented* = Earnings-22 (27 countries), *Spontaneous* = AMI headset turns. **Typical clip** is the median wall time for one utterance with the model already warm; **First use** is what the first dictation of a session waits for while the weights load.


## Meeting transcripts

The headline is `1 − tcpWER`: words *and* the speaker they were attributed to, which is what the user actually reads. The two columns beside it split the blame — **Words** is `1 − ORC-WER`, ignoring speakers entirely, and **Speakers** is `1 − DER`, ignoring words entirely.

| Model                   | Score    | Words | Speakers | Diarizer | AMI close | NOTSOFAR | AMI far | Speed |
|-------------------------|----------|-------|----------|----------|-----------|----------|---------|-------|
| Distil-Whisper large-v3 | **0.50** | 0.58  | 0.60     | 0.90     | 0.64      | 0.50     | 0.35    | 17×   |
| Whisper large-v3 turbo  | **0.48** | 0.57  | 0.59     | 0.90     | 0.63      | 0.49     | 0.32    | 9×    |
| Whisper large-v3        | **0.39** | 0.47  | 0.50     | 0.90     | 0.49      | 0.44     | 0.24    | 2×    |
| Parakeet TDT 0.6b v3    | **0.35** | 0.74  | 0.64     | 0.82     | 0.43      | 0.38     | 0.25    | 53×   |
| Parakeet TDT-CTC 110M   | **0.34** | 0.70  | 0.59     | 0.82     | 0.41      | 0.36     | 0.24    | 59×   |

A high **Words** with a low **Score** means the transcript is right and the speaker labels are wrong. **Speakers** and **Diarizer** are both `1 − DER`, and the gap between them is worth looking at: **Diarizer** is the turns the diarizer produced, and **Speakers** is what survived assembly, which attributes each whole ASR segment to whichever turn it overlaps most. A segment that runs across a speaker change takes one label for all of it.


Neither speaker column is a property of the ASR model — the diarizer follows from the engine, so every Whisper row shares one and both Parakeet rows share another. That is why they cluster.


## The corpora

| Corpus                    | Track     | Why it is here                                                                                           | Licence      |
|---------------------------|-----------|----------------------------------------------------------------------------------------------------------|--------------|
| AMI meetings              | meeting   | Scenario meetings, non-native English. Has published DER baselines to check ourselves against.           | CC BY 4.0    |
| AMI headset, utterances   | asr       | Short spontaneous speech, ~4s a turn — the register of actually holding the hotkey.                      | CC BY 4.0    |
| AMI, far-field array      | meeting   | The same meetings as above, recorded across the room. Isolates what mic distance costs.                  | CC BY 4.0    |
| AMI abstractive summaries | summarize | Human abstracts with separate action-item and decision fields — the only corpus shaped like our output.  | CC BY 4.0    |
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

