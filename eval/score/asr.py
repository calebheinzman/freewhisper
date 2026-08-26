"""Dictation accuracy: word error rate, normalized.

Normalization is not a detail here, it is most of the measurement. Raw WER
against these references punishes a model for writing "$25 million" where the
reference says "twenty five million dollars", for capitalizing a sentence, and
for adding a full stop — none of which is a mistake in text about to be typed
into someone's email. Whisper's own English normalizer is the standard answer
and is what every published number on these corpora uses, so applying it to both
sides keeps our figures comparable to the literature rather than merely
internally consistent.
"""

from __future__ import annotations

import jiwer
from whisper_normalizer.english import EnglishTextNormalizer

from common import score_from_error_rate

_normalize = EnglishTextNormalizer()


def normalize(text: str) -> str:
    return _normalize(text or "").strip()


def score(items: list[dict], results: dict[str, dict]) -> dict:
    """Corpus-level WER, plus the latency figures the picker needs."""
    references: list[str] = []
    hypotheses: list[str] = []
    latencies: list[float] = []
    speeds: list[float] = []
    audio_total = 0.0
    failures = 0

    for item in items:
        result = results.get(item["id"])
        if result is None:
            continue

        reference = normalize(item.get("reference", ""))
        if not reference:
            # An empty reference makes WER undefined — jiwer divides by the
            # reference length. Skipping is right: there is no claim to check.
            continue

        if result.get("error"):
            # Scored as an empty transcript, not skipped.
            #
            # Skipping failures is how a broken model gets a good score: one
            # engine here crashed on 176 of 200 clips and, judged on the 24 that
            # survived, looked like the best model in the table. A crash is not
            # a missing measurement, it is the worst possible outcome — the user
            # asked for a transcript and got nothing — so every reference word
            # counts as a deletion, which is exactly what an empty hypothesis
            # gives us.
            failures += 1
            references.append(reference)
            hypotheses.append("")
            continue

        references.append(reference)
        hypotheses.append(normalize(result.get("text", "")))

        wall = result.get("wallSeconds") or 0.0
        latencies.append(wall)
        if result.get("rtfx"):
            speeds.append(result["rtfx"])
        audio_total += result.get("audioSeconds") or 0.0

    if not references:
        return {"n": 0, "failures": failures}

    # Pooled over the whole corpus rather than averaged per clip. A per-clip
    # mean lets a three-word utterance that came out wrong count as much as a
    # thirty-second one that came out right, which overstates the error on
    # exactly the short clips this track is full of.
    measures = jiwer.process_words(references, hypotheses)
    characters = jiwer.process_characters(references, hypotheses)

    return {
        "n": len(references),
        "failures": failures,
        "failureRate": failures / len(references),
        "score": score_from_error_rate(measures.wer),
        "wer": measures.wer,
        "cer": characters.cer,
        "insertions": measures.insertions,
        "deletions": measures.deletions,
        "substitutions": measures.substitutions,
        "audioSeconds": audio_total,
        "medianLatencySeconds": _median(latencies),
        "rtfx": (audio_total / sum(latencies)) if sum(latencies) else None,
        "medianRtfx": _median(speeds),
    }


def _median(values: list[float]) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2
