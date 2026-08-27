#!/usr/bin/env python3
"""Check the diarization harness against a published number before believing it.

    uv run --project eval eval/calibrate_der.py

A scoring harness that is quietly wrong looks exactly like one that works, and
diarization error rate is the easiest number in this suite to compute
incorrectly — collar, overlap handling and the choice of reference each move it
by tens of points. So it gets checked against somebody else's published result
on the same meetings before any of it is reported.

Two references, deliberately:

* **pyannote's RTTM**, which is what pyannote and FluidAudio publish against, and
  which describes *who was speaking when* — the diarizer's own output.
* **our transcript**, which is ASR segments carrying the labels the diarizer gave
  them. That is what a user actually reads, and it is a different and harsher
  thing to measure, because an ASR segment boundary is not a speech boundary.

If the first is near the published figure the harness is sound, and any gap in
the second is a real property of the product rather than a bug in the scoring.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from pyannote.core import Annotation, Segment  # noqa: E402
from pyannote.metrics.diarization import DiarizationErrorRate  # noqa: E402

from common import DATA, FWEVAL  # noqa: E402
from prepare import ami  # noqa: E402
from score.meeting import DER_COLLAR, DER_SKIP_OVERLAP, _annotation  # noqa: E402

#: What each channel is checked against, and whether it decides the verdict.
#:
#: The headset mix is the gate. It is also the condition this app actually
#: records: on a video call every remote participant is close-miked and the
#: platform mixes them, which is what a headset mix is. The array is a far-field
#: capture of a room and is reported for context only — FluidAudio's 10.6% is
#: from their own 16-meeting run with their own clustering configuration, and a
#: two-meeting subset scored here is not the same measurement. Gating on a
#: number we cannot reproduce the conditions for would fail honest runs.
PUBLISHED = {
    "Mix-Headset": ("pyannote, AMI headset-mix", 0.188, True),
    "Array1-01": ("FluidAudio, AMI SDM — different split and config, context only", 0.106, False),
}

MEETINGS = ["IS1009a", "ES2004a"]


def rttm_annotation(text: str) -> Annotation:
    """The reference every published AMI diarization number is measured against."""
    annotation = Annotation()
    for index, line in enumerate(text.strip().splitlines()):
        parts = line.split()
        if len(parts) < 8 or parts[0] != "SPEAKER":
            continue
        start, duration, speaker = float(parts[3]), float(parts[4]), parts[7]
        if duration > 0:
            annotation[Segment(start, start + duration), index] = speaker
    return annotation


def diarize(meeting: str, channel: str, model: str) -> dict:
    """Run the real pipeline over one meeting and hand back its transcript."""
    out = DATA / "ami"
    audio = ami.audio(out, meeting, channel=channel)

    with tempfile.TemporaryDirectory() as workspace:
        manifest = Path(workspace) / "manifest.json"
        manifest.write_text(json.dumps({
            "dataset": "calibration",
            "track": "meeting",
            "items": [{"id": meeting, "audio": str(audio)}],
        }))
        results = Path(workspace) / "results"
        subprocess.run(
            [str(FWEVAL), "meeting", "--manifest", str(manifest),
             "--model", model, "--out", str(results)],
            check=True, capture_output=True,
        )
        return json.loads((results / f"{meeting}.json").read_text())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="parakeet-v3")
    parser.add_argument("--channel", action="append", choices=list(PUBLISHED))
    args = parser.parse_args()
    channels = args.channel or list(PUBLISHED)

    out = DATA / "ami"
    root = ami.annotations(out)
    print(f"model: {args.model}   collar {DER_COLLAR}, "
          f"overlap {'excluded' if DER_SKIP_OVERLAP else 'scored'}\n")

    verdicts = []
    for channel in channels:
        label, published, gates = PUBLISHED[channel]
        against_rttm = DiarizationErrorRate(collar=DER_COLLAR, skip_overlap=DER_SKIP_OVERLAP)
        against_ours = DiarizationErrorRate(collar=DER_COLLAR, skip_overlap=DER_SKIP_OVERLAP)

        for meeting in MEETINGS:
            result = diarize(meeting, channel, args.model)
            reference = rttm_annotation(ami.rttm(out, meeting))
            # The diarizer's own turns, which is what published DER scores.
            against_rttm(reference, _annotation(result.get("speakerTurns") or [], "speaker"))
            # The same reference against the finished transcript, which is what
            # the user reads. The gap between the two is the cost of assembly.
            against_ours(reference, _annotation(result["segments"], "speaker"))

        measured = abs(against_rttm)
        verdicts.append((channel, measured, published, gates, abs(against_ours)))
        print(f"{channel}{'' if gates else '   (context only)'}")
        print(f"  diarizer turns         DER {measured:.3f}   "
              f"(published {published:.3f} — {label})")
        print(f"  finished transcript    DER {abs(against_ours):.3f}   "
              "(after assembly labels each word and cuts on speaker changes)")
        detail = against_rttm[:]
        print(f"  miss {detail['missed detection']:.0f}s  "
              f"false alarm {detail['false alarm']:.0f}s  "
              f"confusion {detail['confusion']:.0f}s  of {detail['total']:.0f}s\n")

    # Within 1.75x of the published figure. Loose on purpose: the split, the
    # engine and the exact pyannote revision all differ, and the check is meant
    # to catch a harness that is wrong by a factor, not to reproduce a paper.
    gated = [v for v in verdicts if v[3]]
    ok = all(measured <= published * 1.75 for _, measured, published, _, _ in gated)
    print("HARNESS OK" if ok else "HARNESS SUSPECT — do not publish these numbers")

    # The gap between the diarizer and the transcript is not a harness problem,
    # but it is the most actionable thing this check produces, so say it out
    # loud rather than leaving it in two numbers a reader has to subtract.
    for channel, measured, _, gates, delivered in verdicts:
        if gates and delivered > measured * 1.5:
            print(
                f"\nNote: on {channel} the diarizer is right {(1 - measured) * 100:.0f}% of the "
                f"time but the finished transcript is only {(1 - delivered) * 100:.0f}%. "
                "The remainder is what assembly costs: words whose own timing puts them "
                "on the wrong side of a turn boundary, and segments that arrived with no "
                "word timings to cut on."
            )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
