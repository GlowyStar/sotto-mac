import CryptoKit
import Foundation

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    /// The position of the row in the message log; for a text that waits for a session, the
    /// position of its row among the pending texts, negated.
    public let id: Int64
    public let outgoing: Bool
    public let text: String
    public let date: Date
    /// An outgoing message that waits for a session or in the outbox; false once the relay
    /// stored it or once it failed.
    public let waiting: Bool
    /// Why an outgoing message is not sent: the relay refused it, or it could not be made.
    public var failure: String?
    /// The file of the message; `text` is then its caption.
    public var file: ChatFile? = nil
    /// The message this one answers (protocol section 39.2).
    public var quote: ChatQuote? = nil
    /// The text was changed after the message was sent (section 39.3).
    public var edited = false
    /// The last receipt of the peer for an own message (section 39.5).
    public var receipt: ReceiptKind? = nil
    /// The timer the message carries in seconds, 0 for none (section 39.6).
    public var expiresAfter = 0
    /// When the message disappears; nil while its timer has not started.
    public var expiresAt: Date? = nil
    /// Until when an own message can be edited; nil when it cannot be (section 39.3).
    public var editableUntil: Date? = nil
}

/// The message a reply quotes, as the app shows it: its own copy when it has one
/// (`position`, the current text and file), else the text the quote carried; neither once
/// that message is gone (protocol section 39.2).
public struct ChatQuote: Codable, Hashable, Sendable {
    public var position: Int64?
    /// The quoted message is the user's own.
    public var outgoing: Bool
    public var text: String?
    public var file: ChatFile?

    public init(position: Int64?, outgoing: Bool, text: String?, file: ChatFile? = nil) {
        self.position = position
        self.outgoing = outgoing
        self.text = text
        self.file = file
    }

    /// The quoted message is gone here and its quote keeps no text.
    public var isGone: Bool { position == nil && text == nil }
}

/// A change of the disappearing timer of a chat, shown as a service line (section 39.8).
public struct TimerChange: Codable, Hashable, Sendable {
    public var date: Date
    public var seconds: Int
    /// The user set it, not the contact.
    public var own: Bool

    public init(date: Date, seconds: Int, own: Bool) {
        self.date = date
        self.seconds = seconds
        self.own = own
    }
}

/// A file sent or received (section 33.5).
public struct ChatFile: Codable, Hashable, Sendable {
    /// The media types that the app shows as a photo; any other file, and a picture sent with
    /// an empty media type, shows as a file.
    public static let photoTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/heic", "image/heif", "image/webp", "image/tiff", "image/bmp",
    ]

    /// The name in the attachment: a text of the peer for a received file.
    public let name: String
    public let size: Int
    public let mediaType: String
    public let state: FileState
    /// Bytes of the blob stored at the relay or downloaded, out of `total`, while the file is
    /// sending or receiving; 0 before the first piece.
    public let done: Int
    public let total: Int
    /// Where a received file was saved, or the file a sent one was read from; nil when the
    /// store keeps the file (`kept`) or it is not here.
    public let savedAs: String?
    /// Why the file failed: a result of section 33.6 or of a refusal.
    public let result: String?
    /// The image size in pixels, 0 when the sender gave none.
    public var width = 0
    public var height = 0
    /// The thumbnail as the sender gave it; `Thumbnail.decode` tells whether it may be shown.
    public var thumbnail = Data()
    /// The store keeps the bytes of the file, which `Messenger.contents` reads.
    public var kept = false

    public init(
        name: String, size: Int, mediaType: String, state: FileState, done: Int = 0, total: Int = 0,
        savedAs: String? = nil, result: String? = nil, width: Int = 0, height: Int = 0, thumbnail: Data = Data(),
        kept: Bool = false
    ) {
        self.name = name
        self.size = size
        self.mediaType = mediaType
        self.state = state
        self.done = done
        self.total = total
        self.savedAs = savedAs
        self.result = result
        self.width = width
        self.height = height
        self.thumbnail = thumbnail
        self.kept = kept
    }

    public var isPhoto: Bool { Self.isPhoto(mediaType) }

    public static func isPhoto(_ mediaType: String) -> Bool {
        photoTypes.contains(mediaType.lowercased())
    }
}

/// A file to send again is not where it was read from.
public struct FileGoneError: Error, Equatable, Sendable {}

/// A profile of part 4: the user's own, or the latest one a contact sent.
public struct UserProfile: Codable, Hashable, Sendable {
    /// The display name; for a contact, a text of the peer that its local name wins over.
    public var name: String
    public var avatar: ProfilePhoto?

    public init(name: String = "", avatar: ProfilePhoto? = nil) {
        self.name = name
        self.avatar = avatar
    }
}

/// The avatar of a profile (protocol section 36.4).
public struct ProfilePhoto: Codable, Hashable, Sendable {
    /// Changes whenever the picture does: the blob id of a contact's avatar in hex, a digest
    /// of the user's own.
    public var key: String
    /// The picture, once it is received; always there for the user's own avatar.
    public var picture: Data?
    /// The JPEG thumbnail that came with the picture, possibly empty.
    public var thumbnail: Data
    /// Received, or why the picture is not here (section 36.5).
    public var state: FileState

    public init(key: String, picture: Data?, thumbnail: Data, state: FileState) {
        self.key = key
        self.picture = picture
        self.thumbnail = thumbnail
        self.state = state
    }
}

public struct Chat: Codable, Equatable, Sendable {
    public let userID: String
    public let name: String
    public let added: Date
    public let unread: Int
    public let messages: [ChatMessage]
    /// The place among the pinned chats, 0 on top; nil when the chat is not pinned.
    public var pinned: Int?
    public var muted = false
    public var archived = false
    /// The text typed in the compose bar and not sent.
    public var draft: String?
    /// The latest profile the contact sent; `name` above stays the local name.
    public var profile: UserProfile?
    /// The disappearing timer of the chat in seconds, 0 when off (section 39.6).
    public var timer = 0
    /// The changes of the timer, oldest first.
    public var timerChanges: [TimerChange] = []
    /// The user marked the contact as verified after comparing the safety number (protocol
    /// section 45).
    public var verified = false
    /// When a key that the identity of the contact signed in place of the pinned one was
    /// last refused (IDENTITY_KEY_MISMATCH, protocol sections 5.3 and 45.2); nil when none
    /// was, or once the user took the warning off the chat.
    public var refusedKey: Date?
}

public enum LinkState: Codable, Equatable, Sendable {
    /// No transport runs: no identity yet, or a read of the store without a connection.
    case idle
    case connecting
    case connected
    /// The transport does not reconnect by itself; the text is for a person.
    case stopped(String)
}

public struct MessengerState: Codable, Equatable, Sendable {
    /// Nil until an identity exists.
    public var userID: String?
    public var chats: [Chat]
    public var link: LinkState
    public var relay: String
    /// The user's own profile; empty until one is set.
    public var profile = UserProfile()
    /// Whether contacts get read receipts (section 39.5).
    public var readReceipts = true
}

public enum ContactError: Error, Equatable, Sendable {
    case emptyName
    case nameTaken(String)
    case wrongLength
    case notHex
    case ownID
    case alreadySaved(String)

    public var message: String {
        switch self {
        case .emptyName: "Enter a name."
        case .nameTaken(let name): "A contact named \(name) exists."
        case .wrongLength: "The id must be 64 characters long."
        case .notHex: "The id may contain only 0-9 and a-f."
        case .ownID: "This is your own id."
        case .alreadySaved(let name): "This contact is already saved as \(name)."
        }
    }

    public var isAboutName: Bool {
        switch self {
        case .emptyName, .nameTaken: true
        default: false
        }
    }
}

public struct NotConnectedError: Error, Equatable, Sendable {}

/// What the app shows and does, over the store, the session layer and the transport of one
/// identity. Every change is published on `changes` as a whole new state.
///
/// Its notes are kept in the store with the rest (docs/key-storage.md): the relay address
/// once it is set here, the last read position of each chat, when each contact and message
/// was first seen, the drafts, pins, muted and archived chats, and the settings of the app.
/// `app.json` next to the store keeps only the theme, which the lock screen shows before
/// the store is open.
public actor Messenger {
    public static let notesFile = "app.json"
    /// Where a version before the notes moved into the store kept pasted pictures.
    public static let pastedFolder = "Pasted"
    /// Where a file the store keeps is written for another app to open; Spotlight skips a
    /// `.noindex` folder.
    public static let openedFolder = "temp.noindex"
    static let pollSeconds = 0.5
    static let expirySeconds = 1.0

    public nonisolated let changes: AsyncStream<MessengerState>
    /// Whether the store held an identity when it was opened.
    public nonisolated let hadIdentity: Bool
    /// This open took in the notes of an older `app.json`: the notifications that version
    /// posted may still show names and texts.
    public nonisolated let tookInOlderNotes: Bool
    /// The settings the store held when it was opened; nil when none were saved yet.
    public nonisolated let launchSettings: AppSettings?
    private let sink: AsyncStream<MessengerState>.Continuation
    private let directory: URL
    /// The connection that writes the notes, in the order they change.
    private let notesStore: ClientStore
    private let launchRelay: String
    private var notes: Notes
    private var userID: String?
    private var link = LinkState.idle
    private var transport: Transport?
    /// The session layer while no transport owns one.
    private var client: Client?
    private var runner: Task<Void, Never>?
    private var listener: Task<Void, Never>?
    private var poller: Task<Void, Never>?
    /// Removes expired messages every `expirySeconds` for the whole life of the messenger,
    /// also after the transport stopped (protocol section 39.6).
    private var expirer: Task<Void, Never>?
    /// Commits the pending texts through the transport, one at a time.
    private var flusher: Task<Void, Never>?
    private var flushAgain = false
    private var last: MessengerState?
    private let receivedFiles: URL?
    /// The progress of each file that is sending or receiving, by message id.
    private var progress: [Data: Progress] = [:]
    /// The copies written into `openedFolder`, by the position of their message.
    private var opened: [Int64: [URL]] = [:]
    private var closed = false

    /// Opens the store in `directory`, creating it when it is missing; `relay` is used until
    /// an address is saved with `setRelay`. Received files are downloaded, each by itself
    /// when it is within the auto-download size of its kind and the others when `download`
    /// asks, and kept in the store; with "Save received files automatically" they are
    /// written into the folder of the settings, or `receivedFiles` when they name none. A
    /// nil `receivedFiles` leaves every received file offered.
    ///
    /// The first open since the notes moved into the store takes them in from `app.json`
    /// and the pasted pictures from their folder, and leaves neither readable there.
    public init(directory: URL, relay: String, receivedFiles: URL? = nil) throws {
        self.directory = directory
        self.receivedFiles = receivedFiles
        launchRelay = relay
        let store = try ClientStore(directory: directory)
        userID = try store.identity().map { try Identity.encodeUserID(Identity.deriveIdentityKey(seed: $0.seed)) }
        hadIdentity = userID != nil
        (notes, tookInOlderNotes) = try Self.takeInNotes(store, directory)
        try Self.takeInPasted(store, directory)
        notesStore = store
        launchSettings = notes.settings
        (changes, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// The notes of the store; at the first open since they moved there, the ones of
    /// `app.json`, saved into the store before `app.json` is left with the theme only. A
    /// notification of such a file shows neither the name nor the text: the file cannot
    /// tell a choice to show them from the default of its version.
    static func takeInNotes(_ store: ClientStore, _ directory: URL) throws -> (Notes, older: Bool) {
        var notes: Notes
        var older = false
        if let stored = try Notes.load(store) {
            notes = stored
        } else {
            let legacy = Notes.legacy(directory)
            older = legacy != nil
            notes = legacy ?? Notes()
            notes.settings?.notificationSender = false
            notes.settings?.notificationPreview = false
            try notes.save(store)
        }
        try keepLaunchNotes(directory, theme: notes.settings?.theme ?? launchTheme(directory: directory))
        return (notes, older)
    }

    /// The theme that `app.json` keeps for the lock screen, nil when it keeps none.
    public static func launchTheme(directory: URL) -> AppSettings.Theme? {
        let url = directory.appendingPathComponent(notesFile)
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(LaunchNotes.self, from: $0) }?.theme
    }

    /// Leaves `app.json` holding the theme and nothing else; a file that holds more is
    /// overwritten with zeros before it goes (docs/key-storage.md).
    static func keepLaunchNotes(_ directory: URL, theme: AppSettings.Theme?) throws {
        let url = directory.appendingPathComponent(notesFile)
        let wanted = try theme.map { try JSONEncoder().encode(LaunchNotes(theme: $0)) }
        let present = FileManager.default.contents(atPath: url.path)
        guard present != wanted else {
            return
        }
        // A file that does not open for writing (read only, a link) is only removed: the
        // store must open whatever app.json is.
        if present != nil, (try? ClientStore.overwriteAndRemove(url)) == nil {
            try FileManager.default.removeItem(at: url)
        }
        if let wanted {
            try wanted.write(to: url, options: .atomic)
            chmod(url.path, ClientStore.fileMode)
        }
    }

    /// Moves the pictures that a version before kept in `Pasted` into the store, with the
    /// sent files that name them, then overwrites and removes the folder; an entry that is
    /// no plain file (a link, a folder) is only removed.
    static func takeInPasted(_ store: ClientStore, _ directory: URL) throws {
        let folder = directory.appendingPathComponent(pastedFolder, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return
        }
        let resolved = folder.resolvingSymlinksInPath().path
        for file in try store.files() where !file.incoming && !file.kept {
            guard let path = file.savedAs,
                URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path == resolved,
                let bytes = FileManager.default.contents(atPath: path)
            else { continue }
            try store.transaction { try store.keepFile(file.position, bytes) }
        }
        for name in names {
            let url = folder.appendingPathComponent(name)
            if (try? ClientStore.overwriteAndRemove(url)) == nil {
                try? FileManager.default.removeItem(at: url)
            }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    public var relay: String {
        notes.relay ?? launchRelay
    }

    /// Connects when an identity exists and publishes the first state.
    public func start() async {
        if userID != nil {
            connect()
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollSeconds * 1_000_000_000))
                await self?.pollWaiting()
            }
        }
        expirer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.expirySeconds * 1_000_000_000))
                await self?.expire()
            }
        }
        await publish()
    }

    /// Stops the transport, closes the store, removes the copies of `openCopy` and ends
    /// `changes`.
    public func close() async {
        closed = true
        await disconnect()
        poller?.cancel()
        expirer?.cancel()
        // Once more, should the last write of a change have failed.
        try? notes.save(notesStore)
        notesStore.close()
        opened = [:]
        Self.clearOpened(directory: directory)
        sink.finish()
    }

    /// Makes the identity of an empty store, connects and returns the user id.
    public func createIdentity() async throws -> String {
        if let userID {
            return userID
        }
        let made = try Identity.encodeUserID(Client(store: ClientStore(directory: directory)).identityKey)
        userID = made
        connect()
        await publish()
        return made
    }

    /// The current state; message times and contacts seen for the first time are saved.
    @discardableResult
    public func state() async throws -> MessengerState {
        let rows = try await read()
        var updated = notes
        let state = try Self.build(rows, notes: &updated, relay: relay, link: link, now: Date(), progress: progress)
        if updated != notes {
            notes = updated
            try notes.save(notesStore)
        }
        if state != last {
            last = state
            sink.yield(state)
        }
        dropOpened(notIn: state)
        return state
    }

    /// The state of the store in `directory` without a connection and without a write to
    /// its notes.
    public static func peek(directory: URL, relay: String) throws -> MessengerState {
        let store = try ClientStore(directory: directory)
        var notes = try Notes.load(store) ?? Notes.legacy(directory) ?? Notes()
        return try build(Rows(store: store), notes: &notes, relay: notes.relay ?? relay, link: .idle, now: Date(), progress: [:])
    }

    // MARK: Actions

    /// Keeps the text in the store at once, then commits it to the outbox and sends it. A
    /// contact without a session waits for a connection, which fetches its bundle; until then
    /// the text waits among the pending texts, also across a restart.
    /// `replyTo` is the position of the message of the chat that the text answers.
    public func send(_ text: String, to userID: String, replyTo: Int64? = nil) async throws {
        _ = try Envelope.encodeText(text)
        let contact = try Identity.decodeUserID(userID)
        let madeAt = Self.milliseconds(Date())
        try await withClient { client in
            try client.store.transaction {
                _ = try client.store.addPending(contact, text: text, madeAt: madeAt, replyTo: replyTo)
            }
        }
        if notes.drafts.removeValue(forKey: userID) != nil {
            try notes.save(notesStore)
        }
        await publish()
        flush()
    }

    /// Sends a file once the transport is logged in: its blob is made and kept in the store,
    /// and the upload goes on by itself, also after a reconnect or a restart. The file shows
    /// as a message whose text is the caption.
    ///
    /// - Throws: `NotConnectedError` without a transport; `FileError` or
    ///   `SessionError.notAContact` from the checks of section 33.1; an error of the file
    ///   system when the file cannot be read.
    /// `mediaType`, `width`, `height` and `thumbnail` are those of `Transport.sendFile`.
    /// Returns the position of the message.
    @discardableResult
    public func sendFile(
        _ file: URL, caption: String = "", to userID: String, mediaType: String? = nil,
        width: Int = 0, height: Int = 0, thumbnail: Data = Data(), replyTo: Int64? = nil
    ) async throws -> Int64 {
        try await sendFile(
            .path(file), caption: caption, to: userID, mediaType: mediaType, width: width, height: height,
            thumbnail: thumbnail, replyTo: replyTo
        )
    }

    /// `sendFile` for bytes that are in no file, such as a pasted picture: the store keeps
    /// them with the message.
    @discardableResult
    public func sendFile(
        named name: String, contents: Data, caption: String = "", to userID: String, mediaType: String? = nil,
        width: Int = 0, height: Int = 0, thumbnail: Data = Data(), replyTo: Int64? = nil
    ) async throws -> Int64 {
        try await sendFile(
            .contents(name, contents), caption: caption, to: userID, mediaType: mediaType, width: width, height: height,
            thumbnail: thumbnail, replyTo: replyTo
        )
    }

    private enum Source: Sendable {
        case path(URL)
        case contents(String, Data)
    }

    private func sendFile(
        _ source: Source, caption: String, to userID: String, mediaType: String?, width: Int, height: Int,
        thumbnail: Data, replyTo: Int64?
    ) async throws -> Int64 {
        guard let transport else {
            throw NotConnectedError()
        }
        let contact = try Identity.decodeUserID(userID)
        let replyTo = try await transport.withClient { client in
            try replyTo.flatMap { try client.store.message($0)?.contact == contact ? $0 : nil }
        }
        func start(_ replyTo: Int64?) async throws -> Data {
            switch source {
            case .path(let file):
                try await transport.sendFile(
                    contact, file: file, caption: caption, mediaType: mediaType, width: width, height: height,
                    thumbnail: thumbnail, replyTo: replyTo
                )
            case .contents(let name, let contents):
                try await transport.sendFile(
                    contact, named: name, contents: contents, caption: caption, mediaType: mediaType, width: width,
                    height: height, thumbnail: thumbnail, replyTo: replyTo
                )
            }
        }
        let blobID: Data
        do {
            blobID = try await start(replyTo)
        } catch ChangeError.noSuchMessage where replyTo != nil {
            // The quoted message went while the login was awaited: the file goes alone.
            blobID = try await start(nil)
        }
        let position = try await transport.withClient { client -> Int64 in
            guard let sent = try client.store.files().last(where: { !$0.incoming && $0.attachment.blobID == blobID }) else {
                return 0
            }
            return try client.store.messages(contact).last { $0.messageID == sent.messageID }?.position ?? 0
        }
        await publish()
        return position
    }

    /// Sends the file of a message that was not sent again, as a new message from the file it
    /// was read from or the bytes the store keeps, and deletes the old message (section
    /// 33.5). Returns the new position.
    ///
    /// - Throws: `FileGoneError` when the file is not where it was read from; what `sendFile`
    ///   throws.
    @discardableResult
    public func resendFile(_ position: Int64) async throws -> Int64 {
        guard let file = try await withClient({ try $0.store.files(ofMessageAt: position).first }), !file.incoming,
            file.state == .notSent
        else {
            return position
        }
        let sent = file.attachment
        let source: Source
        if file.kept, let contents = try await contents(position) {
            source = .contents(sent.fileName, contents)
        } else if let path = file.savedAs, FileManager.default.fileExists(atPath: path) {
            source = .path(URL(fileURLWithPath: path))
        } else {
            throw FileGoneError()
        }
        let made = try await sendFile(
            source, caption: sent.caption, to: Identity.encodeUserID(file.contact), mediaType: sent.mediaType,
            width: Int(sent.width), height: Int(sent.height), thumbnail: sent.thumbnail, replyTo: nil
        )
        try await deleteMessage(position)
        return made
    }

    /// Downloads the received file of a message: offered, paused or not received; after the
    /// next login when there is no connection.
    public func download(_ position: Int64) async throws {
        guard let transport else {
            throw NotConnectedError()
        }
        if let file = try await transport.withClient({ try $0.store.files(ofMessageAt: position).first }) {
            try await transport.download(file.position)
        }
        await publish()
    }

    /// Pauses the download of the file of a message; the bytes it holds stay.
    public func pauseDownload(_ position: Int64) async throws {
        guard let transport else {
            throw NotConnectedError()
        }
        if let file = try await transport.withClient({ try $0.store.files(ofMessageAt: position).first }) {
            try await transport.pauseDownload(file.position)
        }
        await publish()
    }

    /// Saves the own profile and sends it to every contact with a session, at once when
    /// logged in, else after the next login (protocol section 36.2). An empty name and no
    /// avatar clear it. `thumbnail`, `width` and `height` go with the avatar.
    ///
    /// - Throws: `EnvelopeError.badProfileName`, `.avatarTooLarge` or `.notAnImage`.
    public func setProfile(name: String, avatar: Data?, thumbnail: Data = Data(), width: Int = 0, height: Int = 0) async throws {
        let profile = OwnProfile(name: name, avatar: avatar, thumbnail: thumbnail, width: width, height: height)
        if let transport {
            try await transport.setProfile(profile)
        } else {
            try await withClient { try $0.setProfile(profile) }
        }
        await publish()
    }

    public func addContact(name rawName: String, userID rawID: String) async throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = Self.normalizedID(rawID)
        let saved = try await savedNames()
        if let problem = Self.nameProblem(name, saved: saved) ?? Self.idProblem(id, own: userID, saved: saved) {
            throw problem
        }
        try await withClient { try $0.addContact(id, name: name) }
        await publish()
    }

    public func rename(_ userID: String, to rawName: String) async throws {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        var saved = try await savedNames()
        saved[userID] = nil
        if let problem = Self.nameProblem(name, saved: saved) {
            throw problem
        }
        let contact = try Identity.decodeUserID(userID)
        try await withClient { client in try client.store.transaction { try client.store.renameContact(contact, name: name) } }
        await publish()
    }

    /// Edits an own message of the chat: its text, or the caption of its file (protocol
    /// section 39.3); waits for a connection when the contact has no session.
    ///
    /// - Throws: `NotConnectedError` without a transport; `ChangeError`;
    ///   `EnvelopeError.textTooLong`.
    public func edit(_ position: Int64, text: String, in userID: String) async throws {
        guard let transport else {
            throw NotConnectedError()
        }
        let contact = try Identity.decodeUserID(userID)
        try await noting(contact) { try await transport.edit(contact, position, text) }
        await publish()
    }

    /// Deletes an own message here and asks the contact's app to delete it too (protocol
    /// section 39.4).
    public func deleteForBoth(_ position: Int64, in userID: String) async throws {
        guard let transport else {
            throw NotConnectedError()
        }
        let contact = try Identity.decodeUserID(userID)
        try await noting(contact) { try await transport.delete(contact, position) }
        notes.times[String(position)] = nil
        try notes.save(notesStore)
        await publish()
    }

    /// Sets the disappearing timer of the chat, 0 for off, for the messages sent from now on
    /// by either side (protocol section 39.6).
    public func setTimer(_ seconds: Int, in userID: String) async throws {
        guard let transport else {
            throw NotConnectedError()
        }
        let contact = try Identity.decodeUserID(userID)
        try await noting(contact) { try await transport.setTimer(contact, seconds: seconds) }
        notes.timerChanges[userID, default: []].append(TimerNote(at: Self.milliseconds(Date()), seconds: seconds, own: true))
        try notes.save(notesStore)
        await publish()
    }

    /// Turns the read receipts that contacts get on or off (protocol section 39.5).
    public func setReadReceipts(_ on: Bool) async throws {
        if let transport {
            try await transport.setReadReceipts(on)
        } else {
            try await withClient { try $0.setReadReceipts(on) }
        }
        await publish()
    }

    /// The user has seen these messages of the chat on screen: their timers start and their
    /// read receipts are owed (protocol sections 39.5 and 39.6).
    public func markSeen(_ positions: [Int64], in userID: String) async throws {
        let contact = try Identity.decodeUserID(userID)
        if let transport {
            try await transport.markRead(contact, positions)
        } else {
            try await withClient { _ = try $0.markRead(contact, positions) }
        }
        await publish()
    }

    /// Counts every message of the chat as read.
    public func markRead(_ userID: String) async throws {
        let contact = try Identity.decodeUserID(userID)
        let newest = try await withClient { try $0.store.messages(contact).last?.position } ?? 0
        guard notes.read[userID] != newest else {
            return
        }
        notes.read[userID] = newest
        try notes.save(notesStore)
        await publish()
    }

    /// Starts a new session with a fresh bundle; waits for a connection.
    public func resetSession(_ userID: String) async throws {
        guard let transport else {
            throw NotConnectedError()
        }
        let contact = try Identity.decodeUserID(userID)
        _ = try await noting(contact) { try await transport.resetSession(contact) }
        await publish()
    }

    /// Sets or clears the verified mark of the contact (protocol section 45). It stays in
    /// the store of this Mac; the contact does not learn it.
    public func setVerified(_ on: Bool, for userID: String) async throws {
        let contact = try Identity.decodeUserID(userID)
        try await withClient { try $0.setVerified(contact, on) }
        await publish()
    }

    /// Takes the warning about a refused key off the chat, until another key is refused.
    public func dismissRefusedKey(_ userID: String) async throws {
        notes.refusedKeys[userID] = nil
        try notes.save(notesStore)
        await publish()
    }

    /// Deletes the contact, its sessions and its messages.
    public func deleteContact(_ userID: String) async throws {
        let contact = try Identity.decodeUserID(userID)
        let positions = try await withClient { client in
            try client.store.transaction {
                let positions = try client.store.messages(contact).map(\.position)
                try client.deleteMessages(contact)
                try client.store.removeContact(contact)
                return positions
            }
        }
        notes.read[userID] = nil
        notes.added[userID] = nil
        notes.forget(userID)
        positions.forEach { notes.times[String($0)] = nil }
        try notes.save(notesStore)
        await publish()
    }

    /// Deletes a logged message, or a pending text when `position` is negative.
    public func deleteMessage(_ position: Int64) async throws {
        try await withClient { client in
            try client.store.transaction {
                if position < 0 {
                    try client.store.removePending(-position)
                } else {
                    try client.deleteMessage(position)
                }
            }
        }
        notes.times[String(position)] = nil
        try notes.save(notesStore)
        await publish()
    }

    /// Saves the relay address and connects to it.
    ///
    /// - Throws: `URLRefusedError` when the address is not one the transport dials.
    public func setRelay(_ address: String) async throws {
        _ = try Transport.serverName(of: address, insecure: false)
        notes.relay = address
        try notes.save(notesStore)
        await reconnect()
    }

    /// Keeps the unsent text of a chat; an empty or blank text removes the draft.
    public func setDraft(_ text: String, for userID: String) throws {
        let draft = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard notes.drafts[userID] != draft else {
            return
        }
        notes.drafts[userID] = draft
        try notes.save(notesStore)
    }

    /// Pins a chat on top of the pinned ones, or unpins it.
    public func setPinned(_ userID: String, _ pinned: Bool) async throws {
        notes.pin(userID, pinned)
        try notes.save(notesStore)
        await publish()
    }

    public func setMuted(_ userID: String, _ muted: Bool) async throws {
        notes.mute(userID, muted)
        try notes.save(notesStore)
        await publish()
    }

    /// Moves a chat to the archive, which unpins it, or back to the list.
    public func setArchived(_ userID: String, _ archived: Bool) async throws {
        notes.archive(userID, archived)
        try notes.save(notesStore)
        await publish()
    }

    /// Saves the settings, and the theme into `app.json` for the lock screen; where received
    /// files go and their auto-download sizes hold for the files that arrive from now on.
    public func saveSettings(_ settings: AppSettings) async throws {
        notes.settings = settings
        try notes.save(notesStore)
        try Self.keepLaunchNotes(directory, theme: settings.theme)
        await transport?.setDownloads(downloads, autoDownload: Self.autoDownload(settings))
    }

    /// Received files stay in the store unless the settings ask to save them into their
    /// folder, or the one given at launch; nowhere without a folder at launch.
    private var downloads: Transport.Downloads {
        guard let receivedFiles else {
            return .off
        }
        guard let settings = notes.settings, settings.saveReceivedFiles else {
            return .store
        }
        return .folder(settings.downloadFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? receivedFiles)
    }

    /// The bytes of the file of a message that the store keeps; nil when it keeps none.
    public func contents(_ position: Int64) async throws -> Data? {
        try await withStore { store in
            try store.files(ofMessageAt: position).first.flatMap { $0.kept ? try store.keptFile($0.position) : nil }
        }
    }

    /// Writes the file of a message that the store keeps into `descriptor` a piece at a time,
    /// so a large one is never whole in memory; false when the store keeps none.
    ///
    /// - Throws: `StoreError.system` when a write to the descriptor fails.
    public func writeContents(_ position: Int64, to descriptor: Int32) async throws -> Bool {
        try await withStore { store in
            guard let file = try store.files(ofMessageAt: position).first, file.kept else {
                return false
            }
            return try store.readKeptFile(file.position) { piece in
                guard ReceivedFiles.write(descriptor, piece) else {
                    throw StoreError.system(path: "the file being saved", errno: errno)
                }
            }
        }
    }

    /// Writes the file the store keeps for a message into `openedFolder` of the data folder
    /// (0700, its file 0600, excluded from backups, marked as downloaded), a piece at a time,
    /// for its app to open; nil when the store keeps none or the messenger closed meanwhile.
    /// The copy is overwritten and removed as soon as a state lacks its message (a delete, an
    /// expiry, a deleted contact), and with the others on `close` and by
    /// `clearOpened` (docs/key-storage.md).
    public func openCopy(_ position: Int64, named name: String) async throws -> URL? {
        let folder = directory.appendingPathComponent(Self.openedFolder, isDirectory: true)
        let (url, descriptor) = try ReceivedFiles.create(named: name, into: folder)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var marked = folder
        try? marked.setResourceValues(excluded)
        guard (try? await writeContents(position, to: descriptor)) == true, !closed else {
            Darwin.close(descriptor)
            Self.removeCopy(url)
            return nil
        }
        try ReceivedFiles.finish(url, descriptor)
        opened[position, default: []].append(url)
        // The message may have gone while its file was written.
        if let last { dropOpened(notIn: last) }
        return opened[position] == nil ? nil : url
    }

    /// Overwrites and removes every file in `openedFolder` of `directory`, and the folder.
    public static func clearOpened(directory: URL) {
        let folder = directory.appendingPathComponent(openedFolder, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        names.forEach { removeCopy(folder.appendingPathComponent($0)) }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Overwrites and removes the copies of the messages that `state` lacks.
    private func dropOpened(notIn state: MessengerState) {
        guard !opened.isEmpty else { return }
        let present = Set(state.chats.flatMap { $0.messages.map(\.id) })
        for (position, copies) in opened where !present.contains(position) {
            copies.forEach(Self.removeCopy)
            opened[position] = nil
        }
    }

    /// A copy that does not open for writing is only removed.
    private static func removeCopy(_ copy: URL) {
        if (try? ClientStore.overwriteAndRemove(copy)) == nil { try? FileManager.default.removeItem(at: copy) }
    }

    /// A photo or a file downloads by itself up to the size of its kind; 0 is off.
    static func autoDownload(_ settings: AppSettings) -> Transport.AutoDownload {
        let (photos, files) = (settings.autoDownloadPhotos, settings.autoDownloadFiles)
        return { attachment in
            let megabytes = ChatFile.isPhoto(attachment.mediaType) ? photos : files
            return megabytes > 0 && Int(attachment.size) <= megabytes * 1_000_000
        }
    }

    /// Deletes the files of a store in `directory` (the database, its journal, its wrapped
    /// key and `app.json`), then the folder itself when nothing else is left in it, and drops
    /// the key: pages of the old store left on the disk cannot be decrypted after it. Call it
    /// only after `close`.
    public static func erase(directory: URL) throws {
        StoreKeys.lock(directory)
        let store = directory.appendingPathComponent(ClientStore.fileName).path
        unlink(store + ClientStore.encryptingSuffix)
        if FileManager.default.fileExists(atPath: store + ClientStore.plainSuffix) {
            try ClientStore.overwriteAndRemove(URL(fileURLWithPath: store + ClientStore.plainSuffix))
        }
        let manager = FileManager.default
        let names = [ClientStore.fileName, ClientStore.fileName + "-journal", StoreKeys.fileName, notesFile]
        for name in names {
            let url = directory.appendingPathComponent(name)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }
        if (try? manager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
            try manager.removeItem(at: directory)
        }
    }

    /// A new transport to the same relay, after the old one stopped.
    public func reconnect() async {
        await disconnect()
        if userID != nil {
            connect()
        }
        await publish()
    }

    // MARK: Checks

    public static func normalizedID(_ raw: String) -> String {
        raw.filter { !$0.isWhitespace }.lowercased()
    }

    /// The problem of a new contact's id, already normalized; `saved` maps user ids to names.
    public static func idProblem(_ id: String, own: String?, saved: [String: String]) -> ContactError? {
        if id.count != 64 {
            return .wrongLength
        }
        if !id.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) {
            return .notHex
        }
        if id == own {
            return .ownID
        }
        if let name = saved[id] {
            return .alreadySaved(name)
        }
        return nil
    }

    public static func nameProblem(_ name: String, saved: [String: String]) -> ContactError? {
        if name.isEmpty {
            return .emptyName
        }
        if saved.values.contains(name) {
            return .nameTaken(name)
        }
        return nil
    }

    /// A line for a person about an error of an action.
    public static func describe(_ error: Error) -> String {
        switch error {
        case let error as ContactError: error.message
        case EnvelopeError.textTooLong: "The message is too long."
        case CryptoError.identityKeyMismatch:
            "The identity of the contact signed another key, and it was refused (IDENTITY_KEY_MISMATCH)."
        case let error as RefusedError: "The relay refused the request (\(error.result))."
        case let error as URLRefusedError: "The relay address is refused: \(error.message)."
        case is NotConnectedError: "There is no connection to a relay."
        case FileError.filesUnsupported: "The relay does not take files."
        case FileError.fileTooLarge: "The file is too large."
        case ChangeError.noSuchMessage: "The message is gone."
        case ChangeError.notOwnMessage: "Only your own messages can be changed."
        case ChangeError.tooManyEdits: "The message was edited \(Client.maxEdits) times already."
        case ChangeError.editTooLate: "A message can be edited within a day of sending."
        case EnvelopeError.badTimer: "The timer is too long."
        case EnvelopeError.badProfileName: "The name is too long or holds a control character."
        case EnvelopeError.avatarTooLarge: "The picture is too large."
        case EnvelopeError.notAnImage: "Choose a picture."
        case is FileGoneError: "The file to send again is not where it was read from."
        case is CancellationError: "The request was cancelled."
        default: "\(error)"
        }
    }

    /// The failure of a message that the relay refused with `result`.
    static func refusal(_ result: String) -> String {
        "The relay refused it (\(result))."
    }

    /// The failure of a file that is not sent.
    static func notSent(_ result: String?) -> String {
        "The file was not sent (\(result ?? "cancelled"))."
    }

    static func explain(_ reason: String) -> String {
        if reason.hasSuffix(" 4001") {
            return "This id is in use on another device: the relay closed this connection."
        }
        return "The connection stopped: \(reason)."
    }

    // MARK: Inside

    private func connect() {
        do {
            client = nil
            let made = try Transport(
                client: Client(store: ClientStore(directory: directory)), url: relay, downloads: downloads,
                autoDownload: Self.autoDownload(notes.settings ?? AppSettings())
            )
            transport = made
            link = .connecting
            runner = Task { [weak self] in
                do {
                    try await made.run()
                } catch is CancellationError {
                } catch {
                    await self?.stopped("The connection stopped: \(error).")
                }
            }
            listener = Task { [weak self] in
                for await event in made.events {
                    await self?.handle(event)
                }
            }
            flush()
        } catch let refused as URLRefusedError {
            link = .stopped("The relay address is refused: \(refused.message).")
            client = try? Client(store: ClientStore(directory: directory))
        } catch {
            link = .stopped("The store cannot be opened: \(error).")
        }
    }

    private func disconnect() async {
        if let transport {
            await transport.stop()
            runner?.cancel()
            await runner?.value
            await listener?.value
        }
        flusher?.cancel()
        await flusher?.value
        flusher = nil
        // Closed here, not when the last task lets go of the transport.
        await transport?.closeStore()
        transport = nil
        client?.store.close()
        client = nil
        link = .idle
    }

    func handle(_ event: TransportEvent) async {
        switch event {
        case .connected: link = .connected
        case .retrying: link = .connecting
        case .stopped(let reason): link = .stopped(Self.explain(reason))
        case .incoming(let sender, let received):
            // A profile, a change of part 5, or a member of a later part that the client does
            // not know, is no message (protocol sections 20.3, 36.3 and 39.7): the chat stays
            // where it is.
            guard let userID = try? Identity.encodeUserID(sender) else { break }
            if received.result == CryptoError.identityKeyMismatch.result {
                noteRefusedKey(sender)
            }
            var changed = received.isANewMessage && notes.arrived(userID)
            if let seconds = received.timer {
                notes.timerChanges[userID, default: []].append(TimerNote(at: Self.milliseconds(Date()), seconds: seconds, own: false))
                changed = true
            }
            if received.deleted, let position = received.position {
                notes.times[String(position)] = nil
                changed = true
            }
            if changed {
                try? notes.save(notesStore)
            }
        case .expired(let positions):
            positions.forEach { notes.times[String($0)] = nil }
            try? notes.save(notesStore)
        case .written, .sent: break
        case .refused, .transferFailed: break
        case .file(let update) where update.avatar:
            if update.state == .sending || update.state == .receiving {
                return
            }
        case .file(let update):
            if update.result == CryptoError.identityKeyMismatch.result {
                noteRefusedKey(update.contact)
            }
            let moving = update.state == .sending || update.state == .receiving
            let made = Progress(done: update.done, total: update.total)
            let before = progress[update.messageID]
            progress[update.messageID] = moving ? made : nil
            if moving, let before, before.percent == made.percent {
                return
            }
        }
        await publish()
    }

    private func stopped(_ text: String) async {
        link = .stopped(text)
        await publish()
    }

    /// A key that the identity of the contact signed in place of the pinned one was refused
    /// (IDENTITY_KEY_MISMATCH): the chat warns about it until the user takes the warning off.
    private func noteRefusedKey(_ contact: Data) {
        guard let userID = try? Identity.encodeUserID(contact) else { return }
        notes.refusedKeys[userID] = Self.milliseconds(Date())
        try? notes.save(notesStore)
    }

    /// Runs an action that may start a session with the contact; a refused key is noted
    /// before the error goes on.
    private func noting<T: Sendable>(_ contact: Data, _ action: () async throws -> T) async throws -> T {
        do {
            return try await action()
        } catch CryptoError.identityKeyMismatch {
            noteRefusedKey(contact)
            await publish()
            throw CryptoError.identityKeyMismatch
        }
    }

    /// The expired messages go, through the transport when there is one, which also ends
    /// their downloads and deletes their blobs at the relay, else through the client.
    private func expire() async {
        var positions: [Int64] = []
        if let transport {
            positions = (try? await transport.expireNow()) ?? []
        } else if let client {
            positions = (try? client.expireMessages()) ?? []
        }
        guard !positions.isEmpty else {
            return
        }
        positions.forEach { notes.times[String($0)] = nil }
        try? notes.save(notesStore)
        await publish()
    }

    /// The relay answers a Send with Stored, which the transport reports with no event.
    private func pollWaiting() async {
        if last?.chats.contains(where: { $0.messages.contains(where: \.waiting) }) == true {
            await publish()
        }
    }

    private func flush() {
        guard let transport else {
            return
        }
        if flusher != nil {
            flushAgain = true
            return
        }
        flusher = Task { [weak self] in await self?.drain(transport) }
    }

    /// Commits the pending texts that have not failed, oldest first; the time a text was typed
    /// becomes the time of its logged message.
    private func drain(_ transport: Transport) async {
        while !Task.isCancelled {
            guard let rows = try? await transport.withClient({ try $0.store.pending() }) else {
                break
            }
            guard let row = rows.first(where: { $0.failure == nil }) else {
                if flushAgain {
                    flushAgain = false
                    continue
                }
                break
            }
            do {
                // A text that waited for a session answers its message only while that one is there.
                let replyTo = try await transport.withClient { client in
                    try row.replyTo.flatMap { try client.store.message($0)?.contact == row.contact ? $0 : nil }
                }
                let messageID: Data
                do {
                    messageID = try await transport.sendText(row.contact, row.text, pending: row.position, replyTo: replyTo)
                } catch ChangeError.noSuchMessage where replyTo != nil {
                    // The quoted message went while the bundle was fetched: the text goes alone.
                    messageID = try await transport.sendText(row.contact, row.text, pending: row.position)
                }
                let logged = try await transport.withClient {
                    try $0.store.messages(row.contact).last { $0.messageID == messageID }
                }
                if let logged {
                    notes.times[String(logged.position)] = row.madeAt
                    try notes.save(notesStore)
                }
            } catch is CancellationError {
                break
            } catch {
                if error as? CryptoError == .identityKeyMismatch {
                    noteRefusedKey(row.contact)
                }
                let reason = (error as? RefusedError).map { Self.refusal($0.result) } ?? Self.describe(error)
                try? await transport.withClient { client in
                    try client.store.transaction { try client.store.failPending(row.position, reason: reason) }
                }
            }
            await publish()
        }
        flusher = nil
    }

    private func publish() async {
        _ = try? await state()
    }

    private func savedNames() async throws -> [String: String] {
        let contacts = try await withClient { try $0.store.contacts() }
        var saved: [String: String] = [:]
        for contact in contacts {
            saved[try Identity.encodeUserID(contact.identityKey)] = contact.name ?? ""
        }
        return saved
    }

    @discardableResult
    private func withClient<T: Sendable>(_ body: @escaping @Sendable (Client) throws -> T) async throws -> T {
        if let transport {
            return try await transport.withClient(body)
        }
        if let client {
            return try body(client)
        }
        throw NotConnectedError()
    }

    private func read() async throws -> Rows {
        try await withStore { try Rows(store: $0) }
    }

    /// Runs `body` on the store of the transport or of the client, else on the notes' own.
    private func withStore<T: Sendable>(_ body: @escaping @Sendable (ClientStore) throws -> T) async throws -> T {
        if transport != nil || client != nil {
            return try await withClient { try body($0.store) }
        }
        return try body(notesStore)
    }

    private static func build(
        _ rows: Rows, notes: inout Notes, relay: String, link: LinkState, now: Date, progress: [Data: Progress]
    ) throws -> MessengerState {
        let milliseconds = Self.milliseconds(now)
        let chats = try rows.contacts.map { contact in
            let userID = try Identity.encodeUserID(contact.identityKey)
            let added = notes.added[userID] ?? milliseconds
            notes.added[userID] = added
            let rowsOfChat = rows.messages[contact.identityKey, default: []]
            // The latest message of each author and id, which a quote names (protocol 39.1).
            var byID: [FileKey: StoredMessage] = [:]
            for row in rowsOfChat {
                byID[FileKey(contact: contact.identityKey, outgoing: !row.incoming, messageID: row.messageID)] = row
            }
            func chatFile(_ row: StoredMessage) -> ChatFile? {
                let key = FileKey(contact: contact.identityKey, outgoing: !row.incoming, messageID: row.messageID)
                return rows.files[key].map { file in
                    let moved = progress[row.messageID]
                    return ChatFile(
                        name: file.attachment.fileName,
                        size: Int(file.attachment.size),
                        mediaType: file.attachment.mediaType,
                        state: file.state,
                        done: moved?.done ?? file.held,
                        total: moved?.total ?? (file.state == .receiving ? Blob.blobLength(Int(file.attachment.size)) : 0),
                        savedAs: file.savedAs,
                        result: file.result,
                        width: Int(file.attachment.width),
                        height: Int(file.attachment.height),
                        thumbnail: file.attachment.thumbnail,
                        kept: file.kept
                    )
                }
            }
            let logged = rowsOfChat.map { row in
                let time = notes.times[String(row.position)] ?? milliseconds
                notes.times[String(row.position)] = time
                let refused = rows.refusals[row.messageID]
                let outgoing = row.direction == .outgoing
                let file = chatFile(row)
                var message = ChatMessage(
                    id: row.position,
                    outgoing: outgoing,
                    text: row.text,
                    date: date(time),
                    waiting: outgoing && refused == nil
                        && (rows.waiting.contains(row.messageID) || file?.state == .sending),
                    failure: refused.map(refusal) ?? file.flatMap { $0.state == .notSent ? notSent($0.result) : nil },
                    file: file
                )
                message.quote = row.quote.map { quote in
                    let key = FileKey(contact: contact.identityKey, outgoing: !quote.incoming, messageID: quote.messageID)
                    guard let copy = byID[key] else {
                        return ChatQuote(position: nil, outgoing: !quote.incoming, text: quote.text)
                    }
                    return ChatQuote(position: copy.position, outgoing: !quote.incoming, text: copy.text, file: chatFile(copy))
                }
                message.edited = row.edits > 0
                message.receipt = row.receipt
                message.expiresAfter = row.expiresAfter
                message.expiresAt = row.expiresAt.map { Date(timeIntervalSince1970: Double($0)) }
                if outgoing, let written = row.writtenAt, row.edits < Client.maxEdits, message.failure == nil {
                    message.editableUntil = Date(timeIntervalSince1970: Double(written + Client.editSeconds))
                }
                return message
            }
            let pending = rows.pending[contact.identityKey, default: []].map {
                ChatMessage(
                    id: -$0.position, outgoing: true, text: $0.text, date: date($0.madeAt),
                    waiting: $0.failure == nil, failure: $0.failure
                )
            }
            let messages = (logged + pending).enumerated()
                .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
                .map(\.element)
            let read = notes.read[userID] ?? 0
            return Chat(
                userID: userID,
                name: contact.name ?? String(userID.prefix(8)),
                added: date(added),
                unread: messages.filter { !$0.outgoing && $0.id > read }.count,
                messages: messages,
                pinned: notes.pins.firstIndex(of: userID),
                muted: notes.muted.contains(userID),
                archived: notes.archived.contains(userID),
                draft: notes.drafts[userID],
                profile: rows.profiles[contact.identityKey].map { sent in
                    UserProfile(
                        name: sent.name,
                        avatar: sent.avatarFile.flatMap { rows.avatarFiles[$0] }.map { file in
                            ProfilePhoto(
                                key: file.attachment.blobID.map { String(format: "%02x", $0) }.joined(),
                                picture: sent.avatar, thumbnail: file.attachment.thumbnail, state: file.state
                            )
                        }
                    )
                },
                timer: rows.timers[contact.identityKey] ?? 0,
                timerChanges: notes.timerChanges[userID, default: []].map {
                    TimerChange(date: date($0.at), seconds: $0.seconds, own: $0.own)
                },
                verified: rows.verified.contains(contact.identityKey),
                refusedKey: notes.refusedKeys[userID].map(date)
            )
        }
        let own = rows.ownProfile
        return MessengerState(
            userID: try rows.identityKey.map(Identity.encodeUserID),
            chats: chats,
            link: link,
            relay: relay,
            profile: UserProfile(
                name: own.name,
                avatar: own.avatar.map {
                    ProfilePhoto(
                        key: SHA256.hash(data: $0).prefix(8).map { String(format: "%02x", $0) }.joined(),
                        picture: $0, thumbnail: own.thumbnail, state: .received
                    )
                }
            ),
            readReceipts: rows.readReceipts
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}

struct Progress: Equatable, Sendable {
    var done: Int
    var total: Int

    var percent: Int {
        100 * done / max(total, 1)
    }
}

/// A message or its file by author and id.
struct FileKey: Hashable, Sendable {
    var contact: Data
    var outgoing: Bool
    var messageID: Data
}

/// One read of the store, made where the session layer lives.
struct Rows: Sendable {
    var identityKey: Data?
    var contacts: [Contact]
    var messages: [Data: [StoredMessage]] = [:]
    var pending: [Data: [PendingText]] = [:]
    var waiting: Set<Data>
    var refusals: [Data: String]
    var files: [FileKey: FileRow] = [:]
    var ownProfile: OwnProfile
    var profiles: [Data: ContactProfile] = [:]
    /// The files of the avatars of the profiles, by position; no file of the message log.
    var avatarFiles: [Int64: FileRow] = [:]
    var timers: [Data: Int] = [:]
    var readReceipts: Bool
    var verified: Set<Data>

    init(store: ClientStore) throws {
        identityKey = try store.identity().map { try Identity.deriveIdentityKey(seed: $0.seed) }
        contacts = try store.contacts()
        for contact in contacts {
            messages[contact.identityKey] = try store.messages(contact.identityKey)
            timers[contact.identityKey] = try store.timer(contact.identityKey)
        }
        readReceipts = try store.readReceipts()
        verified = try store.verifiedContacts()
        for row in try store.pending() {
            pending[row.contact, default: []].append(row)
        }
        waiting = Set(try store.outbox().map(\.messageID))
        refusals = try store.refusals()
        for file in try store.files() {
            if file.avatar {
                avatarFiles[file.position] = file
            } else {
                files[FileKey(contact: file.contact, outgoing: !file.incoming, messageID: file.messageID)] = file
            }
        }
        ownProfile = try store.ownProfile()
        for profile in try store.profiles() {
            profiles[profile.contact] = profile
        }
    }
}

/// The notes of the app, kept in the store: times are milliseconds since 1970, message keys
/// are log positions. A version before kept them in `app.json`.
struct Notes: Codable, Equatable {
    var relay: String?
    var read: [String: Int64] = [:]
    var added: [String: Int64] = [:]
    var times: [String: Int64] = [:]
    var settings: AppSettings?
    /// Unsent texts by user id.
    var drafts: [String: String] = [:]
    /// Pinned user ids, the top one first.
    var pins: [String] = []
    var muted: Set<String> = []
    var archived: Set<String> = []
    /// The changes of the disappearing timer of each chat, by user id, oldest first.
    var timerChanges: [String: [TimerNote]] = [:]
    /// When a key of each contact was last refused (IDENTITY_KEY_MISMATCH), by user id.
    var refusedKeys: [String: Int64] = [:]

    init(relay: String? = nil, read: [String: Int64] = [:]) {
        self.relay = relay
        self.read = read
    }

    /// A key that is missing or unreadable takes its default, so an older file loads.
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? keys.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        relay = value(.relay, nil)
        read = value(.read, [:])
        added = value(.added, [:])
        times = value(.times, [:])
        settings = value(.settings, nil)
        drafts = value(.drafts, [:])
        pins = value(.pins, [])
        muted = value(.muted, [])
        archived = value(.archived, [])
        timerChanges = value(.timerChanges, [:])
        refusedKeys = value(.refusedKeys, [:])
    }

    mutating func pin(_ userID: String, _ on: Bool) {
        pins.removeAll { $0 == userID }
        if on { pins.insert(userID, at: 0) }
    }

    mutating func mute(_ userID: String, _ on: Bool) {
        if on { muted.insert(userID) } else { muted.remove(userID) }
    }

    mutating func archive(_ userID: String, _ on: Bool) {
        if on {
            archived.insert(userID)
            pin(userID, false)
        } else {
            archived.remove(userID)
        }
    }

    /// A message arrived from `userID`: an archived chat that is not muted comes back to the
    /// list. Returns whether anything changed.
    mutating func arrived(_ userID: String) -> Bool {
        guard archived.contains(userID), !muted.contains(userID) else { return false }
        archived.remove(userID)
        return true
    }

    /// Drops what is kept for a deleted contact.
    mutating func forget(_ userID: String) {
        drafts[userID] = nil
        timerChanges[userID] = nil
        refusedKeys[userID] = nil
        pin(userID, false)
        muted.remove(userID)
        archived.remove(userID)
    }

    /// The notes the store keeps; nil when it keeps none yet or none that read as notes.
    static func load(_ store: ClientStore) throws -> Notes? {
        try store.appNotes().flatMap { try? JSONDecoder().decode(Notes.self, from: $0) }
    }

    func save(_ store: ClientStore) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        try store.transaction { try store.setAppNotes(data) }
    }

    /// The notes of `app.json` of a version that kept them there; nil without the file.
    static func legacy(_ directory: URL) -> Notes? {
        let url = directory.appendingPathComponent(Messenger.notesFile)
        return (try? Data(contentsOf: url)).map { (try? JSONDecoder().decode(Notes.self, from: $0)) ?? Notes() }
    }
}

/// What `app.json` keeps: what the app shows before the store is unlocked.
struct LaunchNotes: Codable, Equatable {
    var theme: AppSettings.Theme?
}

/// A change of the timer of a chat as the notes keep it: the time in milliseconds.
struct TimerNote: Codable, Equatable {
    var at: Int64
    var seconds: Int
    var own: Bool
}
