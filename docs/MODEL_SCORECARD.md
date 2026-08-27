# Model scorecard

Every score is 0 to 1, higher is better, and each is an average over three deliberately different corpora — the per-corpus numbers are underneath each table. Speed and latency were measured on one machine and do not transfer.

- **Measured on:** Apple M1 Max, 32 GB, macOS 26.5.1
- **Date:** 2026-08-27  
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
| Parakeet TDT 0.6b v3    | **0.61** | 0.74  | 0.82     | 0.87     | 0.73      | 0.45     | 0.65    | 61×   |
| Parakeet TDT-CTC 110M   | **0.59** | 0.71  | 0.75     | 0.87     | 0.72      | 0.43     | 0.63    | 80×   |
| Distil-Whisper large-v3 | **0.49** | 0.57  | 0.65     | 0.90     | 0.63      | 0.49     | 0.36    | 18×   |
| Whisper large-v3 turbo  | **0.48** | 0.55  | 0.62     | 0.90     | 0.62      | 0.48     | 0.34    | 9×    |
| Whisper large-v3        | **0.45** | 0.52  | 0.59     | 0.90     | 0.64      | 0.44     | 0.26    | 2×    |

A high **Words** with a low **Score** means the transcript is right and the speaker labels are wrong. **Speakers** and **Diarizer** are both `1 − DER`, and the gap between them is worth looking at: **Diarizer** is the turns the diarizer produced, and **Speakers** is what survived assembly, which labels each *word* by the turn it falls in and cuts the segment where the speaker changes. What is left of the gap is words whose own timing puts them on the wrong side of a boundary, plus whatever arrived with no word timings to cut on.


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

