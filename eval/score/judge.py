"""Gemini Flash as the judge, with anchors that say when to disbelieve it.

Summary quality is the one thing in this suite with no arithmetic answer. ROUGE
counts shared n-grams, which rewards a summary for reusing the reference's
wording rather than for being right; two summaries can say the same thing and
score far apart. A model reading both and answering a rubric is closer to what a
person would say, and is the standard the field has settled on.

The obvious objection is that the judge might be wrong or drift between runs, at
which point the whole table is decoration. Three things here answer that:

  * every rubric call is made three times and the median is taken, so one odd
    sample cannot move a score;
  * `calibrate()` scores the reference against itself and against a different
    meeting's reference. Those must come out near 1 and near 0. If they do not,
    the judge is not measuring what it claims to and the run is void; and
  * the judge is given the reference and asked to compare, never asked to have
    an opinion about quality in the abstract.
"""

from __future__ import annotations

import json
import os
import statistics
import time
from pathlib import Path

from dotenv import dotenv_values
from google import genai
from google.genai import types

MODEL = "gemini-flash-latest"
SAMPLES = 3

#: Fallback for the key when it is not already in the environment. Gitignored,
#: and outside the repo entirely if `FREEWHISPER_EVAL_ENV` points elsewhere.
ENV_FILE = Path(
    os.environ.get("FREEWHISPER_EVAL_ENV") or Path(__file__).resolve().parents[1] / ".env"
)


def api_key() -> str:
    key = os.environ.get("GEMINI_API_KEY")
    if key:
        return key
    if ENV_FILE.exists():
        key = dotenv_values(ENV_FILE).get("GEMINI_API_KEY")
        if key:
            return key
    raise RuntimeError(
        f"No GEMINI_API_KEY in the environment or in {ENV_FILE}. "
        "The summary track cannot be scored without a judge."
    )


class Judge:
    def __init__(self, model: str = MODEL, samples: int = SAMPLES, cache: Path | None = None):
        self.client = genai.Client(api_key=api_key())
        self.model = model
        self.samples = samples
        # Judging is the only part of this harness that costs money per call, so
        # it is also the only part with its own cache. Re-running the report
        # after a change to the arithmetic must not re-buy every verdict.
        self.cache_path = cache
        self.cache: dict[str, dict] = {}
        if cache and cache.exists():
            self.cache = json.loads(cache.read_text())

    # ------------------------------------------------------------------ core

    def ask(self, key: str, prompt: str, schema: dict) -> dict:
        if key in self.cache:
            return self.cache[key]

        samples = [self._once(prompt, schema) for _ in range(self.samples)]
        samples = [s for s in samples if s]
        if not samples:
            return {}

        merged: dict = {}
        for field, value in samples[0].items():
            values = [s.get(field) for s in samples if isinstance(s.get(field), (int, float))]
            # Numbers get the median across samples; anything else is taken from
            # the first, since averaging prose is not a thing.
            merged[field] = statistics.median(values) if len(values) == len(samples) else value

        self.cache[key] = merged
        self._flush()
        return merged

    def _once(self, prompt: str, schema: dict) -> dict | None:
        for attempt in range(4):
            try:
                response = self.client.models.generate_content(
                    model=self.model,
                    contents=prompt,
                    config=types.GenerateContentConfig(
                        temperature=0.0,
                        response_mime_type="application/json",
                        response_schema=schema,
                    ),
                )
                return json.loads(response.text)
            except Exception:
                # Rate limits and transient 5xxs are normal at this volume;
                # a judge that gives up on the first one loses the whole run.
                if attempt == 3:
                    return None
                time.sleep(2 ** attempt)
        return None

    def _flush(self) -> None:
        if self.cache_path:
            self.cache_path.parent.mkdir(parents=True, exist_ok=True)
            self.cache_path.write_text(json.dumps(self.cache, indent=1, sort_keys=True))


# --------------------------------------------------------------- the rubrics

SUMMARY_SCHEMA = {
    "type": "object",
    "properties": {
        "coverage": {"type": "number"},
        "faithfulness": {"type": "number"},
        "concision": {"type": "number"},
        "note": {"type": "string"},
    },
    "required": ["coverage", "faithfulness", "concision"],
}


def summary_prompt(reference: str, candidate: str) -> str:
    return f"""You are grading an automatically generated meeting summary against a summary written by a person who attended the meeting.

REFERENCE (written by a human attendee):
{reference}

CANDIDATE (generated):
{candidate}

Score three things, each from 0.0 to 1.0:

"coverage" — how much of what the reference says the candidate also says. 1.0 means every substantive point is there. 0.0 means it shares nothing with the reference. Judge on meaning, not wording: different phrasing for the same point is full credit.

"faithfulness" — whether everything the candidate asserts is supported by the reference. 1.0 means nothing is invented. Deduct hard for confident specifics the reference does not support — a made-up name, number, or decision — because a summary a reader cannot trust is worse than a thin one. Deduct nothing for leaving things out; that is coverage's job.

"concision" — whether it reads as a summary. 1.0 is a tight paragraph. Deduct for padding, for restating the instructions it was given, and for transcript fragments pasted in verbatim.

Return JSON only.
"""


ACTION_SCHEMA = {
    "type": "object",
    "properties": {
        "matched": {"type": "integer"},
        "spurious": {"type": "integer"},
        "note": {"type": "string"},
    },
    "required": ["matched", "spurious"],
}


def action_prompt(reference: list[str], candidate: list[str]) -> str:
    gold = "\n".join(f"- {item}" for item in reference) or "(none)"
    proposed = "\n".join(f"- {item}" for item in candidate) or "(none)"
    return f"""Two lists of action items from the same meeting. The first was written by a human attendee and is correct.

HUMAN:
{gold}

GENERATED:
{proposed}

Match them on meaning, not wording. "Dan will backfill the table by Thursday" and "Backfill: Dan, Thu" are the same item. One generated item may only match one human item.

"matched" — how many of the {len(reference)} human items have a match in the generated list.
"spurious" — how many generated items are not commitments anyone in the human list made. Count a restatement of a topic or decision as spurious: an action item is something a person agreed to do.

Return JSON only, integers.
"""


TITLE_SCHEMA = {
    "type": "object",
    "properties": {"score": {"type": "number"}, "note": {"type": "string"}},
    "required": ["score"],
}


def title_prompt(reference: str, topics: list[str], title: str) -> str:
    hint = f"\nTopics covered: {', '.join(t for t in topics if t)}" if any(topics) else ""
    return f"""Judge a generated title for a meeting.

WHAT THE MEETING WAS ABOUT:
{reference}{hint}

GENERATED TITLE: {title!r}

Score 0.0 to 1.0 on whether someone scrolling a list of meetings would know which one this was.

1.0 — specific and accurate; names the actual subject.
0.5 — accurate but generic; "Weekly Sync", "Project Discussion". True of a hundred meetings.
0.0 — wrong, empty, or not a title: a whole sentence, a fragment of transcript, or the word "Meeting".

Being under eight words is expected; do not reward brevity beyond that, and do not punish a title for lacking detail the meeting itself did not have.

Return JSON only.
"""


SPEAKER_SCHEMA = {
    "type": "object",
    "properties": {"same": {"type": "boolean"}, "note": {"type": "string"}},
    "required": ["same"],
}


def speaker_prompt(context: str, label: str, truth: str, guess: str) -> str:
    return f"""In a meeting transcript, the speaker shown as {label!r} is in fact: {truth!r}.

A model proposed that {label!r} is: {guess!r}.

Do those refer to the same person? Answer true if they are the same person under a different description — a first name against a full name, "PM" against "Project Manager", a role against the name of the person filling it according to the transcript below.

Answer false if they are different people, or if the proposal is a placeholder like "Unknown" or "Participant".

TRANSCRIPT OPENING (for working out who holds which role):
{context[:3000]}

Return JSON only.
"""
