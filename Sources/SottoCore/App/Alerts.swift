import Foundation

/// A macOS notification about one incoming message, decided here and posted by the app.
public struct Alert: Equatable, Sendable {
    public let chatID: String
    public let messageID: Int64
    public let title: String
    public let body: String
    public let sound: Bool
}

/// What the app tells about new messages outside the window: notifications and the Dock
/// badge (DESIGN.md 11.3 and 19.6).
public enum Alerts {
    public static let hiddenTitle = "Sotto"
    public static let hiddenBody = "New message"

    /// A notification for each chat with incoming messages in `new` that `old` did not hold,
    /// about the newest of them. None at launch (`old` is nil), none for `quietChat` (the
    /// chat open in the front window), none for a muted chat. `locked` is true while the lock
    /// screen covers the window.
    public static func make(
        old: MessengerState?, new: MessengerState, settings: AppSettings, quietChat: String?, locked: Bool
    ) -> [Alert] {
        guard settings.notifications, let old else { return [] }
        let hide = locked && settings.passcode != nil && settings.hideContentsWhileLocked
        var alerts: [Alert] = []
        for chat in new.chats where chat.userID != quietChat && !chat.muted {
            guard let before = old.chats.first(where: { $0.userID == chat.userID }) else { continue }
            let seen = before.messages.map(\.id).max() ?? 0
            // Several messages at once (the ones that waited on the relay) make one
            // notification, about the newest.
            if let message = chat.messages.last(where: { !$0.outgoing && $0.id > seen }) {
                alerts.append(Alert(
                    chatID: chat.userID,
                    messageID: message.id,
                    title: hide || !settings.notificationSender ? hiddenTitle : chat.name,
                    body: hide || !settings.notificationPreview ? hiddenBody : preview(message),
                    sound: settings.sound
                ))
            }
        }
        return alerts
    }

    /// The identifier of the notification of a message.
    public static func identifier(_ chatID: String, _ messageID: Int64) -> String {
        "\(chatID)-\(messageID)"
    }

    /// The notifications to take away: of the incoming messages of `old` that `new` does not
    /// hold (deleted for both or expired, protocol sections 39.4 and 39.6) or holds with
    /// another text (edited, 39.3), so that their text stays in no notification.
    public static func changed(old: MessengerState?, new: MessengerState) -> [String] {
        guard let old else { return [] }
        var ids: [String] = []
        for before in old.chats {
            let now = new.chats.first { $0.userID == before.userID }
            let texts = Dictionary((now?.messages ?? []).map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
            for message in before.messages where !message.outgoing && texts[message.id] != message.text {
                ids.append(identifier(before.userID, message.id))
            }
        }
        return ids
    }

    /// The text of a message for a person: a photo or a file says so before its caption.
    public static func preview(_ message: ChatMessage) -> String {
        preview(message.text, file: message.file)
    }

    public static func preview(_ text: String, file: ChatFile?) -> String {
        guard let file else {
            return text
        }
        let kind = file.isPhoto ? "Photo" : file.name.isEmpty ? "File" : "File: \(file.name)"
        return text.isEmpty ? kind : "\(kind), \(text)"
    }

    /// The number on the Dock icon: unread messages of every chat, muted and archived ones
    /// included, except `quietChat`; 0 when the setting is off.
    public static func badge(_ state: MessengerState, settings: AppSettings, quietChat: String?) -> Int {
        guard settings.dockBadge else { return 0 }
        return state.chats.filter { $0.userID != quietChat }.reduce(0) { $0 + $1.unread }
    }
}
