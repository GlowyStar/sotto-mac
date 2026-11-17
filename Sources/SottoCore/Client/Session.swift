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

/// A named local result of part 3 (section 33.6) that is not BAD_BLOB.
public enum FileError: Error, Equatable, Sendable {
    case filesUnsupported
    case fileTooLarge
    case blobGone

    public var result: String {
        switch self {
        case .filesUnsupported: "FILES_UNSUPPORTED"
        case .fileTooLarge: "FILE_TOO_LARGE"
        case .blobGone: "BLOB_GONE"
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

/// What a Deliver gives: a text or an attachment to show, a profile that replaced the
/// sender's earlier one, or the named result of section 24.2. `missing` is the GAP of
/// section 20.3: the skipped keys that this message removed without use.
public struct Received: Equatable, Sendable {
    public var ack: Bool
    public var text: String?
    public var result: String?
    public var missing: Int
    public var attachment: Sotto_Attachment?
    public var profile: Sotto_Profile?

    public init(
        ack: Bool, text: String?, result: String?, missing: Int = 0, attachment: Sotto_Attachment? = nil,
        profile: Sotto_Profile? = nil
    ) {
        self.ack = ack
        self.text = text
        self.result = result
        self.missing = missing
        self.attachment = attachment
        self.profile = profile
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

    /// Deletes a contact with its sessions and its profile; its seen ids and records stay
    /// (section 20.6).
    public func removeContact(_ contact: Data) throws {
        try store.transaction {
            try giveUpProfileUpload(contact)
            try store.removeContact(contact)
        }
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
            try oweProfileToANewSession(contact)
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
        let sealed = try seal(contact, paddedPlaintext, bundle: bundle, messageID: randomBytes(Frames.messageIDLength))
        try store.transaction {
            try commit(sealed)
            try store.logMessage(contact, direction: .outgoing, messageID: sealed.outgoing.messageID, text: text)
            if let pending {
                try store.removePending(pending)
            }
        }
        return sealed.outgoing
    }

    /// The Sends that the relay has not confirmed, to be sent again as they are.
    public func outbox() throws -> [Outgoing] {
        try store.outbox().map { Outgoing(messageID: $0.messageID, recipient: $0.recipient, payload: $0.payload) }
    }

    /// Removes the outbox row of a Send that the relay answered with Stored; a file that the
    /// message carries counts as sent (section 33.2, step 6) and is returned.
    @discardableResult
    public func confirmStored(_ messageID: Data) throws -> FileRow? {
        try store.transaction {
            try store.removeFromOutbox(messageID)
            guard let file = try store.fileOfMessage(messageID) else {
                return nil
            }
            try store.setFileState(file.position, .sent)
            return file
        }
    }

    /// Removes the outbox row of a Send that the relay refused with an action Stop and notes
    /// the result next to the logged message; a file that the message carries is not sent,
    /// and the DeleteBlob of its blob is saved (section 33.2). The file is returned.
    @discardableResult
    public func dropRefusedSend(_ messageID: Data, result: String) throws -> FileRow? {
        try store.transaction {
            try store.removeFromOutbox(messageID)
            // A profile is no logged message: its refusal has nothing to show on.
            if try store.isLoggedOutgoing(messageID) {
                try store.addRefusal(messageID, result: result)
            }
            guard let file = try store.fileOfMessage(messageID) else {
                return nil
            }
            try store.setFileState(file.position, .notSent, result: result)
            try store.addBlobDeletion(uploader: identityKey, blobID: file.attachment.blobID)
            return file
        }
    }

    // MARK: Files (part 3)

    /// The checks of section 33.1, in their order.
    ///
    /// - Throws: `SessionError.notAContact`, `FileError.filesUnsupported` or
    ///   `FileError.fileTooLarge`.
    public func checkFile(_ contact: Data, size: Int, blobMaxBytes: Int) throws {
        guard try store.isContact(contact) else {
            throw SessionError.notAContact
        }
        guard blobMaxBytes > 0 else {
            throw FileError.filesUnsupported
        }
        guard size <= Blob.maxFileBytes, Blob.blobLength(size) <= blobMaxBytes else {
            throw FileError.fileTooLarge
        }
    }

    /// Steps 1 and 2 of section 33.2: the checks, the blob and the upload, committed with
    /// the file and the logged message (its text is the caption) that the upload becomes.
    /// `localPath`, where the file was read from, is kept with the file for this client.
    ///
    /// - Throws: a check of section 33.1; `InvalidInputError` when a name, media type or
    ///   caption is beyond its limit of section 32.1.
    public func startUpload(
        _ contact: Data,
        file: Data,
        blobMaxBytes: Int,
        fileName: String = "",
        mediaType: String = "",
        caption: String = "",
        width: Int = 0,
        height: Int = 0,
        thumbnail: Data = Data(),
        localPath: String? = nil
    ) throws -> UploadRow {
        try checkFile(contact, size: file.count, blobMaxBytes: blobMaxBytes)
        var (attachment, blob) = try encryptFile(file)
        attachment.mediaType = mediaType
        attachment.fileName = fileName
        attachment.caption = caption
        attachment.width = UInt32(clamping: width)
        attachment.height = UInt32(clamping: height)
        attachment.thumbnail = thumbnail
        _ = try Envelope.encodeAttachment(attachment)

        let upload = UploadRow(
            blobID: attachment.blobID, contact: contact, messageID: randomBytes(Frames.messageIDLength),
            attachment: attachment, length: blob.count
        )
        try store.transaction {
            try store.addUpload(upload, blob: blob)
            try store.addFile(
                contact, incoming: false, messageID: upload.messageID, attachment: attachment, state: .sending,
                savedAs: localPath
            )
            try store.logMessage(contact, direction: .outgoing, messageID: upload.messageID, text: caption)
        }
        return upload
    }

    public func uploads() throws -> [UploadRow] {
        try store.uploads()
    }

    public func hasUpload(_ blobID: Data) throws -> Bool {
        try store.hasUpload(blobID)
    }

    /// Deletes a logged message, with its file, inside the caller's transaction: an upload of
    /// it ends as a cancel of section 33.2 and its blob, like the blob of a received file not
    /// downloaded yet, is saved for a DeleteBlob.
    public func deleteMessage(_ position: Int64) throws {
        try saveBlobDeletions(try store.files(ofMessageAt: position))
        try store.deleteMessage(position)
    }

    /// Deletes the logged and the pending messages of a contact, with their files, as
    /// `deleteMessage` does, inside the caller's transaction.
    public func deleteMessages(_ contact: Data) throws {
        try saveBlobDeletions(try store.files().filter { $0.contact == contact })
        try giveUpProfileUpload(contact)
        try store.deleteMessages(contact)
    }

    /// Deletes the avatar upload of the profile owed to a contact, if one started, and saves
    /// the DeleteBlob of its blob, inside the caller's transaction; returns its blob id.
    @discardableResult
    private func giveUpProfileUpload(_ contact: Data) throws -> Data? {
        guard let blobID = try store.profileUpload(contact) else {
            return nil
        }
        try store.deleteUpload(blobID)
        try store.addBlobDeletion(uploader: identityKey, blobID: blobID)
        return blobID
    }

    private func saveBlobDeletions(_ files: [FileRow]) throws {
        for file in files {
            let blobID = file.attachment.blobID
            if !file.incoming, try store.hasUpload(blobID) {
                try store.deleteUpload(blobID)
                try store.addBlobDeletion(uploader: identityKey, blobID: blobID)
            } else if file.incoming, file.state == .offered || file.state == .receiving {
                try store.addBlobDeletion(uploader: file.contact, blobID: blobID)
            }
        }
    }

    public func readUpload(_ blobID: Data, offset: Int, length: Int) throws -> Data {
        try store.readUpload(blobID, offset: offset, length: length)
    }

    /// Step 5 of section 33.2: SEND of the attachment, which deletes the upload. The upload of
    /// an avatar sends the own profile with its current name (section 36.2).
    ///
    /// - Throws: `SessionError.notAContact`; `CryptoError` when START failed.
    public func sendAttachment(_ upload: UploadRow, bundle: PrekeyBundle? = nil) throws -> Outgoing {
        guard try store.hasUpload(upload.blobID) else {
            throw InvalidInputError(message: "the upload was given up")
        }
        let plaintext = upload.profile
            ? try Envelope.encodeProfile(name: store.ownProfile().name, avatar: upload.attachment)
            : try Envelope.encodeAttachment(upload.attachment)
        let sealed = try seal(upload.contact, plaintext, bundle: bundle, messageID: upload.messageID)
        try store.transaction {
            try commit(sealed)
            try store.deleteUpload(upload.blobID)
        }
        return sealed.outgoing
    }

    /// Ends an upload as not sent: deletes it, saves the DeleteBlob of its blob and notes the
    /// result on its file, which is returned.
    @discardableResult
    public func giveUpUpload(_ upload: UploadRow, result: String) throws -> FileRow? {
        try store.transaction {
            try store.deleteUpload(upload.blobID)
            try store.addBlobDeletion(uploader: identityKey, blobID: upload.blobID)
            guard let file = try store.fileOfMessage(upload.messageID) else {
                return nil
            }
            try store.setFileState(file.position, .notSent, result: result)
            return file
        }
    }

    /// The received files whose blob is not downloaded yet: offered or receiving.
    public func downloads() throws -> [FileRow] {
        try store.files().filter { $0.incoming && ($0.state == .offered || $0.state == .receiving) }
    }

    /// Makes room for the blob of a received file in the store (section 33.3).
    public func beginDownload(_ position: Int64) throws {
        let file = try file(position)
        try store.transaction { try store.beginDownload(position, length: Blob.blobLength(Int(file.attachment.size))) }
    }

    /// Stops a download until the user asks again; the bytes it holds stay.
    public func pauseDownload(_ position: Int64) throws {
        try store.transaction { try store.pauseDownload(position) }
    }

    /// Saves bytes of a blob at its held length together with the new length.
    public func saveDownloadPiece(_ position: Int64, _ data: Data) throws {
        try store.transaction { try store.addDownloadPiece(position, data) }
    }

    /// Step 4 of section 33.3: opens the blob, writes the file into the folder, drops the
    /// downloaded bytes and saves the DeleteBlob of the blob.
    ///
    /// - Throws: `CryptoError.badBlob` when the blob does not open (section 29.7), and
    ///   nothing is written; `StoreError.system` when the file cannot be written, and the
    ///   downloaded bytes stay.
    public func finishDownload(_ position: Int64, folder: URL) throws -> URL {
        let file = try file(position)
        let attachment = file.attachment
        let data = try Blob.open(
            store.downloaded(position), fileKey: attachment.key, size: Int(attachment.size), digest: attachment.digest
        )
        let path = try ReceivedFiles.save(data, named: attachment.fileName, into: folder)
        try store.transaction {
            try store.setFileState(position, .received, savedAs: path.path)
            try store.addBlobDeletion(uploader: file.contact, blobID: attachment.blobID)
        }
        return path
    }

    /// Step 4 of section 33.3 for an avatar (section 36.3): opens the blob, keeps the picture
    /// with the profile of its contact and saves the DeleteBlob of the blob.
    ///
    /// - Throws: `CryptoError.badBlob` when the blob does not open; `EnvelopeError.notAnImage`
    ///   when the picture does not start with the signature of its media type. Nothing is kept.
    public func finishAvatarDownload(_ position: Int64) throws {
        let file = try file(position)
        let attachment = file.attachment
        let picture = try Blob.open(
            store.downloaded(position), fileKey: attachment.key, size: Int(attachment.size), digest: attachment.digest
        )
        guard try Envelope.avatarMediaType(picture) == attachment.mediaType else {
            throw EnvelopeError.notAnImage
        }
        try store.transaction {
            try store.setAvatar(position, picture)
            try store.setFileState(position, .received)
            try store.addBlobDeletion(uploader: file.contact, blobID: attachment.blobID)
        }
    }

    /// Steps 5 and 6 of section 33.3: drops the downloaded bytes, and a BAD_BLOB or a
    /// NOT_AN_IMAGE also saves the DeleteBlob of the blob; returns the state that the file
    /// takes.
    @discardableResult
    public func failDownload(_ position: Int64, result: String) throws -> FileState {
        let file = try file(position)
        let state: FileState = result == FileError.blobGone.result ? .notAvailable : .notReceived
        try store.transaction {
            try store.setFileState(position, state, result: result)
            if result == CryptoError.badBlob.result || result == EnvelopeError.notAnImage.result {
                try store.addBlobDeletion(uploader: file.contact, blobID: file.attachment.blobID)
            }
        }
        return state
    }

    /// The DeleteBlob frames still to send.
    public func blobDeletions() throws -> [(uploader: Data, blobID: Data)] {
        try store.blobDeletions()
    }

    /// Forgets a DeleteBlob that the relay handled (section 33.2, last paragraph).
    public func confirmBlobDeletion(uploader: Data, blobID: Data) throws {
        try store.transaction { try store.deleteBlobDeletion(uploader: uploader, blobID: blobID) }
    }

    // MARK: The profile (part 4)

    public func ownProfile() throws -> OwnProfile {
        try store.ownProfile()
    }

    /// The profile as it is saved: the media type read from the picture, no thumbnail or
    /// size without a picture, a thumbnail beyond MAX_THUMBNAIL_BYTES dropped.
    ///
    /// - Throws: `EnvelopeError.badProfileName`, `.avatarTooLarge` or `.notAnImage`
    ///   (section 35.2).
    public static func checked(_ profile: OwnProfile) throws -> OwnProfile {
        guard Envelope.isProfileName(profile.name) else {
            throw EnvelopeError.badProfileName
        }
        guard let avatar = profile.avatar else {
            return OwnProfile(name: profile.name)
        }
        guard avatar.count <= Envelope.maxAvatarBytes else {
            throw EnvelopeError.avatarTooLarge
        }
        var checked = profile
        checked.mediaType = try Envelope.avatarMediaType(avatar)
        if checked.thumbnail.count > Envelope.maxThumbnailBytes {
            checked.thumbnail = Data()
        }
        checked.width = min(max(checked.width, 0), Int(UInt32.max))
        checked.height = min(max(checked.height, 0), Int(UInt32.max))
        return checked
    }

    /// Saves the own profile and owes it to every contact with a session (section 36.2); an
    /// empty name and no avatar clear it. A newer profile gives up the avatar uploads of an
    /// older one; their blob ids are returned.
    ///
    /// - Throws: what `checked` throws.
    @discardableResult
    public func setProfile(_ profile: OwnProfile) throws -> [Data] {
        let profile = try Self.checked(profile)
        return try store.transaction {
            try store.setOwnProfile(profile)
            var givenUp: [Data] = []
            for contact in try store.contacts().map(\.identityKey) {
                if let blobID = try giveUpProfileUpload(contact) {
                    givenUp.append(blobID)
                }
                if try hasSession(contact) {
                    try store.oweProfile(contact)
                }
            }
            return givenUp
        }
    }

    public func oweProfile(_ contact: Data) throws {
        try store.transaction { try store.oweProfile(contact) }
    }

    /// An avatar upload that the relay does not take (section 33.4): given up with the
    /// DeleteBlob of its blob and the profile owed again, in one transaction, so that it goes
    /// without the avatar (section 36.2).
    public func oweProfileWithoutUpload(_ upload: UploadRow) throws {
        try store.transaction {
            try store.deleteUpload(upload.blobID)
            try store.addBlobDeletion(uploader: identityKey, blobID: upload.blobID)
            try store.oweProfile(upload.contact)
        }
    }

    /// Turns the profile sends owed to contacts into messages (section 36.2). A profile
    /// without an avatar, or one whose avatar the relay does not take, is sealed and committed
    /// at once and returned as a Send. One with an avatar becomes an upload, whose message
    /// `sendAttachment` sends once its blob is complete.
    public func sendOwedProfiles(blobMaxBytes: Int) throws -> [Outgoing] {
        let own = try store.ownProfile()
        var outgoing: [Outgoing] = []
        for contact in try store.owedProfiles() {
            guard try hasSession(contact) else {
                continue
            }
            if let avatar = own.avatar, Blob.blobLength(avatar.count) <= blobMaxBytes {
                try startProfileUpload(contact, avatar, own)
                continue
            }
            let sealed = try seal(
                contact, Envelope.encodeProfile(name: own.name, avatar: nil), bundle: nil,
                messageID: randomBytes(Frames.messageIDLength)
            )
            try store.transaction {
                try commit(sealed)
                try store.deleteProfileSend(contact)
            }
            outgoing.append(sealed.outgoing)
        }
        return outgoing
    }

    /// The latest profile of a contact, nil when it sent none or cleared it.
    public func profile(_ contact: Data) throws -> ContactProfile? {
        try store.profile(contact)
    }

    private func startProfileUpload(_ contact: Data, _ avatar: Data, _ own: OwnProfile) throws {
        var (attachment, blob) = try encryptFile(avatar)
        attachment.mediaType = own.mediaType
        attachment.width = UInt32(own.width)
        attachment.height = UInt32(own.height)
        attachment.thumbnail = own.thumbnail
        let upload = UploadRow(
            blobID: attachment.blobID, contact: contact, messageID: randomBytes(Frames.messageIDLength),
            attachment: attachment, length: blob.count, profile: true
        )
        try store.transaction {
            try store.addUpload(upload, blob: blob)
            try store.startProfileUpload(contact, blobID: upload.blobID)
        }
    }

    /// Section 36.2: a session that enters the list gets the own profile once, unless the
    /// profile is empty; inside the caller's transaction.
    private func oweProfileToANewSession(_ contact: Data) throws {
        if try !store.ownProfile().isEmpty {
            try store.oweProfile(contact)
        }
    }

    /// Step 2 of section 33.2: a new blob id, file key and nonce, and the blob.
    private func encryptFile(_ file: Data) throws -> (Sotto_Attachment, Data) {
        let fileKey = randomBytes(Blob.fileKeyLength)
        var attachment = Sotto_Attachment()
        attachment.blobID = randomBytes(Frames.blobIDLength)
        attachment.key = fileKey
        let blob = try Blob.encrypt(file, fileKey: fileKey, nonce: randomBytes(Blob.nonceLength))
        attachment.size = UInt32(file.count)
        attachment.digest = Blob.digest(blob)
        return (attachment, blob)
    }

    private func file(_ position: Int64) throws -> FileRow {
        guard let file = try store.file(position) else {
            throw InvalidInputError(message: "the store holds no file at position \(position)")
        }
        return file
    }

    /// L1 of section 20.2 up to the commit: START when the contact has no session.
    private func seal(_ contact: Data, _ paddedPlaintext: Data, bundle: PrekeyBundle?, messageID: Data) throws -> Sealed {
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
        return Sealed(outgoing: outgoing, sessionID: session.sessionID, state: encrypted.state)
    }

    /// The chain advance and the outbox row of SEND, inside the caller's transaction.
    private func commit(_ sealed: Sealed) throws {
        let outgoing = sealed.outgoing
        try store.advanceSession(sealed.sessionID, state: sealed.state)
        try store.addToOutbox(OutboxRow(messageID: outgoing.messageID, recipient: outgoing.recipient, payload: outgoing.payload))
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
        let content = Self.readContent(decrypted.paddedPlaintext)

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
            try oweProfileToANewSession(delivered.sender)
            try saveReceived(delivered, content)
            return dropped
        }
        return Received(
            ack: true, text: content.text, result: content.result, missing: decrypted.purged + dropped,
            attachment: content.attachment, profile: content.profile
        )
    }

    /// ACCEPT of section 20.3.
    private func accept(_ delivered: Delivered, _ session: StoredSession, _ decrypted: Decrypted) throws -> Received {
        let content = Self.readContent(decrypted.paddedPlaintext)
        try store.transaction {
            try store.acceptOnSession(session.sessionID, state: decrypted.state)
            try saveReceived(delivered, content)
        }
        return Received(
            ack: true, text: content.text, result: content.result, missing: decrypted.purged,
            attachment: content.attachment, profile: content.profile
        )
    }

    private func saveReceived(_ delivered: Delivered, _ content: Content) throws {
        try store.addSeenID(sender: delivered.sender, messageID: delivered.messageID, seenAt: now())
        if let profile = content.profile {
            return try saveProfile(delivered, profile)
        }
        if let text = content.text ?? content.attachment?.caption {
            try store.logMessage(delivered.sender, direction: .incoming, messageID: delivered.messageID, text: text)
        }
        if let attachment = content.attachment {
            try store.addFile(
                delivered.sender, incoming: true, messageID: delivered.messageID, attachment: attachment, state: .offered
            )
        }
    }

    /// Section 36.3: the profile replaces the earlier one of its sender whole and logs no
    /// message; an earlier avatar that was not downloaded gets its blob deleted.
    private func saveProfile(_ delivered: Delivered, _ profile: Sotto_Profile) throws {
        let contact = delivered.sender
        if let position = try store.profile(contact)?.avatarFile, let earlier = try store.file(position) {
            if earlier.state == .offered || earlier.state == .receiving {
                try store.addBlobDeletion(uploader: contact, blobID: earlier.attachment.blobID)
            }
            try store.deleteFile(position)
        }
        guard !profile.name.isEmpty || profile.hasAvatar else {
            return try store.deleteProfile(contact)
        }
        let avatarFile = profile.hasAvatar
            ? try store.addFile(contact, incoming: true, messageID: delivered.messageID, attachment: profile.avatar, state: .offered)
            : nil
        try store.setProfile(contact, name: profile.name, avatarFile: avatarFile)
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

    /// The text, the attachment or the profile of a message that decrypted, or the result
    /// that it has none (section 20.3).
    private static func readContent(_ paddedPlaintext: Data) -> Content {
        do {
            switch try Envelope.decodeContent(paddedPlaintext) {
            case .text(let text): return Content(text: text)
            case .attachment(let attachment): return Content(attachment: attachment)
            case .profile(let profile): return Content(profile: profile)
            }
        } catch {
            return Content(result: (error as? EnvelopeError)?.result ?? EnvelopeError.badContent.result)
        }
    }
}

private struct Content {
    var text: String?
    var attachment: Sotto_Attachment?
    var profile: Sotto_Profile?
    var result: String?
}

/// A message encrypted on the head session of a contact, not yet committed.
private struct Sealed {
    let outgoing: Outgoing
    let sessionID: Int64
    let state: RatchetState
}
