"""Live meeting transcription engine, fully offline.

    ffmpeg ... -f s16le -ac 1 -ar 16000 pipe:1 | python engine.py --out transcript.txt
    python engine.py --file audio.wav --out transcript.txt
    python engine.py --selftest

Per utterance (split at pauses by silero VAD): whisper-tiny picks German, English or Portuguese (~90 ms, CPU) and
large-v3-turbo transcribes it in that language via a resident whisper-server (GPU). After the recording, the text is
written at once; then offline diarization (diarize.py, 4/4 on a real test file) labels speakers per sentence.
Why per utterance: whisper forced to one language translates the other one. When transcription falls behind,
waiting utterances of one language are packed into one request (one 30 s encoder pass) to catch up.

stdout, one JSON object per line, for the app:
  {"t":"ready"} · {"t":"stopped"} · {"t":"speaking","on":bool} · {"t":"utt","id":n,"start":s,"end":e,"lang":"de","text":"…"}
  {"t":"partial","start":s,"text":"…"} (the sentence still being spoken, revised every ~0.6 s; the next utt replaces it)
  {"t":"text","out":path} (transcript written, no speakers yet) · {"t":"done","out":path} (with speakers)
"""
import io
import json
import os
import queue
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.request
import uuid
import wave

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import diarize  # noqa: E402

RATE = 16000
MODELS = os.path.expanduser("~/.meeting-notes/models")
WHISPER_MODELS = os.path.expanduser(os.environ.get("WHISPER_MODELS", "~/.whisper-models"))
# Core ML build (encoder on the Neural Engine, GPU stays free) when its converted encoder exists; else Homebrew's Metal build.
COREML_SERVER = os.path.expanduser("~/.meeting-notes/src/whisper.cpp/build/bin/whisper-server")
COREML_ENCODER = f"{WHISPER_MODELS}/ggml-large-v3-turbo-encoder.mlmodelc"
SERVER = os.environ.get("MEETING_WHISPER_SERVER") or (
    COREML_SERVER if os.path.exists(COREML_SERVER) and os.path.isdir(COREML_ENCODER) else "/opt/homebrew/bin/whisper-server")
PARTIAL_EVERY = 0.4      # s between live re-transcriptions of the sentence still being spoken
PACK_MAX = 28.0          # s of speech per whisper request (its window is 30 s)
# Own vocabulary (dictionary file + calendar attendees, set by the app) steers whisper's spelling of names and jargon.
# shortcut: whisper's prompt holds ~224 tokens, so the list is cut at 600 chars; enough for a few dozen terms.
VOCAB = os.environ.get("MEETING_VOCAB", "").strip()[:600]
# A plain sentence, no "Begriffe:" label: whisper copied that label into the transcript ("Begriff: Okay, gut.").
PROMPT = {"de": "Besprechung auf Deutsch" + (f" über {VOCAB}." if VOCAB else "."),
          "en": "A meeting in English" + (f" about {VOCAB}." if VOCAB else "."),
          # whisper has one "pt"; a Brazilian prompt steers it to Brazilian spelling (você, ônibus, fato)
          "pt": "Reunião em português do Brasil, você está ótimo" + (f", sobre {VOCAB}." if VOCAB else ".")}
# Sentences whisper invents from YouTube subtitles in quiet or unclear audio; dropped wherever they appear.
PHANTOM = re.compile(r"wir sehen uns im (nächsten )?video|untertitel (im auftrag|von|der amara)|danke fürs zuschauen"
                     r"|vielen dank fürs zuschauen|abonnier|thanks? (you )?for watching|subscribe to", re.I)
# Swiss German sometimes passes whisper-tiny as English (or Portuguese) and comes back as gibberish. When a
# non-German result scores below this, the audio is transcribed again as German and the likelier text wins.
# English gets a much lower bar: accented English in a room mic scores around -0.5 too, and forced to German whisper
# translates it ("Wir haben die Möglichkeit, …" in the middle of an English talk). Only gibberish is redone.
# shortcut: guessed from typical whisper avg_logprob (clean ≈ -0.3), not measured on Swiss German; tune with real audio.
LANG_DOUBT = {"en": -1.0, "pt": -0.5}


def emit(**msg):
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


# ---------- whisper-server ----------

def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wav_bytes(samples):
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes((np.clip(samples, -1, 1) * 32767).astype(np.int16).tobytes())
    return buf.getvalue()


class Whisper:
    def __init__(self):
        self.port = free_port()
        # The server holds ~4 GB, so it must never outlive the engine (left-over servers piled up to 20 GB when the
        # engine was killed or crashed). A small sh guard reads our stdin pipe: it hits EOF however this process ends,
        # even on SIGKILL, and then kills the server; the guard itself exits with the server, so poll() still works.
        guard = 'exec 3<&0; "$@" <&- 3<&- & pid=$!; (read _ <&3; kill $pid 2>/dev/null) & wait $pid'
        self.proc = subprocess.Popen(
            ["/bin/sh", "-c", guard, "whisper-guard",
             SERVER, "-m", f"{WHISPER_MODELS}/ggml-large-v3-turbo.bin", "--host", "127.0.0.1",
             "--port", str(self.port), "-t", "8", "-bs", "1", "-bo", "1",  # greedy: measured as accurate as beam here
             "-nlp"],  # verbose_json would otherwise detect all languages: a 2nd encoder pass, doubles each request
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(240):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{self.port}/", timeout=1)
                return
            except OSError:
                if self.proc.poll() is not None:
                    raise RuntimeError("whisper-server exited")
                time.sleep(0.25)
        raise RuntimeError("whisper-server did not start")

    def transcribe(self, samples, language):
        """Returns (segments [(start, end, text)] relative to the samples, mean avg_logprob)."""
        boundary = uuid.uuid4().hex
        fields = {"language": language, "response_format": "verbose_json", "temperature": "0.0",
                  "prompt": PROMPT.get(language, "")}
        body = b""
        for k, v in fields.items():
            body += f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
        body += (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="u.wav"\r\n'
                 f"Content-Type: audio/wav\r\n\r\n").encode() + wav_bytes(samples) + f"\r\n--{boundary}--\r\n".encode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/inference", data=body,
                                     headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
        data = json.loads(urllib.request.urlopen(req, timeout=600).read())
        segs = data.get("segments", [])
        score = sum(s.get("avg_logprob", 0.0) for s in segs) / len(segs) if segs else 0.0
        return scrub(glue([(s["start"], s["end"], s.get("text", "")) for s in segs]), language), score

    def close(self):
        self.proc.stdin.close()   # EOF → the guard kills the server
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def glue(segments):
    """whisper sometimes ends a segment mid-word ("Pilotpro" + "jekt"); a piece without a leading space continues
    the previous word."""
    out = []
    for s, e, t in segments:
        if not t.strip():
            continue
        if out and not t.startswith(" "):
            ps, _, pt = out[-1]
            out[-1] = (ps, e, pt + t.strip())
        else:
            out.append((s, e, t.strip()))
    return out


# Leftovers of the old prompt label and whisper's sound notes ("*ding*", "*sad*").
NOISE = re.compile(r"\b(Begriff(e|en)?|Terms?|Termos?):\s*|\*[^*]{1,30}\*\s*")


# English stock phrases whisper adds to German or Portuguese speech ("Thank you." at the end of a sentence).
STOCK_EN = re.compile(r"^(thank you( very much| so much)?|thanks|see you( later)?|bye( bye)?|you)[.!]?$", re.I)


def unloop(t):
    """whisper's decoding loop: a phrase of 2–6 words 3+ times in a row ("Vercel, Begriff, Vercel, Begriff, …")
    keeps one copy (punctuation ignored when comparing); a sentence of 4+ words twice in a row keeps one.
    Single words are left alone: "Ja. Ja. Ja." is how people talk."""
    toks = re.findall(r"\S+\s*", t)
    key = [re.sub(r"\W+", "", x).lower() for x in toks]
    out, i = [], 0
    while i < len(toks):
        for n in range(2, 7):
            reps = 1
            while key[i:i + n] == key[i + reps * n:i + (reps + 1) * n] and all(key[i:i + n]):
                reps += 1
            if reps >= 3:
                out += toks[i + (reps - 1) * n:i + reps * n]   # the last copy keeps its own end punctuation
                i += reps * n
                break
        else:
            out.append(toks[i])
            i += 1
    t = "".join(out).strip()
    out = []
    for x in re.split(r"(?<=[.!?])\s+", t):
        norm = re.sub(r"\W+", " ", x).strip().lower()
        if not (out and len(norm.split()) >= 4 and norm == re.sub(r"\W+", " ", out[-1]).strip().lower()):
            out.append(x)
    return " ".join(out)


def scrub(segments, language="de"):
    """Drop invented subtitle sentences (PHANTOM), prompt/sound noise, decoding loops and, outside English, lone
    English stock phrases; a segment left empty disappears."""
    out = []
    for s, e, t in segments:
        t = unloop(NOISE.sub("", t).strip())
        keep = [x for x in re.split(r"(?<=[.!?])\s+", t)
                if x and not PHANTOM.search(x) and not (language != "en" and STOCK_EN.match(x))]
        if keep:
            out.append((s, e, " ".join(keep)))
    return out


# ---------- engine ----------

def pack(items, limit=PACK_MAX):
    """Leading run of same-language utterances that fits one whisper window (always at least one)."""
    out, total = [], 0.0
    for it in items:
        d = len(it["samples"]) / RATE
        if out and (it["lang"] != out[0]["lang"] or total + d + 0.3 > limit):
            break
        out.append(it)
        total += d + 0.3
    return out


def split_segments(segments, spans):
    """Give each packed utterance the whisper segments whose midpoint falls inside its span (times stay relative
    to the start of that utterance)."""
    out = [[] for _ in spans]
    for s, e, t in segments:
        mid = (s + e) / 2
        k = min(range(len(spans)), key=lambda i: 0 if spans[i][0] <= mid <= spans[i][1]
                else min(abs(mid - spans[i][0]), abs(mid - spans[i][1])))
        out[k].append((round(max(0.0, s - spans[k][0]), 3), round(max(0.0, e - spans[k][0]), 3), t))
    return out


class Engine:
    def __init__(self):
        import sherpa_onnx as so
        vc = so.VadModelConfig()
        vc.silero_vad.model = f"{MODELS}/silero_vad.onnx"
        vc.silero_vad.min_silence_duration = 0.5   # a pause this long ends an utterance (one bubble)
        vc.silero_vad.min_speech_duration = 0.25
        vc.silero_vad.max_speech_duration = 25
        vc.sample_rate = RATE
        self.vad = so.VoiceActivityDetector(vc, buffer_size_in_seconds=120)
        self.window = vc.silero_vad.window_size
        tiny = f"{MODELS}/sherpa-onnx-whisper-tiny"
        self.lid = so.SpokenLanguageIdentification(so.SpokenLanguageIdentificationConfig(
            whisper=so.SpokenLanguageIdentificationWhisperConfig(
                encoder=f"{tiny}/tiny-encoder.int8.onnx", decoder=f"{tiny}/tiny-decoder.int8.onnx"), num_threads=2))
        self.pending = queue.Queue()
        self.utts = []           # finished: id, start, end, lang, text
        self.segs = []           # whisper sentences in absolute time, for speaker labels at the end
        self.count = 0
        self.audio = np.zeros(RATE * 600, dtype=np.float32)   # whole recording so far, grows as needed
        self.length = 0
        self.lock = threading.Lock()
        self.speaking = False
        self.speech_from = 0     # sample where the sentence being spoken began (for partials)
        self.lang = "de"         # language of the latest sentence, a good guess for the current one
        self.whisper = None
        self.ready = threading.Event()
        threading.Thread(target=self._start_whisper, daemon=True).start()
        self.worker = threading.Thread(target=self._work, daemon=True)
        self.worker.start()
        threading.Thread(target=self._partials, daemon=True).start()

    def _start_whisper(self):
        self.whisper = Whisper()   # ~3 s model load overlaps with the first words being spoken
        self.ready.set()
        emit(t="ready")

    def language(self, samples):
        s = self.lid.create_stream()
        s.accept_waveform(RATE, samples[: RATE * 8])
        lang = self.lid.compute(s)
        return lang if lang in PROMPT else "de"   # only the languages in PROMPT; anything else is most likely German

    def feed(self, samples):
        if self.length + len(samples) > len(self.audio):
            self.audio = np.concatenate([self.audio, np.zeros(max(len(self.audio), len(samples)), np.float32)])
        self.audio[self.length:self.length + len(samples)] = samples
        self.length += len(samples)
        for i in range(0, len(samples), self.window):
            self.vad.accept_waveform(samples[i:i + self.window])
        on = self.vad.is_speech_detected()
        if on != self.speaking:
            self.speaking = on
            if on:   # VAD fires ~0.5 s into speech
                self.speech_from = max(0, self.length - int(RATE * 0.8))
            emit(t="speaking", on=on)
        self._drain_vad()

    def _drain_vad(self):
        while not self.vad.empty():
            seg = self.vad.front
            a = max(0, seg.start - int(RATE * 0.4))           # VAD reacts late: short first words ("Ja", "Not")
            b = min(self.length, seg.start + len(seg.samples) + int(RATE * 0.2))   # got clipped without this pad
            self.vad.pop()
            samples = self.audio[a:b].copy()
            start = a / RATE
            if len(samples) < RATE * 0.5:
                continue
            self.count += 1
            self.lang = self.language(samples)
            self.pending.put({"id": self.count, "start": start, "end": start + len(samples) / RATE,
                              "lang": self.lang, "samples": samples})

    def _work(self):
        backlog = []
        while True:
            if not backlog:
                item = self.pending.get()
                if item is None:
                    return
                backlog.append(item)
            while not self.pending.empty():            # take everything waiting, keep order
                nxt = self.pending.get()
                if nxt is None:
                    self.pending.put(None)
                    break
                backlog.append(nxt)
            batch = pack(backlog)
            del backlog[:len(batch)]
            self.ready.wait()
            gap = np.zeros(int(RATE * 0.3), dtype=np.float32)
            audio, spans, t = [], [], 0.0
            for it in batch:
                d = len(it["samples"]) / RATE
                spans.append((t, t + d))
                audio += [it["samples"], gap]
                t += d + 0.3
            try:
                wav, lang = np.concatenate(audio), batch[0]["lang"]
                segs, score = self.whisper.transcribe(wav, lang)
                if score < LANG_DOUBT.get(lang, -9.0):   # German is never redone
                    de_segs, de_score = self.whisper.transcribe(wav, "de")
                    if de_score > score:
                        segs = de_segs
                        for it in batch:
                            it["lang"] = "de"
                parts = split_segments(segs, spans)
            except Exception as e:  # keep going; one lost utterance beats a dead engine
                parts = [[] for _ in batch]
                print(f"whisper error: {e}", file=sys.stderr)
            for it, segs in zip(batch, parts):
                text = " ".join(t for _, _, t in segs)
                u = {k: it[k] for k in ("id", "start", "end", "lang")} | {"text": text}
                with self.lock:
                    self.utts.append(u)
                    self.segs += [(it["start"] + s, it["start"] + e, t) for s, e, t in segs]
                if text:
                    emit(t="utt", **u)

    def _partials(self):
        """While someone speaks, re-transcribe their sentence so far with whisper-tiny (CPU, 0.1-0.8 s, leaves the
        GPU to the final pass) and send it as a partial; the large model's utt replaces it moments later."""
        import sherpa_onnx as so
        tiny, models = f"{MODELS}/sherpa-onnx-whisper-tiny", {}
        while True:
            time.sleep(PARTIAL_EVERY)
            a, b, lang = self.speech_from, self.length, self.lang
            if not self.speaking or b - a < RATE * 0.7:   # shorter: tiny tends to invent words
                continue
            if lang not in models:
                models[lang] = so.OfflineRecognizer.from_whisper(
                    encoder=f"{tiny}/tiny-encoder.int8.onnx", decoder=f"{tiny}/tiny-decoder.int8.onnx",
                    tokens=f"{tiny}/tiny-tokens.txt", language=lang, task="transcribe", num_threads=2)
            stream = models[lang].create_stream()
            stream.accept_waveform(RATE, self.audio[max(a, b - RATE * 28):b].copy())   # whisper's window is 30 s
            models[lang].decode_stream(stream)
            text = stream.result.text.strip()
            if text and self.speaking and self.speech_from == a:   # still the same sentence
                emit(t="partial", start=a / RATE, text=text)

    def finish(self, out_path, wav_path):
        emit(t="stopped")
        self.speaking = False   # stops partials before whisper closes
        self.vad.flush()
        self._drain_vad()
        if self.speaking:
            emit(t="speaking", on=False)
        self.pending.put(None)
        self.worker.join()
        if self.whisper:
            self.whisper.close()       # frees the GPU before the CPU-heavy speaker step
        segs = sorted(self.segs)
        write(out_path, diarize.render([(s, None, t) for s, _, t in segs]))   # text first: never lose it
        emit(t="text", out=out_path)
        try:
            if wav_path:
                write(out_path, diarize.render(diarize.label(segs, wav_path)))
        except Exception as e:
            print(f"speaker labels skipped: {e}", file=sys.stderr)
        emit(t="done", out=out_path)


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text + ("\n" if text else ""))


def selftest():
    mk = lambda lang, sec: {"lang": lang, "samples": np.zeros(int(sec * RATE))}
    assert len(pack([mk("de", 5), mk("de", 5), mk("en", 5)])) == 2          # stops at language change
    assert len(pack([mk("de", 20), mk("de", 10)])) == 1                     # stops at the window limit
    assert len(pack([mk("de", 40)])) == 1                                   # always makes progress
    assert glue([(0, 1, " Aus dem Pilotpro"), (1, 2, "jekt."), (2, 3, " Gut."), (3, 4, " ")]) == \
        [(0, 2, "Aus dem Pilotprojekt."), (2, 3, "Gut.")]
    assert split_segments([(0, 2, "Hallo"), (5.5, 7, "Welt"), (7.1, 8, "!")], [(0, 5), (5.3, 9)]) == \
        [[(0, 2, "Hallo")], [(0.2, 1.7, "Welt"), (1.8, 2.7, "!")]]
    assert scrub([(0, 2, "Gut. Wir sehen uns im Video. Tschüss!"), (2, 3, "Thanks for watching!")]) == \
        [(0, 2, "Gut. Tschüss!")]
    assert scrub([(0, 1, "Begriff: Okay, gut. *ding* Ja."), (1, 2, "*sad*")]) == [(0, 1, "Okay, gut. Ja.")]
    assert scrub([(0, 1, "Ich bin Stress. Thank you. Vielen Dank.")]) == [(0, 1, "Ich bin Stress. Vielen Dank.")]
    assert scrub([(0, 1, "Thank you.")], "en") == [(0, 1, "Thank you.")]
    assert unloop("Gut. Vercel, Begriff, Vercel, Begriff, Vercel, Begriff, Verde, ok?") == "Gut. Vercel, Begriff, Verde, ok?"
    assert unloop("So, the first thing, the first thing, the first thing. Ja.") == "So, the first thing. Ja."
    assert unloop("Da. - I think it's good. - I think it's good.") == "Da. - I think it's good."
    assert unloop("Ja. Ja. Ja. Nein, nein, nein.") == "Ja. Ja. Ja. Nein, nein, nein."   # single words stay
    print("engine selftest ok")


def main():
    import signal
    signal.signal(signal.SIGINT, signal.SIG_IGN)   # Ctrl+C stops ffmpeg; the engine must live on to finish the text
    args = sys.argv[1:]
    if args == ["--selftest"]:
        return selftest()
    out = args[args.index("--out") + 1]
    wav = args[args.index("--wav") + 1] if "--wav" in args else None    # full recording, for speaker labels
    eng = Engine()
    if "--file" in args:
        src = args[args.index("--file") + 1]
        wav = wav or src    # --wav (e.g. the stereo original) is what the speaker step labels
        with wave.open(src) as w:
            data = w.readframes(w.getnframes())
        pcm = np.frombuffer(data, dtype=np.int16).astype(np.float32) / 32768
        for i in range(0, len(pcm), RATE):
            eng.feed(pcm[i:i + RATE])
    else:
        stdin = sys.stdin.buffer
        while chunk := stdin.read(RATE // 5 * 2):   # 200 ms of 16-bit audio
            eng.feed(np.frombuffer(chunk[: len(chunk) // 2 * 2], dtype=np.int16).astype(np.float32) / 32768)
    eng.finish(out, wav)


if __name__ == "__main__":
    main()
