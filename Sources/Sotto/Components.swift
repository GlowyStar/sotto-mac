import AppKit
import SottoCore
import SwiftUI

/// A circle with the contact's gradient and initials (DESIGN.md 3), or its photo filling the
/// circle when the photo is on this Mac (DESIGN.md 16).
struct Avatar: View {
    let id: String
    let name: String
    let size: CGFloat
    var photo: ProfilePhoto?

    var body: some View {
        let colors = AvatarPalette.colors[AvatarPalette.index(for: id)] ?? ("5caffa", "408acf")
        let picture = photo.flatMap { AvatarPictures.image($0, side: size) }
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(nsColor: NSColor(hex: colors.top)), Color(nsColor: NSColor(hex: colors.bottom))],
                        startPoint: .top, endPoint: .bottom)
                )
                .overlay(Text(Self.initials(name)).font(Fonts.initials(for: size)).foregroundStyle(Color.avatarFg))
            if let picture {
                Image(nsImage: picture)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .animation(Motion.picture, value: picture == nil ? nil : photo?.key)
        .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace).prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

/// A rounded pill of service text over the chat background.
struct ServicePill: View {
    let text: String
    @Environment(\.settings) private var settings

    var body: some View {
        Text(text)
            .font(Fonts.service)
            .foregroundStyle(Color.serviceFg)
            .padding(Metrics.servicePad)
            .background(Capsule().fill(settings.background.service))
    }
}

/// An unread counter: height 19, at least 19 wide.
struct Badge: View {
    let count: Int
    var active = false
    var muted = false
    var height = Metrics.badgeHeight

    var body: some View {
        Text("\(count)")
            .font(Fonts.badge)
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(active ? Color.badgeFgActive : Color.badgeFg)
            .padding(.horizontal, Metrics.badgePadding)
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .background(Capsule().fill(fill))
    }

    private var fill: Color {
        switch (active, muted) {
        case (true, true): .badgeBgMutedActive
        case (true, false): .badgeBgActive
        case (false, true): .badgeBgMuted
        case (false, false): .badgeBg
        }
    }
}

/// The mark of an own message (DESIGN.md 7.6 and 20.5): a clock while waiting, one check
/// once stored, two checks once delivered and two in the full colour once read, a danger
/// mark with the reason on hover when it is not sent.
struct StatusMark: View {
    let state: MessageState
    let waitingColor: Color
    let storedColor: Color
    /// The two checks of a message delivered and not read.
    var deliveredColor: Color?
    /// The smaller checks of a chat list row.
    var small = false

    var body: some View {
        switch state {
        case .waiting: mark("clock", waitingColor, label: "Sending")
        case .stored: checks(double: false, storedColor, label: "Sent")
        case .delivered: checks(double: true, deliveredColor ?? storedColor.opacity(0.55), label: "Delivered")
        case .read: checks(double: true, storedColor, label: "Read")
        case .failed(let reason):
            mark("exclamationmark.circle.fill", .danger, label: "Not sent: \(reason)")
                .help("Not sent. \(reason)")
        }
    }

    private func checks(double: Bool, _ color: Color, label: String) -> some View {
        let size = double ? Metrics.checksSize : Metrics.checkSize
        return Checks(double: double)
            .fill(color)
            .frame(width: size.width - (small ? 1 : 0), height: size.height - (small ? 1 : 0))
            .frame(width: Metrics.checksSize.width, alignment: .leading)
            .help(label)
            .accessibilityLabel(label)
            .transition(.opacity)
    }

    private func mark(_ symbol: String, _ color: Color, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(color)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(label)
    }
}

/// A square icon button that darkens its symbol on hover.
struct IconButton: View {
    let symbol: String
    let size: CGFloat
    let label: String
    var color = Color.composeIconFg
    var hoverColor = Color.composeIconFgOver
    var side = Metrics.headerButton
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(hover ? hoverColor : color)
                .frame(width: side, height: side)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A text button of a box: no fill, a tinted fill on hover (DESIGN.md 5.10).
struct BoxButton: View {
    let title: String
    var danger = false
    var enabled = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.button)
                .foregroundStyle(danger ? Color.danger : Color.accentText)
                .padding(.horizontal, Metrics.buttonPadH)
                .frame(height: Metrics.buttonHeight)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.buttonRadius)
                        .fill(hover && enabled ? (danger ? Color.dangerBgOver : Color.lightButtonBgOver) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
    }
}

/// A filled accent button (first launch).
struct FilledButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label()
                .font(Fonts.button)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.buttonRadius).fill(hover ? Color.accentOver : Color.accent)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
    }
}

/// The id in 16 groups of 4, 4 groups per line (DESIGN.md 7.2).
struct IDBlock: View {
    let id: String
    /// Characters in a group: 4 for an id, 5 for a safety number (DESIGN.md 21.2).
    var group = 4

    /// The lines of the block: four groups each, one space between two groups.
    static func lines(_ id: String, group: Int) -> [String] {
        let groups = stride(from: 0, to: id.count, by: group).map { start -> String in
            let from = id.index(id.startIndex, offsetBy: start)
            return String(id[from..<id.index(from, offsetBy: group, limitedBy: id.endIndex)!])
        }
        return stride(from: 0, to: groups.count, by: 4).map { groups[$0..<min($0 + 4, groups.count)].joined(separator: " ") }
    }

    var body: some View {
        Text(Self.lines(id, group: group).joined(separator: "\n"))
            .font(Fonts.id)
            .lineSpacing(5)
            .multilineTextAlignment(.center)
            .foregroundStyle(Color.windowFg)
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.windowBgOver))
    }
}

/// The "end-to-end encrypted" line with its small lock.
struct EncryptedLine: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill").font(.system(size: 10))
            Text("end-to-end encrypted").font(Fonts.headerSubtitle)
        }
        .foregroundStyle(Color.windowSubFg)
    }
}

/// A row with hover background, used for panel actions and the context of settings.
struct HoverRow<Content: View>: View {
    var height = Metrics.panelRow
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
                .background(hover ? Color.windowBgOver : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
    }
}

/// An area that moves the window when dragged and zooms it on a double click.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

@MainActor
enum Formats {
    private static let time24: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("Hm")
        return formatter
    }()
    private static let time12: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("hm")
        return formatter
    }()

    /// Whether the locale writes times on a 24-hour clock.
    static let localeUses24Hours: Bool = {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "H"
        return format.contains("H") || format.contains("k")
    }()
    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter
    }()
    private static let short: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter
    }()
    private static let dayMonth: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        return formatter
    }()
    private static let dayMonthYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy"
        return formatter
    }()

    static func clock(_ date: Date, h24: Bool) -> String { (h24 ? time24 : time12).string(from: date) }

    /// The time of a list row: today the clock, within the week the weekday, older the date.
    static func row(_ date: Date, h24: Bool) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return clock(date, h24: h24) }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day,
            days < 7
        {
            return weekday.string(from: date)
        }
        return short.string(from: date)
    }

    /// The text of a date separator.
    static func separator(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        return (sameYear ? dayMonth : dayMonthYear).string(from: date)
    }
}
