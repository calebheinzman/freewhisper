"""Parsing for the NXT format, which AMI and ICSI both ship in.

The two corpora were annotated by the same group in the same schema and differ
only in where the files sit and what the segment files are called. Everything
that actually reads XML lives here so that neither corpus module has to repeat
it, and so that a fix to the word-range resolution — which is the fiddly part —
lands for both at once.
"""

from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

NITE_ID = "{http://nite.sourceforge.net/}id"


@dataclass
class Word:
    start: float
    end: float
    text: str


@dataclass(frozen=True)
class Layout:
    """Where one corpus keeps its files."""

    words: str
    segments: str
    segments_suffix: str
    abstractive: str


AMI = Layout(
    words="words",
    segments="segments",
    segments_suffix="segments",
    abstractive="abstractive",
)

ICSI = Layout(
    words="ICSIplus/Words",
    segments="ICSIplus/Segments",
    segments_suffix="segs",
    abstractive="ICSIplus/Contributions/Summarization/abstractive",
)


def agents(root: Path, layout: Layout, mid: str) -> list[str]:
    """Which speaker slots this meeting actually used. ICSI runs to 'E' and beyond."""
    found = set()
    for path in (root / layout.words).glob(f"{mid}.*.words.xml"):
        parts = path.name.split(".")
        if len(parts) >= 3:
            found.add(parts[1])
    return sorted(found)


def words(root: Path, layout: Layout, mid: str, agent: str) -> tuple[list[str], dict[str, Word]]:
    """Word-level reference, as (document order, scorable words).

    Two structures rather than one because the segments file addresses words by
    *range* — "words0 through words3" — and either endpoint of such a range can
    be something we do not want to score. Punctuation is its own element here,
    and so are the `<vocalsound>` / `<disfmarker>` / `<gap>` annotations that
    record laughter and hesitation. Filtering those out of the index as well as
    out of the text loses every span that happens to end on one, which on these
    corpora is very nearly all of them.

    So: `order` holds every element and is what ranges resolve against;
    `lexicon` holds only the words a model could reasonably be expected to say
    back, and is what the text is built from.
    """
    path = root / layout.words / f"{mid}.{agent}.words.xml"
    if not path.exists():
        return [], {}

    order: list[str] = []
    lexicon: dict[str, Word] = {}

    for element in ET.parse(path).getroot():
        wid = element.get(NITE_ID)
        if not wid:
            continue
        order.append(wid)

        if not element.tag.endswith("w") or element.get("punc") == "true":
            continue
        start, end, text = element.get("starttime"), element.get("endtime"), (element.text or "").strip()
        if not (start and end and text):
            continue
        lexicon[wid] = Word(float(start), float(end), text)

    return order, lexicon


_CHILD = re.compile(r"#id\(([^)]+)\)(?:\.\.id\(([^)]+)\))?")


def utterances(root: Path, layout: Layout, mid: str, agent: str) -> list[tuple[float, float, str]]:
    """The corpus's own utterance segmentation, resolved to text.

    Using its boundaries rather than inventing our own from pauses: they are
    what every published number on these corpora is measured against, so a WER
    here is comparable to the literature instead of to nothing.
    """
    path = root / layout.segments / f"{mid}.{agent}.{layout.segments_suffix}.xml"
    if not path.exists():
        return []

    order, lexicon = words(root, layout, mid, agent)
    index = {wid: position for position, wid in enumerate(order)}

    result = []
    for segment in ET.parse(path).getroot():
        spans: list[str] = []
        for child in segment:
            match = _CHILD.search(child.get("href") or "")
            if not match:
                continue
            first, last = match.group(1), match.group(2) or match.group(1)
            if first not in index or last not in index:
                continue
            spans += order[index[first]: index[last] + 1]

        picked = [lexicon[wid] for wid in spans if wid in lexicon]
        if not picked:
            continue
        result.append((
            min(w.start for w in picked),
            max(w.end for w in picked),
            " ".join(w.text for w in picked),
        ))
    return result


def summary(root: Path, layout: Layout, mid: str) -> dict | None:
    """The human abstract, split into the fields our summarizer emits.

    These corpora write "NA." into a section that has no content. Left in, every
    model would be scored against the literal string "NA", and action-item
    recall for those meetings would be meaningless.
    """
    path = root / layout.abstractive / f"{mid}.abssumm.xml"
    if not path.exists():
        return None

    sections: dict[str, list[str]] = {}
    for section in ET.parse(path).getroot():
        name = section.tag.split("}")[-1]
        lines = [
            (sentence.text or "").strip()
            for sentence in section
            if (sentence.text or "").strip()
            and (sentence.text or "").strip().rstrip(".").upper() != "NA"
        ]
        sections.setdefault(name, []).extend(lines)

    abstract = " ".join(sections.get("abstract", []))
    if not abstract:
        return None

    return {
        "summary": abstract,
        "actionItems": sections.get("actions", []),
        "keyPoints": sections.get("decisions", []) + sections.get("problems", []),
    }
