"""Earnings-22 — accented English under a proper-noun load.

Earnings calls from 27 countries, so most speakers are using English as a second
language and the vocabulary is dense with company names, figures and finance
jargon. That combination is the point: LibriSpeech says what a model does when
nothing is hard, and this says what happens when the accent is unfamiliar and
the words are ones no language model can guess from context.

Read from parquet with pyarrow rather than through `datasets`, because the
audio-decoding path in current `datasets` wants torchcodec, and pulling torch
into a harness that is otherwise pure Python is a poor trade for reading a
column of WAV bytes we are about to hand to ffmpeg anyway.
"""

from __future__ import annotations

import io
from pathlib import Path

import pyarrow.parquet as pq
from huggingface_hub import hf_hub_download

from .audio import to_wav

REPO = "distil-whisper/earnings22"
SHARD = "chunked/test-00000-of-00038-6f4f182bdbb6f186.parquet"

#: Dictation is a sentence or two, not a monologue and not a single word. Both
#: ends matter: sub-2s clips are dominated by whether the model emits one filler
#: token, and very long ones stop resembling anything anybody dictates.
MIN_SECONDS = 2.0
MAX_SECONDS = 12.0


def build(out: Path, limit: int) -> list[dict]:
    path = hf_hub_download(REPO, SHARD, repo_type="dataset")
    table = pq.read_table(path)

    rows = []
    for row in table.to_pylist():
        try:
            duration = float(row["end_ts"]) - float(row["start_ts"])
        except (TypeError, ValueError):
            continue
        text = (row.get("transcription") or "").strip()
        if not text or not MIN_SECONDS <= duration <= MAX_SECONDS:
            continue
        rows.append((row, duration, text))

    # Stable order by id, so a smoke run and a fast run agree on which clips
    # they share and the cache is reused rather than invalidated.
    rows.sort(key=lambda r: (r[0]["file_id"], int(r[0]["segment_id"])))

    items = []
    for row, duration, text in rows[:limit]:
        name = f"{row['file_id']}-{row['segment_id']}"
        source = out / "_raw" / f"{name}.wav"
        if not source.exists():
            source.parent.mkdir(parents=True, exist_ok=True)
            source.write_bytes(row["audio"]["bytes"])
        wav = to_wav(source, out / f"{name}.wav")
        items.append({
            "id": name,
            "audio": str(wav),
            "reference": text,
            "durationSeconds": round(duration, 2),
        })
    return items
