import AVFoundation
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct MeetingNotesApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @StateObject private var rec = Recorder.shared

    init() {
        if CommandLine.arguments.contains("--selftest") { selftest(); exit(0) }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(rec).environmentObject(rec.meter).environmentObject(rec.live)
        } label: {
            Image(systemName: rec.state == .recording ? "record.circle.fill"
                  : rec.state == .transcribing ? "ellipsis.circle" : "waveform")
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Einstellungen …") { SettingsWindow.shared.show() }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Neue Notiz") { rec.newNote() }.keyboardShortcut("n").disabled(rec.state != .idle)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pill: PillPanel?

    @MainActor func applicationDidFinishLaunching(_ note: Notification) {
        let rec = Recorder.shared
        pill = PillPanel(PillView().environmentObject(rec).environmentObject(rec.meter).environmentObject(rec.live))
        pill?.orderFrontRegardless()
        registerHotKey { Recorder.shared.toggle() }
        if !launchedAsLoginItem { NoteWindow.shared.show() }   // at login it should just sit in the menu bar
        signal(SIGPIPE, SIG_IGN)   // writing into the audio FIFO after ffmpeg quit must not kill the app
        for md in rec.recent where !FileManager.default.fileExists(atPath: VaultMirror.noteURL(for: md).path) {
            VaultMirror.write(md)   // meetings from before the vault mirror existed
        }
        MeetingContext.shared.requestCalendar()
        if rec.recent.map(rec.autoTitle).contains(where: { !rec.recent.contains($0) }) { rec.refresh() }   // titles that arrived while the app was closed
        // a call app took the microphone → offer to record (pill + notification), once per call
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in
                let rec = Recorder.shared
                let d = UserDefaults.standard
                // the call app that was recording with us let go of the mic for ~20 s: the call is over
                if rec.state == .recording, let app = rec.recordingCall, d.object(forKey: "autoStop") as? Bool ?? true {
                    rec.callGoneTicks = MeetingContext.shared.activeCall() == nil ? rec.callGoneTicks + 1 : 0
                    if rec.callGoneTicks * 3 >= (d.object(forKey: "autoStopDelay") as? Int ?? 20) {
                        rec.stop()
                        Notifier.shared.callEnded(MeetingContext.appName(app))
                    }
                }
                guard rec.state == .idle, d.object(forKey: "detectMeetings") as? Bool ?? true else {
                    rec.detectedCall = nil; return
                }
                let call = MeetingContext.shared.activeCall()
                if let call, rec.detectedCall == nil {
                    Notifier.shared.offerRecording("\(MeetingContext.appName(call)) nutzt das Mikrofon. Aufnehmen?")
                } else if call == nil, d.object(forKey: "calendarReminder") as? Bool ?? true,
                          let event = MeetingContext.shared.startingEvent() {
                    Notifier.shared.offerRecording("„\(event.title ?? "Termin")“ beginnt. Aufnehmen?", title: "Termin beginnt")
                }
                rec.detectedCall = call
            }
        }
    }

    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ note: Notification) {
        // the launch Apple Event is only readable here; launchIsDefaultUserInfoKey proved unreliable after relaunches
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem = event?.eventID == AEEventID(kAEOpenApplication)
            && event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    // meetingnotes://start?token=…&title=… and meetingnotes://stop?token=…, sent by mcp_server.py
    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { Recorder.shared.handleControl(url) }
    }

    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NoteWindow.shared.show()   // the floating pill counts as a visible window, so always show the note window
        return true
    }
}

// ⌃⌥Space anywhere toggles recording. Carbon hot keys need no Accessibility permission.
private var hotKeyAction: (() -> Void)?
private var hotKeyRef: EventHotKeyRef?

func registerHotKey(_ action: @escaping () -> Void) {
    hotKeyAction = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { hotKeyAction?() }
        return noErr
    }, 1, &spec, nil, nil)
    RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                        EventHotKeyID(signature: OSType(0x4D4E4F54), id: 1),  // 'MNOT'
                        GetApplicationEventTarget(), 0, &hotKeyRef)
}

// Runs Resources/meeting (record → whisper.cpp) and follows its stdout.
@MainActor
final class Recorder: ObservableObject {
    static let shared = Recorder()
    enum State { case idle, recording, transcribing }

    @Published var state = State.idle
    @Published var started = Date()
    @Published var stoppedAt = Date()
    @Published var title = ""
    @Published var lastResult: URL?
    @Published var justFinished = false
    @Published var error: String?
    @Published var recent: [URL] = []
    @Published var previews: [URL: String] = [:]   // first words of each transcript, for the meeting list
    @Published var notes = "" { didSet { if notes != oldValue { scheduleNotesSave() } } }   // "Notizen" tab
    @Published var summary = ""      // "## Zusammenfassung" section of the open meeting
    @Published var summarizing = false
    @Published var viewing: URL?     // past meeting open in the note window (editable)
    @Published var detectedCall: String?   // bundle ID of a call app using the mic while idle
    @Published var project = ""      // "Projekt:" of the open meeting; groups meetings like folders
    @Published var projects: [URL: String] = [:]
    @Published var durations: [URL: Double] = [:]   // seconds to the last transcript line
    @Published var setupProblems: [String] = []
    private(set) var texts: [URL: String] = [:]   // lowercased content, for the search field
    var recordingCall: String?       // call app that was using the mic when recording started (auto-stop)
    var callGoneTicks = 0
    let meter = Meter()
    let live = LiveTranscriber()

    let outDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Meetings")
    private var proc: Process?
    private var input: Pipe?
    private var buffer = ""
    private var lastLine = ""
    private var silent = false   // the script found no speech and wrote no meeting
    private var startName = ""
    private var notesFile: URL?      // notes of the running meeting, saved continuously (survives a crash)
    private var notesSave: DispatchWorkItem?
    private var systemAudio: SystemAudio?
    private var fifo: URL?

    init() {
        Notifier.shared.setup()
        refresh()
        watchFolder()
        _ = Self.controlToken   // mcp_server.py needs it before the first command
    }

    // MARK: remote control (mcp_server.py)

    /// Secret in ~/.meeting-notes/control-token (only this user can read it). Without it a web page or another
    /// app could start a recording through the URL scheme.
    static let controlToken: String = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".meeting-notes/control-token")
        if let t = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), t.count >= 32 {
            return t
        }
        let t = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
        return t
    }()

    func handleControl(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in query.first { $0.name == name }?.value }
        guard url.scheme == "meetingnotes", value("token") == Self.controlToken else {
            Self.log("Steuerbefehl ohne gültiges Token ignoriert: \(url.host ?? "")"); return
        }
        switch url.host {
        case "start" where state == .idle:
            let d = UserDefaults.standard
            start(name: value("title") ?? "", device: d.string(forKey: "device") ?? "default", mix: d.string(forKey: "mix") ?? "")
        case "stop": stop()
        default: break
        }
    }

    static func log(_ line: String) {
        if let h = try? FileHandle(forWritingTo: logFile) { h.seekToEndOfFile(); h.write(Data("\(Date()) \(line)\n".utf8)); try? h.close() }
    }

    // MARK: live state for mcp_server.py (~/Meetings/.live.json, only while a meeting runs)

    private var liveWrite: DispatchWorkItem?
    private var liveURL: URL { outDir.appendingPathComponent(".live.json") }

    private func scheduleLiveFile(now: Bool = false) {
        if now { liveWrite?.cancel(); liveWrite = nil; writeLiveFile(); return }
        guard liveWrite == nil else { return }   // at most one write every 2 s
        let work = DispatchWorkItem { [weak self] in self?.liveWrite = nil; self?.writeLiveFile() }
        liveWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func writeLiveFile() {
        guard state != .idle else { try? FileManager.default.removeItem(at: liveURL); return }
        let info: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "state": state == .recording ? "recording" : "transcribing",
            "title": title, "started": ISO8601DateFormatter().string(from: started), "notes": notes,
            "utterances": live.bubbles.map { ["start": $0.start, "text": $0.text] },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) {
            try? data.write(to: liveURL, options: .atomic)
        }
    }

    // MARK: changes from outside (Claude via mcp_server.py, Obsidian, Finder)

    private var folderWatch: DispatchSourceFileSystemObject?
    private var folderChange: DispatchWorkItem?
    private var seen: [URL: Date] = [:]   // modification dates of the meetings at the last look

    /// Atomic writes (ours, mcp_server.py) replace the file, which changes the folder itself: one watch is enough.
    private func watchFolder() {
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let fd = Darwin.open(outDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        seen = mtimes()
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            self?.folderChange?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.folderChanged() }
            self?.folderChange = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        folderWatch = src
    }

    private func mtimes() -> [URL: Date] {
        let files = (try? FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return Dictionary(uniqueKeysWithValues: files
            .filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix(".") }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) })
    }

    private func folderChanged() {
        let now = mtimes()
        guard now != seen else { return }   // e.g. only the hidden notes file of a running meeting
        for (url, date) in now where seen[url] != date { VaultMirror.write(url) }
        for url in seen.keys where now[url] == nil { VaultMirror.remove(url) }
        if let md = viewing, now[md] == nil,   // renamed outside: follow it by its "<date>_<time>" prefix
           let moved = now.keys.first(where: { $0.lastPathComponent.hasPrefix(String(md.lastPathComponent.prefix(15))) }) {
            viewing = moved; lastResult = moved; title = meetingName(moved)
        }
        if let md = viewing, seen[md] != now[md], state == .idle, notesSave == nil || notesSave!.isCancelled {
            open(md)   // not while notes are waiting to be saved: that would drop what was just typed
        }
        seen = now
        refresh()
    }

    static let defaultMeName = NSFullUserName().split(separator: " ").first.map(String.init) ?? "Ich"

    static func inputDevices() -> [String] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                         position: .unspecified).devices.map(\.localizedName)
    }

    func start(name: String, language: String = UserDefaults.standard.string(forKey: "language") ?? "de", device: String, mix: String) {
        // the engine picks German or English per sentence; -l only matters for the fallback whole-file pass
        guard let script = Bundle.main.url(forResource: "meeting", withExtension: nil) else {
            error = "meeting-Skript fehlt im App-Bundle."; return
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in
                if ok { self.launch(script, name, language, device, mix) }
                else { self.error = "Kein Mikrofonzugriff – Systemeinstellungen › Datenschutz › Mikrofon." }
            }
        }
    }

    private func launch(_ script: URL, _ typedName: String, _ language: String, _ device: String, _ mix: String) {
        let d = UserDefaults.standard
        let event = MeetingContext.shared.currentEvent()
        let name = typedName.isEmpty ? (event?.title ?? "") : typedName
        var args = [script.path, "-l", language]

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"  // GUI apps get no Homebrew PATH
        // the title first: it names the project ("DAPP Sync"), which whisper otherwise hears as "DA40"
        env["MEETING_VOCAB"] = MeetingContext.vocab(own: (name.isEmpty ? [] : [name]) + MeetingContext.shared.vocabulary(),
                                                    attendees: MeetingContext.attendeeNames(event))
        if let people = MeetingContext.headcount(event) { env["MEETING_ATTENDEES"] = String(people) }   // caps speaker count
        env["MEETING_PEOPLE"] = MeetingContext.attendeeNames(event).joined(separator: ", ")
        env["MEETING_ME_NAME"] = d.string(forKey: "meName").flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultMeName
        env["MEETING_SUMMARY"] = d.string(forKey: "summary") ?? "ollama"
        env["MEETING_SUMMARY_MODEL"] = d.string(forKey: "summaryModel").flatMap { $0.isEmpty ? nil : $0 }
        if d.integer(forKey: "speakers") > 0 { env["MEETING_SPEAKERS"] = String(d.integer(forKey: "speakers")) }
        let stamp = Int(Date().timeIntervalSince1970)
        let notesURL = outDir.appendingPathComponent(".notes-\(stamp).md")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try? Data().write(to: notesURL)
        env["MEETING_NOTES"] = notesURL.path

        // Mac sound + mic as one stereo stream; falls back to the plain mic (and optional 2nd device) if unavailable
        var sys: SystemAudio?
        let uid = device == "default" ? nil : AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.first { $0.localizedName == device }?.uniqueID
        if d.object(forKey: "systemAudio") as? Bool ?? true {
            let fifoURL = FileManager.default.temporaryDirectory.appendingPathComponent("meetingnotes-\(stamp).fifo")
            do {
                let s = try SystemAudio(micUID: uid)
                guard mkfifo(fifoURL.path, 0o600) == 0 else { throw SystemAudio.Failure("mkfifo") }
                sys = s; fifo = fifoURL
                env["MEETING_FIFO"] = fifoURL.path
                args += ["-s", String(Int(s.sampleRate))]
            } catch {
                self.error = "Nur Mikrofon: \(error.localizedDescription)"
            }
        }
        if sys == nil {
            args += ["-d", device]
            if !mix.isEmpty { args += ["-m", mix] }
        }
        let slug = Self.slug(name)
        if !slug.isEmpty { args.append(slug) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = args
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe   // ffmpeg reads "q" from stdin to stop cleanly
        p.standardOutput = outPipe
        p.standardError = FileHandle(forWritingAtPath: Self.logFile.path) ?? FileHandle.nullDevice
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let s = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self.consume(s) }
        }
        p.terminationHandler = { p in
            let status = p.terminationStatus
            Task { @MainActor in self.finished(status) }
        }
        do { try p.run() } catch {
            self.error = "Start fehlgeschlagen: \(error.localizedDescription)"
            sys?.stop(); removeFifo(); return
        }
        if let sys, let fifo {
            systemAudio = sys
            DispatchQueue.global(qos: .userInitiated).async {
                do { try sys.start(fifo: fifo.path) }   // blocks until ffmpeg opens the FIFO
                catch { Task { @MainActor in self.error = error.localizedDescription; self.systemAudio?.stop() } }
            }
        }

        proc = p; input = inPipe; buffer = ""; lastLine = ""; silent = false
        if sys != nil { error = nil }
        lastResult = nil; viewing = nil; summary = ""
        notesFile = notesURL
        notes = ""
        startName = name
        title = name.isEmpty ? "Meeting" : name
        started = Date()
        state = .recording
        recordingCall = MeetingContext.shared.activeCall() ?? detectedCall
        callGoneTicks = 0
        detectedCall = nil
        project = ""
        NSSound(named: "Pop")?.play()
        meter.start(deviceUID: uid)
        live.reset()
        scheduleLiveFile(now: true)
        NoteWindow.shared.show()
    }

    static let logFile: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MeetingNotes.log")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        return url
    }()

    static func slug(_ name: String) -> String {
        name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
    }

    // used by the hot key and the floating pill: same settings as the panel, no name
    func toggle() {
        switch state {
        case .idle:
            let d = UserDefaults.standard
            start(name: "", device: d.string(forKey: "device") ?? "default", mix: d.string(forKey: "mix") ?? "")
        case .recording: stop()
        case .transcribing: break
        }
    }

    func stop() {
        guard state == .recording, let p = proc else { return }
        stoppedAt = Date()
        NSSound(named: "Tink")?.play()
        saveNotesNow()   // the script copies the notes file into the meeting
        input?.fileHandleForWriting.write(Data("q".utf8))
        systemAudio?.stop()   // closes the FIFO: ffmpeg sees the end of the stream
        systemAudio = nil
        // fallback if ffmpeg ignored stdin
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard self?.state == .recording, p.isRunning else { return }
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-INT", "-P", String(p.processIdentifier), "ffmpeg"]
            try? kill.run()
        }
    }

    private func consume(_ chunk: String) {
        buffer += chunk
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl]).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(...nl)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("{") {
                if let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                    let stopped = event["t"] as? String == "stopped"
                    if stopped { state = .transcribing; meter.stop() }
                    live.handle(event)
                    scheduleLiveFile(now: stopped)
                }
                continue
            }
            lastLine = line
            if line.hasPrefix("📝") { state = .transcribing; meter.stop(); scheduleLiveFile(now: true) }   // fallback path without the engine
            if line.hasPrefix("🧠") { live.phase = .summarizing }
            if line.hasPrefix("🔇") { silent = true }
            if line.hasPrefix("✅ ") { lastResult = URL(fileURLWithPath: String(line.dropFirst(2))) }
        }
    }

    private func finished(_ status: Int32) {
        state = .idle
        scheduleLiveFile(now: true)   // removes .live.json
        meter.stop()
        systemAudio?.stop(); systemAudio = nil
        removeFifo()
        proc = nil; input = nil
        if var r = lastResult {
            if let f = notesFile {   // notes typed while transcribing were not in the file the script read
                writeNotes(to: r)
                try? FileManager.default.removeItem(at: f)
            }
            notesFile = nil
            if title != startName, title != "Meeting", let moved = rename(r, to: title) { r = moved; lastResult = moved }
            let titled = autoTitle(r)
            if titled != r { r = titled; lastResult = titled; title = meetingName(titled) }
            viewing = r
            if !project.isEmpty { setProject(project) }
            VaultMirror.write(r)
            live.load(transcriptOf: r)   // final text with speaker labels
            summary = Self.section("Zusammenfassung", in: (try? String(contentsOf: r, encoding: .utf8)) ?? "")
        }
        refresh()
        if let r = lastResult {
            NSSound(named: "Glass")?.play()  // audible even if notifications aren't allowed
            Notifier.shared.notify(r)
            justFinished = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.justFinished = false }
        } else if silent {
            if let f = notesFile, ((try? String(contentsOf: f, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try? FileManager.default.removeItem(at: f) }   // typed after stop: keep it
            notesFile = nil
            error = "Nichts aufgenommen: Es wurde keine Sprache erkannt. Läuft das richtige Mikrofon?"
            NSSound(named: "Funk")?.play()
            Notifier.shared.nothingRecorded()
        } else if status != 0 || lastResult == nil {
            error = lastLine.isEmpty ? "Aufnahme fehlgeschlagen (Code \(status))." : lastLine
            // the notes file stays in ~/Meetings (hidden .notes-*.md) so nothing typed is lost
        }
    }

    private func removeFifo() {
        if let fifo { try? FileManager.default.removeItem(at: fifo) }
        fifo = nil
    }

    func open(_ md: URL) {
        guard state == .idle, let content = try? String(contentsOf: md, encoding: .utf8) else { return }
        notesSave?.cancel()
        viewing = md; lastResult = md
        title = meetingName(md)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        started = f.date(from: String(md.deletingPathExtension().lastPathComponent.prefix(15))) ?? modified(md)
        live.load(transcriptOf: md)
        stoppedAt = started.addingTimeInterval((live.bubbles.last?.start ?? 0) + 5)
        notes = Self.section("Meine Notizen", in: content)
        notesSave?.cancel()   // just loaded, nothing to save
        summary = Self.section("Zusammenfassung", in: content)
        project = VaultMirror.header("Projekt", in: content) ?? ""
    }

    /// Creates an empty "<date>_Notiz.md" (no recording) and opens it in the main window.
    func newNote() {
        guard state == .idle else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        let date = f.string(from: .now)
        var md = outDir.appendingPathComponent("\(date)_Notiz.md")
        var n = 2
        while FileManager.default.fileExists(atPath: md.path) {
            md = outDir.appendingPathComponent("\(date)_Notiz-\(n).md"); n += 1
        }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        guard (try? "# Meeting \(md.deletingPathExtension().lastPathComponent)\n".write(to: md, atomically: true, encoding: .utf8)) != nil
        else { error = "Notiz konnte nicht angelegt werden."; return }
        refresh()
        show(md)
    }

    /// Opens a meeting in the main window (from the panel, the pill or a notification).
    func show(_ md: URL) {
        open(md)
        NoteWindow.shared.show()
    }

    /// Writes the "Projekt:" header of the open meeting (empty removes it).
    func setProject(_ name: String) {
        project = name.trimmingCharacters(in: .whitespaces)
        guard state == .idle, let md = viewing, let content = try? String(contentsOf: md, encoding: .utf8) else { return }
        try? VaultMirror.setHeader("Projekt", project, in: content).write(to: md, atomically: true, encoding: .utf8)
        VaultMirror.write(md)
        refresh()
    }

    // MARK: notes

    private func scheduleNotesSave() {
        notesSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNotesNow() }
        notesSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func saveNotesNow() {
        notesSave?.cancel()
        if state != .idle, let f = notesFile {
            try? notes.write(to: f, atomically: true, encoding: .utf8)
        } else if let md = viewing {
            writeNotes(to: md)
            VaultMirror.write(md)
        }
    }

    /// Replaces (or adds) the "## Meine Notizen" section of a meeting file.
    private func writeNotes(to md: URL) {
        guard let content = try? String(contentsOf: md, encoding: .utf8) else { return }
        let updated = Self.replacing("Meine Notizen", in: content, with: notes.trimmingCharacters(in: .whitespacesAndNewlines))
        if updated != content { try? updated.write(to: md, atomically: true, encoding: .utf8) }
    }

    static func section(_ heading: String, in content: String) -> String {
        guard let r = content.range(of: "\n## \(heading)\n") else { return "" }
        let rest = content[r.upperBound...]
        let end = rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex
        return rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func replacing(_ heading: String, in content: String, with body: String) -> String {
        var text = content
        if let r = text.range(of: "\n## \(heading)\n") {
            let end = text[r.upperBound...].range(of: "\n## ")?.lowerBound ?? text.endIndex
            text.removeSubrange(r.lowerBound..<end)
        }
        text = text.trimmingCharacters(in: .newlines) + "\n"
        return body.isEmpty ? text : text + "\n## \(heading)\n\n\(body)\n"
    }

    // MARK: renaming

    /// Renames a meeting file (and its .json) to "<date>_<slug>.md"; returns the new URL.
    @discardableResult
    func rename(_ md: URL, to newTitle: String) -> URL? {
        let stem = md.deletingPathExtension().lastPathComponent
        let date = String(stem.prefix(15))   // "2026-11-07_1952"
        let slug = Self.slug(newTitle)
        let target = md.deletingLastPathComponent().appendingPathComponent(slug.isEmpty ? date : "\(date)_\(slug)")
            .appendingPathExtension("md")
        guard target != md, !FileManager.default.fileExists(atPath: target.path) else { return nil }
        do { try FileManager.default.moveItem(at: md, to: target) } catch { return nil }
        VaultMirror.remove(md)
        defer { VaultMirror.write(target) }
        let json = md.deletingPathExtension().appendingPathExtension("json")
        try? FileManager.default.moveItem(at: json, to: target.deletingPathExtension().appendingPathExtension("json"))
        return target
    }

    /// An unnamed meeting ("2026-11-07_1952.md") gets the title the summary step wrote into its JSON.
    @discardableResult
    func autoTitle(_ md: URL) -> URL {
        guard md.deletingPathExtension().lastPathComponent.split(separator: "_").count == 2,
              let data = try? Data(contentsOf: md.deletingPathExtension().appendingPathExtension("json")),
              let t = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["title"] as? String,
              !Self.slug(t).isEmpty, let moved = rename(md, to: t) else { return md }
        return moved
    }

    func renameOpenMeeting() {
        guard state == .idle, let md = viewing, let moved = rename(md, to: title) else { return }
        viewing = moved; lastResult = moved
        refresh()
    }

    /// "Sprecher 2" → "Anna" everywhere in the meeting file (transcript, summary owners) and its JSON.
    func renameSpeaker(_ old: String, to new: String) {
        let new = new.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard !new.isEmpty, new != old, let md = viewing ?? lastResult,
              var content = try? String(contentsOf: md, encoding: .utf8) else { return }
        content = content.replacingOccurrences(of: "**\(old):**", with: "**\(new):**")
            .replacingOccurrences(of: "· **\(old)**", with: "· **\(new)**")
            .replacingOccurrences(of: "] \(old): ", with: "] **\(new):** ")   // files from before bold names
        try? content.write(to: md, atomically: true, encoding: .utf8)
        VaultMirror.write(md)
        let json = md.deletingPathExtension().appendingPathExtension("json")
        if let j = try? String(contentsOf: json, encoding: .utf8) {
            try? j.replacingOccurrences(of: "\"owner\": \"\(old)\"", with: "\"owner\": \"\(new)\"")
                .write(to: json, atomically: true, encoding: .utf8)
        }
        live.load(transcriptOf: md)
        summary = Self.section("Zusammenfassung", in: content)
    }

    // MARK: summary of a past meeting

    func summarize() {
        guard state == .idle, !summarizing, let md = viewing ?? lastResult,
              let script = Bundle.main.url(forResource: "summarize", withExtension: "py") else { return }
        saveNotesNow()
        let p = Process()
        p.executableURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".meeting-notes/venv/bin/python")
        p.arguments = ["-I", script.path, md.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let backend = UserDefaults.standard.string(forKey: "summary") ?? "ollama"
        env["MEETING_SUMMARY"] = backend == "off" ? "ollama" : backend   // an explicit click overrides "off"
        env["MEETING_SUMMARY_MODEL"] = UserDefaults.standard.string(forKey: "summaryModel").flatMap { $0.isEmpty ? nil : $0 }
        p.environment = env
        p.standardError = FileHandle(forWritingAtPath: Self.logFile.path) ?? FileHandle.nullDevice
        p.terminationHandler = { p in
            let ok = p.terminationStatus == 0
            Task { @MainActor in
                self.summarizing = false
                guard let content = try? String(contentsOf: md, encoding: .utf8) else { return }
                self.summary = Self.section("Zusammenfassung", in: content)
                let titled = self.autoTitle(md)   // rename() mirrors the new file to the vault itself
                if titled != md {
                    if self.viewing == md { self.viewing = titled; self.title = meetingName(titled) }
                    if self.lastResult == md { self.lastResult = titled }
                    self.refresh()
                } else { VaultMirror.write(md) }
                if !ok || self.summary.isEmpty { self.error = "Zusammenfassung fehlgeschlagen (Details: ~/Library/Logs/MeetingNotes.log)." }
            }
        }
        do { try p.run(); summarizing = true; error = nil } catch { self.error = "Zusammenfassung: \(error.localizedDescription)" }
    }

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: outDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        recent = files.filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // date-stamped names: newest first, stable when edited
        let contents = Dictionary(uniqueKeysWithValues: recent.map { ($0, (try? String(contentsOf: $0, encoding: .utf8)) ?? "") })
        let parsed = contents.mapValues { LiveTranscriber.parse($0) }
        previews = parsed.mapValues { String($0.map(\.text).joined(separator: " ").prefix(160)) }
        durations = parsed.compactMapValues { $0.last?.start }
        projects = contents.compactMapValues { VaultMirror.header("Projekt", in: $0) }
        texts = contents.mapValues { $0.lowercased() }
        setupProblems = SetupCheck.problems(summary: UserDefaults.standard.string(forKey: "summary") ?? "ollama")
    }

    func modified(_ url: URL) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmm"
        return f.date(from: String(url.deletingPathExtension().lastPathComponent.prefix(15)))
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let record = UNNotificationAction(identifier: "record", title: "Aufnehmen", options: [])
        c.setNotificationCategories([UNNotificationCategory(identifier: "meeting", actions: [record], intentIdentifiers: [])])
    }

    func notify(_ url: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Transkript fertig"
        content.body = url.deletingPathExtension().lastPathComponent
        content.sound = .default
        content.userInfo = ["path": url.path]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func callEnded(_ app: String) {
        let content = UNMutableNotificationContent()
        content.title = "Call beendet, Aufnahme gestoppt"
        content.body = "\(app) nutzt das Mikrofon nicht mehr. Das Transkript wird erstellt."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "call-ended", content: content, trigger: nil))
    }

    func nothingRecorded() {
        let content = UNMutableNotificationContent()
        content.title = "Nichts aufgenommen"
        content.body = "Keine Sprache erkannt, deshalb wurde kein Meeting angelegt. Mikrofon prüfen?"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "nothing-recorded", content: content, trigger: nil))
    }

    func offerRecording(_ body: String, title: String = "Meeting erkannt") {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = "meeting"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "meeting-offer", content: content, trigger: nil))
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if r.notification.request.content.categoryIdentifier == "meeting" {
            if r.actionIdentifier != UNNotificationDismissActionIdentifier {
                Task { @MainActor in if Recorder.shared.state == .idle { Recorder.shared.toggle() } }
            }
        } else if let p = r.notification.request.content.userInfo["path"] as? String {
            Task { @MainActor in Recorder.shared.show(URL(fileURLWithPath: p)) }
        }
        done()
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// Live input level for the waveform, from the microphone picked for recording.
final class Meter: ObservableObject {
    @Published var levels = [CGFloat](repeating: 0, count: 34)
    private let engine = AVAudioEngine()

    func start(deviceUID: String? = nil) {
        let input = engine.inputNode
        // the engine keeps the last device it was given, so always set one (the default input when none was picked)
        if let unit = input.audioUnit, var id = (deviceUID ?? SystemAudio.defaultInputUID()).flatMap(SystemAudio.device) {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let db = 20 * log10(max(sqrt(sum / Float(max(n, 1))), 1e-6))
            let v = CGFloat(min(max((db + 55) / 45, 0), 1))  // -55 dB … -10 dB → 0 … 1
            DispatchQueue.main.async { self?.push(v) }
        }
        try? engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        levels = levels.map { _ in 0 }
    }

    private func push(_ v: CGFloat) {
        levels.removeFirst()
        levels.append(v)
    }
}

// Live transcript fed by engine.py events (via the meeting script's stdout): one bubble per utterance while
// recording, then the final file with speaker labels.
final class LiveTranscriber: ObservableObject {
    struct Bubble: Identifiable, Equatable {
        let id: Int
        let start: Double
        var text: String
        var speaker: String?   // name ("Sprecher 2", "Johan", "Anna"); nil until labelled after the meeting
    }
    enum Phase { case live, labeling, summarizing, done }

    @Published var bubbles: [Bubble] = []
    var speakers: [String] {   // in order of first appearance, for stable colors
        var seen: [String] = []
        for b in bubbles { if let s = b.speaker, !seen.contains(s) { seen.append(s) } }
        return seen
    }
    @Published var speaking = false
    @Published var phase = Phase.live
    @Published var text = ""          // latest sentence, typed out word by word (pill caption, panel)
    @Published var partial = ""       // sentence still being spoken, revised live by the engine
    private var partialStart = 0.0
    private var typer: Timer?

    func reset() {
        bubbles = []; speaking = false; phase = .live; text = ""; partial = ""
        typer?.invalidate()
        typer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            guard let self else { return }
            let target = self.partial.isEmpty ? self.bubbles.last?.text ?? "" : self.partial
            let next = Self.step(shown: self.text, target: target)
            if next != self.text { self.text = next }
        }
    }

    func handle(_ e: [String: Any]) {
        switch e["t"] as? String {
        case "utt":
            let text = Self.clean(e["text"] as? String ?? "")
            guard !text.isEmpty else { return }
            bubbles.append(Bubble(id: e["id"] as? Int ?? bubbles.count, start: e["start"] as? Double ?? 0, text: text))
            // this sentence is now final; a partial starting near its end (VAD padding) is already the next one
            if partialStart + 1 < e["end"] as? Double ?? .infinity { partial = "" }
        case "partial":
            partial = Self.clean(e["text"] as? String ?? "")
            partialStart = e["start"] as? Double ?? 0
        case "speaking": speaking = e["on"] as? Bool ?? false
        case "stopped": speaking = false; partial = ""; phase = .labeling
        case "done": phase = .done; typer?.invalidate()
        default: break
        }
    }

    // "[00:01:02] Sprecher 2: text" lines of a meeting file → bubbles with speakers
    func load(transcriptOf md: URL) {
        typer?.invalidate()
        guard let content = try? String(contentsOf: md, encoding: .utf8) else { return }
        let parsed = Self.parse(content)
        if !parsed.isEmpty { bubbles = parsed }
        phase = .done
    }

    static func parse(_ content: String) -> [Bubble] {
        // "[00:01:02] **Anna:** text", older files "[00:01:02] Sprecher 2: text", single speaker "[00:01:02] text"
        let re = try! NSRegularExpression(pattern: #"^\[(\d+):(\d+):(\d+)\] (?:\*\*(.+?):\*\* |(Sprecher \d+): )?(.+?)\s*$"#)
        var out: [Bubble] = []
        for line in content.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let num = { (i: Int) in Int(ns.substring(with: m.range(at: i))) ?? 0 }
            let group = { (i: Int) in m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            let spk = group(4) ?? group(5)
            out.append(Bubble(id: out.count, start: Double(num(1) * 3600 + num(2) * 60 + num(3)),
                              text: clean(ns.substring(with: m.range(at: 6))), speaker: spk))
        }
        return out
    }

    // One typing step: drop words that changed, then reveal the next word(s) — faster when far behind.
    static func step(shown: String, target: String) -> String {
        let s = shown.split(separator: " "), t = target.split(separator: " ")
        var k = 0
        while k < s.count && k < t.count && s[k] == t[k] { k += 1 }
        if k < s.count { return t[..<k].joined(separator: " ") }
        guard k < t.count else { return shown }
        let behind = t.count - k
        let n = behind > 16 ? 4 : behind > 6 ? 2 : 1
        return t[..<(k + n)].joined(separator: " ")
    }

    static func clean(_ s: String) -> String {
        let last = s.components(separatedBy: "\r").last ?? s
        let cleaned = last
            .replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[[^\\]]*\\]|\\([^)]*\\)|\\*[^*]*\\*", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(^|\\s)- ", with: " ", options: .regularExpression)  // whisper's speaker-turn dashes
            .replacingOccurrences(of: "(.{6,80}?)(?:\\s*\\1)+", with: "$1", options: .regularExpression)  // whisper repeat loops
            .trimmingCharacters(in: .whitespaces)
        return cleaned.rangeOfCharacter(from: .letters) == nil ? "" : cleaned  // drop lone "-", "…" etc.
    }
}

// MARK: shared helpers

// "2026-11-07_1400_kundencall" → "kundencall", undated names stay as they are
func meetingName(_ url: URL) -> String {
    let stem = url.deletingPathExtension().lastPathComponent
    let parts = stem.split(separator: "_", maxSplits: 2)
    if parts.count == 3 { return parts[2].replacingOccurrences(of: "-", with: " ") }
    return parts.count == 2 ? "Meeting" : stem
}

func elapsedString(from start: Date, to now: Date) -> String {
    let s = max(0, Int(now.timeIntervalSince(start)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}

// MARK: floating pill

// Borderless, non-activating, always on top, on every Space. Transparent around the pill so clicks pass through.
final class PillPanel: NSPanel {
    static let size = NSSize(width: 380, height: 130)

    init<V: View>(_ root: V) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        appearance = NSAppearance(named: .darkAqua)  // black pill: native controls must render light-on-dark
        contentView = host
        if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.midX - Self.size.width / 2, y: screen.minY + 16))
        }
        setFrameAutosaveName("MeetingNotesPill")  // keeps the spot you dragged it to
        // only the pill strip takes the mouse; everything else in the panel clicks through to the app below
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let hot = Self.hotRect(in: self.frame)
            let pass = !hot.contains(NSEvent.mouseLocation)
            if self.ignoresMouseEvents != pass { self.ignoresMouseEvents = pass }
        }
    }

    static func hotRect(in frame: NSRect) -> NSRect {
        NSRect(x: frame.midX - 160, y: frame.minY, width: 320, height: 48)
    }

    override var canBecomeKey: Bool { false }
}

// Dynamic Island style: one black capsule that morphs between states.
struct PillView: View {
    @EnvironmentObject var rec: Recorder
    @EnvironmentObject var meter: Meter
    @EnvironmentObject var live: LiveTranscriber
    @AppStorage("showPill") private var showPill = true
    @State private var hover = false

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if showPill {
                if rec.state == .recording, let line = caption {
                    // like macOS Live Captions
                    Text(line)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .contentTransition(.interpolate)   // new words materialize instead of popping in
                        .frame(maxWidth: 340, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .transition(.opacity)
                }
                pill
            }
        }
        .padding(.bottom, 6)
        .frame(width: PillPanel.size.width, height: PillPanel.size.height, alignment: .bottom)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: rec.state)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: hover)
        .animation(.easeOut(duration: 0.3), value: caption)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: rec.justFinished)
        .environment(\.colorScheme, .dark)
    }

    // last ~110 characters, starting at a word boundary, so the caption scrolls like subtitles
    private var caption: String? {
        let t = live.text
        guard !t.isEmpty else { return nil }
        guard t.count > 110 else { return t }
        let tail = t.suffix(110)
        return tail.firstIndex(of: " ").map { "…" + tail[tail.index(after: $0)...] } ?? String(tail)
    }

    private var expanded: Bool { rec.state != .idle || hover || rec.justFinished || rec.detectedCall != nil }

    private var pill: some View {
        content
            .padding(.horizontal, expanded ? 14 : 0)
            .frame(minWidth: expanded ? 0 : 40, minHeight: expanded ? 34 : 8)
            .background(.black, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .contentShape(Capsule())
            .onHover { hover = $0 }
            .onTapGesture { if rec.state == .idle && !rec.justFinished && rec.detectedCall == nil { rec.toggle() } }
    }

    @ViewBuilder private var content: some View {
        switch rec.state {
        case .idle:
            if let call = rec.detectedCall, !rec.justFinished {
                Button { rec.toggle() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7)
                        Text("\(MeetingContext.appName(call)) aufnehmen")
                        Text("⌃⌥␣").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
            } else if rec.justFinished, let r = rec.lastResult {
                Button { rec.show(r) } label: {
                    Label("Transkript ansehen", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
            } else if hover {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill").foregroundStyle(.white)
                    Text("Aufnehmen").foregroundStyle(.white)
                    Text("⌃⌥␣").foregroundStyle(.secondary)
                }
                .font(.system(size: 13, weight: .medium))
                .transition(.opacity)
            } else {
                Color.clear.frame(width: 40, height: 8)  // an empty view would drop the capsule background too
            }
        case .recording:
            HStack(spacing: 10) {
                LiveDot(size: 7)
                Waveform(levels: Array(meter.levels.suffix(12)), tint: .white)
                    .frame(width: 52, height: 16)
                if hover {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(elapsedString(from: rec.started, to: ctx.date))
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .transition(.opacity)
                    Button(action: rec.stop) {
                        RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 9, height: 9)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(.white.opacity(0.15)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Stoppen & transkribieren (⌃⌥ Leertaste)")
                    .transition(.opacity)
                }
            }
        case .transcribing:
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle().fill(.white)
                            .frame(width: 5, height: 5)
                            .opacity(0.3 + 0.7 * (0.5 + 0.5 * sin(t * 5 - Double(i) * 0.9)))
                    }
                }
            }
            .help("Transkribiere lokal …")
        }
    }
}

// MeetingNotes.app/Contents/MacOS/MeetingNotes --selftest
@MainActor func selftest() {
    let md = "# Meeting x\n\n## Zusammenfassung\n\nKurz.\n\n### To-dos\n\n- [ ] A\n\n## Transcript\n\n" +
        "[00:00:01] **Johan:** Hallo.  \n[00:01:02] Sprecher 2: Ja.  \n[00:01:05] ohne Name  \n\n## Meine Notizen\n\nalt\n"
    precondition(Recorder.section("Zusammenfassung", in: md) == "Kurz.\n\n### To-dos\n\n- [ ] A")
    precondition(Recorder.section("Meine Notizen", in: md) == "alt")
    let replaced = Recorder.replacing("Meine Notizen", in: md, with: "neu")
    precondition(Recorder.section("Meine Notizen", in: replaced) == "neu" && replaced.components(separatedBy: "## Meine").count == 2)
    precondition(!Recorder.replacing("Meine Notizen", in: md, with: "").contains("Meine Notizen"))
    let b = LiveTranscriber.parse(md)
    precondition(b.map(\.speaker) == ["Johan", "Sprecher 2", nil] && b[1].start == 62 && b[0].text == "Hallo.")
    precondition(MeetingContext.terms("# Kopf\nOpenTwin, Wispr\n  Johan # ich\n\n") == ["OpenTwin", "Wispr", "Johan"])
    precondition(MeetingContext.vocab(own: ["Anna", "X"], attendees: ["anna", "Bob"]) == "Anna, X, Bob")
    precondition(MeetingContext.vocab(own: ["X"], attendees: (0...MeetingContext.promptAttendeeLimit).map { "P\($0)" }) == "X")
    precondition(Recorder.slug("Kunden-Call: Q4 ✓") == "Kunden-Call-Q4")

    // aggregate input: a 2-channel mic buffer, then a 1-channel tap buffer → [mic avg, system] pairs
    let mic: [Float] = [1, 3, 5, 7], sys: [Float] = [0.5, 0.25]
    let abl = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(abl.unsafeMutablePointer) }
    mic.withUnsafeBufferPointer { m in
        sys.withUnsafeBufferPointer { s in
            abl[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 16, mData: UnsafeMutableRawPointer(mutating: m.baseAddress))
            abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: UnsafeMutableRawPointer(mutating: s.baseAddress))
            precondition(SystemAudio.interleave(abl, micChannels: 2) == [2, 0.5, 6, 0.25])
        }
    }
    // vault mirror
    let url = URL(fileURLWithPath: "/x/2026-11-07_1952_kunden-call.md")
    precondition(VaultMirror.noteURL(for: url).lastPathComponent == "2026-11-07 19.52 kunden call.md")
    let doc = "# Meeting x\n\nAudio: a.m4a\n\nTeilnehmer: Anna Muster, Bob\n\n## Transcript\n\n" +
        "[00:00:01] **Johan:** Hi.  \n[00:00:02] **Sprecher 2:** Ja.  \n[00:00:03] **Anna Muster:** Ok.\n"
    precondition(VaultMirror.participants(doc) == ["Anna Muster", "Bob", "Johan"])
    precondition(VaultMirror.header("Teilnehmer", in: doc) == "Anna Muster, Bob" && VaultMirror.header("Projekt", in: doc) == nil)
    let withProject = VaultMirror.setHeader("Projekt", "OpenTwin", in: doc)
    precondition(VaultMirror.header("Projekt", in: withProject) == "OpenTwin" && withProject.contains("Audio: a.m4a\n\nProjekt: OpenTwin"))
    precondition(VaultMirror.setHeader("Projekt", "", in: withProject) == doc)
    let vnote = VaultMirror.note(for: url, content: withProject)
    precondition(vnote.hasPrefix("---\ndatum: 2026-11-07\n") && vnote.contains("projekt: OpenTwin")
                 && vnote.contains("teilnehmer: [\"Anna Muster\", \"Bob\", \"Johan\"]")
                 && vnote.contains("## Transcript") && !vnote.contains("Audio: a.m4a"))
    print("app selftest ok")
}
