import SwiftUI

// 20 s of your voice → ~/.meeting-notes/voice.npy (diarize.py --enroll). With it the speaker step labels you by name
// even when there is no Mac sound channel to tell you apart (meetings in a room).
enum VoiceEnroll {
    static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".meeting-notes")
    static var exists: Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent("voice.npy").path) }
    static let seconds = 20
    static let text = """
    Ich lese jetzt einen kurzen Text vor, damit die App meine Stimme kennenlernt. \
    In Meetings spreche ich oft über Projekte, Termine und Aufgaben, manchmal auf Deutsch und manchmal auf Englisch. \
    Wenn ich nachdenke, werde ich etwas langsamer, und wenn mir etwas wichtig ist, spreche ich lauter. \
    Am Ende eines Meetings fasse ich gerne zusammen, wer was bis wann erledigt. \
    Okay, let's wrap this up: I'll send the notes after the call.
    """
}

@MainActor
final class VoiceWindow {
    static let shared = VoiceWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Stimmprobe"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: VoiceEnrollView())
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct VoiceEnrollView: View {
    enum Phase: Equatable { case idle, recording(Int), saving, done, failed(String) }
    @State private var phase = Phase.idle
    @AppStorage("device") private var device = "default"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lies den Text in normalem Tempo vor, so wie du in Meetings sprichst.")
                .font(.callout).foregroundStyle(.secondary)
            Text(VoiceEnroll.text)
                .font(.system(size: 15)).lineSpacing(4)
                .padding(14)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                switch phase {
                case .idle, .failed:
                    Button(VoiceEnroll.exists ? "Neu aufnehmen (\(VoiceEnroll.seconds) s)" : "Aufnahme starten (\(VoiceEnroll.seconds) s)",
                           action: record)
                        .controlSize(.large).keyboardShortcut(.defaultAction)
                case .recording(let left):
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text("Aufnahme … noch \(left) s").monospacedDigit()
                case .saving:
                    ProgressView().controlSize(.small)
                    Text("Stimme wird gespeichert …")
                case .done:
                    Label("Gespeichert. Ab jetzt erkennt die App dich auch ohne Mac-Ton.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Spacer()
            }
            if case .failed(let msg) = phase { Text(msg).font(.caption).foregroundStyle(.red) }
            Text("Bleibt lokal: gespeichert wird nur ein Stimm-Fingerabdruck in ~/.meeting-notes/voice.npy, nicht die Aufnahme.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 420)
    }

    private func record() {
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("meetingnotes-voice.wav")
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.fileExists(atPath: $0) }
        guard let ffmpeg, let script = Bundle.main.url(forResource: "diarize", withExtension: "py") else {
            phase = .failed("ffmpeg oder diarize.py fehlt."); return
        }
        let rec = Process()
        rec.executableURL = URL(fileURLWithPath: ffmpeg)
        rec.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-f", "avfoundation", "-i", ":\(device)",
                         "-t", String(VoiceEnroll.seconds), "-ac", "1", "-ar", "16000", sample.path]
        rec.standardInput = FileHandle.nullDevice
        rec.terminationHandler = { p in
            Task { @MainActor in
                guard p.terminationStatus == 0 else { phase = .failed("Aufnahme fehlgeschlagen (Mikrofonzugriff?)."); return }
                phase = .saving
                let py = Process()
                py.executableURL = VoiceEnroll.dir.appendingPathComponent("venv/bin/python")
                py.arguments = ["-I", script.path, "--enroll", sample.path]
                py.standardOutput = FileHandle.nullDevice
                py.standardError = FileHandle(forWritingAtPath: Recorder.logFile.path) ?? FileHandle.nullDevice
                py.terminationHandler = { p in
                    Task { @MainActor in
                        try? FileManager.default.removeItem(at: sample)   // only the voice vector is kept
                        phase = p.terminationStatus == 0 ? .done : .failed("Zu kurz oder zu leise, bitte nochmal.")
                    }
                }
                do { try py.run() } catch { phase = .failed(error.localizedDescription) }
            }
        }
        do { try rec.run() } catch { phase = .failed(error.localizedDescription); return }
        phase = .recording(VoiceEnroll.seconds)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            Task { @MainActor in
                guard case .recording(let left) = phase, left > 1 else { t.invalidate(); return }
                phase = .recording(left - 1)
            }
        }
    }
}
