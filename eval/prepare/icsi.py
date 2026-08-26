"""ICSI — real research meetings, summarized by hand.

Chosen over the ELITR minuting corpus this suite originally aimed at. ELITR is
distributed through a DSpace 7 front end that serves HTML rather than the
archive at every stable URL it advertises, and it is CC BY-NC-SA, so it could
not have been redistributed with the harness anyway. ICSI costs nothing extra:
it is annotated in the same NXT schema as AMI, so `nxt.py` already reads it, and
it is CC BY 4.0.

It also earns the slot on its own merits. AMI is four people role-playing a
product design from a script; ICSI is the Berkeley speech group holding their
actual weekly meetings, with real agendas, genuine disagreement, and five to
eight participants rather than a tidy four. Summarizing a real meeting is a
different problem from summarizing a scenario, and that difference is exactly
what a third corpus is for.

Speaker naming is not scored here — ICSI ships no speaker-to-name mapping, so
there is nothing to be right or wrong against. That sub-score is simply absent
for this corpus rather than counted as a failure.
"""

from __future__ import annotations

import zipfile
from pathlib import Path

import requests

from . import nxt
from .qmsum import write_transcript

ANNOTATIONS_URL = "https://groups.inf.ed.ac.uk/ami/ICSICorpusAnnotations/ICSI_plus_NXT.zip"


def annotations(out: Path) -> Path:
    cache = out.parent / "_cache"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "icsi.zip"
    extracted = cache / "icsi"

    if not archive.exists():
        response = requests.get(ANNOTATIONS_URL, timeout=600)
        response.raise_for_status()
        archive.write_bytes(response.content)

    marker = extracted / ".extracted"
    if not marker.exists():
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(extracted)
        marker.write_text(ANNOTATIONS_URL)
    return extracted


def build(out: Path, limit: int) -> list[dict]:
    root = annotations(out)
    available = sorted(
        path.name.split(".")[0]
        for path in (root / nxt.ICSI.abstractive).glob("*.abssumm.xml")
    )

    items = []
    for mid in available:
        if len(items) >= limit:
            break
        gold = nxt.summary(root, nxt.ICSI, mid)
        if not gold:
            continue

        # Interleave every speaker's utterances back into one timeline, then
        # collapse consecutive turns by the same person — the corpus segments
        # per speaker, and a transcript that alternates every three words reads
        # nothing like what the app produces.
        turns: list[tuple[float, str, str]] = []
        for agent in nxt.agents(root, nxt.ICSI, mid):
            for start, _, text in nxt.utterances(root, nxt.ICSI, mid, agent):
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

        path = write_transcript(out, mid, merged)
        items.append({
            "id": mid,
            "transcript": str(path),
            "gold": {
                **gold,
                "topics": [],
                # No name mapping exists for this corpus, so every speaker's
                # truth is "cannot be known" and the sub-score sits out.
                "speakerNames": {},
            },
        })
    return items
