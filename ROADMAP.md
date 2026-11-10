# Roadmap: Richtung Wispr Flow Notetaker

Stand: 2026-11-10. Ziel: so nah wie möglich an Wispr Flows Notetaker, aber alles lokal.

## Heute

- Menüleisten-App, ⌃⌥Leertaste global, schwebende Pill mit Live-Untertitel, Notizfenster (Notizen / Transkript / Zusammenfassung), Meeting-Liste mit Suche und Projekt-Filter.
- Audio: Mikrofon und Mac-Ton (Process Tap) auf getrennten Kanälen, gespeichert als m4a (~25 MB/h).
- Engine: Silero VAD → whisper-tiny erkennt DE/EN pro Satz → large-v3-turbo über residenten whisper-server (Metal / Core ML), Aufhol-Bündelung.
- Live-Text Wort für Wort (2026-11-10): whisper-tiny liefert alle ~0,4 s einen grauen Zwischenstand (`partial`), den der fertige Satz ersetzt.
- Sprechererkennung offline nach dem Meeting: `meeting-diarize` (Swift, FluidAudio auf Core ML), ~15 s für 40 min. „Ich“ über den Mikrofon-Kanal oder die Stimmprobe.
- Zusammenfassung (`summarize.py`, Ollama oder Claude), Kalender über EventKit, eigenes Wörterbuch, Setup-Check.
- Ausgabe: Markdown in `~/Meetings`, gespiegelt nach `~/Vault/Meetings`. MCP-Server `mcp_server.py` für Claude (siehe [MCP.md](MCP.md)).

## Stärken (behalten)

- 100 % lokal: Verkaufsargument gegenüber Wispr.
- Spracherkennung pro Satz verhindert, dass whisper die zweite Sprache übersetzt.
- Text wird vor der Sprechererkennung geschrieben: kein Textverlust.
- Selftests für pack / glue / split / assign / render.

## Lücken

Die zehn Lücken vom 2026-11-07 (System-Audio, Zusammenfassung, Notizen nur im RAM, Bearbeiten, Sprechernamen, Kalender, Wörterbuch, Setup, Suche/Claude, Pegel/WAV-Größe) sind alle gelöst, siehe Roadmap-Punkte 1–9. Sprachen: DE/EN, seit 2026-11-10 auch Portugiesisch (brasilianisch, über den Prompt).

## Roadmap (Wirkung pro Aufwand)

- [x] 1. **System-Audio nativ** (2026-11-07: Process Tap + Aggregat-Gerät, Stereo-WAV links Mikro / rechts Mac-Ton, „Ich“ = eigener Vorname): Core Audio Process Taps (macOS 14.2+) oder ScreenCaptureKit. Mikrofon und System auf getrennten Kanälen → „Ich vs. Andere“ gratis.
- [x] 2. **Zusammenfassung nach dem Meeting** (2026-11-07: `summarize.py`, Ollama qwen2.5:14b oder Claude, JSON + Markdown, Tab in der App): Entscheidungen, To-dos mit Verantwortlichen, offene Punkte. Lokal über Ollama/MLX (Qwen 3 / Gemma), optional Claude-API. Als `## Zusammenfassung` in die .md.
- [x] 3. **Notizen laufend speichern** (2026-11-07: alle 1,5 s, Titel/Notizen alter Meetings bearbeitbar) (alle paar Sekunden) und vergangene Meetings bearbeitbar machen.
- [x] 4. **Sprecher umbenennen** (2026-11-07: Klick auf Namen; Fragment-Sprecher werden zusammengelegt, 121 → 5 im Testmeeting). Stimmprobe (2026-11-08, Menü „Stimmprobe aufnehmen“) erkennt dich auch ohne Mac-Ton; Teilnehmerzahl aus dem Kalender begrenzt die Sprecher in der UI (Name wird in die Datei übernommen); später eigene Stimmprobe speichern → „Johan“ automatisch.
- [x] 5. **Kalender über EventKit** (2026-11-07: Titel + Teilnehmer, Hinweis per Pill und Mitteilung). Auto-Stopp 20 s nach Call-Ende (2026-11-08): Titel und Teilnehmer übernehmen; Hinweis „Meeting aufnehmen?“, wenn Zoom/Teams das Mikrofon nutzt.
- [x] 6. **Eigenes Wörterbuch** (2026-11-07: `~/Meetings/Wörterbuch.txt`, Menü „Wörterbuch bearbeiten“): Begriffsliste + Teilnehmernamen in den whisper-Prompt.
- [x] 7. **Claude-Anbindung billig** (2026-11-08: `~/Vault/Meetings`, automatisch gespiegelt, Index mit Dataview): Meetings in `~/Vault` schreiben. Seit 2026-11-09 zusätzlich eigener MCP-Server `mcp_server.py` (Lesen, Suchen, To-dos, Aufnahme steuern), siehe [MCP.md](MCP.md).
- [x] 8. **Setup-Check beim Start** (2026-11-08: Warnung im Panel und in der Meeting-Liste, Log in `~/Library/Logs/MeetingNotes.log`): Modelle, ffmpeg, whisper-server prüfen und klar anzeigen, was fehlt; stderr in eine Logdatei.
- [x] 9. Suche, Ordner, Audio als m4a (2026-11-08: Volltextsuche, „Projekt“ als Ordner/Filter, AAC ~25 MB/h). Pegelanzeige folgt jetzt dem gewählten Mikrofon.

Punkte 1–3 bringen den größten Sprung, 4–6 machen es zum echten Notetaker.

### Offen: mit echtem Einsatz testen (Stand 2026-11-08)

- [ ] Stimmprobe mit Johans Stimme aufnehmen (⋯-Menü → „Stimmprobe aufnehmen …“), danach ein Meeting vor Ort ohne Mac-Ton: wird „Johan“ erkannt?
- [ ] Vorlesetests: `tests/texte/*.txt` aufnehmen, mit `tests/compare.py` vergleichen; Dialog mit `tests/dialog.sh`. Falsche Wörter ins Wörterbuch.
- [ ] Echter Call (Zoom/Teams): Hinweis „Meeting aufnehmen?“ erscheint, Auto-Stopp ~20 s nach Ende. Prüfen, ob Teams-Stummschaltung den Auto-Stopp fälschlich auslöst.
- [ ] Kalender: Zugriffsabfrage, Titel/Teilnehmer und Sprecher-Obergrenze aus einem echten Termin.
- [ ] Sprecher im Meeting 2026-11-07_1952 in der App umbenennen, damit die Namen im Vault-Frontmatter landen.

### Spike FluidAudio (2026-11-08, M1 Pro)

FluidAudio (Swift, Core ML, MIT/Apache) gegen den heutigen Python-Pfad. Testdaten: Dialog aus `tests/texte/05-dialog.txt` mit 3 Mac-Stimmen (129 s, bekannte Sprecherwechsel), Meeting 2026-11-07_1952 (40 min), Texte 01–04 mit `say -v Anna`.

| | sherpa-onnx (heute) | FluidAudio offline |
|---|---|---|
| Dialog: Zeit | 12,9 s | 1,1 s |
| Dialog: Sprecher verwechselt | 4,9 % | 1,2 % |
| Meeting 40 min: Zeit | 290 s | 13 s |
| Meeting 40 min: RAM-Spitze | 2,3 GB | 0,5–0,8 GB |
| Meeting: Sprecher | 2 | 3 |

FluidAudio-Streaming-Modus: 47 % DER, unbrauchbar. Offline ausgelassene Satzränder (15 %) sind egal, weil `assign` whisper-Sätze ohnehin dem nächsten Abschnitt zuordnet.

ASR (WER mit `tests/compare.py`, ohne Wörterbuch): whisper large-v3-turbo 12,1 % gesamt, Parakeet ultra 11,7 %, v3 13,1 %. Bei DE/EN gemischt verliert Parakeet klar (whisper 7,8 %, ultra 18,2 %: Englisch wird eingedeutscht), egal ob mit oder ohne `--language de`. Parakeet ist ~80× schneller als Echtzeit.

→ **Sprechererkennung auf FluidAudio umstellen**, **whisper behalten**: Die Spracherkennung pro Satz ist bei DE/EN-Mix besser als Parakeet.

- [x] Umgestellt (2026-11-09): Hilfsprogramm `meeting-diarize` im Bundle, `diarize.py` ruft es auf, `absorb`/„Ich“/Stimmprobe/`assign` unverändert. Schwellen neu gemessen (`ME_SIMILARITY` 0,7, `ME_TURN` 0,65, `MERGE_SIMILARITY` 0,85). Test: `tests/speakers.py` (3 Mac-Stimmen, 1,4 % falsch zugeordnet, „Ich“ 27/27).
- Echtes Meeting 2026-11-07_1952: 81 % der Absätze gleich wie vorher. Die Abweichung: alte „Sprecher 1“ und „Sprecher 2“ landen jetzt meist bei einer Person; beide Stimmmodelle sehen die zwei als fast gleiche Stimme (0,88–0,91, gleiche Person 0,94–0,97). Vermutlich hat sherpa eine Person geteilt; per Gehör bestätigen.
- sherpa-onnx bleibt im venv: die Engine nutzt es für whisper-tiny (DE/EN-Erkennung).
- [ ] Nach ~1 Woche echtem Einsatz löschen: `~/.meeting-notes/models/sherpa-onnx-pyannote-segmentation-3-0` und `3dspeaker_speech_campplus_…onnx`.
- [x] Verwaiste whisper-server (2026-11-09): je ~4 GB, 5 Stück liefen nach abgebrochenen Engine-Läufen weiter (~20 GB). Jetzt startet ein sh-Wächter den Server und beendet ihn, sobald die Engine endet, auch bei SIGKILL. Test: `tests/server_cleanup.py`.
- [ ] Knopf „Es waren N Leute“ im Notizfenster: `meeting-diarize --speakers N` rechnet in Sekunden neu.

### Nächste Schritte (aus der Analyse eines 46-Min-Meetings, 2026-11-10)

- [x] Kurze Satzenden landeten fälschlich bei „Ich“ (über 30 Stück). Behoben: „Ich“ nur, wenn der Mac-Ton still ist **und** das Mikrofon Stimme hat (`MIC_VOICE` in `diarize.py`).
- [x] Live-Text Wort für Wort statt ~8–10 s verzögert und satzweise.
- [x] Audio wurde beim Umwandeln nach m4a nach ~1–1,5 min abgeschnitten und die WAV gelöscht (Meeting 2026-11-09_1832: nur 65 s von 47 min). Ursache: das Stopp-„q“ der App blieb in stdin liegen und beendete das Umwandlungs-ffmpeg. Fix 2026-11-10: `-nostdin`, WAV wird nur gelöscht, wenn die m4a gleich lang ist.
- [ ] Ton beginnt teils Minuten nach dem Start der Aufnahme (DAPP Sync 2026-11-10: ~5½ min). Vermutlich neue Mac-Ton-Freigabe nach einem Neubau; prüfen.
- [ ] Beides in einem echten Meeting prüfen. `MIC_VOICE` (0,01) ist geschätzt; mit `MEETING_KEEP_WAV=1` am eigenen Mikrofon messen.
- [ ] Sprecherwechsel: Ganze Sätze landen am Wechsel beim falschen Sprecher (z. B. 18:51, 31:25, 42:54). Satz am Wechsel nach Zeitanteil aufteilen oder neu zuordnen.
- [x] Schweizerdeutsch wird als Englisch erkannt und ergibt Unsinn. Seit 2026-11-10: Ein englisches Ergebnis mit schwacher Sicherheit (`LANG_DOUBT`, avg_logprob < -0,5; gilt auch für Portugiesisch) wird zusätzlich als Deutsch transkribiert, das wahrscheinlichere gewinnt. Schwelle geschätzt, an echter Aufnahme prüfen.
- [x] Erfundene Sätze filtern (z. B. „Wir sehen uns im Video“): Sperrliste `PHANTOM` in `engine.py` (2026-11-10). Offen: Pegel-Abgleich für Floskeln, die nicht auf der Liste stehen.
- [x] Wörterbuch ergänzt (2026-11-10): Vercel, Simli, Four-Part Sketch, Issue-Liste, Feature, Go/No-Go u. a.
- [ ] Zusammenfassung: Es gab ein falsches To-do, und Kernpunkte fehlten (Deadlines, Go/No-Go). Prompt schärfen und Fristen ausdrücklich abfragen.
- [ ] Optional: Zwischenstand aus dem Live-Text auch in der schwebenden Pill zeigen.

## Vision: Meeting → Board → Workflow

Irgendwann: Ein Meeting wird transkribiert, daraus entstehen automatisch Ideen, Issues, Entscheidungen und To-dos. Alles landet zuerst als Sticky Notes auf einem Board (Spalten wie bei einem Business Model Canvas, aber mit Meeting-Inhalt). Dort prüft und verschiebt man die Notes und schickt sie erst dann weiter.

```
Transkript → Extraktion (LLM, strukturiertes JSON) → Board (Staging) → Freigabe → Ziele
```

- **Extraktion**: Dieselbe LLM-Stufe wie Roadmap-Punkt 2, aber mit strukturierter Ausgabe statt nur Fließtext. Jedes Item hat Typ (Idee / Issue / Entscheidung / To-do / offene Frage), Text, Verantwortliche, Zeitstempel im Transkript (zurückspringen zur Stelle) und Sprecher.
  → Punkt 2 deshalb gleich als JSON + Markdown bauen, dann ist die Vision nur noch eine weitere Ausgabe.
- **Board als Staging**: Spalten pro Typ, eine Sticky Note pro Item. Nichts geht ungeprüft raus.
  - Variante A: Miro-Board über die vorhandene Miro-MCP (schnell, kein eigenes UI).
  - Variante B: eigenes Board im Notizfenster (SwiftUI, Drag & Drop), bleibt lokal.
- **Ziele nach Freigabe**: Issues → GitHub / Linear, Ideen und Entscheidungen → `~/Vault`, To-dos → TickTick / Erinnerungen (z. B. über Morph).
- **Board-Vorlagen pro Meeting-Typ** (z. B. Kundencall, Brainstorming, Sprint-Planung) bestimmen die Spalten.

Voraussetzungen: Punkte 2 (Extraktion), 4 (Sprechernamen) und 5 (Kalender-Kontext) aus der Roadmap.

### Rolle von jks (Server)

jks: 4 Kerne, 7 GB RAM, 205 GB frei, nur Intel HD 520 (keine GPU), Tailscale vorhanden. Stand 2026-11-07.

Faustregel: **Rechnen auf dem Mac, Dauerbetrieb und Ablage auf jks.**

- **Nicht auf jks**: whisper, Sprechererkennung, LLM. Viel zu langsam ohne GPU, bleibt auf dem Mac.
- **Board hosten**: kleine Web-App für die Sticky Notes, über Tailscale auch vom Handy erreichbar. Lokale Alternative zu Miro (Variante B, aber überall verfügbar).
- **Workflow-Runner**: Der Mac schickt nach dem Meeting das Extraktions-JSON an jks. Nach Freigabe erstellt jks Issues (GitHub / Linear) und To-dos, auch wenn der Mac zu ist.
- **Vault**: synchronisiert schon mit jks. Meeting-Notizen in `~/Vault` sind damit automatisch überall verfügbar.
- **Telegram**: Alerts laufen auf jks schon. Erweitern zu „Meeting fertig, 5 Items zur Freigabe“, Freigabe direkt im Chat.
- **Audio-Archiv**: alte Aufnahmen auf jks auslagern (m4a ~25 MB/h).

Zu beachten: Sobald Audio oder Transkripte auf jks liegen, gilt „alles bleibt auf deinem Mac“ nicht mehr, sondern „alles bleibt bei dir“. Ohne Off-site-Backup ist jks dann die einzige Kopie dieser Daten.

## Referenz Wispr Flow Notetaker (laut Wispr-Doku, Aug 2026)

System-Audio ohne Bot im Call, Live-Transkript, nachträglich verfeinert mit Sprechernamen, Zusammenfassung mit Entscheidungen/Deadlines/Aufgaben, persönliches Wörterbuch, Kontext aus Kalender/Slack, schwebender Notizblock, Notizen/Summary/Titel nachträglich bearbeitbar, Anbindung an Claude/ChatGPT.
Quellen: https://wisprflow.ai/post/wispr-flow-notetaker · https://docs.wisprflow.ai/articles/3665250541-getting-started-with-notetaker-beta
