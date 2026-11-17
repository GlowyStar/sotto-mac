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

    /// Opens the store in `directory`, creating it when it is missing; `relay` is used until
    /// an address is saved with `setRelay`.
    public init(directory: URL, relay: String) throws {
        self.directory = directory
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
        let state = try Self.build(rows, notes: &updated, relay: relay, link: link, now: Date())
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
        return try build(Rows(store: store), notes: &notes, relay: notes.relay ?? relay, link: .idle, now: Date())
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
                try client.store.removeContact(contact)
                try client.store.deleteMessages(contact)
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
                    try client.store.deleteMessage(position)
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

    public func saveSettings(_ settings: AppSettings) throws {
        notes.settings = settings
        try notes.save(directory)
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
        case is CancellationError: "The request was cancelled."
        default: "\(error)"
        }
    }

    /// The failure of a message that the relay refused with `result`.
    static func refusal(_ result: String) -> String {
        "The relay refused it (\(result))."
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
            let made = try Transport(client: Client(store: ClientStore(directory: directory)), url: relay)
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
        case .incoming(let sender, _):
            if let userID = try? Identity.encodeUserID(sender), notes.arrived(userID) {
                try? notes.save(directory)
            }
        case .refused: break
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
        _ rows: Rows, notes: inout Notes, relay: String, link: LinkState, now: Date
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
                return ChatMessage(
                    id: row.position,
                    outgoing: row.direction == .outgoing,
                    text: row.text,
                    date: date(time),
                    waiting: row.direction == .outgoing && refused == nil && rows.waiting.contains(row.messageID),
                    failure: refused.map(refusal)
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
                draft: notes.drafts[userID]
            )
        }
        return MessengerState(
            userID: try rows.identityKey.map(Identity.encodeUserID),
            chats: chats,
            link: link,
            relay: relay
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}

/// One read of the store, made where the session layer lives.
struct Rows: Sendable {
    var identityKey: Data?
    var contacts: [Contact]
    var messages: [Data: [StoredMessage]] = [:]
    var pending: [Data: [PendingText]] = [:]
    var waiting: Set<Data>
    var refusals: [Data: String]

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
