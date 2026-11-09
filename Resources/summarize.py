"""Meeting summary: decisions, to-dos with owners, open points, ideas, issues.

    python summarize.py meeting.md        → writes meeting.json and a "## Zusammenfassung" section into meeting.md
    python summarize.py --selftest

Backend (MEETING_SUMMARY): "ollama" (default, local and offline; starts `ollama serve` itself if it isn't running),
"claude" (Claude API via the anthropic SDK, needs credentials and `pip install anthropic` in the venv), "off".
MEETING_SUMMARY_MODEL overrides the model (default qwen2.5:14b-instruct / claude-opus-5-5).

The JSON is the structured form (every item has the transcript time it came from), meant for a later board/workflow
step; the Markdown section is rendered from it.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request

OLLAMA = "http://127.0.0.1:11434"
STAMP = r"\d\d:\d\d:\d\d"
ITEM = {"type": "object", "additionalProperties": False, "required": ["text", "at"],
        "properties": {"text": {"type": "string"}, "at": {"type": "string", "description": "hh:mm:ss aus dem Transkript"}}}
TODO = {"type": "object", "additionalProperties": False, "required": ["text", "owner", "due", "at"],
        "properties": {"text": {"type": "string"}, "owner": {"type": "string", "description": "Name, oder leer"},
                       "due": {"type": "string", "description": "Termin wie gesagt, oder leer"}, "at": {"type": "string"}}}
SCHEMA = {"type": "object", "additionalProperties": False,
          "required": ["title", "summary", "decisions", "todos", "open_questions", "ideas", "issues"],
          "properties": {"title": {"type": "string", "description": "2 bis 6 Wörter"},
                         "summary": {"type": "string"},
                         "decisions": {"type": "array", "items": ITEM},
                         "todos": {"type": "array", "items": TODO},
                         "open_questions": {"type": "array", "items": ITEM},
                         "ideas": {"type": "array", "items": ITEM},
                         "issues": {"type": "array", "items": ITEM}}}
SYSTEM = """Du fasst Meeting-Transkripte zusammen. Das Transkript ist automatisch erkannt (whisper) und enthält Hörfehler;
deute sie sinnvoll, erfinde aber nichts. Schreibe auf Deutsch, knapp und konkret.
- title: kurzer, konkreter Titel für das Meeting (2 bis 6 Wörter), ohne Datum und ohne Anführungszeichen.
  Die App benennt damit Meetings, die beim Start keinen Namen bekommen haben.
- summary: 2 bis 4 Sätze, worum es ging und was herauskam.
- decisions: was entschieden oder vereinbart wurde.
- todos: konkrete Aufgaben. owner = wer es übernimmt (Name oder Sprecher-Bezeichnung wie im Transkript), sonst leer.
  due = Termin, falls genannt, sonst leer.
- open_questions: offene Fragen und ungeklärte Punkte.
- ideas: Ideen und Vorschläge, die genannt wurden.
- issues: Probleme, Bugs, Risiken, die angesprochen wurden.
- at: Zeitstempel hh:mm:ss der Transkriptzeile, aus der der Punkt stammt.
Leere Listen sind in Ordnung. Die Notizen des Nutzers (falls vorhanden) zeigen, was ihm wichtig war."""
HEADINGS = [("decisions", "Entscheidungen"), ("todos", "To-dos"), ("open_questions", "Offene Punkte"),
            ("ideas", "Ideen"), ("issues", "Probleme")]


def sections(md):
    """Transcript text and the user's notes from a meeting file."""
    transcript = re.search(r"\n## Transcript\n(.*?)(?=\n## |\Z)", md, re.S)
    notes = re.search(r"\n## Meine Notizen\n(.*?)(?=\n## |\Z)", md, re.S)
    clean = lambda m: m.group(1).replace("  \n", "\n").strip() if m else ""
    return clean(transcript), clean(notes)


def prompt(title, transcript, notes):
    p = f"Meeting: {title}\n\n<transkript>\n{transcript}\n</transkript>"
    return p + (f"\n\n<notizen>\n{notes}\n</notizen>" if notes else "")


def render(data):
    out = ["## Zusammenfassung", "", data.get("summary", "").strip()]
    for key, heading in HEADINGS:
        items = data.get(key) or []
        if not items:
            continue
        out += ["", f"### {heading}", ""]
        for it in items:
            at = f" `{it['at']}`" if re.fullmatch(STAMP, it.get("at", "")) else ""
            if key == "todos":
                extra = "".join([f" · **{it['owner']}**" if it.get("owner") else "",
                                 f" · bis {it['due']}" if it.get("due") else ""])
                out.append(f"- [ ] {it['text']}{extra}{at}")
            else:
                out.append(f"- {it['text']}{at}")
    return "\n".join(out).strip() + "\n"


def insert(md, section):
    """Put (or replace) the summary section right before the transcript."""
    md = re.sub(r"\n## Zusammenfassung\n.*?(?=\n## (?!#)|\Z)", "\n", md, flags=re.S)
    if "\n## Transcript\n" in md:
        return md.replace("\n## Transcript\n", f"\n{section}\n## Transcript\n", 1)
    return md.rstrip("\n") + "\n\n" + section


# ---------- backends ----------

def ollama(text, model):
    started = None
    try:
        urllib.request.urlopen(OLLAMA, timeout=2)
    except OSError:
        exe = shutil.which("ollama") or "/opt/homebrew/bin/ollama"
        started = subprocess.Popen([exe, "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(60):
            try:
                urllib.request.urlopen(OLLAMA, timeout=1)
                break
            except OSError:
                time.sleep(0.5)
    try:
        body = json.dumps({"model": model, "stream": False, "format": SCHEMA,
                           "options": {"num_ctx": 32768, "temperature": 0.2},
                           "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}]})
        req = urllib.request.Request(f"{OLLAMA}/api/chat", data=body.encode(), headers={"Content-Type": "application/json"})
        return json.loads(json.loads(urllib.request.urlopen(req, timeout=1800).read())["message"]["content"])
    finally:
        if started:
            started.terminate()   # frees the model's RAM again; we only started it for this summary


def claude(text, model):
    import anthropic

    client = anthropic.Anthropic()
    response = client.beta.messages.create(
        model=model,
        max_tokens=16000,
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",   # a refused request is re-run on a fallback model instead of failing
        system=SYSTEM,
        output_config={"effort": "medium", "format": {"type": "json_schema", "schema": SCHEMA}},
        messages=[{"role": "user", "content": text}],
    )
    if response.stop_reason == "refusal":
        raise RuntimeError("Claude hat die Zusammenfassung abgelehnt")
    return json.loads(next(b.text for b in response.content if b.type == "text"))


def summarize(md_path):
    backend = os.environ.get("MEETING_SUMMARY", "ollama")
    if backend == "off":
        return None
    with open(md_path, encoding="utf-8") as f:
        md = f.read()
    transcript, notes = sections(md)
    if len(transcript) < 200:   # a few words: nothing worth summarizing
        return None
    title = re.sub(r"^\d{4}-\d\d-\d\d_\d{4}_?", "", os.path.splitext(os.path.basename(md_path))[0]).replace("-", " ")
    text = prompt(title or "Meeting", transcript, notes)
    if backend == "claude":
        data = claude(text, os.environ.get("MEETING_SUMMARY_MODEL", "claude-opus-5-5"))
    else:
        data = ollama(text, os.environ.get("MEETING_SUMMARY_MODEL", "qwen2.5:14b-instruct"))
    with open(os.path.splitext(md_path)[0] + ".json", "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    with open(md_path, encoding="utf-8") as f:   # re-read: the app may have saved notes meanwhile
        md = f.read()
    with open(md_path, "w", encoding="utf-8") as f:
        f.write(insert(md, render(data)))
    return data


def selftest():
    md = ("# Meeting x\n\nAudio: a.wav\n\n## Transcript\n\n[00:00:01] **Ich:** Hallo.  \n[00:00:05] **Sprecher 1:** Ja.  \n"
          "\n## Meine Notizen\n\nwichtig\n")
    assert sections(md) == ("[00:00:01] **Ich:** Hallo.\n[00:00:05] **Sprecher 1:** Ja.", "wichtig")
    data = {"title": "Kickoff", "summary": "Kurz.", "decisions": [{"text": "Wir bauen X", "at": "00:00:05"}],
            "todos": [{"text": "Mail schicken", "owner": "Ich", "due": "", "at": "bogus"}],
            "open_questions": [], "ideas": [], "issues": []}
    section = render(data)
    assert "Kickoff" not in section   # the title only goes to the JSON (the app renames the file)
    assert SCHEMA["required"][0] == "title" and "title" in SCHEMA["properties"]
    assert section == ("## Zusammenfassung\n\nKurz.\n\n### Entscheidungen\n\n- Wir bauen X `00:00:05`\n\n"
                       "### To-dos\n\n- [ ] Mail schicken · **Ich**\n")
    once = insert(md, section)
    assert once.index("## Zusammenfassung") < once.index("## Transcript") and once.endswith("wichtig\n")
    assert insert(once, render(data | {"summary": "Neu."})).count("## Zusammenfassung") == 1   # rerun replaces
    assert "Kurz." not in insert(once, render(data | {"summary": "Neu."}))
    print("summarize selftest ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        sys.exit()
    try:
        summarize(sys.argv[1])
    except Exception as e:   # the transcript is already saved; a missing summary must not fail the meeting
        print(f"Zusammenfassung übersprungen: {e}", file=sys.stderr)
        sys.exit(1)
