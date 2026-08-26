"""Shared vocabulary: where things live, what a manifest is, which models run.

The registry below is the single place that knows what the suite consists of.
Adding a dataset means adding a `Dataset` here and a `prepare` module; nothing
in the runner, the scorers or the report is aware of any corpus by name.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent

DATA = ROOT / "datasets"  # gitignored: audio, and a lot of it
MANIFESTS = ROOT / "manifests"  # committed: small, and pins exactly what ran
RESULTS = ROOT / "results"  # committed: the numbers themselves
RAW = RESULTS / "raw"  # per-item model output, the resume cache

FWEVAL = REPO / ".build" / "release" / "fweval"

# Three jobs the app does, which are three different questions.
ASR = "asr"  # dictation: one voice, short, how accurate
MEETING = "meeting"  # meetings: many voices, who said what
SUMMARIZE = "summarize"  # summaries: title, action items, who was there


@dataclass(frozen=True)
class Dataset:
    key: str
    track: str
    title: str
    #: What makes it different from the other two in its track. This ends up in
    #: the report, because an average over three corpora is only meaningful if
    #: the reader can see what was averaged.
    role: str
    license: str
    source: str
    #: Items to take per profile. Sized so `fast` is roughly 30 minutes of audio
    #: per speech dataset.
    limits: dict[str, int] = field(default_factory=dict)

    def limit(self, profile: str) -> int:
        return self.limits.get(profile, self.limits["fast"])


DATASETS: dict[str, Dataset] = {
    d.key: d
    for d in [
        # ---- Track V: dictation ------------------------------------------
        Dataset(
            key="librispeech",
            track=ASR,
            title="LibriSpeech (Argmax 200)",
            role="Clean read speech — the ceiling. If a model is bad here it is bad everywhere.",
            license="MIT",
            source="argmaxinc/librispeech-200",
            limits={"smoke": 5, "fast": 200, "full": 200},
        ),
        Dataset(
            key="earnings22",
            track=ASR,
            title="Earnings-22",
            role="Speakers from 27 countries — the accent probe, and full of proper nouns.",
            license="CC BY-SA 4.0",
            source="distil-whisper/earnings22",
            limits={"smoke": 5, "fast": 250, "full": 800},
        ),
        Dataset(
            key="ami-ihm",
            track=ASR,
            title="AMI headset, utterances",
            role="Short spontaneous speech, ~4s a turn — the register of actually holding the hotkey.",
            license="CC BY 4.0",
            source="edinburghcstr/ami",
            limits={"smoke": 5, "fast": 400, "full": 1200},
        ),
        # ---- Track T: meetings -------------------------------------------
        Dataset(
            key="ami",
            track=MEETING,
            title="AMI meetings",
            role="Scenario meetings, non-native English. Has published DER baselines to check ourselves against.",
            license="CC BY 4.0",
            source="groups.inf.ed.ac.uk/ami",
            limits={"smoke": 1, "fast": 2, "full": 16},
        ),
        Dataset(
            key="notsofar",
            track=MEETING,
            title="NOTSOFAR-1",
            role="Real conference rooms, far-field mic — the closest public corpus to what this app records.",
            license="CC BY 4.0",
            source="microsoft/NOTSOFAR",
            limits={"smoke": 1, "fast": 5, "full": 20},
        ),
        # Was CHiME-6. Its HuggingFace mirror ships word-level text and
        # utterance-level times as two lists that cannot be joined: the words are
        # not in time order, because people talk over each other all evening, so
        # nothing positional lines them up. Reconstructing it needs the original
        # OpenSLR annotation. Left as a broken reference it scored every model at
        # exactly zero and looked like a result, which is the worst way for a
        # dataset to fail.
        #
        # The far-field AMI array replaces it, and earns the slot on its own: it
        # is the same two meetings as the row above at a microphone across the
        # room instead of on the speakers' heads. Everything else held constant,
        # so the difference between the two rows is the cost of mic distance —
        # which is the question a user picking a model for a laptop on a
        # conference table actually has.
        Dataset(
            key="ami-sdm",
            track=MEETING,
            title="AMI, far-field array",
            role="The same meetings as above, recorded across the room. Isolates what mic distance costs.",
            license="CC BY 4.0",
            source="groups.inf.ed.ac.uk/ami (Array1-01)",
            limits={"smoke": 1, "fast": 2, "full": 16},
        ),
        # ---- Track S: summaries ------------------------------------------
        Dataset(
            key="ami-summ",
            track=SUMMARIZE,
            title="AMI abstractive summaries",
            role="Human abstracts with separate action-item and decision fields — the only corpus shaped like our output.",
            license="CC BY 4.0",
            source="ami_public_manual_1.6.2",
            # Weighted heavier than the other two summary corpora on purpose:
            # AMI is the only one anywhere with *typed* action-item annotation.
            # QMSum ships a whole-meeting abstract and nothing else; ICSI's
            # summaries have abstract, decisions and problems but no actions
            # section at all — verified across all 61 of its files. So the
            # action-item column rests entirely on this corpus, and it should
            # rest on more than a handful of meetings.
            limits={"smoke": 1, "fast": 10, "full": 20},
        ),
        Dataset(
            key="qmsum",
            track=SUMMARIZE,
            title="QMSum",
            role="AMI, ICSI and parliamentary committees. Real names in the committee half, so speaker naming is scorable.",
            license="MIT",
            source="Yale-LILY/QMSum",
            limits={"smoke": 1, "fast": 5, "full": 35},
        ),
        Dataset(
            key="icsi",
            track=SUMMARIZE,
            title="ICSI meetings",
            role="Real research-group meetings rather than a scripted scenario, and five to eight people instead of four.",
            license="CC BY 4.0",
            source="ICSI_plus_NXT",
            limits={"smoke": 1, "fast": 5, "full": 20},
        ),
    ]
}


def datasets_for(track: str) -> list[Dataset]:
    return [d for d in DATASETS.values() if d.track == track]


# Models. Ids match ModelCatalog exactly; a mismatch here silently produces an
# empty column, so `run.py --check` verifies them against `fwctl models`.
SPEECH_MODELS = [
    "whisper-large-v3-turbo",
    "parakeet-v3",
    "whisper-large-v3",
    "distil-whisper-large-v3",
    "parakeet-110m",
]

SUMMARY_MODELS = [
    "mlx-community/Qwen3-4B-Instruct-2507-4bit",
    "mlx-community/Llama-3.2-3B-Instruct-4bit",
    "mlx-community/Qwen3-1.7B-4bit",
]


# ---------------------------------------------------------------- manifests


def manifest_path(key: str, profile: str) -> Path:
    return MANIFESTS / f"{key}.{profile}.json"


def write_manifest(key: str, profile: str, items: list[dict]) -> Path:
    """Write a manifest with paths relative to the manifest file itself.

    Relative to the manifest rather than to `eval/`, because the manifest is the
    only thing the Swift runner is handed and so is the only base it can resolve
    against. That yields `../datasets/...`, which looks odd in the file and is
    the one form that is unambiguous from both sides.
    """
    dataset = DATASETS[key]
    path = manifest_path(key, profile)
    path.parent.mkdir(parents=True, exist_ok=True)

    for item in items:
        for field_name in ("audio", "transcript"):
            value = item.get(field_name)
            if value:
                item[field_name] = os.path.relpath(Path(value).resolve(), MANIFESTS)

    payload = {
        "dataset": key,
        "track": dataset.track,
        "profile": profile,
        "items": items,
    }
    path.write_text(json.dumps(payload, indent=2, sort_keys=True))
    return path


def load_manifest(key: str, profile: str) -> dict:
    return json.loads(manifest_path(key, profile).read_text())


def results_dir(track: str, key: str, model: str) -> Path:
    """Per-item output for one (dataset, model) pair — also the resume cache."""
    return RAW / track / key / model.replace("/", "__")


def load_results(track: str, key: str, model: str) -> dict[str, dict]:
    directory = results_dir(track, key, model)
    if not directory.is_dir():
        return {}
    out = {}
    for path in sorted(directory.glob("*.json")):
        if path.name == "_run.json":
            continue
        payload = json.loads(path.read_text())
        out[payload["id"]] = payload
    return out


def load_run(track: str, key: str, model: str) -> dict | None:
    path = results_dir(track, key, model) / "_run.json"
    return json.loads(path.read_text()) if path.exists() else None


# ---------------------------------------------------------------- utilities


def host_description() -> str:
    def sysctl(name: str) -> str:
        return subprocess.run(
            ["sysctl", "-n", name], capture_output=True, text=True, check=False
        ).stdout.strip()

    memory = int(sysctl("hw.memsize") or 0) // 1_073_741_824
    version = subprocess.run(
        ["sw_vers", "-productVersion"], capture_output=True, text=True, check=False
    ).stdout.strip()
    return f"{sysctl('machdep.cpu.brand_string')}, {memory} GB, macOS {version}"


def score_from_error_rate(rate: float) -> float:
    """Turn an error rate into the 0-1 score the table reports.

    Clamped at zero because error rates above 1 are real — a model that
    hallucinates a paragraph over three words of speech scores 4.0 — and a
    negative entry in a column captioned "0 to 1" is just confusing. Everything
    at or beyond total failure is equally useless.
    """
    return max(0.0, min(1.0, 1.0 - rate))
