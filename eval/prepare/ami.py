"""The AMI Meeting Corpus — three of the nine datasets come from here.

AMI is scenario meetings: four people, mostly non-native European English,
designing a remote control. It earns its place three times over because it is
the only corpus that is simultaneously

  * audio with reference speaker turns (track T),
  * short spontaneous utterances at close mic (track V), and
  * human abstracts with *separate action-item and decision fields* (track S),

which is to say it is the only public corpus shaped like this app's output. It
is also the one with published diarization baselines, which is what lets us
check the harness itself rather than only the models.

Everything here is built from two downloads — the 22 MB annotation zip and the
meeting audio — rather than from a HuggingFace mirror. The mirrors of AMI live
inside multi-terabyte monorepos whose metadata alone takes minutes to resolve,
which is the wrong trade for a suite meant to be re-runnable in an afternoon.

The join between the three files is worth stating once, because nothing names
it: `meetings.xml` describes each speaker by *agent* (A-D) and by *global_name*
(MEO015); the word and segment XML are filed under the agent; the reference
RTTM labels turns with the global name.
"""

from __future__ import annotations

import re
import zipfile
from dataclasses import dataclass
from pathlib import Path

import requests

from . import nxt
from .audio import to_wav

ANNOTATIONS_URL = "https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip"
AUDIO_URL = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/{mid}/audio/{mid}.{channel}.wav"
RTTM_URL = (
    "https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/test/{mid}.rttm"
)

#: The standard AMI diarization test split. Ordered so that the first two are
#: the pair the fast profile uses — both are opening meetings, which is where
#: participants introduce themselves and so where speaker naming is winnable.
TEST_MEETINGS = [
    "IS1009a", "ES2004a", "TS3003a", "EN2002a",
    "IS1009b", "ES2004b", "TS3003b", "EN2002b",
    "IS1009c", "ES2004c", "TS3003c", "EN2002c",
    "IS1009d", "ES2004d", "TS3003d", "EN2002d",
]

#: `meetings.xml` records the scenario role as an abbreviation. Expanded here to
#: the phrase people actually say out loud, because that is what a model could
#: plausibly recover and therefore what it is fair to score it against.
ROLES = {
    "PM": "Project Manager",
    "ID": "Industrial Designer",
    "UI": "User Interface Designer",
    "ME": "Marketing Expert",
}


@dataclass
class Speaker:
    agent: str
    global_name: str
    role: str

    @property
    def label(self) -> str:
        return ROLES.get(self.role, self.role)


# ----------------------------------------------------------------- fetching


def _cache(out: Path) -> Path:
    return out.parent / "_cache"


def annotations(out: Path) -> Path:
    """Download and unpack the annotation zip once."""
    cache = _cache(out)
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "ami_manual.zip"
    extracted = cache / "ami"

    if not archive.exists():
        response = requests.get(ANNOTATIONS_URL, timeout=300)
        response.raise_for_status()
        archive.write_bytes(response.content)

    # A marker written last, rather than testing for some file the archive
    # happens to contain. An interrupted unzip leaves a tree that looks
    # plausible and is missing three of every four speakers, and the resulting
    # reference is quietly a quarter of the meeting rather than an error.
    marker = extracted / ".extracted"
    if not marker.exists():
        with zipfile.ZipFile(archive) as zf:
            zf.extractall(extracted)
        marker.write_text(ANNOTATIONS_URL)
    return extracted


def audio(out: Path, mid: str, channel: str = "Mix-Headset") -> Path:
    """Fetch one meeting's audio, converted to the pipeline's 16 kHz mono."""
    cache = _cache(out)
    raw = cache / "audio" / f"{mid}.{channel}.wav"
    if not raw.exists():
        raw.parent.mkdir(parents=True, exist_ok=True)
        with requests.get(AUDIO_URL.format(mid=mid, channel=channel), stream=True, timeout=600) as response:
            response.raise_for_status()
            with raw.open("wb") as handle:
                for chunk in response.iter_content(1 << 20):
                    handle.write(chunk)
    return to_wav(raw, out / f"{mid}.{channel}.wav")


# ------------------------------------------------------------------ parsing


def speakers(root: Path, mid: str) -> dict[str, Speaker]:
    text = (root / "corpusResources" / "meetings.xml").read_text(encoding="latin-1")
    block = re.search(rf'<meeting[^>]*observation="{mid}".*?</meeting>', text, re.S)
    if not block:
        return {}
    found = {}
    for match in re.finditer(r"<speaker\b[^>]*/>", block.group(0)):
        tag = match.group(0)
        agent = re.search(r'nxt_agent="([^"]+)"', tag)
        name = re.search(r'global_name="([^"]+)"', tag)
        role = re.search(r'role="([^"]+)"', tag)
        if agent and name and role:
            found[agent.group(1)] = Speaker(agent.group(1), name.group(1), role.group(1))
    return found


def reference_segments(root: Path, mid: str) -> list[dict]:
    """Every speaker's utterances on one timeline, for tcpWER and DER."""
    segments = []
    for agent, speaker in speakers(root, mid).items():
        for start, end, text in nxt.utterances(root, nxt.AMI, mid, agent):
            segments.append({
                "start": start,
                "end": end,
                "speaker": speaker.global_name,
                "text": text,
            })
    segments.sort(key=lambda s: s["start"])
    return segments


def rttm(out: Path, mid: str) -> str:
    """The reference RTTM the published DER baselines are measured against.

    Taken from pyannote's AMI setup rather than derived from the word timings,
    precisely so that our diarization numbers can be compared against theirs. A
    locally-derived RTTM would differ in collar and overlap handling in ways
    that are invisible until the comparison silently stops meaning anything.
    """
    cache = _cache(out) / "rttm"
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / f"{mid}.rttm"
    if not path.exists():
        response = requests.get(RTTM_URL.format(mid=mid), timeout=120)
        response.raise_for_status()
        path.write_text(response.text)
    return path.read_text()


def summary(root: Path, mid: str) -> dict | None:
    return nxt.summary(root, nxt.AMI, mid)


def utterances(root: Path, mid: str, agent: str) -> list[tuple[float, float, str]]:
    return nxt.utterances(root, nxt.AMI, mid, agent)


def speaker_truth(root: Path, mid: str, transcript: str) -> dict[str, str | None]:
    """Gold speaker labels for the naming sub-score, keyed by anonymized label.

    AMI's `global_name` is itself an anonymization ("MEO015"), so the scenario
    *role* is the ground truth here — and it is a fair target, because in these
    meetings people address each other by role constantly ("so as Project
    Manager I…"). Where a role is never spoken, the truth is None and the model
    is expected to stay quiet rather than invent something.
    """
    spoken = transcript.lower()
    truth: dict[str, str | None] = {}
    for order, (_, speaker) in enumerate(sorted(speakers(root, mid).items())):
        label = f"Speaker {order + 1}"
        role = speaker.label
        # "Project Manager" is unlikely to be said in full every time; the head
        # noun carries it, so match on that.
        head = role.split()[-1].lower()
        truth[label] = role if head in spoken else None
    return truth
