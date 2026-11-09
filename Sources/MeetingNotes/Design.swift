import SwiftUI

// One place for the look: calm warm greys, soft filled surfaces instead of lines, one green signal for "live",
// serif (New York) only for note titles.
enum Theme {
    static let accent = Color(red: 0.12, green: 0.62, blue: 0.42)   // live / stop
    static let radius: CGFloat = 14
    static let canvas = dyn(0xF4F3F0, 0x1B1A18)   // window behind the card
    static let card = dyn(0xFCFCFB, 0x232220)     // main surface
    static let soft = dyn(0xF5F4F1, 0x2A2926)     // grouped blocks on the card
    static let fill = dyn(0xF0EEE9, 0x302E2B)     // bubbles, hover
    static let beige = dyn(0xECE9E2, 0x3B3834)    // primary buttons, selection
    static let line = dyn(0xE6E3DC, 0x3A3733)
    static let muted = dyn(0x6E6A63, 0xA39E95)    // secondary text, 4.5:1 on card
    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static let mono = Font.system(size: 11, weight: .medium).monospacedDigit()

    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let h = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(h >> 16 & 0xFF) / 255, green: CGFloat(h >> 8 & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        })
    }
}

// "HEUTE", "ZULETZT": small spaced caps above a group.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.9).foregroundStyle(Theme.muted)
    }
}

// Buttons sink in a little when pressed: the "satisfying" part.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

// Ring with a dot: the record glyph on beige buttons.
struct RecordDot: View {
    var size: CGFloat = 14
    var body: some View {
        Circle().strokeBorder(lineWidth: size * 0.13).frame(width: size, height: size)
            .overlay(Circle().frame(width: size * 0.42, height: size * 0.42))
            .accessibilityHidden(true)
    }
}

// Beige "Aufnahme starten"; fills the width when `wide`.
struct StartButton: View {
    var height: CGFloat = 44
    var wide = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) { RecordDot(size: height * 0.34); Text("Aufnahme starten") }
                .font(.system(size: height * 0.34, weight: .semibold))
                .padding(.horizontal, 20)
                .frame(maxWidth: wide ? .infinity : nil).frame(height: height)
                .background(Theme.beige, in: RoundedRectangle(cornerRadius: height * 0.28, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut(.defaultAction)
        .help("Aufnahme starten (⌃⌥ Leertaste)")
    }
}

// White pill with a softly pulsing green square, at the bottom of a running meeting.
struct StopPill: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                TimelineView(.animation) { ctx in
                    let p = 0.5 + 0.5 * sin(ctx.date.timeIntervalSinceReferenceDate * 3.2)
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(Theme.accent).frame(width: 14, height: 14)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.accent.opacity(0.28 * (1 - p))).padding(-5 * p))
                }
                Text("Stopp").font(.system(size: 15, weight: .semibold))
            }
            .padding(.leading, 18).padding(.trailing, 22).frame(height: 46)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.07), radius: 12, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel("Stoppen und transkribieren")
        .help("Stoppen & transkribieren (⌃⌥ Leertaste)")
    }
}

// Three bouncing bars next to "Transkript" while recording.
struct LiveBars: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(Theme.accent).frame(width: 3, height: 5 + 9 * (0.5 + 0.5 * sin(t * 6 + Double(i) * 1.1)))
                }
            }
            .frame(height: 14)
        }
        .accessibilityHidden(true)
    }
}

extension View {
    // Small outlined tag: date, duration, project (dashed = editable).
    func pill(dashed: Bool = false) -> some View {
        font(.system(size: 13))
            .padding(.horizontal, 10).frame(height: 30)
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 3] : [])))
    }
}

enum SpeakerColor {
    static let palette: [Color] = [.orange, .blue, .purple, .green, .pink, .teal, .indigo, .brown]
    static func of(_ i: Int) -> Color { palette[i % palette.count] }
}

// Initials in a tinted circle; "Sprecher 2" → "2".
struct Avatar: View {
    let name: String
    let color: Color
    var size: CGFloat = 24

    var body: some View {
        Text(Self.initials(name))
            .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.16), in: Circle())
            .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        if name.hasPrefix("Sprecher ") { return String(name.dropFirst(9)) }
        return name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

// "⌃ ⌥ Leertaste" as small key caps.
struct Keycaps: View {
    var keys = ["⌃", "⌥", "Leertaste"]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { k in
                Text(k)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 17)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Control Option Leertaste")
    }
}

// Inline message with an icon, optionally dismissable (errors, finished transcript, setup hints).
struct Banner<Trailing: View>: View {
    let text: String
    var icon = "exclamationmark.triangle.fill"
    var tint: Color = .red
    var dismiss: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 4)
            trailing
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Schliessen")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.18), lineWidth: 0.5))
    }
}

extension Banner where Trailing == EmptyView {
    init(text: String, icon: String = "exclamationmark.triangle.fill", tint: Color = .red, dismiss: (() -> Void)? = nil) {
        self.init(text: text, icon: icon, tint: tint, dismiss: dismiss) { EmptyView() }
    }
}

struct SetupWarning: View {
    let problems: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Einrichtung unvollständig", systemImage: "wrench.and.screwdriver.fill")
                .font(.callout.weight(.semibold)).foregroundStyle(.orange)
            ForEach(problems, id: \.self) { p in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(.orange.opacity(0.6)).frame(width: 4, height: 4)
                    Text(p)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.orange.opacity(0.2), lineWidth: 0.5))
        .textSelection(.enabled)
    }
}

// Dark disc with a green square: stop in the menu bar panel.
struct StopButton: View {
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: size * 0.09, style: .continuous).fill(Theme.accent)
                .frame(width: size * 0.32, height: size * 0.32)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.primary))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel("Stoppen und transkribieren")
        .help("Stoppen & transkribieren (⌃⌥ Leertaste)")
    }
}

// Window chrome: "Aufnehmen" when idle, live time while recording (stop sits at the bottom of the meeting), progress after.
struct RecordCapsule: View {
    @EnvironmentObject var rec: Recorder

    var body: some View {
        switch rec.state {
        case .idle:
            Button { rec.toggle() } label: {
                HStack(spacing: 7) { RecordDot(size: 12); Text("Aufnehmen") }
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Theme.beige, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
            .font(.system(size: 12, weight: .semibold))
            .help("Neue Aufnahme (⌃⌥ Leertaste)")
        case .recording:
            HStack(spacing: 7) {
                LiveDot(size: 7)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(elapsedString(from: rec.started, to: ctx.date)).monospacedDigit()
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).frame(height: 30)
            .background(Theme.accent.opacity(0.12), in: Capsule())
        case .transcribing:
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Wird fertig …") }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 12).frame(height: 30)
                .background(Theme.fill, in: Capsule())
        }
    }
}

struct Waveform: View {
    let levels: [CGFloat]
    let tint: Color
    var animated = true

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 3) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule()
                        .fill(tint.opacity(0.35 + 0.65 * Double(levels[i])))
                        .frame(height: max(3, levels[i] * geo.size.height))  // silence = row of dots
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(animated ? .easeOut(duration: 0.12) : nil, value: levels)
        .accessibilityHidden(true)
    }
}

struct Chip<Content: View>: View {
    let icon: String
    let text: String
    @ViewBuilder let content: Content

    var body: some View {
        Menu { content } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(text).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.5)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line))
    }
}

struct TypingDots: View {
    var tint: Color = .secondary
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(tint).frame(width: 5, height: 5)
                        .opacity(0.3 + 0.7 * (0.5 + 0.5 * sin(t * 5 - Double(i) * 0.9)))
                }
            }
        }
        .accessibilityLabel("Jemand spricht")
    }
}

// Blinking signal dot for "recording".
struct LiveDot: View {
    var size: CGFloat = 8
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.8)) { ctx in
            Circle().fill(Theme.accent).frame(width: size, height: size)
                .opacity(Int(ctx.date.timeIntervalSince1970 / 0.8) % 2 == 0 ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.4), value: Int(ctx.date.timeIntervalSince1970 / 0.8))
        }
        .accessibilityLabel("Aufnahme läuft")
    }
}


func durationString(_ seconds: Double) -> String {
    let m = Int(seconds / 60)
    return m < 1 ? "< 1 Min." : m < 60 ? "\(m) Min." : "\(m / 60) Std. \(m % 60) Min."
}
