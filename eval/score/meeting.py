"""Meeting transcripts: the words, the speakers, and the two together.

Three numbers, because "the transcript is bad" has two quite different causes
and the fix for each is a different model:

  * **ORC-WER** ignores speaker labels entirely and asks only whether the words
    came out right. This is the ASR model's score.
  * **DER** ignores words entirely and asks only whether the speaker turns were
    found and grouped correctly. This is the diarizer's score, and since the
    diarizer follows from the engine, every Whisper model shares one and both
    Parakeets share another.
  * **tcpWER** is the headline, and is the only one of the three that describes
    what the user actually receives. It matches hypothesis speakers to reference
    speakers, then scores words within each — so a perfectly transcribed
    sentence attributed to the wrong person is wrong, which is correct, because
    to a reader it is.

The diagnostic that matters is the gap between the first and the third. High
ORC with low tcpWER means the words are fine and the diarization is not.
"""

from __future__ import annotations

import meeteval.wer as meeteval_wer
from meeteval.io.seglst import SegLST
from pyannote.core import Annotation, Segment
from pyannote.metrics.diarization import DiarizationErrorRate

from common import score_from_error_rate

from .asr import normalize

#: Five seconds, matching CHiME-8 and NOTSOFAR-1. The collar exists because
#: tcpWER would otherwise punish a model for placing a correct word slightly off
#: in time, and ASR timestamps are approximate by nature. Five is loose enough
#: to forgive that and tight enough to still catch a transcript that has drifted.
TCP_COLLAR = 5.0

#: Quarter-second collar, overlap excluded — the configuration FluidAudio's
#: published AMI numbers use. Chosen for comparability, not because it is the
#: strictest option: it is what lets us check our DER against theirs and notice
#: when the harness itself is wrong.
DER_COLLAR = 0.25
DER_SKIP_OVERLAP = True


def _seglst(session: str, segments: list[dict], speaker_key: str) -> SegLST:
    rows = []
    for segment in segments:
        words = normalize(segment.get("text", ""))
        if not words:
            continue
        rows.append({
            "session_id": session,
            "start_time": float(segment.get("start", 0.0)),
            "end_time": float(segment.get("end", 0.0)),
            "words": words,
            "speaker": str(segment.get(speaker_key) or "unknown"),
        })
    return SegLST(rows)


def _annotation(segments: list[dict], speaker_key: str) -> Annotation:
    annotation = Annotation()
    for index, segment in enumerate(segments):
        start, end = float(segment.get("start", 0.0)), float(segment.get("end", 0.0))
        if end <= start:
            continue
        annotation[Segment(start, end), index] = str(segment.get(speaker_key) or "unknown")
    return annotation


def score(items: list[dict], results: dict[str, dict]) -> dict:
    references: list[SegLST] = []
    hypotheses: list[SegLST] = []
    # Two, because they answer different questions. `delivered` scores the
    # labels on the transcript the user reads; `diarizer` scores the turns the
    # diarizer produced before assembly attributed ASR segments to them. Only
    # the second is comparable to published diarization numbers, and the gap
    # between them is the cost of the assembly step.
    delivered = DiarizationErrorRate(collar=DER_COLLAR, skip_overlap=DER_SKIP_OVERLAP)
    diarizer = DiarizationErrorRate(collar=DER_COLLAR, skip_overlap=DER_SKIP_OVERLAP)

    audio_total = 0.0
    wall_total = 0.0
    scored = 0
    failures = 0
    der_scored = 0
    turns_scored = 0

    for item in items:
        result = results.get(item["id"])
        if result is None:
            continue

        reference = item.get("refSegments") or []
        if not reference:
            continue

        # A failure is scored as an empty transcript rather than skipped — see
        # the note in `asr.py`. A model that crashes on a meeting has not
        # declined to be measured, it has produced the worst possible result.
        if result.get("error"):
            failures += 1
            references.append(_seglst(item["id"], reference, "speaker"))
            # One row with no words, rather than no rows. A session absent from
            # the hypothesis entirely is not "got everything wrong" to meeteval,
            # it is a missing recording, and it refuses to score the set at all —
            # which is exactly the confusion it is warning about, since a system
            # that silently drops a file would otherwise look flawless.
            hypotheses.append(SegLST([{
                "session_id": item["id"],
                "start_time": 0.0,
                "end_time": 0.0,
                "words": "",
                "speaker": "unknown",
            }]))
            scored += 1
            continue

        hypothesis = result.get("segments") or []

        session = item["id"]
        references.append(_seglst(session, reference, "speaker"))
        hypotheses.append(_seglst(session, hypothesis, "speaker"))
        scored += 1

        # Accumulated into the metric objects rather than averaged after the
        # fact: pyannote pools the confusion, miss and false-alarm times across
        # files, which is what a corpus-level DER means.
        reference_annotation = _annotation(reference, "speaker")
        if hypothesis:
            delivered(reference_annotation, _annotation(hypothesis, "speaker"))
            der_scored += 1

        turns = result.get("speakerTurns") or []
        if turns:
            diarizer(reference_annotation, _annotation(turns, "speaker"))
            turns_scored += 1

        audio_total += result.get("audioSeconds") or 0.0
        wall_total += result.get("wallSeconds") or 0.0

    if not references:
        return {"n": 0, "failures": failures}

    merged_reference = SegLST([row for group in references for row in group])
    merged_hypothesis = SegLST([row for group in hypotheses for row in group])

    tcp = _pool(meeteval_wer.tcpwer(merged_reference, merged_hypothesis, collar=TCP_COLLAR))
    cp = _pool(meeteval_wer.cpwer(merged_reference, merged_hypothesis))
    # The greedy assignment, not the exact one. ORC-WER searches over ways to
    # assign each hypothesis segment to a reference speaker, and on a real
    # meeting — hundreds of segments, four or five speakers — the exact search
    # does not finish: it ran for ten minutes here and then died. meeteval ships
    # the greedy variant for this case. It is an upper bound on the true ORC-WER,
    # so the words column is if anything pessimistic, and it returns in a second.
    orc = _pool(meeteval_wer.greedy_orcwer(merged_reference, merged_hypothesis))

    delivered_der = abs(delivered) if der_scored else None
    diarizer_der = abs(diarizer) if turns_scored else None

    return {
        "n": scored,
        "failures": failures,
        "score": score_from_error_rate(tcp),
        "tcpwer": tcp,
        "wordScore": score_from_error_rate(orc),
        "orcwer": orc,
        "cpwer": cp,
        "speakerScore": score_from_error_rate(delivered_der) if delivered_der is not None else None,
        "der": delivered_der,
        "diarizerScore": score_from_error_rate(diarizer_der) if diarizer_der is not None else None,
        "diarizerDer": diarizer_der,
        "audioSeconds": audio_total,
        "wallSeconds": wall_total,
        "rtfx": (audio_total / wall_total) if wall_total else None,
    }


def _pool(per_session: dict) -> float:
    """One error rate for the corpus, weighted by reference length.

    Not the mean of the per-meeting rates: that would give a four-minute meeting
    the same say as a thirty-minute one. Summing errors over summing reference
    words is what "the error rate on this corpus" means.
    """
    errors = sum(rate.errors for rate in per_session.values())
    length = sum(rate.length for rate in per_session.values())
    return (errors / length) if length else 0.0
