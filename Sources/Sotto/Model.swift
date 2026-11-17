import AppKit
import Observation
import SottoCore
import SwiftUI

struct Contact: Identifiable, Hashable {
    /// 64 lowercase hex characters: the contact's public id.
    let id: String
    var name: String
    let added: Date
    var unread: Int = 0
    /// The place among the pinned chats, 0 on top.
    var pinned: Int?
    var muted = false
    var archived = false
}

/// A line of the list while it searches (DESIGN.md 5.2 and 19.4): a chat found by its name,
/// or a message found by its text.
enum SearchRow: Identifiable {
    case chat(Contact)
    case message(Contact, Message)

    var id: String {
        switch self {
        case .chat(let contact): contact.id
        case .message(let contact, let message): contact.id + "/" + message.id
        }
    }
}

/// A message to scroll to and highlight; `tick` repeats a request for the same message.
struct FocusRequest: Equatable {
    let messageID: String
    let tick: Int
}

enum MessageState: Hashable {
    /// Waiting in the outbox.
    case waiting
    /// Stored by the relay.
    case stored
    /// Not sent, with the reason for a person.
    case failed(String)

    init(_ message: ChatMessage) {
        if let failure = message.failure {
            self = .failed(failure)
        } else {
            self = message.waiting ? .waiting : .stored
        }
    }
}

struct Message: Identifiable, Hashable {
    var id = UUID().uuidString
    let outgoing: Bool
    let text: String
    let date: Date
    var state: MessageState = .stored
}

enum ConnectionState: Hashable {
    case connected
    case connecting
    /// No transport runs.
    case idle
    /// The client does not reconnect by itself.
    case stopped(String)

    init(_ link: LinkState) {
        switch link {
        case .idle: self = .idle
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .stopped(let text): self = .stopped(text)
        }
    }

    var label: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting..."
        case .idle: "Not connected"
        case .stopped(let text): text
        }
    }
}

extension AppSettings.Theme {
    var title: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The pages under the root page of the settings panel (DESIGN.md 11).
enum SettingsPage: Hashable, CaseIterable {
    case notifications, chats, data, privacy, connection, advanced
}

/// The boxes drawn over the settings panel.
enum SettingsDialog: Hashable {
    case myID
    case passcode
    case autoLock
    case reset
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

/// The launch arguments of the app.
struct Launch {
    static let defaultRelay = "ws://127.0.0.1:8765/ws"

    var demo = false
    var firstLaunch = false
    var dataDirectory: URL?
    var relay = defaultRelay
    var snapshot: URL?
    var dump = false
    /// `--send NAME TEXT`, any number of times: texts sent to the contacts of those names once
    /// the app is connected, through the action of the compose bar.
    var sends: [(name: String, text: String)] = []

    static let current = Launch(CommandLine.arguments)

    init(_ arguments: [String]) {
        for (index, argument) in arguments.enumerated() where argument == "--send" && index + 2 < arguments.count {
            sends.append((arguments[index + 1], arguments[index + 2]))
        }
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        demo = arguments.contains("--demo")
        firstLaunch = arguments.contains("--first-launch")
        dump = arguments.contains("--dump")
        dataDirectory = value(after: "--data-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        relay = value(after: "--relay") ?? Self.defaultRelay
        snapshot = value(after: "--snapshot").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var directory: URL {
        dataDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sotto", isDirectory: true)
    }
}

/// The whole state of the interface and the actions of its screens: a thin wrapper over
/// `Messenger`, or mock data when there is none (`--demo` and the snapshot pictures).
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel.launched()

    private(set) var messenger: Messenger?
    var myID: String
    /// Set while the first-launch screen is shown.
    var welcome: Welcome?
    var contacts: [Contact] = []
    var messages: [String: [Message]] = [:]
    var drafts: [String: String] = [:] {
        didSet { scheduleDraftSave() }
    }
    var openChatID: String?
    /// Set while the list shows the archived chats.
    var archiveOpen = false
    /// The query of the search in the open chat; nil while that search is closed.
    var chatSearch: String?
    /// The result of the search in the open chat that is shown, 0 the newest.
    var chatSearchIndex = 0
    var focusMessage: FocusRequest?
    /// Set when macOS refused notifications to Sotto (DESIGN.md 11.3).
    var notificationsDenied = false
    /// The first unread message of the open chat, kept until the chat is closed.
    var unreadAnchor: String?
    var panelOpen = false
    var modal: Modal?
    var toast: String?
    var search = ""
    var searchFocused = false
    var searchSelection = 0
    var connection: ConnectionState = .connected
    var relayAddress: String
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            if settings.theme != oldValue.theme { applyTheme() }
            if settings.notifications, !oldValue.notifications { alerts?.refresh(ask: true) }
            if settings.dockBadge != oldValue.dockBadge, let lastState { updateBadge(lastState) }
            let saved = settings
            run { try await $0.saveSettings(saved) }
        }
    }
    /// The open page of the settings panel; nil is the root page.
    var settingsPage: SettingsPage?
    var settingsDialog: SettingsDialog?
    /// The relay address typed on the connection page and not saved yet.
    var relayDraft: String?
    /// Set while the lock screen covers the window (DESIGN.md 11.6).
    var locked = false
    /// The data folder; nil for the mock data.
    private(set) var dataDirectory: URL?
    /// The size of the data folder, read when the storage page opens.
    var storageBytes: Int64?
    @ObservationIgnored var lastActivity = Date()
    /// Bumped to ask the compose field for focus.
    var composeFocusTick = 0
    /// Bumped to ask the search field for focus.
    var searchFocusTick = 0

    private var toastTask: Task<Void, Never>?
    private var scriptedSends: [(name: String, text: String)] = []
    @ObservationIgnored private var lastState: MessengerState?
    @ObservationIgnored private var savedDrafts: [String: String] = [:]
    @ObservationIgnored private var draftSave: Task<Void, Never>?
    /// The last draft write; each write waits for the one before, so the newest text lands last.
    @ObservationIgnored private var draftWrite: Task<Void, Never>?
    @ObservationIgnored private var focusTick = 0
    @ObservationIgnored private lazy var notifier = Notifier(model: self)
    /// The notification poster, only over a real store: the mock data and the snapshots
    /// never touch the notification center or the Dock.
    var alerts: Notifier? { messenger == nil ? nil : notifier }

    init(mock: Bool = true) {
        messenger = nil
        myID = MockData.id(for: "me")
        relayAddress = "wss://relay.sotto.example"
        settings = AppSettings()
        if mock { MockData.fill(self) }
    }

    init(messenger: Messenger, directory: URL) {
        myID = ""
        relayAddress = ""
        connection = .idle
        dataDirectory = directory
        settings = messenger.launchSettings ?? Self.legacySettings()
        locked = settings.passcode != nil
        scriptedSends = Launch.current.sends
        attach(messenger)
    }

    /// Before the settings moved to `app.json` the theme was kept in the user defaults.
    private static func legacySettings() -> AppSettings {
        var settings = AppSettings()
        if let theme = UserDefaults.standard.string(forKey: "theme").flatMap(AppSettings.Theme.init(rawValue:)) {
            settings.theme = theme
        }
        return settings
    }

    private func attach(_ messenger: Messenger) {
        self.messenger = messenger
        welcome = messenger.hadIdentity ? nil : .start
        Task { [weak self] in
            for await state in messenger.changes { self?.apply(state) }
        }
        Task { await messenger.start() }
    }

    private static func launched() -> AppModel {
        let launch = Launch.current
        if launch.demo {
            let model = AppModel()
            if launch.firstLaunch { model.welcome = .start }
            return model
        }
        do {
            return AppModel(messenger: try Messenger(directory: launch.directory, relay: launch.relay), directory: launch.directory)
        } catch {
            let model = AppModel(mock: false)
            model.myID = ""
            model.connection = .stopped("The store cannot be opened: \(error).")
            return model
        }
    }

    /// Takes over a state of the messenger; the chat open in the key window counts as read.
    /// New incoming messages become notifications and the Dock badge follows the unread count.
    func apply(_ state: MessengerState) {
        if let userID = state.userID { myID = userID }
        relayAddress = state.relay
        connection = ConnectionState(state.link)
        let quiet = quietChat
        if lastState == nil {
            let loaded = Dictionary(uniqueKeysWithValues: state.chats.compactMap { chat in chat.draft.map { (chat.userID, $0) } })
            savedDrafts = loaded
            drafts = loaded
        }
        contacts = state.chats.map {
            Contact(
                id: $0.userID, name: $0.name, added: $0.added, unread: $0.userID == quiet ? 0 : $0.unread,
                pinned: $0.pinned, muted: $0.muted, archived: $0.archived)
        }
        messages = Dictionary(uniqueKeysWithValues: state.chats.map { chat in
            (chat.userID, chat.messages.map {
                Message(id: String($0.id), outgoing: $0.outgoing, text: $0.text, date: $0.date, state: MessageState($0))
            })
        })
        if let quiet, state.chats.contains(where: { $0.userID == quiet && $0.unread > 0 }) {
            run { try await $0.markRead(quiet) }
        }
        if messenger != nil {
            Alerts.make(old: lastState, new: state, settings: settings, quietChat: quiet, locked: locked)
                .forEach { alerts?.post($0) }
            updateBadge(state)
        }
        lastState = state
        if archiveOpen, archivedContacts.isEmpty { archiveOpen = false }
        if connection == .connected, !scriptedSends.isEmpty {
            for (name, text) in scriptedSends {
                if let contact = contacts.first(where: { $0.name == name }) {
                    send(text, to: contact.id)
                } else {
                    FileHandle.standardError.write(Data("--send: no contact named \(name)\n".utf8))
                }
            }
            scriptedSends = []
        }
    }

    /// Runs an action of the messenger; its error becomes a toast.
    private func run(_ action: @escaping @Sendable (Messenger) async throws -> Void, failed: (@MainActor () -> Void)? = nil) {
        guard let messenger else { return }
        Task { [weak self] in
            do {
                try await action(messenger)
            } catch {
                failed?()
                self?.showToast(Messenger.describe(error))
            }
        }
    }

    // MARK: Derived

    /// Pinned chats first in their own order, then the others by their last activity.
    var sortedContacts: [Contact] {
        contacts.sorted {
            switch ($0.pinned, $1.pinned) {
            case let (a?, b?): a < b
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lastActivity($0) > lastActivity($1)
            }
        }
    }

    /// The rows of the list, or of the archive while it is open.
    var visibleContacts: [Contact] {
        sortedContacts.filter { $0.archived == archiveOpen }
    }

    var archivedContacts: [Contact] {
        sortedContacts.filter(\.archived)
    }

    /// Chats whose name holds the query, then messages whose text holds it, newest first;
    /// archived chats included.
    var searchRows: [SearchRow] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let all = sortedContacts
        let chats = all.filter { $0.name.localizedCaseInsensitiveContains(query) }.map(SearchRow.chat)
        let found = all.flatMap { contact in
            (messages[contact.id] ?? []).filter { $0.text.localizedCaseInsensitiveContains(query) }.map { (contact, $0) }
        }
        return chats + found.sorted { $0.1.date > $1.1.date }.map(SearchRow.message)
    }

    /// The messages of the open chat that hold the query of the chat search, newest first.
    var chatSearchResults: [Message] {
        guard let id = openChatID, let query = chatSearch?.trimmingCharacters(in: .whitespaces), !query.isEmpty else { return [] }
        return (messages[id] ?? []).filter { $0.text.localizedCaseInsensitiveContains(query) }.reversed()
    }

    /// The open chat while the window is in front and unlocked: it gets no notification and
    /// its messages count as read.
    var quietChat: String? {
        // The main window, not the key one: the character palette takes the key while it is open.
        guard !locked, NSApp?.isActive == true, NSApp?.mainWindow?.isVisible == true else { return nil }
        return openChatID
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
        NSApp?.appearance = settings.theme.appearance
    }

    // MARK: Settings

    func openSettings() {
        guard modal != .settings else { return }
        settingsPage = nil
        settingsDialog = nil
        relayDraft = nil
        modal = .settings
    }

    var waitingCount: Int {
        messages.values.reduce(0) { $0 + $1.filter { $0.state == .waiting }.count }
    }

    var clock24: Bool { settings.clock24 ?? Formats.localeUses24Hours }

    func measureStorage() {
        guard let directory = dataDirectory else { return }
        Task.detached {
            var total: Int64 = 0
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys)
            while let url = files?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
            }
            await MainActor.run { [weak self] in self?.storageBytes = total }
        }
    }

    func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if let folder = settings.downloadFolder { panel.directoryURL = URL(fileURLWithPath: folder) }
        if panel.runModal() == .OK, let url = panel.url { settings.downloadFolder = url.path }
    }

    var downloadFolder: URL {
        settings.downloadFolder.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// Engages the lock screen when a passcode is set.
    func lock() {
        guard settings.passcode != nil, welcome == nil else { return }
        locked = true
    }

    func unlock(_ text: String) -> Bool {
        guard settings.passcode?.matches(text) ?? true else { return false }
        locked = false
        lastActivity = Date()
        windowBecameKey()
        return true
    }

    /// Watches input, idle time and sleep for the auto-lock.
    func watchActivity() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .mouseMoved]) {
            [weak self] event in
            self?.lastActivity = Date()
            return event
        }
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowBecameKey() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.saveDrafts() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.settings.lockOnSleep == true { self?.lock() }
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                let idle = Date().timeIntervalSince(self.lastActivity)
                if !self.locked, idle >= Double(self.settings.autoLockMinutes * 60) { self.lock() }
            }
        }
    }

    /// Deletes the identity, the contacts and the messages of this Mac and shows the first
    /// launch; the mock data is only cleared.
    func resetEverything() {
        let messenger = messenger
        self.messenger = nil
        settingsDialog = nil
        settingsPage = nil
        modal = nil
        closeChat()
        panelOpen = false
        contacts = []
        messages = [:]
        drafts = [:]
        savedDrafts = [:]
        lastState = nil
        archiveOpen = false
        if messenger != nil { notifier.setBadge(0) }
        myID = ""
        settings = AppSettings()
        locked = false
        guard let messenger, let directory = dataDirectory else {
            welcome = .start
            return
        }
        welcome = .start
        Task { [weak self] in
            await messenger.close()
            do {
                try Messenger.erase(directory: directory)
                self?.attach(try Messenger(directory: directory, relay: Launch.current.relay))
            } catch {
                self?.connection = .stopped("The store cannot be opened: \(error).")
                self?.showToast(Messenger.describe(error))
            }
        }
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
        saveDrafts()
        openChatID = nil
        unreadAnchor = nil
        chatSearch = nil
        focusMessage = nil
    }

    func markRead(_ id: String) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        guard id == quietChat || messenger == nil else { return }
        if contacts[index].unread > 0 { run { try await $0.markRead(id) } }
        contacts[index].unread = 0
        alerts?.clear(id)
    }

    /// The window came to the front or was unlocked: the open chat is read now.
    func windowBecameKey() {
        if let id = openChatID { markRead(id) }
        if let lastState { updateBadge(lastState) }
        alerts?.refresh(ask: false)
    }

    func openFromNotification(_ id: String) {
        guard contact(id) != nil else { return }
        modal = nil
        archiveOpen = contact(id)?.archived ?? false
        openChat(id)
    }

    private func updateBadge(_ state: MessengerState) {
        alerts?.setBadge(Alerts.badge(state, settings: settings, quietChat: quietChat))
    }

    // MARK: Drafts, pins, mute, archive

    private func scheduleDraftSave() {
        guard messenger != nil else { return }
        draftSave?.cancel()
        draftSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveDrafts()
        }
    }

    /// Hands the drafts that changed to the messenger, in order; a failed write is tried
    /// again with the next change.
    func saveDrafts() {
        guard let messenger else { return }
        let changed = Set(drafts.keys).union(savedDrafts.keys).filter { drafts[$0] != savedDrafts[$0] }
        guard !changed.isEmpty else { return }
        let writes = changed.map { ($0, drafts[$0] ?? "") }
        changed.forEach { savedDrafts[$0] = drafts[$0] }
        let previous = draftWrite
        draftWrite = Task { [weak self] in
            await previous?.value
            for (id, text) in writes {
                do {
                    try await messenger.setDraft(text, for: id)
                } catch {
                    self?.savedDrafts[id] = "\u{0}"
                }
            }
        }
    }

    /// Saves the drafts and waits for the writes, before the app quits.
    func saveDraftsNow() async {
        saveDrafts()
        await draftWrite?.value
    }

    func setPinned(_ id: String, _ on: Bool) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(Motion.reorder) {
            if on {
                for other in contacts.indices where contacts[other].pinned != nil { contacts[other].pinned! += 1 }
                contacts[index].pinned = 0
            } else {
                contacts[index].pinned = nil
            }
        }
        run { try await $0.setPinned(id, on) }
    }

    func setMuted(_ id: String, _ on: Bool) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        contacts[index].muted = on
        run { try await $0.setMuted(id, on) }
    }

    func setArchived(_ id: String, _ on: Bool) {
        guard let index = contacts.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(Motion.reorder) {
            contacts[index].archived = on
            if on { contacts[index].pinned = nil }
            if archiveOpen, archivedContacts.isEmpty { archiveOpen = false }
        }
        run { try await $0.setArchived(id, on) }
        if on { showToast("Chat archived") }
    }

    // MARK: Search

    func open(_ row: SearchRow) {
        switch row {
        case .chat(let contact): openChat(contact.id)
        case .message(let contact, let message): focus(message.id, in: contact.id)
        }
    }

    /// Opens a chat at a message and highlights it.
    func focus(_ messageID: String, in id: String) {
        openChat(id)
        focusTick += 1
        focusMessage = FocusRequest(messageID: messageID, tick: focusTick)
    }

    func openChatSearch() {
        guard openChatID != nil else { return searchFocusTick += 1 }
        chatSearch = chatSearch ?? ""
        chatSearchIndex = 0
    }

    /// Moves to an older (`by` 1) or newer (`by` -1) result of the chat search.
    func stepChatSearch(_ by: Int) {
        let results = chatSearchResults
        guard !results.isEmpty else { return }
        chatSearchIndex = min(max(chatSearchIndex + by, 0), results.count - 1)
        focusTick += 1
        focusMessage = FocusRequest(messageID: results[chatSearchIndex].id, tick: focusTick)
    }

    func send(_ text: String, to id: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        drafts[id] = nil
        if messenger != nil {
            run({ try await $0.send(trimmed, to: id) }, failed: { [weak self] in
                if self?.drafts[id] == nil { self?.drafts[id] = trimmed }
            })
            return
        }
        let message = Message(outgoing: true, text: trimmed, date: Date(), state: .waiting)
        withAnimation(Motion.reorder) {
            messages[id, default: []].append(message)
        }
        if connection == .connected { store(message.id, in: id) }
    }

    /// The mock relay stores a message about a second after it leaves the outbox.
    private func store(_ messageID: String, in chat: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.connection == .connected,
                let index = self.messages[chat]?.firstIndex(where: { $0.id == messageID })
            else { return }
            self.messages[chat]?[index].state = .stored
        }
    }

    func deleteMessage(_ messageID: String, in chat: String) {
        if let position = Int64(messageID), messenger != nil {
            run { try await $0.deleteMessage(position) }
        }
        messages[chat]?.removeAll { $0.id == messageID }
    }

    /// Checks a new contact; returns the message for the field that failed, or nil when added.
    func addContact(name: String, id rawID: String) -> (name: String?, id: String?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = Self.normalizedID(rawID)
        let nameError = Messenger.nameProblem(name, saved: savedNames)?.message
        let idError = Self.idError(id, own: myID, existing: contacts)
        if nameError != nil || idError != nil { return (nameError, idError) }
        if messenger != nil {
            run { try await $0.addContact(name: name, userID: id) }
        } else {
            contacts.append(Contact(id: id, name: name, added: Date()))
        }
        modal = nil
        openChat(id)
        return (nil, nil)
    }

    private var savedNames: [String: String] {
        Dictionary(contacts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    static func normalizedID(_ raw: String) -> String {
        Messenger.normalizedID(raw)
    }

    static func idError(_ id: String, own: String, existing: [Contact]) -> String? {
        let saved = Dictionary(existing.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return Messenger.idProblem(id, own: own, saved: saved)?.message
    }

    /// Returns the message for the field, or nil when the name is taken over.
    func rename(_ id: String, to name: String) -> String? {
        var saved = savedNames
        saved[id] = nil
        if let problem = Messenger.nameProblem(name, saved: saved) { return problem.message }
        if messenger != nil {
            run { try await $0.rename(id, to: name) }
        } else if let index = contacts.firstIndex(where: { $0.id == id }) {
            contacts[index].name = name
        }
        modal = nil
        return nil
    }

    func resetSession(_ id: String) {
        modal = nil
        guard messenger != nil else { return showToast("Session reset") }
        run { [weak self] messenger in
            try await messenger.resetSession(id)
            await self?.showToast("Session reset")
        }
    }

    func deleteContact(_ id: String) {
        modal = nil
        if openChatID == id {
            closeChat()
            panelOpen = false
        }
        run { try await $0.deleteContact(id) }
        contacts.removeAll { $0.id == id }
        messages[id] = nil
        drafts[id] = nil
        if archiveOpen, archivedContacts.isEmpty { archiveOpen = false }
        showToast("Contact deleted")
    }

    /// Returns the message for the field, or nil when the address is taken over.
    func setRelay(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        do {
            _ = try Transport.serverName(of: trimmed, insecure: false)
        } catch {
            return Messenger.describe(error)
        }
        relayAddress = trimmed
        run { try await $0.setRelay(trimmed) }
        return nil
    }

    func reconnect() {
        run { await $0.reconnect() }
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
        guard let messenger else {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                withAnimation(Motion.box) { self?.welcome = .created }
            }
            return
        }
        Task { [weak self] in
            do {
                let made = try await messenger.createIdentity()
                self?.myID = made
                withAnimation(Motion.box) { self?.welcome = .created }
            } catch {
                self?.welcome = .start
                self?.showToast(Messenger.describe(error))
            }
        }
    }

    /// Escape, wherever the focus is (DESIGN.md 6).
    func escape() {
        if locked { return }
        if settingsDialog != nil {
            settingsDialog = nil
        } else if modal == .settings, settingsPage != nil {
            settingsPage = nil
        } else if modal != nil {
            modal = nil
        } else if chatSearch != nil {
            chatSearch = nil
        } else if searchFocused {
            if search.isEmpty { searchFocused = false } else { search = "" }
        } else if archiveOpen {
            archiveOpen = false
        } else if openChatID != nil {
            closeChat()
        }
    }
}
