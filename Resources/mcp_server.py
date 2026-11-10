"""MCP server: Claude Code / Claude Desktop read and search the meetings in ~/Meetings (stdio, read-only for now).

    python -I mcp_server.py              → serve over stdio
    python -I mcp_server.py --selftest

Register:  claude mcp add meetingnotes -s user -- ~/.meeting-notes/venv/bin/python -I <bundle>/Resources/mcp_server.py
The .md files are the source of truth (the vault copy is generated from them). MEETING_DIR overrides ~/Meetings.
See MCP.md for the plan (editing, recording control, live transcript come later).
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
from datetime import datetime, timezone
from typing import Any

try:   # the model only sees the message of a ToolError; any other exception becomes a bare "Error executing tool"
    from mcp.server.mcpserver.exceptions import ToolError as Problem
except ImportError:
    Problem = ValueError

DIR = os.path.expanduser(os.environ.get("MEETING_DIR", "~/Meetings"))
# "[00:01:02] **Anna:** text", older files "[00:01:02] Sprecher 2: text", single speaker "[00:01:02] text"
LINE = re.compile(r"^\[(\d+):(\d\d):(\d\d)\] (?:\*\*(.+?):\*\* |(Sprecher \d+): )?(.+?)\s*$")
TODO = re.compile(r"^- \[([ xX])\] (.+?)\s*$")
TODO_META = re.compile(r"^(.*?)(?: · \*\*(.+?)\*\*)?(?: · bis (.+?))?(?: `(\d\d:\d\d:\d\d)`)?$")


# ---------- reading the meeting files (same rules as the Swift app) ----------

def stems():
    """Meeting ids (file names without .md), newest first; dotfiles are app internals."""
    try:
        names = os.listdir(DIR)
    except FileNotFoundError:
        return []
    return sorted((n[:-3] for n in names if n.endswith(".md") and not n.startswith(".")), reverse=True)


def read(stem):
    with open(os.path.join(DIR, stem + ".md"), encoding="utf-8") as f:
        return f.read()


def title(stem):
    """"2026-11-07_1400_kundencall" → "kundencall" (meetingName in App.swift)."""
    parts = stem.split("_", 2)
    return parts[2].replace("-", " ") if len(parts) == 3 else "Meeting" if len(parts) == 2 else stem


def when(stem):
    m = re.match(r"(\d{4}-\d\d-\d\d)_(\d\d)(\d\d)", stem)
    return f"{m[1]} {m[2]}:{m[3]}" if m else ""


def section(md, heading):
    m = re.search(rf"\n## {re.escape(heading)}\n(.*?)(?=\n## |\Z)", md, re.S)
    return m[1].strip() if m else ""


def header(md, key):
    """"Projekt: X" style line before the first "## " section."""
    for line in md.split("\n"):
        if line.startswith("## "):
            break
        if line.startswith(f"{key}: "):
            return line[len(key) + 2:].strip() or None
    return None


def transcript(md):
    """[(seconds, speaker or None, text)]"""
    out = []
    for line in md.split("\n"):
        m = LINE.match(line)
        if m:
            out.append((int(m[1]) * 3600 + int(m[2]) * 60 + int(m[3]), m[4] or m[5], m[6]))
    return out


def participants(md):
    """Calendar attendees plus named speakers (not "Sprecher N"), like VaultMirror.participants."""
    names = [n.strip() for n in (header(md, "Teilnehmer") or "").split(",")]
    names += re.findall(r"\*\*([^*:]{1,40}):\*\*", md)
    seen, out = set(), []
    for n in names:
        if n and not n.startswith("Sprecher ") and n.lower() not in seen:
            seen.add(n.lower())
            out.append(n)
    return out


def todos(md):
    out = []
    for line in md.split("\n"):
        m = TODO.match(line)
        if m:
            text, owner, due, at = TODO_META.match(m[2]).groups()
            out.append({"text": text, "done": m[1] != " ", "owner": owner or "", "due": due or "", "at": at or ""})
    return out


def stamp(seconds):
    return f"{seconds // 3600:02d}:{seconds // 60 % 60:02d}:{seconds % 60:02d}"


def seconds(hms):
    h, m, s = (int(x) for x in hms.split(":"))
    return h * 3600 + m * 60 + s


def info(stem, md):
    lines = transcript(md)
    return {"id": stem, "title": title(stem), "date": when(stem),
            "minutes": round(lines[-1][0] / 60) if lines else 0,
            "project": header(md, "Projekt") or "", "participants": participants(md),
            "has_summary": "\n## Zusammenfassung\n" in md,
            "open_todos": sum(not t["done"] for t in todos(md))}


def meetings(since=None, until=None, project=None, participant=None):
    """(stem, content) of every meeting matching the filters, newest first."""
    for stem in stems():
        day = stem[:10]
        if (since and day < since) or (until and day > until):
            continue
        md = read(stem)
        if project and (header(md, "Projekt") or "").lower() != project.lower():
            continue
        if participant and not any(participant.lower() in p.lower() for p in participants(md)):
            continue
        yield stem, md


def resolve(meeting_id):
    """Exact id, or a unique part of it ("Sprint", "2026-11-07_1952"); never a path outside DIR."""
    all_ = stems()
    if meeting_id in all_:
        return meeting_id
    hits = [s for s in all_ if meeting_id.lower() in s.lower()]
    if len(hits) == 1:
        return hits[0]
    raise Problem(f"Kein eindeutiges Meeting für {meeting_id!r}. "
                     + (f"Kandidaten: {', '.join(hits[:10])}" if hits else "list_meetings zeigt alle ids."))


# ---------- tools ----------

def list_meetings(since: str = "", until: str = "", project: str = "", participant: str = "", limit: int = 20) -> list[dict[str, Any]]:
    """Meetings, neueste zuerst. Filter: since/until als YYYY-MM-DD, project (exakt, wie der Ordner in der App),
    participant (Teil eines Namens). Liefert id, Titel, Datum, Dauer, Projekt, Teilnehmer, ob es eine
    Zusammenfassung gibt, und die Zahl offener To-dos."""
    out = []
    for stem, md in meetings(since, until, project, participant):
        out.append(info(stem, md))
        if len(out) >= limit:
            break
    return out


def search_meetings(query: str, since: str = "", until: str = "", project: str = "", participant: str = "",
                    limit: int = 20) -> list[dict[str, Any]]:
    """Volltextsuche über Titel, Transkript, Notizen und Zusammenfassung. Alle Wörter müssen im Meeting vorkommen
    (wie das Suchfeld der App), Groß-/Kleinschreibung egal. Das Transkript ist automatisch erkannt und enthält
    Hörfehler: bei wenigen Treffern Synonyme oder Wortteile probieren. Liefert pro Meeting bis zu 5 passende Zeilen."""
    words = query.lower().split()
    out = []
    for stem, md in meetings(since, until, project, participant):
        low = (title(stem) + "\n" + md).lower()
        if not words or not all(w in low for w in words):
            continue
        hits = [line.strip() for line in md.split("\n")
                if not line.startswith(("# ", "Audio: ")) and any(w in line.lower() for w in words)]
        out.append({"id": stem, "title": title(stem), "date": when(stem), "hits": hits[:5]})
        if len(out) >= limit:
            break
    return out


def get_meeting(meeting_id: str, parts: list[str] = ["summary", "notes", "transcript"],
                start: str = "", end: str = "") -> str:
    """Ein Meeting als Markdown. meeting_id: id aus list_meetings/search_meetings (ein eindeutiger Teil reicht).
    parts: beliebige von "summary", "notes", "transcript". start/end (hh:mm:ss) begrenzen das Transkript auf ein
    Zeitfenster, sinnvoll bei langen Meetings. Sprecher heißen "Sprecher N", solange sie in der App nicht
    umbenannt wurden."""
    stem = resolve(meeting_id)
    md = read(stem)
    i = info(stem, md)
    out = [f"# {i['title']}", "", f"id: {stem}", f"Datum: {i['date']}", f"Dauer: {i['minutes']} min"]
    out += [f"Projekt: {i['project']}"] if i["project"] else []
    out += [f"Teilnehmer: {', '.join(i['participants'])}"] if i["participants"] else []
    if "summary" in parts:
        out += ["", "## Zusammenfassung", "", section(md, "Zusammenfassung") or "(keine)"]
    if "notes" in parts:
        out += ["", "## Meine Notizen", "", section(md, "Meine Notizen") or "(keine)"]
    if "transcript" in parts:
        lo, hi = seconds(start) if start else 0, seconds(end) if end else float("inf")
        lines = [f"[{stamp(t)}] {spk + ': ' if spk else ''}{text}" for t, spk, text in transcript(md) if lo <= t <= hi]
        out += ["", "## Transkript", "", "\n".join(lines) or "(leer)"]
    return "\n".join(out) + "\n"


def list_todos(open_only: bool = True, owner: str = "", project: str = "", since: str = "") -> list[dict[str, Any]]:
    """To-dos über alle Meetings, neueste Meetings zuerst: aus den Zusammenfassungen und aus abhakbaren Zeilen
    in den eigenen Notizen. owner: Teil eines Namens (oder "Sprecher 2"). at: Zeitstempel im Transkript, um mit
    get_meeting(start=at) nachzulesen, was genau gesagt wurde."""
    out = []
    for stem, md in meetings(since, None, project):
        for t in todos(md):
            if (open_only and t["done"]) or (owner and owner.lower() not in t["owner"].lower()):
                continue
            out.append({"meeting": stem, "date": when(stem), **t})
    return out


# ---------- writing (same edits as the Swift app) ----------

def write(stem, text):
    """Atomic (temp file + rename): the app's folder watcher sees it and never reads half a file."""
    tmp = os.path.join(DIR, f".{stem}.md.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, os.path.join(DIR, stem + ".md"))


def slug(name):
    """Recorder.slug: runs of letters/digits joined by "-"."""
    return "-".join(re.findall(r"[^\W_]+", name))


def set_header(md, key, value):
    """VaultMirror.setHeader: sets, adds (after "Audio:") or with an empty value removes a "Key: value" line."""
    lines = md.split("\n")
    end = next((i for i, l in enumerate(lines) if l.startswith("## ")), len(lines))
    i = next((i for i in range(end) if lines[i].startswith(f"{key}: ")), None)
    if i is not None:
        if value:
            lines[i] = f"{key}: {value}"
        else:
            del lines[i]
            if i < len(lines) and not lines[i]:
                del lines[i]
    elif value:
        at = next((i + 1 for i in range(end) if lines[i].startswith("Audio: ")), min(1, len(lines)))
        lines[at:at] = ["", f"{key}: {value}"]
    return "\n".join(lines)


def replace_section(md, heading, body):
    """Recorder.replacing: drops the section and appends it again at the end (empty body: just drops it)."""
    md = re.sub(rf"\n## {re.escape(heading)}\n.*?(?=\n## |\Z)", "", md, flags=re.S).strip("\n") + "\n"
    return md + f"\n## {heading}\n\n{body}\n" if body else md


def rename(stem, new_title):
    """Recorder.rename: "<date>_<slug>.md" plus its .json; returns the new id."""
    s = slug(new_title)
    target = f"{stem[:15]}_{s}" if s else stem[:15]
    if target == stem:
        return stem
    if os.path.exists(os.path.join(DIR, target + ".md")):
        raise Problem(f"Es gibt schon ein Meeting {target!r}.")
    os.rename(os.path.join(DIR, stem + ".md"), os.path.join(DIR, target + ".md"))
    if os.path.exists(os.path.join(DIR, stem + ".json")):
        os.rename(os.path.join(DIR, stem + ".json"), os.path.join(DIR, target + ".json"))
    return target


def update_meeting(meeting_id: str, title: str = "", project: str | None = None, notes: str | None = None,
                   append_notes: str = "") -> dict[str, Any]:
    """Ändert ein Meeting; nicht angegebene Felder bleiben. title: neuer Titel (benennt die Datei um, die id ändert
    sich). project: Projekt/Ordner, "" entfernt es. notes: ersetzt "Meine Notizen" ganz; append_notes: hängt einen
    Absatz an (vorzuziehen, damit nichts verloren geht). Liefert das Meeting mit der neuen id."""
    stem = resolve(meeting_id)
    md = read(stem)
    new = md if project is None else set_header(md, "Projekt", project.strip())
    if notes is not None or append_notes.strip():
        body = section(new, "Meine Notizen") if notes is None else notes.strip()
        if append_notes.strip():
            body = (body + "\n\n" if body else "") + append_notes.strip()
        new = replace_section(new, "Meine Notizen", body)
    if new != md:
        write(stem, new)
    if title.strip():
        stem = rename(stem, title)
    return info(stem, read(stem))


def rename_speaker(meeting_id: str, old: str, new: str) -> dict[str, Any]:
    """Benennt einen Sprecher im ganzen Meeting um (Transkript und Verantwortliche der To-dos), z. B.
    "Sprecher 2" → "Anna". Wie der Klick auf den Namen in der App. Vorher im Transkript prüfen, wer es ist."""
    stem = resolve(meeting_id)
    new = new.strip().replace("*", "").replace(":", "")
    md = read(stem)
    speakers = sorted({spk for _, spk, _ in transcript(md) if spk})
    if old not in speakers:
        raise Problem(f"Sprecher {old!r} kommt nicht vor. Sprecher: {', '.join(speakers) or 'keine'}")
    if not new or new == old:
        raise Problem("Der neue Name fehlt oder ist gleich wie der alte.")
    write(stem, md.replace(f"**{old}:**", f"**{new}:**").replace(f"· **{old}**", f"· **{new}**")
          .replace(f"] {old}: ", f"] **{new}:** "))   # last one: files from before bold names
    json_path = os.path.join(DIR, stem + ".json")
    if os.path.exists(json_path):
        with open(json_path, encoding="utf-8") as f:
            j = f.read()
        with open(json_path, "w", encoding="utf-8") as f:
            f.write(j.replace(f'"owner": "{old}"', f'"owner": "{new}"'))
    return info(stem, read(stem))


def set_todo(meeting_id: str, text: str, done: bool = True) -> dict[str, Any]:
    """Hakt ein To-do ab (done=true) oder wieder auf (done=false). text: der To-do-Text oder ein eindeutiger Teil
    davon, wie ihn list_todos liefert."""
    stem = resolve(meeting_id)
    lines = read(stem).split("\n")
    found = [(i, TODO_META.match(m[2])[1]) for i, m in ((i, TODO.match(l)) for i, l in enumerate(lines)) if m]
    hits = [h for h in found if text.strip().lower() in h[1].lower()]
    if len(hits) > 1:
        hits = [h for h in hits if h[1].lower() == text.strip().lower()] or hits
    if len(hits) != 1:
        raise Problem(f"{'Mehrere' if hits else 'Keine'} To-dos passen zu {text!r}. "
                      f"To-dos: {'; '.join(t for _, t in (hits or found)) or 'keine'}")
    i = hits[0][0]
    lines[i] = ("- [x] " if done else "- [ ] ") + lines[i][6:]
    write(stem, "\n".join(lines))
    return {"meeting": stem, "text": hits[0][1], "done": done}


def summarize(meeting_id: str) -> str:
    """Erstellt die Zusammenfassung (Entscheidungen, To-dos, offene Punkte, Ideen, Probleme) neu, lokal über
    Ollama wie der Knopf in der App; dauert etwa eine Minute. Ersetzt die bisherige Zusammenfassung, abgehakte
    To-dos sind danach wieder offen. Meetings ohne Titel bekommen einen."""
    stem = resolve(meeting_id)
    backend = subprocess.run(["defaults", "read", "com.johankoller.MeetingNotes", "summary"],
                             capture_output=True, text=True).stdout.strip()
    env = dict(os.environ, PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
               MEETING_SUMMARY=backend if backend in ("ollama", "claude") else "ollama")   # explicit request beats "off"
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "summarize.py")
    r = subprocess.run([sys.executable, "-I", script, os.path.join(DIR, stem + ".md")], env=env,
                       capture_output=True, text=True, timeout=900)
    if r.returncode:
        raise Problem(f"Zusammenfassung fehlgeschlagen: {r.stderr.strip()[-500:]}")
    write(stem, read(stem))   # summarize.py writes in place: rewrite atomically so the app notices
    try:   # Recorder.autoTitle: an unnamed meeting takes the title the summary suggested
        if len(stem.split("_")) == 2:
            with open(os.path.join(DIR, stem + ".json"), encoding="utf-8") as f:
                stem = rename(stem, json.load(f).get("title", ""))
    except (OSError, ValueError, Problem):
        pass
    return get_meeting(stem, parts=["summary"])


# ---------- recording control and live transcript (the app writes .live.json while a meeting runs) ----------

TOKEN = os.path.expanduser("~/.meeting-notes/control-token")


def live():
    """The running meeting from .live.json, or None (no file, or the app that wrote it is gone)."""
    try:
        with open(os.path.join(DIR, ".live.json"), encoding="utf-8") as f:
            data = json.load(f)
        os.kill(data["pid"], 0)
        return data
    except (OSError, ValueError, KeyError):
        return None


def app_running():
    return subprocess.run(["pgrep", "-x", "MeetingNotes"], capture_output=True).returncode == 0


def command(action, **params):
    """meetingnotes://<action>?token=… through `open` (starts the app if needed); the token comes from the app."""
    if not os.path.exists(TOKEN):   # the app writes it on its first launch
        subprocess.run(["open", "-g", "-b", "com.johankoller.MeetingNotes"], check=False)
        for _ in range(20):
            if os.path.exists(TOKEN):
                break
            time.sleep(0.5)
        else:
            raise Problem("MeetingNotes läuft nicht und ließ sich nicht starten.")
    with open(TOKEN, encoding="utf-8") as f:
        query = urllib.parse.urlencode({"token": f.read().strip(), **params}, quote_via=urllib.parse.quote)   # %20, not +
    subprocess.run(["open", "-g", f"meetingnotes://{action}?{query}"], check=True)


def wait_for(check, seconds):
    for _ in range(int(seconds * 4)):
        if check():
            return True
        time.sleep(0.25)
    return False


def status_of(data):
    if not data:
        return {"state": "idle", "app_running": app_running()}
    start = datetime.fromisoformat(data["started"].replace("Z", "+00:00"))
    return {"state": data["state"], "title": data["title"],
            "started": start.astimezone().strftime("%Y-%m-%d %H:%M"),
            "minutes": round((datetime.now(timezone.utc) - start).total_seconds() / 60, 1),
            "sentences": len(data.get("utterances", []))}


def recording_status() -> dict[str, Any]:
    """Läuft gerade eine Aufnahme? state: "idle", "recording" oder "transcribing" (Aufnahme gestoppt, Sprecher und
    Zusammenfassung werden berechnet), dazu Titel, Startzeit, Dauer und Zahl der erkannten Sätze."""
    return status_of(live())


def start_recording(title: str = "") -> dict[str, Any]:
    """Startet eine Aufnahme in MeetingNotes (Mikrofon + Mac-Ton), wie ⌃⌥Leertaste. Nur auf ausdrücklichen Wunsch
    von Johan. title: optional; ohne Titel nimmt die App den laufenden Kalendertermin. Die App startet bei Bedarf."""
    if live():
        raise Problem(f"Es läuft schon eine Aufnahme: {status_of(live())}")
    command("start", **({"title": title.strip()} if title.strip() else {}))
    if not wait_for(lambda: (live() or {}).get("state") == "recording", 10):
        raise Problem("Die Aufnahme hat nicht begonnen. Fehlt der Mikrofonzugriff? Details in der App und in "
                      "~/Library/Logs/MeetingNotes.log.")
    return recording_status()


def stop_recording() -> dict[str, Any]:
    """Stoppt die laufende Aufnahme. Das fertige Meeting (mit Sprechern und Zusammenfassung) erscheint nach
    ein bis zwei Minuten; dann findet es list_meetings."""
    if (live() or {}).get("state") != "recording":
        raise Problem("Es läuft keine Aufnahme.")
    command("stop")
    wait_for(lambda: (live() or {}).get("state") != "recording", 10)
    return recording_status()


def live_transcript(last_minutes: float = 0) -> str:
    """Was bisher im laufenden Meeting gesagt wurde, plus Johans Notizen dazu. last_minutes: nur die letzten N
    Minuten (0 = alles). Noch ohne Sprechernamen: die kommen erst nach dem Meeting."""
    data = live()
    if not data:
        raise Problem("Es läuft gerade kein Meeting.")
    utts = data.get("utterances", [])
    if last_minutes and utts:
        cut = utts[-1]["start"] - last_minutes * 60
        utts = [u for u in utts if u["start"] >= cut]
    s = status_of(data)
    out = [f"# {s['title']} (läuft seit {s['started']}, {s['minutes']} min, {s['state']})", "", "## Transkript", ""]
    out += [f"[{stamp(int(u['start']))}] {u['text']}" for u in utts] or ["(noch nichts erkannt)"]
    if data.get("notes", "").strip():
        out += ["", "## Meine Notizen", "", data["notes"].strip()]
    return "\n".join(out) + "\n"


# ---------- widget data (MCP Apps, Claude Desktop): called by widget.html, hidden from the model ----------

def meeting_data(meeting_id: str) -> dict[str, Any]:
    """Nur für das Widget: ein Meeting als strukturierte Daten."""
    stem = resolve(meeting_id)
    md = read(stem)
    return {**info(stem, md), "summary": section(md, "Zusammenfassung"), "notes": section(md, "Meine Notizen"),
            "transcript": [{"t": stamp(t), "speaker": spk or "", "text": text} for t, spk, text in transcript(md)]}


def live_data() -> dict[str, Any]:
    """Nur für das Widget: Status und Live-Transkript des laufenden Meetings."""
    data = live()
    return {**status_of(data), "notes": (data or {}).get("notes", ""),
            "utterances": [{"t": stamp(int(u["start"])), "text": u["text"]} for u in (data or {}).get("utterances", [])]}


# view of widget.html each tool opens in Claude Desktop; other clients just get the text
VIEWS = {"get_meeting": "meeting", "list_todos": "todos", "list_meetings": "list", "search_meetings": "list",
         "recording_status": "recording", "start_recording": "recording", "stop_recording": "recording",
         "live_transcript": "recording", "meeting_data": "meeting", "live_data": "recording"}
APP_ONLY = (meeting_data, live_data)
# Some hosts (Claude Desktop's Code tab) render widgets but can't relay the widget's own tool calls, so these tools
# carry the widget's data in structuredContent; the model still reads the usual text.
WIDGET_DATA = {"get_meeting": lambda kw: meeting_data(kw["meeting_id"]), "recording_status": lambda kw: live_data(),
               "start_recording": lambda kw: live_data(), "stop_recording": lambda kw: live_data(),
               "live_transcript": lambda kw: live_data()}


def with_widget_data(fn):
    """fn's text for the model plus WIDGET_DATA for the widget, as one CallToolResult (same name and arguments)."""
    import inspect
    from mcp.types import CallToolResult, TextContent

    def tool(**kw):
        r = fn(**kw)
        text = r if isinstance(r, str) else json.dumps(r, ensure_ascii=False, indent=2)
        return CallToolResult(content=[TextContent(type="text", text=text)], structured_content=WIDGET_DATA[fn.__name__](kw))
    tool.__name__, tool.__doc__ = fn.__name__, fn.__doc__
    tool.__signature__ = inspect.signature(fn).replace(return_annotation=CallToolResult)
    tool.__annotations__ = {**fn.__annotations__, "return": CallToolResult}
    return tool


TOOLS = [list_meetings, search_meetings, get_meeting, list_todos,
         update_meeting, rename_speaker, set_todo, summarize,
         recording_status, start_recording, stop_recording, live_transcript]


# ---------- selftest ----------

def selftest():
    import tempfile
    global DIR
    DIR = tempfile.mkdtemp()
    files = {
        "2026-11-07_1952_Sprint-Strategie": "# Meeting 2026-11-07_1952\n\nAudio: x.m4a\n\nProjekt: Agenten\n\n"
            "Teilnehmer: Dion, Anna\n\n## Zusammenfassung\n\nKurz.\n\n### To-dos\n\n"
            "- [ ] Budget klären · **Dion** · bis Montag `00:01:07`\n- [x] Demo bauen `00:02:00`\n\n"
            "## Transcript\n\n[00:00:01] **Sprecher 1:** Wir reden über das Budget.  \n"
            "[00:01:07] **Dion:** Ich kläre das Budget bis Montag.  \n\n## Meine Notizen\n\n- [ ] Raum buchen\n",
        "2026-11-08_1257": "# Meeting 2026-11-08_1257\n\nAudio: y.m4a\n\n## Transcript\n\n"
            "[00:00:01] Hot takes in the tech world.  \n[00:02:30] Electric cars.  \n",
        ".notes-123": "intern",
    }
    for stem, md in files.items():
        with open(os.path.join(DIR, stem + ".md"), "w", encoding="utf-8") as f:
            f.write(md)

    ms = list_meetings()
    assert [m["id"] for m in ms] == ["2026-11-08_1257", "2026-11-07_1952_Sprint-Strategie"], ms   # no dotfiles
    sprint = ms[1]
    assert sprint["title"] == "Sprint Strategie" and sprint["project"] == "Agenten" and sprint["open_todos"] == 2
    assert sprint["participants"] == ["Dion", "Anna"] and sprint["minutes"] == 1 and ms[0]["title"] == "Meeting"
    assert [m["id"] for m in list_meetings(since="2026-11-08")] == ["2026-11-08_1257"]
    assert [m["id"] for m in list_meetings(participant="dio")] == [sprint["id"]]
    assert list_meetings(project="agenten")[0]["id"] == sprint["id"] and not list_meetings(project="Agent")

    hits = search_meetings("budget montag")
    assert len(hits) == 1 and hits[0]["hits"][0].startswith("- [ ] Budget"), hits
    assert search_meetings("strategie")   # title counts
    assert not search_meetings("budget cars")   # every word must be in the same meeting

    text = get_meeting("Sprint", parts=["transcript"], start="00:01:00")
    assert "Dion: Ich kläre" in text and "Sprecher 1" not in text and "Zusammenfassung" not in text, text
    assert "Projekt: Agenten" in get_meeting("2026-11-07_1952_Sprint-Strategie")
    for bad in ("2026", "nope", "../etc/passwd"):
        try:
            resolve(bad)
            raise AssertionError(bad)
        except Problem:
            pass

    todo = list_todos()
    assert [t["text"] for t in todo] == ["Budget klären", "Raum buchen"], todo
    assert todo[0] == {"meeting": sprint["id"], "date": "2026-11-07 19:52", "text": "Budget klären",
                            "done": False, "owner": "Dion", "due": "Montag", "at": "00:01:07"}
    assert len(list_todos(open_only=False)) == 3 and [t["text"] for t in list_todos(owner="dion")] == ["Budget klären"]
    # editing
    assert slug("Kunden-Call: Q4/2026 Ü") == "Kunden-Call-Q4-2026-Ü" and slug(" _ ") == ""
    sid = sprint["id"]
    with open(os.path.join(DIR, sid + ".json"), "w", encoding="utf-8") as f:
        f.write('{"todos": [{"owner": "Sprecher 1"}]}')
    m = update_meeting("Sprint", project="", append_notes="Neu: Budget prüfen")
    assert m["project"] == "" and "Projekt:" not in read(sid)
    assert section(read(sid), "Meine Notizen") == "- [ ] Raum buchen\n\nNeu: Budget prüfen"
    assert read(sid).rstrip().endswith("Neu: Budget prüfen") and "## Transcript" in read(sid)
    m = update_meeting(sid, title="Sprint Review!", project="Agenten")
    assert m["id"] == "2026-11-07_1952_Sprint-Review" and m["project"] == "Agenten", m
    sid = m["id"]
    assert os.path.exists(os.path.join(DIR, sid + ".json")) and not os.path.exists(os.path.join(DIR, "2026-11-07_1952_Sprint-Strategie.md"))
    assert read(sid).split("\n")[2:6] == ["Audio: x.m4a", "", "Projekt: Agenten", ""], read(sid)   # header back after Audio:
    assert not [n for n in os.listdir(DIR) if n.endswith(".tmp")]

    rename_speaker(sid, "Sprecher 1", "Johan")
    assert "**Johan:** Wir reden" in read(sid) and "Sprecher 1" not in read(sid)
    assert '"owner": "Johan"' in open(os.path.join(DIR, sid + ".json"), encoding="utf-8").read()
    for args in ((sid, "Sprecher 9", "X"), (sid, "Johan", "Johan")):
        try:
            rename_speaker(*args)
            raise AssertionError(args)
        except Problem:
            pass

    assert set_todo(sid, "budget")["text"] == "Budget klären" and "- [x] Budget klären" in read(sid)
    set_todo(sid, "Budget klären", done=False)
    assert "- [ ] Budget klären · **Dion**" in read(sid)
    try:
        set_todo(sid, "b")   # Budget, Demo bauen, Raum buchen
        raise AssertionError("ambiguous")
    except Problem as e:
        assert "Mehrere" in str(e)
    # live state
    assert recording_status()["state"] == "idle"
    live_path = os.path.join(DIR, ".live.json")
    with open(live_path, "w", encoding="utf-8") as f:
        json.dump({"pid": os.getpid(), "state": "recording", "title": "Daily", "started": "2026-11-09T08:00:00Z",
                   "notes": "Budget!", "utterances": [{"start": 5, "text": "Hallo."}, {"start": 400, "text": "Budget."}]}, f)
    st = recording_status()
    assert st["state"] == "recording" and st["title"] == "Daily" and st["sentences"] == 2, st
    text = live_transcript(last_minutes=2)
    assert "[00:06:40] Budget." in text and "Hallo" not in text and "Budget!" in text, text
    assert "Hallo" in live_transcript() and not [m for m in list_meetings() if m["id"].startswith(".")]
    with open(live_path, "w", encoding="utf-8") as f:   # written by an app that crashed
        json.dump({"pid": 999999, "state": "recording", "title": "x", "started": "2026-11-09T08:00:00Z"}, f)
    assert recording_status()["state"] == "idle"
    try:
        live_transcript()
        raise AssertionError("stale")
    except Problem:
        pass
    # widget data
    m = meeting_data(sid)
    assert m["id"] == sid and m["transcript"][0] == {"t": "00:00:01", "speaker": "Johan", "text": "Wir reden über das Budget."}
    assert "Budget klären" in m["summary"] and "Raum buchen" in m["notes"]
    assert live_data()["state"] == "idle" and live_data()["utterances"] == []
    assert set(VIEWS) - {t.__name__ for t in TOOLS + list(APP_ONLY)} == set()   # no typo in VIEWS
    r = with_widget_data(get_meeting)(meeting_id="Sprint", parts=["summary"])
    assert r.content[0].text.startswith("# Sprint Review") and r.structured_content["transcript"][0]["speaker"] == "Johan"
    assert with_widget_data(recording_status)().structured_content["utterances"] == []
    print("mcp_server selftest ok")


def main():
    from mcp.server.apps import Apps
    from mcp.server.mcpserver import MCPServer   # mcp 2.x (FastMCP in 1.x)
    apps = Apps()
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "widget.html"), encoding="utf-8") as f:
        html = f.read()
    for view in sorted(set(VIEWS.values())):
        apps.add_html_resource(f"ui://meetingnotes/{view}.html", html.replace("__VIEW__", view), name=f"MeetingNotes {view}")
    plain = []
    for tool in TOOLS + list(APP_ONLY):
        if tool.__name__ in VIEWS:
            wrapped = with_widget_data(tool) if tool.__name__ in WIDGET_DATA else tool
            apps.tool(resource_uri=f"ui://meetingnotes/{VIEWS[tool.__name__]}.html",
                      visibility=["app"] if tool in APP_ONLY else None,
                      structured_output=None if wrapped is not tool else True)(wrapped)
        else:
            plain.append(tool)
    server = MCPServer("meetingnotes", extensions=[apps], instructions=(
        "Meetings aus der lokalen App MeetingNotes (Johans Mac): Transkripte (automatisch erkannt, Deutsch/Englisch/Portugiesisch, "
        "mit Hörfehlern), eigene Notizen, Zusammenfassungen mit Entscheidungen und To-dos. Zum Finden "
        "search_meetings oder list_meetings, dann get_meeting mit der id. Zitiere Zeitstempel, damit Johan in der "
        "App nachhören kann."))
    for tool in plain:
        server.tool()(tool)
    server.run()


if __name__ == "__main__":
    selftest() if "--selftest" in sys.argv else main()
