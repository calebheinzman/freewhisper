#!/usr/bin/env python3
"""Turn a scorecard into the table people read and the file the app ships.

    uv run --project eval eval/report.py --profile fast

Writes three things from one scorecard:

  * `docs/MODEL_SCORECARD.md` — the full table, with the caveats attached
  * `Sources/FreeWhisperKit/Resources/scorecard.json` — what the Settings picker
    reads, which is only the headline score and speed per model id
  * a summary to stdout
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import ASR, DATASETS, MEETING, REPO, RESULTS, SUMMARIZE  # noqa: E402

BUNDLED = REPO / "Sources" / "FreeWhisperKit" / "Resources" / "scorecard.json"
DOC = REPO / "docs" / "MODEL_SCORECARD.md"

NAMES = {
    "whisper-large-v3-turbo": "Whisper large-v3 turbo",
    "parakeet-v3": "Parakeet TDT 0.6b v3",
    "whisper-large-v3": "Whisper large-v3",
    "distil-whisper-large-v3": "Distil-Whisper large-v3",
    "parakeet-110m": "Parakeet TDT-CTC 110M",
    "mlx-community/Qwen3-4B-Instruct-2507-4bit": "Qwen3 4B Instruct",
    "mlx-community/Llama-3.2-3B-Instruct-4bit": "Llama 3.2 3B Instruct",
    "mlx-community/Qwen3-1.7B-4bit": "Qwen3 1.7B",
}


def num(value, places=2, dash="—") -> str:
    return f"{value:.{places}f}" if isinstance(value, (int, float)) else dash


def speed(value) -> str:
    return f"{value:.0f}×" if isinstance(value, (int, float)) else "—"


def seconds(value) -> str:
    if not isinstance(value, (int, float)):
        return "—"
    return f"{value:.1f}s" if value < 60 else f"{value / 60:.1f} min"


def table(rows: list[list[str]], header: list[str]) -> str:
    widths = [max(len(str(r[i])) for r in [header, *rows]) for i in range(len(header))]
    line = lambda cells: "| " + " | ".join(str(c).ljust(widths[i]) for i, c in enumerate(cells)) + " |"
    return "\n".join([
        line(header),
        "|" + "|".join("-" * (w + 2) for w in widths) + "|",
        *(line(r) for r in rows),
    ])


def sorted_models(track_data: dict) -> list[tuple[str, dict]]:
    """Best first — but never rank a partial row above a complete one.

    Each headline is a mean over the corpora a model was scored on, so a model
    that has only been through the easy corpus outscores one that has been
    through all three. During a run that is every model in turn, and the table
    would confidently rank them by how far along they are. Completeness sorts
    first, score second, and incomplete rows are marked in the table itself.
    """
    complete = max((len(d.get("datasets", {})) for d in track_data.values()), default=0)
    return sorted(
        track_data.items(),
        key=lambda kv: (
            len(kv[1].get("datasets", {})) >= complete,
            kv[1].get("score") if isinstance(kv[1].get("score"), (int, float)) else -1,
        ),
        reverse=True,
    )


def coverage(data: dict, expected: int) -> str:
    """A marker for a row whose average is over fewer corpora than its peers."""
    return "" if len(data.get("datasets", {})) >= expected else " ⚠"


def render(report: dict) -> str:
    tracks = report.get("tracks", {})
    calibration = report.get("calibration") or {}
    out: list[str] = []

    out.append("# Model scorecard\n")
    out.append(
        "Every score is 0 to 1, higher is better, and each is an average over three "
        "deliberately different corpora — the per-corpus numbers are underneath each "
        "table. Speed and latency were measured on one machine and do not transfer.\n"
    )
    # Every model's pass over every corpus, added up: what the run cost.
    audio = sum(
        scored.get("audioSeconds") or 0
        for track in (ASR, MEETING)
        for model in tracks.get(track, {}).values()
        for scored in model.get("datasets", {}).values()
    )
    out.append(
        f"- **Measured on:** {report.get('host', 'unknown')}\n"
        f"- **Date:** {report.get('generatedAt', '')}  \n"
        f"- **Profile:** `{report.get('profile', '')}`"
        + (f", {audio / 3600:.1f} hours of audio transcribed in total\n" if audio else "\n")
    )

    # ---- dictation -------------------------------------------------------
    if ASR in tracks:
        out.append("\n## Voice to text\n")
        out.append(
            "What the ⌘⎋ hotkey produces. Scored as `1 − WER` after Whisper's English "
            "normalizer, so a model is not marked down for writing \"$25m\" where the "
            "reference says \"twenty five million dollars\".\n"
        )
        rows = []
        broken = []
        expected = max(len(d.get("datasets", {})) for d in tracks[ASR].values())
        for model, data in sorted_models(tracks[ASR]):
            by = data.get("datasets", {})
            failed = sum(d.get("failures") or 0 for d in by.values())
            total = sum(d.get("n") or 0 for d in by.values())
            # A transient failure is noise; a model that cannot run is the
            # headline. Only the second deserves a callout, or the note appears
            # under a model whose score it does not explain and undermines every
            # other note on the page.
            if total and failed / total > 0.05:
                broken.append((NAMES.get(model, model), failed, total))
            rows.append([
                NAMES.get(model, model) + coverage(data, expected),
                f"**{num(data.get('score'))}**",
                num(by.get("librispeech", {}).get("score")),
                num(by.get("earnings22", {}).get("score")),
                num(by.get("ami-ihm", {}).get("score")),
                f"{failed}/{total}" if total else "—",
                speed(data.get("rtfx")),
                seconds(data.get("medianLatencySeconds")),
                seconds(data.get("modelLoadSeconds")),
            ])
        out.append(table(rows, [
            "Model", "Score", "Clean", "Accented", "Spontaneous", "Failed",
            "Speed", "Typical clip", "First use",
        ]))
        for name, failed, total in broken:
            out.append(
                f"\n> **{name} crashed on {failed} of {total} clips.** A crash is scored as "
                "an empty transcript rather than skipped, which is why its score is low: "
                "judged only on the clips that survived it would look like one of the best "
                "models here.\n"
            )
        out.append(
            "\n*Clean* = LibriSpeech, *Accented* = Earnings-22 (27 countries), "
            "*Spontaneous* = AMI headset turns. **Typical clip** is the median wall "
            "time for one utterance with the model already warm; **First use** is what "
            "the first dictation of a session waits for while the weights load.\n"
        )

    # ---- meetings --------------------------------------------------------
    if MEETING in tracks:
        out.append("\n## Meeting transcripts\n")
        out.append(
            "The headline is `1 − tcpWER`: words *and* the speaker they were attributed "
            "to, which is what the user actually reads. The two columns beside it split "
            "the blame — **Words** is `1 − ORC-WER`, ignoring speakers entirely, and "
            "**Speakers** is `1 − DER`, ignoring words entirely.\n"
        )
        rows = []
        expected = max(len(d.get("datasets", {})) for d in tracks[MEETING].values())
        for model, data in sorted_models(tracks[MEETING]):
            by = data.get("datasets", {})
            rows.append([
                NAMES.get(model, model) + coverage(data, expected),
                f"**{num(data.get('score'))}**",
                num(data.get("wordScore")),
                num(data.get("speakerScore")),
                num(data.get("diarizerScore")),
                num(by.get("ami", {}).get("score")),
                num(by.get("notsofar", {}).get("score")),
                num(by.get("ami-sdm", {}).get("score")),
                speed(data.get("rtfx")),
            ])
        out.append(table(rows, [
            "Model", "Score", "Words", "Speakers", "Diarizer",
            "AMI close", "NOTSOFAR", "AMI far", "Speed",
        ]))
        out.append(
            "\nA high **Words** with a low **Score** means the transcript is right and "
            "the speaker labels are wrong. **Speakers** and **Diarizer** are both "
            "`1 − DER`, and the gap between them is worth looking at: **Diarizer** is "
            "the turns the diarizer produced, and **Speakers** is what survived "
            "assembly, which attributes each whole ASR segment to whichever turn it "
            "overlaps most. A segment that runs across a speaker change takes one label "
            "for all of it.\n"
        )
        out.append(
            "\nNeither speaker column is a property of the ASR model — the diarizer "
            "follows from the engine, so every Whisper row shares one and both Parakeet "
            "rows share another. That is why they cluster.\n"
        )

    # ---- summaries -------------------------------------------------------
    if SUMMARIZE in tracks:
        out.append("\n## Summaries\n")
        out.append(
            "Judged by Gemini Flash against summaries written by people who attended "
            "the meeting, three samples per call with the median taken. The score is "
            "the mean of the four columns beside it.\n"
        )
        rows = []
        expected = max(len(d.get("datasets", {})) for d in tracks[SUMMARIZE].values())
        for model, data in sorted_models(tracks[SUMMARIZE]):
            rows.append([
                NAMES.get(model, model) + coverage(data, expected),
                f"**{num(data.get('score'))}**",
                num(data.get("summaryQuality")),
                num(data.get("actionItems")),
                num(data.get("meetingName")),
                num(data.get("speakerMapping")),
                seconds(data.get("medianWallSeconds")),
            ])
        out.append(table(rows, [
            "Model", "Score", "Summary", "Action items", "Meeting name",
            "Who was there", "Per meeting",
        ]))

        if calibration:
            boilerplate = calibration.get("boilerplate")
            out.append(
                f"\n**Read these against {num(boilerplate)}.** That is what a *different "
                "meeting's* human summary scores on the summary column — AMI is 140 "
                "recordings of four people designing the same remote control, so generic "
                "plausible text earns partial credit for free. A model near that number "
                "has guessed the genre rather than summarized the meeting.\n"
            )
            out.append(
                f"\nJudge check: identical summaries score "
                f"{num(calibration.get('ceiling'))}, unrelated ones "
                f"{num(calibration.get('floor'))}. "
                + ("The judge separates them cleanly.\n"
                   if calibration.get("trustworthy")
                   else "**The judge did not separate them; treat this table as unreliable.**\n")
            )

        out.append(
            "\n**Action items** are scored on AMI only — it is the one public corpus with "
            "typed action-item annotation. QMSum ships a whole-meeting abstract and "
            "nothing else, and no ICSI summary has an actions section. **Who was there** "
            "is scored on AMI and QMSum; ICSI publishes no speaker names. A model is "
            "credited for *not* naming a speaker whose name is never said aloud, so the "
            "column cannot be won by guessing.\n"
        )

    # ---- what was measured ----------------------------------------------
    if "⚠" in "\n".join(out):
        out.append(
            "\n⚠ marks a model averaged over fewer corpora than the others — usually a "
            "run that was interrupted. Its score is not comparable to the rows above it.\n"
        )

    out.append("\n## The corpora\n")
    rows = [
        [DATASETS[k].title, DATASETS[k].track, DATASETS[k].role, DATASETS[k].license]
        for k in report.get("datasets", {})
        if k in DATASETS
    ]
    out.append(table(rows, ["Corpus", "Track", "Why it is here", "Licence"]))

    out.append("\n## Reproducing\n")
    out.append(
        "```sh\n"
        "swift build -c release\n"
        "uv run --project eval eval/run.py --profile fast\n"
        "uv run --project eval eval/report.py --profile fast\n"
        "```\n"
    )
    return "\n".join(out) + "\n"


def bundle(report: dict) -> dict:
    """The subset the app ships: a score and a speed per model, per job.

    Keyed by role rather than one entry per model. A speech model is offered for
    two different jobs and is not equally good at both — Whisper turbo scores
    0.83 for dictation and 0.48 for meetings — and the two numbers are not even
    on the same scale, since one is word error and the other also counts who
    said what. Collapsing them means the picker is wrong in one of the two
    places the model appears.
    """
    entries: dict[str, dict] = {}
    for track, models in report.get("tracks", {}).items():
        for model, data in models.items():
            score = data.get("score")
            if not isinstance(score, (int, float)):
                continue
            # Whichever speed figure means something for this kind of model.
            if track == SUMMARIZE:
                speed_value, unit = data.get("medianWallSeconds"), "secondsPerMeeting"
            else:
                speed_value, unit = data.get("rtfx"), "realtimeFactor"

            entries.setdefault(model, {})[track] = {
                "track": track,
                "accuracy": round(score, 3),
                "speed": round(speed_value, 2) if isinstance(speed_value, (int, float)) else None,
                "speedUnit": unit,
            }

    return {
        "measuredOn": report.get("host", ""),
        "generatedAt": report.get("generatedAt", ""),
        "profile": report.get("profile", ""),
        "models": entries,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="fast")
    args = parser.parse_args()

    path = RESULTS / f"scorecard.{args.profile}.json"
    if not path.exists():
        print(f"No scorecard at {path}. Run eval/run.py first.", file=sys.stderr)
        return 1
    report = json.loads(path.read_text())

    DOC.parent.mkdir(parents=True, exist_ok=True)
    DOC.write_text(render(report))
    print(f"written: {DOC}")

    BUNDLED.parent.mkdir(parents=True, exist_ok=True)
    BUNDLED.write_text(json.dumps(bundle(report), indent=2, sort_keys=True))
    print(f"written: {BUNDLED}")

    print()
    print(render(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
