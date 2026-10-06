#!/usr/bin/env python3
"""Generate two-channel, turn-taking fixtures for the record harness (macOS ``say``).

Real telehealth capture is two isolated channels: the clinician's mic hears the
clinician and is silent while they listen; the system channel hears the remote
client and is silent while *they* listen. This builds the fixtures the same way,
as a turn-taking dialogue where each channel carries only its speaker's turns
and matched silence during the other's, so the two streams interleave into a
natural, correctly timestamped session.

The dialogue is fictional and PHI-free. The record harness loops the fixtures,
so a short dialogue feeds a capture of any length.

Voices: the preferred voices are used when the machine has them; otherwise the
first installed English voice, and failing that the system default. GitHub's
hosted macOS images do not always carry the same voices as a desktop Mac.

Usage:
    python3 scripts/gen_record_fixture.py <out_dir>

Writes ``<out_dir>/therapist.wav`` (mic) and ``<out_dir>/client.wav`` (system),
both 48 kHz signed-16-bit mono to match the capture graph.
"""

from __future__ import annotations

import subprocess
import sys
import wave
from pathlib import Path

_FMT = "LEI16@48000"
_PREFERRED = {"therapist": ["Alex", "Daniel", "Fred"], "client": ["Samantha", "Karen", "Moira"]}

# Alternating turns in time order: (speaker, text).
_DIALOGUE: list[tuple[str, str]] = [
    ("therapist", "Good morning. Thanks for coming in today. How have you been feeling since our last session?"),
    ("client", "Honestly, it has been a hard couple of weeks. The sleep problems are back and I feel on edge."),
    ("therapist", "I am sorry it has been so heavy. You mentioned anxiety at work last time. Has that continued?"),
    ("client", "Work has been overwhelming. I keep waking up around three in the morning with my mind racing."),
    ("therapist", "How have the breathing exercises we practiced been going?"),
    (
        "client",
        "They helped a little in the evenings. I also went for a walk with a friend on Saturday, which "
        "felt good. But my mood has been low, and I am worried about falling behind.",
    ),
]


def _installed_voices() -> list[tuple[str, str]]:
    """(name, locale) for every voice ``say`` knows on this machine."""
    out = subprocess.run(["say", "-v", "?"], check=True, capture_output=True, text=True).stdout
    voices = []
    for line in out.splitlines():
        # "Samantha            en_US    # Hello! My name is Samantha."
        head = line.split("#", 1)[0].rstrip()
        if not head:
            continue
        name, _, locale = head.rpartition(" ")
        voices.append((name.strip(), locale.strip()))
    return voices


def _pick_voices() -> dict[str, str | None]:
    installed = _installed_voices()
    names = {name for name, _ in installed}
    english = [name for name, locale in installed if locale.startswith("en")]
    picked: dict[str, str | None] = {}
    for speaker, preferred in _PREFERRED.items():
        choice = next((v for v in preferred if v in names), None)
        if choice is None:
            others = [v for v in english if v not in picked.values()]
            choice = others[0] if others else None
        picked[speaker] = choice
    return picked


def _say(voice: str | None, text: str, out: Path) -> None:
    voice_args = ["-v", voice] if voice else []
    subprocess.run(
        ["say", *voice_args, "--data-format", _FMT, "--file-format", "WAVE", "-o", str(out), text],
        check=True,
    )


def main() -> int:
    if len(sys.argv) != 2:  # prog + out_dir
        print("usage: gen_record_fixture.py <out_dir>", file=sys.stderr)
        return 2
    out_dir = Path(sys.argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    voices = _pick_voices()
    print(f"voices: therapist={voices['therapist'] or 'default'} client={voices['client'] or 'default'}")

    params = None
    turns: list[tuple[str, bytes]] = []
    for idx, (speaker, text) in enumerate(_DIALOGUE):
        clip = out_dir / f"turn_{idx}.wav"
        _say(voices[speaker], text, clip)
        with wave.open(str(clip), "rb") as w:
            params = w.getparams()
            turns.append((speaker, w.readframes(w.getnframes())))
        clip.unlink()

    if params is None:
        print("no turns synthesized", file=sys.stderr)
        return 1

    therapist, client = bytearray(), bytearray()
    for speaker, data in turns:
        silence = b"\x00" * len(data)
        therapist += data if speaker == "therapist" else silence
        client += data if speaker == "client" else silence

    for path, buf in ((out_dir / "therapist.wav", therapist), (out_dir / "client.wav", client)):
        with wave.open(str(path), "wb") as w:
            w.setnchannels(params.nchannels)
            w.setsampwidth(params.sampwidth)
            w.setframerate(params.framerate)
            w.writeframes(bytes(buf))

    seconds = len(therapist) / (params.sampwidth * params.nchannels) / params.framerate
    print(f"fixture duration: {seconds:.1f}s per channel ({params.framerate} Hz)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
