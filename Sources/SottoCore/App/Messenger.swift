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
    /// Where a received file was saved, or the file a sent one was read from.
    public let savedAs: String?
    /// Why the file failed: a result of section 33.6 or of a refusal.
    public let result: String?
    /// The image size in pixels, 0 when the sender gave none.
    public var width = 0
    public var height = 0
    /// The thumbnail as the sender gave it; `Thumbnail.decode` tells whether it may be shown.
    public var thumbnail = Data()

    public init(
        name: String, size: Int, mediaType: String, state: FileState, done: Int = 0, total: Int = 0,
        savedAs: String? = nil, result: String? = nil, width: Int = 0, height: Int = 0, thumbnail: Data = Data()
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
/// What the store does not hold is kept in `app.json` next to it: the relay address once it
/// is set here, the last read position of each chat, when each contact and message was
/// first seen, the drafts, pins, muted and archived chats, and the settings of the app.
public actor Messenger {
    public static let notesFile = "app.json"
    static let pollSeconds = 0.5

    public nonisolated let changes: AsyncStream<MessengerState>
    /// Whether the store held an identity when it was opened.
    public nonisolated let hadIdentity: Bool
    /// The settings in `app.json` when the store was opened; nil when none were saved yet.
    public nonisolated let launchSettings: AppSettings?
    private let sink: AsyncStream<MessengerState>.Continuation
    private let directory: URL
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
    /// Commits the pending texts through the transport, one at a time.
    private var flusher: Task<Void, Never>?
    private var flushAgain = false
    private var last: MessengerState?
    private let receivedFiles: URL?
    /// The progress of each file that is sending or receiving, by message id.
    private var progress: [Data: Progress] = [:]

    /// Opens the store in `directory`, creating it when it is missing; `relay` is used until
    /// an address is saved with `setRelay`. Received files are downloaded into the folder of
    /// the settings, or `receivedFiles` when they name none, each by itself when it is within
    /// the auto-download size of its kind and the others when `download` asks; a nil
    /// `receivedFiles` leaves every received file offered.
    public init(directory: URL, relay: String, receivedFiles: URL? = nil) throws {
        self.directory = directory
        self.receivedFiles = receivedFiles
        launchRelay = relay
        let store = try ClientStore(directory: directory)
        userID = try store.identity().map { try Identity.encodeUserID(Identity.deriveIdentityKey(seed: $0.seed)) }
        store.close()
        hadIdentity = userID != nil
        notes = Notes.load(directory)
        launchSettings = notes.settings
        (changes, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
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
        await publish()
    }

    /// Stops the transport and ends `changes`.
    public func close() async {
        await disconnect()
        poller?.cancel()
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
            try notes.save(directory)
        }
        if state != last {
            last = state
            sink.yield(state)
        }
        return state
    }

    /// The state of the store in `directory` without a connection and without a write to
    /// its notes.
    public static func peek(directory: URL, relay: String) throws -> MessengerState {
        let store = try ClientStore(directory: directory)
        var notes = Notes.load(directory)
        return try build(Rows(store: store), notes: &notes, relay: notes.relay ?? relay, link: .idle, now: Date(), progress: [:])
    }

    // MARK: Actions

    /// Keeps the text in the store at once, then commits it to the outbox and sends it. A
    /// contact without a session waits for a connection, which fetches its bundle; until then
    /// the text waits among the pending texts, also across a restart.
    public func send(_ text: String, to userID: String) async throws {
        _ = try Envelope.encodeText(text)
        let contact = try Identity.decodeUserID(userID)
        let madeAt = Self.milliseconds(Date())
        try await withClient { client in
            try client.store.transaction { _ = try client.store.addPending(contact, text: text, madeAt: madeAt) }
        }
        if notes.drafts.removeValue(forKey: userID) != nil {
            try notes.save(directory)
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
        width: Int = 0, height: Int = 0, thumbnail: Data = Data()
    ) async throws -> Int64 {
        guard let transport else {
            throw NotConnectedError()
        }
        let contact = try Identity.decodeUserID(userID)
        let blobID = try await transport.sendFile(
            contact, file: file, caption: caption, mediaType: mediaType, width: width, height: height, thumbnail: thumbnail
        )
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
    /// was read from, and deletes the old message (section 33.5). Returns the new position.
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
        guard let path = file.savedAs, FileManager.default.fileExists(atPath: path) else {
            throw FileGoneError()
        }
        let sent = file.attachment
        let made = try await sendFile(
            URL(fileURLWithPath: path), caption: sent.caption, to: Identity.encodeUserID(file.contact),
            mediaType: sent.mediaType, width: Int(sent.width), height: Int(sent.height), thumbnail: sent.thumbnail
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

    /// Counts every message of the chat as read.
    public func markRead(_ userID: String) async throws {
        let contact = try Identity.decodeUserID(userID)
        let newest = try await withClient { try $0.store.messages(contact).last?.position } ?? 0
        guard notes.read[userID] != newest else {
            return
        }
        notes.read[userID] = newest
        try notes.save(directory)
        await publish()
    }

    /// Starts a new session with a fresh bundle; waits for a connection.
    public func resetSession(_ userID: String) async throws {
        guard let transport else {
            throw NotConnectedError()
        }
        _ = try await transport.resetSession(Identity.decodeUserID(userID))
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
        try notes.save(directory)
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
        try notes.save(directory)
        await publish()
    }

    /// Saves the relay address and connects to it.
    ///
    /// - Throws: `URLRefusedError` when the address is not one the transport dials.
    public func setRelay(_ address: String) async throws {
        _ = try Transport.serverName(of: address, insecure: false)
        notes.relay = address
        try notes.save(directory)
        await reconnect()
    }

    /// Keeps the unsent text of a chat; an empty or blank text removes the draft.
    public func setDraft(_ text: String, for userID: String) throws {
        let draft = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        guard notes.drafts[userID] != draft else {
            return
        }
        notes.drafts[userID] = draft
        try notes.save(directory)
    }

    /// Pins a chat on top of the pinned ones, or unpins it.
    public func setPinned(_ userID: String, _ pinned: Bool) async throws {
        notes.pin(userID, pinned)
        try notes.save(directory)
        await publish()
    }

    public func setMuted(_ userID: String, _ muted: Bool) async throws {
        notes.mute(userID, muted)
        try notes.save(directory)
        await publish()
    }

    /// Moves a chat to the archive, which unpins it, or back to the list.
    public func setArchived(_ userID: String, _ archived: Bool) async throws {
        notes.archive(userID, archived)
        try notes.save(directory)
        await publish()
    }

    /// Saves the settings; a new download folder or auto-download size holds for the files
    /// that arrive from now on.
    public func saveSettings(_ settings: AppSettings) async throws {
        notes.settings = settings
        try notes.save(directory)
        await transport?.setDownloads(folder: downloadFolder, autoDownload: Self.autoDownload(settings))
    }

    /// The folder of the settings, or the one given at launch.
    private var downloadFolder: URL? {
        guard let receivedFiles else {
            return nil
        }
        return notes.settings?.downloadFolder.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? receivedFiles
    }

    /// A photo or a file downloads by itself up to the size of its kind; 0 is off.
    static func autoDownload(_ settings: AppSettings) -> Transport.AutoDownload {
        let (photos, files) = (settings.autoDownloadPhotos, settings.autoDownloadFiles)
        return { attachment in
            let megabytes = ChatFile.isPhoto(attachment.mediaType) ? photos : files
            return megabytes > 0 && Int(attachment.size) <= megabytes * 1_000_000
        }
    }

    /// Deletes the files of a store in `directory` (the database, its journal and
    /// `app.json`), then the folder itself when nothing else is left in it. Call it only
    /// after `close`.
    public static func erase(directory: URL) throws {
        let manager = FileManager.default
        let names = [ClientStore.fileName, ClientStore.fileName + "-journal", notesFile]
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
        case let error as RefusedError: "The relay refused the request (\(error.result))."
        case let error as URLRefusedError: "The relay address is refused: \(error.message)."
        case is NotConnectedError: "There is no connection to a relay."
        case FileError.filesUnsupported: "The relay does not take files."
        case FileError.fileTooLarge: "The file is too large."
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
                client: Client(store: ClientStore(directory: directory)), url: relay, receivedFiles: downloadFolder,
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
        transport = nil
        client = nil
        link = .idle
    }

    private func handle(_ event: TransportEvent) async {
        switch event {
        case .connected: link = .connected
        case .retrying: link = .connecting
        case .stopped(let reason): link = .stopped(Self.explain(reason))
        case .incoming(let sender, let received):
            // A profile, or a member of a later part that the client does not know, is no
            // message (protocol sections 20.3 and 36.3): the chat stays where it is.
            let isMessage = received.text != nil || received.attachment != nil
            if isMessage, let userID = try? Identity.encodeUserID(sender), notes.arrived(userID) {
                try? notes.save(directory)
            }
        case .refused, .transferFailed: break
        case .file(let update) where update.avatar:
            if update.state == .sending || update.state == .receiving {
                return
            }
        case .file(let update):
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
                let messageID = try await transport.sendText(row.contact, row.text, pending: row.position)
                let logged = try await transport.withClient {
                    try $0.store.messages(row.contact).last { $0.messageID == messageID }
                }
                if let logged {
                    notes.times[String(logged.position)] = row.madeAt
                    try notes.save(directory)
                }
            } catch is CancellationError {
                break
            } catch {
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
        if transport != nil || client != nil {
            return try await withClient { try Rows(store: $0.store) }
        }
        return try Rows(store: ClientStore(directory: directory))
    }

    private static func build(
        _ rows: Rows, notes: inout Notes, relay: String, link: LinkState, now: Date, progress: [Data: Progress]
    ) throws -> MessengerState {
        let milliseconds = Self.milliseconds(now)
        let chats = try rows.contacts.map { contact in
            let userID = try Identity.encodeUserID(contact.identityKey)
            let added = notes.added[userID] ?? milliseconds
            notes.added[userID] = added
            let logged = rows.messages[contact.identityKey, default: []].map { row in
                let time = notes.times[String(row.position)] ?? milliseconds
                notes.times[String(row.position)] = time
                let refused = rows.refusals[row.messageID]
                let outgoing = row.direction == .outgoing
                let file = rows.files[FileKey(contact: contact.identityKey, outgoing: outgoing, messageID: row.messageID)]
                let moved = progress[row.messageID]
                return ChatMessage(
                    id: row.position,
                    outgoing: outgoing,
                    text: row.text,
                    date: date(time),
                    waiting: outgoing && refused == nil
                        && (rows.waiting.contains(row.messageID) || file?.state == .sending),
                    failure: refused.map(refusal) ?? file.flatMap { $0.state == .notSent ? notSent($0.result) : nil },
                    file: file.map {
                        ChatFile(
                            name: $0.attachment.fileName,
                            size: Int($0.attachment.size),
                            mediaType: $0.attachment.mediaType,
                            state: $0.state,
                            done: moved?.done ?? $0.held,
                            total: moved?.total ?? ($0.state == .receiving ? Blob.blobLength(Int($0.attachment.size)) : 0),
                            savedAs: $0.savedAs,
                            result: $0.result,
                            width: Int($0.attachment.width),
                            height: Int($0.attachment.height),
                            thumbnail: $0.attachment.thumbnail
                        )
                    }
                )
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
                }
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
            )
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

    init(store: ClientStore) throws {
        identityKey = try store.identity().map { try Identity.deriveIdentityKey(seed: $0.seed) }
        contacts = try store.contacts()
        for contact in contacts {
            messages[contact.identityKey] = try store.messages(contact.identityKey)
        }
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

/// `app.json`: times are milliseconds since 1970, message keys are log positions.
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
        pin(userID, false)
        muted.remove(userID)
        archived.remove(userID)
    }

    static func load(_ directory: URL) -> Notes {
        let url = directory.appendingPathComponent(Messenger.notesFile)
        guard let data = try? Data(contentsOf: url), let notes = try? JSONDecoder().decode(Notes.self, from: data) else {
            return Notes()
        }
        return notes
    }

    func save(_ directory: URL) throws {
        let url = directory.appendingPathComponent(Messenger.notesFile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(self).write(to: url, options: .atomic)
        chmod(url.path, ClientStore.fileMode)
    }
}
