import SwiftUI

// Menu bar panel: start/stop, live view while recording, last meetings.
struct PanelView: View {
    @EnvironmentObject var rec: Recorder
    @EnvironmentObject var meter: Meter
    @EnvironmentObject var live: LiveTranscriber
    @AppStorage("device") private var device = "default"
    @AppStorage("mix") private var mix = ""
    @State private var name = ""
    @State private var devices: [String] = []

    var body: some View {
        VStack(spacing: 14) {
            topBar
            Group {
                switch rec.state {
                case .idle: idle
                case .recording: recording
                case .transcribing: transcribing
                }
            }
            .frame(height: rec.state == .recording ? 330 : 230)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))

            if let e = rec.error { Banner(text: e, dismiss: { rec.error = nil }) }
            if rec.state == .idle && !rec.setupProblems.isEmpty { SetupWarning(problems: rec.setupProblems) }
            if rec.state == .idle { recentList }
        }
        .padding(16)
        .frame(width: 340)
        .background(Theme.card)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: rec.state)
        .onAppear {
            devices = Recorder.inputDevices()
            rec.refresh()
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 14, weight: .bold)).foregroundStyle(.primary)
            Text("MeetingNotes").font(.system(size: 15, weight: .bold)).tracking(-0.3).foregroundStyle(.primary)
            Spacer()
            Button { NoteWindow.shared.show() } label: { Image(systemName: "sidebar.left") }
                .help("Alle Meetings")
            Menu {
                Button("Alle Meetings") { NoteWindow.shared.show() }
                Button("Einstellungen …") { SettingsWindow.shared.show() }.keyboardShortcut(",")
                Divider()
                Button("Wörterbuch bearbeiten …") { MeetingContext.shared.openVocabulary() }
                Button(VoiceEnroll.exists ? "Stimmprobe neu aufnehmen …" : "Stimmprobe aufnehmen …") { VoiceWindow.shared.show() }
                Button("Ordner öffnen") { NSWorkspace.shared.open(rec.outDir) }
                Divider()
                Button("MeetingNotes beenden") { NSApp.terminate(nil) }.disabled(rec.state != .idle)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(Theme.muted)
    }

    // MARK: states

    private var idle: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Neue Notiz", text: $name)
                .textFieldStyle(.plain)
                .font(Theme.title(30))
                .onSubmit(start)
            Chip(icon: mix.isEmpty ? "mic.fill" : "person.2.wave.2.fill", text: deviceName) {
                Picker("Mikrofon", selection: $device) {
                    Text("Systemstandard").tag("default")
                    ForEach(devices, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.inline)
            }
            StartButton(wide: true, action: start)
            HStack(spacing: 6) { Keycaps(); Text("startet überall").font(.caption).foregroundStyle(Theme.muted) }
                .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var recording: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        LiveDot()
                        Text("Aufnahme läuft").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(elapsedString(from: rec.started, to: ctx.date))
                            .font(.system(size: 32, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.snappy, value: elapsedString(from: rec.started, to: ctx.date))
                    }
                }
                Spacer()
                StopButton(action: rec.stop)
            }
            Waveform(levels: meter.levels, tint: Theme.accent).frame(height: 30)
            LiveText(text: live.text)
            HStack {
                Text(rec.title).lineLimit(1)
                Spacer()
                Button("Notizen öffnen") { NoteWindow.shared.show() }.buttonStyle(.plain).foregroundStyle(Theme.muted)
            }
            .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private var transcribing: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            ProgressView().controlSize(.large)
            Text(live.phase == .summarizing ? "Fasse zusammen …" : live.phase == .labeling ? "Ordne Sprecher zu …" : "Transkribiere …")
                .font(Theme.title(20))
            Text("Läuft lokal auf deinem Mac.\nDu bekommst eine Mitteilung, wenn's fertig ist.")
                .font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
    }

    // MARK: recent

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if rec.justFinished, let r = rec.lastResult {
                Banner(text: "Transkript fertig", icon: "checkmark.circle.fill", tint: .green) {
                    Button("Ansehen") { rec.show(r) }.buttonStyle(.plain).fontWeight(.semibold)
                }
                .padding(.bottom, 8)
            }
            if !rec.recent.isEmpty {
                HStack {
                    SectionLabel("Zuletzt")
                    Spacer()
                    Button("Alle anzeigen") { NoteWindow.shared.show() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 8).padding(.bottom, 2)
                ForEach(rec.recent.prefix(4), id: \.self) { url in
                    RecentRow(title: meetingName(url), date: rec.modified(url)) { rec.show(url) }
                }
            }
        }
    }

    private var deviceName: String {
        let base = device == "default" ? "Mikrofon" : String(device.prefix(18))
        return mix.isEmpty ? base : "\(base) + 1"
    }

    private func start() {
        rec.start(name: name, device: device, mix: mix)
        name = ""
    }
}

struct RecentRow: View {
    let title: String
    let date: Date
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28)
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title).lineLimit(1)
                Spacer()
                Text(date.formatted(.relative(presentation: .named).locale(Locale(identifier: "de"))))
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            .font(.system(size: 13.5))
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(hover ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }
}

struct LiveText: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? "Hört zu …" : text)
                        .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                        .lineSpacing(3)
                        .contentTransition(.interpolate)   // new words materialize instead of popping in
                        .animation(.easeOut(duration: 0.3), value: text)
                    Color.clear.frame(height: 1).id("end")
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .scrollIndicators(.never)
            .onChange(of: text) { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                     .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom))
    }
}
