"""Summaries: quality, action items, meeting name, and who was in the room.

Four sub-scores, averaged. They are averaged over *what a corpus can support*
rather than over all four always: QMSum ships a whole-meeting abstract and no
action-item annotation, and ICSI's summaries have no actions section in any of
its 61 files. Scoring those as zero would say the models failed at something
nobody asked them, so an unsupported sub-score is absent and the mean is taken
over the rest. Every table that reports an average also reports what went into
it.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from rouge_score import rouge_scorer

from common import MANIFESTS

from . import judge as judging

_rouge = rouge_scorer.RougeScorer(["rougeL"], use_stemmer=True)

#: Equal weights. A weighting would be a claim about which of these matters
#: most to a user, and that is the user's call, not ours — the sub-scores are
#: all reported separately so anyone can weight them differently.
SUBSCORES = ("summaryQuality", "actionItems", "meetingName", "speakerMapping")


def score(items: list[dict], results: dict[str, dict], judge: judging.Judge, model: str) -> dict:
    per_item = []
    walls: list[float] = []
    failures = 0
    wall_total = 0.0
    chars_total = 0
    parse_failures = 0

    for item in items:
        result = results.get(item["id"])
        if result is None:
            continue
        if result.get("error"):
            failures += 1
            continue

        payload = result.get("summary") or {}
        gold = item.get("gold") or {}

        # `Summarizer.parse` never throws: when a model returns prose instead of
        # JSON it hands back the raw response under the title "Meeting". That is
        # right for the app and invisible here unless we look for it, so it is
        # counted — a model that cannot hold the format is failing at the task
        # even if its prose is lovely.
        if payload.get("title") == "Meeting" and not payload.get("keyPoints"):
            parse_failures += 1

        scores = {
            "summaryQuality": _quality(judge, model, item, gold, payload),
            "actionItems": _actions(judge, model, item, gold, payload),
            "meetingName": _title(judge, model, item, gold, payload),
            "speakerMapping": _speakers(judge, model, item, gold, payload),
        }
        available = {k: v for k, v in scores.items() if v is not None}
        per_item.append({
            "id": item["id"],
            **scores,
            "overall": sum(available.values()) / len(available) if available else None,
            "rougeL": _rouge_l(gold.get("summary", ""), payload.get("summary", "")),
        })

        wall = result.get("wallSeconds") or 0.0
        walls.append(wall)
        wall_total += wall
        chars_total += result.get("inputChars") or 0

    if not per_item:
        return {"n": 0, "failures": failures}

    summary = {
        "n": len(per_item),
        "failures": failures,
        "parseFailures": parse_failures,
        "wallSeconds": wall_total,
        "inputChars": chars_total,
        "medianWallSeconds": _median(walls),
        "charsPerSecond": (chars_total / wall_total) if wall_total else None,
        "items": per_item,
    }
    for field in (*SUBSCORES, "overall", "rougeL"):
        values = [p[field] for p in per_item if p.get(field) is not None]
        summary[field] = (sum(values) / len(values)) if values else None
    summary["score"] = summary["overall"]
    return summary


# --------------------------------------------------------------- sub-scores


def _quality(judge, model, item, gold, payload) -> float | None:
    reference = (gold.get("summary") or "").strip()
    candidate = (payload.get("summary") or "").strip()
    if not reference:
        return None
    if not candidate:
        return 0.0

    verdict = judge.ask(
        f"quality|{model}|{item['id']}",
        judging.summary_prompt(reference, candidate),
        judging.SUMMARY_SCHEMA,
    )
    if not verdict:
        return None

    parts = [
        _clamp(verdict.get("coverage")),
        _clamp(verdict.get("faithfulness")),
        _clamp(verdict.get("concision")),
    ]
    return sum(parts) / len(parts)


def _actions(judge, model, item, gold, payload) -> float | None:
    reference = [a for a in (gold.get("actionItems") or []) if a.strip()]
    if not reference:
        # Not "this model found no action items" — this corpus does not say
        # what the action items were, so there is nothing to be right about.
        return None

    candidate = [a for a in (payload.get("actionItems") or []) if a.strip()]
    if not candidate:
        return 0.0

    verdict = judge.ask(
        f"actions|{model}|{item['id']}",
        judging.action_prompt(reference, candidate),
        judging.ACTION_SCHEMA,
    )
    if not verdict:
        return None

    matched = max(0, min(int(verdict.get("matched", 0)), len(reference)))
    spurious = max(0, min(int(verdict.get("spurious", 0)), len(candidate)))

    recall = matched / len(reference)
    precision = (len(candidate) - spurious) / len(candidate)
    if precision + recall == 0:
        return 0.0
    # F1 rather than recall alone: a model that lists twenty guesses will find
    # every real commitment among them, and that is not a useful action list.
    return 2 * precision * recall / (precision + recall)


def _title(judge, model, item, gold, payload) -> float | None:
    reference = (gold.get("summary") or "").strip()
    title = (payload.get("title") or "").strip()
    if not reference:
        return None
    if not title or title.lower() == "meeting":
        return 0.0

    verdict = judge.ask(
        f"title|{model}|{item['id']}",
        judging.title_prompt(reference, gold.get("topics") or [], title),
        judging.TITLE_SCHEMA,
    )
    return _clamp(verdict.get("score")) if verdict else None


def _speakers(judge, model, item, gold, payload) -> float | None:
    truth = gold.get("speakerNames") or {}
    if not truth:
        return None

    guesses = {
        _label(k): (v or "").strip()
        for k, v in (payload.get("speakerNames") or {}).items()
    }
    context = _transcript_text(item)

    correct = 0
    for label, expected in truth.items():
        guess = guesses.get(_label(label), "")

        if expected is None:
            # Nobody said this person's name, so silence is the right answer and
            # is scored as such. Without this, the metric would pay a model for
            # attaching a plausible name to every voice it heard, which is the
            # one behaviour that puts a stranger's name on someone's words.
            correct += 1 if not guess else 0
            continue

        if not guess:
            continue
        if _same(guess, expected):
            correct += 1
        else:
            verdict = judge.ask(
                f"speaker|{model}|{item['id']}|{label}",
                judging.speaker_prompt(context, label, expected, guess),
                judging.SPEAKER_SCHEMA,
            )
            correct += 1 if verdict.get("same") else 0

    return correct / len(truth)


# ---------------------------------------------------------------- utilities


def _label(text: str) -> str:
    return re.sub(r"\s+", " ", (text or "").strip()).lower()


def _same(guess: str, expected: str) -> bool:
    """Cheap agreement, to keep the judge for cases that actually need it."""
    a, b = _label(guess), _label(expected)
    if a == b:
        return True
    # "Lynne" against "Lynne Neagle AM": people use first names out loud.
    first_a, first_b = a.split(), b.split()
    return bool(first_a and first_b and first_a[0] == first_b[0] and len(first_a[0]) > 2)


def _transcript_text(item: dict) -> str:
    path = item.get("transcript")
    if not path:
        return ""
    file = Path(path)
    if not file.is_absolute():
        # Manifest paths are relative to the manifest directory, not to `eval/`.
        file = (MANIFESTS / path).resolve()
    if not file.exists():
        return ""
    payload = json.loads(file.read_text())
    return "\n".join(
        f"{s.get('speakerName', '?')}: {s.get('text', '')}" for s in payload.get("segments", [])
    )


def _rouge_l(reference: str, candidate: str) -> float | None:
    if not reference or not candidate:
        return None
    return _rouge.score(reference, candidate)["rougeL"].fmeasure


def _clamp(value) -> float:
    try:
        return max(0.0, min(1.0, float(value)))
    except (TypeError, ValueError):
        return 0.0


def _median(values):
    if not values:
        return None
    ordered = sorted(values)
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2

def calibrate(by_dataset: dict[str, list[dict]], judge: judging.Judge) -> dict:
    """Establish what 1.0 and 0.0 actually mean before trusting anything between.

    Three anchors, because "unrelated" turns out to have two meanings:

    * **ceiling** — a human summary graded against itself. Must be ~1.0, or the
      judge is not recognising agreement even when it is total.
    * **floor** — graded against a summary of a meeting from a *different
      corpus*. Must be low, or the judge is handing out credit for nothing, and
      every number in the summary table is noise.
    * **boilerplate** — graded against a different meeting from the *same*
      corpus. This one is not a judge check, it is a reading aid. AMI is 140
      recordings of four people designing the same remote control, so a generic
      "the group discussed the design and assigned next steps" genuinely does
      overlap the reference. Whatever this scores is roughly what a model can
      earn by writing plausible nothing, and a model near it has not summarized
      the meeting so much as guessed the genre.

    Only ceiling and floor decide whether the run is trustworthy. Boilerplate is
    reported beside the scores so they can be read against something.
    """
    pool = {
        key: [
            (item["id"], (item.get("gold") or {}).get("summary", "").strip())
            for item in items
        ]
        for key, items in by_dataset.items()
    }
    pool = {k: [(n, t) for n, t in v if t] for k, v in pool.items() if any(t for _, t in v)}
    if not pool:
        return {}

    ceiling, floor, boilerplate = [], [], []
    keys = list(pool)

    for index, key in enumerate(keys):
        entries = pool[key]
        other_key = keys[(index + 1) % len(keys)]

        for name, text in entries[:4]:
            same = judge.ask(
                f"calib-self|{name}", judging.summary_prompt(text, text), judging.SUMMARY_SCHEMA
            )
            if same:
                ceiling.append(_clamp(same.get("coverage")))

            if other_key != key:
                other_name, other = pool[other_key][0]
                cross = judge.ask(
                    f"calib-cross|{name}|{other_name}",
                    judging.summary_prompt(text, other),
                    judging.SUMMARY_SCHEMA,
                )
                if cross:
                    floor.append(_clamp(cross.get("coverage")))

            if len(entries) > 1:
                peer_name, peer = entries[(entries.index((name, text)) + 1) % len(entries)]
                within = judge.ask(
                    f"calib-within|{name}|{peer_name}",
                    judging.summary_prompt(text, peer),
                    judging.SUMMARY_SCHEMA,
                )
                if within:
                    boilerplate.append(_clamp(within.get("coverage")))

    if not ceiling or not floor:
        return {}

    ceiling_mean = sum(ceiling) / len(ceiling)
    floor_mean = sum(floor) / len(floor)
    return {
        "ceiling": ceiling_mean,
        "floor": floor_mean,
        "boilerplate": (sum(boilerplate) / len(boilerplate)) if boilerplate else None,
        "separation": ceiling_mean - floor_mean,
        "trustworthy": ceiling_mean >= 0.85 and floor_mean <= 0.30,
        "n": len(ceiling),
    }
