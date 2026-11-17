import AppKit
import SottoCore
import SwiftUI

/// The open chat: header, messages, compose bar and, when it fits, the contact panel.
struct ChatScreen: View {
    @Bindable var model: AppModel
    let contact: Contact
    let singleColumn: Bool
    let width: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var panelFits: Bool { width - Metrics.panelWidth - 1 >= Metrics.chatMin }

    var body: some View {
        VStack(spacing: 0) {
            if model.chatSearch != nil {
                ChatSearchTopBar(model: model)
            } else {
                ChatHeader(model: model, contact: contact, singleColumn: singleColumn) {
                    if panelFits {
                        withAnimation(Motion.pick(Motion.column, reduce: reduceMotion)) { model.panelOpen.toggle() }
                    } else {
                        model.modal = .contactInfo(contact.id)
                    }
                }
            }
            HStack(spacing: 0) {
                GeometryReader { area in
                    VStack(spacing: 0) {
                        MessageList(model: model, contact: contact)
                        if model.chatSearch != nil {
                            ChatSearchBottomBar(model: model)
                        } else {
                            ComposeBar(model: model, chatID: contact.id)
                        }
                    }
                    .overlay(alignment: .bottomLeading) { attachMenu }
                    .overlay { if let drop = model.drop { DropOverlay(state: drop).transition(.opacity) } }
                    .onDrop(of: [.fileURL], delegate: ChatDropDelegate(model: model, height: area.size.height))
                }
                if model.panelOpen && panelFits {
                    Rectangle().fill(Color.divider).frame(width: 1)
                    ContactPanel(model: model, contact: contact, asBox: false)
                        .frame(width: Metrics.panelWidth)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                }
            }
        }
    }
}

extension ChatScreen {
    /// The popup of the attach button, over a layer that closes it on a click elsewhere.
    @ViewBuilder
    var attachMenu: some View {
        if model.attachMenuOpen {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.attachMenuOpen = false }
                AttachMenu(model: model)
                    .padding(.bottom, Metrics.composeHeight + Metrics.attachMenuAbove)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.95, anchor: .bottomLeading)))
            }
        }
    }
}

struct ChatHeader: View {
    let model: AppModel
    let contact: Contact
    let singleColumn: Bool
    let togglePanel: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if singleColumn {
                IconButton(symbol: "chevron.left", size: 17, label: "Back to chats") { model.closeChat() }
                    .padding(.leading, 6)
            }
            Button(action: togglePanel) {
                HStack(spacing: Metrics.headerTitleGap) {
                    Avatar(id: contact.id, name: contact.name, size: Metrics.headerAvatar, photo: contact.profile?.avatar)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(contact.name)
                            .font(Fonts.headerTitle)
                            .foregroundStyle(Color.windowBoldFg)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            EncryptedLine().lineLimit(1)
                            if let timer = model.timers[contact.id], timer > 0 {
                                TimerLabel(seconds: timer, color: .windowSubFg)
                                    .fixedSize()
                                    .layoutPriority(1)
                                    .help("Disappearing messages: \(TimerChoices.title(timer))")
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, singleColumn ? 0 : Metrics.headerAvatarLeft)
            .accessibilityLabel("\(contact.name), contact info")
            Spacer(minLength: 8)
            IconButton(symbol: "magnifyingglass", size: 18, label: "Search in chat") { model.openChatSearch() }
            IconButton(symbol: "sidebar.right", size: 18, label: "Contact info", action: togglePanel)
            Menu {
                Menu("Disappearing messages") { TimerMenuItems(model: model, chatID: contact.id) }
                Button("Contact info", action: togglePanel)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.composeIconFg)
                    .frame(width: Metrics.headerButton, height: Metrics.headerButton)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
            .help("More")
            .padding(.trailing, 8)
        }
        .frame(height: Metrics.topBarHeight)
        .background(Color.topBarBg)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.divider).frame(height: 1) }
    }
}

/// One line of the message list.
enum ChatItem: Identifiable {
    case date(Date)
    case unread
    case message(Message, top: Bool, bottom: Bool)
    /// A change of the disappearing timer (DESIGN.md 20.7).
    case service(TimerChange)

    var id: String {
        switch self {
        case .date(let date): "date-\(date.timeIntervalSinceReferenceDate)"
        case .unread: "unread"
        case .message(let message, _, _): message.id
        case .service(let change): "timer-\(change.date.timeIntervalSinceReferenceDate)-\(change.seconds)"
        }
    }

    /// The day of a date pill, a message or a service line.
    var day: Date? {
        switch self {
        case .date(let date): date
        case .unread: nil
        case .message(let message, _, _): message.date
        case .service(let change): change.date
        }
    }

    /// Splits messages into days and groups (DESIGN.md 5.4 to 5.6); a change of the timer
    /// stands between the messages of its time and ends a group.
    static func build(_ messages: [Message], unreadAnchor: String?, changes: [TimerChange] = []) -> [ChatItem] {
        let calendar = Calendar.current
        enum Entry {
            case message(Message)
            case change(TimerChange)

            var date: Date {
                switch self {
                case .message(let message): message.date
                case .change(let change): change.date
                }
            }

            var message: Message? {
                if case .message(let message) = self { message } else { nil }
            }
        }
        let entries = (messages.map(Entry.message) + changes.map(Entry.change)).enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)
        var items: [ChatItem] = []
        for (index, entry) in entries.enumerated() {
            let previous = index > 0 ? entries[index - 1] : nil
            let next = index + 1 < entries.count ? entries[index + 1] : nil
            let newDay = previous.map { !calendar.isDate($0.date, inSameDayAs: entry.date) } ?? true
            if newDay { items.append(.date(entry.date)) }
            guard let message = entry.message else {
                if case .change(let change) = entry { items.append(.service(change)) }
                continue
            }
            if message.id == unreadAnchor { items.append(.unread) }
            func joins(_ a: Message?, _ b: Message?) -> Bool {
                guard let a, let b else { return false }
                return a.outgoing == b.outgoing && calendar.isDate(a.date, inSameDayAs: b.date)
                    && b.date.timeIntervalSince(a.date) < Metrics.groupGap && b.id != unreadAnchor
            }
            items.append(.message(message, top: !joins(previous?.message, message), bottom: !joins(message, next?.message)))
        }
        return items
    }
}

struct MessageList: View {
    let model: AppModel
    let contact: Contact
    @State private var content = CGRect.zero
    @State private var distanceFromBottom: CGFloat = 0
    /// Incoming messages that arrived while the list was scrolled away from the bottom.
    @State private var unseen = 0
    /// The day of the topmost visible line, while its own date pill is out of view.
    @State private var topDay: Date?
    @State private var pillShown = false
    @State private var pillHide: Task<Void, Never>?
    /// The message found by a search, highlighted for a moment (DESIGN.md 19.7).
    @State private var highlighted: String?
    @State private var highlightHide: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct ContentKey: PreferenceKey {
        static let defaultValue = CGRect.zero
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
    }

    private struct Line: Equatable {
        let day: Date
        let isDate: Bool
        let minY: CGFloat
        let maxY: CGFloat
        /// The id of an incoming message.
        var incoming: String?
    }

    private struct LinesKey: PreferenceKey {
        static let defaultValue: [Line] = []
        static func reduce(value: inout [Line], nextValue: () -> [Line]) { value += nextValue() }
    }

    var body: some View {
        let messages = model.messages[contact.id] ?? []
        let items = ChatItem.build(messages, unreadAnchor: model.unreadAnchor, changes: model.timerChanges[contact.id] ?? [])
        GeometryReader { outer in
            let maxBubble = min(Metrics.bubbleMaxWidth, outer.size.width - Metrics.bubbleNear - Metrics.bubbleFar)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item, maxBubble: maxBubble)
                                .id(item.id)
                                .background { lineFrame(item) }
                        }
                        Color.clear.frame(height: Metrics.listToCompose).id("bottom")
                    }
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: ContentKey.self, value: inner.frame(in: .named("messages")))
                        })
                }
                .coordinateSpace(name: "messages")
                .defaultScrollAnchor(.bottom)
                .scrollIndicators(.automatic)
                .onPreferenceChange(ContentKey.self) { frame in
                    Task { @MainActor in moved(frame, height: outer.size.height) }
                }
                .onPreferenceChange(LinesKey.self) { lines in
                    Task { @MainActor in
                        topDay = Self.topDay(lines)
                        let shown = lines.filter { $0.maxY > 0 && $0.minY < outer.size.height }.compactMap(\.incoming)
                        model.showing(shown, in: contact.id)
                    }
                }
                .overlay(alignment: .top) {
                    if pillShown, let topDay {
                        ServicePill(text: Formats.separator(topDay))
                            .padding(.top, Metrics.floatingDateTop)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if distanceFromBottom > Metrics.toDownThreshold {
                        ScrollDownButton(unseen: unseen) {
                            let far = distanceFromBottom > outer.size.height * 2
                            withAnimation(far || reduceMotion ? nil : Motion.newMessage) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .padding(.trailing, Metrics.toDownRight)
                        .padding(.bottom, Metrics.toDownBottom)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 10)))
                    }
                }
                .animation(Motion.pick(Motion.toDown, reduce: reduceMotion), value: distanceFromBottom > Metrics.toDownThreshold)
                .onChange(of: model.focusMessage) { _, request in
                    guard let request else { return }
                    show(request.messageID, proxy: proxy)
                }
                .onAppear {
                    if let request = model.focusMessage {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { show(request.messageID, proxy: proxy) }
                        return
                    }
                    guard model.unreadAnchor != nil else { return }
                    // After the first layout, which the bottom anchor would override.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        proxy.scrollTo("unread", anchor: .top)
                    }
                }
                .onChange(of: messages.last?.id) { old, _ in
                    let start = messages.firstIndex { $0.id == old }.map { $0 + 1 } ?? max(messages.count - 1, 0)
                    let arrived = messages[start...].filter { !$0.outgoing }.count
                    if distanceFromBottom > Metrics.toDownThreshold, arrived > 0, messages.last?.outgoing == false {
                        unseen += arrived
                        return
                    }
                    withAnimation(reduceMotion ? nil : Motion.newMessage) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .id(contact.id)
    }

    private func show(_ messageID: String, proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : Motion.newMessage) { proxy.scrollTo(messageID, anchor: .center) }
        withAnimation(Motion.highlightIn) { highlighted = messageID }
        highlightHide?.cancel()
        highlightHide = Task { @MainActor in
            try? await Task.sleep(for: Metrics.highlightHold)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.highlightOut) { highlighted = nil }
        }
    }

    private func lineFrame(_ item: ChatItem) -> some View {
        GeometryReader { line in
            let frame = line.frame(in: .named("messages"))
            let incoming: String? = if case .message(let message, _, _) = item, !message.outgoing { message.id } else { nil }
            Color.clear.preference(
                key: LinesKey.self,
                value: item.day.map {
                    [Line(
                        day: $0, isDate: { if case .date = item { true } else { false } }(), minY: frame.minY, maxY: frame.maxY,
                        incoming: incoming)]
                } ?? [])
        }
    }

    /// The day of the topmost visible line, or nil while that line is a date pill in full view.
    private static func topDay(_ lines: [Line]) -> Date? {
        guard let top = lines.filter({ $0.maxY > 0 }).min(by: { $0.minY < $1.minY }) else { return nil }
        return top.isDate && top.minY >= 0 ? nil : top.day
    }

    /// A scroll moves the content without changing its height; it shows the floating date pill
    /// until the scrolling has stopped for a moment (DESIGN.md 5.5).
    private func moved(_ frame: CGRect, height: CGFloat) {
        let scrolled = frame.height == content.height && frame.minY != content.minY
        content = frame
        distanceFromBottom = frame.maxY - height
        if distanceFromBottom <= Metrics.toDownThreshold { unseen = 0 }
        guard scrolled else { return }
        pillShown = true
        pillHide?.cancel()
        pillHide = Task { @MainActor in
            try? await Task.sleep(for: Metrics.floatingDateHold)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.floatingDate) { pillShown = false }
        }
    }

    @ViewBuilder
    private func row(_ item: ChatItem, maxBubble: CGFloat) -> some View {
        switch item {
        case .date(let date):
            ServicePill(text: Formats.separator(date))
                .padding(.top, Metrics.dateTop)
                .padding(.bottom, Metrics.dateBottom)
        case .unread:
            Text("Unread messages")
                .font(Fonts.service)
                .foregroundStyle(Color.unreadBarFg)
                .frame(maxWidth: .infinity, minHeight: Metrics.unreadBand, maxHeight: Metrics.unreadBand)
                .background(Color.unreadBarBg)
                .overlay(alignment: .top) { Rectangle().fill(Color.unreadBarBorder).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(Color.unreadBarBorder).frame(height: 1) }
                .padding(.vertical, Metrics.unreadMargin)
        case .service(let change):
            ServicePill(text: TimerChoices.line(change, name: contact.name))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Metrics.bubbleFar)
                .padding(.top, Metrics.dateTop)
                .padding(.bottom, Metrics.dateBottom)
        case .message(let message, let top, let bottom):
            MessageRow(message: message, top: top, bottom: bottom, maxWidth: maxBubble, model: model, chatID: contact.id) {
                model.deleteMessage(message.id, in: contact.id)
            }
            .background { if highlighted == message.id { Color.messageHighlight } }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
        }
    }
}

struct ScrollDownButton: View {
    let unseen: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 18))
                .foregroundStyle(Color.toDownFg)
                .frame(width: Metrics.toDownCircle, height: Metrics.toDownCircle)
                .background(Circle().fill(Color.toDownBg).shadow(color: .shadow, radius: 2, y: 1))
                .overlay(alignment: .top) {
                    if unseen > 0 {
                        Badge(count: unseen, height: Metrics.toDownBadge)
                            .offset(y: -Metrics.toDownBadge / 2)
                    }
                }
                .frame(width: 52, height: 62)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(unseen > 0 ? "Scroll to the newest message, \(unseen) new" : "Scroll to the newest message")
    }
}

/// A message with its margins, bubble, tail and time (DESIGN.md 5.4); a photo or a file
/// draws its own bubble (DESIGN.md 13).
struct MessageRow: View {
    let message: Message
    let top: Bool
    let bottom: Bool
    let maxWidth: CGFloat
    /// The model and chat of the actions of a photo or a file; nil in previews.
    var model: AppModel?
    var chatID = ""
    let delete: () -> Void
    @Environment(\.settings) private var settings

    var body: some View {
        let out = message.outgoing
        HStack(spacing: 0) {
            if out { Spacer(minLength: Metrics.bubbleFar) }
            bubble
                .frame(maxWidth: maxWidth, alignment: out ? .trailing : .leading)
                .contextMenu { menu }
            if !out { Spacer(minLength: Metrics.bubbleFar) }
        }
        .padding(out ? .trailing : .leading, Metrics.bubbleNear)
        .padding(.top, top ? Metrics.groupTopSpace : 0)
        .padding(.bottom, Metrics.messageBottomSpace)
    }

    private var shape: BubbleShape {
        BubbleShape(
            senderTop: top ? Metrics.radiusLarge : Metrics.radiusSmall,
            senderBottom: bottom ? 0 : Metrics.radiusSmall,
            tail: bottom, mirrored: message.outgoing)
    }

    private var connected: Bool { (model?.connection ?? .connected) == .connected }

    private var time: String {
        Formats.clock(message.date, h24: settings.clock24 ?? Formats.localeUses24Hours)
    }

    @ViewBuilder
    private var bubble: some View {
        if let file = message.file {
            let tap: () -> Void = { model?.tap(message, in: chatID) }
            if file.isPhoto {
                PhotoBubble(
                    message: message, file: file, shape: shape, maxWidth: maxWidth, time: time,
                    connected: connected, tap: tap, header: quoteView.map { AnyView($0) }
                ) { textWithTime }
            } else {
                FileBubble(
                    message: message, file: file, shape: shape, maxWidth: maxWidth, time: time,
                    connected: connected, tap: tap, header: quoteView.map { AnyView($0) }
                ) { textWithTime }
            }
        } else if let quoteView {
            BubbleColumn {
                quoteView
                    .padding(.horizontal, Metrics.quoteInset)
                    .padding(.top, Metrics.quoteTop)
                textWithTime
            }
            .background { BubbleBackground(shape: shape, out: message.outgoing) }
        } else {
            textWithTime.background { BubbleBackground(shape: shape, out: message.outgoing) }
        }
    }

    /// The quote of a reply; a click shows the quoted message when the chat holds it.
    private var quoteView: QuoteBlock? {
        guard let quote = message.quote else { return nil }
        let target = quote.messageID.flatMap { id in model?.message(id, in: chatID).map { _ in id } }
        return QuoteBlock(
            quote: quote, out: message.outgoing, author: model?.author(quote.outgoing, in: chatID) ?? "",
            action: target.map { id in { model?.focus(id, in: chatID) } })
    }

    /// The text with the time and the status mark at the end of its last line.
    private var textWithTime: some View {
        let out = message.outgoing
        // A transparent copy of the time keeps room for it on the last line.
        let reserve = Text(TimeMark.reserve(message, time: time)).foregroundColor(.clear)
        return (Text(Self.attributed(message.text, out: out)) + reserve)
            .font(Fonts.message(settings.textSize))
            .lineSpacing(Fonts.messageLineSpacing(settings.textSize))
            .foregroundStyle(out ? Color.msgOutFg : Color.msgInFg)
            .tint(out ? Color.msgOutLinkFg : Color.msgInLinkFg)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Metrics.bubblePadH)
            .padding(.vertical, Metrics.bubblePadV)
            .overlay(alignment: .bottomTrailing) {
                TimeMark(message: message, time: time)
                    .padding(.trailing, Metrics.timeRight)
                    .padding(.bottom, Metrics.timeBottom)
            }
    }

    @ViewBuilder
    private var menu: some View {
        if let model {
            if message.position != nil || model.messenger == nil {
                Button { model.startReply(message.id, in: chatID) } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                }
            }
            if message.canEdit() || (model.messenger == nil && message.outgoing) {
                Button { model.startEdit(message.id, in: chatID) } label: { Label("Edit", systemImage: "pencil") }
            }
        }
        if let file = message.file, let model {
            if let url = Media.localURL(file) {
                Button { model.saveAs(message) } label: { Label("Save as...", systemImage: "square.and.arrow.down") }
                if file.isPhoto {
                    Button { model.copyImage(url) } label: { Label("Copy image", systemImage: "doc.on.doc") }
                } else {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
            }
        }
        if !message.text.isEmpty {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
            } label: {
                Label("Copy text", systemImage: "doc.on.doc")
            }
        }
        Button(role: .destructive) {
            if let model {
                model.modal = .deleteMessage(chatID, message.id)
            } else {
                delete()
            }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    /// The text with its links detected and coloured.
    static func attributed(_ text: String, out: Bool) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return result
        }
        let nsText = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            guard let url = match.url, let range = Range(match.range, in: result) else { continue }
            result[range].link = url
            result[range].foregroundColor = out ? Color.msgOutLinkFg : Color.msgInLinkFg
        }
        return result
    }
}

/// A bubble with per-corner radii and an optional tail at the bottom corner on the sender's
/// side, drawn for an incoming message and mirrored for an outgoing one.
struct BubbleShape: Shape {
    let senderTop: CGFloat
    let senderBottom: CGFloat
    let tail: Bool
    let mirrored: Bool
    var otherTop = Metrics.radiusLarge
    var otherBottom = Metrics.radiusLarge

    func path(in rect: CGRect) -> Path {
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        var path = Path()
        path.move(to: CGPoint(x: minX + senderTop, y: minY))
        path.addArc(tangent1End: CGPoint(x: maxX, y: minY), tangent2End: CGPoint(x: maxX, y: maxY), radius: otherTop)
        path.addArc(tangent1End: CGPoint(x: maxX, y: maxY), tangent2End: CGPoint(x: minX, y: maxY), radius: otherBottom)
        if tail {
            let w = Metrics.tailWidth, h = Metrics.tailHeight
            path.addLine(to: CGPoint(x: minX - w, y: maxY))
            path.addCurve(
                to: CGPoint(x: minX, y: maxY - h),
                control1: CGPoint(x: minX - w * 0.35, y: maxY - h * 0.15),
                control2: CGPoint(x: minX, y: maxY - h * 0.45))
        } else {
            path.addArc(tangent1End: CGPoint(x: minX, y: maxY), tangent2End: CGPoint(x: minX, y: minY), radius: senderBottom)
        }
        path.addArc(tangent1End: CGPoint(x: minX, y: minY), tangent2End: CGPoint(x: maxX, y: minY), radius: senderTop)
        path.closeSubpath()
        guard mirrored else { return path }
        return path.applying(CGAffineTransform(translationX: minX + maxX, y: 0).scaledBy(x: -1, y: 1))
    }
}

/// The bar over the open chat while it is searched: back and the query field (DESIGN.md 19.5).
struct ChatSearchTopBar: View {
    @Bindable var model: AppModel
    @FocusState private var focused: Bool

    private var query: Binding<String> {
        Binding(get: { model.chatSearch ?? "" }, set: { model.chatSearch = $0 })
    }

    var body: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "chevron.left", size: 17, label: "Close search") { model.chatSearch = nil }
                .padding(.leading, 6)
            ZStack(alignment: .leading) {
                if query.wrappedValue.isEmpty {
                    Text("Search")
                        .font(Fonts.rowText)
                        .foregroundStyle(focused ? Color.placeholderFgActive : Color.placeholderFg)
                        .padding(.leading, Metrics.searchTextLeft)
                        .allowsHitTesting(false)
                }
                TextField("", text: query)
                    .textFieldStyle(.plain)
                    .font(Fonts.rowText)
                    .foregroundStyle(Color.windowFg)
                    .focused($focused)
                    .padding(.leading, Metrics.searchTextLeft)
                    .padding(.trailing, Metrics.searchTextRight)
                    .accessibilityLabel("Search in chat")
                    .onSubmit { model.stepChatSearch(1) }
                    .onKeyPress(.upArrow) {
                        model.stepChatSearch(1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        model.stepChatSearch(-1)
                        return .handled
                    }
            }
            .frame(height: Metrics.searchHeight)
            .background(RoundedRectangle(cornerRadius: Metrics.searchRadius).fill(focused ? Color.searchBgActive : Color.searchBg))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.searchRadius)
                    .strokeBorder(focused ? Color.searchBorderActive : .clear, lineWidth: 2))
            .padding(Metrics.searchOuter)
        }
        .frame(height: Metrics.topBarHeight)
        .background(Color.topBarBg)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.divider).frame(height: 1) }
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: model.chatSearch) { old, new in
            guard old != nil, let new, new != old else { return }
            model.chatSearchIndex = 0
            model.stepChatSearch(0)
        }
    }
}

/// The bar under the open chat while it is searched: "N of M" and the arrows (DESIGN.md 19.5).
struct ChatSearchBottomBar: View {
    let model: AppModel

    var body: some View {
        let results = model.chatSearchResults
        let query = model.chatSearch?.trimmingCharacters(in: .whitespaces) ?? ""
        HStack(spacing: 0) {
            Group {
                if results.isEmpty {
                    Text(query.isEmpty ? "" : "No results")
                } else {
                    Text("\(model.chatSearchIndex + 1) of \(results.count)")
                }
            }
            .font(Fonts.settingsRow)
            .foregroundStyle(Color.windowSubFg)
            .padding(.leading, Metrics.chatSearchCounterLeft)
            Spacer()
            IconButton(
                symbol: "chevron.up", size: 18, label: "Older result",
                color: model.chatSearchIndex + 1 < results.count ? .composeIconFg : .placeholderFgActive,
                side: Metrics.chatSearchArrow
            ) { model.stepChatSearch(1) }
            IconButton(
                symbol: "chevron.down", size: 18, label: "Newer result",
                color: model.chatSearchIndex > 0 ? .composeIconFg : .placeholderFgActive,
                side: Metrics.chatSearchArrow
            ) { model.stepChatSearch(-1) }
        }
        .frame(height: Metrics.composeHeight)
        .background(Color.composeBg)
        .overlay(alignment: .top) { Rectangle().fill(Color.divider).frame(height: 1) }
    }
}
