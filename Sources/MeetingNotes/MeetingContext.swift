import AppKit
import EventKit

// What the app knows about a meeting before it starts: the calendar event (title, attendees), the own vocabulary
// file, and whether a call app has just started using the microphone.
final class MeetingContext {
    static let shared = MeetingContext()
    private let store = EKEventStore()
    private var calendarAllowed = false

    /// ~/Meetings/Wörterbuch.txt: one term per line (or comma separated), "#" starts a comment.
    let vocabularyFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Meetings/Wörterbuch.txt")

    func requestCalendar() {
        store.requestFullAccessToEvents { ok, _ in self.calendarAllowed = ok }
    }

    /// The event running now (started up to 15 min ago or starting within 10 min), preferring the one closest to now.
    func currentEvent(at now: Date = Date()) -> EKEvent? {
        guard calendarAllowed || EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(600),
                                            calendars: nil)
        return store.events(matching: pred)
            .filter { !$0.isAllDay && $0.endDate > now && $0.startDate < now.addingTimeInterval(600) }
            .min { abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now)) }
    }

    static func attendeeNames(_ event: EKEvent?) -> [String] {
        (event?.attendees ?? []).compactMap { p in
            // name, or the readable part of the address ("anna.muster@x.ch" → "anna muster")
            p.name ?? p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                .split(separator: "@").first.map { $0.replacingOccurrences(of: ".", with: " ") }
        }
    }

    /// People in the meeting including you, from the invite; nil without attendees (then nothing is capped).
    static func headcount(_ event: EKEvent?) -> Int? {
        guard let people = event?.attendees, !people.isEmpty else { return nil }
        return people.count + (people.contains(where: \.isCurrentUser) ? 0 : 1)
    }

    func vocabulary() -> [String] {
        guard let text = try? String(contentsOf: vocabularyFile, encoding: .utf8) else { return [] }
        return Self.terms(text)
    }

    static func terms(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "" }
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// whisper prompt terms: own vocabulary first, then attendees, without duplicates.
    static func vocab(own: [String], attendees: [String]) -> String {
        var seen = Set<String>()
        return (own + attendees).filter { seen.insert($0.lowercased()).inserted }.joined(separator: ", ")
    }

    func openVocabulary() {
        if !FileManager.default.fileExists(atPath: vocabularyFile.path) {
            try? FileManager.default.createDirectory(at: vocabularyFile.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? """
            # Eigene Begriffe für die Transkription: Namen, Firmen, Fachwörter.
            # Ein Begriff pro Zeile (oder mit Komma getrennt). Zeilen mit # werden ignoriert.

            """.write(to: vocabularyFile, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(vocabularyFile)
    }

    // MARK: meeting detection

    static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager", "com.apple.FaceTime", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
        "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
    ]
    // Browsers use the mic for many things; they only count while a calendar event is running (Google Meet etc.).
    static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
                                        "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser"]

    /// Bundle ID of a call that is using the microphone right now, if any.
    func activeCall() -> String? {
        let using = SystemAudio.processesUsingInput()
        if let app = using.first(where: Self.callApps.contains) { return app }
        if currentEvent() != nil, let b = using.first(where: Self.browsers.contains) { return b }
        return nil
    }

    static func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
    }
}
