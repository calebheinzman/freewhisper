"""LibriSpeech, via Argmax's 200-clip subset.

Read audiobook speech, clean recording, mostly North American. Deliberately the
easy one: it is the anchor that says what a model's word error rate looks like
when nothing is working against it, so the other two corpora can be read as the
cost of accents and of spontaneity rather than as absolute numbers.

Argmax publish this subset and also ship WhisperKit, which this app depends on,
so it doubles as a calibration check — our numbers here should land near the
published ones.
"""

from __future__ import annotations

import json
from pathlib import Path

from huggingface_hub import hf_hub_download

from .audio import to_wav

REPO = "argmaxinc/librispeech-200"


def build(out: Path, limit: int) -> list[dict]:
    metadata = json.loads(
        Path(hf_hub_download(REPO, "metadata.json", repo_type="dataset")).read_text()
    )
    # Sorted by clip name, not by duration: the source order is arbitrary and a
    # stable order means `--profile smoke` picks the same five clips every run.
    metadata.sort(key=lambda row: row["audio"])

    items = []
    for row in metadata[:limit]:
        flac = hf_hub_download(REPO, row["audio"], repo_type="dataset")
        name = Path(row["audio"]).stem
        wav = to_wav(flac, out / f"{name}.wav")
        items.append({
            "id": name,
            "audio": str(wav),
            "reference": row["text"],
            "durationSeconds": row["duration"],
        })
    return items
