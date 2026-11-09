"""Automatic speaker test, no microphone needed: three Mac voices read tests/texte/05-dialog.txt.

    ~/.meeting-notes/venv/bin/python tests/speakers.py

Checks with the real meeting-diarize helper (.build/release, so run `swift build -c release` first): three speakers
are found, at most a few percent of speech goes to the wrong one, and with Flo's voice enrolled Flo's lines become "Ich".
"""
import os
import subprocess
import sys
import tempfile
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("MEETING_DIARIZE", f"{ROOT}/.build/release/meeting-diarize")
sys.path.insert(0, f"{ROOT}/Resources")
import diarize  # noqa: E402

VOICES = {"DU": "Flo (German (Germany))", "ANNA": "Anna", "EDDY": "Eddy (German (Germany))"}
RATE = 16000


def say(voice, text, path):
    subprocess.run(["say", "-v", voice, "-o", path, f"--data-format=LEI16@{RATE}", text], check=True)
    with wave.open(path) as w:
        return w.readframes(w.getnframes())


def main():
    tmp = tempfile.mkdtemp()
    lines = [l.split(":", 1) for l in open(f"{ROOT}/tests/texte/05-dialog.txt") if l[:1].isupper() and ":" in l]
    pcm, truth, t, gap = b"", [], 0.0, b"\0\0" * int(RATE * 0.6)
    for who, text in lines * 3:   # ~2 min, enough speech per voice for clustering
        clip = say(VOICES[who], text.strip(), f"{tmp}/clip.wav")
        truth.append((t, t + len(clip) / 2 / RATE, who))
        pcm += clip + gap
        t += len(clip) / 2 / RATE + 0.6
    dialog = f"{tmp}/dialog.wav"
    with wave.open(dialog, "wb") as w:
        w.setnchannels(1), w.setsampwidth(2), w.setframerate(RATE), w.writeframes(pcm)

    rate, audio = diarize.load(dialog)
    turns, _ = diarize.diarize(audio[:, 0], rate)
    speakers = {s for _, _, s in turns}
    assert len(speakers) == 3, f"expected 3 speakers, got {len(speakers)}"
    # each found speaker maps to the true voice it overlaps most; count speech time attributed to the wrong voice
    overlap = {}
    for a, b, s in turns:
        for ta, tb, who in truth:
            overlap[s, who] = overlap.get((s, who), 0) + max(0.0, min(b, tb) - max(a, ta))
    owner = {s: max(VOICES, key=lambda w: overlap.get((s, w), 0)) for s in speakers}
    assert len(set(owner.values())) == 3, f"two speakers map to one voice: {owner}"
    wrong = sum(v for (s, w), v in overlap.items() if owner[s] != w) / sum(overlap.values())
    assert wrong < 0.05, f"{wrong:.0%} of speech on the wrong speaker"

    # voice sample of Flo with other text → Flo's lines are labelled as you
    enroll_text = "Ich lese jetzt einen kurzen Text vor, damit die App meine Stimme kennenlernt. " \
                  "In Meetings spreche ich oft über Projekte, Termine und Aufgaben. Am Ende fasse ich gerne zusammen."
    say(VOICES["DU"], enroll_text, f"{tmp}/sample.wav")
    diarize.VOICE = f"{tmp}/voice.npy"
    diarize.enroll(f"{tmp}/sample.wav")
    segs = [(a, b, who) for a, b, who in truth]   # whisper segments stand-in: text = true speaker
    labeled = diarize.label(segs, dialog)
    hits = sum((spk == diarize.ME) == (who == "DU") for (_, spk, who) in labeled)
    assert hits == len(labeled), f"'Ich' wrong on {len(labeled) - hits} of {len(labeled)} lines"
    print(f"speakers ok: 3 voices, {wrong:.1%} on the wrong speaker, 'Ich' right on all {len(labeled)} lines")


if __name__ == "__main__":
    main()
