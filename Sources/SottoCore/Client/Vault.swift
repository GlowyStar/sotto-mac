import CryptoKit
import Foundation

/// The hidden chats of a data directory (docs/key-storage.md): a second SQLCipher store,
/// `vault.db`, with the schema of the main store, keyed by a phrase through SQLCipher's own
/// key derivation. Every directory has the file from its first open, at first an empty vault
/// under a random key that nobody keeps, so that a store without hidden chats looks like one
/// with them; making a vault replaces it. The main store keeps nothing of a vault but the
/// public key that envelopes of senders it does not know are sealed to.
public enum Vault {
    public static let fileName = "vault.db"
    /// Rounds of PBKDF2-HMAC-SHA512 in SQLCipher's key derivation: about half a second for
    /// one open on the Mac it was measured on (docs/key-storage.md).
    static let kdfIterations = 1_600_000
    public static let minimumPhraseLength = 8
    /// The bounds of the sealed inbox, those of a queue of the relay.
    static let sealedMaxCount = 1000
    static let sealedMaxBytes = 16_777_216
    static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    static let inboxInfo = Data("sotto-mac sealed inbox 1".utf8)
    static let encapsulatedKeyLength = 65
    static let newSuffix = ".new"
    static let oldSuffix = ".old"
    static let decoySuffix = ".decoy"

    public static func path(_ directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// The phrase as it keys a vault: without the spaces around it, in Unicode form C.
    public static func normalized(_ phrase: String) -> String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    /// Opens the vault of `directory` with the phrase. `StoreError.wrongKey` when it does not
    /// open it, after the same key derivation whether the file is a vault or the decoy.
    static func open(_ directory: URL, phrase: String) throws -> ClientStore {
        guard normalized(phrase).count >= minimumPhraseLength else { throw StoreError.wrongKey }
        try ClientStore.whileHolding(directory) { try makeDecoy(directory) }
        return try ClientStore(vaultAt: path(directory), in: directory, key: Data(normalized(phrase).utf8), phrase: true)
    }

    /// Makes the decoy unless the directory has a vault file: an empty vault under a random
    /// raw key that is dropped, so random bytes of the size an empty vault has. Called under
    /// the lock of the directory.
    static func makeDecoy(_ directory: URL) throws {
        let file = path(directory)
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        let staging = URL(fileURLWithPath: file.path + decoySuffix)
        unlink(staging.path)
        defer { unlink(staging.path) }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let literal = Data(("x'" + key.map { String(format: "%02x", $0) }.joined() + "'").utf8)
        _ = try create(at: staging, in: directory, key: literal, phrase: false)
        try ClientStore.fullSync(staging)
        guard link(staging.path, file.path) == 0 || errno == EEXIST else {
            throw StoreError.system(path: file.path, errno: errno)
        }
        try ClientStore.fullSync(directory)
    }

    /// Makes a new vault under the phrase in place of the decoy or of the vault there, whose
    /// file is overwritten, and returns the public key of its inbox. No connection to the old
    /// vault may be open.
    static func make(_ directory: URL, phrase: String) throws -> Data {
        guard normalized(phrase).count >= minimumPhraseLength else { throw StoreError.wrongKey }
        return try ClientStore.whileHolding(directory) {
            let file = path(directory)
            let fresh = URL(fileURLWithPath: file.path + newSuffix)
            let old = URL(fileURLWithPath: file.path + oldSuffix)
            unlink(fresh.path)
            defer { unlink(fresh.path) }
            let publicKey = try create(at: fresh, in: directory, key: Data(normalized(phrase).utf8), phrase: true)
            try ClientStore.fullSync(fresh)
            unlink(old.path)
            guard link(file.path, old.path) == 0 || errno == ENOENT else {
                throw StoreError.system(path: old.path, errno: errno)
            }
            // A journal of the old vault would be played back onto the new one.
            let journal = URL(fileURLWithPath: file.path + "-journal")
            if FileManager.default.fileExists(atPath: journal.path) {
                try ClientStore.overwriteAndRemove(journal)
            }
            guard rename(fresh.path, file.path) == 0 else { throw StoreError.system(path: file.path, errno: errno) }
            try ClientStore.fullSync(directory)
            try finishReplacing(directory)
            return publicKey
        }
    }

    /// Ends what a stopped `make` or `makeDecoy` left: an unfinished file goes, the old vault
    /// beside its new one is overwritten. Called under the lock of the directory.
    static func finishReplacing(_ directory: URL) throws {
        let file = path(directory)
        for suffix in [newSuffix, decoySuffix] {
            unlink(file.path + suffix)
            unlink(file.path + suffix + "-journal")
        }
        let old = URL(fileURLWithPath: file.path + oldSuffix)
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        var current = stat()
        var left = stat()
        if stat(file.path, &current) == 0, lstat(old.path, &left) == 0, current.st_ino == left.st_ino {
            unlink(old.path)
        } else {
            try ClientStore.overwriteAndRemove(old)
        }
    }

    /// Writes an empty vault with its inbox key pair at `file`; returns the public key.
    private static func create(at file: URL, in directory: URL, key: Data, phrase: Bool) throws -> Data {
        let store = try ClientStore(vaultAt: file, in: directory, key: key, phrase: phrase)
        defer { store.close() }
        let inbox = P256.KeyAgreement.PrivateKey()
        let publicKey = inbox.publicKey.x963Representation
        try store.transaction {
            try store.change("INSERT INTO inbox_key VALUES (1, ?, ?)", [.blob(publicKey), .blob(inbox.rawRepresentation)])
        }
        return publicKey
    }

    // MARK: The sealed inbox

    /// The inbox key of a store without a vault: a public key whose private half is dropped.
    static func decoyInboxKey() -> Data {
        P256.KeyAgreement.PrivateKey().publicKey.x963Representation
    }

    /// The envelope of a Deliver, sender and id included, sealed to an inbox key (HPKE base
    /// mode): the encapsulated key, then the ciphertext.
    static func seal(_ delivered: Delivered, to publicKey: Data) throws -> Data {
        var deliver = Sotto_Deliver()
        deliver.sender = delivered.sender
        deliver.messageID = delivered.messageID
        deliver.payload = delivered.payload
        var sender = try HPKE.Sender(
            recipientKey: P256.KeyAgreement.PublicKey(x963Representation: publicKey), ciphersuite: suite, info: inboxInfo)
        let sealed = try sender.seal(deliver.serializedBytes() as Data)
        return sender.encapsulatedKey + sealed
    }

    /// The envelope sealed to the inbox key whose private half is given; nil when it was
    /// sealed to another key or does not open.
    static func open(_ sealed: Data, privateKey: Data) -> Delivered? {
        guard sealed.count > encapsulatedKeyLength,
            let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: privateKey),
            var recipient = try? HPKE.Recipient(
                privateKey: key, ciphersuite: suite, info: inboxInfo, encapsulatedKey: Data(sealed.prefix(encapsulatedKeyLength))),
            let plaintext = try? recipient.open(Data(sealed.dropFirst(encapsulatedKeyLength))),
            let deliver = try? Sotto_Deliver(serializedBytes: plaintext)
        else { return nil }
        return Delivered(sender: deliver.sender, messageID: deliver.messageID, payload: deliver.payload)
    }

    // MARK: The identity and the prekeys

    /// The tables of the identity and its prekeys: the main store makes and rotates them, a
    /// vault holds a copy, so that its client takes the sessions its contacts start.
    static let mirrored = ["identity", "signed_prekeys", "one_time_prekeys", "pq_prekeys", "pq_prekey_ids"]

    /// Brings the identity and the prekeys of the main store into the vault: a one-time
    /// prekey that the vault used is deleted in the main store first, then every table that
    /// differs is copied whole. A stop between the two is made good by the next call.
    static func syncPrekeys(main: ClientStore, vault: ClientStore) throws {
        if let mark = try vault.query("SELECT last_one_time_prekey_id FROM identity").first?[0].integer {
            let pqMark = try vault.query("SELECT last_id FROM pq_prekey_ids").first?[0].integer ?? 0
            let used = try usedInVault(main, vault, "one_time_prekeys", "", mark)
            let pqUsed = try usedInVault(main, vault, "pq_prekeys", " AND signed_prekey_id IS NULL", pqMark)
            if !used.isEmpty || !pqUsed.isEmpty {
                try main.transaction {
                    for id in used { try main.deleteOneTimePrekey(UInt32(id)) }
                    for id in pqUsed { try main.deletePQOneTimePrekey(UInt32(id)) }
                }
            }
        }
        var copies: [(table: String, rows: [[SQLValue]])] = []
        for table in mirrored {
            let rows = try main.query("SELECT * FROM \(table) ORDER BY 1")
            if try vault.query("SELECT * FROM \(table) ORDER BY 1") != rows {
                copies.append((table, rows))
            }
        }
        guard !copies.isEmpty else { return }
        try vault.transaction {
            for (table, rows) in copies {
                try vault.change("DELETE FROM \(table)")
                for row in rows {
                    try vault.change("INSERT INTO \(table) VALUES (\(marks(row.count)))", row)
                }
            }
        }
    }

    /// The one-time prekeys that the vault was given (ids up to `mark`) and has used, while
    /// the main store still holds them.
    private static func usedInVault(
        _ main: ClientStore, _ vault: ClientStore, _ table: String, _ condition: String, _ mark: Int64
    ) throws -> [Int64] {
        let held = Set(try vault.query("SELECT prekey_id FROM \(table) WHERE 1\(condition)").map { $0[0].integer! })
        return try main.query("SELECT prekey_id FROM \(table) WHERE prekey_id <= ?\(condition)", [.integer(mark)])
            .map { $0[0].integer! }.filter { !held.contains($0) }
    }

    // MARK: Moving a contact

    /// The rows of a contact, table by table, in the order they are deleted: a table whose
    /// rows a subquery finds through another table comes before that table.
    static let contactRows: [(table: String, filter: String)] = [
        ("refusals", "message_id IN (SELECT message_id FROM messages WHERE contact = ?1 AND direction = 'out')"),
        ("pending_replies", "position IN (SELECT position FROM pending WHERE contact = ?1)"),
        ("downloads", "position IN (SELECT position FROM files WHERE contact = ?1)"),
        ("kept_files", "position IN (SELECT position FROM files WHERE contact = ?1)"),
        ("contacts", "identity_key = ?1"),
        ("sessions", "contact = ?1"),
        ("records", "sender = ?1"),
        ("seen_ids", "sender = ?1"),
        ("outbox", "recipient = ?1"),
        ("messages", "contact = ?1"),
        ("message_states", "contact = ?1"),
        ("pending", "contact = ?1"),
        ("uploads", "contact = ?1"),
        ("files", "contact = ?1"),
        ("blob_deletions", "uploader = ?1"),
        ("profiles", "contact = ?1"),
        ("profile_sends", "contact = ?1"),
        ("timers", "contact = ?1"),
        ("verified_contacts", "contact = ?1"),
    ]
    /// Tables whose rows may hold a whole file, copied one row at a time.
    private static let large: Set<String> = ["uploads", "downloads", "kept_files"]
    /// Tables whose `position` only orders their rows within a store.
    private static let renumbered: Set<String> = ["outbox", "uploads"]

    /// Hides a contact: its rows are committed in the vault with the move noted there, then
    /// deleted from the main store, then the note goes. A repeat after a stop at any step
    /// neither doubles nor loses a row: a noted move takes the main store's rows, the newer
    /// ones, in place of the vault's copy. `notes` are the app's notes of each store after
    /// the move, written with the rows.
    static func hide(_ contact: Data, main: ClientStore, vault: ClientStore, notes: (main: Data, vault: Data)) throws {
        if try main.isContact(contact) {
            let repeated = try vault.vaultMove(contact) == true
            try vault.transaction {
                if repeated {
                    try deleteRows(of: contact, in: vault)
                }
                try copyRows(of: contact, from: main, to: vault)
                try vault.setAppNotes(notes.vault)
                try vault.setVaultMove(contact, hiding: true)
            }
            try main.transaction {
                try deleteRows(of: contact, in: main)
                try main.setAppNotes(notes.main)
            }
        }
        try vault.transaction { try vault.setVaultMove(contact, hiding: nil) }
    }

    /// Brings a hidden contact back: the move is noted in the vault, the rows are committed in
    /// the main store, then deleted from the vault with the note. A repeat after a stop goes
    /// on from where it stopped.
    static func unhide(_ contact: Data, main: ClientStore, vault: ClientStore, notes: (main: Data, vault: Data)) throws {
        if try vault.isContact(contact) {
            let copied = try vault.vaultMove(contact) == false && main.isContact(contact)
            if !copied {
                try vault.transaction { try vault.setVaultMove(contact, hiding: false) }
                try main.transaction {
                    try copyRows(of: contact, from: vault, to: main)
                    try main.setAppNotes(notes.main)
                }
            }
            try vault.transaction {
                try deleteRows(of: contact, in: vault)
                try vault.setAppNotes(notes.vault)
            }
        }
        try vault.transaction { try vault.setVaultMove(contact, hiding: nil) }
    }

    /// Copies every row of the contact into `target`, in its caller's transaction. The
    /// sessions take ids of the target, and a record of a session that is gone an id that no
    /// session takes; a row the target holds already stays, and a local name that the target
    /// gives another contact gets a number.
    static func copyRows(of contact: Data, from source: ClientStore, to target: ClientStore) throws {
        let key = [SQLValue.blob(contact)]
        if let row = try source.query("SELECT identity_key, pinned_identity_dh_key, name FROM contacts WHERE identity_key = ?", key).first {
            var name = row[2]
            var number = 1
            while case .text(let base) = row[2],
                try !target.query("SELECT 1 FROM contacts WHERE name = ? AND identity_key != ?", [name, .blob(contact)]).isEmpty
            {
                number += 1
                name = .text("\(base) \(number)")
            }
            try target.change("INSERT INTO contacts VALUES (?, ?, ?) ON CONFLICT DO NOTHING", [row[0], row[1], name])
        }
        var sessions: [Int64: Int64] = [:]
        let stored = "SELECT session_id, position, associated_data, state, initial_header FROM sessions WHERE contact = ? ORDER BY session_id"
        for row in try source.query(stored, key) {
            sessions[row[0].integer!] = try target.change(
                "INSERT INTO sessions (contact, position, associated_data, state, initial_header) VALUES (?, ?, ?, ?, ?) RETURNING session_id",
                key + row.dropFirst()
            )[0][0].integer!
        }
        for row in try source.query("SELECT sender, ephemeral_key, session_id, signed_prekey_id FROM records WHERE sender = ?", key) {
            let sessionID = try sessions[row[2].integer!] ?? unusedSessionID(target)
            try target.change("INSERT INTO records VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING", [row[0], row[1], .integer(sessionID), row[3]])
        }
        for (table, filter) in contactRows where !["contacts", "sessions", "records"].contains(table) {
            let columns = try source.query("SELECT name FROM pragma_table_info(?)", [.text(table)]).map { $0[0].text! }
                .filter { !(renumbered.contains(table) && $0 == "position") }
            let list = columns.joined(separator: ", ")
            let insert = "INSERT INTO \(table) (\(list)) VALUES (\(marks(columns.count))) ON CONFLICT DO NOTHING"
            if large.contains(table) {
                for row in try source.query("SELECT rowid FROM \(table) WHERE \(filter)", key) {
                    try target.change(insert, try source.query("SELECT \(list) FROM \(table) WHERE rowid = ?", row)[0])
                }
            } else {
                for row in try source.query("SELECT \(list) FROM \(table) WHERE \(filter)", key) {
                    try target.change(insert, row)
                }
            }
        }
    }

    /// Deletes every row of the contact, in the caller's transaction.
    static func deleteRows(of contact: Data, in store: ClientStore) throws {
        for (table, filter) in contactRows {
            try store.change("DELETE FROM \(table) WHERE \(filter)", [.blob(contact)])
        }
    }

    /// A session id above every one the store gave or will give.
    private static func unusedSessionID(_ store: ClientStore) throws -> Int64 {
        if let row = try store.change("UPDATE sqlite_sequence SET seq = seq + 1 WHERE name = 'sessions' RETURNING seq").first {
            return row[0].integer!
        }
        return try store.change(
            "INSERT INTO sqlite_sequence (name, seq) VALUES ('sessions', (SELECT coalesce(max(session_id), 0) + 1 FROM sessions)) RETURNING seq"
        )[0][0].integer!
    }

    private static func marks(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }
}

/// The vault is closed: an action on a hidden chat waits for its phrase.
public struct VaultClosedError: Error, Equatable, Sendable {
    public init() {}
}

extension ClientStore {
    /// The public key of the inbox and, in a vault, its private key.
    func inboxKey() throws -> (publicKey: Data, privateKey: Data?)? {
        try query("SELECT public_key, private_key FROM inbox_key").first.map { ($0[0].data!, $0[1].data) }
    }

    /// Whether the store has the message at the position, or the pending text at its negation.
    func holds(_ position: Int64) throws -> Bool {
        if position > 0 {
            return try message(position) != nil
        }
        return try !query("SELECT 1 FROM pending WHERE position = ?", [.integer(-position)]).isEmpty
    }

    /// Replaces the inbox key of the main store with the public key of a new vault.
    func setInboxPublicKey(_ publicKey: Data) throws {
        try change(
            "INSERT INTO inbox_key VALUES (1, ?, NULL) ON CONFLICT (only_row) DO UPDATE SET public_key = excluded.public_key, private_key = NULL",
            [.blob(publicKey)]
        )
    }

    /// Seals an envelope to the inbox key and keeps it, in the caller's transaction; the
    /// oldest go beyond `Vault.sealedMaxCount` envelopes or `Vault.sealedMaxBytes`.
    func keepSealed(_ delivered: Delivered) throws {
        guard let publicKey = try inboxKey()?.publicKey else { return }
        try change("INSERT INTO sealed_inbox (sealed) VALUES (?)", [.blob(try Vault.seal(delivered, to: publicKey))])
        try change(
            "DELETE FROM sealed_inbox WHERE position NOT IN (SELECT position FROM sealed_inbox ORDER BY position DESC LIMIT ?)",
            [.integer(Int64(Vault.sealedMaxCount))]
        )
        try change(
            """
            DELETE FROM sealed_inbox WHERE position IN (
                SELECT position FROM (
                    SELECT position, sum(length(sealed)) OVER (ORDER BY position DESC) AS total FROM sealed_inbox
                ) WHERE total > ?
            )
            """,
            [.integer(Int64(Vault.sealedMaxBytes))]
        )
    }

    /// The sealed envelopes, oldest first.
    func sealedInbox() throws -> [(position: Int64, sealed: Data)] {
        try query("SELECT position, sealed FROM sealed_inbox ORDER BY position").map { ($0[0].integer!, $0[1].data!) }
    }

    func deleteSealed(_ position: Int64) throws {
        try change("DELETE FROM sealed_inbox WHERE position = ?", [.integer(position)])
    }

    /// The move of the contact that a vault noted: true into it, false out of it.
    func vaultMove(_ contact: Data) throws -> Bool? {
        try query("SELECT hiding FROM vault_moves WHERE contact = ?", [.blob(contact)]).first.map { $0[0].integer == 1 }
    }

    func vaultMoves() throws -> [(contact: Data, hiding: Bool)] {
        try query("SELECT contact, hiding FROM vault_moves ORDER BY contact").map { ($0[0].data!, $0[1].integer == 1) }
    }

    /// Notes a move of the contact, or with nil forgets it.
    func setVaultMove(_ contact: Data, hiding: Bool?) throws {
        if let hiding {
            try change(
                "INSERT INTO vault_moves VALUES (?, ?) ON CONFLICT (contact) DO UPDATE SET hiding = excluded.hiding",
                [.blob(contact), .integer(hiding ? 1 : 0)]
            )
        } else {
            try change("DELETE FROM vault_moves WHERE contact = ?", [.blob(contact)])
        }
    }
}
