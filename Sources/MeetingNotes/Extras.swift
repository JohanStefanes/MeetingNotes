import Foundation

// Copies each meeting into the Obsidian vault (~/Vault/Meetings) so Claude finds it with the vault notes.
// The vault note is generated: it is rewritten whenever the meeting changes in the app.
enum VaultMirror {
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Vault/Meetings")

    static var enabled: Bool {
        (UserDefaults.standard.object(forKey: "vault") as? Bool ?? true)
            && FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path)
    }

    /// "2026-11-07_1952_kundencall.md" → "Meetings/2026-11-07 19.52 kundencall.md"
    static func noteURL(for md: URL) -> URL {
        let stem = md.deletingPathExtension().lastPathComponent
        let date = String(stem.prefix(10)), time = String(stem.dropFirst(11).prefix(4))
        let stamp = time.count == 4 ? "\(date) \(time.prefix(2)).\(time.suffix(2))" : date
        let name = "\(stamp) \(meetingName(md))".replacingOccurrences(of: "/", with: "-")
        return folder.appendingPathComponent(name).appendingPathExtension("md")
    }

    static func write(_ md: URL) {
        guard enabled, let content = try? String(contentsOf: md, encoding: .utf8) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? note(for: md, content: content).write(to: noteURL(for: md), atomically: true, encoding: .utf8)
    }

    static func remove(_ md: URL) {
        guard enabled else { return }
        try? FileManager.default.removeItem(at: noteURL(for: md))
    }

    static func note(for md: URL, content: String) -> String {
        let stem = md.deletingPathExtension().lastPathComponent
        let people = participants(content).map { "\"\($0)\"" }.joined(separator: ", ")
        let project = header("Projekt", in: content) ?? ""
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var body = content.components(separatedBy: "\n").drop { !$0.hasPrefix("## ") }.joined(separator: "\n")
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ---
        datum: \(stem.prefix(10))
        tags:
          - meeting
        teilnehmer: [\(people)]
        projekt: \(project)
        quelle: \(md.path.replacingOccurrences(of: home, with: "~"))
        ---

        # \(meetingName(md))

        *Automatisch aus MeetingNotes. Änderungen bitte in der App machen, hier werden sie überschrieben.*

        \(body)

        *[[Meetings/Meetings Index|← Meetings]]*

        """
    }

    /// Named speakers from the transcript ("**Anna:**", not "Sprecher 2") plus the "Teilnehmer:" line from the calendar.
    static func participants(_ content: String) -> [String] {
        var names: [String] = []
        if let line = header("Teilnehmer", in: content) {
            names += line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let re = try! NSRegularExpression(pattern: #"\*\*([^*:]{1,40}):\*\*"#)
        let ns = content as NSString
        for m in re.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            names.append(ns.substring(with: m.range(at: 1)))
        }
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && !$0.hasPrefix("Sprecher ") && seen.insert($0.lowercased()).inserted }
    }

    /// "Projekt: X" style line in the meeting header (before the first "## " section).
    static func header(_ key: String, in content: String) -> String? {
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { break }
            if line.hasPrefix("\(key): ") {
                let v = line.dropFirst(key.count + 2).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Sets (or removes, with an empty value) a "Key: value" header line; it goes after the "Audio:" line.
    static func setHeader(_ key: String, _ value: String, in content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        let end = lines.firstIndex { $0.hasPrefix("## ") } ?? lines.count
        if let i = lines[..<end].firstIndex(where: { $0.hasPrefix("\(key): ") }) {
            if value.isEmpty { lines.remove(at: i); if i < lines.count, lines[i].isEmpty { lines.remove(at: i) } }
            else { lines[i] = "\(key): \(value)" }
        } else if !value.isEmpty {
            let at = (lines[..<end].firstIndex { $0.hasPrefix("Audio: ") }).map { $0 + 1 } ?? min(1, lines.count)
            lines.insert(contentsOf: ["", "\(key): \(value)"], at: at)
        }
        return lines.joined(separator: "\n")
    }
}

// Everything the recording pipeline needs outside the app bundle. Shown in the panel when something is missing.
enum SetupCheck {
    static func problems(summary: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        let exists = { (p: String) in fm.fileExists(atPath: p.replacingOccurrences(of: "~", with: home)) }
        let any = { (ps: [String]) in ps.contains(where: exists) }
        var out: [String] = []
        if !any(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]) { out.append("ffmpeg fehlt (brew install ffmpeg)") }
        if !any(["/opt/homebrew/bin/whisper-server", "~/.meeting-notes/src/whisper.cpp/build/bin/whisper-server"]) {
            out.append("whisper-server fehlt (brew install whisper-cpp)")
        }
        let models = ProcessInfo.processInfo.environment["WHISPER_MODELS"] ?? "~/.whisper-models"
        if !exists("\(models)/ggml-large-v3-turbo.bin") { out.append("Whisper-Modell fehlt: \(models)/ggml-large-v3-turbo.bin") }
        if !exists("~/.meeting-notes/venv/bin/python") {
            out.append("Python-Umgebung fehlt (~/.meeting-notes/venv): kein Live-Text, keine Sprecher, keine Zusammenfassung")
        } else if !any(["~/.meeting-notes/venv/lib/python3.11/site-packages/mcp", "~/.meeting-notes/venv/lib/python3.12/site-packages/mcp"]) {
            out.append("MCP für Claude fehlt: ~/.meeting-notes/venv/bin/pip install mcp")
        }
        for (file, what) in [("silero_vad.onnx", "Satzerkennung"), ("sherpa-onnx-whisper-tiny", "Spracherkennung DE/EN")]
        where !exists("~/.meeting-notes/models/\(file)") {
            out.append("Modell für \(what) fehlt: ~/.meeting-notes/models/\(file)")
        }
        // meeting-diarize downloads these itself (~35 MB) on first use, so this is a heads-up, not a hard failure.
        if !exists("~/Library/Application Support/FluidAudio/Models/speaker-diarization") {
            out.append("Sprecher-Modelle werden nach dem ersten Meeting einmalig geladen (Internet nötig, ~35 MB)")
        }
        if summary == "ollama" {
            if !any(["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app"]) {
                out.append("Ollama fehlt: keine lokale Zusammenfassung (brew install ollama)")
            } else if !exists("~/.ollama/models/manifests/registry.ollama.ai/library/qwen2.5/14b-instruct") {
                out.append("Ollama-Modell fehlt: ollama pull qwen2.5:14b-instruct")
            }
        }
        return out
    }
}
