import AppKit
import SottoCore
import SwiftUI

// The settings panel of DESIGN.md 11: a root page and one level of pages pushed over it.

extension SettingsPage {
    var title: String {
        switch self {
        case .notifications: "Notifications"
        case .chats: "Chat settings"
        case .data: "Data and storage"
        case .privacy: "Privacy and security"
        case .connection: "Connection"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .notifications: "bell.fill"
        case .chats: "bubble.left.fill"
        case .data: "arrow.up.arrow.down"
        case .privacy: "lock.fill"
        case .connection: "antenna.radiowaves.left.and.right"
        case .advanced: "gearshape.2.fill"
        }
    }

    var tile: Color {
        switch self {
        case .notifications: .settingsIconBg1
        case .chats: .settingsIconBg4
        case .data: .settingsIconBg2
        case .privacy: .settingsIconBg3
        case .connection: .settingsIconBg5
        case .advanced: .settingsIconBg6
        }
    }
}

struct SettingsPanel: View {
    @Bindable var model: AppModel
    let window: CGSize
    @State private var heights: [SettingsPage?: CGFloat] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let full = window.width < Metrics.settingsFullBelow
        let width = full ? window.width : min(max(window.width - 2 * Metrics.settingsSide, Metrics.settingsMinWidth), Metrics.settingsMaxWidth)
        let margin = window.height < 600 ? Metrics.settingsTopShort : Metrics.settingsTop
        let tallest = full ? window.height : window.height - 2 * margin
        let page = model.settingsPage
        let height = full ? window.height : min(Metrics.settingsBar + (heights[page] ?? 480), tallest)
        let pushed = page != nil
        ZStack(alignment: .top) {
            rootPage
                .offset(x: pushed && !reduceMotion ? -Metrics.pageShift : 0)
                .overlay { Color.slideFadeOutBg.opacity(pushed && !reduceMotion ? 1 : 0).allowsHitTesting(false) }
                .opacity(pushed && reduceMotion ? 0 : 1)
            if let page {
                content(of: page)
                    .background(Rectangle().fill(Color.boxBg).shadow(color: .black.opacity(0.12), radius: 6, x: -3))
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: full ? 0 : Metrics.boxRadius))
        .background(
            RoundedRectangle(cornerRadius: full ? 0 : Metrics.boxRadius)
                .fill(Color.boxBg)
                .shadow(color: .shadow, radius: 12, y: 4)
        )
        .animation(reduceMotion ? Motion.reduced : Motion.page, value: page)
        .animation(reduceMotion ? nil : Motion.page, value: height)
    }

    private func measured(_ page: SettingsPage?) -> (CGFloat) -> Void {
        { heights[page] = $0 }
    }

    private var rootPage: some View {
        SettingsPageView(title: "Settings", close: { model.modal = nil }, height: measured(nil)) {
            SettingsRoot(model: model)
        }
    }

    @ViewBuilder
    private func content(of page: SettingsPage) -> some View {
        SettingsPageView(title: page.title, back: { model.settingsPage = nil }, height: measured(page)) {
            switch page {
            case .notifications: NotificationsPage(model: model)
            case .chats: ChatSettingsPage(model: model)
            case .data: DataPage(model: model)
            case .privacy: PrivacyPage(model: model)
            case .connection: ConnectionPage(model: model)
            case .advanced: AdvancedPage(model: model)
            }
        }
    }
}

/// A page: the top bar with the title and a close or back button, and the content under it,
/// which scrolls when the panel is too low.
struct SettingsPageView<Content: View>: View {
    let title: String
    var back: (() -> Void)?
    var close: (() -> Void)?
    let height: (CGFloat) -> Void
    @ViewBuilder let content: () -> Content
    @State private var scrolled = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                Text(title)
                    .font(Fonts.boxTitle)
                    .foregroundStyle(Color.boxTitleFg)
                    .padding(.leading, back == nil ? Metrics.boxPad : Metrics.settingsIconTextLeft)
                if let back { BackButton(action: back) }
                if let close {
                    HStack {
                        Spacer()
                        IconButton(symbol: "xmark", size: 14, label: "Close settings", side: 48, action: close)
                            .frame(height: Metrics.settingsBar)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.settingsBar, maxHeight: Metrics.settingsBar, alignment: .leading)
            .background(Color.boxBg)
            .overlay(alignment: .bottom) {
                if scrolled { Rectangle().fill(Color.divider).frame(height: 1) }
            }
            .zIndex(1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("settingsPage")) } action: { frame in
                        height(frame.height)
                        scrolled = frame.minY < -0.5
                    }
            }
            .coordinateSpace(name: "settingsPage")
        }
        .background(Color.boxBg)
    }
}

struct BackButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17))
                .foregroundStyle(hover ? Color.composeIconFgOver : Color.composeIconFg)
                .frame(width: 40, height: 40)
                .background(Circle().fill(hover ? Color.windowBgOver : .clear))
                .frame(width: 60, height: Metrics.settingsBar)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.hover, value: hover)
        .accessibilityLabel("Back")
    }
}

// MARK: Shared rows (DESIGN.md 11.1)

/// Hover and pressed backgrounds of a settings row.
struct RowStyle: ButtonStyle {
    var danger = false

    func makeBody(configuration: Configuration) -> some View {
        Hovering(pressed: configuration.isPressed, danger: danger) { configuration.label }
    }

    private struct Hovering<Label: View>: View {
        let pressed: Bool
        let danger: Bool
        @ViewBuilder let label: () -> Label
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            label()
                .background(
                    pressed && enabled ? Color.windowBgRipple
                        : hover && enabled ? (danger ? Color.dangerBgOver : Color.windowBgOver) : .clear
                )
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .animation(Motion.hover, value: hover)
        }
    }
}

struct SettingsTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(color)
            .frame(width: Metrics.settingsTile, height: Metrics.settingsTile)
            .overlay(Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Color.settingsIconFg))
            .accessibilityHidden(true)
    }
}

/// A button row, or a status row when `action` is nil.
struct SettingsRow: View {
    let title: String
    var tile: (symbol: String, color: Color)?
    var icon: String?
    var value: String?
    var help: String?
    var danger = false
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) { label }.buttonStyle(RowStyle(danger: danger))
        } else {
            label.accessibilityElement(children: .combine)
        }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Fonts.settingsRow)
                .foregroundStyle(danger ? Color.danger : Color.windowBoldFg)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let value {
                Text(value)
                    .font(Fonts.settingsRow)
                    .foregroundStyle(Color.accentText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(help ?? "")
            }
        }
        .padding(.leading, tile != nil || icon != nil ? Metrics.settingsIconTextLeft : Metrics.settingsTextLeft)
        .padding(.trailing, value != nil ? 23 : Metrics.settingsTextLeft)
        .frame(height: Metrics.settingsRow)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            if let tile {
                SettingsTile(symbol: tile.symbol, color: tile.color).padding(.leading, 20)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.menuIconFg)
                    .frame(width: Metrics.settingsTile)
                    .padding(.leading, 20)
            }
        }
    }
}

struct ToggleKnob: View {
    let on: Bool

    var body: some View {
        ZStack {
            Capsule().fill(on ? Color.accent : Color.checkboxFg).frame(width: 28, height: 14)
            Circle()
                .fill(Color.windowBg)
                .overlay(Circle().strokeBorder(on ? Color.accent : Color.checkboxFg, lineWidth: 2))
                .frame(width: 16, height: 16)
                .offset(x: on ? 9 : -9)
        }
        .frame(width: 34, height: 20)
        .animation(Motion.toggle, value: on)
    }
}

struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    var enabled = true

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 12) {
                Text(title)
                    .font(Fonts.settingsRow)
                    .foregroundStyle(Color.windowBoldFg)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                ToggleKnob(on: isOn)
            }
            .padding(.leading, Metrics.settingsTextLeft)
            .padding(.trailing, 20)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: Metrics.settingsRow)
        }
        .buttonStyle(RowStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

struct SectionTitle: View {
    let text: String
    var value: String?

    var body: some View {
        HStack {
            Text(text).font(Fonts.settingsSection).foregroundStyle(Color.accentText)
            Spacer()
            if let value { Text(value).font(Fonts.settingsRow).foregroundStyle(Color.accentText) }
        }
        .padding(EdgeInsets(top: 7, leading: 22, bottom: 9, trailing: value == nil ? 10 : 23))
    }
}

/// The band between two groups.
struct GroupGap: View {
    var body: some View {
        Rectangle().fill(Color.windowBgOver).frame(height: Metrics.settingsGroupGap)
    }
}

/// An explanation under a group, on the band.
struct Hint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Fonts.hint)
            .foregroundStyle(Color.windowSubFg)
            .fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: 8, leading: 22, bottom: 16, trailing: 22))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.windowBgOver)
    }
}

struct RadioCircle: View {
    let selected: Bool

    var body: some View {
        ZStack {
            Circle().strokeBorder(selected ? Color.accent : Color.checkboxFg, lineWidth: 2)
            Circle().fill(Color.accent).frame(width: 10, height: 10).opacity(selected ? 1 : 0)
        }
        .frame(width: 22, height: 22)
        .animation(Motion.toggle, value: selected)
    }
}

struct CheckSquare: View {
    let checked: Bool
    var size: CGFloat = 22
    var color = Color.accent

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.checkboxFg, lineWidth: 2).opacity(checked ? 0 : 1)
            RoundedRectangle(cornerRadius: 4).fill(color).opacity(checked ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
                .opacity(checked ? 1 : 0)
        }
        .frame(width: size, height: size)
        .animation(Motion.toggle, value: checked)
    }
}

struct RadioRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                RadioCircle(selected: selected)
                Text(title).font(Fonts.settingsRow).foregroundStyle(Color.windowBoldFg)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 5, leading: 22, bottom: 5, trailing: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A slider over a fixed list of stops.
struct StopSlider: View {
    let count: Int
    @Binding var index: Int
    var label = ""

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = width * CGFloat(index) / CGFloat(max(count - 1, 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.sliderBgInactive).frame(height: 3)
                Capsule().fill(Color.sliderBgActive).frame(width: x, height: 3)
                Circle().fill(Color.sliderBgActive).frame(width: 15, height: 15).offset(x: x - 7.5)
            }
            .frame(height: 15)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let step = (drag.location.x / max(width, 1) * CGFloat(count - 1)).rounded()
                    let next = min(max(Int(step), 0), count - 1)
                    if next != index { index = next }
                }
            )
        }
        .frame(height: 15)
        .padding(.horizontal, 7.5)
        .padding(EdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 22))
        .animation(Motion.slider, value: index)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: index = min(index + 1, count - 1)
            case .decrement: index = max(index - 1, 0)
            @unknown default: break
            }
        }
    }
}

// MARK: Root page (DESIGN.md 11.2)

struct SettingsRoot: View {
    let model: AppModel

    private var connectionValue: String {
        switch model.connection {
        case .connected: "Connected"
        case .connecting: "Connecting..."
        case .idle: "Not connected"
        case .stopped: "Can not connect"
        }
    }

    var body: some View {
        cover
        GroupGap()
        ForEach([SettingsPage.notifications, .chats, .data, .privacy], id: \.self) { page in
            SettingsRow(title: page.title, tile: (page.symbol, page.tile)) { model.settingsPage = page }
        }
        GroupGap()
        SettingsRow(title: SettingsPage.connection.title, tile: (SettingsPage.connection.symbol, SettingsPage.connection.tile), value: connectionValue) {
            model.settingsPage = .connection
        }
        SettingsRow(title: SettingsPage.advanced.title, tile: (SettingsPage.advanced.symbol, SettingsPage.advanced.tile)) {
            model.settingsPage = .advanced
        }
        GroupGap()
        Text("Sotto \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
            .font(Fonts.hint)
            .foregroundStyle(Color.windowSubFg)
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.windowBgOver)
    }

    /// The own avatar, the short id and the QR button. The name line comes with the profile.
    private var cover: some View {
        HStack(spacing: 10) {
            Avatar(id: model.myID, name: "Me", size: Metrics.bigAvatar)
            Text(model.myID.count == 64 ? "\(model.myID.prefix(8))...\(model.myID.suffix(8))" : model.myID)
                .font(Fonts.idField)
                .foregroundStyle(Color.windowSubFg)
                .textSelection(.enabled)
                .help(model.myID)
            Spacer(minLength: 0)
            IconButton(symbol: "qrcode", size: 18, label: "My id", color: .accentText, hoverColor: .accentText, side: 34) {
                model.settingsDialog = .myID
            }
            .padding(.trailing, 5)
        }
        .padding(.leading, 22)
        .frame(height: 104)
    }
}

// MARK: Notifications (DESIGN.md 11.3)

struct NotificationsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        SectionTitle(text: "macOS notifications")
        SettingsToggle(title: "Show notifications", isOn: $model.settings.notifications)
        SettingsToggle(title: "Show sender name", isOn: $model.settings.notificationSender)
        SettingsToggle(title: "Show message preview", isOn: $model.settings.notificationPreview)
        Hint(text: "Without a preview, a notification only says that a message arrived.")
        SectionTitle(text: "Sound")
        SettingsToggle(title: "Play a sound", isOn: $model.settings.sound)
        GroupGap()
        SectionTitle(text: "Dock")
        SettingsToggle(title: "Show unread count on the Dock icon", isOn: $model.settings.dockBadge)
        GroupGap()
        previewCard
            .padding(EdgeInsets(top: 20, leading: 40, bottom: 58, trailing: 40))
    }

    private var previewCard: some View {
        let sample = "Anna Petrova"
        return HStack(alignment: .top, spacing: 14) {
            Avatar(id: MockData.id(for: sample), name: model.settings.notificationSender ? sample : "Sotto", size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.settings.notificationSender ? sample : "Sotto")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.windowBoldFg)
                Text(model.settings.notificationPreview ? "Are you free tonight?" : "New message")
                    .font(Fonts.hint)
                    .foregroundStyle(Color.windowSubFg)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 11, leading: 14, bottom: 9, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.windowBgOver))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notification preview")
    }
}

// MARK: Chat settings (DESIGN.md 11.4)

struct ChatSettingsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        SectionTitle(text: "Theme")
        HStack(spacing: 4) {
            ForEach(AppSettings.Theme.allCases, id: \.self) { theme in
                if theme != .system { Spacer(minLength: 0) }
                ThemeTile(theme: theme, selected: model.settings.theme == theme) { model.settings.theme = theme }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 8, trailing: 16))
        GroupGap()
        SectionTitle(text: "Text size", value: "\(model.settings.textSize) pt")
        StopSlider(
            count: AppSettings.textSizes.count,
            index: Binding(
                get: { model.settings.textSize - AppSettings.textSizes.lowerBound },
                set: { model.settings.textSize = AppSettings.textSizes.lowerBound + $0 }),
            label: "Text size")
        textPreview
        GroupGap()
        SectionTitle(text: "Chat background")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 76), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 15) {
            ForEach(AppSettings.Background.allCases, id: \.self) { background in
                BackgroundTile(background: background, selected: model.settings.background == background) {
                    model.settings.background = background
                }
            }
        }
        .padding(EdgeInsets(top: 11, leading: 22, bottom: 12, trailing: 10))
        GroupGap()
        SectionTitle(text: "Sending")
        RadioRow(title: "Enter sends the message", selected: !model.settings.sendWithCommandEnter) {
            model.settings.sendWithCommandEnter = false
        }
        RadioRow(title: "Cmd+Enter sends the message", selected: model.settings.sendWithCommandEnter) {
            model.settings.sendWithCommandEnter = true
        }
        .padding(.bottom, 8)
        Hint(text: model.settings.sendWithCommandEnter ? "Enter adds a new line." : "Shift+Enter adds a new line.")
        SectionTitle(text: "Time")
        SettingsToggle(
            title: "24-hour time",
            isOn: Binding(get: { model.clock24 }, set: { model.settings.clock24 = $0 }))
            .padding(.bottom, 8)
    }

    private var textPreview: some View {
        let today = Calendar.current.date(bySettingHour: 14, minute: 5, second: 0, of: Date()) ?? Date()
        return VStack(spacing: 0) {
            MessageRow(message: Message(id: "in", outgoing: false, text: "Hello", date: today), top: true, bottom: true, maxWidth: 300) {}
            MessageRow(message: Message(id: "out", outgoing: true, text: "Hi", date: today), top: true, bottom: true, maxWidth: 300) {}
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(LinearGradient(colors: [model.settings.background.top, model.settings.background.bottom], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct ThemeTile: View {
    let theme: AppSettings.Theme
    let selected: Bool
    let action: () -> Void

    private static let light = (bg: "dfe7d6", inBubble: "ffffff", outBubble: "effdde")
    private static let dark = (bg: "0e1621", inBubble: "182533", outBubble: "2b5278")

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    switch theme {
                    case .light: chat(Self.light)
                    case .dark: chat(Self.dark)
                    case .system:
                        chat(Self.light)
                        chat(Self.dark).mask(Diagonal())
                    }
                }
                .frame(width: 80, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accent, lineWidth: 2).opacity(selected ? 1 : 0))
                Text(theme.title).font(Fonts.hint).foregroundStyle(selected ? Color.accentText : Color.windowSubFg)
            }
            .animation(Motion.toggle, value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.title) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func chat(_ colors: (bg: String, inBubble: String, outBubble: String)) -> some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: NSColor(hex: colors.bg))
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: NSColor(hex: colors.inBubble)))
                .frame(width: 40, height: 14).offset(x: 6, y: 8)
            RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: NSColor(hex: colors.outBubble)))
                .frame(width: 40, height: 14).offset(x: 80 - 6 - 40, y: 28)
        }
    }

    private struct Diagonal: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}

struct BackgroundTile: View {
    let background: AppSettings.Background
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [background.top, background.bottom], startPoint: .top, endPoint: .bottom))
                .padding(selected ? 4 : 0)
                .frame(width: 76, height: 76)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accent : Color.divider, lineWidth: selected ? 2 : 1))
                .overlay(alignment: .bottomTrailing) {
                    if selected {
                        Circle().fill(Color.accent).frame(width: 16, height: 16)
                            .overlay(Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                            .padding(6)
                    }
                }
                .overlay {
                    if background == .standard {
                        Text("Default").font(Fonts.hint).foregroundStyle(Color.windowSubFg)
                    }
                }
                .animation(Motion.toggle, value: selected)
        }
        .buttonStyle(.plain)
        .help(background.title)
        .accessibilityLabel("\(background.title) background")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Data and storage (DESIGN.md 11.5)

struct DataPage: View {
    @Bindable var model: AppModel
    @State private var checked: Set<String> = ["Photos", "Files", "Other"]

    private static func limit(_ megabytes: Int) -> String {
        megabytes == 0 ? "Off" : "Up to \(megabytes) MB"
    }

    private func stop(_ value: WritableKeyPath<AppSettings, Int>) -> Binding<Int> {
        Binding(
            get: { AppSettings.downloadStops.firstIndex(of: model.settings[keyPath: value]) ?? 3 },
            set: { model.settings[keyPath: value] = AppSettings.downloadStops[$0] })
    }

    var body: some View {
        SectionTitle(text: "Automatic download")
        SettingsRow(title: "Photos", value: Self.limit(model.settings.autoDownloadPhotos))
        StopSlider(count: AppSettings.downloadStops.count, index: stop(\.autoDownloadPhotos), label: "Photos")
        SettingsRow(title: "Files", value: Self.limit(model.settings.autoDownloadFiles))
        StopSlider(count: AppSettings.downloadStops.count, index: stop(\.autoDownloadFiles), label: "Files")
            .padding(.bottom, 8)
        Hint(text: "Larger photos and files wait for a tap. Small previews always load.")
        SectionTitle(text: "Storage")
        storage
        Hint(text: "Files cleared from the cache can be downloaded again only while they are still stored on the relay.")
        SectionTitle(text: "Download folder")
        SettingsRow(
            title: "Save files to", value: model.downloadFolder.lastPathComponent, help: model.downloadFolder.path
        ) { model.chooseDownloadFolder() }
        SettingsToggle(title: "Ask where to save each file", isOn: $model.settings.askWhereToSave)
            .padding(.bottom, 8)
    }

    /// Photos and files are not kept on this Mac yet, so their categories are empty.
    private var storage: some View {
        let used = model.storageBytes.map(Self.bytes) ?? "..."
        let categories: [(String, Color)] = [("Photos", .settingsIconBg4), ("Files", .settingsIconBg2), ("Other", .settingsIconBg8)]
        return VStack(spacing: 0) {
            SettingsRow(title: "Used by Sotto", value: used)
            Capsule().fill(Color.sliderBgInactive).frame(height: 4).padding(EdgeInsets(top: 6, leading: 22, bottom: 6, trailing: 22))
            ForEach(categories, id: \.0) { name, color in
                Button {
                    if checked.contains(name) { checked.remove(name) } else { checked.insert(name) }
                } label: {
                    HStack(spacing: 0) {
                        CheckSquare(checked: checked.contains(name), size: 20, color: color).clipShape(Circle())
                        Text(name).font(Fonts.hint).foregroundStyle(Color.windowBoldFg).padding(.leading, 14)
                        Text("0%").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.windowBoldFg).padding(.leading, 8)
                        Spacer()
                        Text(Self.bytes(0)).font(Fonts.hint).foregroundStyle(Color.accentText)
                    }
                    .padding(.leading, 22)
                    .padding(.trailing, 20)
                    .frame(height: 44)
                }
                .buttonStyle(RowStyle())
            }
            Button {} label: {
                Text("Clear cache (\(Self.bytes(0)))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.windowSubFg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.windowBgOver))
            }
            .buttonStyle(.plain)
            .disabled(true)
            .help("Nothing is cached yet.")
            .padding(EdgeInsets(top: 6, leading: 12, bottom: 9, trailing: 12))
        }
        .onAppear { model.measureStorage() }
    }

    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func bytes(_ count: Int64) -> String { formatter.string(fromByteCount: count) }
}

// MARK: Privacy and security (DESIGN.md 11.6)

extension AppSettings {
    static func autoLockTitle(_ minutes: Int) -> String {
        switch minutes {
        case 1: "1 minute"
        case 60: "1 hour"
        case let value where value % 60 == 0: "\(value / 60) hours"
        default: "\(minutes) minutes"
        }
    }
}

struct PrivacyPage: View {
    @Bindable var model: AppModel

    var body: some View {
        let on = model.settings.passcode != nil
        SectionTitle(text: "Local passcode")
        SettingsRow(title: "Passcode", value: on ? "On" : "Off") { model.settingsDialog = .passcode }
        if on {
            SettingsRow(title: "Auto-lock", value: AppSettings.autoLockTitle(model.settings.autoLockMinutes)) {
                model.settingsDialog = .autoLock
            }
            SettingsRow(title: "Lock Sotto now", icon: "lock.fill") { model.lock() }
        }
        Hint(text: "The passcode locks the app on this Mac. It is not sent anywhere and it cannot be recovered.")
        SectionTitle(text: "Notifications")
        SettingsToggle(title: "Hide contents while locked", isOn: $model.settings.hideContentsWhileLocked, enabled: on)
        Hint(text: "While Sotto is locked, notifications say only that a message arrived.")
    }
}

// MARK: Connection (DESIGN.md 11.7)

struct ConnectionPage: View {
    @Bindable var model: AppModel
    @State private var error: String?

    private var draft: Binding<String> {
        Binding(get: { model.relayDraft ?? model.relayAddress }, set: { model.relayDraft = $0 })
    }

    var body: some View {
        let changed = draft.wrappedValue != model.relayAddress
        SectionTitle(text: "Relay")
        VStack(alignment: .leading, spacing: 6) {
            BoxField(label: "", placeholder: "wss://relay.example", text: draft, error: error)
            stateLine
        }
        .padding(.horizontal, 22)
        HStack(spacing: 8) {
            Spacer()
            BoxButton(title: "Cancel", enabled: changed) {
                model.relayDraft = nil
                error = nil
            }
            BoxButton(title: "Save", enabled: changed) {
                error = model.setRelay(draft.wrappedValue) == nil ? nil : "Enter a valid address."
                if error == nil { model.relayDraft = nil }
            }
        }
        .padding(EdgeInsets(top: 10, leading: 6, bottom: 10, trailing: 10))
        GroupGap()
        SectionTitle(text: "Outbox")
        SettingsRow(title: "Waiting to send", value: "\(model.waitingCount)")
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private var stateLine: some View {
        HStack(spacing: 8) {
            switch model.connection {
            case .connected:
                Circle().fill(Color.msgStoredIconFg).frame(width: 8, height: 8)
                Text("Connected").foregroundStyle(Color.windowSubFg)
            case .connecting:
                ProgressView().controlSize(.mini).frame(width: 8, height: 8).scaleEffect(0.6)
                Text("Connecting...").foregroundStyle(Color.accentText)
            case .idle:
                Circle().fill(Color.windowSubFg).frame(width: 8, height: 8)
                Text("Not connected").foregroundStyle(Color.windowSubFg)
            case .stopped(let reason):
                Circle().fill(Color.danger).frame(width: 8, height: 8)
                Text("Can not connect").foregroundStyle(Color.danger).help(reason)
                Spacer()
                Button("Try again") { model.reconnect() }
                    .buttonStyle(.plain)
                    .font(Fonts.button)
                    .foregroundStyle(Color.accentText)
            }
        }
        .font(Fonts.hint)
    }
}

// MARK: Advanced (DESIGN.md 11.8)

struct AdvancedPage: View {
    let model: AppModel

    var body: some View {
        let folder = model.dataDirectory ?? Launch.current.directory
        SectionTitle(text: "Data")
        SettingsRow(title: "Data folder", value: folder.lastPathComponent, help: folder.path)
        SettingsRow(title: "Show in Finder", icon: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
        GroupGap()
        SectionTitle(text: "Reset")
        SettingsRow(title: "Reset Sotto...", danger: true) { model.settingsDialog = .reset }
        Hint(text: "Resetting deletes your identity, your contacts and all messages from this Mac.")
    }
}

// MARK: Boxes over the panel

/// Sets, changes or turns off the passcode (DESIGN.md 11.6).
struct PasscodeBox: View {
    enum Mode { case set, manage, change, turnOff }

    @Bindable var model: AppModel
    @State private var mode: Mode
    @State private var current = ""
    @State private var first = ""
    @State private var second = ""
    @State private var error: String?

    init(model: AppModel, mode: Mode? = nil) {
        self.model = model
        _mode = State(initialValue: mode ?? (model.settings.passcode == nil ? .set : .manage))
    }

    private func close() { model.settingsDialog = nil }

    var body: some View {
        switch mode {
        case .manage:
            ModalBox(title: "Passcode") {
                Text("The passcode is on. Sotto locks after the auto-lock time and on Cmd+L.")
                    .font(Fonts.boxBody)
                    .foregroundStyle(Color.windowFg)
                    .fixedSize(horizontal: false, vertical: true)
            } buttons: {
                BoxButton(title: "Cancel", action: close)
                BoxButton(title: "Turn off", danger: true) { mode = .turnOff }
                BoxButton(title: "Change") { mode = .change }.keyboardShortcut(.defaultAction)
            }
        case .turnOff:
            ModalBox(title: "Turn off passcode") {
                BoxField(label: "Current passcode", placeholder: "", text: $current, error: error, focusOnAppear: true, secure: true)
            } buttons: {
                BoxButton(title: "Cancel", action: close)
                BoxButton(title: "Turn off", danger: true) {
                    guard model.settings.passcode?.matches(current) == true else { return error = "Wrong passcode." }
                    model.settings.passcode = nil
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        case .set, .change:
            ModalBox(title: mode == .set ? "Set a passcode" : "Change passcode") {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 23) {
                        if mode == .change {
                            BoxField(label: "Current passcode", placeholder: "", text: $current, focusOnAppear: true, secure: true)
                        }
                        BoxField(label: "Passcode", placeholder: "", text: $first, focusOnAppear: mode == .set, secure: true)
                        BoxField(label: "Repeat passcode", placeholder: "", text: $second, secure: true)
                    }
                    .frame(width: 256)
                    Text(error ?? "The passcode locks the app on this Mac. It is not sent anywhere and it cannot be recovered.")
                        .font(Fonts.hint)
                        .foregroundStyle(error == nil ? Color.windowSubFg : Color.fieldError)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 256, alignment: .leading)
                        .padding(.top, 7)
                }
                .frame(maxWidth: .infinity)
            } buttons: {
                BoxButton(title: "Cancel", action: close)
                BoxButton(title: "Save", action: save).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func save() {
        if mode == .change, model.settings.passcode?.matches(current) != true {
            error = "Wrong passcode."
        } else if first.count < Passcode.minimumLength {
            error = "Use at least \(Passcode.minimumLength) characters."
        } else if first != second {
            error = "The passcodes do not match."
        } else {
            model.settings.passcode = Passcode(first)
            model.lastActivity = Date()
            close()
        }
    }
}

struct AutoLockBox: View {
    @Bindable var model: AppModel

    var body: some View {
        ModalBox(title: "Auto-lock") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(AppSettings.autoLockStops, id: \.self) { minutes in
                    RadioRow(title: AppSettings.autoLockTitle(minutes), selected: model.settings.autoLockMinutes == minutes) {
                        model.settings.autoLockMinutes = minutes
                    }
                    .frame(width: 200)
                }
                Button { model.settings.lockOnSleep.toggle() } label: {
                    HStack(spacing: 15) {
                        CheckSquare(checked: model.settings.lockOnSleep)
                        Text("Lock when the Mac sleeps").font(Fonts.settingsRow).foregroundStyle(Color.windowBoldFg)
                    }
                    .padding(EdgeInsets(top: 13, leading: 22, bottom: 5, trailing: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(model.settings.lockOnSleep ? "On" : "Off")
            }
            .padding(.horizontal, -Metrics.boxPad + 2)
        } buttons: {
            BoxButton(title: "Close") { model.settingsDialog = nil }.keyboardShortcut(.defaultAction)
        }
    }
}

struct ResetBox: View {
    let model: AppModel
    @State private var confirmation: String

    init(model: AppModel, confirmation: String = "") {
        self.model = model
        _confirmation = State(initialValue: confirmation)
    }

    var body: some View {
        ModalBox(title: "Reset Sotto?") {
            VStack(alignment: .leading, spacing: 16) {
                Text(
                    "Your identity, your contacts, all messages, photos and files will be deleted from this Mac. This cannot be undone. People you wrote to will see you as a new contact."
                )
                .font(Fonts.boxBody)
                .foregroundStyle(Color.windowFg)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                BoxField(label: "", placeholder: "Type RESET to confirm", text: $confirmation, focusOnAppear: true)
            }
        } buttons: {
            BoxButton(title: "Cancel") { model.settingsDialog = nil }
            BoxButton(title: "Reset", danger: true, enabled: confirmation == "RESET") { model.resetEverything() }
        }
    }
}

// MARK: Lock screen (DESIGN.md 11.6)

struct LockScreen: View {
    let model: AppModel
    @State private var text = ""
    @State private var wrong = false
    @State private var shakes: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Circle()
                .fill(Color.accent)
                .frame(width: 96, height: 96)
                .overlay(Image(systemName: "lock.shield.fill").font(.system(size: 44)).foregroundStyle(.white))
                .accessibilityHidden(true)
            Text("Sotto is locked")
                .font(Fonts.welcomeTitle)
                .foregroundStyle(Color.windowBoldFg)
                .padding(.top, 24)
            SecureField("", text: $text, prompt: Text("Passcode").foregroundStyle(Color.placeholderFg))
                .textFieldStyle(.plain)
                .font(Fonts.boxBody)
                .foregroundStyle(Color.windowFg)
                .focused($focused)
                .frame(height: Metrics.fieldHeight)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(wrong ? Color.fieldError : focused ? Color.activeLine : Color.divider)
                        .frame(height: focused || wrong ? 2 : 1)
                }
                .modifier(Shake(amount: shakes))
                .onSubmit(unlock)
                .accessibilityLabel("Passcode")
                .padding(.top, 16)
            Text("Wrong passcode.")
                .font(Fonts.hint)
                .foregroundStyle(Color.fieldError)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
                .opacity(wrong ? 1 : 0)
        }
        .frame(width: 256)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.windowBg)
        .onAppear { focused = true }
    }

    private func unlock() {
        if model.unlock(text) {
            wrong = false
        } else {
            wrong = true
            if !reduceMotion { withAnimation(.linear(duration: 0.3)) { shakes += 1 } }
        }
        text = ""
    }

    /// Three swings of 4 points to each side per step of `amount`.
    private struct Shake: GeometryEffect {
        var amount: CGFloat
        var animatableData: CGFloat {
            get { amount }
            set { amount = newValue }
        }

        func effectValue(size: CGSize) -> ProjectionTransform {
            ProjectionTransform(CGAffineTransform(translationX: 4 * sin(amount * .pi * 6), y: 0))
        }
    }
}
