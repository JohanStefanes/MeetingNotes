# MeetingNotes

Eine macOS-Menüleisten-App, die Meetings mitschreibt, ohne dass Audio den Mac verlässt. Sie transkribiert live auf Deutsch und Englisch, erkennt die Sprecher und erstellt danach eine Zusammenfassung mit Entscheidungen und To-dos.

## Funktionen

- **Live-Transkript**: Silero VAD teilt das Gesagte in Sätze. whisper-tiny erkennt pro Satz die Sprache (DE/EN), large-v3-turbo transkribiert über einen lokalen `whisper-server` (Metal / Core ML). Weil die Sprache pro Satz bestimmt wird, übersetzt Whisper die zweite Sprache nicht.
- **Mikrofon und Mac-Ton**: Core Audio Process Taps (macOS 14.2+) nehmen Zoom, Teams usw. ohne BlackHole auf. Mikrofon links und System rechts ergibt „Ich“ gegenüber den anderen ohne Zusatzaufwand.
- **Sprechererkennung** nach dem Meeting mit [FluidAudio](https://github.com/FluidInference/FluidAudio) auf Core ML (40 min Audio in ~15 s). Sprecher lassen sich umbenennen. Eine Stimmprobe erkennt dich auch ohne Mac-Ton.
- **Zusammenfassung**: Entscheidungen, To-dos mit Verantwortlichen, offene Punkte. Lokal über Ollama (Standard) oder über die Claude-API.
- **Kalender** (EventKit): Titel und Teilnehmer aus dem aktuellen Termin, Hinweis „Meeting aufnehmen?“, wenn ein Call das Mikrofon nutzt, und automatischer Stopp nach dem Call.
- **Eigenes Wörterbuch** für Namen und Fachbegriffe, Volltextsuche, Projekte als Ordner.
- **Claude-Anbindung**: ein MCP-Server zum Suchen, Lesen und Bearbeiten von Meetings und To-dos, mit Widgets für Claude Desktop. Optional ein Spiegel in einen Obsidian-Vault.

Meetings werden als Markdown in `~/Meetings` gespeichert, das Audio als m4a in `~/Meetings/audio`.

## Voraussetzungen

- macOS 14.2 oder neuer, Apple Silicon
- Xcode bzw. Swift 6.2
- `ffmpeg` und `whisper-server` aus [whisper.cpp](https://github.com/ggml-org/whisper.cpp), z. B. `brew install ffmpeg whisper-cpp`
- Modelle in `~/.whisper-models` (oder `WHISPER_MODELS`): `ggml-large-v3-turbo.bin`, `ggml-silero-v5.1.2.bin`
- Python-venv in `~/.meeting-notes/venv` mit `numpy`, `sherpa-onnx`; optional `mcp` (MCP-Server) und `anthropic` (Zusammenfassung über Claude)
- optional [Ollama](https://ollama.com) mit `qwen2.5:14b-instruct` für lokale Zusammenfassungen

Beim Start prüft die App, was fehlt, und zeigt es an. Das Log liegt in `~/Library/Logs/MeetingNotes.log`.

## Bauen

```bash
make app       # baut build/MeetingNotes.app
make run       # bauen und starten
make install   # nach /Applications kopieren und starten
```

Mit einer „Apple Development“-Signatur bleibt die Mikrofon-Freigabe über Rebuilds erhalten. Sonst signiert das Skript ad hoc, und macOS fragt nach jedem Build erneut.

## Bedienung

- **⌃⌥Leertaste** startet und stoppt eine Aufnahme. Eine schwebende Pill zeigt den Live-Untertitel.
- Im Notizfenster schreibst du eigene Notizen während des Meetings, sie werden alle 1,5 s gespeichert.
- Danach: Tabs für Notizen, Transkript und Zusammenfassung. Ein Klick auf einen Sprechernamen benennt ihn um.

Ohne App geht es auch im Terminal mit `Resources/meeting` (Aufnahme bis Ctrl+C oder eine vorhandene Datei transkribieren).

## MCP-Server (Claude)

```bash
claude mcp add meetingnotes -s user -- ~/.meeting-notes/venv/bin/python -I /Applications/MeetingNotes.app/Contents/Resources/mcp_server.py
```

Tools unter anderem: `list_meetings`, `search_meetings`, `get_meeting`, `list_todos`, `update_meeting`, `rename_speaker`, `summarize`, `start_recording`, `stop_recording`. Details in [MCP.md](MCP.md).

Datenschutz: Aufnahme, Transkription und Sprechererkennung laufen lokal. Was Claude über ein Tool abruft oder was du über die Claude-API zusammenfassen lässt, geht an das Claude-Modell.

## Projektstruktur

| Pfad | Inhalt |
|---|---|
| `Sources/MeetingNotes/` | die App (SwiftUI/AppKit, Aufnahme, Fenster, Kalender, System-Audio) |
| `Sources/meeting-diarize/` | Swift-Helfer für die Sprechererkennung (FluidAudio) |
| `Resources/engine.py` | Live-Transkription (VAD, Spracherkennung, whisper-server) |
| `Resources/diarize.py` | Sprecher den Sätzen zuordnen, Stimmprobe |
| `Resources/summarize.py` | Zusammenfassung (Ollama / Claude) |
| `Resources/mcp_server.py`, `widget.html` | MCP-Server und Widgets |
| `Resources/meeting` | Aufnahme- und Transkriptions-Skript |
| `tests/` | Vorlesetexte und Vergleichsskripte |

Die Python-Skripte haben Selbsttests: `python Resources/engine.py --selftest` (ebenso `diarize.py`, `summarize.py`).

Was geplant ist und was schon erledigt ist, steht in [ROADMAP.md](ROADMAP.md).

## Lizenz

[MIT](LICENSE)
