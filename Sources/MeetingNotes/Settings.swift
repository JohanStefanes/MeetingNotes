import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Einstellungen"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView().environmentObject(Recorder.shared))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

struct SettingsView: View {
    @EnvironmentObject var rec: Recorder
    @AppStorage("device") private var device = "default"
    @AppStorage("mix") private var mix = ""
    @AppStorage("showPill") private var showPill = true
    @AppStorage("systemAudio") private var systemAudio = true
    @AppStorage("detectMeetings") private var detectMeetings = true
    @AppStorage("summary") private var summaryBackend = "ollama"
    @AppStorage("autoStop") private var autoStop = true
    @AppStorage("autoStopDelay") private var autoStopDelay = 20
    @AppStorage("meName") private var meName = ""
    @AppStorage("speakers") private var speakers = 0
    @AppStorage("language") private var language = "de"
    @AppStorage("summaryModel") private var summaryModel = ""
    @AppStorage("calendarReminder") private var calendarReminder = true
    @State private var calendarConnected = MeetingContext.shared.calendarConnected
    @AppStorage("vault") private var vault = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var devices: [String] = []

    var body: some View {
        Form {
            Section("Allgemein") {
                Toggle("Beim Login starten", isOn: $launchAtLogin)
                Toggle("Schwebende Pill am unteren Bildschirmrand", isOn: $showPill)
                LabeledContent("Kurzbefehl") { Keycaps() }
            }
            Section {
                Picker("Mikrofon", selection: $device) {
                    Text("Systemstandard").tag("default")
                    ForEach(devices, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Mac-Ton mitschneiden (Zoom, Teams, Browser)", isOn: $systemAudio)
                if !systemAudio {
                    Picker("Zweites Gerät dazumischen", selection: $mix) {
                        Text("Nichts").tag("")
                        ForEach(devices, id: \.self) { Text($0).tag($0) }
                    }
                }
            } header: { Text("Aufnahme") } footer: {
                Text("Mit Mac-Ton landen Mikrofon und Call auf getrennten Kanälen: so weiss die App, was du gesagt hast.")
            }
            Section {
                LabeledContent("Kalender") {
                    if calendarConnected { Text("Verbunden").foregroundStyle(.secondary) }
                    else {
                        Button("Verbinden …") {
                            MeetingContext.shared.requestCalendar { ok in
                                calendarConnected = ok
                                if !ok { MeetingContext.shared.openCalendarPrivacy() }   // denied before: only Settings can fix it
                            }
                        }
                    }
                }
                Toggle("Aufnahme vorschlagen, wenn ein Termin beginnt", isOn: $calendarReminder).disabled(!calendarConnected)
                Toggle("Aufnahme vorschlagen, wenn ein Call das Mikrofon nutzt", isOn: $detectMeetings)
                Toggle("Automatisch stoppen, wenn der Call endet", isOn: $autoStop)
                if autoStop {
                    Stepper("… nach \(autoStopDelay) s ohne Call", value: $autoStopDelay, in: 6...120, step: 3)
                }
            } header: { Text("Meetings erkennen") } footer: {
                Text("Kalender gilt für alle Konten in der Kalender-App (iCloud, Google, Exchange). Titel und Teilnehmer landen im Meeting.")
            }
            Section {
                Picker("Zusammenfassung", selection: $summaryBackend) {
                    Text("Lokal mit Ollama").tag("ollama")
                    Text("Claude API").tag("claude")
                    Text("Aus").tag("off")
                }
                if summaryBackend != "off" {
                    TextField("Modell", text: $summaryModel,
                              prompt: Text(summaryBackend == "claude" ? "claude-opus-5-5" : "qwen2.5:14b-instruct"))
                }
                Toggle("Im Obsidian-Vault ablegen (~/Vault/Meetings)", isOn: $vault)
            } header: { Text("Nach dem Meeting") } footer: {
                Text(summaryBackend == "claude" ? "Das Transkript wird zur Zusammenfassung an die Claude API geschickt."
                                                : "Transkript und Zusammenfassung verlassen deinen Mac nicht.")
            }
            Section {
                TextField("Dein Name im Transkript", text: $meName, prompt: Text(Recorder.defaultMeName))
                Picker("Anzahl Sprecher", selection: $speakers) {
                    Text("Automatisch").tag(0)
                    ForEach(2...10, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Sprache für Ganzdatei-Durchlauf", selection: $language) {
                    Text("Deutsch").tag("de")
                    Text("Englisch").tag("en")
                    Text("Portugiesisch (Brasilien)").tag("pt")
                }
            } header: { Text("Transkript") } footer: {
                Text("Live wird Deutsch/Englisch/Portugiesisch pro Satz erkannt; die Sprache gilt nur, wenn die Live-Erkennung ausfällt. Sprecherzahl automatisch nutzt die Teilnehmer aus dem Kalender als Obergrenze.")
            }
            Section("Erkennung verbessern") {
                LabeledContent("Wörterbuch") {
                    Button("Bearbeiten …") { MeetingContext.shared.openVocabulary() }
                }
                LabeledContent("Stimmprobe") {
                    Button(VoiceEnroll.exists ? "Neu aufnehmen …" : "Aufnehmen …") { VoiceWindow.shared.show() }
                }
            }
            Section("Speicherort") {
                LabeledContent("Meetings") {
                    Button("~/Meetings im Finder zeigen") { NSWorkspace.shared.open(rec.outDir) }
                }
                LabeledContent("Protokoll") {
                    Button("Log öffnen") { NSWorkspace.shared.open(Recorder.logFile) }
                }
            }
            if !rec.setupProblems.isEmpty {
                Section { SetupWarning(problems: rec.setupProblems).listRowInsets(EdgeInsets()) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
        .onAppear { devices = Recorder.inputDevices() }
        .onChange(of: launchAtLogin) { _, on in
            do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
            catch { rec.error = "Login-Start: \(error.localizedDescription)" }
        }
        .onChange(of: summaryBackend) { rec.refresh() }   // setup check depends on the backend
    }
}
