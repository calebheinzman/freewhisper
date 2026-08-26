"""QMSum — meeting summaries with real names attached.

Thirty-five test meetings drawn from AMI, ICSI and Welsh parliamentary
committees, each with a human answer to "Summarize the whole meeting." Two
things make it the most useful of the three summary corpora:

  * the committee half names its speakers properly ("Lynne Neagle AM"), which is
    the only clean ground truth anywhere in this suite for whether a model can
    work out who was in the room; and
  * it is MIT licensed, so unlike ELITR it can be redistributed.

It has no action-item annotation, so that sub-score is simply absent here rather
than scored as zero — see the note in `score/summary.py` about averaging over
the sub-scores a corpus can actually support.
"""

from __future__ import annotations

import json
from pathlib import Path

import requests

URL = "https://raw.githubusercontent.com/Yale-LILY/QMSum/main/data/ALL/jsonl/test.jsonl"

#: The prompt whose answer is the whole-meeting summary. QMSum's general queries
#: are phrased a few different ways; this is the one that matches what our
#: summarizer is asked to produce.
WHOLE_MEETING = "summarize the whole meeting"


def build(out: Path, limit: int) -> list[dict]:
    cache = out.parent / "_cache" / "qmsum-test.jsonl"
    if not cache.exists():
        cache.parent.mkdir(parents=True, exist_ok=True)
        response = requests.get(URL, timeout=120)
        response.raise_for_status()
        cache.write_text(response.text)

    items = []
    for index, line in enumerate(cache.read_text().splitlines()):
        if len(items) >= limit:
            break
        meeting = json.loads(line)
        gold = _general_summary(meeting)
        if not gold:
            continue

        name = f"qmsum-{index:03d}"
        turns = [
            (str(turn.get("speaker") or "").strip(), (turn.get("content") or "").strip())
            for turn in meeting.get("meeting_transcripts", [])
        ]
        turns = [(speaker, text) for speaker, text in turns if speaker and text]
        if not turns:
            continue

        path = write_transcript(out, name, turns)
        items.append({
            "id": name,
            "transcript": str(path),
            "gold": {
                "summary": gold,
                # No action-item annotation in this corpus. Left empty on
                # purpose, and read as "not scorable here" rather than "none".
                "actionItems": [],
                "keyPoints": [],
                "topics": [t.get("topic", "") for t in meeting.get("topic_list", [])],
                "speakerNames": speaker_truth(turns),
            },
        })
    return items


def _general_summary(meeting: dict) -> str:
    for query in meeting.get("general_query_list", []):
        if WHOLE_MEETING in (query.get("query") or "").lower():
            return (query.get("answer") or "").strip()
    return ""


# ---------------------------------------------------------------- shared


def speaker_truth(turns: list[tuple[str, str]]) -> dict[str, str | None]:
    """What each speaker's label should resolve to — or None, meaning abstain.

    A model can only name someone whose name is actually spoken by somebody.
    Where the gold name never appears in anyone's words, the correct answer is
    to leave that speaker as "Speaker 3", and the truth here is None so the
    scorer can credit silence. Without this the metric would reward guessing a
    name for every speaker, which is precisely the behaviour that puts a
    stranger's name on someone's words.
    """
    spoken = " ".join(text for _, text in turns).lower()
    truth: dict[str, str | None] = {}
    for order, name in enumerate(dict.fromkeys(speaker for speaker, _ in turns)):
        label = f"Speaker {order + 1}"
        # First name is enough: people say "Lynne", not "Lynne Neagle AM".
        first = name.split()[0].lower() if name.split() else ""
        nameable = len(first) > 2 and first in spoken
        truth[label] = name if nameable else None
    return truth


def write_transcript(out: Path, name: str, turns: list[tuple[str, str]]) -> Path:
    """Render gold turns as a `Transcript`, with the speakers anonymized.

    Anonymizing is the whole experiment for the speaker-naming sub-score: the
    model sees "Speaker 1" exactly as it would after diarization, and has to
    recover the name from what people call each other. Handing it the real
    labels would make the task trivial and the score meaningless.
    """
    order = list(dict.fromkeys(speaker for speaker, _ in turns))
    labels = {speaker: f"Speaker {i + 1}" for i, speaker in enumerate(order)}

    segments = []
    for index, (speaker, text) in enumerate(turns):
        segments.append({
            "id": f"{index:08d}-0000-0000-0000-{index:012d}",
            "start": float(index),
            "end": float(index) + 1.0,
            "text": text,
            "channel": "system",
            "speakerID": f"speaker_{order.index(speaker)}",
            "speakerName": labels[speaker],
        })

    payload = {
        "segments": segments,
        "speakerNames": {f"speaker_{i}": labels[s] for i, s in enumerate(order)},
        "engine": "gold",
        "generatedAt": "2026-01-01T00:00:00Z",
    }
    path = out / f"{name}.transcript.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=1))
    return path
