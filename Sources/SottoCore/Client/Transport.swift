import Foundation
import SwiftProtobuf
import UniformTypeIdentifiers

/// The three actions of section 11.1.
public enum TransportAction: String, Sendable {
    case retry = "Retry"
    case stop = "Stop"
    case backOff = "Back off"
}

/// The URL is not dialed: section 8.2, rule 4, or the loopback rule of section 23.1.
public struct URLRefusedError: Error, Equatable, Sendable {
    public let message: String
}

/// The relay refused a FetchBundle with an Error whose action is Stop.
public struct RefusedError: Error, Equatable, Sendable {
    public let result: String
}

/// A file of section 33.5 changed its state or its progress. `contact` is the recipient of a
/// file being sent and the sender of a received one; `fileName` is the name in the
/// attachment, a text of the peer for a received file. `done` out of `total` bytes of the
/// blob are stored at the relay or downloaded; `path` is where a received file was saved.
public struct FileUpdate: Equatable, Sendable {
    public var contact: Data
    public var blobID: Data
    public var messageID: Data
    public var fileName: String
    public var state: FileState
    public var done = 0
    public var total = 0
    public var result: String?
    public var path: URL?
}

/// What the transport reports, in its order.
public enum TransportEvent: Sendable, Equatable {
    /// The relay accepted the Login and the steps of section 23.3 went out.
    case connected
    /// A Deliver after `Client.receive`, which committed before its Ack left.
    case incoming(sender: Data, received: Received)
    /// A Send or an UploadBundle that the relay refused with an action Stop; `contact` is
    /// the recipient of a Send and nil for an UploadBundle.
    case refused(result: String, contact: Data?)
    /// The connection is gone or was never made; the next attempt follows the wait.
    case retrying(seconds: Double)
    /// The client does not reconnect; a person takes the next step (section 11.1).
    case stopped(reason: String)
    /// A file of part 3 changed.
    case file(FileUpdate)
    /// A transfer stopped on a local failure; the next login starts it again.
    case transferFailed(reason: String)
}

/// The client transport of docs/protocol.md, section 23, over the session layer.
///
/// `run` dials the relay, logs in, runs the steps after the LoggedIn and serves the frames
/// of the relay until the connection ends; it reconnects or stops as section 11 says. It
/// only moves frames: every rule of a message is a method of `Client`, which commits before
/// it answers. The actor owns the `Client`, so its store is used from one place at a time.
public actor Transport {
    public typealias Jitter = @Sendable (Double) -> Double
    public typealias Sleep = @Sendable (Double) async throws -> Void
    /// Whether a file that arrives is downloaded by itself; the others wait for `download`.
    public typealias AutoDownload = @Sendable (Sotto_Attachment) -> Bool

    public static let retryMaxSeconds = 60.0
    public static let frameRefillSeconds = 1.0
    public static let normalClosure = 1000
    public static let stopCloseCodes: Set<Int> = [1003, 1008, 1009, 3000, 4001]
    public static let backOffCodes: Set<Int> = [2, 3, 4]
    /// The frame bucket and the page ceiling are shared by every request (section 23.5).
    public static let holdingCodes: Set<Int> = [3, 4]
    static let textFrame = 1003
    static let protocolViolation = 1008
    static let frameTooBig = 1009
    static let errorNames = [
        "ERROR_CODE_UNSPECIFIED", "UNKNOWN_RECIPIENT", "QUEUE_FULL", "STORAGE_FULL",
        "RATE_LIMITED", "NOT_FOUND", "BAD_BUNDLE", "IDENTITY_KEY_MISMATCH", "QUOTA_FULL",
        "BLOB_TOO_LARGE",
    ]

    public nonisolated let serverName: String
    public nonisolated let url: URL
    public nonisolated let events: AsyncStream<TransportEvent>
    private let eventSink: AsyncStream<TransportEvent>.Continuation
    private let client: Client
    private let dialer: any RelayDialer
    private let jitter: Jitter
    private let sleep: Sleep

    private var dialed: (any RelaySocket)?
    private var socket: (any RelaySocket)?
    private var ready = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var holders = 0
    private var unblockWaiters: [CheckedContinuation<Void, Never>] = []
    private var requests: [Request] = []
    private var backOffs: [Task<Void, Never>] = []
    private var stopping = false
    /// The folder for received files (section 33.3); nil leaves every file offered.
    private var receivedFiles: URL?
    private var autoDownload: AutoDownload
    /// The `blob_max_bytes` of the last LoggedIn: 0 before a login and for a relay without
    /// the blob frames (section 28.2).
    public private(set) var blobMaxBytes = 0
    private var transfers: [TransferKey: (id: Int, task: Task<Void, Never>)] = [:]
    private var transferCount = 0
    /// Counts the requests in the order they left.
    private var sequence = 0
    /// A DeleteBlob sent on this connection, with the sequence of the last request that left
    /// before it: an answer to a later request confirms it (section 33.2).
    private var deletionsSent: [BlobKey: Int] = [:]
    /// Counts the ends of connections, so that a send that outlived its connection changes
    /// nothing of the next one.
    private var generation = 0
    /// The last frame handed to the socket; the next one leaves after it.
    private var sendTail: Task<Void, Never>?

    /// - Parameters:
    ///   - client: The session layer of the identity; the transport owns it from here on.
    ///   - url: The URL of the relay, dialed as given (section 23.1).
    ///   - insecure: The override that allows a ws URL to a host that is not a loopback host.
    ///   - jitter: Chooses a number evenly between 0 and its argument (sections 23.4, 23.5).
    /// - Throws: `URLRefusedError`: the URL is not dialed; nothing else ran.
    public init(
        client: sending Client,
        url: String,
        insecure: Bool = false,
        receivedFiles: URL? = nil,
        autoDownload: @escaping AutoDownload = { _ in true },
        dialer: any RelayDialer = URLSessionDialer(),
        jitter: @escaping Jitter = Transport.evenJitter,
        sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) throws {
        serverName = try Self.serverName(of: url, insecure: insecure)
        guard let parsed = URL(string: url) else {
            throw URLRefusedError(message: "the URL does not parse")
        }
        self.url = parsed
        self.client = client
        self.receivedFiles = receivedFiles
        self.autoDownload = autoDownload
        self.dialer = dialer
        self.jitter = jitter
        self.sleep = sleep
        (events, eventSink) = AsyncStream.makeStream()
    }

    // MARK: Rules

    public static func evenJitter(_ upper: Double) -> Double {
        upper > 0 ? Double.random(in: 0...upper) : 0
    }

    /// Returns the server name of section 8.2 of a URL that the client may dial.
    public static func serverName(of url: String, insecure: Bool) throws -> String {
        // Split by hand as the reference's urlsplit does: URLComponents turns an IDNA host
        // into Unicode and would hide what the URL says.
        guard let schemeEnd = url.range(of: "://"), URL(string: url) != nil else {
            throw URLRefusedError(message: "the URL does not parse")
        }
        let scheme = url[..<schemeEnd.lowerBound].lowercased()
        guard scheme == "ws" || scheme == "wss" else {
            throw URLRefusedError(message: "the scheme of the URL is not ws or wss")
        }

        let authority = url[schemeEnd.upperBound...].prefix { !"/?#".contains($0) }
        let hostAndPort = authority.split(separator: "@", omittingEmptySubsequences: false).last ?? ""
        var host: Substring
        var port: Substring
        if hostAndPort.hasPrefix("["), let close = hostAndPort.firstIndex(of: "]") {
            host = hostAndPort[hostAndPort.index(after: hostAndPort.startIndex)..<close]
            port = hostAndPort[hostAndPort.index(after: close)...]
        } else if let colon = hostAndPort.lastIndex(of: ":") {
            host = hostAndPort[..<colon]
            port = hostAndPort[colon...]
        } else {
            host = hostAndPort
            port = ""
        }
        if port.hasPrefix(":") {
            port = port.dropFirst()
        }
        guard port.isEmpty || port.allSatisfy({ $0.isASCII && $0.isNumber }) && Int(port).map({ $0 <= 65535 }) == true else {
            throw URLRefusedError(message: "the URL does not parse")
        }
        let name = host.lowercased()
        guard name.range(of: #"^[a-z0-9._:-]{1,255}$"#, options: .regularExpression) != nil else {
            throw URLRefusedError(message: "the host of the URL gives no server name (section 8.2)")
        }

        if scheme == "ws" && !isLoopback(name) && !insecure {
            throw URLRefusedError(message: "a ws URL is dialed only to a loopback host without the insecure override")
        }
        return name
    }

    /// The loopback host of section 23.1: localhost, 127.x.y.z in full, or ::1.
    public static func isLoopback(_ serverName: String) -> Bool {
        if serverName == "localhost" {
            return true
        }
        let dottedDecimal = #"^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$"#
        if serverName.range(of: dottedDecimal, options: .regularExpression) != nil {
            let numbers = serverName.split(separator: ".").map { Int($0)! }
            return numbers[0] == 127 && numbers.max()! <= 255
        }
        var address = in6_addr()
        guard inet_pton(AF_INET6, serverName, &address) == 1 else {
            return false
        }
        return withUnsafeBytes(of: &address) { Array($0) } == Array(repeating: 0, count: 15) + [1]
    }

    /// The wait before attempt n of section 23.4.
    public static func retrySeconds(_ attempt: Int, jitter: Jitter = evenJitter) -> Double {
        let wait = min(pow(2, Double(min(attempt - 1, 10))), retryMaxSeconds)
        return wait + jitter(wait / 2)
    }

    /// The wait of section 23.5 after the k-th refusal in a row of one frame.
    public static func backOffSeconds(_ refusals: Int, jitter: Jitter = evenJitter) -> Double {
        let wait = min(frameRefillSeconds * pow(2, Double(min(refusals - 1, 10))), retryMaxSeconds)
        return wait + jitter(wait / 2)
    }

    /// The action of a close that the relay sent (section 11.3); nil for no close.
    public static func closeAction(_ code: Int?) -> TransportAction {
        if let code, stopCloseCodes.contains(code) {
            return .stop
        }
        return .retry
    }

    /// The action of an Error code (section 11.2); an unknown code is Stop.
    public static func errorAction(_ code: Int) -> TransportAction {
        backOffCodes.contains(code) ? .backOff : .stop
    }

    static func errorName(_ code: Int) -> String {
        errorNames.indices.contains(code) ? errorNames[code] : "error code \(code)"
    }

    static func uploadFrame(_ upload: PrekeyUpload) -> Sotto_ClientFrame {
        var frame = Sotto_UploadBundle()
        frame.identityDhKey = upload.identityDHKey
        frame.identityDhSignature = upload.identityDHSignature
        frame.signedPrekey.id = upload.signedPrekey.id
        frame.signedPrekey.key = upload.signedPrekey.key
        frame.signedPrekey.signature = upload.signedPrekey.signature
        frame.oneTimePrekeys = upload.oneTimePrekeys.map { prekey in
            var oneTimePrekey = Sotto_OneTimePrekey()
            oneTimePrekey.id = prekey.id
            oneTimePrekey.key = prekey.key
            return oneTimePrekey
        }
        var envelope = Sotto_ClientFrame()
        envelope.uploadBundle = frame
        return envelope
    }

    static func bundle(of frame: Sotto_Bundle) -> PrekeyBundle {
        PrekeyBundle(
            identity: frame.identity,
            identityDHKey: frame.identityDhKey,
            identityDHSignature: frame.identityDhSignature,
            signedPrekey: SignedPrekey(
                id: frame.signedPrekey.id,
                key: frame.signedPrekey.key,
                signature: frame.signedPrekey.signature
            ),
            oneTimePrekey: frame.hasOneTimePrekey
                ? OneTimePrekey(id: frame.oneTimePrekey.id, key: frame.oneTimePrekey.key)
                : nil
        )
    }

    static func sendFrame(_ outgoing: Outgoing) -> Sotto_ClientFrame {
        var envelope = Sotto_ClientFrame()
        envelope.send.messageID = outgoing.messageID
        envelope.send.recipient = outgoing.recipient
        envelope.send.payload = outgoing.payload
        return envelope
    }

    // MARK: The caller's side

    /// Runs `body` with the client on the actor, for reads and local changes such as a
    /// new contact.
    public func withClient<T: Sendable>(_ body: @Sendable (Client) throws -> T) rethrows -> T {
        try body(client)
    }

    /// Serves connections until an action Stop, reported as `.stopped`, or until `stop`.
    /// A Retry waits by the schedule of section 23.4. `events` ends when this returns.
    public func run() async throws {
        defer { eventSink.finish() }
        try client.deleteExpiredPrekeys()
        var attempt = 0
        while !stopping {
            if attempt > 0 {
                let wait = Self.retrySeconds(attempt, jitter: jitter)
                eventSink.yield(.retrying(seconds: wait))
                try await sleep(wait)
                if stopping {
                    return
                }
            }
            do {
                let loggedIn = try await serveConnection()
                attempt = loggedIn ? 1 : attempt + 1
            } catch let stop as StopRun {
                eventSink.yield(.stopped(reason: stop.reason))
                return
            }
        }
    }

    /// Ends `run` without an event: closes the connection with 1000 and fails every call
    /// that waits for a login. Cancel the task of `run` too when it may sleep in a wait.
    public func stop() async {
        stopping = true
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume(throwing: CancellationError()) }
        await dialed?.close(code: Self.normalClosure)
    }

    /// Commits a text to the outbox and sends it; a Send without a Stored is sent again
    /// after the next login. A contact without a session gets its bundle fetched first,
    /// which waits for a login.
    ///
    /// - Throws: `EnvelopeError.textTooLong` before any frame; `RefusedError` when the relay
    ///   refused the FetchBundle with a Stop; `CryptoError` or `SessionError` when
    ///   `Client.sendText` failed with the result that it names.
    /// - Returns: The message id.
    @discardableResult
    public func sendText(_ contact: Data, _ text: String, pending: Int64? = nil) async throws -> Data {
        _ = try Envelope.encodeText(text)
        var bundle: PrekeyBundle?
        if try !client.hasSession(contact) {
            bundle = try await fetchBundle(contact)
        }
        let outgoing = try client.sendText(contact, text, bundle: bundle, pending: pending)
        if ready {
            await request(Request(frame: Self.sendFrame(outgoing)))
        }
        return outgoing.messageID
    }

    /// Steps 1 and 2 of section 33.2 once logged in: reads the file once, makes its blob and
    /// commits the upload; the upload goes on by itself and reports `.file` events, also
    /// after a reconnect or a restart. A nil `mediaType` is taken from the name's extension;
    /// `width`, `height` and `thumbnail` are the fields of section 32.1.
    ///
    /// - Throws: a check of section 33.1 (`SessionError.notAContact`,
    ///   `FileError.filesUnsupported`, `FileError.fileTooLarge`); `InvalidInputError` when
    ///   the caption is longer than `Envelope.maxCaptionBytes`; an error of the file system
    ///   when the file cannot be read.
    /// - Returns: The blob id that the `.file` events of the file name.
    @discardableResult
    public func sendFile(
        _ contact: Data, file: URL, caption: String = "", mediaType: String? = nil,
        width: Int = 0, height: Int = 0, thumbnail: Data = Data()
    ) async throws -> Data {
        try await waitUntilReady()
        // A sending cancelled while it waited for the login makes nothing.
        try Task.checkCancellation()
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        try client.checkFile(contact, size: size, blobMaxBytes: blobMaxBytes)
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let mediaType = mediaType ?? UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? ""
        let upload = try client.startUpload(
            contact,
            file: data,
            blobMaxBytes: blobMaxBytes,
            fileName: Self.cut(file.lastPathComponent, to: Envelope.maxFileNameBytes),
            mediaType: mediaType.utf8.count <= Envelope.maxMediaTypeBytes ? mediaType : "",
            caption: caption,
            width: width,
            height: height,
            thumbnail: thumbnail.count <= Envelope.maxThumbnailBytes ? thumbnail : Data(),
            localPath: file.path
        )
        report(upload, .sending)
        startTransfers()
        return upload.blobID
    }

    /// Downloads a received file that is offered, paused or could not be received, from the
    /// bytes it holds; without a connection it starts after the next login.
    public func download(_ position: Int64) throws {
        guard receivedFiles != nil, let file = try client.store.file(position), file.incoming,
            [.offered, .receiving, .notReceived].contains(file.state)
        else {
            return
        }
        try client.beginDownload(position)
        eventSink.yield(.file(Self.update(file, .receiving, done: file.held, total: Blob.blobLength(Int(file.attachment.size)))))
        startTransfers()
    }

    /// Stops a download until `download` is asked again; the bytes it holds stay. A piece on
    /// its way is still saved, so the answers of the relay keep their order (section 7.4).
    public func pauseDownload(_ position: Int64) throws {
        guard let file = try client.store.file(position), file.state == .receiving else {
            return
        }
        try client.pauseDownload(position)
        eventSink.yield(.file(Self.update(file, .offered, done: file.held)))
    }

    /// The folder for received files and the rule for files that arrive from now on.
    public func setDownloads(folder: URL?, autoDownload: @escaping AutoDownload) {
        receivedFiles = folder
        self.autoDownload = autoDownload
    }

    /// L2 of section 20.6 with a fresh bundle; returns the GAP of the session that left.
    public func resetSession(_ contact: Data) async throws -> Int {
        let bundle = try await fetchBundle(contact)
        return try client.startSession(contact, bundle: bundle)
    }

    /// The bundle of a contact, fetched again after a reconnect until an answer.
    ///
    /// - Throws: `RefusedError` when the relay refused the FetchBundle with a Stop.
    public func fetchBundle(_ contact: Data) async throws -> PrekeyBundle {
        while true {
            try Task.checkCancellation()
            try await waitUntilReady()
            var frame = Sotto_ClientFrame()
            frame.fetchBundle.identity = contact
            let request = Request(frame: frame)
            request.fetches = true
            guard await self.request(request) else {
                continue
            }
            do {
                return try await withCheckedThrowingContinuation { waiter in
                    if let outcome = request.outcome {
                        waiter.resume(with: outcome)
                    } else {
                        request.waiter = waiter
                    }
                }
            } catch is ConnectionLost {
                continue
            }
        }
    }

    // MARK: One connection

    /// One connection from the dial to its end; true when the relay sent LoggedIn.
    private func serveConnection() async throws -> Bool {
        let socket: any RelaySocket
        do {
            socket = try await dialer.dial(url)
        } catch {
            return false
        }
        dialed = socket
        var loggedIn = false
        var stopRun: StopRun?
        do {
            let loggedInFrame = try await logIn(socket)
            loggedIn = true
            try await afterLogin(loggedInFrame)
            try await serve(socket)
        } catch let violation as Violation {
            await socket.close(code: violation.code)
        } catch SocketError.tooBig {
            await socket.close(code: Self.frameTooBig)
        } catch SocketError.closed(let code) {
            if !stopping, let code, Self.closeAction(code) == .stop {
                stopRun = StopRun(reason: "the relay closed the connection with \(code)")
            }
        } catch let stop as StopRun {
            stopRun = stop
        } catch {
            try endConnection()
            throw error
        }
        try endConnection()
        if let stopRun {
            throw stopRun
        }
        return loggedIn
    }

    /// Hello, Login and LoggedIn of section 8.1; returns the LoggedIn.
    private func logIn(_ socket: any RelaySocket) async throws -> Sotto_LoggedIn {
        let hello: Sotto_Hello
        do {
            guard case .hello(let first) = try await Frames.readServerFrame(receiveBinary(socket)) else {
                throw Violation(code: Self.protocolViolation)
            }
            hello = first
        } catch FrameError.unknownVersion(let version) {
            await socket.close(code: Self.normalClosure)
            throw StopRun(reason: "the relay speaks protocol version \(version)")
        } catch is FrameError {
            throw Violation(code: Self.protocolViolation)
        }

        var login = Sotto_ClientFrame()
        login.login = try client.signLogin(serverName: serverName, serverNonce: hello.nonce)
        try await socket.send(login.serializedBytes())
        guard case .loggedIn(let loggedIn) = try await receiveFrame(socket) else {
            throw Violation(code: Self.protocolViolation)
        }
        self.socket = socket
        blobMaxBytes = Int(loggedIn.blobMaxBytes)
        return loggedIn
    }

    /// The three steps of section 23.3, then the transfers of section 33.4.
    private func afterLogin(_ loggedIn: Sotto_LoggedIn) async throws {
        await sendBlobDeletions()
        if let upload = try client.prepareUpload(oneTimePrekeyCount: Int(loggedIn.oneTimePrekeyCount)) {
            let request = Request(frame: Self.uploadFrame(upload))
            request.upload = upload
            await self.request(request)
        }
        var sent: Set<Data> = []
        // Again until no row is new: a text committed while a Send was on its way is sent
        // here, and one committed after the last look finds the transport ready.
        while case let rows = try client.outbox().filter({ !sent.contains($0.messageID) }), !rows.isEmpty {
            for outgoing in rows {
                sent.insert(outgoing.messageID)
                await request(Request(frame: Self.sendFrame(outgoing)))
            }
        }
        try client.forgetSeenIDs()
        ready = true
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume() }
        eventSink.yield(.connected)
        try endTransfersBeyondTheRelay()
        startTransfers()
    }

    private func serve(_ socket: any RelaySocket) async throws {
        while true {
            switch try await receiveFrame(socket) {
            case .deliver(let deliver):
                try await self.deliver(socket, deliver)
            case .stored(let stored):
                if take(.send, stored.messageID) != nil, let file = try client.confirmStored(stored.messageID) {
                    eventSink.yield(.file(Self.update(file, .sent)))
                }
            case .bundleStored:
                if let upload = take(.upload, Data())?.upload {
                    try client.confirmUpload(upload)
                }
            case .bundle(let bundle):
                take(.fetch, bundle.identity)?.settle(.success(Self.bundle(of: bundle)))
            case .blobStored(let stored):
                take(.blobWrite, stored.blobID)?.settleBlob(.success(.stored(stored)))
            case .blobData(let data):
                // A FetchBlob gets its answer in the order of the frames (section 7.4), so a
                // BlobData that names another blob answers the oldest one.
                let request = take(.blobRead, data.blobID + data.uploader) ?? takeOldest(.blobRead)
                request?.settleBlob(.success(.data(data)))
            case .error(let error):
                try await refused(socket, error)
            case .hello, .loggedIn:
                throw Violation(code: Self.protocolViolation)
            }
        }
    }

    private func deliver(_ socket: any RelaySocket, _ deliver: Sotto_Deliver) async throws {
        let received = try client.receive(
            Delivered(sender: deliver.sender, messageID: deliver.messageID, payload: deliver.payload)
        )
        if received.ack {
            var reference = Sotto_MessageRef()
            reference.messageID = deliver.messageID
            reference.sender = deliver.sender
            var ack = Sotto_ClientFrame()
            ack.ack.messages = [reference]
            try await socket.send(ack.serializedBytes())
        }
        eventSink.yield(.incoming(sender: deliver.sender, received: received))
        if let attachment = received.attachment, receivedFiles != nil, autoDownload(attachment),
            let file = try client.store.files().last(where: {
                $0.incoming && $0.contact == deliver.sender && $0.messageID == deliver.messageID
            })
        {
            try client.beginDownload(file.position)
            startTransfers()
        }
    }

    private func refused(_ socket: any RelaySocket, _ error: Sotto_Error) async throws {
        let (kind, reference): (Request.Kind, Data) =
            if !error.messageID.isEmpty { (.send, error.messageID) }
            else if !error.blobID.isEmpty && !error.identity.isEmpty { (.blobRead, error.blobID + error.identity) }
            else if !error.blobID.isEmpty { (.blobWrite, error.blobID) }
            else if !error.identity.isEmpty { (.fetch, error.identity) }
            else { (.upload, Data()) }
        guard let request = first(kind, reference) else {
            return
        }

        let code = error.code.rawValue
        if Self.errorAction(code) == .backOff {
            request.holdsOthers = Self.holdingCodes.contains(code)
            backOff(socket, request)
            return
        }

        requests.removeAll { $0 === request }
        answered(request)
        let result = Self.errorName(code)
        if request.fetches {
            request.settle(.failure(RefusedError(result: result)))
        } else if request.asksBlob {
            request.settleBlob(.success(.refused(error)))
        } else if request.upload != nil {
            eventSink.yield(.refused(result: result, contact: nil))
        } else {
            let file = try client.dropRefusedSend(reference, result: result)
            eventSink.yield(.refused(result: result, contact: request.frame.send.recipient))
            if let file {
                eventSink.yield(.file(Self.update(file, .notSent, result: result)))
                await sendBlobDeletions()
            }
        }
    }

    private func backOff(_ socket: any RelaySocket, _ request: Request) {
        request.refusals += 1
        request.waiting = true
        if request.holdsOthers {
            holders += 1
        }
        let wait = Self.backOffSeconds(request.refusals, jitter: jitter)
        backOffs.append(Task { await self.sendAgain(socket, request, after: wait) })
    }

    private func sendAgain(_ socket: any RelaySocket, _ request: Request, after wait: Double) async {
        do {
            try await sleep(wait)
        } catch {
            // Cancelled with its connection, whose end already settled the request.
            return
        }
        request.waiting = false
        request.sequence = nextSequence()
        let sentOn = generation
        if let data = try? request.frame.serializedBytes() as Data {
            await sendInOrder(socket, data)
        }
        guard sentOn == generation else {
            return
        }
        if request.holdsOthers {
            request.holdsOthers = false
            holders -= 1
            if holders == 0 {
                unblock()
            }
        }
    }

    /// Sends a request on the live connection; false when there is none.
    @discardableResult
    private func request(_ request: Request) async -> Bool {
        if holders > 0 {
            await withCheckedContinuation { unblockWaiters.append($0) }
        }
        guard let socket else {
            return false
        }
        // Listed before it leaves, so that its answer always finds it.
        request.sequence = nextSequence()
        requests.append(request)
        if let data = try? request.frame.serializedBytes() as Data {
            await sendInOrder(socket, data)
        }
        return true
    }

    /// Sends after every frame handed over before it, so that frames leave in the order the
    /// actor sent them: the relay handles them in that order (section 7.4), which the
    /// confirmation of a DeleteBlob relies on.
    private func sendInOrder(_ socket: any RelaySocket, _ data: Data) async {
        let previous = sendTail
        let sending = Task {
            await previous?.value
            try? await socket.send(data)
        }
        sendTail = sending
        await sending.value
    }

    private func first(_ kind: Request.Kind, _ key: Data) -> Request? {
        requests.first { $0.kind == kind && $0.key == key && !$0.waiting }
    }

    /// Removes the request that an answer matches; nil means the answer is ignored.
    private func take(_ kind: Request.Kind, _ key: Data) -> Request? {
        let request = first(kind, key)
        if let request {
            requests.removeAll { $0 === request }
            answered(request)
        }
        return request
    }

    private func takeOldest(_ kind: Request.Kind) -> Request? {
        guard let request = requests.first(where: { $0.kind == kind && !$0.waiting }) else {
            return nil
        }
        requests.removeAll { $0 === request }
        answered(request)
        return request
    }

    private func nextSequence() -> Int {
        sequence += 1
        return sequence
    }

    /// Forgets the DeleteBlob frames that left before the request: the relay handled them,
    /// as it handles the frames of a connection in order (section 33.2).
    private func answered(_ request: Request) {
        for (deletion, sentAfter) in deletionsSent where request.sequence > sentAfter {
            deletionsSent[deletion] = nil
            try? client.confirmBlobDeletion(uploader: deletion.uploader, blobID: deletion.blobID)
        }
    }

    private func waitUntilReady() async throws {
        if stopping {
            throw CancellationError()
        }
        if !ready {
            try await withCheckedThrowingContinuation { readyWaiters.append($0) }
        }
    }

    private func unblock() {
        let waiters = unblockWaiters
        unblockWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// What sections 21.4 and 23.5 ask when a connection ends with requests open.
    private func endConnection() throws {
        backOffs.forEach { $0.cancel() }
        backOffs = []
        transfers.values.forEach { $0.task.cancel() }
        transfers = [:]
        deletionsSent = [:]
        generation += 1
        sendTail = nil
        let open = requests
        requests = []
        socket = nil
        dialed = nil
        ready = false
        holders = 0
        unblock()
        for request in open {
            if request.fetches {
                request.settle(.failure(ConnectionLost()))
            }
            request.settleBlob(.failure(ConnectionLost()))
        }
        for request in open {
            if let upload = request.upload, request.waiting {
                try client.dropRefusedUpload(upload)
            }
        }
    }

    // MARK: Files (part 3)

    /// Sends the saved DeleteBlob frames that this connection has not sent; none to a relay
    /// without blob frames (section 30.1).
    private func sendBlobDeletions() async {
        guard let socket, blobMaxBytes > 0, let deletions = try? client.blobDeletions() else {
            return
        }
        let sentOn = generation
        for deletion in deletions where sentOn == generation {
            let key = BlobKey(uploader: deletion.uploader, blobID: deletion.blobID)
            guard deletionsSent[key] == nil else {
                continue
            }
            deletionsSent[key] = sequence
            var frame = Sotto_ClientFrame()
            frame.deleteBlob.blobID = deletion.blobID
            frame.deleteBlob.uploader = deletion.uploader
            if let data = try? frame.serializedBytes() as Data {
                await sendInOrder(socket, data)
            }
        }
    }

    /// The last row of the table of section 33.4, after a LoggedIn.
    private func endTransfersBeyondTheRelay() throws {
        for upload in try client.uploads() {
            let result: FileError? = blobMaxBytes == 0 ? .filesUnsupported : upload.length > blobMaxBytes ? .fileTooLarge : nil
            if let result {
                try client.giveUpUpload(upload, result: result.result)
                report(upload, .notSent, result: result.result)
            }
        }
        if blobMaxBytes == 0, receivedFiles != nil {
            let result = FileError.filesUnsupported.result
            for file in try client.downloads() where file.state == .receiving {
                eventSink.yield(.file(Self.update(file, try client.failDownload(file.position, result: result), result: result)))
            }
        }
    }

    /// Starts a task for every upload and download of the store that has none.
    private func startTransfers() {
        guard ready, blobMaxBytes > 0 else {
            return
        }
        for upload in (try? client.uploads()) ?? [] {
            track(.upload(upload.blobID)) { try await $0.upload(upload) }
        }
        guard let folder = receivedFiles else {
            return
        }
        for file in (try? client.downloads()) ?? [] where file.state == .receiving {
            track(.download(file.position)) { try await $0.download(file, into: folder) }
        }
    }

    private func track(_ key: TransferKey, _ body: @escaping @Sendable (isolated Transport) async throws -> Void) {
        guard transfers[key] == nil else {
            return
        }
        transferCount += 1
        let id = transferCount
        let task = Task {
            do {
                try await body(self)
            } catch is ConnectionLost {
            } catch is CancellationError {
            } catch {
                eventSink.yield(.transferFailed(reason: "\(error)"))
            }
            if transfers[key]?.id == id {
                transfers[key] = nil
            }
        }
        transfers[key] = (id, task)
    }

    /// Steps 3 to 5 of section 33.2. A connection that ends cancels the task, and the next
    /// login starts it again from the stored length (section 33.4).
    private func upload(_ upload: UploadRow) async throws {
        var start = Sotto_ClientFrame()
        start.startBlob.blobID = upload.blobID
        start.startBlob.recipient = upload.contact
        start.startBlob.length = UInt32(upload.length)
        var reply = try await askBlob(start)
        var sentAPiece = false
        while true {
            switch reply {
            case .refused(let error):
                if sentAPiece && error.code == .notFound {
                    sentAPiece = false
                    reply = try await askBlob(start)
                    continue
                }
                try await notSent(upload, Self.errorName(error.code.rawValue))
                return
            case .stored(let stored):
                let length = Int(stored.storedLength)
                guard length <= upload.length else {
                    try await notSent(upload, CryptoError.badBlob.result)
                    return
                }
                guard try client.hasUpload(upload.blobID) else {
                    return
                }
                report(upload, .sending, done: length)
                if length == upload.length {
                    try await sendAttachment(upload)
                    return
                }
                var put = Sotto_ClientFrame()
                put.putBlob.blobID = upload.blobID
                put.putBlob.offset = UInt32(length)
                put.putBlob.data = try client.readUpload(upload.blobID, offset: length, length: Frames.blobChunkBytes)
                reply = try await askBlob(put)
                sentAPiece = true
            case .data:
                throw Violation(code: Self.protocolViolation)
            }
        }
    }

    /// Step 5 of section 33.2: the message of the file, after START when needed.
    private func sendAttachment(_ upload: UploadRow) async throws {
        let outgoing: Outgoing
        do {
            var bundle: PrekeyBundle?
            if try !client.hasSession(upload.contact) {
                bundle = try await fetchBundle(upload.contact)
                try Task.checkCancellation()
            }
            outgoing = try client.sendAttachment(upload, bundle: bundle)
        } catch let error as RefusedError {
            return try await notSent(upload, error.result)
        } catch let error as CryptoError {
            return try await notSent(upload, error.result)
        } catch let error as SessionError {
            return try await notSent(upload, error.result)
        }
        await request(Request(frame: Self.sendFrame(outgoing)))
    }

    private func notSent(_ upload: UploadRow, _ result: String) async throws {
        try client.giveUpUpload(upload, result: result)
        report(upload, .notSent, result: result)
        await sendBlobDeletions()
    }

    /// Steps 2 to 6 of section 33.3 from the bytes the store holds.
    private func download(_ file: FileRow, into folder: URL) async throws {
        let attachment = file.attachment
        let length = Blob.blobLength(Int(attachment.size))
        var held = file.held
        guard try client.store.file(file.position)?.state == .receiving else {
            return
        }
        try client.beginDownload(file.position)
        while held < length {
            guard try client.store.file(file.position)?.state == .receiving else {
                return
            }
            let asked = min(Frames.blobChunkBytes, length - held)
            var fetch = Sotto_ClientFrame()
            fetch.fetchBlob.blobID = attachment.blobID
            fetch.fetchBlob.uploader = file.contact
            fetch.fetchBlob.offset = UInt32(held)
            fetch.fetchBlob.length = UInt32(asked)
            let reply = try await askBlob(fetch)
            guard try client.store.file(file.position) != nil else {
                return
            }
            switch reply {
            case .refused:
                return try await notReceived(file, FileError.blobGone.result)
            case .data(let data):
                let isAnotherRange = data.offset != held || data.blobID != attachment.blobID || data.uploader != file.contact
                guard !isAnotherRange, data.data.count == asked else {
                    return try await notReceived(file, CryptoError.badBlob.result)
                }
                try client.saveDownloadPiece(file.position, data.data)
                held += asked
                eventSink.yield(.file(Self.update(file, .receiving, done: held, total: length)))
            case .stored:
                throw Violation(code: Self.protocolViolation)
            }
        }

        let path: URL
        do {
            path = try client.finishDownload(file.position, folder: folder)
        } catch CryptoError.badBlob {
            return try await notReceived(file, CryptoError.badBlob.result)
        } catch StoreError.system(let failed, let code) {
            eventSink.yield(.transferFailed(reason: "cannot write \(failed): \(String(cString: strerror(code)))"))
            return
        }
        eventSink.yield(.file(Self.update(file, .received, path: path)))
        await sendBlobDeletions()
    }

    private func notReceived(_ file: FileRow, _ result: String) async throws {
        let state = try client.failDownload(file.position, result: result)
        eventSink.yield(.file(Self.update(file, state, result: result)))
        await sendBlobDeletions()
    }

    /// Sends a blob frame and waits for its answer; an Error with an action Back off is
    /// handled by the frame being sent again, so only a Stop comes back as `.refused`.
    ///
    /// - Throws: `ConnectionLost` when there is no connection or it ended before the answer.
    private func askBlob(_ frame: Sotto_ClientFrame) async throws -> BlobReply {
        let request = Request(frame: frame)
        request.asksBlob = true
        guard await self.request(request) else {
            throw ConnectionLost()
        }
        let reply = try await withCheckedThrowingContinuation { request.waitBlob($0) }
        try Task.checkCancellation()
        return reply
    }

    private func report(_ upload: UploadRow, _ state: FileState, done: Int = 0, result: String? = nil) {
        eventSink.yield(.file(FileUpdate(
            contact: upload.contact, blobID: upload.blobID, messageID: upload.messageID,
            fileName: upload.attachment.fileName, state: state, done: done, total: upload.length, result: result
        )))
    }

    static func update(_ file: FileRow, _ state: FileState, done: Int = 0, total: Int = 0, result: String? = nil, path: URL? = nil) -> FileUpdate {
        FileUpdate(
            contact: file.contact, blobID: file.attachment.blobID, messageID: file.messageID,
            fileName: file.attachment.fileName, state: state, done: done, total: total, result: result, path: path
        )
    }

    /// The longest start of `name` that is at most `limit` bytes of UTF-8.
    static func cut(_ name: String, to limit: Int) -> String {
        var cut = ""
        for scalar in name.unicodeScalars where cut.utf8.count + String(scalar).utf8.count <= limit {
            cut.unicodeScalars.append(scalar)
        }
        return cut
    }

    private func receiveBinary(_ socket: any RelaySocket) async throws -> Data {
        switch try await socket.receive() {
        case .binary(let data): data
        case .text: throw Violation(code: Self.textFrame)
        }
    }

    /// The next frame after the Hello, where a second Hello is a malformed frame too.
    private func receiveFrame(_ socket: any RelaySocket) async throws -> Sotto_ServerFrame.OneOf_Frame {
        do {
            return try await Frames.readServerFrame(receiveBinary(socket))
        } catch is FrameError {
            throw Violation(code: Self.protocolViolation)
        }
    }
}

/// A frame that waits for its answer on the connection that sent it.
private final class Request {
    enum Kind {
        case send, fetch, upload, blobWrite, blobRead
    }

    let frame: Sotto_ClientFrame
    var upload: PrekeyUpload?
    var fetches = false
    var asksBlob = false
    var sequence = 0
    var refusals = 0
    var waiting = false
    var holdsOthers = false
    var outcome: Result<PrekeyBundle, Error>?
    var waiter: CheckedContinuation<PrekeyBundle, Error>?
    var blobOutcome: Result<BlobReply, Error>?
    var blobWaiter: CheckedContinuation<BlobReply, Error>?

    init(frame: Sotto_ClientFrame) {
        self.frame = frame
    }

    var kind: Kind {
        switch frame.frame {
        case .send: .send
        case .fetchBundle: .fetch
        case .startBlob, .putBlob: .blobWrite
        case .fetchBlob: .blobRead
        default: .upload
        }
    }

    var key: Data {
        switch frame.frame {
        case .send(let send): send.messageID
        case .fetchBundle(let fetch): fetch.identity
        case .startBlob(let start): start.blobID
        case .putBlob(let put): put.blobID
        case .fetchBlob(let fetch): fetch.blobID + fetch.uploader
        default: Data()
        }
    }

    /// Settles a fetch once; a caller that waits gets the outcome, a later one finds it.
    func settle(_ result: Result<PrekeyBundle, Error>) {
        guard outcome == nil else {
            return
        }
        outcome = result
        waiter?.resume(with: result)
        waiter = nil
    }

    /// Settles the answer of a blob frame once, like `settle`.
    func settleBlob(_ result: Result<BlobReply, Error>) {
        guard asksBlob, blobOutcome == nil else {
            return
        }
        blobOutcome = result
        blobWaiter?.resume(with: result)
        blobWaiter = nil
    }

    func waitBlob(_ waiter: CheckedContinuation<BlobReply, Error>) {
        if let blobOutcome {
            waiter.resume(with: blobOutcome)
        } else {
            blobWaiter = waiter
        }
    }
}

/// The answer to a StartBlob, a PutBlob or a FetchBlob; `.refused` is an Error whose action
/// is Stop.
private enum BlobReply {
    case stored(Sotto_BlobStored)
    case data(Sotto_BlobData)
    case refused(Sotto_Error)
}

private enum TransferKey: Hashable {
    case upload(Data)
    case download(Int64)
}

private struct BlobKey: Hashable {
    let uploader: Data
    let blobID: Data
}

private struct Violation: Error {
    let code: Int
}

private struct StopRun: Error {
    let reason: String
}

private struct ConnectionLost: Error {}
