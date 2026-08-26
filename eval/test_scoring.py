#!/usr/bin/env python3
"""Tests for the scoring rules, which is where a silent bug is most expensive.

    uv run --project eval eval/test_scoring.py

A wrong number here does not look wrong. It looks like a model being good or
bad, gets written into a table and into the app's Settings pane, and nobody has
any reason to doubt it. Each of these covers a rule that was either got wrong
once or would have been easy to.

Deliberately dependency-free — no pytest, just asserts and a runner — so that
checking the harness never involves installing something first.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from common import score_from_error_rate  # noqa: E402
from report import coverage, sorted_models  # noqa: E402
from score import asr as score_asr  # noqa: E402
from score import meeting as score_meeting  # noqa: E402
from score import summary as score_summary  # noqa: E402

CASES = []


def case(fn):
    CASES.append(fn)
    return fn


# ------------------------------------------------------------------- scaling


@case
def error_rates_become_scores():
    assert score_from_error_rate(0.0) == 1.0
    assert score_from_error_rate(0.25) == 0.75
    # Error rates above 1 are real — a model that hallucinates a paragraph over
    # three words of speech scores 4.0 — and everything past total failure is
    # equally useless.
    assert score_from_error_rate(1.0) == 0.0
    assert score_from_error_rate(4.0) == 0.0


# ------------------------------------------------------------------ failures


@case
def a_crash_counts_against_the_model():
    """The one that mattered most.

    An engine here crashed on 176 of 200 clips. Skipping failures scored it 0.97
    on the 24 that survived — the best model in the table — when what a user
    would actually get is nothing at all, seven times out of eight.
    """
    items = [{"id": str(i), "reference": "the quick brown fox"} for i in range(4)]
    results = {
        "0": {"text": "the quick brown fox", "wallSeconds": 1, "audioSeconds": 1},
        "1": {"error": "engine exploded", "wallSeconds": 0},
        "2": {"error": "engine exploded", "wallSeconds": 0},
        "3": {"error": "engine exploded", "wallSeconds": 0},
    }
    scored = score_asr.score(items, results)

    assert scored["failures"] == 3, scored["failures"]
    assert scored["n"] == 4, "failures must stay in the denominator"
    # Three of four transcripts missing entirely: three quarters of the words lost.
    assert abs(scored["wer"] - 0.75) < 1e-9, scored["wer"]
    assert abs(scored["score"] - 0.25) < 1e-9, scored["score"]


@case
def a_perfect_model_scores_one():
    items = [{"id": "a", "reference": "hello there"}]
    results = {"a": {"text": "Hello, there!", "wallSeconds": 1, "audioSeconds": 2}}
    scored = score_asr.score(items, results)
    # Normalization is doing the work: casing and punctuation are not errors in
    # text about to be typed into somebody's email.
    assert scored["score"] == 1.0, scored
    assert scored["rtfx"] == 2.0


@case
def an_empty_reference_is_skipped_not_scored():
    items = [{"id": "a", "reference": ""}, {"id": "b", "reference": "real words here"}]
    results = {
        "a": {"text": "anything", "wallSeconds": 1, "audioSeconds": 1},
        "b": {"text": "real words here", "wallSeconds": 1, "audioSeconds": 1},
    }
    # Word error rate divides by the reference length, so an empty reference has
    # no answer rather than a bad one.
    assert score_asr.score(items, results)["n"] == 1


# ------------------------------------------------------------------ meetings


def _meeting_items():
    return [{"id": "m", "refSegments": [
        {"start": 0, "end": 2, "speaker": "A", "text": "hello there friend"},
        {"start": 2.5, "end": 4, "speaker": "B", "text": "good to see you"},
        {"start": 4.5, "end": 6, "speaker": "A", "text": "shall we begin"},
    ]}]


def _result(segments, turns=None):
    return {"m": {
        "id": "m", "segments": segments, "speakerTurns": turns,
        "audioSeconds": 6, "wallSeconds": 1,
    }}


@case
def the_three_columns_separate_the_two_failures():
    items = _meeting_items()
    perfect = [
        {"start": 0, "end": 2, "speaker": "s0", "text": "hello there friend"},
        {"start": 2.5, "end": 4, "speaker": "s1", "text": "good to see you"},
        {"start": 4.5, "end": 6, "speaker": "s0", "text": "shall we begin"},
    ]
    assert score_meeting.score(items, _result(perfect))["score"] == 1.0

    # Right words, every one attributed to the same person. The words column
    # must stay perfect and the headline must not.
    collapsed = [dict(s, speaker="s0") for s in perfect]
    scored = score_meeting.score(items, _result(collapsed))
    assert scored["wordScore"] == 1.0, scored["wordScore"]
    assert scored["score"] < 0.5, scored["score"]

    # Right speakers, garbled words: the mirror image.
    garbled = [dict(s, text="xxx yyy zzz") for s in perfect]
    scored = score_meeting.score(items, _result(garbled))
    assert scored["wordScore"] == 0.0, scored["wordScore"]
    assert scored["speakerScore"] == 1.0, scored["speakerScore"]


@case
def diarizer_and_delivered_are_scored_separately():
    """The gap between them is the cost of assembly, so they cannot be one number."""
    items = _meeting_items()
    perfect_turns = [
        {"start": 0, "end": 2, "speaker": "s0"},
        {"start": 2.5, "end": 4, "speaker": "s1"},
        {"start": 4.5, "end": 6, "speaker": "s0"},
    ]
    # A diarizer that was right, and an assembly step that put every segment on
    # one speaker anyway.
    collapsed = [
        {"start": 0, "end": 2, "speaker": "s0", "text": "hello there friend"},
        {"start": 2.5, "end": 4, "speaker": "s0", "text": "good to see you"},
        {"start": 4.5, "end": 6, "speaker": "s0", "text": "shall we begin"},
    ]
    scored = score_meeting.score(items, _result(collapsed, perfect_turns))
    assert scored["diarizerScore"] == 1.0, scored["diarizerScore"]
    assert scored["speakerScore"] < 1.0, scored["speakerScore"]


@case
def a_failed_meeting_is_scored_as_an_empty_transcript():
    items = _meeting_items()
    scored = score_meeting.score(items, {"m": {"id": "m", "error": "boom"}})
    assert scored["failures"] == 1
    assert scored["score"] == 0.0, scored["score"]


# ------------------------------------------------------------- speaker names


class _NoJudge:
    """Refuses every equivalence, so only the exact-match path is exercised."""

    def ask(self, key, prompt, schema):
        return {"same": False}


@case
def naming_a_speaker_nobody_named_is_wrong():
    """Silence is the correct answer when a name is never spoken.

    Without this the metric pays a model for attaching a plausible name to every
    voice it heard, which is the single behaviour we most need it not to have:
    it puts a stranger's name on someone's words.
    """
    gold = {"speakerNames": {"Speaker 1": "Sarah", "Speaker 2": None}}
    item = {"id": "x", "gold": gold}

    # Right name, and correctly silent about the speaker nobody named.
    got = score_summary._speakers(
        _NoJudge(), "m", item, gold, {"speakerNames": {"Speaker 1": "Sarah"}}
    )
    assert got == 1.0, got

    # Same correct name, plus a guess where it should have stayed quiet.
    got = score_summary._speakers(
        _NoJudge(), "m", item, gold,
        {"speakerNames": {"Speaker 1": "Sarah", "Speaker 2": "Dan"}},
    )
    assert got == 0.5, got

    # Saying nothing at all still earns credit for the unnameable speaker.
    assert score_summary._speakers(_NoJudge(), "m", item, gold, {"speakerNames": {}}) == 0.5


@case
def first_names_match_full_names():
    gold = {"speakerNames": {"Speaker 1": "Lynne Neagle AM"}}
    item = {"id": "x", "gold": gold}
    # People say "Lynne", not "Lynne Neagle AM".
    got = score_summary._speakers(
        _NoJudge(), "m", item, gold, {"speakerNames": {"Speaker 1": "Lynne"}}
    )
    assert got == 1.0, got


@case
def a_corpus_without_names_sits_the_subscore_out():
    item = {"id": "x", "gold": {"speakerNames": {}}}
    # ICSI publishes no speaker names. Scoring that zero would say the models
    # failed at something nobody asked them.
    assert score_summary._speakers(_NoJudge(), "m", item, item["gold"], {}) is None


@case
def action_items_are_absent_not_zero_when_unannotated():
    item = {"id": "x", "gold": {"actionItems": []}}
    assert score_summary._actions(_NoJudge(), "m", item, item["gold"], {"actionItems": ["x"]}) is None


# ----------------------------------------------------------------- reporting


@case
def a_partial_row_never_outranks_a_complete_one():
    """Mid-run, a model that has only done the easy corpus has the best average."""
    track = {
        "thorough": {"score": 0.90, "datasets": {"a": {}, "b": {}, "c": {}}},
        "barely-started": {"score": 0.99, "datasets": {"a": {}}},
    }
    order = [name for name, _ in sorted_models(track)]
    assert order == ["thorough", "barely-started"], order
    assert coverage(track["barely-started"], 3) == " ⚠"
    assert coverage(track["thorough"], 3) == ""


def main() -> int:
    failed = 0
    for fn in CASES:
        try:
            fn()
            print(f"  ok   {fn.__name__}")
        except AssertionError as error:
            failed += 1
            print(f"  FAIL {fn.__name__}: {error}")
    print(f"\n{len(CASES) - failed}/{len(CASES)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
