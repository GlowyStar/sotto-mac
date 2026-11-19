import Foundation
@testable import SottoCore

/// What the scripted relay puts on a connection to the client.
enum Outbound: Sendable {
    case message(SocketMessage)
    case close(Int?)
    case tooBig
}

/// The connection that an edit of the scripted relay sees.
struct Link: Sendable {
    let number: Int
    let identity: Data?
}

/// Raised by an edit: the connection ends without its frame, with close code 1011.
struct Cut: Error {}

/// A relay in the test process that keeps the rules a client meets: Hello, Login and
/// LoggedIn, uploads, fetches with one handout, queues with Stored, Deliver and Ack, one live
/// connection per identity, and the blob frames of section 31. Its edits stand where the
/// reference puts its tampering proxy.
actor ScriptedRelay: RelayDialer {
    typealias ToClient = @Sendable (Link, SocketMessage) throws -> [Outbound]
    typealias ToRelay = @Sendable (Link, SocketMessage) throws -> SocketMessage?

    private(set) var connections = 0
    private(set) var sentToRelay: [(link: Link, frame: Data)] = []
    private(set) var clientCloseCodes: [Int: Int] = [:]
    private var toClient: ToClient = { [.message($1)] }
    private var toRelay: ToRelay = { $1 }
    private var refusals: [Int] = []
    private var isUp = true
    private var sockets: [Int: ScriptedSocket] = [:]
    private var identities: [Int: Data] = [:]
    private var online: [Data: Int] = [:]
    private var bundles: [Data: Sotto_UploadBundle] = [:]
    private(set) var queues: [Data: [Sotto_Deliver]] = [:]
    /// The blobs by uploader and blob id, with the bytes stored so far.
    private(set) var blobs: [Data: StoredBlob] = [:]
    private var blobMaxBytes = 1 << 26
    private var blobQuotaBytes = 1 << 27

    struct StoredBlob {
        var recipient: Data
        var length: Int
        var bytes: Data
    }

    /// What the next LoggedIn announces and what a StartBlob may take; 0 serves no blobs.
    func setBlobLimits(maxBytes: Int, quotaBytes: Int = 1 << 27) {
        blobMaxBytes = maxBytes
        blobQuotaBytes = quotaBytes
    }

    /// Drops the bytes of a blob, as expiry does.
    func expireBlobs() {
        blobs = [:]
    }

    func edit(toClient: @escaping ToClient) {
        self.toClient = toClient
    }

    func edit(toRelay: @escaping ToRelay) {
        self.toRelay = toRelay
    }

    /// The next Sends are refused with these error codes, one each, and store nothing.
    func refuseSends(_ codes: [Int]) {
        refusals += codes
    }

    /// Closes every connection with 1001 and refuses dials until `start`.
    func shutDown() async {
        isUp = false
        for number in sockets.keys.sorted() {
            await end(number, .close(1001))
        }
    }

    func start() {
        isUp = true
    }

    func close(_ number: Int, code: Int) async {
        await end(number, .close(code))
    }

    /// What a newer login of the identity does to the live connection (section 8.5).
    func replace(_ identity: Data) async {
        if let number = online[identity] {
            await end(number, .close(4001))
        }
    }

    /// The kinds of the frames that the client sent, on one connection or on all.
    func kinds(_ number: Int? = nil, of identity: Data? = nil) -> [String] {
        sentToRelay.filter { sent in
            (number == nil || sent.link.number == number) && (identity == nil || sent.link.identity == identity)
        }.map { kind(of: $0.frame) }
    }

    func uploads() -> [Sotto_UploadBundle] {
        sentToRelay.compactMap { sent in
            guard case .uploadBundle(let upload) = try? Sotto_ClientFrame(serializedBytes: sent.frame).frame else {
                return nil
            }
            return upload
        }
    }

    func dial(_ url: URL) async throws -> any RelaySocket {
        guard isUp else {
            throw SocketError.closed(code: nil)
        }
        connections += 1
        let socket = ScriptedSocket(number: connections, relay: self)
        sockets[connections] = socket
        var hello = Sotto_ServerFrame()
        hello.hello.version = 1
        hello.hello.nonce = Data(repeating: 7, count: Identity.nonceLength)
        await push(connections, hello)
        return socket
    }

    func clientClosed(_ number: Int, code: Int) {
        clientCloseCodes[number] = code
        disconnect(number)
    }

    func received(_ number: Int, _ data: Data) async {
        guard sockets[number] != nil else {
            return
        }
        let link = Link(number: number, identity: identities[number])
        let edited: SocketMessage?
        do {
            edited = try toRelay(link, .binary(data))
        } catch {
            await end(number, .close(1011))
            return
        }
        guard case .binary(let frame) = edited else {
            return
        }
        sentToRelay.append((link, frame))
        guard let parsed = try? Sotto_ClientFrame(serializedBytes: frame).frame else {
            await end(number, .close(1008))
            return
        }
        await handle(number, parsed)
    }

    private func handle(_ number: Int, _ frame: Sotto_ClientFrame.OneOf_Frame) async {
        var answer = Sotto_ServerFrame()
        switch frame {
        case .login(let login):
            if let old = online[login.identityKey] {
                await end(old, .close(4001))
            }
            identities[number] = login.identityKey
            online[login.identityKey] = number
            answer.loggedIn.oneTimePrekeyCount = UInt32(bundles[login.identityKey]?.oneTimePrekeys.count ?? 0)
            answer.loggedIn.blobMaxBytes = UInt32(blobMaxBytes)
            await push(number, answer)
            for deliver in queues[login.identityKey] ?? [] {
                await push(number, deliverFrame(deliver))
            }
            return
        case .uploadBundle(let upload):
            let identity = identities[number]!
            var held = upload
            held.oneTimePrekeys = (bundles[identity]?.oneTimePrekeys ?? []) + upload.oneTimePrekeys
            bundles[identity] = held
            answer.bundleStored = Sotto_BundleStored()
        case .fetchBundle(let fetch):
            guard var held = bundles[fetch.identity] else {
                answer.error.code = .notFound
                answer.error.identity = fetch.identity
                break
            }
            answer.bundle.identity = fetch.identity
            answer.bundle.identityDhKey = held.identityDhKey
            answer.bundle.identityDhSignature = held.identityDhSignature
            answer.bundle.signedPrekey = held.signedPrekey
            if !held.oneTimePrekeys.isEmpty {
                answer.bundle.oneTimePrekey = held.oneTimePrekeys.removeFirst()
                bundles[fetch.identity] = held
            }
        case .send(let send):
            if !refusals.isEmpty {
                answer.error.code = Sotto_ErrorCode(rawValue: refusals.removeFirst())!
                answer.error.messageID = send.messageID
                break
            }
            guard bundles[send.recipient] != nil else {
                answer.error.code = .unknownRecipient
                answer.error.messageID = send.messageID
                break
            }
            var deliver = Sotto_Deliver()
            deliver.messageID = send.messageID
            deliver.sender = identities[number]!
            deliver.payload = send.payload
            let queue = queues[send.recipient] ?? []
            let isNew = !queue.contains { $0.sender == deliver.sender && $0.messageID == deliver.messageID }
            if isNew {
                queues[send.recipient] = queue + [deliver]
            }
            answer.stored.messageID = send.messageID
            await push(number, answer)
            if isNew, let recipient = online[send.recipient] {
                await push(recipient, deliverFrame(deliver))
            }
            return
        case .ack(let ack):
            let identity = identities[number]!
            for reference in ack.messages {
                queues[identity]?.removeAll { $0.sender == reference.sender && $0.messageID == reference.messageID }
            }
            return
        case .startBlob(let start):
            let key = identities[number]! + start.blobID
            if let held = blobs[key] {
                answer.blobStored.blobID = start.blobID
                answer.blobStored.storedLength = UInt32(held.bytes.count)
                break
            }
            answer.error.blobID = start.blobID
            let uploaded = blobs.filter { $0.key.prefix(32) == identities[number]! }.map(\.value.length).reduce(0, +)
            if Int(start.length) > blobMaxBytes {
                answer.error.code = .blobTooLarge
            } else if bundles[start.recipient] == nil {
                answer.error.code = .unknownRecipient
            } else if uploaded + Int(start.length) > blobQuotaBytes {
                answer.error.code = .quotaFull
            } else {
                blobs[key] = StoredBlob(recipient: start.recipient, length: Int(start.length), bytes: Data())
                answer.blobStored.blobID = start.blobID
            }
        case .putBlob(let put):
            let key = identities[number]! + put.blobID
            guard var held = blobs[key] else {
                answer.error.code = .notFound
                answer.error.blobID = put.blobID
                break
            }
            if Int(put.offset) == held.bytes.count {
                guard held.bytes.count + put.data.count <= held.length else {
                    answer.error.code = .blobTooLarge
                    answer.error.blobID = put.blobID
                    break
                }
                held.bytes += put.data
                blobs[key] = held
            }
            answer.blobStored.blobID = put.blobID
            answer.blobStored.storedLength = UInt32(held.bytes.count)
        case .fetchBlob(let fetch):
            guard let held = blobs[fetch.uploader + fetch.blobID], held.recipient == identities[number],
                  held.bytes.count == held.length
            else {
                answer.error.code = .notFound
                answer.error.blobID = fetch.blobID
                answer.error.identity = fetch.uploader
                break
            }
            let from = min(Int(fetch.offset), held.length)
            answer.blobData.blobID = fetch.blobID
            answer.blobData.uploader = fetch.uploader
            answer.blobData.offset = fetch.offset
            answer.blobData.data = held.bytes.subdata(in: from..<min(from + Int(fetch.length), held.length))
        case .deleteBlob(let delete):
            let identity = identities[number]!
            if let held = blobs[delete.uploader + delete.blobID],
               delete.uploader == identity || (held.recipient == identity && held.bytes.count == held.length) {
                blobs[delete.uploader + delete.blobID] = nil
            }
            return
        }
        await push(number, answer)
    }

    private func deliverFrame(_ deliver: Sotto_Deliver) -> Sotto_ServerFrame {
        var frame = Sotto_ServerFrame()
        frame.deliver = deliver
        return frame
    }

    private func push(_ number: Int, _ frame: Sotto_ServerFrame) async {
        guard let socket = sockets[number] else {
            return
        }
        let edited: [Outbound]
        do {
            edited = try toClient(Link(number: number, identity: identities[number]), .binary(frame.serializedBytes()))
        } catch {
            await end(number, .close(1011))
            return
        }
        for outbound in edited {
            await socket.push(outbound)
        }
    }

    private func end(_ number: Int, _ outbound: Outbound) async {
        await sockets[number]?.push(outbound)
        disconnect(number)
    }

    private func disconnect(_ number: Int) {
        sockets[number] = nil
        if let identity = identities[number], online[identity] == number {
            online[identity] = nil
        }
    }

    private func kind(of frame: Data) -> String {
        switch try? Sotto_ClientFrame(serializedBytes: frame).frame {
        case .login: "login"
        case .uploadBundle: "upload_bundle"
        case .fetchBundle: "fetch_bundle"
        case .send: "send"
        case .ack: "ack"
        case .startBlob: "start_blob"
        case .putBlob: "put_blob"
        case .fetchBlob: "fetch_blob"
        case .deleteBlob: "delete_blob"
        case nil: "none"
        }
    }
}

/// The client's end of one connection of the scripted relay.
actor ScriptedSocket: RelaySocket {
    let number: Int
    let relay: ScriptedRelay
    private var inbox: [Outbound] = []
    private var waiter: CheckedContinuation<SocketMessage, Error>?
    private var ended: SocketError?
    private var closedByClient = false

    init(number: Int, relay: ScriptedRelay) {
        self.number = number
        self.relay = relay
    }

    func push(_ outbound: Outbound) {
        guard ended == nil else {
            return
        }
        inbox.append(outbound)
        if let waiter {
            self.waiter = nil
            take(waiter)
        }
    }

    func receive() async throws -> SocketMessage {
        if let ended {
            throw ended
        }
        return try await withCheckedThrowingContinuation { waiter in
            if inbox.isEmpty {
                self.waiter = waiter
            } else {
                take(waiter)
            }
        }
    }

    func send(_ data: Data) async throws {
        if let ended {
            throw ended
        }
        await relay.received(number, data)
    }

    func close(code: Int) async {
        guard !closedByClient else {
            return
        }
        closedByClient = true
        ended = .closed(code: nil)
        inbox = []
        waiter?.resume(throwing: SocketError.closed(code: nil))
        waiter = nil
        await relay.clientClosed(number, code: code)
    }

    private func take(_ waiter: CheckedContinuation<SocketMessage, Error>) {
        switch inbox.removeFirst() {
        case .message(let message):
            waiter.resume(returning: message)
        case .close(let code):
            ended = .closed(code: code)
            inbox = []
            waiter.resume(throwing: SocketError.closed(code: code))
        case .tooBig:
            ended = .tooBig
            inbox = []
            waiter.resume(throwing: SocketError.tooBig)
        }
    }
}

/// A relay that is never there: every dial fails.
struct NoRelay: RelayDialer {
    func dial(_ url: URL) async throws -> any RelaySocket {
        throw SocketError.closed(code: nil)
    }
}

// MARK: Running transports

let patienceSeconds = 10.0

/// The one clock of the clients of a test, which can be shared with their transports.
final class SharedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds = Date().timeIntervalSince1970.rounded(.down)

    var now: TimeInterval {
        lock.withLock { seconds }
    }

    func advance(_ by: Int64) {
        lock.withLock { seconds += TimeInterval(by) }
    }
}

/// The folder of the clients of one test, removed when the test lets it go.
final class Folder: Sendable {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-transport-\(UUID().uuidString)")
    let clock = SharedClock()

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Opens the client of a name with system random bytes, so that a second call, a
    /// restart, makes new message ids.
    func open(_ name: String) throws -> Client {
        let clock = clock
        return try Client(store: ClientStore(directory: url.appendingPathComponent(name)), clock: { clock.now })
    }

    func userID(_ name: String) throws -> String {
        try Identity.encodeUserID(identityKey(name))
    }

    func identityKey(_ name: String) throws -> Data {
        try Identity.deriveIdentityKey(seed: ClientStore(directory: url.appendingPathComponent(name)).identity()!.seed)
    }
}

/// Makes the clients of the names, each the contact of every other.
func befriend(_ folder: Folder, _ names: String...) throws {
    for name in names {
        _ = try folder.open(name)
    }
    for name in names {
        let client = try folder.open(name)
        for other in names where other != name {
            try client.addContact(folder.userID(other))
        }
    }
}

/// A transport whose waits are the schedule times `scale` and have no jitter.
func makeTransport(
    _ client: sending Client,
    _ dialer: any RelayDialer,
    url: String = "ws://127.0.0.1:9/ws",
    scale: Double = 0.02,
    receivedFiles: URL? = nil
) throws -> Transport {
    try Transport(
        client: client, url: url, downloads: receivedFiles.map { .folder($0) } ?? .off, dialer: dialer, jitter: { _ in 0 },
        sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(seconds * scale * 1_000_000_000)) }
    )
}

struct Timeout: Error {}

/// Runs `body` with a time limit; throws `Timeout` when the limit comes first.
func within<T: Sendable>(_ seconds: Double = patienceSeconds, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw Timeout()
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

/// The next event that matches; the events before it are dropped.
@discardableResult
func nextEvent(_ transport: Transport, _ matches: @escaping @Sendable (TransportEvent) -> Bool) async throws -> TransportEvent {
    try await within {
        for await event in transport.events where matches(event) {
            return event
        }
        throw Timeout()
    }
}

/// The next Deliver that is more than a receipt of part 5 (section 39.5), which every
/// message of the chat now brings back to its sender.
func nextIncoming(_ transport: Transport) async throws -> (sender: Data, received: Received) {
    guard case .incoming(let sender, let received) = try await nextEvent(transport, {
        if case .incoming(_, let received) = $0 { !isAReceipt(received) } else { false }
    }) else {
        throw Timeout()
    }
    return (sender, received)
}

/// A Deliver that changed nothing but the marks of own messages, or nothing at all.
func isAReceipt(_ received: Received) -> Bool {
    received.text == nil && received.attachment == nil && received.profile == nil && received.result == nil
        && received.missing == 0 && received.position == nil && received.timer == nil
}

/// The next Deliver that is more than a receipt, or a copy of one that a relay delivered
/// again (a receipt can come twice around a restart of the relay).
func nextText(_ transport: Transport) async throws -> (Data, String?) {
    while true {
        let incoming = try await nextIncoming(transport)
        if incoming.received.result != SessionError.duplicate.result {
            return (incoming.sender, incoming.received.text)
        }
    }
}

/// Waits until `condition` holds, polling.
func until(_ condition: @escaping @Sendable () async throws -> Bool) async throws {
    try await within {
        while try await !condition() {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// A transport whose run task is started; `stop` ends it.
final class Running: Sendable {
    let transport: Transport
    let task: Task<Void, Error>

    init(_ transport: Transport) {
        self.transport = transport
        task = Task { try await transport.run() }
    }

    func connected() async throws -> Running {
        try await nextEvent(transport) { $0 == .connected }
        return self
    }

    func stop() async {
        await transport.stop()
        task.cancel()
        _ = await task.result
    }
}

func run(
    _ client: sending Client,
    _ dialer: any RelayDialer,
    url: String = "ws://127.0.0.1:9/ws",
    scale: Double = 0.02,
    receivedFiles: URL? = nil
) async throws -> Running {
    try await Running(makeTransport(client, dialer, url: url, scale: scale, receivedFiles: receivedFiles)).connected()
}

func isRegistered(_ transport: Transport) async throws -> Bool {
    try await transport.withClient { try $0.store.newestSignedPrekey()?.confirmed ?? false }
}

func outbox(_ transport: Transport) async throws -> [Outgoing] {
    try await transport.withClient { try $0.outbox() }
}

func textsReceived(_ transport: Transport) async throws -> [String] {
    try await transport.withClient { client in
        try client.store.query("SELECT text FROM messages WHERE direction = 'in' ORDER BY rowid").map { $0[0].text! }
    }
}

func sessionCount(_ transport: Transport, _ contact: Data) async throws -> Int {
    try await transport.withClient { try $0.store.sessions(contact).count }
}

func serverKind(_ message: SocketMessage) -> String? {
    guard case .binary(let data) = message, let frame = try? Sotto_ServerFrame(serializedBytes: data).frame else {
        return nil
    }
    return switch frame {
    case .hello: "hello"
    case .loggedIn: "logged_in"
    case .bundleStored: "bundle_stored"
    case .bundle: "bundle"
    case .stored: "stored"
    case .deliver: "deliver"
    case .error: "error"
    case .blobStored: "blob_stored"
    case .blobData: "blob_data"
    }
}

func serverFrame(_ message: SocketMessage) -> Sotto_ServerFrame {
    guard case .binary(let data) = message else {
        return Sotto_ServerFrame()
    }
    return (try? Sotto_ServerFrame(serializedBytes: data)) ?? Sotto_ServerFrame()
}

func binary(_ frame: Sotto_ServerFrame) -> SocketMessage {
    .binary((try? frame.serializedBytes()) ?? Data())
}
