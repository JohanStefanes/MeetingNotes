# Plan: MCP-Server für MeetingNotes

Stand: 2026-11-09. Ziel: Claude Code und Claude Desktop lesen, durchsuchen, bearbeiten und steuern MeetingNotes.

## Entscheidungen

| Frage | Entscheidung | Grund |
|---|---|---|
| Clients | Claude Code + Claude Desktop (Chat), lokal | stdio reicht, kein Server im Netz |
| Bauweise | Python-Skript `Resources/mcp_server.py` im Bundle, offizielles `mcp`-SDK 2.x (`MCPServer`, hieß in 1.x FastMCP) | gleiche Art wie `summarize.py`, läuft auch ohne geöffnete App |
| Datenquelle | die Markdown-Dateien in `~/Meetings` (`MEETING_DIR`) | sie sind schon die Wahrheit; Vault ist nur ein generierter Spiegel |
| Suche | Volltext, Filter Datum/Projekt/Teilnehmer | Claude formuliert Synonyme selbst |
| Steuerung | URL-Schema `meetingnotes://` in der App | keine neue Abhängigkeit, `open -g` reicht |
| Live / Status | App schreibt `~/Meetings/.live.json` | Dotfile: die Meeting-Liste ignoriert es schon (`refresh()` filtert „.“) |

**Datenschutz:** Die Aufnahme und Verarbeitung bleibt lokal. Was Claude über ein Tool abruft (Transkript, Notizen), geht aber an das Claude-Modell. Das ist der Preis dieser Anbindung.

## Tools

IDs sind der Dateiname ohne `.md`, z. B. `2026-11-07_1952_Sprint-Strategie`. Tool-Namen englisch, Beschreibungen deutsch.

### Lesen

| Tool | Parameter | Liefert |
|---|---|---|
| `list_meetings` | `since?`, `until?`, `project?`, `participant?`, `limit=20` | id, Titel, Datum, Dauer, Projekt, Teilnehmer, hat Zusammenfassung, Anzahl offener To-dos |
| `search_meetings` | `query`, dieselben Filter, `limit=20` | Treffer mit Zeitstempel und Ausschnitt (Zeile ± 1); alle Wörter müssen vorkommen, wie die Suche in der App |
| `get_meeting` | `id`, `parts=[summary, notes, transcript]`, `start?`, `end?` (hh:mm:ss) | gewünschte Abschnitte; Transkript optional nur ein Zeitfenster (40 min ≈ 6.000 Wörter) |
| `list_todos` | `open_only=true`, `owner?`, `project?`, `since?` | To-dos aus den `- [ ]`/`- [x]`-Zeilen aller Meetings, mit id und Zeitstempel |

To-dos kommen aus der `.md`, nicht aus dem JSON: dort steht der abgehakte Zustand.

### Bearbeiten

| Tool | Wirkung |
|---|---|
| `update_meeting(id, title?, project?, notes?, append_notes?)` | Titel = Datei umbenennen mit derselben Slug-Regel wie `Recorder.slug` (inkl. `.json`); Projekt = `Projekt:`-Kopfzeile; Notizen ersetzen oder anhängen |
| `rename_speaker(id, old, new)` | dieselben Ersetzungen wie `Recorder.renameSpeaker` in `.md` und `.json` |
| `set_todo(id, text, done)` | hakt die passende To-do-Zeile ab oder auf (Treffer über Textanfang; mehrdeutig → Fehler mit Kandidaten) |
| `summarize(id)` | startet `summarize.py` (Ollama, ~1 min), gibt die neue Zusammenfassung zurück |

Alle Schreibvorgänge: lesen → ändern → atomar schreiben (Temp-Datei + `os.replace`). Während einer Aufnahme ist das laufende Meeting gesperrt.

### Steuern und live

| Tool | Wirkung |
|---|---|
| `recording_status()` | aus `.live.json`: idle / recording / labeling, Titel, Startzeit, Dauer |
| `start_recording(title?)` | `open -g "meetingnotes://start?title=…"`, wartet bis 5 s auf `.live.json` als Bestätigung |
| `stop_recording()` | `open -g meetingnotes://stop`; das fertige Meeting erscheint nach Sprechererkennung + Zusammenfassung |
| `live_transcript(last_minutes?)` | bisherige Sätze (ohne Sprecher, die kommen erst am Ende) plus die Notizen aus `.notes-<stamp>.md` |

`.live.json` enthält eine `pid`; läuft die App nicht mehr, gilt die Datei als veraltet (Absturz).

## Änderungen in der App (Swift)

1. **URL-Schema:** `CFBundleURLTypes` mit `meetingnotes` in `Info.plist`; `AppDelegate.application(_:open:)` verarbeitet `start` (mit Titel, sonst wie `toggle()`) und `stop`. Nur diese zwei Befehle, Rest ignorieren.
2. **`.live.json`:** `Recorder` schreibt die Datei bei Start, bei jedem `utt` (gedrosselt auf ~2 s) und beim Phasenwechsel; löscht sie, wenn das Meeting fertig ist.
3. **Ordner beobachten:** `DispatchSource` auf `~/Meetings`. Bei Änderung: `refresh()`, Vault-Spiegel der geänderten Dateien neu schreiben, ein offenes Meeting neu laden (`open(md)`). Grund: Sonst überschreibt die Notizen-Speicherung alle 1,5 s die Änderung von Claude und der Vault bleibt veraltet. Atomares Schreiben im MCP löst das Ordner-Ereignis zuverlässig aus.

## Einbau und Registrierung

- `mcp` ins venv: `~/.meeting-notes/venv/bin/pip install mcp` (Python 3.11 passt); `SetupCheck` prüft es.
- `scripts/build-app.sh` kopiert `mcp_server.py` mit ins Bundle.
- Claude Code:
  `claude mcp add meetingnotes -s user -- ~/.meeting-notes/venv/bin/python -I /Applications/MeetingNotes.app/Contents/Resources/mcp_server.py`
- Claude Desktop: derselbe Befehl in `~/Library/Application Support/Claude/claude_desktop_config.json`.

## Tests

- `mcp_server.py --selftest` mit einem Temp-Ordner als `MEETING_DIR`: list/search/todos, `rename_speaker`, Slug wie in Swift, `set_todo` mehrdeutig, `.live.json` veraltet.
- Von Hand: `claude mcp list`, dann in Claude Code „Was habe ich im Sprint-Meeting beschlossen?“, Notiz per Claude ändern, während das Meeting in der App offen ist.

## Reihenfolge

1. [x] Lesen + Registrierung (2026-11-09: 4 Tools, Selftest, in Claude Code und Claude Desktop eingetragen)
2. [x] Bearbeiten + Ordner-Beobachtung in der App (2026-11-09: update_meeting, rename_speaker, set_todo, summarize; App folgt Umbenennungen und spiegelt Änderungen in den Vault)
3. [x] URL-Schema + `.live.json` (2026-11-09: recording_status, start/stop_recording, live_transcript; URL-Befehle brauchen das Token aus `~/.meeting-notes/control-token`)
4. Widgets (MCP Apps)

## Phase 4: Widgets in Claude Desktop (MCP Apps)

MCP Apps (`io.modelcontextprotocol/ui`): Ein Tool verweist mit `_meta.ui.resourceUri` auf eine `ui://`-HTML-Ressource; Claude Desktop zeigt sie im Chat in einem abgeschotteten iframe. Das SDK hat das eingebaut (`mcp.server.apps.Apps`, `MCPServer(extensions=[apps])`). Claude Code im Terminal zeigt weiter nur Text, deshalb liefern alle Tools zusätzlich Text (`client_supports_apps(ctx)`).

| Widget | Tool | Inhalt | Klicks |
|---|---|---|---|
| Meeting-Karte | `get_meeting` | Zusammenfassung, To-dos, Transkript mit Sprecherfarben wie in der App | To-do abhaken, Sprecher umbenennen |
| To-do-Board | `list_todos` | offene To-dos, gruppiert nach Meeting oder Person (Board-Variante B der Roadmap-Vision) | abhaken, Meeting-Karte öffnen |
| Meeting-Liste | `list_meetings` / `search_meetings` | Liste mit Suchfeld, Filter Projekt/Person | Karte öffnen |
| Aufnahme | `recording_status` | Start/Stopp, Laufzeit, Live-Transkript, aktualisiert sich alle paar Sekunden | Start, Stopp |

- Ein HTML-Bundle für alle vier (eine Datei im Bundle, `ui://meetingnotes/app.html`), wählt die Ansicht nach dem Tool. Daten kommen nur aus Tool-Ergebnissen, kein Netzwerk; Klicks rufen über die Host-Brücke die Tools aus Phase 2/3 auf.
- Aussehen wie die App: Farben und Sprecherfarben aus `Design.swift` (`Theme`, `SpeakerColor`), Hell und Dunkel.
- Vorher prüfen: welche Bridge-Version Claude Desktop spricht (offizielles `@modelcontextprotocol/ext-apps` per CDN mit `csp.resourceDomains` oder eigene postMessage-Implementierung).

## Nicht in diesem Plan

- Aufnehmen mit dem Handy (2026-11-09 abgesagt; eine Datei geht von Hand mit `meeting datei.m4a`).
- claude.ai Web/Handy (bräuchte Remote-MCP mit Auth, z. B. auf jks).
- Semantische Suche.
