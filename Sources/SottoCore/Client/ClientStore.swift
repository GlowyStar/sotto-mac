import Foundation
import SQLite3

public enum StoreError: Error, Equatable, Sendable {
    /// The directory or the file of the store gives a right to the group or to others.
    case wideMode(path: String, mode: UInt16)
    case writeOutsideTransaction
    case noIdentity
    case system(path: String, errno: Int32)
    case sqlite(code: Int32, message: String)
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

/// A row of the message log; `position` grows with every new row.
public struct StoredMessage: Equatable, Sendable {
    public var position: Int64
    public var direction: MessageDirection
    public var messageID: Data
    public var text: String
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

    public let path: URL
    private var connection: OpaquePointer?

    /// Opens the store in `directory`, making the directory and the file when they are
    /// missing, and refuses either when its mode has one of the bits 077.
    public init(directory: URL) throws {
        path = directory.appendingPathComponent(Self.fileName)
        try Self.makePrivateDirectory(directory)
        try Self.makePrivateFile(path)

        var opened: OpaquePointer?
        let code = sqlite3_open_v2(path.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        connection = opened
        guard code == SQLITE_OK else {
            let error = Self.sqliteError(opened, code)
            sqlite3_close_v2(opened)
            connection = nil
            throw error
        }
        sqlite3_busy_timeout(connection, Self.busyTimeoutMilliseconds)
        try query("PRAGMA journal_mode=DELETE")
        try query("PRAGMA secure_delete=ON")
        try transaction {
            for table in Schema.tables {
                try change(table)
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
        try query(
            "SELECT position, direction, message_id, text FROM messages WHERE contact = ? ORDER BY position",
            [.blob(contact)]
        ).map {
            StoredMessage(
                position: $0[0].integer!,
                direction: MessageDirection(rawValue: $0[1].text!)!,
                messageID: $0[2].data!,
                text: $0[3].text!
            )
        }
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

    /// Deletes the contact and its sessions; its seen ids and records stay (section 20.6).
    public func removeContact(_ contact: Data) throws {
        try change("DELETE FROM sessions WHERE contact = ?", [.blob(contact)])
        try change("DELETE FROM contacts WHERE identity_key = ?", [.blob(contact)])
        try change(Schema.deleteOrphanRecords)
    }

    public func renameContact(_ contact: Data, name: String) throws {
        try change("UPDATE contacts SET name = ? WHERE identity_key = ?", [.text(name), .blob(contact)])
    }

    public func deleteMessages(_ contact: Data) throws {
        try change("DELETE FROM messages WHERE contact = ?", [.blob(contact)])
    }

    public func deleteMessage(_ position: Int64) throws {
        try change("DELETE FROM messages WHERE position = ?", [.integer(position)])
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

    public func logMessage(_ contact: Data, direction: MessageDirection, messageID: Data, text: String) throws {
        try change(
            "INSERT INTO messages (contact, direction, message_id, text) VALUES (?, ?, ?, ?)",
            [.blob(contact), .text(direction.rawValue), .blob(messageID), .text(text)]
        )
    }

    // MARK: SQLite

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

    private static func encode(_ state: RatchetState) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(state), as: UTF8.self)
    }

    // MARK: Modes

    private static func makePrivateDirectory(_ directory: URL) throws {
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
    ]

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
