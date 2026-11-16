import AppKit
import Observation
import SwiftUI

struct Contact: Identifiable, Hashable {
    /// 64 lowercase hex characters: the contact's public id.
    let id: String
    var name: String
    let added: Date
    var unread: Int = 0
}

enum MessageState: Hashable {
    /// Waiting in the outbox.
    case waiting
    /// Stored by the relay.
    case stored
}

struct Message: Identifiable, Hashable {
    let id = UUID()
    let outgoing: Bool
    let text: String
    let date: Date
    var state: MessageState = .stored
}

enum ConnectionState: Hashable {
    case connected
    case connecting
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum Modal: Hashable {
    case addContact
    case myID
    case settings
    case contactInfo(String)
    case rename(String)
    case reset(String)
    case delete(String)

    var isWide: Bool {
        switch self {
        case .addContact, .myID, .settings, .contactInfo: true
        default: false
        }
    }
}

enum Welcome: Hashable {
    case start, creating, created
}

/// The whole state of the interface and the actions of its screens. The inside is mock data
/// for now; the real core replaces it without changing what the views see.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var myID: String
    /// Set while the first-launch screen is shown.
    var welcome: Welcome?
    var contacts: [Contact] = []
    var messages: [String: [Message]] = [:]
    var drafts: [String: String] = [:]
    var openChatID: String?
    /// The first unread message of the open chat, kept until the chat is closed.
    var unreadAnchor: UUID?
    var panelOpen = false
    var modal: Modal?
    var toast: String?
    var search = ""
    var searchFocused = false
    var searchSelection = 0
    var connection: ConnectionState = .connected
    var relayAddress: String
    var theme: ThemeChoice {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "theme")
            applyTheme()
        }
    }
    /// Bumped to ask the compose field for focus.
    var composeFocusTick = 0
    /// Bumped to ask the search field for focus.
    var searchFocusTick = 0

    private var toastTask: Task<Void, Never>?

    init(mock: Bool = true) {
        myID = MockData.id(for: "me")
        relayAddress = "wss://relay.sotto.example"
        theme = ThemeChoice(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .system
        if mock { MockData.fill(self) }
    }

    // MARK: Derived

    var sortedContacts: [Contact] {
        contacts.sorted { lastActivity($0) > lastActivity($1) }
    }

    var visibleContacts: [Contact] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sortedContacts }
        return sortedContacts.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func lastActivity(_ contact: Contact) -> Date {
        messages[contact.id]?.last?.date ?? contact.added
    }

    func contact(_ id: String?) -> Contact? {
        contacts.first { $0.id == id }
    }

    var openChat: Contact? { contact(openChatID) }

    // MARK: Actions

    func applyTheme() {
        NSApp?.appearance = theme.appearance
    }

    func openChat(_ id: String) {
        guard id != openChatID else {
            composeFocusTick += 1
            return
        }
        closeChat()
        openChatID = id
        if let index = contacts.firstIndex(where: { $0.id == id }), contacts[index].unread > 0 {
            let incoming = messages[id, default: []].filter { !$0.outgoing }
            unreadAnchor = incoming.suffix(contacts[index].unread).first?.id
        }
        markRead(id)
        composeFocusTick += 1
    }

    func closeChat() {
        openChatID = nil
        unreadAnchor = nil
    }

    func markRead(_ id: String) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].unread = 0
    }

    func send(_ text: String, to id: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let message = Message(outgoing: true, text: trimmed, date: Date(), state: .waiting)
        withAnimation(Motion.reorder) {
            messages[id, default: []].append(message)
        }
        drafts[id] = nil
        if connection == .connected { store(message.id, in: id) }
    }

    /// The mock relay stores a message about a second after it leaves the outbox.
    private func store(_ messageID: UUID, in chat: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.connection == .connected,
                let index = self.messages[chat]?.firstIndex(where: { $0.id == messageID })
            else { return }
            self.messages[chat]?[index].state = .stored
        }
    }

    func deleteMessage(_ messageID: UUID, in chat: String) {
        messages[chat]?.removeAll { $0.id == messageID }
    }

    /// Checks a new contact; returns the message for the field that failed, or nil when added.
    func addContact(name: String, id rawID: String) -> (name: String?, id: String?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = Self.normalizedID(rawID)
        let nameError = name.isEmpty ? "Enter a name." : nil
        let idError = Self.idError(id, own: myID, existing: contacts)
        if nameError != nil || idError != nil { return (nameError, idError) }
        contacts.append(Contact(id: id, name: name, added: Date()))
        modal = nil
        openChat(id)
        return (nil, nil)
    }

    static func normalizedID(_ raw: String) -> String {
        raw.filter { !$0.isWhitespace }.lowercased()
    }

    static func idError(_ id: String, own: String, existing: [Contact]) -> String? {
        if id.count != 64 { return "The id must be 64 characters long." }
        if !id.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) {
            return "The id may contain only 0-9 and a-f."
        }
        if id == own { return "This is your own id." }
        if let saved = existing.first(where: { $0.id == id }) {
            return "This contact is already saved as \(saved.name)."
        }
        return nil
    }

    func rename(_ id: String, to name: String) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].name = name
        modal = nil
    }

    func resetSession(_ id: String) {
        modal = nil
        showToast("Session reset")
    }

    func deleteContact(_ id: String) {
        modal = nil
        if openChatID == id {
            closeChat()
            panelOpen = false
        }
        contacts.removeAll { $0.id == id }
        messages[id] = nil
        drafts[id] = nil
        showToast("Contact deleted")
    }

    /// Returns false when the address is not a ws or wss URL with a host.
    func setRelay(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), ["ws", "wss"].contains(url.scheme ?? ""), url.host != nil
        else { return false }
        relayAddress = trimmed
        return true
    }

    func setConnection(_ state: ConnectionState) {
        connection = state
        guard state == .connected else { return }
        for (chat, list) in messages {
            for message in list where message.state == .waiting { store(message.id, in: chat) }
        }
    }

    func copyID(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
        showToast("Id copied")
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: Metrics.toastHold)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.toastOut) { self?.toast = nil }
        }
    }

    func createIdentity() {
        welcome = .creating
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(Motion.box) { self?.welcome = .created }
        }
    }

    /// Escape, wherever the focus is (DESIGN.md 6).
    func escape() {
        if modal != nil {
            modal = nil
        } else if searchFocused {
            if search.isEmpty { searchFocused = false } else { search = "" }
        } else if openChatID != nil {
            closeChat()
        }
    }
}
