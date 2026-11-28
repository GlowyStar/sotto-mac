import AppKit
import IOKit.pwr_mgt
import LocalAuthentication
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
    /// The latest profile the contact sent; `name` stays the local name.
    var profile: UserProfile?
    /// The user marked the safety number as compared (DESIGN.md 21).
    var verified = false
    /// When a key that the identity of the contact signed in place of the pinned one was
    /// refused; the chat shows the warning of DESIGN.md 21.4 while it is set.
    var refusedKey: Date?
    /// The chat is in the open vault (DESIGN.md 22).
    var hidden = false
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
    /// A delivery receipt of the contact names it (protocol section 39.5).
    case delivered
    /// A read receipt of the contact names it.
    case read
    /// Not sent, with the reason for a person.
    case failed(String)

    init(_ message: ChatMessage) {
        if let failure = message.failure {
            self = .failed(failure)
        } else if message.waiting {
            self = .waiting
        } else {
            switch message.receipt {
            case .read: self = .read
            case .delivered: self = .delivered
            case nil: self = .stored
            }
        }
    }
}

/// The message a reply answers as a bubble shows it (DESIGN.md 20.3): the id of the copy in
/// the chat when there is one, its current text and file, else the text the quote carried;
/// neither once it is gone.
struct MessageQuote: Hashable {
    var messageID: String?
    /// The quoted message is the user's own.
    let outgoing: Bool
    var text: String?
    var file: ChatFile?

    var isGone: Bool { messageID == nil && text == nil }

    /// The line of the quote: the kind of a photo or a file with its caption.
    var preview: String? {
        guard let text else { return nil }
        return Alerts.preview(text, file: file)
    }
}

struct Message: Identifiable, Hashable {
    var id = UUID().uuidString
    let outgoing: Bool
    var text: String
    let date: Date
    var state: MessageState = .stored
    /// The photo or file of the message; `text` is then its caption.
    var file: ChatFile?
    var quote: MessageQuote?
    /// The text was changed after it was sent.
    var edited = false
    /// The timer of the message in seconds, 0 for none.
    var expiresAfter = 0
    var expiresAt: Date?
    /// Until when an own message can be edited; nil when it cannot be.
    var editableUntil: Date?

    /// The text of the message for a list row: a photo or a file says so.
    var preview: String { Alerts.preview(text, file: file) }

    /// The position of a logged message; nil for a text waiting for a session, a file that
    /// is not logged yet and a message of the mock data.
    var position: Int64? { Int64(id).flatMap { $0 > 0 ? $0 : nil } }

    func canEdit(at now: Date = Date()) -> Bool {
        outgoing && (editableUntil.map { $0 > now } ?? false)
    }
}

/// An edit of an own message in the compose bar; the draft of the chat waits under it.
struct EditDraft: Hashable {
    let messageID: String
    let original: String
    let savedDraft: String?
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
    case notifications, chats, data, privacy, connection, advanced, profile
}

/// The boxes drawn over the settings panel.
enum SettingsDialog: Hashable {
    case myID
    case qrCode
    case crop
    case discardProfile
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
    /// The send box of the files in `AppModel.picks` (DESIGN.md 14.2).
    case sendFiles
    /// The delete box of a message: chat, message (DESIGN.md 20.6).
    case deleteMessage(String, String)
    /// The disappearing timer of a chat (DESIGN.md 20.7).
    case timer(String)
    /// The safety number of a contact with its QR code (DESIGN.md 21.3).
    case verify(String)
    /// The phrase box of a chat to hide, and the question when the phrase opens no vault
    /// (DESIGN.md 22.2).
    case hide(String)
    case hideConfirm(String)

    var isWide: Bool {
        switch self {
        case .addContact, .myID, .settings, .contactInfo, .sendFiles, .timer, .verify: true
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
    /// `--store-info`: prints which SQLCipher serves the store of `--data-dir`, and exits.
    var storeInfo = false
    /// `--safety-number NAME`: prints the safety number with the contact of that name as the
    /// contact panel shows it and the text of its QR code, from the store of `--data-dir`,
    /// and exits.
    var safetyNumberOf: String?
    /// `--send NAME TEXT`, any number of times: texts sent to the contacts of those names once
    /// the app is connected, through the action of the compose bar.
    var sends: [(name: String, text: String)] = []
    /// `--send-file NAME PATH`, any number of times: files sent like `--send`, a picture as a
    /// photo, through the action of the send box.
    var fileSends: [(name: String, path: String)] = []
    /// `--profile NAME PATH`: the profile set once the app is connected, through the action of
    /// the Edit profile page; an empty PATH is no picture.
    var profile: (name: String, path: String)?
    /// `--read NAME`: the chat of that name counts as open on the screen for the whole run, so
    /// that every message of the contact is seen as it arrives (DESIGN.md 20.5).
    var readChats: [String] = []
    /// `--reply NAME TEXT`, `--edit NAME TEXT`, `--delete NAME` and `--timer NAME SECONDS`:
    /// once the app is connected, a reply to the newest message of the contact, an edit of the
    /// newest own message that can be edited, a delete for both of the newest own message and
    /// a timer of the chat, each through the action of the screen. `--reset NAME`: a new
    /// session with the contact, through the action of its menu.
    var changes: [ScriptedChange] = []
    /// The first flag of the launch that prints, draws or acts on the chats of a store for a
    /// script: it needs a store of the test kind (docs/key-storage.md). Nil for none and for
    /// the mock data (`--demo`, or `--snapshot` without `--data-dir`).
    var scriptingFlag: String?

    static let scriptingFlags: Set<String> = [
        "--dump", "--snapshot", "--safety-number", "--send", "--send-file", "--profile", "--read", "--reply", "--edit",
        "--delete", "--timer", "--reset",
    ]

    static let current = Launch(CommandLine.arguments)

    init(_ arguments: [String]) {
        for (index, argument) in arguments.enumerated() where index + 2 < arguments.count {
            if argument == "--send" { sends.append((arguments[index + 1], arguments[index + 2])) }
            if argument == "--send-file" { fileSends.append((arguments[index + 1], arguments[index + 2])) }
            if argument == "--profile" { profile = (arguments[index + 1], arguments[index + 2]) }
            if argument == "--reply" { changes.append(.reply(arguments[index + 1], arguments[index + 2])) }
            if argument == "--edit" { changes.append(.edit(arguments[index + 1], arguments[index + 2])) }
            if argument == "--timer", let seconds = Int(arguments[index + 2]) {
                changes.append(.timer(arguments[index + 1], seconds))
            }
        }
        for (index, argument) in arguments.enumerated() where index + 1 < arguments.count {
            if argument == "--read" { readChats.append(arguments[index + 1]) }
            if argument == "--delete" { changes.append(.delete(arguments[index + 1])) }
            if argument == "--reset" { changes.append(.reset(arguments[index + 1])) }
        }
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        demo = arguments.contains("--demo")
        firstLaunch = arguments.contains("--first-launch")
        dump = arguments.contains("--dump")
        storeInfo = arguments.contains("--store-info")
        dataDirectory = value(after: "--data-dir").map { URL(fileURLWithPath: $0, isDirectory: true) }
        relay = value(after: "--relay") ?? Self.defaultRelay
        snapshot = value(after: "--snapshot").map { URL(fileURLWithPath: $0, isDirectory: true) }
        safetyNumberOf = value(after: "--safety-number")
        if dataDirectory != nil || !(demo || snapshot != nil) {
            scriptingFlag = arguments.dropFirst().first(where: Self.scriptingFlags.contains)
        }
    }

    var directory: URL {
        dataDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sotto", isDirectory: true)
    }
}

/// An action of part 5, or a reset, that a launch flag asks for, by the local name of the chat.
enum ScriptedChange {
    case reply(String, String)
    case edit(String, String)
    case delete(String)
    case timer(String, Int)
    case reset(String)

    var chatName: String {
        switch self {
        case .reply(let name, _), .edit(let name, _), .delete(let name), .timer(let name, _), .reset(let name): name
        }
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
    /// The user's own profile.
    var profile = UserProfile()
    /// The Edit profile page while it is open (DESIGN.md 12.1).
    var profileDraft: ProfileDraft?
    /// The picture of the crop box while it is open.
    var cropSource: CropSource?
    /// Set while the system file panel for an avatar is open.
    var pickingAvatar = false
    /// The contact photo open over the window (DESIGN.md 16).
    var avatarViewer: ProfilePhoto?
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
    /// Set while a chat is being hidden: the key derivation of the phrase takes a moment.
    var hiding = false
    /// The phrase of the hide box while its question waits for an answer.
    @ObservationIgnored private var hidePhrase: String?
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
    /// Set while the store is closed and its key dropped: the unlock screen covers the window
    /// until Touch ID or the Mac password opens it (DESIGN.md 11.6).
    var storeLocked = false
    /// Why the last unlock of the store failed; nil after a cancel.
    var unlockFailure: String?
    @ObservationIgnored private var unlocking = false
    /// Set while a lock closes the messenger; no unlock starts meanwhile.
    @ObservationIgnored private var closing: Task<Void, Never>?
    @ObservationIgnored private var sleepWatcher: SleepWatcher?
    /// Either lock screen covers the window.
    var covered: Bool { locked || storeLocked }
    /// The data folder; nil for the mock data.
    private(set) var dataDirectory: URL?
    /// The size of the data folder, read when the storage page opens.
    var storageBytes: Int64?
    @ObservationIgnored var lastActivity = Date()
    /// Bumped to ask the compose field for focus.
    var composeFocusTick = 0
    /// Bumped to ask the search field for focus.
    var searchFocusTick = 0
    /// The files of the send box, in the order they go (DESIGN.md 14.2).
    var picks: [Pick] = []
    var sendAsFile = false
    var attachMenuOpen = false
    /// Files dragged over the chat area (DESIGN.md 14.3).
    var drop: DropState?
    /// The photo open in the media viewer (DESIGN.md 15).
    var viewer: ViewerItem?
    /// The messages whose kept photo the picture cache of `Media` may hold, so that a photo
    /// that goes leaves memory too; a lock empties the cache (docs/key-storage.md).
    @ObservationIgnored var keptDecoded: Set<String> = []
    /// Files handed to the messenger that it has not logged yet, by chat; each shows as a
    /// message until the message of its upload replaces it.
    @ObservationIgnored var localSends: [String: [LocalSend]] = [:]
    /// The last file handed to the messenger; the next waits for it, so files keep their order.
    @ObservationIgnored var lastFileSend: Task<Void, Never>?
    /// The disappearing timer of each chat in seconds (DESIGN.md 20.7).
    var timers: [String: Int] = [:]
    /// The changes of the timer of each chat, shown as service lines.
    var timerChanges: [String: [TimerChange]] = [:]
    /// Whether contacts get read receipts (DESIGN.md 20.9).
    var readReceipts = true
    /// The message each chat answers in its compose bar (DESIGN.md 20.2).
    var replies: [String: String] = [:]
    /// The own message each chat edits in its compose bar (DESIGN.md 20.4).
    var edits: [String: EditDraft] = [:]
    /// The incoming messages of each chat that the list shows on screen.
    @ObservationIgnored var onScreen: [String: [String]] = [:]
    /// The messages already reported as seen to the messenger.
    @ObservationIgnored var reportedSeen: Set<String> = []
    @ObservationIgnored var scriptedReads: [String] = []
    @ObservationIgnored var scriptedChanges: [ScriptedChange] = []

    /// The safety number of each contact, made once and kept in memory: 5200 SHA-512 per
    /// key (protocol section 44.2).
    @ObservationIgnored private var safetyNumbers: [String: SafetyNumber] = [:]

    private var toastTask: Task<Void, Never>?
    private var scriptedSends: [(name: String, text: String)] = []
    private var scriptedFileSends: [(name: String, path: String)] = []
    private var scriptedProfile: (name: String, path: String)?
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

    /// The app over the store in `directory`, locked until `unlockStore`.
    init(directory: URL) {
        myID = ""
        relayAddress = ""
        connection = .idle
        dataDirectory = directory
        settings = Self.launchSettings(directory)
        storeLocked = true
        clearOpenedFiles()
        scriptedSends = Launch.current.sends
        scriptedFileSends = Launch.current.fileSends
        scriptedProfile = Launch.current.profile
        scriptedReads = Launch.current.readChats
        scriptedChanges = Launch.current.changes
    }

    /// Asks for Touch ID or the Mac password with the system sheet (a store of the test kind
    /// asks nothing), unwraps the store key and opens the messenger; the passcode, when set,
    /// is asked after that.
    func unlockStore() {
        guard storeLocked, !unlocking, closing == nil, messenger == nil, let directory = dataDirectory else { return }
        unlocking = true
        unlockFailure = nil
        Task {
            defer { unlocking = false }
            do {
                let protection = try StoreProtection.asked(for: directory)
                let context = LAContext()
                if protection == .presence {
                    try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "open your chats")
                }
                try StoreKeys.unlock(directory, protection: protection, context: context)
                if Launch.current.scriptingFlag != nil { try StoreKeys.requireTestKind(directory) }
                let messenger = try Self.messenger(directory)
                settings = messenger.launchSettings ?? Self.launchSettings(directory)
                locked = settings.passcode != nil
                storeLocked = false
                lastActivity = Date()
                attach(messenger)
                if messenger.tookInOlderNotes { alerts?.removeAll() }
                alerts?.refresh(ask: settings.notifications)
            } catch let error as LAError where [.userCancel, .appCancel, .systemCancel].contains(error.code) {
            } catch {
                StoreKeys.lock(directory)
                unlockFailure = Messenger.describe(error)
            }
        }
    }

    /// The settings before the store opens: the theme of `app.json`, which the lock screen
    /// shows; before the settings had a page the theme was kept in the user defaults.
    private static func launchSettings(_ directory: URL) -> AppSettings {
        var settings = AppSettings()
        let legacy = UserDefaults.standard.string(forKey: "theme").flatMap(AppSettings.Theme.init(rawValue:))
        if let theme = Messenger.launchTheme(directory: directory) ?? legacy {
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
        return AppModel(directory: launch.directory)
    }

    /// The messenger of a data folder; received files stay in the store unless the settings
    /// save them into a folder, the user's Downloads folder unless they name another.
    static func messenger(_ directory: URL) throws -> Messenger {
        try Messenger(
            directory: directory, relay: Launch.current.relay,
            receivedFiles: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
    }

    /// Takes over a state of the messenger; the chat open in the key window counts as read.
    /// New incoming messages become notifications and the Dock badge follows the unread count.
    func apply(_ state: MessengerState) {
        if storeLocked { return }
        if let userID = state.userID { myID = userID }
        relayAddress = state.relay
        connection = ConnectionState(state.link)
        profile = state.profile
        let quiet = quietChat
        if lastState == nil {
            let loaded = Dictionary(uniqueKeysWithValues: state.chats.compactMap { chat in chat.draft.map { (chat.userID, $0) } })
            savedDrafts = loaded
            drafts = loaded
        }
        contacts = state.chats.map {
            Contact(
                id: $0.userID, name: $0.name, added: $0.added, unread: $0.userID == quiet ? 0 : $0.unread,
                pinned: $0.pinned, muted: $0.muted, archived: $0.archived, profile: $0.profile,
                verified: $0.verified, refusedKey: $0.refusedKey, hidden: $0.hidden)
        }
        timers = Dictionary(uniqueKeysWithValues: state.chats.map { ($0.userID, $0.timer) })
        timerChanges = Dictionary(uniqueKeysWithValues: state.chats.map { ($0.userID, $0.timerChanges) })
        readReceipts = state.readReceipts
        messages = Dictionary(uniqueKeysWithValues: state.chats.map { chat in
            let logged = chat.messages.map(Message.init)
            let ids = Set(logged.map(\.id))
            localSends[chat.userID]?.removeAll { $0.resolved.map(ids.contains) ?? false }
            return (chat.userID, logged + (localSends[chat.userID] ?? []).filter { !$0.cancelled }.map(\.message))
        })
        // A photo that is gone, deleted or expired, leaves memory too.
        let shown = Set(messages.values.joined().map(\.id))
        for id in keptDecoded.subtracting(shown) { Media.forgetKept(id) }
        keptDecoded.formIntersection(shown)
        if let quiet, state.chats.contains(where: { $0.userID == quiet && $0.unread > 0 }) {
            run { try await $0.markRead(quiet) }
        }
        dropGoneComposeModes()
        if let quiet { reportSeen(in: quiet) }
        for name in scriptedReads {
            if let contact = contacts.first(where: { $0.name == name }) {
                onScreen[contact.id] = messages[contact.id, default: []].filter { !$0.outgoing }.map(\.id)
                reportSeen(in: contact.id)
            }
        }
        if messenger != nil {
            Alerts.make(old: lastState, new: state, settings: settings, quietChat: quiet, locked: locked)
                .forEach { alerts?.post($0) }
            alerts?.remove(Alerts.changed(old: lastState, new: state))
            updateBadge(state)
        }
        lastState = state
        if archiveOpen, archivedContacts.isEmpty { archiveOpen = false }
        if connection == .connected, let scripted = scriptedProfile {
            scriptedProfile = nil
            setScriptedProfile(name: scripted.name, path: scripted.path)
        }
        if connection == .connected, !scriptedSends.isEmpty || !scriptedFileSends.isEmpty {
            for (name, text) in scriptedSends {
                if let contact = contacts.first(where: { $0.name == name }) {
                    send(text, to: contact.id)
                } else {
                    FileHandle.standardError.write(Data("--send: no contact named \(name)\n".utf8))
                }
            }
            scriptedSends = []
            for (name, path) in scriptedFileSends {
                if let contact = contacts.first(where: { $0.name == name }), let pick = Pick(URL(fileURLWithPath: path)) {
                    send([pick], caption: "", asFile: false, to: contact.id)
                } else {
                    FileHandle.standardError.write(Data("--send-file: no contact named \(name) or no file \(path)\n".utf8))
                }
            }
            scriptedFileSends = []
        }
        if connection == .connected, !scriptedChanges.isEmpty {
            let changes = scriptedChanges
            scriptedChanges = []
            changes.forEach(runScripted)
        }
    }

    /// Runs an action of the messenger; its error becomes a toast.
    func run(_ action: @escaping @Sendable (Messenger) async throws -> Void, failed: (@MainActor () -> Void)? = nil) {
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
            (messages[contact.id] ?? []).filter { $0.preview.localizedCaseInsensitiveContains(query) }.map { (contact, $0) }
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
        profileDraft = nil
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

    /// Overwrites the store key at once, closes the store and covers the window until Touch
    /// ID or the Mac password opens it again; also on the first-launch screen, since the store
    /// is open once a messenger is attached. The task ends when every connection to the store
    /// is closed; nil when nothing was open. The mock data has only the passcode lock.
    @discardableResult
    func lock() -> Task<Void, Never>? {
        if let closing { return closing }
        guard let messenger, let directory = dataDirectory else {
            if !storeLocked, welcome == nil, settings.passcode != nil { locked = true }
            return nil
        }
        storeLocked = true
        locked = false
        StoreKeys.lock(directory)
        // The vault closes with the store, and the notifications of its chats go with it.
        alerts?.clear(Alerts.hiddenThread)
        let task = Task {
            await saveDraftsNow()
            self.messenger = nil
            await messenger.close()
            clearContent()
            closing = nil
        }
        closing = task
        return task
    }

    /// Drops the store key and closes the store before the app quits.
    func closeStore() async {
        if let dataDirectory { StoreKeys.lock(dataDirectory) }
        alerts?.clear(Alerts.hiddenThread)
        await saveDraftsNow()
        let messenger = messenger
        self.messenger = nil
        await messenger?.close()
        clearOpenedFiles()
    }

    /// Forgets what the window shows of the chats.
    private func clearContent() {
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
        profileDraft = nil
        viewer = nil
        avatarViewer = nil
        replies = [:]
        edits = [:]
        picks = []
        hidePhrase = nil
        keptDecoded = []
        Media.forget()
        clearOpenedFiles()
        ChatPasteboard.clear()
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
        // Sleep, a locked screen and a switch to another user lock alike; loginwindow posts
        // the distributed com.apple.screenIsLocked when the screen locks.
        let workspace = NSWorkspace.shared.notificationCenter
        let lockEvents: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")),
        ]
        for (center, name) in lockEvents {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if self?.settings.lockOnSleep == true { self?.lock() }
                }
            }
        }
        // The same lock, and the sleep waits until the store is closed.
        sleepWatcher = SleepWatcher { [weak self] done in
            MainActor.assumeIsolated {
                guard let self, self.settings.lockOnSleep, let closing = self.lock() else { return done() }
                Task {
                    await closing.value
                    done()
                }
            }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                let idle = Date().timeIntervalSince(self.lastActivity)
                if !self.storeLocked, idle >= Double(self.settings.autoLockMinutes * 60) { self.lock() }
            }
        }
    }

    /// Deletes the identity, the contacts and the messages of this Mac and shows the first
    /// launch; the mock data is only cleared.
    func resetEverything() {
        let messenger = messenger
        self.messenger = nil
        clearContent()
        if messenger != nil { notifier.setBadge(0) }
        myID = ""
        profile = UserProfile()
        profileDraft = nil
        settings = AppSettings()
        locked = false
        guard let messenger, let directory = dataDirectory else {
            welcome = .start
            return
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(Messenger.pastedFolder, isDirectory: true))
        welcome = .start
        Task { [weak self] in
            await messenger.close()
            do {
                try Messenger.erase(directory: directory)
                self?.storeLocked = true
                self?.unlockStore()
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
        attachMenuOpen = false
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
        alerts?.clear(contacts[index].hidden ? Alerts.hiddenThread : id)
    }

    /// The window came to the front or was unlocked: the open chat is read now.
    func windowBecameKey() {
        if let id = openChatID {
            markRead(id)
            if id == quietChat { reportSeen(in: id) }
        }
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
        // A chat in edit mode keeps the draft that waits under the edit, never the edited text.
        func kept(_ id: String) -> String? { edits[id].map(\.savedDraft) ?? drafts[id] }
        let changed = Set(drafts.keys).union(savedDrafts.keys).union(edits.keys).filter { kept($0) != savedDrafts[$0] }
        guard !changed.isEmpty else { return }
        let writes = changed.map { ($0, kept($0) ?? "") }
        changed.forEach { savedDrafts[$0] = kept($0) }
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

    // MARK: Hidden chats (DESIGN.md 22)

    /// Hides a chat behind the phrase; a phrase that opens no vault asks first. The mock data
    /// only takes the row away.
    func hideChat(_ id: String, phrase: String) {
        guard let messenger else {
            modal = nil
            contacts.removeAll { $0.id == id }
            return
        }
        hiding = true
        Task { [weak self] in
            defer { self?.hiding = false }
            do {
                if try await messenger.hideChat(id, phrase: phrase) {
                    self?.hidden(id)
                } else {
                    self?.hidePhrase = phrase
                    self?.modal = .hideConfirm(id)
                }
            } catch {
                self?.showToast(Messenger.describe(error))
            }
        }
    }

    /// The answer to the question of a phrase that opened no vault: a new vault under it.
    func confirmHide(_ id: String) {
        guard let messenger, let phrase = hidePhrase else { return }
        hidePhrase = nil
        hiding = true
        Task { [weak self] in
            defer { self?.hiding = false }
            do {
                _ = try await messenger.hideChat(id, phrase: phrase, makeNew: true)
                self?.hidden(id)
            } catch {
                self?.showToast(Messenger.describe(error))
            }
        }
    }

    private func hidden(_ id: String) {
        modal = nil
        if openChatID == id {
            closeChat()
            panelOpen = false
        }
        showToast("Chat hidden")
    }

    func unhideChat(_ id: String) {
        run { try await $0.unhideChat(id) }
        showToast("Chat unhidden")
    }

    /// Return in the list search: a text as long as a phrase is tried on the vault first, and
    /// one that opens it leaves the field; otherwise, and for a shorter text, Return opens the
    /// selected row. Nothing tells a wrong phrase from a folder without a vault.
    func submitSearch() {
        let text = search
        guard let messenger, Vault.normalized(text).count >= Vault.minimumPhraseLength else {
            return openSelectedSearchRow()
        }
        Task { [weak self] in
            do {
                if try await messenger.openVault(text) {
                    if self?.search == text { self?.search = "" }
                    return
                }
            } catch {
                self?.showToast(Messenger.describe(error))
                return
            }
            self?.openSelectedSearchRow()
        }
    }

    private func openSelectedSearchRow() {
        let rows = searchRows
        guard rows.indices.contains(searchSelection) else { return }
        open(rows[searchSelection])
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
        if edits[id] != nil {
            return saveEdit(text, in: id)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        drafts[id] = nil
        let replyID = replies.removeValue(forKey: id)
        if messenger != nil {
            let replyTo = replyID.flatMap { Int64($0) }
            run({ try await $0.send(trimmed, to: id, replyTo: replyTo) }, failed: { [weak self] in
                if self?.drafts[id] == nil { self?.drafts[id] = trimmed }
            })
            return
        }
        var message = Message(outgoing: true, text: trimmed, date: Date(), state: .waiting)
        message.quote = replyID.flatMap { quote(of: $0, in: id) }
        withAnimation(Motion.reorder) {
            messages[id, default: []].append(message)
        }
        if connection == .connected { store(message.id, in: id) }
    }

    /// The mock relay stores a message about a second after it leaves the outbox.
    func store(_ messageID: String, in chat: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.connection == .connected,
                let index = self.messages[chat]?.firstIndex(where: { $0.id == messageID })
            else { return }
            self.messages[chat]?[index].state = .stored
        }
    }

    /// Deletes a message on this Mac only (Delete for me).
    func deleteMessage(_ messageID: String, in chat: String) {
        endComposeModes(for: messageID, in: chat)
        if let index = localSends[chat]?.firstIndex(where: { $0.message.id == messageID }) {
            localSends[chat]?[index].cancelled = true
            localSends[chat]?[index].task?.cancel()
        }
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

    // MARK: Safety number and the verified mark (DESIGN.md 21)

    /// The safety number of the user and the contact; nil when either id is not one.
    func safetyNumber(_ id: String) -> SafetyNumber? {
        let key = myID + id
        if let known = safetyNumbers[key] { return known }
        guard let own = try? Identity.decodeUserID(myID), let contact = try? Identity.decodeUserID(id),
            let made = try? SafetyNumber(identityKey: own, contactIdentityKey: contact)
        else { return nil }
        safetyNumbers[key] = made
        return made
    }

    func setVerified(_ on: Bool, _ id: String) {
        guard messenger != nil else {
            if let index = contacts.firstIndex(where: { $0.id == id }) { contacts[index].verified = on }
            return
        }
        run { try await $0.setVerified(on, for: id) }
    }

    func dismissRefusedKey(_ id: String) {
        guard messenger != nil else {
            if let index = contacts.firstIndex(where: { $0.id == id }) { contacts[index].refusedKey = nil }
            return
        }
        run { try await $0.dismissRefusedKey(id) }
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
        if viewer != nil {
            viewer = nil
        } else if avatarViewer != nil {
            avatarViewer = nil
        } else if attachMenuOpen {
            attachMenuOpen = false
        } else if settingsDialog != nil {
            if settingsDialog == .crop { cropSource = nil }
            settingsDialog = nil
        } else if modal == .settings, settingsPage != nil {
            leavePage()
        } else if modal != nil {
            modal = nil
        } else if chatSearch != nil {
            chatSearch = nil
        } else if let id = openChatID, replies[id] != nil || edits[id] != nil {
            cancelComposeMode(in: id)
        } else if searchFocused {
            if search.isEmpty { searchFocused = false } else { search = "" }
        } else if archiveOpen {
            archiveOpen = false
        } else if openChatID != nil {
            closeChat()
        }
    }
}

/// Holds the sleep of the Mac until `onSleep` calls its completion: IOKit waits for the answer
/// to a system sleep, up to 30 seconds, while an observer of NSWorkspace delays it only by
/// blocking the main thread.
final class SleepWatcher {
    // iokit_common_msg(0x270) and iokit_common_msg(0x280) of IOMessage.h, which Swift does not
    // import: kIOMessageCanSystemSleep and kIOMessageSystemWillSleep.
    private static let canSleep: natural_t = 0xE000_0270
    private static let willSleep: natural_t = 0xE000_0280
    private let onSleep: (@escaping @Sendable () -> Void) -> Void
    private var root: io_connect_t = 0
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0

    init(onSleep: @escaping (_ done: @escaping @Sendable () -> Void) -> Void) {
        self.onSleep = onSleep
        root = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(), &port,
            { context, _, message, argument in
                guard let context else { return }
                Unmanaged<SleepWatcher>.fromOpaque(context).takeUnretainedValue().handle(message, Int(bitPattern: argument))
            }, &notifier)
        if root != 0 { IONotificationPortSetDispatchQueue(port, .main) }
    }

    private func handle(_ message: natural_t, _ change: Int) {
        let root = root
        switch message {
        case Self.canSleep: IOAllowPowerChange(root, change)
        case Self.willSleep: onSleep { IOAllowPowerChange(root, change) }
        default: break
        }
    }
}

/// Chat texts and pictures on the general pasteboard, marked concealed and transient
/// (nspasteboard.org) so that clipboard managers neither show nor keep them; a lock takes
/// them off while the pasteboard still holds what Sotto put there (docs/key-storage.md).
@MainActor
enum ChatPasteboard {
    private static let markers = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
    ]
    private static var written: Int?

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        mark()
    }

    static func copy(_ image: NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        mark()
    }

    /// Marks what was just written to the general pasteboard as a copy of the chats.
    static func mark() {
        let board = NSPasteboard.general
        board.addTypes(markers, owner: nil)
        for marker in markers { board.setData(Data(), forType: marker) }
        written = board.changeCount
    }

    /// Clears the pasteboard unless something was copied after Sotto's copy.
    static func clear() {
        guard let written, NSPasteboard.general.changeCount == written else { return }
        NSPasteboard.general.clearContents()
        self.written = nil
    }
}
