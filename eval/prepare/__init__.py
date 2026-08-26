"""Turning nine unrelated corpora into one manifest shape.

Each builder returns a list of manifest items. Everything downstream — the Swift
runner, the three scorers, the report — is written against that shape and knows
nothing about any particular corpus.
"""

from __future__ import annotations

from pathlib import Path

from common import DATA, DATASETS, write_manifest

from . import ami as ami_module
from . import earnings22, icsi, librispeech, notsofar, qmsum
from .qmsum import write_transcript


def _ami_meetings(out: Path, limit: int, channel: str = "Mix-Headset") -> list[dict]:
    """Track T: meeting audio with reference speaker turns.

    The reference is the same whichever microphone recorded it — who spoke when
    is a fact about the room, not about the capture — so the close-mic and
    far-field rows share everything except the audio.
    """
    root = ami_module.annotations(out)
    items = []
    for mid in ami_module.TEST_MEETINGS[:limit]:
        segments = ami_module.reference_segments(root, mid)
        if not segments:
            continue
        items.append({
            "id": mid,
            "audio": str(ami_module.audio(out, mid, channel=channel)),
            "refSegments": segments,
            "rttm": ami_module.rttm(out, mid),
        })
    return items


def _ami_utterances(out: Path, limit: int) -> list[dict]:
    """Track V: short spontaneous turns, cut from the meeting mix.

    Cut from `Mix-Headset` rather than the four individual headset channels.
    That is the compromise this makes knowingly: a true close-mic clip would be
    cleaner, but it costs four more multi-hundred-megabyte downloads per
    meeting, and the mix is nearer to what a laptop microphone hears anyway.
    """
    from .audio import to_wav

    root = ami_module.annotations(out)
    clips = out / "utterances"

    items: list[dict] = []
    for mid in ami_module.TEST_MEETINGS:
        if len(items) >= limit:
            break
        source = ami_module.audio(out, mid)
        for segment in ami_module.reference_segments(root, mid):
            if len(items) >= limit:
                break
            duration = segment["end"] - segment["start"]
            # Below a second is usually "yeah" or "mm-hmm", which measures
            # almost nothing; above twelve is no longer dictation.
            if not 1.0 <= duration <= 12.0 or len(segment["text"].split()) < 3:
                continue
            name = f"{mid}-{int(segment['start'] * 100):08d}"
            wav = to_wav(source, clips / f"{name}.wav", start=segment["start"], duration=duration)
            items.append({
                "id": name,
                "audio": str(wav),
                "reference": segment["text"],
                "durationSeconds": round(duration, 2),
            })
    return items


def _ami_summaries(out: Path, limit: int) -> list[dict]:
    """Track S: gold transcripts paired with the human abstract."""
    root = ami_module.annotations(out)

    items = []
    for mid in ami_module.TEST_MEETINGS:
        if len(items) >= limit:
            break
        gold = ami_module.summary(root, mid)
        if not gold:
            continue

        speakers = ami_module.speakers(root, mid)
        turns: list[tuple[float, str, str]] = []
        for agent in sorted(speakers):
            for start, _, text in ami_module.utterances(root, mid, agent):
                turns.append((start, agent, text))
        turns.sort()
        if not turns:
            continue

        merged: list[tuple[str, str]] = []
        for _, agent, text in turns:
            if merged and merged[-1][0] == agent:
                merged[-1] = (agent, merged[-1][1] + " " + text)
            else:
                merged.append((agent, text))

        spoken = " ".join(text for _, text in merged)
        path = write_transcript(out, mid, merged)
        items.append({
            "id": mid,
            "transcript": str(path),
            "gold": {
                **gold,
                "topics": [],
                "speakerNames": ami_module.speaker_truth(root, mid, spoken),
            },
        })
    return items


BUILDERS = {
    "librispeech": librispeech.build,
    "earnings22": earnings22.build,
    "ami-ihm": _ami_utterances,
    "ami": _ami_meetings,
    "notsofar": notsofar.build,
    "ami-sdm": lambda out, limit: _ami_meetings(out, limit, channel="Array1-01"),
    "ami-summ": _ami_summaries,
    "qmsum": qmsum.build,
    "icsi": icsi.build,
}


def build(key: str, profile: str) -> Path:
    """Prepare one dataset and write its manifest."""
    dataset = DATASETS[key]
    out = DATA / key
    out.mkdir(parents=True, exist_ok=True)

    items = BUILDERS[key](out, dataset.limit(profile))
    if not items:
        raise RuntimeError(f"{key}: prepared nothing — the corpus layout has probably moved")
    return write_manifest(key, profile, items)
