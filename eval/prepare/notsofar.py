"""NOTSOFAR-1 — the corpus that looks most like what this app records.

Microsoft recorded real meetings in real conference rooms with a device sitting
on the table, which is close to the position a laptop is in during a call. Where
AMI is a 2005 scenario exercise and CHiME-6 is a deliberately awful dinner
party, this is simply a meeting, at the distance meetings actually happen.

The single-channel `sc_*/ch0.wav` capture is used rather than the seven-channel
array. The app has one microphone.
"""

from __future__ import annotations

import json
from pathlib import Path

from huggingface_hub import hf_hub_download, list_repo_files

from .audio import to_wav

REPO = "microsoft/NOTSOFAR"
#: The eval split that ships reference transcripts. The plain `eval_small`
#: directory beside it has the audio but no ground truth, which makes it useless
#: here and easy to reach for by mistake.
BASE = "benchmark-datasets/eval_set/240629.1_eval_small_with_GT/MTG"


def _meetings() -> dict[str, list[str]]:
    grouped: dict[str, list[str]] = {}
    for path in list_repo_files(REPO, repo_type="dataset"):
        if not path.startswith(BASE + "/"):
            continue
        rest = path[len(BASE) + 1:]
        meeting, _, tail = rest.partition("/")
        if tail.startswith("sc_") or tail == "gt_transcription.json":
            grouped.setdefault(meeting, []).append(tail)
    return grouped


def build(out: Path, limit: int) -> list[dict]:
    meetings = _meetings()

    items = []
    for meeting in sorted(meetings)[:limit]:
        files = meetings[meeting]
        channel = next((f for f in sorted(files) if f.startswith("sc_")), None)
        if not channel or "gt_transcription.json" not in files:
            continue

        source = hf_hub_download(REPO, f"{BASE}/{meeting}/{channel}", repo_type="dataset")
        gt_path = hf_hub_download(
            REPO, f"{BASE}/{meeting}/gt_transcription.json", repo_type="dataset"
        )
        wav = to_wav(source, out / f"{meeting}.wav")

        segments = []
        for row in json.loads(Path(gt_path).read_text()):
            text = (row.get("text") or "").strip()
            if not text:
                continue
            segments.append({
                "start": float(row["start_time"]),
                "end": float(row["end_time"]),
                # Real first names, which is unusual and useful: it means the
                # same corpus can score diarization and speaker naming.
                "speaker": str(row["speaker_id"]),
                "text": text,
            })
        segments.sort(key=lambda s: s["start"])
        if not segments:
            continue

        items.append({
            "id": meeting,
            "audio": str(wav),
            "refSegments": segments,
        })
    return items
