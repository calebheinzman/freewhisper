"""Turning whatever a corpus ships into what the engines expect."""

from __future__ import annotations

import subprocess
from pathlib import Path

import soundfile as sf

# What `TranscriptionEngine.transcribe` documents as its input, and what the
# app's own recorder writes.
SAMPLE_RATE = 16_000


def to_wav(source: str | Path, destination: Path, start: float | None = None,
           duration: float | None = None) -> Path:
    """Convert to 16 kHz mono WAV, optionally clipping a window out of it.

    The pipeline resamples anything it is given, so this is not strictly
    required — but doing it once up front means the realtime factors are
    measured against a known sample rate, and that a corpus shipping 8 kHz
    telephone audio doesn't quietly get a free speed-up.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        return destination

    command = ["ffmpeg", "-nostdin", "-loglevel", "error", "-y"]
    if start is not None:
        command += ["-ss", f"{start:.3f}"]
    command += ["-i", str(source)]
    if duration is not None:
        command += ["-t", f"{duration:.3f}"]
    command += ["-ac", "1", "-ar", str(SAMPLE_RATE), "-c:a", "pcm_s16le", str(destination)]

    subprocess.run(command, check=True, capture_output=True)
    return destination


def write_wav(samples, destination: Path, sample_rate: int = SAMPLE_RATE) -> Path:
    """Write decoded samples straight out, for corpora loaded through `datasets`."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        return destination
    sf.write(destination, samples, sample_rate, subtype="PCM_16")
    return destination


def duration_of(path: Path) -> float:
    info = sf.info(str(path))
    return info.frames / info.samplerate
