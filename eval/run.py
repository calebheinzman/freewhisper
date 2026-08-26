#!/usr/bin/env python3
"""Prepare, run and score the whole suite.

    uv run --project eval eval/run.py --profile smoke
    uv run --project eval eval/run.py --profile fast
    uv run --project eval eval/run.py --profile fast --track asr --model parakeet-v3

Everything is resumable. `fweval` skips items that already have a result file and
the judge caches its verdicts, so an interrupted three-hour run picks up where it
stopped, and adding one model re-runs only that model.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import prepare  # noqa: E402
from common import (  # noqa: E402
    ASR,
    DATASETS,
    FWEVAL,
    MEETING,
    RESULTS,
    SPEECH_MODELS,
    SUMMARIZE,
    SUMMARY_MODELS,
    datasets_for,
    host_description,
    load_manifest,
    load_results,
    load_run,
    manifest_path,
    results_dir,
)
from score import asr as score_asr  # noqa: E402
from score import judge as judging  # noqa: E402
from score import meeting as score_meeting  # noqa: E402
from score import summary as score_summary  # noqa: E402

TRACKS = (ASR, MEETING, SUMMARIZE)


def models_for(track: str) -> list[str]:
    return SUMMARY_MODELS if track == SUMMARIZE else SPEECH_MODELS


# ------------------------------------------------------------------ running


def run_model(track: str, key: str, model: str, profile: str, force: bool) -> None:
    """Invoke `fweval` for one (dataset, model) pair."""
    out = results_dir(track, key, model)
    out.mkdir(parents=True, exist_ok=True)

    command = [
        str(FWEVAL), track,
        "--manifest", str(manifest_path(key, profile)),
        "--model", model,
        "--out", str(out),
    ]
    if force:
        command.append("--force")
    if track == SUMMARIZE:
        # The three catalog summarizers are MLX weights, run in-process.
        command.append("--on-device")

    print(f"\n=== {track}/{key} — {model} ===", flush=True)
    result = subprocess.run(command)
    if result.returncode != 0:
        print(f"!!! fweval exited {result.returncode} for {model} on {key}", flush=True)


def already_done(track: str, key: str, model: str, profile: str) -> bool:
    expected = {item["id"] for item in load_manifest(key, profile)["items"]}
    return expected.issubset(set(load_results(track, key, model)))


# ------------------------------------------------------------------ scoring


def score_all(profile: str, tracks: tuple[str, ...]) -> dict:
    report: dict = {
        "profile": profile,
        "host": host_description(),
        "generatedAt": time.strftime("%Y-%m-%d"),
        "datasets": {
            key: {
                "title": d.title, "track": d.track, "role": d.role,
                "license": d.license, "source": d.source,
            }
            for key, d in DATASETS.items()
        },
        "tracks": {},
    }

    judge = None
    if SUMMARIZE in tracks:
        judge = judging.Judge(cache=RESULTS / "judge-cache.json")

    if judge:
        # Calibrated across all three summary corpora at once, so the floor is
        # measured between genuinely unrelated meetings rather than between two
        # runs of the same AMI scenario.
        pool = {
            d.key: load_manifest(d.key, profile)["items"]
            for d in datasets_for(SUMMARIZE)
            if manifest_path(d.key, profile).exists()
        }
        report["calibration"] = score_summary.calibrate(pool, judge)

    for track in tracks:
        per_model: dict[str, dict] = {}
        for dataset in datasets_for(track):
            if not manifest_path(dataset.key, profile).exists():
                continue
            items = load_manifest(dataset.key, profile)["items"]

            for model in models_for(track):
                results = load_results(track, dataset.key, model)
                if not results:
                    continue

                if track == ASR:
                    scored = score_asr.score(items, results)
                elif track == MEETING:
                    scored = score_meeting.score(items, results)
                else:
                    scored = score_summary.score(items, results, judge, model)

                run = load_run(track, dataset.key, model)
                if run:
                    scored["modelLoadSeconds"] = run.get("modelLoadSeconds")
                per_model.setdefault(model, {})[dataset.key] = scored
                print(
                    f"  {track:10} {dataset.key:12} {model:44} "
                    f"score={_fmt(scored.get('score'))} n={scored.get('n', 0)}",
                    flush=True,
                )

        report["tracks"][track] = {
            model: {
                "datasets": by_dataset,
                # The headline is the plain mean over the three corpora, not a
                # pooled figure. Each corpus is a different question — clean
                # speech, accented speech, spontaneous speech — and pooling would
                # let whichever one happens to have the most items decide the
                # answer to all three.
                "score": _mean([d.get("score") for d in by_dataset.values()]),
                **_aggregate(track, by_dataset),
            }
            for model, by_dataset in per_model.items()
        }

    return report


def _aggregate(track: str, by_dataset: dict) -> dict:
    values = list(by_dataset.values())
    if track == ASR:
        return {
            "wer": _mean([v.get("wer") for v in values]),
            "rtfx": _mean([v.get("rtfx") for v in values]),
            "medianLatencySeconds": _mean([v.get("medianLatencySeconds") for v in values]),
            # The cheapest load observed, not the average. Each corpus runs in a
            # fresh process, so the very first one also compiles CoreML kernels —
            # thirteen minutes for one model here — while every run after reads
            # the compiled cache. Averaging those together describes a wait
            # nobody has: the compile happens once per install, and the warm
            # figure is what a user pays at the start of every session.
            "modelLoadSeconds": _min([v.get("modelLoadSeconds") for v in values]),
            "firstLoadSeconds": _max([v.get("modelLoadSeconds") for v in values]),
        }
    if track == MEETING:
        return {
            "wordScore": _mean([v.get("wordScore") for v in values]),
            "speakerScore": _mean([v.get("speakerScore") for v in values]),
            "diarizerScore": _mean([v.get("diarizerScore") for v in values]),
            "tcpwer": _mean([v.get("tcpwer") for v in values]),
            "orcwer": _mean([v.get("orcwer") for v in values]),
            "der": _mean([v.get("der") for v in values]),
            "diarizerDer": _mean([v.get("diarizerDer") for v in values]),
            "rtfx": _mean([v.get("rtfx") for v in values]),
        }
    return {
        "summaryQuality": _mean([v.get("summaryQuality") for v in values]),
        "actionItems": _mean([v.get("actionItems") for v in values]),
        "meetingName": _mean([v.get("meetingName") for v in values]),
        "speakerMapping": _mean([v.get("speakerMapping") for v in values]),
        "rougeL": _mean([v.get("rougeL") for v in values]),
        "medianWallSeconds": _mean([v.get("medianWallSeconds") for v in values]),
        "charsPerSecond": _mean([v.get("charsPerSecond") for v in values]),
        "parseFailures": sum(v.get("parseFailures") or 0 for v in values),
    }


def _mean(values):
    present = [v for v in values if isinstance(v, (int, float))]
    return sum(present) / len(present) if present else None


def _min(values):
    present = [v for v in values if isinstance(v, (int, float))]
    return min(present) if present else None


def _max(values):
    present = [v for v in values if isinstance(v, (int, float))]
    return max(present) if present else None


def _fmt(value) -> str:
    return f"{value:.3f}" if isinstance(value, (int, float)) else "  -  "


# --------------------------------------------------------------------- main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", default="fast", choices=["smoke", "fast", "full"])
    parser.add_argument("--track", action="append", choices=list(TRACKS))
    parser.add_argument("--model", action="append")
    parser.add_argument("--dataset", action="append")
    parser.add_argument("--force", action="store_true", help="Re-run items that already have results.")
    parser.add_argument("--skip-prepare", action="store_true")
    parser.add_argument("--skip-run", action="store_true", help="Score what is already on disk.")
    args = parser.parse_args()

    tracks = tuple(args.track) if args.track else TRACKS

    if not FWEVAL.exists() and not args.skip_run:
        print(f"Missing {FWEVAL}. Build it first:\n  swift build -c release", file=sys.stderr)
        return 1

    started = time.time()

    if not args.skip_prepare:
        print("--- preparing ---", flush=True)
        for track in tracks:
            for dataset in datasets_for(track):
                if args.dataset and dataset.key not in args.dataset:
                    continue
                try:
                    prepare.build(dataset.key, args.profile)
                    count = len(load_manifest(dataset.key, args.profile)["items"])
                    print(f"  {dataset.key:12} {count} items", flush=True)
                except Exception as error:  # noqa: BLE001
                    # One unreachable corpus must not stop the other eight.
                    print(f"  {dataset.key:12} FAILED: {type(error).__name__}: {error}", flush=True)

    if not args.skip_run:
        print("\n--- running models ---", flush=True)
        for track in tracks:
            for dataset in datasets_for(track):
                if args.dataset and dataset.key not in args.dataset:
                    continue
                if not manifest_path(dataset.key, args.profile).exists():
                    continue
                for model in models_for(track):
                    if args.model and model not in args.model:
                        continue
                    if not args.force and already_done(track, dataset.key, model, args.profile):
                        print(f"  {track}/{dataset.key} {model}: cached", flush=True)
                        continue
                    run_model(track, dataset.key, model, args.profile, args.force)

    print("\n--- scoring ---", flush=True)
    report = score_all(args.profile, tracks)
    report["elapsedSeconds"] = round(time.time() - started, 1)

    RESULTS.mkdir(parents=True, exist_ok=True)
    path = RESULTS / f"scorecard.{args.profile}.json"
    path.write_text(json.dumps(report, indent=2, sort_keys=True))
    print(f"\nwritten: {path}")

    calibration = report.get("calibration")
    if calibration and not calibration.get("trustworthy", True):
        print(
            "\n!!! judge calibration failed "
            f"(ceiling {calibration['ceiling']:.2f}, floor {calibration['floor']:.2f}). "
            "Treat the summary scores as unreliable.",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
