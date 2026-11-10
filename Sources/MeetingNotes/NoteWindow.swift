import SwiftUI

// Main window: meeting library on the left, the open (or running) meeting on the right.
@MainActor
final class NoteWindow {
    static let shared = NoteWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let rec = Recorder.shared
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "MeetingNotes"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 480)
            w.contentView = FirstClickHostingView(rootView: NoteView()
                .environmentObject(rec).environmentObject(rec.live).environmentObject(rec.meter))
            w.center()
            w.setFrameAutosaveName("MeetingNotesMain")   // not the old name: that frame was the 460 px single column
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// SwiftUI ignores the click that activates a window; in this window that click must already hit the button.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NoteView: View {
    @EnvironmentObject var rec: Recorder
    @EnvironmentObject var live: LiveTranscriber
    @State private var tab = 1   // 0 Notizen, 1 Transkript, 2 Zusammenfassung
    @State private var query = ""
    @State private var folder = ""   // project filter, "" = all
    @State private var hint = true   // "speakers come after the meeting" note while recording

    private static let chrome: CGFloat = 40   // height of the transparent title bar band

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 260)
            Group {
                if rec.state != .idle || rec.viewing != nil { detail } else { EmptyDetail() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
            .padding(.top, Self.chrome).padding([.trailing, .bottom], 10)
        }
        .background(Theme.canvas)
        .ignoresSafeArea()
        .onAppear { rec.refresh() }
        .onChange(of: rec.state) { _, s in if s == .recording { tab = 1 } }
    }

    // MARK: sidebar

    private var shown: [URL] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return rec.recent.filter { url in
            (folder.isEmpty || rec.projects[url] == folder)
                && words.allSatisfy { w in meetingName(url).lowercased().contains(w) || (rec.texts[url] ?? "").contains(w) }
        }
    }

    // newest first, so equal keys are always next to each other
    private var groups: [(title: String, urls: [URL])] {
        let cal = Calendar.current
        let week = cal.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        var out: [(String, [URL])] = []
        for url in shown {
            let d = rec.modified(url)
            let key = cal.isDateInToday(d) ? "Heute" : cal.isDateInYesterday(d) ? "Gestern"
                : d > week ? "Letzte 7 Tage" : d.formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "de_CH")))
            if out.last?.0 == key { out[out.count - 1].1.append(url) } else { out.append((key, [url])) }
        }
        return out
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Spacer(); RecordCapsule() }
                .frame(height: Self.chrome).padding(.horizontal, 12)

            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 16, weight: .bold))
                Text("MeetingNotes").font(.system(size: 18, weight: .bold)).tracking(-0.3)
            }
            .padding(.horizontal, 16).padding(.top, 6)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Suchen", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Suche leeren")
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 10).frame(height: 34)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 12).padding(.top, 16)

            let names = Array(Set(rec.projects.values)).sorted()
            if !names.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach([""] + names, id: \.self) { p in
                            Button { folder = p } label: {
                                Label(p.isEmpty ? "Alle" : p, systemImage: p.isEmpty ? "tray.full" : "folder")
                                    .padding(.horizontal, 10).frame(height: 26)
                                    .background(folder == p ? Theme.beige : .clear, in: Capsule())
                                    .overlay(Capsule().strokeBorder(folder == p ? .clear : Theme.line))
                                    .foregroundStyle(folder == p ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.muted))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(PressStyle()).font(.system(size: 12, weight: .medium))
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .padding(.top, 10)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if rec.state != .idle { liveRow.padding(.bottom, 6) }
                    if rec.recent.isEmpty {
                        Text("Noch keine Meetings.").foregroundStyle(.tertiary).padding(8)
                    } else if shown.isEmpty {
                        Text("Keine Treffer für „\(query)“.").foregroundStyle(.tertiary).padding(8)
                    }
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                        SectionLabel(g.title)
                            .padding(.horizontal, 10).padding(.top, 16).padding(.bottom, 6)
                        ForEach(g.urls, id: \.self) { url in
                            MeetingRow(url: url, selected: rec.state == .idle && rec.viewing == url) {
                                rec.open(url); tab = 1
                            }
                            .disabled(rec.state != .idle)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("Alles bleibt auf deinem Mac")
                Spacer()
                Text("\(rec.recent.count)").monospacedDigit()
            }
            .font(.caption).foregroundStyle(Theme.muted)
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
    }

    private var liveRow: some View {
        HStack(spacing: 10) {
            if rec.state == .recording { LiveDot() } else { ProgressView().controlSize(.mini) }
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(rec.state == .recording ? "Aufnahme läuft" : "Wird fertiggestellt …")
                    .font(.caption).foregroundStyle(rec.state == .recording ? Theme.accent : .secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBar.frame(height: 48).padding(.horizontal, 20)
            header.padding(.horizontal, 40).padding(.top, 4)
            HStack(spacing: 28) {
                TabButton(title: "Notizen", selected: tab == 0) { tab = 0 }
                TabButton(title: "Transkript", selected: tab == 1, live: rec.state == .recording) { tab = 1 }
                TabButton(title: "Zusammenfassung", icon: "sparkle", selected: tab == 2) { tab = 2 }
            }
            .padding(.horizontal, 40).padding(.top, 26)
            Rectangle().fill(Theme.line).frame(height: 1)
            Group {
                switch tab {
                case 2: SummaryView()
                case 0: notesEditor
                default: transcript
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if rec.state == .recording {
                HStack(spacing: 16) {
                    StopPill(action: rec.stop)
                    Text("Hol dir das Einverständnis, bevor du andere aufnimmst.").font(.caption).foregroundStyle(Theme.muted)
                    Spacer()
                }
                .padding(.horizontal, 32).padding(.top, 8).padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: rec.state)
    }

    @ViewBuilder private var topBar: some View {
        HStack(spacing: 14) {
            switch rec.state {
            case .recording:
                LiveDot()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsedString(from: rec.started, to: ctx.date)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                }
                MeterStrip()
            case .transcribing:
                ProgressView().controlSize(.small)
                Text(status ?? "Wird fertiggestellt …").foregroundStyle(.secondary)
            case .idle:
                if let status { ProgressView().controlSize(.small); Text(status).foregroundStyle(.secondary) }
            }
            Spacer()
            if rec.state == .idle, let r = rec.viewing {
                Button { NSWorkspace.shared.activateFileViewerSelecting([r]) } label: { Image(systemName: "folder") }
                    .help("Im Finder zeigen")
                Button { NSWorkspace.shared.open(r) } label: { Image(systemName: "arrow.up.forward.square") }
                    .help("Markdown-Datei öffnen")
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .foregroundStyle(Theme.muted)
    }

    private var status: String? {
        switch (rec.state, live.phase) {
        case (_, .summarizing): "Zusammenfassung wird erstellt …"
        case (.transcribing, _), (_, .labeling): "Sprecher werden zugeordnet …"
        default: rec.summarizing ? "Zusammenfassung wird erstellt …" : nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Neue Notiz", text: $rec.title)
                .textFieldStyle(.plain)
                .font(Theme.title(44))
                .disabled(rec.state == .transcribing)
                .onSubmit { rec.renameOpenMeeting() }
            HStack(spacing: 8) {
                Text(rec.started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
                    .locale(Locale(identifier: "de_CH")))).pill()
                if rec.state == .idle, let last = live.bubbles.last {
                    Text(durationString(last.start)).pill()
                }
                if !live.speakers.isEmpty {
                    HStack(spacing: -6) {
                        ForEach(Array(live.speakers.prefix(5).enumerated()), id: \.offset) { i, s in
                            Avatar(name: s, color: SpeakerColor.of(i), size: 20)
                                .background(Circle().fill(Theme.card).padding(-1.5))
                        }
                    }
                    .padding(.horizontal, 4)
                    .help(live.speakers.joined(separator: ", "))
                }
                Label { TextField("Projekt", text: $rec.project).textFieldStyle(.plain).fixedSize()
                    .onSubmit { rec.setProject(rec.project) } } icon: { Image(systemName: "folder") }
                    .pill(dashed: true)
            }
            .foregroundStyle(.primary)
            .labelStyle(.titleAndIcon)
        }
    }

    private var notesEditor: some View {
        TextEditor(text: $rec.notes)
            .font(.system(size: 16))
            .lineSpacing(6)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 35).padding(.vertical, 22)
            .overlay(alignment: .topLeading) {
                if rec.notes.isEmpty {
                    Text("Deine Gedanken zum Meeting … wird automatisch gespeichert.")
                        .font(.system(size: 16)).foregroundStyle(Theme.muted).padding(.horizontal, 40).padding(.vertical, 22)
                        .allowsHitTesting(false)
                }
            }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    transcriptBar.padding(.bottom, 14)
                    if live.bubbles.isEmpty && !live.speaking {
                        Text(rec.state == .recording ? "Hört zu … der Text erscheint live." : "Noch kein Transkript.")
                            .foregroundStyle(Theme.muted).padding(.top, 4)
                    }
                    ForEach(Array(live.bubbles.enumerated()), id: \.element.id) { i, b in
                        if let spk = b.speaker {
                            if i == 0 || live.bubbles[i - 1].speaker != spk {
                                let color = SpeakerColor.of(live.speakers.firstIndex(of: spk) ?? 0)
                                HStack(spacing: 8) {
                                    SpeakerHeader(name: spk, editable: rec.state == .idle) { rec.renameSpeaker(spk, to: $0) }
                                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
                                    Text(timestamp(b.start)).font(Theme.mono).foregroundStyle(Theme.muted)
                                }
                                .padding(.top, i == 0 ? 0 : 14)
                            }
                            bubble(b.text).transition(.opacity)
                        } else {
                            bubble(b.text).help(timestamp(b.start))
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    if rec.state == .recording && !live.partial.isEmpty {
                        bubble(live.partial).foregroundStyle(Theme.muted)   // not final yet: whisper may still revise it
                    } else if rec.state == .recording && live.speaking {
                        TypingDots(tint: Theme.accent)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 40).padding(.vertical, 24)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: live.bubbles)
            }
            .onChange(of: live.bubbles.count) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: live.speaking) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: live.partial) { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func bubble(_ text: String) -> some View {
        Text(text).font(.system(size: 15)).lineSpacing(3).textSelection(.enabled)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: 600, alignment: .leading)
    }

    // Time, copy, and while recording a dismissable note: the soft block above the transcript.
    private var transcriptBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "clock").foregroundStyle(Theme.muted)
                Group {
                    if rec.state == .recording {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in Text(elapsedString(from: rec.started, to: ctx.date)) }
                    } else {
                        Text(live.bubbles.last.map { timestamp($0.start) } ?? "0:00")
                    }
                }
                .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                Spacer()
                Button { copy(plainTranscript) } label: { Image(systemName: "doc.on.doc").frame(width: 30, height: 30).contentShape(Rectangle()) }
                    .buttonStyle(PressStyle()).foregroundStyle(Theme.muted)
                    .help("Transkript kopieren").accessibilityLabel("Transkript kopieren").disabled(live.bubbles.isEmpty)
            }
            .padding(.horizontal, 14).frame(height: 46)
            if rec.state == .recording && hint {
                HStack(spacing: 10) {
                    Text("Nach dem Meeting werden Sprecher zugeordnet und das Transkript bereinigt.")
                    Spacer(minLength: 4)
                    Button { withAnimation(.easeOut(duration: 0.2)) { hint = false } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle()).accessibilityLabel("Hinweis schliessen")
                }
                .font(.system(size: 13)).foregroundStyle(Theme.muted)
                .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
                .background(Theme.fill)
            }
        }
        .background(Theme.soft)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func timestamp(_ s: Double) -> String {
        let t = Int(s)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }

    private var plainTranscript: String {
        live.bubbles.map { b in (b.speaker.map { "\($0): " } ?? "") + b.text }.joined(separator: "\n")
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// Live level in the title bar while recording.
struct MeterStrip: View {
    @EnvironmentObject var meter: Meter
    var body: some View {
        Waveform(levels: Array(meter.levels.suffix(18)), tint: Theme.accent).frame(width: 90, height: 16)
    }
}

// Nothing open: invite to record.
struct EmptyDetail: View {
    @EnvironmentObject var rec: Recorder
    @EnvironmentObject var meter: Meter

    var body: some View {
        VStack(spacing: 18) {
            Text("Bereit für dein nächstes Meeting").font(Theme.title(36))
            Text("Starte eine Aufnahme oder wähle links ein Meeting.\nTranskript, Sprecher und Zusammenfassung entstehen lokal.")
                .font(.system(size: 15)).multilineTextAlignment(.center).foregroundStyle(Theme.muted).lineSpacing(4)
            StartButton(height: 48) { rec.toggle() }.padding(.top, 8)
            HStack(spacing: 8) { Keycaps(); Text("startet und stoppt überall").font(.caption).foregroundStyle(Theme.muted) }
            if !rec.setupProblems.isEmpty { SetupWarning(problems: rec.setupProblems).frame(maxWidth: 420).padding(.top, 10) }
            if let e = rec.error { Banner(text: e, dismiss: { rec.error = nil }).frame(maxWidth: 420) }
        }
        .padding(40)
    }
}

struct MeetingRow: View {
    @EnvironmentObject var rec: Recorder
    let url: URL
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(meetingName(url)).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(dateLabel).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(rec.previews[url].flatMap { $0.isEmpty ? nil : $0 } ?? "Kein Transkript")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.muted).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if rec.projects[url] != nil || rec.durations[url] != nil {
                    HStack(spacing: 8) {
                        if let p = rec.projects[url] { Label(p, systemImage: "folder") }
                        if let d = rec.durations[url] { Label(durationString(d), systemImage: "clock") }
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).padding(.top, 1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(selected ? Theme.beige : hover ? Theme.fill : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hover = $0 }
    }

    private var dateLabel: String {
        let d = rec.modified(url)
        let cal = Calendar.current
        return cal.isDateInToday(d) || cal.isDateInYesterday(d)
            ? d.formatted(.dateTime.hour().minute().locale(Locale(identifier: "de_CH")))
            : d.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "de_CH")))
    }
}

// Text tab with an underline; live bars instead of an icon while recording.
struct TabButton: View {
    let title: String
    var icon: String? = nil
    let selected: Bool
    var live = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                HStack(spacing: 7) {
                    if live { LiveBars() } else if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                    Text(title).font(.system(size: 15, weight: selected ? .semibold : .medium))
                }
                Rectangle().fill(selected ? Color.primary : .clear).frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected || hover ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.muted))
        .animation(.snappy(duration: 0.2), value: selected)
        .onHover { hover = $0 }
        .padding(.bottom, -1)
    }
}

// Speaker name above a run of lines; click to rename everywhere in the meeting (same name twice = merged).
struct SpeakerHeader: View {
    let name: String
    let editable: Bool
    let rename: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var hover = false

    var body: some View {
        Button { draft = name; editing = true } label: {
            HStack(spacing: 4) {
                Text(name)
                if editable { Image(systemName: "pencil").font(.caption2).opacity(hover ? 0.8 : 0) }
            }
        }
        .buttonStyle(.plain)
        .disabled(!editable)
        .onHover { hover = $0 }
        .help("Sprecher umbenennen")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Wer ist \(name)?").font(.headline)
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit { rename(draft); editing = false }
                Text("Gilt für das ganze Meeting. Ein Name, der schon vorkommt, führt beide zusammen.")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 220, alignment: .leading)
                HStack {
                    Spacer()
                    Button("Abbrechen") { editing = false }
                    Button("Umbenennen") { rename(draft); editing = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }
}

// "Zusammenfassung" tab: the summary section of the meeting file as cards, or a button to create it.
struct SummaryView: View {
    @EnvironmentObject var rec: Recorder
    @EnvironmentObject var live: LiveTranscriber

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !rec.summary.isEmpty {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, s in card(s.title, s.lines) }
                } else if rec.state != .idle || live.phase == .summarizing || rec.summarizing {
                    placeholder(icon: "sparkles", title: rec.state == .recording ? "Kommt nach dem Meeting" : "Wird erstellt …",
                                text: "Entscheidungen, To-dos und offene Punkte erscheinen hier.", busy: rec.state != .recording)
                } else if rec.viewing != nil {
                    placeholder(icon: "sparkles", title: "Noch keine Zusammenfassung",
                                text: "Läuft lokal mit Ollama (oder Claude, je nach Einstellung).", busy: false)
                    Button { rec.summarize() } label: {
                        Label("Zusammenfassung erstellen", systemImage: "sparkle")
                            .padding(.horizontal, 16).frame(height: 40)
                            .background(Theme.beige, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle()).font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                }
            }
            .font(.system(size: 15))
            .textSelection(.enabled)
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 40).padding(.vertical, 24)
        }
    }

    private var sections: [(title: String, lines: [String])] {
        var out: [(String, [String])] = [("", [])]
        for line in rec.summary.components(separatedBy: "\n") {
            if line.hasPrefix("### ") { out.append((String(line.dropFirst(4)), [])) }
            else if !line.trimmingCharacters(in: .whitespaces).isEmpty { out[out.count - 1].1.append(line) }
        }
        return out.filter { !$0.1.isEmpty }
    }

    private func icon(_ title: String) -> String {
        let t = title.lowercased()
        if t.contains("to-do") || t.contains("todo") || t.contains("aufgabe") { return "checklist" }
        if t.contains("entscheid") { return "checkmark.seal" }
        if t.contains("offen") || t.contains("frage") { return "questionmark.circle" }
        return "text.alignleft"
    }

    private func card(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty {
                Label { SectionLabel(title) } icon: { Image(systemName: icon(title)).foregroundStyle(Theme.muted) }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.bottom, 2)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in row(line) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Theme.soft, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    @ViewBuilder private func row(_ line: String) -> some View {
        if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: line.hasPrefix("- [x] ") ? "checkmark.circle.fill" : "circle").foregroundStyle(line.hasPrefix("- [x] ") ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.muted))
                inline(String(line.dropFirst(6)))
            }
        } else if line.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(.secondary).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                inline(String(line.dropFirst(2)))
            }
        } else {
            inline(line).lineSpacing(3)
        }
    }

    private func inline(_ md: String) -> Text {
        Text((try? AttributedString(markdown: md)) ?? AttributedString(md))
    }

    private func placeholder(icon: String, title: String, text: String, busy: Bool) -> some View {
        VStack(spacing: 10) {
            if busy { ProgressView().controlSize(.regular) }
            else { Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(Theme.muted) }
            Text(title).font(Theme.title(20))
            Text(text).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 50)
    }
}
