"""Add speaker labels to a whisper.cpp transcript, fully offline (meeting-diarize: FluidAudio on Core ML).

    python diarize.py audio.wav whisper-stdout.txt   → prints "[hh:mm:ss] **Sprecher N:** text" lines
    python diarize.py --selftest
    python diarize.py --enroll sample.wav            → saves your voice; you are then labelled by name in any recording

Stereo recordings (left = microphone, right = system audio from the Mac): lines spoken while the system channel is
silent are you ("Ich", or MEETING_ME_NAME); only the system channel is diarized for the other people.

Segmentation, voice vectors and clustering (VBx) run in meeting-diarize, a Swift helper next to the app binary
(MEETING_DIARIZE overrides its path): 40 min of audio in ~15 s and <1 GB, where sherpa-onnx took ~5 min and 2.3 GB.
Speakers with little speech are still folded into the closest real voice (absorb), in case clustering leaves fragments.

Env: MEETING_SPEAKERS=N forces the speaker count; MEETING_ATTENDEES (from the calendar) caps it.
"""
import collections
import json
import os
import re
import subprocess
import sys
import tempfile
import wave

HELPER = os.environ.get("MEETING_DIARIZE") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "MacOS", "meeting-diarize")   # inside MeetingNotes.app
PARAGRAPH = 160  # chars: one speaker talking long starts a new line at the next sentence end …
LINE_SPAN = 15.0  # … and so does a line that already covers this many seconds (finer timestamps to listen back)
SENTENCE_MAX = 20.0  # s: whisper pieces are joined into one sentence (one speaker) up to this length
LINE = re.compile(r"^\[(\d+):(\d+):(\d+)\.(\d+) --> (\d+):(\d+):(\d+)\.(\d+)\]\s*(.*)$")
ME = "me"                 # speaker id for the microphone side of a stereo recording
MIN_SPEAKER_S = 20.0      # a real speaker talks at least this long …
MIN_SPEAKER_SHARE = 0.03  # … and at least this share of all speech; smaller clusters get absorbed
# Thresholds below are cosines of meeting-diarize's WeSpeaker vectors, measured 2026-11-09 on 4 synthetic voices and
# the 40-min meeting of 2026-11-07: one person split in two ≥ 0.85, different people ≤ 0.69.
MERGE_SIMILARITY = 0.85   # averaged voices this alike are one person
SILENT = 0.004            # RMS below this on the system channel = nobody remote is talking
# Measured 2026-11-10 (DAPP Sync, MacBook mic): room floor 0.0014–0.0025 RMS, speech 0.003–0.015; 0.01 missed most.
# shortcut: one recording, one mic; re-measure if "Ich" goes missing or room noise becomes "Ich".
MIC_VOICE = 0.005         # RMS above this on the mic = you are talking (room noise stays below)
VOICE = os.path.expanduser("~/.meeting-notes/voice.npy")   # your voice (diarize.py --enroll), finds you without stereo
ME_SIMILARITY = 0.7       # a speaker this close to your voice sample is you (test: you ≥ 0.92, others ≤ 0.57)
ME_TURN = 0.65            # … and so is any single stretch ≥ 1.5 s (you ≥ 0.75, others ≤ 0.58), even when merged


def parse_whisper(text):
    segs = []
    for line in text.splitlines():
        m = LINE.match(line.strip())
        if not m or not m.group(9).strip():
            continue
        g = [int(x) for x in m.groups()[:8]]
        start = g[0] * 3600 + g[1] * 60 + g[2] + g[3] / 1000
        end = g[4] * 3600 + g[5] * 60 + g[6] + g[7] / 1000
        segs.append((start, end, m.group(9).strip()))
    return segs


def sentences(segs):
    """Joins whisper pieces that continue an unfinished sentence ("… to provide it to" + "an people."), so a speaker
    change can't cut a sentence in two: the whole sentence then goes to the speaker with the largest time share."""
    out = []
    for start, end, text in segs:
        if out and not out[-1][2].endswith((".", "!", "?")) and start - out[-1][1] < 1.0 \
                and end - out[-1][0] <= SENTENCE_MAX:
            out[-1] = (out[-1][0], end, f"{out[-1][2]} {text}")
        else:
            out.append((start, end, text))
    return out


def assign(segs, turns):
    """Each whisper segment gets the speaker it overlaps most; with no overlap, the nearest turn."""
    out = []
    for start, end, text in segs:
        best, best_overlap = None, 0.0
        for t0, t1, spk in turns:
            ov = min(end, t1) - max(start, t0)
            if ov > best_overlap:
                best, best_overlap = spk, ov
        if best is None and turns:
            mid = (start + end) / 2
            best = min(turns, key=lambda t: min(abs(mid - t[0]), abs(mid - t[1])))[2]
        out.append((start, best, text))
    return out


def render(labeled, me_name=None):
    """Merge consecutive words/lines of one speaker into paragraphs; label speakers 1, 2, … by first appearance
    (the microphone side is me_name). Speaker names are bold, so the app can tell them from text with a colon."""
    me_name = me_name or os.environ.get("MEETING_ME_NAME", "Ich")
    names, lines = {}, []
    many = len({s for _, s, _ in labeled if s is not None}) > 1
    for start, spk, text in labeled:
        if spk not in names:
            names[spk] = me_name if spk == ME else f"Sprecher {sum(1 for k in names if k != ME) + 1}"
        if lines and lines[-1][1] == spk:
            prev = lines[-1][2]
            full = len(" ".join(prev)) > PARAGRAPH or start - lines[-1][0] >= LINE_SPAN
            long_and_done = full and prev[-1].endswith((".", "!", "?"))
            if not long_and_done:
                prev.append(text)
                continue
        lines.append([start, spk, [text]])
    result = []
    for start, spk, texts in lines:
        s = int(start)
        stamp = f"[{s // 3600:02d}:{s // 60 % 60:02d}:{s % 60:02d}]"
        who = f"**{names[spk]}:** " if many else ""
        result.append(f"{stamp} {who}{' '.join(texts)}")
    return "\n".join(result)


def absorb(turns, embed, max_speakers=None):
    """Fold fragment speakers into real ones. embed(t0, t1) → unit voice vector or None.
    Kept speakers: enough speech (MIN_SPEAKER_*); kept speakers with near-identical voices merge; each turn of a
    dropped speaker goes to the kept speaker with the closest voice, or the nearest kept turn in time.
    max_speakers (from the calendar): while more voices remain, the two most alike merge. Never splits."""
    import numpy as np

    dur = collections.Counter()
    for a, b, s in turns:
        dur[s] += b - a
    if not dur:
        return turns
    floor = max(MIN_SPEAKER_S, MIN_SPEAKER_SHARE * sum(dur.values()))
    keep = [s for s, _ in dur.most_common() if dur[s] >= floor] or [dur.most_common(1)[0][0]]

    cents = {}
    for s in keep:
        longest = sorted((t for t in turns if t[2] == s and t[1] - t[0] >= 1.0), key=lambda t: t[0] - t[1])[:20]
        vecs = [v for v in (embed(a, b) for a, b, _ in longest) if v is not None]
        if vecs:
            m = np.mean(vecs, axis=0)
            cents[s] = m / (np.linalg.norm(m) or 1)

    alias = {}  # merged speaker → the longer-talking one it joins (keep is sorted by speech time)
    for i, s in enumerate(keep):
        for t in keep[:i]:
            if s in cents and t in cents and t not in alias and float(cents[s] @ cents[t]) >= MERGE_SIMILARITY:
                alias[s] = t
                break
    keep = [s for s in keep if s not in alias]
    while max_speakers and len(keep) > max(max_speakers, 1):
        pairs = [(float(cents[s] @ cents[t]), t, s) for i, s in enumerate(keep) for t in keep[:i] if s in cents and t in cents]
        _, into, s = max(pairs) if pairs else (0, keep[-2], keep[-1])
        alias[s] = into    # s talks less (keep is sorted by speech time)
        keep.remove(s)

    def resolve(s):
        while s in alias:
            s = alias[s]
        return s
    cents = {s: v for s, v in cents.items() if s in keep}
    kept_turns = [t for t in turns if resolve(t[2]) in keep]

    out = []
    for a, b, s in turns:
        s = resolve(s)
        if s not in keep:
            v = embed(a, b) if b - a >= 0.5 and cents else None
            if v is not None:
                s = max(cents, key=lambda k: float(cents[k] @ v))
            else:
                mid = (a + b) / 2
                near = min(kept_turns, key=lambda t: min(abs(mid - t[0]), abs(mid - t[1])))[2]
                s = resolve(near)
        out.append((a, b, s))
    return out


def load(wav_path):
    """16-bit wav → (rate, float32 array of shape (samples, channels))."""
    import numpy as np

    with wave.open(wav_path) as w:
        assert w.getsampwidth() == 2, "expects 16-bit wav"
        rate, ch = w.getframerate(), w.getnchannels()
        audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    return rate, audio.reshape(-1, ch)


def rms(x):
    import numpy as np
    return float(np.sqrt(np.mean(np.square(x)))) if len(x) else 0.0


def remote_active(sys_audio, rate):
    """Did the system channel carry speech at all (≥ 1 % of seconds above SILENT)? Otherwise it was an in-person
    meeting and the recording is effectively mono."""
    secs = [rms(sys_audio[i:i + rate]) for i in range(0, len(sys_audio), rate)]
    return bool(secs) and sum(s > SILENT for s in secs) >= max(3, len(secs) // 100)


def label(segs, wav_path):
    """[(start, end, text)] + recording → [(start, speaker, text)]."""
    segs = sentences(segs)
    rate, audio = load(wav_path)
    mic = audio[:, 0]
    sys_audio = audio[:, 1] if audio.shape[1] > 1 else None
    people = int(os.environ.get("MEETING_ATTENDEES", "0")) or None   # calendar attendees incl. you, set by the app
    if sys_audio is not None and remote_active(sys_audio, rate):
        try:
            out = assign(segs, diarize(sys_audio, rate, people - 1 if people else None)[0])   # system channel: the others
            return [(s, side(mic[int(s * rate):int(e * rate)], sys_audio[int(s * rate):int(e * rate)], spk), t)
                    for (s, e, t), (_, spk, _) in zip(segs, out)]
        except RuntimeError as e:   # only notification sounds on the Mac (everyone in the room): no speech there
            print(f"system channel unusable ({str(e)[:80]}), labelling the room mix", file=sys.stderr)
    source = mic if sys_audio is None else audio.mean(axis=1)
    turns, embed = diarize(source, rate, people)
    return assign(segs, mark_me(turns, embed))


def side(mic, sys_audio, spk):
    """ME only when the system channel is quiet and the mic carries a voice. A short sentence tail timed into a
    pause is quiet on both: it stays with the nearest remote speaker instead of becoming yours."""
    return ME if rms(sys_audio) < SILENT and rms(mic) >= MIC_VOICE else spk


def helper(audio, rate, *args, stdin=None):
    """Runs meeting-diarize on mono float32 audio (written to a temporary 16-bit wav) → its parsed JSON."""
    import numpy as np

    with tempfile.NamedTemporaryFile(suffix=".wav") as f:
        with wave.open(f.name, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
            w.writeframes((np.clip(audio, -1, 1) * 32767).astype(np.int16).tobytes())
        p = subprocess.run([HELPER, f.name, *args], input=stdin, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"meeting-diarize failed ({p.returncode}): {p.stderr.strip()[-500:]}")
    return json.loads(p.stdout)


def unit(v):
    import numpy as np
    v = np.asarray(v, dtype=np.float32)
    return v / (np.linalg.norm(v) or 1)


def diarize(audio, rate, max_speakers=None):
    """mono float32 audio → ([(start, end, speaker)], embed) with fragment speakers absorbed (at most max_speakers).
    embed(start, end) → unit voice vector of one of those turns (None for any other span)."""
    forced = os.environ.get("MEETING_SPEAKERS")
    args = ["--speakers", forced] if forced else ["--max-speakers", str(max_speakers)] if max_speakers else []
    out = helper(audio, rate, *args)["turns"]
    vectors = {(t["start"], t["end"]): unit(t["embedding"]) for t in out}
    turns = [(t["start"], t["end"], t["speaker"]) for t in out]

    def embed(a, b):
        return vectors.get((a, b))
    return (turns if forced else absorb(turns, embed, max_speakers)), embed   # absorb keeps each turn's span


def embed_spans(audio, rate, spans):
    """[(start, end)] → one unit voice vector per span."""
    out = helper(audio, rate, "--spans", stdin=json.dumps([[float(a), float(b)] for a, b in spans]))
    return [unit(v) for v in out["embeddings"]]


def find_me(turns, embed, voice=None):
    """The speaker whose voice matches the enrolled sample best (≥ ME_SIMILARITY), or None."""
    import numpy as np

    if voice is None:
        if not os.path.exists(VOICE):
            return None
        voice = np.load(VOICE)
    best, best_sim = None, ME_SIMILARITY
    for spk in {s for _, _, s in turns}:
        longest = sorted((t for t in turns if t[2] == spk and t[1] - t[0] >= 1.0), key=lambda t: t[0] - t[1])[:10]
        vecs = [v for v in (embed(a, b) for a, b, _ in longest) if v is not None]
        if not vecs:
            continue
        c = np.mean(vecs, axis=0)
        sim = float(c @ voice) / (float(np.linalg.norm(c)) or 1)
        if sim > best_sim:
            best, best_sim = spk, sim
    return best


def mark_me(turns, embed, voice=None):
    """Relabels your turns as ME using the enrolled voice: long turns by their own voice, short ones by the speaker
    they were clustered into, but only next to a long turn of yours. A short blip of the room clustered with your
    voice ("an people." mid-sentence of someone else) stays theirs."""
    import numpy as np

    if voice is None:
        if not os.path.exists(VOICE):
            return turns
        voice = np.load(VOICE)
    me = find_me(turns, embed, voice)
    vecs = [embed(a, b) if b - a >= 1.5 else None for a, b, _ in turns]
    long_me = [v is not None and float(v @ voice) >= ME_TURN for v in vecs]
    out = []
    for i, (a, b, s) in enumerate(turns):
        if vecs[i] is not None:
            mine = long_me[i]
        else:
            near = [long_me[j] for j in (i - 1, i + 1) if 0 <= j < len(turns) and vecs[j] is not None]
            mine = s == me and any(near)
        out.append((a, b, ME if mine else s))
    return out


def enroll(wav_path):
    """Saves your voice from a ~20 s sample: the mean of 3 s windows, so pauses and one odd word don't dominate."""
    import numpy as np

    rate, audio = load(wav_path)
    mono = audio.mean(axis=1)
    secs = len(mono) / rate
    windows = [(t, min(t + 3, secs)) for t in np.arange(0, max(secs - 1, 0.1), 1.5)]
    windows = [(a, b) for a, b in windows if rms(mono[int(a * rate):int(b * rate)]) >= SILENT]   # skip silence
    vecs = embed_spans(mono, rate, windows) if windows else []
    if len(vecs) < 3:
        raise RuntimeError("Stimmprobe zu kurz oder zu leise")
    m = np.mean(vecs, axis=0)
    os.makedirs(os.path.dirname(VOICE), exist_ok=True)
    np.save(VOICE, m / np.linalg.norm(m))


def selftest():
    import numpy as np

    segs = parse_whisper("[00:00:00.000 --> 00:00:04.000]   Guten Morgen.\n"
                         "[00:00:04.000 --> 00:00:07.500]   Hallo zusammen.\n"
                         "[00:00:07.500 --> 00:00:09.000]   Und weiter.\n"
                         "[00:01:02.250 --> 00:01:05.000]   Thanks.\n"
                         "noise line\n")
    assert segs[0] == (0.0, 4.0, "Guten Morgen.") and segs[3][0] == 62.25 and len(segs) == 4
    turns = [(0.0, 4.2, 7), (4.2, 9.0, 3), (61.0, 66.0, 7)]
    labeled = assign(segs, turns)
    assert [s for _, s, _ in labeled] == [7, 3, 3, 7]
    assert render(labeled) == ("[00:00:00] **Sprecher 1:** Guten Morgen.\n"
                               "[00:00:04] **Sprecher 2:** Hallo zusammen. Und weiter.\n"
                               "[00:01:02] **Sprecher 1:** Thanks.")
    assert render([(0, 5, "Hi."), (2, ME, "Hallo."), (4, 6, "Ok.")], me_name="Johan") == (
        "[00:00:00] **Sprecher 1:** Hi.\n[00:00:02] **Johan:** Hallo.\n[00:00:04] **Sprecher 2:** Ok.")
    assert render(assign(segs[:2], [(0, 9, 0)])) == "[00:00:00] Guten Morgen. Hallo zusammen."  # one speaker: no labels
    assert assign([(100.0, 101.0, "x")], turns)[0][1] == 7  # no overlap → nearest turn
    words = [(float(i), 0, w) for i, w in enumerate(("Satz " * 60 + "Ende. Weiter geht es").split())]
    out = render(words).splitlines()
    assert len(out) == 2 and out[0].endswith("Ende.") and out[1] == "[00:01:01] Weiter geht es"  # long monologue splits

    # absorb: A and B talk long; C is a 2 s fragment with A's voice, D a 0.3 s blip next to B; E sounds like A
    voice = {"A": [1, 0, 0], "B": [0, 1, 0], "C": [0.9, 0.1, 0], "E": [0.95, 0, 0.05]}
    t = [(0, 30, "A"), (30, 60, "B"), (60, 62, "C"), (62, 62.3, "D"), (62.3, 90, "B"), (90, 120, "E")]
    owner = {(a, b): s for a, b, s in t}

    def fake_embed(a, b):
        v = np.array(voice.get(owner[(a, b)], [0, 0, 1]), dtype=np.float32)
        return v / np.linalg.norm(v)
    assert [s for _, _, s in absorb(t, fake_embed)] == ["A", "B", "A", "B", "B", "A"]
    # cap: three real voices, calendar says two people → the two most alike (A, F) merge
    voice["F"] = [0.6, 0, 0.8]
    t3 = [(0, 30, "A"), (30, 60, "B"), (60, 90, "F")]
    owner.update({(a, b): s for a, b, s in t3})
    assert [s for _, _, s in absorb(t3, fake_embed)] == ["A", "B", "F"]
    assert [s for _, _, s in absorb(t3, fake_embed, max_speakers=2)] == ["A", "B", "A"]
    assert [s for _, _, s in absorb(t3, fake_embed, max_speakers=5)] == ["A", "B", "F"]   # never splits
    me = np.array([0, 0.98, 0.2], dtype=np.float32)
    assert find_me(t3, fake_embed, voice=me / np.linalg.norm(me)) == "B"
    assert find_me(t3, fake_embed, voice=np.array([0, 0, -1], dtype=np.float32)) is None   # nobody close enough
    # clustering merged B's voice into A's speaker: the long B turn is still found, the short one follows its speaker
    t4 = [(0, 30, "A"), (30, 60, "A2"), (60, 61, "A")]
    voice["A2"] = voice["B"]
    owner.update({(a, b): s for a, b, s in t4})
    merged = lambda a, b: fake_embed(a, b)
    assert [s for _, _, s in mark_me([(0, 30, "A"), (30, 60, "A"), (60, 61, "A")], lambda a, b: merged(a, b),
                                     voice=me / np.linalg.norm(me))] == ["A", ME, "A"]
    # short turn of "your" cluster: yours only next to a long turn of yours
    own = lambda a, b: unit(me if (a, b) in ((0, 30), (31, 60)) else [1, 0, 0])
    tm = [(0, 30, "M"), (30, 30.5, "M"), (31, 60, "M"), (60, 60.5, "M"), (61, 90, "X"), (90, 90.5, "M")]
    assert [s for _, _, s in mark_me(tm, own, voice=unit(me))] == [ME, ME, ME, ME, "X", "M"]
    # a sentence cut by whisper stays whole and goes to the speaker with the most time in it
    cut = [(0.0, 4.0, "to provide it to"), (4.2, 5.0, "an people."), (5.5, 7.0, "Next one.")]
    assert sentences(cut) == [(0.0, 5.0, "to provide it to an people."), (5.5, 7.0, "Next one.")]
    assert assign(sentences(cut), [(0, 4.1, "F"), (4.1, 5.2, ME), (5.2, 9, "F")])[0][1] == "F"
    assert len(sentences([(0, 15, "a"), (15.5, 30, "b.")])) == 2   # no sentence longer than SENTENCE_MAX
    # one speaker, short sentences: a new line every LINE_SPAN seconds
    talk = [(float(t), 0, "Kurz.") for t in range(0, 40, 4)]
    assert [ln[:10] for ln in render(talk).splitlines()] == ["[00:00:00]", "[00:00:16]", "[00:00:32]"]
    loud, quiet = np.full(1600, 0.05, np.float32), np.zeros(1600, np.float32)
    assert side(loud, quiet, 3) == ME and side(quiet, loud, 3) == 3
    assert side(quiet, quiet, 3) == 3   # sentence tail in a pause: not yours
    print("diarize selftest ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        sys.exit()
    if sys.argv[1] == "--enroll":
        enroll(sys.argv[2])
        print("Stimme gespeichert:", VOICE)
        sys.exit()
    wav, raw = sys.argv[1], sys.argv[2]
    with open(raw, encoding="utf-8") as f:
        segs = parse_whisper(f.read())
    print(render(label(segs, wav)))
