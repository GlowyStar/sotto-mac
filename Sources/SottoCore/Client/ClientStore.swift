import Foundation
import SQLCipher

public enum StoreError: Error, Equatable, Sendable {
    /// The directory or the file of the store gives a right to the group or to others.
    case wideMode(path: String, mode: UInt16)
    case writeOutsideTransaction
    case noIdentity
    case system(path: String, errno: Int32)
    case sqlite(code: Int32, message: String)
    /// The key of the store is not held: the store is locked.
    case locked
    /// The key opens no page of the store, or the wrapped key does not open.
    case wrongKey
    /// The store is encrypted and its wrapped key is gone.
    case missingKey(path: String)
    case damagedKey(path: String)
    case protectionMismatch(path: String, stored: StoreProtection, asked: StoreProtection)
    case testProtectionRefused(path: String)
    case noSecureEnclave
    /// The Secure Enclave refused the key: made by another Mac, damaged, or not authorized.
    case enclaveRefused(reason: String)
    /// The library that serves the store is not SQLCipher.
    case notSQLCipher
    case migrationLostRows(table: String)
    case notATestStore
}

extension StoreError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .wideMode(let path, let mode): "\(path) has mode \(String(format: "%04o", mode)): the group or others have a right"
        case .writeOutsideTransaction: "a write outside a transaction"
        case .noIdentity: "the store holds no identity"
        case .system(let path, let code): "\(path): \(String(cString: strerror(code)))"
        case .sqlite(let code, let message): "SQLite error \(code): \(message)"
        case .locked: "the store is locked"
        case .wrongKey: "the key does not open this store"
        case .missingKey(let path): "the store is encrypted and its key \(path) is missing"
        case .damagedKey(let path): "the store key \(path) is damaged"
        case .protectionMismatch(let path, let stored, let asked):
            "the store key \(path) is of the \(stored.rawValue) kind, this run asks for \(asked.rawValue)"
        case .testProtectionRefused(let path): "\(path) is a default data folder: the test protection is refused there"
        case .noSecureEnclave: "this Mac has no Secure Enclave, which the store key needs"
        case .enclaveRefused(let reason): "the Secure Enclave did not open the store key: \(reason)"
        case .notSQLCipher: "the store is not served by SQLCipher"
        case .migrationLostRows(let table): "the encrypted copy of the store lacks rows of \(table); the plain store is kept"
        case .notATestStore: "only a store of the test kind answers this"
        }
    }
}

public struct StoredIdentity: Equatable, Sendable {
    public var seed: Data
    public var identityDHPrivateKey: Data

    public init(seed: Data, identityDHPrivateKey: Data) {
        self.seed = seed
        self.identityDHPrivateKey = identityDHPrivateKey
    }
}

public struct StoredSignedPrekey: Equatable, Sendable {
    public var prekeyID: UInt32
    public var privateKey: Data
    public var madeAt: Int64
    public var confirmed: Bool
}

public struct StoredSession: Equatable, Sendable {
    public var sessionID: Int64
    public var contact: Data
    public var associatedData: Data
    public var state: RatchetState
    public var initialHeader: Data?
}

/// What an accepted initial message left behind (section 20.4).
public struct SessionRecord: Equatable, Sendable {
    public var sessionID: Int64
    public var signedPrekeyID: UInt32
}

public struct OutboxRow: Equatable, Sendable {
    public var messageID: Data
    public var recipient: Data
    public var payload: Data

    public init(messageID: Data, recipient: Data, payload: Data) {
        self.messageID = messageID
        self.recipient = recipient
        self.payload = payload
    }
}

public struct Contact: Equatable, Sendable {
    public var identityKey: Data
    public var name: String?
}

public enum MessageDirection: String, Sendable {
    case incoming = "in"
    case outgoing = "out"
}

/// What a receipt says of a message (section 39.5), as the store keeps it.
public enum ReceiptKind: String, Codable, Sendable {
    case delivered
    case read
}

/// The message a reply quotes, by its direction in this store and its id, and the text of
/// the quote, nil once that message is gone (section 39.2).
public struct StoredQuote: Equatable, Sendable {
    public var incoming: Bool
    public var messageID: Data
    public var text: String?

    public init(incoming: Bool, messageID: Data, text: String?) {
        self.incoming = incoming
        self.messageID = messageID
        self.text = text
    }
}

/// A row of the message log, a text or an attachment with its caption as `text`, and what
/// part 5 keeps of it (section 39.10). `position` is above every position that a message of
/// the log ever had (section 39.8); `writtenAt` is nil for a message logged before part 5.
public struct StoredMessage: Equatable, Sendable {
    public var position: Int64
    public var contact: Data
    public var direction: MessageDirection
    public var messageID: Data
    public var text: String
    public var writtenAt: Int64?
    public var edits = 0
    public var expiresAfter = 0
    public var expiresAt: Int64?
    public var readAt: Int64?
    /// The last receipt of the peer for an own message.
    public var receipt: ReceiptKind?
    /// The receipt owed for a received message.
    public var owed: ReceiptKind?
    public var quote: StoredQuote?

    public var incoming: Bool { direction == .incoming }
}

/// What part 5 keeps of a message when it enters the log.
public struct NewState: Equatable, Sendable {
    public var writtenAt: Int64
    public var expiresAfter = 0
    public var expiresAt: Int64?
    public var quote: StoredQuote?
    public var owed: ReceiptKind?
}

/// The part 5 state of a message that is not in the log: gone, or edited before it arrived
/// (section 39.7).
public struct Trace: Equatable, Sendable {
    public var gone: Bool
    public var earlyText: String?
    public var edits: Int
}

/// A text typed to a contact without a session, kept until the session exists and the text
/// is committed to the outbox, or until it fails with `failure`.
public struct PendingText: Equatable, Sendable {
    public var position: Int64
    public var contact: Data
    public var text: String
    /// Milliseconds since 1970.
    public var madeAt: Int64
    public var failure: String?
    /// The position of the message of the chat that the text answers.
    public var replyTo: Int64?
}

/// The states of a file of section 33.5, as the store keeps them.
public enum FileState: String, Codable, Sendable {
    case sending
    case sent
    case notSent = "not sent"
    case offered
    case receiving
    case received
    case notReceived = "could not be received"
    case notAvailable = "not available"
}

/// A file being uploaded with the bytes of its blob (section 33.2, step 2); `messageID` is
/// the id that its message takes.
public struct UploadRow: Equatable, Sendable {
    public var blobID: Data
    public var contact: Data
    public var messageID: Data
    public var attachment: Sotto_Attachment
    public var length: Int
    /// The upload carries the avatar of a profile owed to `contact` (section 36.2).
    public var profile = false
}

/// An attachment of the message log, sent or received: `held` bytes of its blob are
/// downloaded, `savedAs` is the path of a received file or the file a sent one was read
/// from, `result` why it failed; `kept` when the store holds the bytes of the file itself.
public struct FileRow: Equatable, Sendable {
    public var position: Int64
    public var contact: Data
    public var incoming: Bool
    public var messageID: Data
    public var attachment: Sotto_Attachment
    public var state: FileState
    public var held: Int
    public var savedAs: String?
    public var result: String?
    /// The file is the avatar of a contact's profile, no file of the message log (section 36.1).
    public var avatar = false
    /// The store holds the bytes of the file: a received file not saved into a folder, or a
    /// sent one that exists nowhere else, such as a pasted picture (docs/key-storage.md).
    public var kept = false
}

/// The client's own profile (section 36.1): the name, the picture with its media type, and
/// the thumbnail and size that go with the picture.
public struct OwnProfile: Equatable, Sendable {
    public var name: String
    public var avatar: Data?
    public var mediaType: String
    public var thumbnail: Data
    public var width: Int
    public var height: Int

    public init(
        name: String = "", avatar: Data? = nil, mediaType: String = "", thumbnail: Data = Data(), width: Int = 0,
        height: Int = 0
    ) {
        self.name = name
        self.avatar = avatar
        self.mediaType = mediaType
        self.thumbnail = thumbnail
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool {
        name.isEmpty && avatar == nil
    }
}

/// The latest profile a contact sent; `avatarFile` is the file of its avatar and `avatar`
/// the picture once it is received.
public struct ContactProfile: Equatable, Sendable {
    public var contact: Data
    public var name: String
    public var avatarFile: Int64?
    public var avatar: Data?
}

/// The client store of docs/protocol.md, section 22: the one connection to the SQLite file
/// of one identity. Every write runs inside `transaction`.
public final class ClientStore {
    public static let fileName = "store.db"
    public static let directoryMode: mode_t = 0o700
    public static let fileMode: mode_t = 0o600
    public static let widerThanOwner: mode_t = 0o077
    public static let maxSessions = 3
    public static let lastPrekeyID = UInt32.max
    /// How long a statement waits for a lock that another connection holds, such as a reader
    /// of the same file in another process, before it fails with SQLITE_BUSY.
    public static let busyTimeoutMilliseconds: Int32 = 5000
    /// The piece in which a kept file goes into the store and out of it.
    public static let keptPieceBytes = 1 << 20

    public let path: URL
    public let directory: URL
    private var connection: OpaquePointer?

    /// Opens the store in `directory` with the key `StoreKeys` holds for it, making the
    /// directory and the file when they are missing, and refuses either when its mode has
    /// one of the bits 077. A plain store of a version before the encryption is encrypted
    /// first (docs/key-storage.md).
    public init(directory: URL) throws {
        self.directory = directory
        path = directory.appendingPathComponent(Self.fileName)
        try Self.makePrivateDirectory(directory)
        try Self.whileHolding(directory) {
            try Self.finishEncrypting(path)
            try Self.makePrivateFile(path)
            try StoreKeys.withKeyLiteral(directory) { literal in
                if try Self.isPlain(path) {
                    try Self.encrypt(path, literal)
                }
                connection = try Self.connect(path, literal, flags: SQLITE_OPEN_READWRITE)
            }
        }
        try Self.check(connection)
        try query("PRAGMA journal_mode=DELETE")
        try query("PRAGMA temp_store=MEMORY")
        try query("PRAGMA secure_delete=ON")
        try transaction {
            for table in Schema.tables {
                try change(table)
            }
            // A store of a version before the counter holds its highest positions only in its
            // rows: the counter starts there, so that deleting the newest row first gives its
            // position to no later row (section 39.8).
            for table in ["messages", "pending", "files"] {
                try change("INSERT OR IGNORE INTO row_numbers SELECT '\(table)', coalesce(max(position), 0) FROM \(table)")
            }
        }
    }

    deinit {
        close()
    }

    public func close() {
        sqlite3_close_v2(connection)
        connection = nil
    }

    /// Runs `body` as one write transaction and rolls it back when it throws.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try query("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try query("COMMIT")
            return result
        } catch {
            if isInTransaction {
                _ = try? query("ROLLBACK")
            }
            throw error
        }
    }

    // MARK: Reads

    public func identity() throws -> StoredIdentity? {
        try query("SELECT seed, identity_dh_private_key FROM identity").first.map {
            StoredIdentity(seed: $0[0].data!, identityDHPrivateKey: $0[1].data!)
        }
    }

    public func isContact(_ identityKey: Data) throws -> Bool {
        try !query("SELECT 1 FROM contacts WHERE identity_key = ?", [.blob(identityKey)]).isEmpty
    }

    /// The pinned X25519 identity key of a contact; nil for no pin and for no contact.
    public func pin(_ contact: Data) throws -> Data? {
        try query("SELECT pinned_identity_dh_key FROM contacts WHERE identity_key = ?", [.blob(contact)])
            .first?[0].data
    }

    /// The private key of a signed prekey that is the newest or was replaced after the
    /// given time; any other counts as not held (section 21.2).
    public func signedPrekey(_ prekeyID: UInt32, replacedAfter: Int64) throws -> Data? {
        try query(Schema.readSignedPrekey, [.integer(Int64(prekeyID)), .integer(replacedAfter)]).first?[0].data
    }

    public func newestSignedPrekey() throws -> StoredSignedPrekey? {
        try query(Schema.readNewestSignedPrekey).first.map {
            StoredSignedPrekey(
                prekeyID: UInt32($0[0].integer!),
                privateKey: $0[1].data!,
                madeAt: $0[2].integer!,
                confirmed: $0[3].integer! == 1
            )
        }
    }

    /// The ids that the counter of one-time prekeys can still give (section 21.1).
    public func oneTimePrekeyIDsLeft() throws -> Int64 {
        guard let lastID = try query("SELECT last_one_time_prekey_id FROM identity").first?[0].integer else {
            throw StoreError.noIdentity
        }
        return Int64(Self.lastPrekeyID) - lastID
    }

    public func oneTimePrekeyCount() throws -> Int {
        Int(try query("SELECT count(*) FROM one_time_prekeys")[0][0].integer!)
    }

    public func oneTimePrekey(_ prekeyID: UInt32) throws -> Data? {
        try query("SELECT private_key FROM one_time_prekeys WHERE prekey_id = ?", [.integer(Int64(prekeyID))])
            .first?[0].data
    }

    /// The session list of a contact, its head first.
    public func sessions(_ contact: Data) throws -> [StoredSession] {
        try query(Schema.readSessions, [.blob(contact)]).map(Self.session)
    }

    public func session(_ sessionID: Int64) throws -> StoredSession? {
        try query(Schema.readSession, [.integer(sessionID)]).first.map(Self.session)
    }

    public func record(sender: Data, ephemeralKey: Data) throws -> SessionRecord? {
        try query(
            "SELECT session_id, signed_prekey_id FROM records WHERE sender = ? AND ephemeral_key = ?",
            [.blob(sender), .blob(ephemeralKey)]
        ).first.map { SessionRecord(sessionID: $0[0].integer!, signedPrekeyID: UInt32($0[1].integer!)) }
    }

    public func isSeen(sender: Data, messageID: Data) throws -> Bool {
        try !query("SELECT 1 FROM seen_ids WHERE sender = ? AND message_id = ?", [.blob(sender), .blob(messageID)])
            .isEmpty
    }

    /// Whether an outgoing message with the id is in the message log.
    public func isLoggedOutgoing(_ messageID: Data) throws -> Bool {
        try !query("SELECT 1 FROM messages WHERE direction = 'out' AND message_id = ?", [.blob(messageID)]).isEmpty
    }

    public func outbox() throws -> [OutboxRow] {
        try query("SELECT message_id, recipient, payload FROM outbox ORDER BY position").map {
            OutboxRow(messageID: $0[0].data!, recipient: $0[1].data!, payload: $0[2].data!)
        }
    }

    /// Every contact with the local name the user gave it, by name.
    public func contacts() throws -> [Contact] {
        try query("SELECT identity_key, name FROM contacts ORDER BY name, identity_key").map {
            Contact(identityKey: $0[0].data!, name: $0[1].text)
        }
    }

    /// The logged messages of a contact, oldest first.
    public func messages(_ contact: Data) throws -> [StoredMessage] {
        try query(Schema.readMessages + " WHERE m.contact = ? ORDER BY m.position", [.blob(contact)]).map(Self.message)
    }

    public func message(_ position: Int64) throws -> StoredMessage? {
        try query(Schema.readMessages + " WHERE m.position = ?", [.integer(position)]).first.map(Self.message)
    }

    /// The latest message of the log that has this author and id (section 39.1).
    public func message(_ contact: Data, incoming: Bool, messageID: Data) throws -> StoredMessage? {
        try query(
            Schema.readMessages + " WHERE m.contact = ? AND m.direction = ? AND m.message_id = ? ORDER BY m.position DESC",
            [.blob(contact), .text(Self.direction(incoming)), .blob(messageID)]
        ).first.map(Self.message)
    }

    /// The messages whose timer ran out at `now` (section 39.6).
    public func expiredMessages(_ now: Int64) throws -> [StoredMessage] {
        try query(Schema.readMessages + " WHERE s.expires_at <= ? ORDER BY m.position", [.integer(now)]).map(Self.message)
    }

    public func trace(_ contact: Data, incoming: Bool, messageID: Data) throws -> Trace? {
        try query(
            "SELECT gone, early_text, edits FROM message_states WHERE contact = ? AND direction = ? AND message_id = ?",
            [.blob(contact), .text(Self.direction(incoming)), .blob(messageID)]
        ).first.map { Trace(gone: $0[0].integer! == 1, earlyText: $0[1].text, edits: Int($0[2].integer!)) }
    }

    /// The receipts to send, as (contact, message id, kind), in the order of the log.
    public func owedReceipts() throws -> [(contact: Data, messageID: Data, kind: ReceiptKind)] {
        try query(
            "SELECT s.contact, s.message_id, s.owed FROM message_states s JOIN messages m USING (contact, direction, message_id) "
                + "WHERE s.direction = 'in' AND s.owed IS NOT NULL ORDER BY m.position"
        ).map { (contact: $0[0].data!, messageID: $0[1].data!, kind: ReceiptKind(rawValue: $0[2].text!)!) }
    }

    /// The position of an own message of the log that no receipt has reached yet.
    public func ownMessageWithoutReceipt(_ messageID: Data) throws -> Int64? {
        try query(
            "SELECT m.position FROM messages m LEFT JOIN message_states s USING (contact, direction, message_id) "
                + "WHERE m.direction = 'out' AND m.message_id = ? AND s.receipt IS NULL",
            [.blob(messageID)]
        ).first?[0].integer
    }

    /// The disappearing timer of the chat with a contact in seconds, 0 when off.
    public func timer(_ contact: Data) throws -> Int {
        Int(try query("SELECT seconds FROM timers WHERE contact = ?", [.blob(contact)]).first?[0].integer ?? 0)
    }

    public func readReceipts() throws -> Bool {
        try query("SELECT read_receipts FROM settings").first.map { $0[0].integer == 1 } ?? true
    }

    /// The texts that wait for a session, oldest first.
    public func pending() throws -> [PendingText] {
        try query(
            "SELECT p.position, p.contact, p.text, p.made_at, p.failure, r.reply_to FROM pending p "
                + "LEFT JOIN pending_replies r USING (position) ORDER BY p.position"
        ).map {
            PendingText(
                position: $0[0].integer!, contact: $0[1].data!, text: $0[2].text!, madeAt: $0[3].integer!, failure: $0[4].text,
                replyTo: $0[5].integer
            )
        }
    }

    /// The result of the refusal of each refused Send, by message id.
    public func refusals() throws -> [Data: String] {
        var refusals: [Data: String] = [:]
        for row in try query("SELECT message_id, result FROM refusals") {
            refusals[row[0].data!] = row[1].text!
        }
        return refusals
    }

    public func uploads() throws -> [UploadRow] {
        try query(Schema.readUploads).map {
            UploadRow(
                blobID: $0[0].data!,
                contact: $0[1].data!,
                messageID: $0[2].data!,
                attachment: try Sotto_Attachment(serializedBytes: $0[3].data!),
                length: Int($0[4].integer!),
                profile: $0[5].integer! == 1
            )
        }
    }

    /// Bytes of the blob of an upload, read by range without loading the whole blob.
    public func readUpload(_ blobID: Data, offset: Int, length: Int) throws -> Data {
        guard let row = try query("SELECT position FROM uploads WHERE blob_id = ?", [.blob(blobID)]).first else {
            throw InvalidInputError(message: "the store holds no upload of this blob")
        }
        return try readBlob("uploads", "blob", row: row[0].integer!, offset: offset, length: length)
    }

    public func hasUpload(_ blobID: Data) throws -> Bool {
        try !query("SELECT 1 FROM uploads WHERE blob_id = ?", [.blob(blobID)]).isEmpty
    }

    /// The files of the logged message at a position: none, or the one it carries.
    public func files(ofMessageAt position: Int64) throws -> [FileRow] {
        try query(
            Schema.readFiles + " WHERE (contact, direction, message_id) IN (SELECT contact, direction, message_id FROM messages WHERE position = ?)",
            [.integer(position)]
        ).map(Self.file)
    }

    public func files() throws -> [FileRow] {
        try query(Schema.readFiles + " ORDER BY position").map(Self.file)
    }

    public func file(_ position: Int64) throws -> FileRow? {
        try query(Schema.readFiles + " WHERE position = ?", [.integer(position)]).first.map(Self.file)
    }

    /// The file that a message of the client's own carries, if it carries one.
    public func fileOfMessage(_ messageID: Data) throws -> FileRow? {
        try query(Schema.readFiles + " WHERE direction = 'out' AND message_id = ?", [.blob(messageID)])
            .first.map(Self.file)
    }

    /// The bytes of a download, as many as its blob has room for.
    public func downloaded(_ position: Int64) throws -> Data {
        guard let row = try query("SELECT bytes FROM downloads WHERE position = ?", [.integer(position)]).first else {
            throw InvalidInputError(message: "the store holds no download at this position")
        }
        return row[0].data ?? Data()
    }

    /// The bytes of a file that the store keeps, nil when it keeps none: whole, for a picture
    /// to decode or a file to send again; `readKeptFile` hands out a large one in pieces.
    public func keptFile(_ position: Int64) throws -> Data? {
        try query("SELECT bytes FROM kept_files WHERE position = ?", [.integer(position)]).first?[0].data
    }

    /// Hands the bytes of a file that the store keeps to `piece`, `keptPieceBytes` at a time;
    /// false when it keeps none.
    public func readKeptFile(_ position: Int64, _ piece: (Data) throws -> Void) throws -> Bool {
        guard let length = try query("SELECT length(bytes) FROM kept_files WHERE position = ?", [.integer(position)])
            .first?[0].integer
        else {
            return false
        }
        var offset = 0
        while offset < Int(length) {
            let read = try readBlob("kept_files", "bytes", row: position, offset: offset, length: Self.keptPieceBytes)
            guard !read.isEmpty else { break }
            try piece(read)
            offset += read.count
        }
        return true
    }

    /// The notes of the app (`Messenger`), nil until they are first saved.
    public func appNotes() throws -> Data? {
        try query("SELECT notes FROM app_notes").first?[0].data
    }

    /// The DeleteBlob frames to send, as (uploader, blob id).
    public func blobDeletions() throws -> [(uploader: Data, blobID: Data)] {
        try query("SELECT uploader, blob_id FROM blob_deletions ORDER BY uploader, blob_id").map {
            (uploader: $0[0].data!, blobID: $0[1].data!)
        }
    }

    /// The own profile; the empty one when none was ever set.
    public func ownProfile() throws -> OwnProfile {
        guard let row = try query("SELECT name, avatar, media_type, thumbnail, width, height FROM own_profile").first else {
            return OwnProfile()
        }
        return OwnProfile(
            name: row[0].text!, avatar: row[1].data, mediaType: row[2].text!, thumbnail: row[3].data ?? Data(),
            width: Int(row[4].integer!), height: Int(row[5].integer!)
        )
    }

    /// The blob id of the avatar upload of the profile owed to a contact, if one started.
    public func profileUpload(_ contact: Data) throws -> Data? {
        try query("SELECT blob_id FROM profile_sends WHERE contact = ?", [.blob(contact)]).first?[0].data
    }

    /// The contacts owed the own profile whose avatar upload has not started.
    public func owedProfiles() throws -> [Data] {
        try query("SELECT contact FROM profile_sends WHERE blob_id IS NULL ORDER BY contact").map { $0[0].data! }
    }

    public func profile(_ contact: Data) throws -> ContactProfile? {
        try query(Schema.readProfiles + " WHERE contact = ?", [.blob(contact)]).first.map(Self.profile)
    }

    /// The latest profile of every contact that sent one.
    public func profiles() throws -> [ContactProfile] {
        try query(Schema.readProfiles).map(Self.profile)
    }

    // MARK: Writes

    public func saveIdentity(_ identity: StoredIdentity) throws {
        try change(
            "INSERT INTO identity VALUES (1, ?, ?, 0, 0)",
            [.blob(identity.seed), .blob(identity.identityDHPrivateKey)]
        )
    }

    /// Saves the newest signed prekey under the next id of its counter (section 21.1) and
    /// marks the one it replaces; nil, and nothing saved, once the counter is at
    /// `lastPrekeyID`.
    public func addSignedPrekey(_ privateKey: Data, madeAt: Int64) throws -> UInt32? {
        guard let counted = try change(Schema.countSignedPrekey, [.integer(Int64(Self.lastPrekeyID))]).first else {
            return nil
        }
        let prekeyID = counted[0].integer!
        try change("UPDATE signed_prekeys SET replaced_at = ? WHERE replaced_at IS NULL", [.integer(madeAt)])
        try change(
            "INSERT INTO signed_prekeys VALUES (?, ?, ?, NULL, 0)",
            [.integer(prekeyID), .blob(privateKey), .integer(madeAt)]
        )
        return UInt32(prekeyID)
    }

    public func confirmSignedPrekey(_ prekeyID: UInt32) throws {
        try change("UPDATE signed_prekeys SET confirmed = 1 WHERE prekey_id = ?", [.integer(Int64(prekeyID))])
    }

    /// Deletes the signed prekeys replaced at or before the time, with the records that
    /// name them and whose session is gone (section 21.2, step 1).
    public func deleteSignedPrekeys(replacedAtOrBefore: Int64) throws {
        try change("DELETE FROM signed_prekeys WHERE replaced_at <= ?", [.integer(replacedAtOrBefore)])
        try change(Schema.deleteOrphanRecords)
    }

    /// Saves a one-time prekey under the next id of its counter (section 21.1); nil, and
    /// nothing saved, once the counter is at `lastPrekeyID`.
    public func addOneTimePrekey(_ privateKey: Data) throws -> UInt32? {
        guard let counted = try change(Schema.countOneTimePrekey, [.integer(Int64(Self.lastPrekeyID))]).first else {
            return nil
        }
        let prekeyID = counted[0].integer!
        try change("INSERT INTO one_time_prekeys VALUES (?, ?)", [.integer(prekeyID), .blob(privateKey)])
        return UInt32(prekeyID)
    }

    public func deleteOneTimePrekey(_ prekeyID: UInt32) throws {
        try change("DELETE FROM one_time_prekeys WHERE prekey_id = ?", [.integer(Int64(prekeyID))])
    }

    public func deleteLowestOneTimePrekeys(_ count: Int) throws {
        try change(Schema.deleteLowestOneTimePrekeys, [.integer(Int64(count))])
    }

    public func addContact(_ identityKey: Data, name: String? = nil) throws {
        try change(
            "INSERT INTO contacts (identity_key, name) VALUES (?, ?) ON CONFLICT DO NOTHING",
            [.blob(identityKey), name.map(SQLValue.text) ?? .null]
        )
    }

    /// Deletes the contact with its sessions and its profile; its seen ids and records stay
    /// (section 20.6).
    public func removeContact(_ contact: Data) throws {
        let avatarFile = "(SELECT avatar_file FROM profiles WHERE contact = ?)"
        try change("DELETE FROM downloads WHERE position IN \(avatarFile)", [.blob(contact)])
        try change("DELETE FROM files WHERE position IN \(avatarFile)", [.blob(contact)])
        try change("DELETE FROM profiles WHERE contact = ?", [.blob(contact)])
        try change("DELETE FROM profile_sends WHERE contact = ?", [.blob(contact)])
        try change("DELETE FROM timers WHERE contact = ?", [.blob(contact)])
        try change("DELETE FROM message_states WHERE contact = ?", [.blob(contact)])
        try change("DELETE FROM sessions WHERE contact = ?", [.blob(contact)])
        try change("DELETE FROM contacts WHERE identity_key = ?", [.blob(contact)])
        try change(Schema.deleteOrphanRecords)
    }

    public func renameContact(_ contact: Data, name: String) throws {
        try change("UPDATE contacts SET name = ? WHERE identity_key = ?", [.text(name), .blob(contact)])
    }

    /// Deletes the logged and the pending messages of a contact.
    public func deleteMessages(_ contact: Data) throws {
        try change(
            "DELETE FROM refusals WHERE message_id IN (SELECT message_id FROM messages WHERE contact = ?)",
            [.blob(contact)]
        )
        try change("DELETE FROM messages WHERE contact = ?", [.blob(contact)])
        try change("DELETE FROM pending_replies WHERE position IN (SELECT position FROM pending WHERE contact = ?)", [.blob(contact)])
        try change("DELETE FROM pending WHERE contact = ?", [.blob(contact)])
        try change("DELETE FROM downloads WHERE position IN (SELECT position FROM files WHERE contact = ?)", [.blob(contact)])
        try change("DELETE FROM files WHERE contact = ?", [.blob(contact)])
    }

    /// Deletes a message of the log with its files, their downloaded bytes and its refusal,
    /// leaves its trace and forgets the text of every quote of it (sections 39.4 and 39.6).
    public func removeMessage(_ message: StoredMessage, at time: Int64) throws {
        let key: [SQLValue] = [.blob(message.contact), .text(message.direction.rawValue), .blob(message.messageID)]
        try change(
            "DELETE FROM downloads WHERE position IN (SELECT position FROM files WHERE contact = ? AND direction = ? AND message_id = ?)",
            key
        )
        try change("DELETE FROM files WHERE contact = ? AND direction = ? AND message_id = ?", key)
        if !message.incoming {
            try change("DELETE FROM refusals WHERE message_id = ?", [.blob(message.messageID)])
        }
        try change("DELETE FROM messages WHERE position = ?", [.integer(message.position)])
        try leaveTrace(message.contact, incoming: message.incoming, messageID: message.messageID, at: time)
    }

    /// Marks a message as gone, whether it is in the log or not yet, and forgets the text of
    /// every quote of it; the trace keeps nothing of the content (section 39.4).
    public func leaveTrace(_ contact: Data, incoming: Bool, messageID: Data, at time: Int64) throws {
        let direction = SQLValue.text(Self.direction(incoming))
        try change(Schema.leaveTrace, [.blob(contact), direction, .blob(messageID), .integer(time)])
        try change(
            "UPDATE message_states SET quote_text = NULL WHERE contact = ? AND quote_direction = ? AND quote_id = ?",
            [.blob(contact), direction, .blob(messageID)]
        )
    }

    /// Saves what part 5 keeps of a message just logged; the text of an edit that came before
    /// it is dropped, its count of edits stays.
    public func saveState(_ contact: Data, incoming: Bool, messageID: Data, state: NewState) throws {
        let quote = state.quote
        try change(
            Schema.saveState,
            [
                .blob(contact), .text(Self.direction(incoming)), .blob(messageID), .integer(state.writtenAt),
                quote.map { .text(Self.direction($0.incoming)) } ?? .null, quote.map { .blob($0.messageID) } ?? .null,
                quote?.text.map(SQLValue.text) ?? .null, .integer(Int64(state.expiresAfter)),
                state.expiresAt.map(SQLValue.integer) ?? .null, state.owed.map { .text($0.rawValue) } ?? .null,
            ]
        )
    }

    /// The timer of an own message from its SEND on: `writtenAt` is when it was sent.
    public func setSent(_ message: StoredMessage, at time: Int64, expiresAfter: Int) throws {
        try change(
            "UPDATE message_states SET written_at = ?, expires_after = ?, expires_at = ? WHERE contact = ? AND direction = ? AND message_id = ?",
            [
                .integer(time), .integer(Int64(expiresAfter)), expiresAfter > 0 ? .integer(time + Int64(expiresAfter)) : .null,
                .blob(message.contact), .text(message.direction.rawValue), .blob(message.messageID),
            ]
        )
    }

    /// Counts an edit of an incoming message that is not in the log; `earlyText` is the text
    /// it waits with (section 39.7).
    public func countEdit(_ contact: Data, messageID: Data, at time: Int64, earlyText: String?) throws {
        try change(Schema.countEdit, [.blob(contact), .text("in"), .blob(messageID), .integer(time), earlyText.map(SQLValue.text) ?? .null])
    }

    /// Replaces the text of a logged message, an attachment's caption included, and counts
    /// the edit (section 39.3).
    public func editMessage(_ message: StoredMessage, text: String, at time: Int64) throws {
        try change("UPDATE messages SET text = ? WHERE position = ?", [.text(text), .integer(message.position)])
        for file in try files(ofMessageAt: message.position) {
            var attachment = file.attachment
            attachment.caption = text
            try change(
                "UPDATE files SET attachment = ? WHERE position = ?", [.blob(try attachment.serializedBytes()), .integer(file.position)]
            )
        }
        try change(
            Schema.countEdit,
            [.blob(message.contact), .text(message.direction.rawValue), .blob(message.messageID), .integer(time), .null]
        )
    }

    public func setReceipt(_ message: StoredMessage, _ receipt: ReceiptKind) throws {
        try change(
            "UPDATE message_states SET receipt = ? WHERE contact = ? AND direction = ? AND message_id = ?",
            [.text(receipt.rawValue), .blob(message.contact), .text(message.direction.rawValue), .blob(message.messageID)]
        )
    }

    /// The user has seen a received message: its read time, its expiry and what it owes.
    public func setRead(_ message: StoredMessage, readAt: Int64, expiresAt: Int64?, owed: ReceiptKind?) throws {
        try change(
            Schema.setRead,
            [
                .blob(message.contact), .blob(message.messageID), .integer(readAt), .integer(readAt),
                expiresAt.map(SQLValue.integer) ?? .null, owed.map { .text($0.rawValue) } ?? .null,
            ]
        )
    }

    public func clearOwed(_ contact: Data, _ messageIDs: [Data]) throws {
        for messageID in messageIDs {
            try change(
                "UPDATE message_states SET owed = NULL WHERE contact = ? AND direction = 'in' AND message_id = ?",
                [.blob(contact), .blob(messageID)]
            )
        }
    }

    /// Turns the read receipts still owed into delivery receipts (section 39.5).
    public func oweDeliveryForRead() throws {
        try change("UPDATE message_states SET owed = 'delivered' WHERE owed = 'read'")
    }

    /// Forgets the traces written at or before the time, with the seen ids (section 39.7).
    public func forgetTraces(writtenAtOrBefore: Int64) throws {
        try change(Schema.forgetTraces, [.integer(writtenAtOrBefore)])
    }

    public func setTimer(_ contact: Data, seconds: Int) throws {
        try change(
            "INSERT INTO timers VALUES (?, ?) ON CONFLICT (contact) DO UPDATE SET seconds = excluded.seconds",
            [.blob(contact), .integer(Int64(seconds))]
        )
    }

    public func setAppNotes(_ notes: Data) throws {
        try change(
            "INSERT INTO app_notes VALUES (1, ?) ON CONFLICT (only_row) DO UPDATE SET notes = excluded.notes", [.blob(notes)]
        )
    }

    /// Keeps the bytes of a file in the store, written `keptPieceBytes` at a time into room
    /// made for them, as a download is, and clears the path the file named.
    public func keepFile(_ position: Int64, _ bytes: Data) throws {
        try change(
            "INSERT INTO kept_files VALUES (?, zeroblob(?)) ON CONFLICT (position) DO UPDATE SET bytes = excluded.bytes",
            [.integer(position), .integer(Int64(bytes.count))]
        )
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + Self.keptPieceBytes, bytes.count)
            try writeBlob("kept_files", "bytes", row: position, offset: offset, bytes[bytes.startIndex + offset ..< bytes.startIndex + end])
            offset = end
        }
        try change("UPDATE files SET saved_as = NULL WHERE position = ?", [.integer(position)])
    }

    public func setReadReceipts(_ on: Bool) throws {
        try change(
            "INSERT INTO settings VALUES (1, ?) ON CONFLICT (only_row) DO UPDATE SET read_receipts = excluded.read_receipts",
            [.integer(on ? 1 : 0)]
        )
    }

    /// Keeps a text that waits for a session before it can be encrypted; returns its position.
    public func addPending(_ contact: Data, text: String, madeAt: Int64, replyTo: Int64? = nil) throws -> Int64 {
        let position = try insertNumbered(
            "pending", columns: "contact, text, made_at", [.blob(contact), .text(text), .integer(madeAt)]
        )
        if let replyTo {
            try change("INSERT INTO pending_replies VALUES (?, ?)", [.integer(position), .integer(replyTo)])
        }
        return position
    }

    public func removePending(_ position: Int64) throws {
        try change("DELETE FROM pending WHERE position = ?", [.integer(position)])
        try change("DELETE FROM pending_replies WHERE position = ?", [.integer(position)])
    }

    /// Marks a pending text as one that is not sent, with a reason for a person.
    public func failPending(_ position: Int64, reason: String) throws {
        try change("UPDATE pending SET failure = ? WHERE position = ?", [.text(reason), .integer(position)])
    }

    /// Notes the result of an Error that refused the Send of a logged message.
    public func addRefusal(_ messageID: Data, result: String) throws {
        try change(
            "INSERT OR REPLACE INTO refusals (message_id, result) VALUES (?, ?)", [.blob(messageID), .text(result)]
        )
    }

    public func setPin(_ contact: Data, identityDHKey: Data) throws {
        try change(
            "UPDATE contacts SET pinned_identity_dh_key = ? WHERE identity_key = ?",
            [.blob(identityDHKey), .blob(contact)]
        )
    }

    /// Puts a new session at the head of the list.
    public func addSession(
        _ contact: Data,
        associatedData: Data,
        state: RatchetState,
        initialHeader: Data?
    ) throws -> Int64 {
        let added = try change(
            Schema.addSession,
            [.blob(contact), .blob(associatedData), .text(try Self.encode(state)), initialHeader.map(SQLValue.blob) ?? .null]
        )
        return added[0][0].integer!
    }

    /// Deletes the sessions past `maxSessions` and the records that go with them (sections
    /// 20.1 and 20.4); returns the skipped keys that left with them.
    public func dropSessionsBehind(_ contact: Data) throws -> Int {
        let behind: [SQLValue] = [.blob(contact), .blob(contact), .integer(Int64(Self.maxSessions))]
        let skipped = try query(Schema.countSkippedKeysBehind, behind)[0][0].integer!
        try change(Schema.dropSessionsBehind, behind)
        try change(Schema.deleteOrphanRecords)
        return Int(skipped)
    }

    /// Saves the state after a decryption: the session drops its initial header and moves
    /// to the head of the list.
    public func acceptOnSession(_ sessionID: Int64, state: RatchetState) throws {
        try change(Schema.acceptOnSession, [.text(try Self.encode(state)), .integer(sessionID)])
    }

    /// Saves the state after an encryption.
    public func advanceSession(_ sessionID: Int64, state: RatchetState) throws {
        try change("UPDATE sessions SET state = ? WHERE session_id = ?", [.text(try Self.encode(state)), .integer(sessionID)])
    }

    public func addRecord(sender: Data, ephemeralKey: Data, sessionID: Int64, signedPrekeyID: UInt32) throws {
        try change(
            "INSERT INTO records VALUES (?, ?, ?, ?)",
            [.blob(sender), .blob(ephemeralKey), .integer(sessionID), .integer(Int64(signedPrekeyID))]
        )
    }

    public func addSeenID(sender: Data, messageID: Data, seenAt: Int64) throws {
        try change("INSERT INTO seen_ids VALUES (?, ?, ?)", [.blob(sender), .blob(messageID), .integer(seenAt)])
    }

    public func deleteSeenIDs(seenAtOrBefore: Int64) throws {
        try change("DELETE FROM seen_ids WHERE seen_at <= ?", [.integer(seenAtOrBefore)])
    }

    public func addToOutbox(_ row: OutboxRow) throws {
        try change(
            "INSERT INTO outbox (message_id, recipient, payload) VALUES (?, ?, ?)",
            [.blob(row.messageID), .blob(row.recipient), .blob(row.payload)]
        )
    }

    public func removeFromOutbox(_ messageID: Data) throws {
        try change("DELETE FROM outbox WHERE message_id = ?", [.blob(messageID)])
    }

    /// Adds a message to the log and returns its position, which is above every position
    /// that a message of the log ever had (section 39.8).
    @discardableResult
    public func logMessage(_ contact: Data, direction: MessageDirection, messageID: Data, text: String) throws -> Int64 {
        try insertNumbered(
            "messages", columns: "contact, direction, message_id, text",
            [.blob(contact), .text(direction.rawValue), .blob(messageID), .text(text)]
        )
    }

    public func addUpload(_ upload: UploadRow, blob: Data) throws {
        try change(
            "INSERT INTO uploads (blob_id, contact, message_id, attachment, blob) VALUES (?, ?, ?, ?, ?)",
            [.blob(upload.blobID), .blob(upload.contact), .blob(upload.messageID), .blob(try upload.attachment.serializedBytes()), .blob(blob)]
        )
    }

    /// Deletes an upload, and the profile send that it carries, if it carries one.
    public func deleteUpload(_ blobID: Data) throws {
        try change("DELETE FROM uploads WHERE blob_id = ?", [.blob(blobID)])
        try change("DELETE FROM profile_sends WHERE blob_id = ?", [.blob(blobID)])
    }

    public func deleteFile(_ position: Int64) throws {
        try change("DELETE FROM files WHERE position = ?", [.integer(position)])
        try change("DELETE FROM downloads WHERE position = ?", [.integer(position)])
    }

    public func setOwnProfile(_ profile: OwnProfile) throws {
        try change(
            Schema.setOwnProfile,
            [
                .text(profile.name), profile.avatar.map(SQLValue.blob) ?? .null, .text(profile.mediaType),
                .blob(profile.thumbnail), .integer(Int64(profile.width)), .integer(Int64(profile.height)),
            ]
        )
    }

    /// Marks the own profile as owed to a contact; a send already owed stays as it is.
    public func oweProfile(_ contact: Data) throws {
        try change("INSERT INTO profile_sends (contact) VALUES (?) ON CONFLICT DO NOTHING", [.blob(contact)])
    }

    public func startProfileUpload(_ contact: Data, blobID: Data) throws {
        try change("UPDATE profile_sends SET blob_id = ? WHERE contact = ?", [.blob(blobID), .blob(contact)])
    }

    public func deleteProfileSend(_ contact: Data) throws {
        try change("DELETE FROM profile_sends WHERE contact = ?", [.blob(contact)])
    }

    /// Saves the latest profile of a contact; its avatar is not received yet.
    public func setProfile(_ contact: Data, name: String, avatarFile: Int64?) throws {
        try change(Schema.setProfile, [.blob(contact), .text(name), avatarFile.map(SQLValue.integer) ?? .null])
    }

    public func deleteProfile(_ contact: Data) throws {
        try change("DELETE FROM profiles WHERE contact = ?", [.blob(contact)])
    }

    public func setAvatar(_ avatarFile: Int64, _ picture: Data) throws {
        try change("UPDATE profiles SET avatar = ? WHERE avatar_file = ?", [.blob(picture), .integer(avatarFile)])
    }

    @discardableResult
    public func addFile(
        _ contact: Data, incoming: Bool, messageID: Data, attachment: Sotto_Attachment, state: FileState,
        savedAs: String? = nil
    ) throws -> Int64 {
        try insertNumbered(
            "files", columns: "contact, direction, message_id, attachment, state, saved_as",
            [
                .blob(contact), .text(Self.direction(incoming)), .blob(messageID),
                .blob(try attachment.serializedBytes()), .text(state.rawValue), savedAs.map(SQLValue.text) ?? .null,
            ]
        )
    }

    /// Sets the state of a file and drops its downloaded bytes; a nil `savedAs` keeps the path.
    public func setFileState(_ position: Int64, _ state: FileState, savedAs: String? = nil, result: String? = nil) throws {
        try change(
            "UPDATE files SET state = ?, saved_as = coalesce(?, saved_as), result = ?, held = 0 WHERE position = ?",
            [.text(state.rawValue), savedAs.map(SQLValue.text) ?? .null, result.map(SQLValue.text) ?? .null, .integer(position)]
        )
        try change("DELETE FROM downloads WHERE position = ?", [.integer(position)])
    }

    /// Makes room for the `length` bytes of a download, unless it has its room.
    public func beginDownload(_ position: Int64, length: Int) throws {
        try change("UPDATE files SET state = ? WHERE position = ?", [.text(FileState.receiving.rawValue), .integer(position)])
        try change(
            "INSERT INTO downloads VALUES (?, zeroblob(?)) ON CONFLICT DO NOTHING", [.integer(position), .integer(Int64(length))]
        )
    }

    /// A download that waits for the user again: it is offered and keeps the bytes it holds.
    public func pauseDownload(_ position: Int64) throws {
        try change(
            "UPDATE files SET state = ? WHERE position = ? AND state = ?",
            [.text(FileState.offered.rawValue), .integer(position), .text(FileState.receiving.rawValue)]
        )
    }

    /// Writes `data` at the held length of a download and counts it as held.
    public func addDownloadPiece(_ position: Int64, _ data: Data) throws {
        guard let held = try change("SELECT held FROM files WHERE position = ?", [.integer(position)]).first?[0].integer else {
            throw InvalidInputError(message: "the store holds no file at this position")
        }
        try writeBlob("downloads", "bytes", row: position, offset: Int(held), data)
        try change("UPDATE files SET held = held + ? WHERE position = ?", [.integer(Int64(data.count)), .integer(position)])
    }

    public func addBlobDeletion(uploader: Data, blobID: Data) throws {
        try change("INSERT INTO blob_deletions VALUES (?, ?) ON CONFLICT DO NOTHING", [.blob(uploader), .blob(blobID)])
    }

    public func deleteBlobDeletion(uploader: Data, blobID: Data) throws {
        try change("DELETE FROM blob_deletions WHERE uploader = ? AND blob_id = ?", [.blob(uploader), .blob(blobID)])
    }

    /// Inserts a row at a position above every position the table ever had, so that a
    /// position of a row that is gone is never given to another one (section 39.8). SQLite
    /// gives the highest `INTEGER PRIMARY KEY` again once its row is deleted.
    private func insertNumbered(_ table: String, columns: String, _ values: [SQLValue]) throws -> Int64 {
        let marks = Array(repeating: "?", count: values.count).joined(separator: ", ")
        let position = try change(
            """
            INSERT INTO \(table) (position, \(columns)) VALUES (
                max(
                    coalesce((SELECT max(position) FROM \(table)), 0),
                    coalesce((SELECT last_number FROM row_numbers WHERE name = '\(table)'), 0)
                ) + 1, \(marks)
            ) RETURNING position
            """,
            values
        )[0][0].integer!
        try change(
            "INSERT INTO row_numbers VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET last_number = excluded.last_number",
            [.text(table), .integer(position)]
        )
        return position
    }

    // MARK: SQLite

    private func readBlob(_ table: String, _ column: String, row: Int64, offset: Int, length: Int) throws -> Data {
        var handle: OpaquePointer?
        defer { sqlite3_blob_close(handle) }
        var code = sqlite3_blob_open(connection, "main", table, column, row, 0, &handle)
        guard code == SQLITE_OK else {
            throw Self.sqliteError(connection, code)
        }
        let count = max(0, min(length, Int(sqlite3_blob_bytes(handle)) - offset))
        var data = Data(count: count)
        if count > 0 {
            code = data.withUnsafeMutableBytes { sqlite3_blob_read(handle, $0.baseAddress, Int32(count), Int32(offset)) }
            guard code == SQLITE_OK else {
                throw Self.sqliteError(connection, code)
            }
        }
        return data
    }

    private func writeBlob(_ table: String, _ column: String, row: Int64, offset: Int, _ data: Data) throws {
        guard isInTransaction else {
            throw StoreError.writeOutsideTransaction
        }
        var handle: OpaquePointer?
        defer { sqlite3_blob_close(handle) }
        var code = sqlite3_blob_open(connection, "main", table, column, row, 1, &handle)
        guard code == SQLITE_OK else {
            throw Self.sqliteError(connection, code)
        }
        code = data.withUnsafeBytes { sqlite3_blob_write(handle, $0.baseAddress, Int32($0.count), Int32(offset)) }
        guard code == SQLITE_OK else {
            throw Self.sqliteError(connection, code)
        }
    }

    var isInTransaction: Bool {
        sqlite3_get_autocommit(connection) == 0
    }

    @discardableResult
    private func change(_ statement: String, _ parameters: [SQLValue] = []) throws -> [[SQLValue]] {
        guard isInTransaction else {
            throw StoreError.writeOutsideTransaction
        }
        return try query(statement, parameters)
    }

    /// Runs one statement with its values bound as parameters and returns its rows.
    @discardableResult
    func query(_ statement: String, _ parameters: [SQLValue] = []) throws -> [[SQLValue]] {
        var prepared: OpaquePointer?
        let code = sqlite3_prepare_v2(connection, statement, -1, &prepared, nil)
        defer { sqlite3_finalize(prepared) }
        guard code == SQLITE_OK else {
            throw Self.sqliteError(connection, code)
        }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let bound = switch parameter {
            case .null: sqlite3_bind_null(prepared, index)
            case .integer(let value): sqlite3_bind_int64(prepared, index, value)
            case .text(let value):
                value.withCString { sqlite3_bind_text(prepared, index, $0, Int32(value.utf8.count), Self.transient) }
            case .blob(let value) where value.isEmpty: sqlite3_bind_zeroblob(prepared, index, 0)
            case .blob(let value):
                value.withUnsafeBytes { sqlite3_bind_blob(prepared, index, $0.baseAddress, Int32($0.count), Self.transient) }
            }
            guard bound == SQLITE_OK else {
                throw Self.sqliteError(connection, bound)
            }
        }

        var rows: [[SQLValue]] = []
        while true {
            let stepped = sqlite3_step(prepared)
            if stepped == SQLITE_DONE {
                return rows
            }
            guard stepped == SQLITE_ROW else {
                throw Self.sqliteError(connection, stepped)
            }
            rows.append((0..<sqlite3_column_count(prepared)).map { Self.column(prepared, $0) })
        }
    }

    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func column(_ statement: OpaquePointer?, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_text(statement, index) else {
                return .text("")
            }
            return .text(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else {
                return .blob(Data())
            }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }

    private static func sqliteError(_ connection: OpaquePointer?, _ code: Int32) -> StoreError {
        .sqlite(code: code, message: connection.map { String(cString: sqlite3_errmsg($0)) } ?? "")
    }

    private static func session(_ row: [SQLValue]) throws -> StoredSession {
        StoredSession(
            sessionID: row[0].integer!,
            contact: row[1].data!,
            associatedData: row[2].data!,
            state: try JSONDecoder().decode(RatchetState.self, from: Data(row[3].text!.utf8)),
            initialHeader: row[4].data
        )
    }

    private static func file(_ row: [SQLValue]) throws -> FileRow {
        FileRow(
            position: row[0].integer!,
            contact: row[1].data!,
            incoming: row[2].text! == MessageDirection.incoming.rawValue,
            messageID: row[3].data!,
            attachment: try Sotto_Attachment(serializedBytes: row[4].data ?? Data()),
            state: FileState(rawValue: row[5].text!) ?? .notAvailable,
            held: Int(row[6].integer!),
            savedAs: row[7].text,
            result: row[8].text,
            avatar: row[9].integer! == 1,
            kept: row[10].integer! == 1
        )
    }

    private static func message(_ row: [SQLValue]) -> StoredMessage {
        StoredMessage(
            position: row[0].integer!,
            contact: row[1].data!,
            direction: MessageDirection(rawValue: row[2].text!)!,
            messageID: row[3].data!,
            text: row[4].text!,
            writtenAt: row[5].integer,
            edits: Int(row[6].integer!),
            expiresAfter: Int(row[7].integer!),
            expiresAt: row[8].integer,
            readAt: row[9].integer,
            receipt: row[10].text.flatMap(ReceiptKind.init),
            owed: row[11].text.flatMap(ReceiptKind.init),
            quote: row[12].text.map { StoredQuote(incoming: $0 == "in", messageID: row[13].data!, text: row[14].text) }
        )
    }

    private static func direction(_ incoming: Bool) -> String {
        (incoming ? MessageDirection.incoming : .outgoing).rawValue
    }

    private static func profile(_ row: [SQLValue]) -> ContactProfile {
        ContactProfile(contact: row[0].data!, name: row[1].text!, avatarFile: row[2].integer, avatar: row[3].data)
    }

    private static func encode(_ state: RatchetState) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(state), as: UTF8.self)
    }

    // MARK: Encryption

    /// The version of SQLCipher that serves this connection; empty for plain SQLite.
    public func cipherVersion() throws -> String {
        try query("PRAGMA cipher_version").first?[0].text ?? ""
    }

    public func cipherProvider() throws -> String {
        try query("PRAGMA cipher_provider").first?[0].text ?? ""
    }

    /// The rows of a read-only statement as JSON, blobs as `{"hex": ...}`, for the scripts
    /// that check a store of the test kind; any other store refuses.
    public func testRowsJSON(_ statement: String) throws -> Data {
        guard StoreKeys.protection(directory) == .test else { throw StoreError.notATestStore }
        try query("PRAGMA query_only=ON")
        defer { _ = try? query("PRAGMA query_only=OFF") }
        let rows: [[Any]] = try query(statement).map { row in
            row.map { value -> Any in
                switch value {
                case .null: NSNull()
                case .integer(let number): number
                case .text(let text): text
                case .blob(let data): ["hex": data.map { String(format: "%02x", $0) }.joined()]
                }
            }
        }
        return try JSONSerialization.data(withJSONObject: rows)
    }

    /// The file of the library whose `sqlite3_open_v2` this code calls.
    public static var servingLibrary: String {
        var info = Dl_info()
        let symbol = unsafeBitCast(sqlite3_libversion as @convention(c) () -> UnsafePointer<CChar>?, to: UnsafeRawPointer.self)
        guard dladdr(symbol, &info) != 0, let name = info.dli_fname else { return "" }
        return String(cString: name)
    }

    static let plainHeader = Data("SQLite format 3\0".utf8)
    static let encryptingSuffix = ".encrypting"
    static let plainSuffix = ".plain"

    static func header(_ path: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: plainHeader.count)
    }

    static func isPlain(_ path: URL) throws -> Bool {
        header(path) == plainHeader
    }

    /// Whether the file holds pages that are not plain SQLite: an encrypted store.
    static func holdsEncryptedPages(_ path: URL) throws -> Bool {
        guard let first = header(path), !first.isEmpty else { return false }
        return first != plainHeader
    }

    private static func connect(_ path: URL, _ literal: UnsafeRawBufferPointer?, flags: Int32) throws -> OpaquePointer? {
        var opened: OpaquePointer?
        var code = sqlite3_open_v2(path.path, &opened, flags | SQLITE_OPEN_FULLMUTEX, nil)
        if code == SQLITE_OK, let literal {
            code = sqlite3_key(opened, literal.baseAddress, Int32(literal.count))
        }
        guard code == SQLITE_OK else {
            let error = sqliteError(opened, code)
            sqlite3_close_v2(opened)
            throw error
        }
        sqlite3_busy_timeout(opened, busyTimeoutMilliseconds)
        return opened
    }

    /// Refuses a connection whose key opens no page, and one that SQLCipher does not serve.
    private static func check(_ connection: OpaquePointer?) throws {
        let code = sqlite3_exec(connection, "SELECT count(*) FROM sqlite_schema", nil, nil, nil)
        if code == SQLITE_NOTADB {
            throw StoreError.wrongKey
        }
        guard code == SQLITE_OK else { throw sqliteError(connection, code) }
        var version: OpaquePointer?
        defer { sqlite3_finalize(version) }
        guard sqlite3_prepare_v2(connection, "PRAGMA cipher_version", -1, &version, nil) == SQLITE_OK,
            sqlite3_step(version) == SQLITE_ROW, sqlite3_column_bytes(version, 0) > 0
        else { throw StoreError.notSQLCipher }
    }

    /// Exports the plain store into an encrypted copy, checks that every table kept its rows,
    /// puts the copy in place by a rename and overwrites the plain file. Until the rename the
    /// plain store stays whole; after it the encrypted one is the store.
    private static func encrypt(_ path: URL, _ literal: UnsafeRawBufferPointer) throws {
        let staging = URL(fileURLWithPath: path.path + encryptingSuffix)
        let plainLink = URL(fileURLWithPath: path.path + plainSuffix)
        unlink(staging.path)
        try makePrivateFile(staging)

        let plain = try connect(path, nil, flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close_v2(plain) }
        let attach = "ATTACH DATABASE ? AS encrypted KEY ?"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(plain, attach, -1, &statement, nil) == SQLITE_OK else { throw sqliteError(plain, sqlite3_errcode(plain)) }
        sqlite3_bind_text(statement, 1, staging.path, -1, transient)
        // Bound without a copy: the literal outlives the statement, and SQLite keeps no copy
        // of the key that is never overwritten.
        sqlite3_bind_text(statement, 2, literal.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(literal.count), nil)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError(plain, sqlite3_errcode(plain)) }
        let exported = sqlite3_exec(plain, "SELECT sqlcipher_export('encrypted')", nil, nil, nil)
        guard exported == SQLITE_OK else { throw sqliteError(plain, exported) }
        try compareRows(plain)
        let detached = sqlite3_exec(plain, "DETACH DATABASE encrypted", nil, nil, nil)
        guard detached == SQLITE_OK else { throw sqliteError(plain, detached) }

        try fullSync(staging)
        unlink(plainLink.path)
        guard link(path.path, plainLink.path) == 0 else { throw StoreError.system(path: plainLink.path, errno: errno) }
        guard rename(staging.path, path.path) == 0 else { throw StoreError.system(path: path.path, errno: errno) }
        try fullSync(path.deletingLastPathComponent())
        try overwriteAndRemove(plainLink)
    }

    /// Every table of the plain store has as many rows in the encrypted copy.
    private static func compareRows(_ plain: OpaquePointer?) throws {
        func integers(_ sql: String) throws -> [Int64] {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(plain, sql, -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(plain, sqlite3_errcode(plain))
            }
            var values: [Int64] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                values.append(sqlite3_column_int64(statement, 0))
            }
            return values
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        sqlite3_prepare_v2(plain, "SELECT name FROM main.sqlite_schema WHERE type = 'table'", -1, &statement, nil)
        while sqlite3_step(statement) == SQLITE_ROW {
            let table = String(cString: sqlite3_column_text(statement, 0))
            let quoted = "\"" + table.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let before = try integers("SELECT count(*) FROM main.\(quoted)")
            let after = try? integers("SELECT count(*) FROM encrypted.\(quoted)")
            if before != after {
                throw StoreError.migrationLostRows(table: table)
            }
        }
    }

    /// Ends what a stopped `encrypt` left: an unfinished copy is removed (the plain store is
    /// still the store), a plain file left beside the encrypted store is overwritten.
    private static func finishEncrypting(_ path: URL) throws {
        unlink(path.path + encryptingSuffix)
        let plainLink = URL(fileURLWithPath: path.path + plainSuffix)
        guard FileManager.default.fileExists(atPath: plainLink.path) else { return }
        var store = stat()
        var left = stat()
        if stat(path.path, &store) == 0, lstat(plainLink.path, &left) == 0, store.st_ino == left.st_ino {
            unlink(plainLink.path)
        } else {
            try overwriteAndRemove(plainLink)
        }
    }

    /// Runs `body` under an exclusive `flock` on the directory, which every open of a store
    /// takes, in this process and in others: the first key and the migration happen once.
    static func whileHolding<T>(_ directory: URL, _ body: () throws -> T) throws -> T {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw StoreError.system(path: directory.path, errno: errno) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw StoreError.system(path: directory.path, errno: errno) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Writes zeros over the whole file, syncs it and removes it. On an SSD and under
    /// snapshots the old blocks may outlive this (docs/key-storage.md).
    public static func overwriteAndRemove(_ file: URL) throws {
        let descriptor = Darwin.open(file.path, O_WRONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw StoreError.system(path: file.path, errno: errno) }
        defer { Darwin.close(descriptor) }
        var status = stat()
        fstat(descriptor, &status)
        let zeros = [UInt8](repeating: 0, count: 1 << 16)
        var left = Int(status.st_size)
        while left > 0 {
            let written = write(descriptor, zeros, min(left, zeros.count))
            guard written > 0 else { throw StoreError.system(path: file.path, errno: errno) }
            left -= written
        }
        _ = fcntl(descriptor, F_FULLFSYNC)
        guard unlink(file.path) == 0 else { throw StoreError.system(path: file.path, errno: errno) }
    }

    static func fullSync(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw StoreError.system(path: url.path, errno: errno) }
        defer { Darwin.close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw StoreError.system(path: url.path, errno: errno)
        }
    }

    // MARK: Modes

    static func makePrivateDirectory(_ directory: URL) throws {
        if mkdir(directory.path, directoryMode) == 0 {
            chmod(directory.path, directoryMode)
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            chmod(directory.path, directoryMode)
        } else if errno != EEXIST {
            throw StoreError.system(path: directory.path, errno: errno)
        }
        try refuseWideMode(directory)
    }

    private static func makePrivateFile(_ path: URL) throws {
        let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL, fileMode)
        if descriptor >= 0 {
            fchmod(descriptor, fileMode)
            Darwin.close(descriptor)
        } else if errno != EEXIST {
            throw StoreError.system(path: path.path, errno: errno)
        }
        try refuseWideMode(path)
    }

    private static func refuseWideMode(_ path: URL) throws {
        var status = stat()
        guard stat(path.path, &status) == 0 else {
            throw StoreError.system(path: path.path, errno: errno)
        }
        let mode = status.st_mode & 0o7777
        if mode & widerThanOwner != 0 {
            throw StoreError.wideMode(path: path.path, mode: UInt16(mode))
        }
    }
}

enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case text(String)
    case blob(Data)

    var integer: Int64? {
        if case .integer(let value) = self { value } else { nil }
    }

    var text: String? {
        if case .text(let value) = self { value } else { nil }
    }

    var data: Data? {
        if case .blob(let value) = self { value } else { nil }
    }
}

private enum Schema {
    static let tables = [
        """
        CREATE TABLE IF NOT EXISTS identity (
            only_row INTEGER PRIMARY KEY CHECK (only_row = 1),
            seed BLOB NOT NULL,
            identity_dh_private_key BLOB NOT NULL,
            last_signed_prekey_id INTEGER NOT NULL,
            last_one_time_prekey_id INTEGER NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE IF NOT EXISTS signed_prekeys (
            prekey_id INTEGER PRIMARY KEY,
            private_key BLOB NOT NULL,
            made_at INTEGER NOT NULL,
            replaced_at INTEGER,
            confirmed INTEGER NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE IF NOT EXISTS one_time_prekeys (
            prekey_id INTEGER PRIMARY KEY,
            private_key BLOB NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE IF NOT EXISTS contacts (
            identity_key BLOB PRIMARY KEY,
            pinned_identity_dh_key BLOB,
            name TEXT UNIQUE
        ) STRICT, WITHOUT ROWID
        """,
        // AUTOINCREMENT: a record keeps the id of a session that is gone, and no later
        // session may take that id.
        """
        CREATE TABLE IF NOT EXISTS sessions (
            session_id INTEGER PRIMARY KEY AUTOINCREMENT,
            contact BLOB NOT NULL,
            position INTEGER NOT NULL,
            associated_data BLOB NOT NULL,
            state TEXT NOT NULL,
            initial_header BLOB
        ) STRICT
        """,
        """
        CREATE TABLE IF NOT EXISTS records (
            sender BLOB NOT NULL,
            ephemeral_key BLOB NOT NULL,
            session_id INTEGER NOT NULL,
            signed_prekey_id INTEGER NOT NULL,
            PRIMARY KEY (sender, ephemeral_key)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS seen_ids (
            sender BLOB NOT NULL,
            message_id BLOB NOT NULL,
            seen_at INTEGER NOT NULL,
            PRIMARY KEY (sender, message_id)
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS outbox (
            position INTEGER PRIMARY KEY,
            message_id BLOB NOT NULL UNIQUE,
            recipient BLOB NOT NULL,
            payload BLOB NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE IF NOT EXISTS messages (
            position INTEGER PRIMARY KEY,
            contact BLOB NOT NULL,
            direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
            message_id BLOB NOT NULL,
            text TEXT NOT NULL
        ) STRICT
        """,
        // The two tables below are this client's own, beyond section 22.1 (section 22.4).
        """
        CREATE TABLE IF NOT EXISTS pending (
            position INTEGER PRIMARY KEY,
            contact BLOB NOT NULL,
            text TEXT NOT NULL,
            made_at INTEGER NOT NULL,
            failure TEXT
        ) STRICT
        """,
        """
        CREATE TABLE IF NOT EXISTS refusals (
            message_id BLOB PRIMARY KEY,
            result TEXT NOT NULL
        ) STRICT, WITHOUT ROWID
        """,
        // Part 3 (section 33.7). `message_id` of an upload is the id its message takes.
        """
        CREATE TABLE IF NOT EXISTS uploads (
            position INTEGER PRIMARY KEY,
            blob_id BLOB NOT NULL UNIQUE,
            contact BLOB NOT NULL,
            message_id BLOB NOT NULL,
            attachment BLOB NOT NULL,
            blob BLOB NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE IF NOT EXISTS files (
            position INTEGER PRIMARY KEY,
            contact BLOB NOT NULL,
            direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
            message_id BLOB NOT NULL,
            attachment BLOB NOT NULL,
            state TEXT NOT NULL,
            held INTEGER NOT NULL DEFAULT 0,
            saved_as TEXT,
            result TEXT
        ) STRICT
        """,
        // Apart from `files`, so that counting a piece in `held` does not rewrite the blob.
        """
        CREATE TABLE IF NOT EXISTS downloads (
            position INTEGER PRIMARY KEY,
            bytes BLOB NOT NULL
        ) STRICT
        """,
        """
        CREATE TABLE IF NOT EXISTS blob_deletions (
            uploader BLOB NOT NULL,
            blob_id BLOB NOT NULL,
            PRIMARY KEY (uploader, blob_id)
        ) STRICT, WITHOUT ROWID
        """,
        // Part 4 (section 36.1). The own profile keeps the thumbnail and the size that it
        // sends with the picture.
        """
        CREATE TABLE IF NOT EXISTS own_profile (
            only_row INTEGER PRIMARY KEY CHECK (only_row = 1),
            name TEXT NOT NULL,
            avatar BLOB,
            media_type TEXT NOT NULL,
            thumbnail BLOB NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL
        ) STRICT
        """,
        // The latest profile of each contact; `avatar_file` is the row of `files` that
        // carries its avatar, which is no attachment of the message log.
        """
        CREATE TABLE IF NOT EXISTS profiles (
            contact BLOB PRIMARY KEY,
            name TEXT NOT NULL,
            avatar_file INTEGER UNIQUE,
            avatar BLOB
        ) STRICT, WITHOUT ROWID
        """,
        // The contacts owed the own profile; `blob_id` names the upload of its avatar.
        """
        CREATE TABLE IF NOT EXISTS profile_sends (
            contact BLOB PRIMARY KEY,
            blob_id BLOB UNIQUE
        ) STRICT, WITHOUT ROWID
        """,
        // Part 5 (section 39.10): what is kept of a message of the log, by the id its sender
        // chose. A row without its message is a trace: a change that came first, or a
        // message that is gone. `receipt` is what the peer reported of an own message,
        // `owed` the receipt to send.
        """
        CREATE TABLE IF NOT EXISTS message_states (
            contact BLOB NOT NULL,
            direction TEXT NOT NULL CHECK (direction IN ('in', 'out')),
            message_id BLOB NOT NULL,
            written_at INTEGER NOT NULL,
            quote_direction TEXT CHECK (quote_direction IN ('in', 'out')),
            quote_id BLOB,
            quote_text TEXT,
            edits INTEGER NOT NULL DEFAULT 0,
            early_text TEXT,
            gone INTEGER NOT NULL DEFAULT 0,
            receipt TEXT CHECK (receipt IN ('delivered', 'read')),
            owed TEXT CHECK (owed IN ('delivered', 'read')),
            read_at INTEGER,
            expires_after INTEGER NOT NULL DEFAULT 0,
            expires_at INTEGER,
            PRIMARY KEY (contact, direction, message_id)
        ) STRICT, WITHOUT ROWID
        """,
        "CREATE INDEX IF NOT EXISTS messages_by_id ON messages (contact, direction, message_id)",
        "CREATE INDEX IF NOT EXISTS message_states_by_expiry ON message_states (expires_at)",
        """
        CREATE TABLE IF NOT EXISTS timers (
            contact BLOB PRIMARY KEY,
            seconds INTEGER NOT NULL
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS settings (
            only_row INTEGER PRIMARY KEY CHECK (only_row = 1),
            read_receipts INTEGER NOT NULL
        ) STRICT
        """,
        // This client's own: the bytes of a file kept in the store instead of a folder, which
        // go with their row of `files` (docs/key-storage.md).
        """
        CREATE TABLE IF NOT EXISTS kept_files (
            position INTEGER PRIMARY KEY,
            bytes BLOB NOT NULL
        ) STRICT
        """,
        """
        CREATE TRIGGER IF NOT EXISTS kept_files_go_with_their_file AFTER DELETE ON files BEGIN
            DELETE FROM kept_files WHERE position = old.position;
        END
        """,
        // The notes of the app: drafts, read positions, times, pins and its settings, as JSON.
        """
        CREATE TABLE IF NOT EXISTS app_notes (
            only_row INTEGER PRIMARY KEY CHECK (only_row = 1),
            notes BLOB NOT NULL
        ) STRICT
        """,
        // This client's own: the highest position that a row of `messages`, `pending` and
        // `files` ever had (section 39.8), and the message a pending text answers.
        """
        CREATE TABLE IF NOT EXISTS row_numbers (
            name TEXT PRIMARY KEY,
            last_number INTEGER NOT NULL
        ) STRICT, WITHOUT ROWID
        """,
        """
        CREATE TABLE IF NOT EXISTS pending_replies (
            position INTEGER PRIMARY KEY,
            reply_to INTEGER NOT NULL
        ) STRICT
        """,
    ]

    static let readMessages = """
        SELECT m.position, m.contact, m.direction, m.message_id, m.text, s.written_at, coalesce(s.edits, 0),
            coalesce(s.expires_after, 0), s.expires_at, s.read_at, s.receipt, s.owed, s.quote_direction, s.quote_id,
            s.quote_text
        FROM messages m LEFT JOIN message_states s
            ON s.contact = m.contact AND s.direction = m.direction AND s.message_id = m.message_id
        """
    static let saveState = """
        INSERT INTO message_states (contact, direction, message_id, written_at, quote_direction, quote_id, quote_text,
            expires_after, expires_at, owed)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (contact, direction, message_id) DO UPDATE SET
            written_at = excluded.written_at, quote_direction = excluded.quote_direction, quote_id = excluded.quote_id,
            quote_text = excluded.quote_text, expires_after = excluded.expires_after, expires_at = excluded.expires_at,
            owed = excluded.owed, early_text = NULL
        """
    static let countEdit = """
        INSERT INTO message_states (contact, direction, message_id, written_at, edits, early_text)
        VALUES (?, ?, ?, ?, 1, ?)
        ON CONFLICT (contact, direction, message_id) DO UPDATE SET edits = edits + 1, early_text = excluded.early_text
        """
    static let leaveTrace = """
        INSERT INTO message_states (contact, direction, message_id, written_at, gone)
        VALUES (?, ?, ?, ?, 1)
        ON CONFLICT (contact, direction, message_id) DO UPDATE SET
            written_at = excluded.written_at, gone = 1, quote_direction = NULL, quote_id = NULL, quote_text = NULL,
            early_text = NULL, receipt = NULL, owed = NULL, read_at = NULL, expires_after = 0, expires_at = NULL
        """
    static let setRead = """
        INSERT INTO message_states (contact, direction, message_id, written_at, read_at, expires_at, owed)
        VALUES (?, 'in', ?, ?, ?, ?, ?)
        ON CONFLICT (contact, direction, message_id) DO UPDATE SET
            read_at = excluded.read_at, expires_at = excluded.expires_at, owed = excluded.owed
        """
    static let forgetTraces = """
        DELETE FROM message_states WHERE written_at <= ? AND NOT EXISTS (
            SELECT 1 FROM messages m WHERE m.contact = message_states.contact
                AND m.direction = message_states.direction AND m.message_id = message_states.message_id
        )
        """

    static let readFiles = """
        SELECT position, contact, direction, message_id, attachment, state, held, saved_as, result,
            position IN (SELECT avatar_file FROM profiles WHERE avatar_file IS NOT NULL),
            position IN (SELECT position FROM kept_files)
        FROM files
        """
    static let readUploads = """
        SELECT blob_id, contact, message_id, attachment, length(blob),
            blob_id IN (SELECT blob_id FROM profile_sends WHERE blob_id IS NOT NULL)
        FROM uploads ORDER BY position
        """
    static let readProfiles = "SELECT contact, name, avatar_file, avatar FROM profiles"
    static let setOwnProfile = """
        INSERT INTO own_profile VALUES (1, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (only_row) DO UPDATE SET
            name = excluded.name, avatar = excluded.avatar, media_type = excluded.media_type,
            thumbnail = excluded.thumbnail, width = excluded.width, height = excluded.height
        """
    static let setProfile = """
        INSERT INTO profiles VALUES (?, ?, ?, NULL)
        ON CONFLICT (contact) DO UPDATE SET name = excluded.name, avatar_file = excluded.avatar_file, avatar = NULL
        """

    static let addSession = """
        INSERT INTO sessions (contact, position, associated_data, state, initial_header)
        VALUES (?, (SELECT coalesce(max(position), 0) + 1 FROM sessions), ?, ?, ?)
        RETURNING session_id
        """
    static let countSkippedKeysBehind = """
        SELECT coalesce(sum(json_array_length(state, '$.mkskipped')), 0) FROM sessions
        WHERE contact = ? AND session_id NOT IN (
            SELECT session_id FROM sessions WHERE contact = ? ORDER BY position DESC LIMIT ?
        )
        """
    static let dropSessionsBehind = """
        DELETE FROM sessions WHERE contact = ? AND session_id NOT IN (
            SELECT session_id FROM sessions WHERE contact = ? ORDER BY position DESC LIMIT ?
        )
        """
    // A record outlives its session until the private key of its signed prekey is deleted
    // (section 20.4).
    static let deleteOrphanRecords = """
        DELETE FROM records
        WHERE session_id NOT IN (SELECT session_id FROM sessions)
            AND signed_prekey_id NOT IN (SELECT prekey_id FROM signed_prekeys)
        """
    static let acceptOnSession = """
        UPDATE sessions SET
            state = ?,
            initial_header = NULL,
            position = (SELECT max(position) + 1 FROM sessions)
        WHERE session_id = ?
        """
    static let readSessions = """
        SELECT session_id, contact, associated_data, state, initial_header FROM sessions
        WHERE contact = ? ORDER BY position DESC
        """
    static let readSession = """
        SELECT session_id, contact, associated_data, state, initial_header FROM sessions
        WHERE session_id = ?
        """
    static let readSignedPrekey = """
        SELECT private_key FROM signed_prekeys
        WHERE prekey_id = ? AND (replaced_at IS NULL OR replaced_at > ?)
        """
    static let readNewestSignedPrekey = """
        SELECT prekey_id, private_key, made_at, confirmed FROM signed_prekeys
        WHERE replaced_at IS NULL
        """
    static let countSignedPrekey = """
        UPDATE identity SET last_signed_prekey_id = last_signed_prekey_id + 1
        WHERE last_signed_prekey_id < ? RETURNING last_signed_prekey_id
        """
    static let countOneTimePrekey = """
        UPDATE identity SET last_one_time_prekey_id = last_one_time_prekey_id + 1
        WHERE last_one_time_prekey_id < ? RETURNING last_one_time_prekey_id
        """
    static let deleteLowestOneTimePrekeys = """
        DELETE FROM one_time_prekeys WHERE prekey_id IN (
            SELECT prekey_id FROM one_time_prekeys ORDER BY prekey_id LIMIT ?
        )
        """
}
