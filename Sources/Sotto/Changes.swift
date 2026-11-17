import AppKit
import SottoCore
import SwiftUI

// Replies, edits, delete for both, receipts and the disappearing timer (DESIGN.md 20,
// protocol part 5): the actions of the model and the views that only they use.

extension Message {
    init(_ chat: ChatMessage) {
        self.init(
            id: String(chat.id), outgoing: chat.outgoing, text: chat.text, date: chat.date, state: MessageState(chat),
            file: chat.file)
        quote = chat.quote.map {
            MessageQuote(messageID: $0.position.map(String.init), outgoing: $0.outgoing, text: $0.text, file: $0.file)
        }
        edited = chat.edited
        expiresAfter = chat.expiresAfter
        expiresAt = chat.expiresAt
        editableUntil = chat.editableUntil
    }
}

/// The choices of the disappearing timer (DESIGN.md 20.7), in seconds; 0 is off.
enum TimerChoices {
    static let all = [0, 30, 300, 3600, 28800, 86400, 604_800, 2_419_200]
    private static let units: [(seconds: Int, short: String, one: String, many: String)] = [
        (604_800, "w", "week", "weeks"), (86400, "d", "day", "days"), (3600, "h", "hour", "hours"),
        (60, "m", "minute", "minutes"), (1, "s", "second", "seconds"),
    ]

    /// "Off", "30 seconds", "1 hour": the largest unit that divides the seconds.
    static func title(_ seconds: Int) -> String {
        guard seconds > 0, let unit = units.first(where: { seconds % $0.seconds == 0 }) else { return "Off" }
        let count = seconds / unit.seconds
        return "\(count) \(count == 1 ? unit.one : unit.many)"
    }

    /// "30s", "1h", "4w".
    static func short(_ seconds: Int) -> String {
        guard seconds > 0, let unit = units.first(where: { seconds % $0.seconds == 0 }) else { return "" }
        return "\(seconds / unit.seconds)\(unit.short)"
    }

    /// The service line of a change (DESIGN.md 20.7).
    static func line(_ change: TimerChange, name: String) -> String {
        let who = change.own ? "You" : name
        return change.seconds == 0
            ? "\(who) turned off disappearing messages"
            : "\(who) set messages to disappear after \(title(change.seconds))"
    }
}

extension AppModel {
    func message(_ messageID: String, in chat: String) -> Message? {
        messages[chat]?.first { $0.id == messageID }
    }

    /// The quote of a message of the chat, as a reply of the mock data shows it.
    func quote(of messageID: String, in chat: String) -> MessageQuote? {
        message(messageID, in: chat).map { MessageQuote(messageID: $0.id, outgoing: $0.outgoing, text: $0.text, file: $0.file) }
    }

    /// The name of the author of a message for a quote: "You" for the user's own.
    func author(_ outgoing: Bool, in chat: String) -> String {
        outgoing ? "You" : contact(chat)?.name ?? ""
    }

    // MARK: Reply and edit (DESIGN.md 20.2 to 20.4)

    func startReply(_ messageID: String, in chat: String) {
        if edits[chat] != nil { cancelComposeMode(in: chat) }
        replies[chat] = messageID
        composeFocusTick += 1
    }

    func startEdit(_ messageID: String, in chat: String) {
        guard let message = message(messageID, in: chat), message.canEdit() || messenger == nil else { return }
        replies[chat] = nil
        let saved = edits[chat]?.savedDraft ?? drafts[chat]
        edits[chat] = EditDraft(messageID: messageID, original: message.text, savedDraft: saved)
        drafts[chat] = message.text
        composeFocusTick += 1
    }

    /// The Up arrow in an empty field: the newest own message that can still be edited.
    func editLast(in chat: String) -> Bool {
        guard edits[chat] == nil, replies[chat] == nil,
            let last = messages[chat]?.last(where: { $0.canEdit() || (messenger == nil && $0.outgoing) })
        else { return false }
        startEdit(last.id, in: chat)
        return true
    }

    /// Ends the reply or the edit of the compose bar; an edit gives the draft back.
    func cancelComposeMode(in chat: String) {
        replies[chat] = nil
        if let edit = edits.removeValue(forKey: chat) {
            drafts[chat] = edit.savedDraft
        }
    }

    /// Saves the edit of the compose bar: an empty text is not sent, the same text ends it.
    func saveEdit(_ text: String, in chat: String) {
        guard let edit = edits[chat] else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAFile = message(edit.messageID, in: chat)?.file != nil
        guard !trimmed.isEmpty || isAFile else { return }
        cancelComposeMode(in: chat)
        guard trimmed != edit.original else { return }
        guard messenger != nil, let position = Int64(edit.messageID) else {
            if let index = messages[chat]?.firstIndex(where: { $0.id == edit.messageID }) {
                messages[chat]?[index].text = trimmed
                messages[chat]?[index].edited = true
            }
            return
        }
        run { try await $0.edit(position, text: trimmed, in: chat) }
    }

    /// A message left the chat: a reply to it or an edit of it ends.
    func endComposeModes(for messageID: String, in chat: String) {
        if replies[chat] == messageID { replies[chat] = nil }
        if edits[chat]?.messageID == messageID { cancelComposeMode(in: chat) }
    }

    /// Ends the replies and edits of messages that are gone, deleted or expired.
    func dropGoneComposeModes() {
        for (chat, messageID) in replies where message(messageID, in: chat) == nil {
            replies[chat] = nil
        }
        for (chat, edit) in edits where message(edit.messageID, in: chat) == nil {
            cancelComposeMode(in: chat)
        }
    }

    // MARK: Delete (DESIGN.md 20.6)

    /// Whether a message can be deleted at both sides: an own message that is logged and was
    /// not refused.
    func canDeleteForBoth(_ message: Message) -> Bool {
        guard message.outgoing, message.file?.state != .notSent else { return false }
        if case .failed = message.state { return false }
        return message.position != nil || messenger == nil
    }

    /// Deletes an own message here and asks the contact's app to delete it too.
    func deleteForBoth(_ messageID: String, in chat: String) {
        modal = nil
        endComposeModes(for: messageID, in: chat)
        let name = contact(chat)?.name ?? ""
        messages[chat]?.removeAll { $0.id == messageID }
        guard messenger != nil, let position = Int64(messageID) else { return showToast("Asked \(name) to delete it too") }
        run { [weak self] messenger in
            try await messenger.deleteForBoth(position, in: chat)
            await self?.showToast("Asked \(name) to delete it too")
        }
    }

    // MARK: Timer and read receipts (DESIGN.md 20.7 and 20.9)

    func setTimer(_ seconds: Int, in chat: String) {
        guard timers[chat, default: 0] != seconds else { return }
        guard messenger != nil else {
            timers[chat] = seconds
            timerChanges[chat, default: []].append(TimerChange(date: Date(), seconds: seconds, own: true))
            return
        }
        run { try await $0.setTimer(seconds, in: chat) }
    }

    func setReadReceipts(_ on: Bool) {
        readReceipts = on
        run { try await $0.setReadReceipts(on) }
    }

    // MARK: Seen on screen (DESIGN.md 20.5)

    /// The incoming messages that the list of a chat shows now; while the chat is open in the
    /// front window they are seen, which starts their timers and owes their read receipts.
    func showing(_ messageIDs: [String], in chat: String) {
        guard onScreen[chat] != messageIDs else { return }
        onScreen[chat] = messageIDs
        if chat == quietChat { reportSeen(in: chat) }
    }

    func reportSeen(in chat: String) {
        guard messenger != nil else { return }
        let fresh = (onScreen[chat] ?? []).filter { !reportedSeen.contains($0) }
        let positions = fresh.compactMap { Int64($0) }
        guard !positions.isEmpty else { return }
        reportedSeen.formUnion(fresh)
        run { try await $0.markSeen(positions, in: chat) }
    }

    // MARK: Launch flags

    func runScripted(_ change: ScriptedChange) {
        guard let chat = contacts.first(where: { $0.name == change.chatName })?.id else {
            FileHandle.standardError.write(Data("no contact named \(change.chatName)\n".utf8))
            return
        }
        let list = messages[chat] ?? []
        switch change {
        case .reply(_, let text):
            guard let target = list.last(where: { !$0.outgoing }) else { return }
            startReply(target.id, in: chat)
            send(text, to: chat)
        case .edit(_, let text):
            guard editLast(in: chat), let edit = edits[chat] else { return }
            drafts[chat] = edit.savedDraft
            saveEdit(text, in: chat)
        case .delete:
            guard let target = list.last(where: { $0.outgoing && $0.position != nil }) else { return }
            deleteForBoth(target.id, in: chat)
        case .timer(_, let seconds):
            setTimer(seconds, in: chat)
        }
    }
}

/// Stacks a quote over the text of a bubble: as wide as the wider of the two, up to the
/// width offered, each child then laid out at that width.
struct BubbleColumn: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = columnWidth(proposal, subviews)
        let height = subviews.reduce(0) { $0 + $1.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let size = ProposedViewSize(width: bounds.width, height: nil)
            subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: size)
            y += subview.sizeThatFits(size).height
        }
    }

    private func columnWidth(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let limit = proposal.width ?? .infinity
        return subviews.map { min($0.sizeThatFits(.unspecified).width, limit) }.max() ?? 0
    }
}

/// The quoted message at the top of a reply (DESIGN.md 20.3): a tinted block with a bar, the
/// author and one line of the text, or "Deleted message".
struct QuoteBlock: View {
    let quote: MessageQuote
    /// The bubble is the user's own.
    let out: Bool
    let author: String
    let action: (() -> Void)?

    var body: some View {
        let bar = out ? Color.quoteBarOut : Color.quoteBarIn
        Button { action?() } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if quote.isGone {
                        Text("Deleted message").font(Fonts.message(13)).foregroundStyle(bar)
                            .frame(height: Metrics.quoteLine * 2, alignment: .center)
                    } else {
                        Text(author).font(Fonts.quoteName).foregroundStyle(out ? Color.quoteNameOut : Color.quoteNameIn)
                            .frame(height: Metrics.quoteLine)
                        Text(Self.oneLine(quote.preview ?? ""))
                            .font(Fonts.message(13))
                            .foregroundStyle(out ? Color.msgOutFg : Color.msgInFg)
                            .frame(height: Metrics.quoteLine)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(Metrics.quotePad)
            .background(bar.opacity(0.12))
            .overlay(alignment: .leading) { Rectangle().fill(bar.opacity(0.9)).frame(width: Metrics.quoteBar) }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.quoteRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
        .accessibilityLabel(quote.isGone ? "Reply to a deleted message" : "Reply to \(author): \(quote.preview ?? "")")
    }

    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }
}

/// The strip above the compose field while a reply or an edit is written (DESIGN.md 20.2).
struct ComposeStrip: View {
    let model: AppModel
    let chatID: String

    var body: some View {
        if let edit = model.edits[chatID] {
            strip(symbol: "pencil", title: "Edit message", text: edit.original, target: edit.messageID)
        } else if let reply = model.replies[chatID], let message = model.message(reply, in: chatID) {
            strip(
                symbol: "arrowshape.turn.up.left", title: model.author(message.outgoing, in: chatID), text: message.preview,
                target: reply)
        }
    }

    private func strip(symbol: String, title: String, text: String, target: String) -> some View {
        HStack(spacing: 0) {
            Button { model.focus(target, in: chatID) } label: {
                HStack(spacing: 0) {
                    Image(systemName: symbol)
                        .font(.system(size: 18))
                        .foregroundStyle(Color.accent)
                        .frame(width: Metrics.stripIcon, height: Metrics.stripIcon)
                        .padding(.leading, Metrics.stripIconLeft)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(Fonts.quoteName).foregroundStyle(Color.accentText)
                        Text(QuoteBlock.oneLine(text)).font(Fonts.message(13)).foregroundStyle(Color.windowFg)
                    }
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, Metrics.stripTextLeft - Metrics.stripIconLeft - Metrics.stripIcon)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title): \(text)")
            IconButton(
                symbol: "xmark", size: 14, label: model.edits[chatID] != nil ? "Cancel the edit" : "Cancel the reply",
                color: .replyCancelFg, hoverColor: .replyCancelFgOver, side: Metrics.stripHeight
            ) { model.cancelComposeMode(in: chatID) }
        }
        .frame(height: Metrics.stripHeight)
    }
}

/// The mark of a sent message: one check when stored, two when delivered or read (DESIGN.md
/// 20.5). An original shape of two strokes.
struct Checks: Shape {
    let double: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func check(_ x: CGFloat) {
            path.move(to: CGPoint(x: x, y: rect.midY + 0.5))
            path.addLine(to: CGPoint(x: x + rect.height * 0.36, y: rect.maxY - 1))
            path.addLine(to: CGPoint(x: x + rect.height * 1.05, y: rect.minY + 1))
        }
        check(rect.minX + 1)
        if double {
            path.move(to: CGPoint(x: rect.minX + 1 + rect.height * 0.62, y: rect.maxY - 1.8))
            path.addLine(to: CGPoint(x: rect.minX + 1 + rect.height * 0.36 + 5, y: rect.maxY - 1))
            path.addLine(to: CGPoint(x: rect.minX + 1 + rect.height * 1.05 + 5, y: rect.minY + 1))
        }
        return path.strokedPath(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }
}

/// The timer of a message before its time: a glyph and the short value (DESIGN.md 20.7).
struct TimerLabel: View {
    let seconds: Int
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "timer").font(.system(size: 10))
            Text(TimerChoices.short(seconds)).font(.system(size: 11))
        }
        .foregroundStyle(color)
        .accessibilityLabel("Disappears after \(TimerChoices.title(seconds))")
    }
}

/// The box of a message's deletion (DESIGN.md 20.6): for an own message, the choice to ask
/// the contact's app to delete it too.
struct DeleteMessageBox: View {
    let model: AppModel
    let chatID: String
    let message: Message
    @State private var forBoth = true

    var body: some View {
        let name = model.contact(chatID)?.name ?? ""
        let both = model.canDeleteForBoth(message)
        ModalBox(title: "Delete message?") {
            VStack(alignment: .leading, spacing: 10) {
                if both {
                    Button { forBoth.toggle() } label: {
                        HStack(spacing: 12) {
                            CheckSquare(checked: forBoth)
                            Text("Also delete for \(name)").font(Fonts.boxBody).foregroundStyle(Color.windowFg)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(forBoth ? "On" : "Off")
                    Text(forBoth
                        ? "Sotto asks the app of \(name) to delete it. A copy that \(name) made stays."
                        : "It is deleted on this Mac only.")
                        .font(Fonts.label)
                        .foregroundStyle(Color.windowSubFg)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("It is deleted on this Mac only. \(message.outgoing ? "The message was not sent." : "\(name) keeps the copy they sent.")")
                        .font(Fonts.boxBody)
                        .foregroundStyle(Color.windowFg)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } buttons: {
            BoxButton(title: "Cancel") { model.modal = nil }
            BoxButton(title: "Delete", danger: true) {
                if both && forBoth {
                    model.deleteForBoth(message.id, in: chatID)
                } else {
                    model.modal = nil
                    model.deleteMessage(message.id, in: chatID)
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// The disappearing timer of a chat (DESIGN.md 20.7): a choice applies at once.
struct TimerBox: View {
    let model: AppModel
    let chatID: String

    var body: some View {
        let name = model.contact(chatID)?.name ?? ""
        let current = model.timers[chatID] ?? 0
        ModalBox(title: "Disappearing messages", wide: true) {
            VStack(alignment: .leading, spacing: 5) {
                Text("New messages of this chat disappear: yours after they are sent, those of \(name) after you read them. The app of \(name) is asked to do the same.")
                    .font(Fonts.label)
                    .foregroundStyle(Color.windowSubFg)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                ForEach(TimerChoices.all + (TimerChoices.all.contains(current) ? [] : [current]), id: \.self) { seconds in
                    RadioRow(title: TimerChoices.title(seconds), selected: current == seconds) {
                        model.setTimer(seconds, in: chatID)
                    }
                    .padding(.horizontal, -Metrics.boxPad + 2)
                }
            }
        } buttons: {
            BoxButton(title: "Close") { model.modal = nil }.keyboardShortcut(.defaultAction)
        }
    }
}

/// The items of the timer in a menu: a check stands before the current value.
struct TimerMenuItems: View {
    let model: AppModel
    let chatID: String

    var body: some View {
        let current = model.timers[chatID] ?? 0
        ForEach(TimerChoices.all, id: \.self) { seconds in
            Button { model.setTimer(seconds, in: chatID) } label: {
                if seconds == current {
                    Label(TimerChoices.title(seconds), systemImage: "checkmark")
                } else {
                    Text(TimerChoices.title(seconds))
                }
            }
        }
    }
}
