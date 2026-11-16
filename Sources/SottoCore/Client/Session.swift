import Foundation
import SwiftProtobuf

/// A named local result of the session rules (sections 20.2 and 24.2).
public enum SessionError: Error, Equatable, Sendable {
    case notAContact
    case duplicate
    case replayedInitial
    case noSession
    case unknownSignedPrekey
    case unknownOneTimePrekey

    public var result: String {
        switch self {
        case .notAContact: "NOT_A_CONTACT"
        case .duplicate: "DUPLICATE"
        case .replayedInitial: "REPLAYED_INITIAL"
        case .noSession: "NO_SESSION"
        case .unknownSignedPrekey: "UNKNOWN_SIGNED_PREKEY"
        case .unknownOneTimePrekey: "UNKNOWN_ONE_TIME_PREKEY"
        }
    }
}

/// The id of the client's own identity is never a contact (section 16.1).
public struct OwnIdentityError: Error, Equatable, Sendable {
    public init() {}
}

/// A Deliver of section 7.14, its lengths checked by the parser of the frame.
public struct Delivered: Equatable, Sendable {
    public var sender: Data
    public var messageID: Data
    public var payload: Data

    public init(sender: Data, messageID: Data, payload: Data) {
        self.sender = sender
        self.messageID = messageID
        self.payload = payload
    }
}

/// What a Deliver gives: a text to show, or the named result of section 24.2. `missing` is
/// the GAP of section 20.3: the skipped keys that this message removed without use.
public struct Received: Equatable, Sendable {
    public var ack: Bool
    public var text: String?
    public var result: String?
    public var missing: Int

    public init(ack: Bool, text: String?, result: String?, missing: Int = 0) {
        self.ack = ack
        self.text = text
        self.result = result
        self.missing = missing
    }
}

/// The fields of a Send; a repeated Send carries them unchanged (section 22.2).
public struct Outgoing: Equatable, Sendable {
    public var messageID: Data
    public var recipient: Data
    public var payload: Data

    public init(messageID: Data, recipient: Data, payload: Data) {
        self.messageID = messageID
        self.recipient = recipient
        self.payload = payload
    }
}

/// The keys of an UploadBundle (section 21.4), saved before they are handed out.
public struct PrekeyUpload: Sendable {
    public var identityDHKey: Data
    public var identityDHSignature: Data
    public var signedPrekey: SignedPrekey
    public var oneTimePrekeys: [OneTimePrekey]
}

/// The session layer of one identity over its store: sections 16.6 to 16.8, 20, 21 and
/// 22.2 of docs/protocol.md, no network. `receive` and `sendText` commit what they change
/// before they answer.
public final class Client {
    public typealias RandomBytes = (Int) -> Data
    public typealias Clock = () -> TimeInterval

    public static let seenIDSeconds: Int64 = 3_196_800
    public static let signedPrekeyRotationSeconds: Int64 = 604_800
    public static let signedPrekeyGraceSeconds: Int64 = 3_196_800
    public static let oneTimePrekeyRefillBelow = 50
    public static let oneTimePrekeyCap = 100
    public static let oneTimePrekeyHeldMax = 1000

    public let store: ClientStore
    public let identityKey: Data
    public let identityDHKey: Data
    private let identity: StoredIdentity
    private let randomBytes: RandomBytes
    private let clock: Clock

    /// Opens the session layer over a store; an empty store gets a new identity.
    public init(
        store: ClientStore,
        randomBytes: @escaping RandomBytes = Client.systemRandomBytes,
        clock: @escaping Clock = { Date().timeIntervalSince1970 }
    ) throws {
        self.store = store
        self.randomBytes = randomBytes
        self.clock = clock
        if let saved = try store.identity() {
            identity = saved
        } else {
            let made = StoredIdentity(seed: randomBytes(Identity.keyLength), identityDHPrivateKey: randomBytes(Identity.keyLength))
            try store.transaction { try store.saveIdentity(made) }
            identity = made
        }
        identityKey = try Identity.deriveIdentityKey(seed: identity.seed)
        identityDHKey = try Identity.deriveX25519PublicKey(identity.identityDHPrivateKey)
    }

    public static func systemRandomBytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// The clock in whole seconds (section 21.1).
    public func now() -> Int64 {
        Int64(clock())
    }

    /// The Login of section 8.1 for the nonce of a Hello and the server name of 8.2.
    public func signLogin(serverName: String, serverNonce: Data) throws -> Sotto_Login {
        let clientNonce = randomBytes(Identity.nonceLength)
        var login = Sotto_Login()
        login.identityKey = identityKey
        login.clientNonce = clientNonce
        login.signature = try Identity.signLogin(
            seed: identity.seed,
            serverName: serverName,
            serverNonce: serverNonce,
            clientNonce: clientNonce
        )
        return login
    }

    /// Makes a new signed prekey and `oneTimeCount` one-time prekeys and saves them.
    public func makePrekeys(oneTimeCount: Int) throws -> PrekeyUpload {
        let now = now()
        let oneTimePrekeys = try store.transaction {
            _ = try store.addSignedPrekey(randomBytes(Identity.keyLength), madeAt: now)
            return try addOneTimePrekeys(oneTimeCount)
        }
        return try upload(newestSignedPrekey(), oneTimePrekeys)
    }

    /// Step 1 of section 21.2, after every LoggedIn and at every start before a dial.
    public func deleteExpiredPrekeys() throws {
        let replacedAtOrBefore = now() - Self.signedPrekeyGraceSeconds
        try store.transaction { try store.deleteSignedPrekeys(replacedAtOrBefore: replacedAtOrBefore) }
    }

    /// Steps 1 and 2 of section 21.2 and the refill of section 21.3, after a LoggedIn with
    /// the count it reported. Returns the one UploadBundle of the login, every key of it
    /// saved first, or nil when the relay confirmed the newest signed prekey and no
    /// one-time prekey was made.
    public func prepareUpload(oneTimePrekeyCount: Int) throws -> PrekeyUpload? {
        try deleteExpiredPrekeys()
        let now = now()
        var refill = 0
        if oneTimePrekeyCount < Self.oneTimePrekeyRefillBelow {
            refill = Self.oneTimePrekeyCap - oneTimePrekeyCount
        }

        let oneTimePrekeys = try store.transaction {
            let newest = try store.newestSignedPrekey()
            if newest == nil || now - newest!.madeAt >= Self.signedPrekeyRotationSeconds {
                _ = try store.addSignedPrekey(randomBytes(Identity.keyLength), madeAt: now)
            }
            return try addOneTimePrekeys(refill)
        }

        let newest = try newestSignedPrekey()
        if newest.confirmed && oneTimePrekeys.isEmpty {
            return nil
        }
        return try upload(newest, oneTimePrekeys)
    }

    /// Records the BundleStored of an UploadBundle: the relay holds its signed prekey.
    public func confirmUpload(_ upload: PrekeyUpload) throws {
        try store.transaction { try store.confirmSignedPrekey(upload.signedPrekey.id) }
    }

    /// Deletes the one-time prekeys of an UploadBundle that waited in Back off when its
    /// connection ended: the relay holds none of them (section 21.4).
    public func dropRefusedUpload(_ upload: PrekeyUpload) throws {
        try store.transaction {
            for oneTimePrekey in upload.oneTimePrekeys {
                try store.deleteOneTimePrekey(oneTimePrekey.id)
            }
        }
    }

    /// Deletes the seen ids older than `seenIDSeconds`, at a login (section 20.4).
    public func forgetSeenIDs() throws {
        let seenAtOrBefore = now() - Self.seenIDSeconds
        try store.transaction { try store.deleteSeenIDs(seenAtOrBefore: seenAtOrBefore) }
    }

    /// Adds the identity of a user id under a local name and returns its identity key; a
    /// contact that exists keeps its name.
    @discardableResult
    public func addContact(_ userID: String, name: String? = nil) throws -> Data {
        let contact = try Identity.decodeUserID(userID)
        guard contact != identityKey else {
            throw OwnIdentityError()
        }
        try store.transaction { try store.addContact(contact, name: name) }
        return contact
    }

    /// Deletes a contact with its sessions; its seen ids and records stay (section 20.6).
    public func removeContact(_ contact: Data) throws {
        try store.transaction { try store.removeContact(contact) }
    }

    public func hasSession(_ contact: Data) throws -> Bool {
        try !store.sessions(contact).isEmpty
    }

    /// START of section 20.3: section 16.6 with a bundle fetched for the contact, for L1
    /// without a session and for L2, the reset. Returns the GAP: the skipped keys of a
    /// session that left the list.
    @discardableResult
    public func startSession(_ contact: Data, bundle: PrekeyBundle) throws -> Int {
        guard try store.isContact(contact) else {
            throw SessionError.notAContact
        }
        let pin = try store.pin(contact)
        let ephemeralPrivateKey = randomBytes(Identity.keyLength)
        let agreement = try X3DH.initiate(
            bundle: bundle,
            identityKey: identityKey,
            identityDHPrivateKey: identity.identityDHPrivateKey,
            ephemeralPrivateKey: ephemeralPrivateKey,
            contactIdentityKey: contact,
            pinnedIdentityDHKey: pin
        )
        let state = try Ratchet.initInitiator(
            sharedSecret: agreement.sharedSecret,
            signedPrekey: bundle.signedPrekey.key,
            ratchetPrivateKey: randomBytes(Identity.keyLength)
        )

        var initialHeader = Sotto_InitialHeader()
        initialHeader.identityDhKey = identityDHKey
        initialHeader.identityDhSignature = try identityDHSignature()
        initialHeader.ephemeralKey = try Identity.deriveX25519PublicKey(ephemeralPrivateKey)
        initialHeader.signedPrekeyID = bundle.signedPrekey.id
        if let oneTimePrekey = bundle.oneTimePrekey {
            initialHeader.oneTimePrekeyID = oneTimePrekey.id
        }
        let serializedHeader: Data = try initialHeader.serializedBytes()

        return try store.transaction {
            _ = try store.addSession(
                contact,
                associatedData: agreement.associatedData,
                state: state,
                initialHeader: serializedHeader
            )
            let missing = try store.dropSessionsBehind(contact)
            if pin == nil {
                try store.setPin(contact, identityDHKey: bundle.identityDHKey)
            }
            return missing
        }
    }

    /// L1 of section 20.2: the bytes of a Send, committed to the outbox first. A contact
    /// without a session needs a fetched bundle. `pending` names a row of the pending texts
    /// that the same commit removes.
    public func sendText(_ contact: Data, _ text: String, bundle: PrekeyBundle? = nil, pending: Int64? = nil) throws -> Outgoing {
        try send(contact, paddedPlaintext: Envelope.encodeText(text), text: text, bundle: bundle, pending: pending)
    }

    func send(_ contact: Data, paddedPlaintext: Data, text: String, bundle: PrekeyBundle?, pending: Int64? = nil) throws -> Outgoing {
        guard try store.isContact(contact) else {
            throw SessionError.notAContact
        }
        if try !hasSession(contact) {
            guard let bundle else {
                throw InvalidInputError(message: "a contact without a session needs a fetched bundle")
            }
            try startSession(contact, bundle: bundle)
        }

        let session = try store.sessions(contact)[0]
        let messageID = randomBytes(Frames.messageIDLength)
        let encrypted = try Ratchet.encrypt(
            session.state,
            paddedPlaintext: paddedPlaintext,
            associatedData: session.associatedData + messageID,
            nonce: randomBytes(Ratchet.messageNonceLength)
        )
        var envelope = Sotto_PeerMessage()
        envelope.version = Envelope.version
        envelope.header = encrypted.header
        envelope.ciphertext = encrypted.ciphertext
        if let initialHeader = session.initialHeader {
            envelope.initialHeader = try Sotto_InitialHeader(serializedBytes: initialHeader)
        }
        let outgoing = Outgoing(messageID: messageID, recipient: contact, payload: try envelope.serializedBytes())

        try store.transaction {
            try store.advanceSession(session.sessionID, state: encrypted.state)
            try store.addToOutbox(OutboxRow(messageID: messageID, recipient: contact, payload: outgoing.payload))
            try store.logMessage(contact, direction: .outgoing, messageID: messageID, text: text)
            if let pending {
                try store.removePending(pending)
            }
        }
        return outgoing
    }

    /// The Sends that the relay has not confirmed, to be sent again as they are.
    public func outbox() throws -> [Outgoing] {
        try store.outbox().map { Outgoing(messageID: $0.messageID, recipient: $0.recipient, payload: $0.payload) }
    }

    /// Removes the outbox row of a Send that the relay answered with Stored.
    public func confirmStored(_ messageID: Data) throws {
        try store.transaction { try store.removeFromOutbox(messageID) }
    }

    /// Removes the outbox row of a Send that the relay refused with an action Stop and notes
    /// the result next to the logged message.
    public func dropRefusedSend(_ messageID: Data, result: String) throws {
        try store.transaction {
            try store.removeFromOutbox(messageID)
            try store.addRefusal(messageID, result: result)
        }
    }

    /// Runs the row of section 20.2 that a Deliver falls into. Every named result is
    /// acked; an accepted message only after its commit, so any other error leaves the
    /// store as it was and gives no ack.
    public func receive(_ delivered: Delivered) throws -> Received {
        do {
            return try receiveOrThrow(delivered)
        } catch let error as SessionError {
            return Received(ack: true, text: nil, result: error.result)
        } catch let error as CryptoError {
            return Received(ack: true, text: nil, result: error.result)
        } catch let error as EnvelopeError {
            return Received(ack: true, text: nil, result: error.result)
        }
    }

    private func receiveOrThrow(_ delivered: Delivered) throws -> Received {
        guard try store.isContact(delivered.sender) else {
            throw SessionError.notAContact
        }
        if try store.isSeen(sender: delivered.sender, messageID: delivered.messageID) {
            throw SessionError.duplicate
        }

        let envelope = try Envelope.parse(delivered.payload)
        if envelope.hasInitialHeader {
            return try receiveInitial(delivered, envelope)
        }
        return try receiveOnList(delivered, envelope)
    }

    /// I3 to I8 of section 20.2.
    private func receiveInitial(_ delivered: Delivered, _ envelope: Sotto_PeerMessage) throws -> Received {
        let initialHeader = envelope.initialHeader
        let pin = try store.pin(delivered.sender)
        try Self.checkInitialHeader(delivered.sender, initialHeader, pin)

        guard let record = try store.record(sender: delivered.sender, ephemeralKey: initialHeader.ephemeralKey) else {
            return try acceptNew(delivered, envelope, pin)
        }
        guard let session = try store.session(record.sessionID) else {
            throw SessionError.replayedInitial
        }
        return try accept(delivered, session, decrypt(session.state, session.associatedData, delivered, envelope))
    }

    /// I9 and I10 of section 20.2.
    private func receiveOnList(_ delivered: Delivered, _ envelope: Sotto_PeerMessage) throws -> Received {
        let sessions = try store.sessions(delivered.sender)
        if sessions.isEmpty {
            throw SessionError.noSession
        }
        for session in sessions {
            let decrypted: Decrypted
            do {
                decrypted = try decrypt(session.state, session.associatedData, delivered, envelope)
            } catch CryptoError.decryptFailed {
                continue
            }
            return try accept(delivered, session, decrypted)
        }
        throw CryptoError.decryptFailed
    }

    /// Steps 3 to 9 of section 16.8 and ACCEPT-NEW of section 20.3.
    private func acceptNew(_ delivered: Delivered, _ envelope: Sotto_PeerMessage, _ pin: Data?) throws -> Received {
        let initialHeader = envelope.initialHeader
        let signedPrekeyID = initialHeader.signedPrekeyID
        guard let signedPrekeyPrivateKey = try store.signedPrekey(
            signedPrekeyID, replacedAfter: now() - Self.signedPrekeyGraceSeconds
        ) else {
            throw SessionError.unknownSignedPrekey
        }

        var oneTimePrekeyID: UInt32?
        var oneTimePrekeyPrivateKey: Data?
        if initialHeader.hasOneTimePrekeyID {
            oneTimePrekeyID = initialHeader.oneTimePrekeyID
            oneTimePrekeyPrivateKey = try store.oneTimePrekey(initialHeader.oneTimePrekeyID)
            if oneTimePrekeyPrivateKey == nil {
                throw SessionError.unknownOneTimePrekey
            }
        }

        let agreement = try X3DH.respond(
            identityKey: identityKey,
            identityDHPrivateKey: identity.identityDHPrivateKey,
            signedPrekeyPrivateKey: signedPrekeyPrivateKey,
            oneTimePrekeyPrivateKey: oneTimePrekeyPrivateKey,
            senderIdentityKey: delivered.sender,
            senderIdentityDHKey: initialHeader.identityDhKey,
            senderIdentityDHSignature: initialHeader.identityDhSignature,
            ephemeralKey: initialHeader.ephemeralKey,
            pinnedIdentityDHKey: pin
        )
        let state = try Ratchet.initResponder(
            sharedSecret: agreement.sharedSecret,
            signedPrekeyPrivateKey: signedPrekeyPrivateKey
        )
        let decrypted = try decrypt(state, agreement.associatedData, delivered, envelope)
        let (text, result) = try Self.readContent(decrypted.paddedPlaintext)

        let dropped = try store.transaction {
            let sessionID = try store.addSession(
                delivered.sender,
                associatedData: agreement.associatedData,
                state: decrypted.state,
                initialHeader: nil
            )
            try store.addRecord(
                sender: delivered.sender,
                ephemeralKey: initialHeader.ephemeralKey,
                sessionID: sessionID,
                signedPrekeyID: signedPrekeyID
            )
            let dropped = try store.dropSessionsBehind(delivered.sender)
            if let oneTimePrekeyID {
                try store.deleteOneTimePrekey(oneTimePrekeyID)
            }
            if pin == nil {
                try store.setPin(delivered.sender, identityDHKey: initialHeader.identityDhKey)
            }
            try saveReceived(delivered, text)
            return dropped
        }
        return Received(ack: true, text: text, result: result, missing: decrypted.purged + dropped)
    }

    /// ACCEPT of section 20.3.
    private func accept(_ delivered: Delivered, _ session: StoredSession, _ decrypted: Decrypted) throws -> Received {
        let (text, result) = try Self.readContent(decrypted.paddedPlaintext)
        try store.transaction {
            try store.acceptOnSession(session.sessionID, state: decrypted.state)
            try saveReceived(delivered, text)
        }
        return Received(ack: true, text: text, result: result, missing: decrypted.purged)
    }

    private func saveReceived(_ delivered: Delivered, _ text: String?) throws {
        try store.addSeenID(sender: delivered.sender, messageID: delivered.messageID, seenAt: now())
        if let text {
            try store.logMessage(delivered.sender, direction: .incoming, messageID: delivered.messageID, text: text)
        }
    }

    /// Section 17.7 on a copy of the state; any failure is DECRYPT_FAILED (section 20.2).
    private func decrypt(
        _ state: RatchetState,
        _ associatedData: Data,
        _ delivered: Delivered,
        _ envelope: Sotto_PeerMessage
    ) throws -> Decrypted {
        do {
            return try Ratchet.decrypt(
                state,
                header: envelope.header,
                ciphertext: envelope.ciphertext,
                associatedData: associatedData + delivered.messageID,
                ratchetPrivateKey: randomBytes(Identity.keyLength)
            )
        } catch is CryptoError {
            throw CryptoError.decryptFailed
        }
    }

    /// Makes `requested` one-time prekeys, first deleting those with the lowest ids that
    /// the batch would push past `oneTimePrekeyHeldMax` (section 21.3).
    private func addOneTimePrekeys(_ requested: Int) throws -> [OneTimePrekey] {
        let count = max(0, min(requested, Self.oneTimePrekeyHeldMax, Int(try store.oneTimePrekeyIDsLeft())))
        let overTheBound = try store.oneTimePrekeyCount() + count - Self.oneTimePrekeyHeldMax
        if overTheBound > 0 {
            try store.deleteLowestOneTimePrekeys(overTheBound)
        }

        var oneTimePrekeys: [OneTimePrekey] = []
        for _ in 0..<count {
            let privateKey = randomBytes(Identity.keyLength)
            guard let prekeyID = try store.addOneTimePrekey(privateKey) else {
                break
            }
            oneTimePrekeys.append(OneTimePrekey(id: prekeyID, key: try Identity.deriveX25519PublicKey(privateKey)))
        }
        return oneTimePrekeys
    }

    /// An UploadBundle of section 21.4 with the newest signed prekey.
    private func upload(_ newest: StoredSignedPrekey, _ oneTimePrekeys: [OneTimePrekey]) throws -> PrekeyUpload {
        let signedKey = try Identity.deriveX25519PublicKey(newest.privateKey)
        return PrekeyUpload(
            identityDHKey: identityDHKey,
            identityDHSignature: try identityDHSignature(),
            signedPrekey: SignedPrekey(
                id: newest.prekeyID,
                key: signedKey,
                signature: try Identity.signSignedPrekey(seed: identity.seed, signedPrekey: signedKey)
            ),
            oneTimePrekeys: oneTimePrekeys
        )
    }

    private func newestSignedPrekey() throws -> StoredSignedPrekey {
        guard let newest = try store.newestSignedPrekey() else {
            throw InvalidInputError(message: "the identity holds no signed prekey")
        }
        return newest
    }

    private func identityDHSignature() throws -> Data {
        try Identity.signIdentityDHKey(seed: identity.seed, identityDHKey: identityDHKey)
    }

    /// Steps 1 and 2 of section 16.8, before any Diffie-Hellman value.
    private static func checkInitialHeader(_ sender: Data, _ initialHeader: Sotto_InitialHeader, _ pin: Data?) throws {
        do {
            try Identity.verifyIdentityDHKey(
                identityKey: sender,
                identityDHKey: initialHeader.identityDhKey,
                signature: initialHeader.identityDhSignature
            )
        } catch CryptoError.badBundle {
            throw CryptoError.badInitialHeader
        }
        if let pin, initialHeader.identityDhKey != pin {
            throw CryptoError.identityKeyMismatch
        }
    }

    /// The text of a message that decrypted, or the result that it has none (section 20.3).
    private static func readContent(_ paddedPlaintext: Data) throws -> (text: String?, result: String?) {
        do {
            return (try Envelope.decodeText(paddedPlaintext), nil)
        } catch let error as EnvelopeError {
            return (nil, error.result)
        }
    }
}
