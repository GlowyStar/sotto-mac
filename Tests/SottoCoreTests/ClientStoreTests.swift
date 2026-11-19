import Foundation
@testable import SottoCore
import Testing

private struct Planted: Error {}

/// A fresh directory under the temporary directory, removed when the test ends.
private func withDataDirectory(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-store-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root.appendingPathComponent("data"))
}

private func mode(of url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
}

private func state(skipped: Int = 0) -> RatchetState {
    RatchetState(
        dhsPrivateKey: Data(repeating: 1, count: 32),
        dhsPublicKey: Data(repeating: 2, count: 32),
        dhr: nil,
        rk: Data(repeating: 3, count: 32),
        cks: Data(repeating: 4, count: 32),
        ckr: nil,
        ns: 5,
        nr: 6,
        pn: 7,
        dhsteps: 8,
        mkskipped: (0..<skipped).map {
            SkippedKey(ratchetKey: Data(count: 32), number: UInt32($0), messageKey: Data(count: 32), step: 1)
        }
    )
}

@Test func directoryGetsMode0700AndTheFile0600() throws {
    let previous = umask(0)
    defer { umask(previous) }
    try withDataDirectory { directory in
        try ClientStore(directory: directory).close()

        #expect(try mode(of: directory) == 0o700)
        #expect(try mode(of: directory.appendingPathComponent(ClientStore.fileName)) == 0o600)
    }
}

@Test func startIsRefusedWhenAModeGivesARightToTheGroupOrOthers() throws {
    for bits in [0o040, 0o020, 0o010, 0o004, 0o002, 0o001] {
        for widenFile in [false, true] {
            try withDataDirectory { directory in
                try ClientStore(directory: directory).close()
                let widened = widenFile ? directory.appendingPathComponent(ClientStore.fileName) : directory
                try FileManager.default.setAttributes(
                    [.posixPermissions: try mode(of: widened) | bits], ofItemAtPath: widened.path
                )

                do {
                    _ = try ClientStore(directory: directory)
                    Issue.record("the store opened with mode bits \(bits)")
                } catch StoreError.wideMode {
                }
            }
        }
    }
}

@Test func storeUsesTheRollbackJournalWithSecureDelete() throws {
    try withDataDirectory { directory in
        let store = try ClientStore(directory: directory)
        try store.transaction { try store.addContact(Data(count: 32)) }

        #expect(try store.query("PRAGMA journal_mode") == [[.text("delete")]])
        #expect(try store.query("PRAGMA secure_delete") == [[.integer(1)]])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == [ClientStore.fileName, StoreKeys.fileName])
        store.close()
    }
}

@Test func writeOutsideATransactionIsRefused() throws {
    try withDataDirectory { directory in
        let store = try ClientStore(directory: directory)

        #expect(throws: StoreError.writeOutsideTransaction) { try store.addContact(Data(count: 32)) }
        #expect(try !store.isContact(Data(count: 32)))
    }
}

@Test func transactionThatThrowsLeavesNoRow() throws {
    try withDataDirectory { directory in
        let store = try ClientStore(directory: directory)

        #expect(throws: Planted.self) {
            try store.transaction {
                try store.addContact(Data(count: 32))
                try store.addToOutbox(OutboxRow(messageID: Data(count: 16), recipient: Data(count: 32), payload: Data([1])))
                throw Planted()
            }
        }
        #expect(throws: StoreError.self) {
            try store.transaction {
                try store.addSeenID(sender: Data(count: 32), messageID: Data(count: 16), seenAt: 1)
                try store.addSeenID(sender: Data(count: 32), messageID: Data(count: 16), seenAt: 2)
            }
        }

        #expect(try !store.isContact(Data(count: 32)))
        #expect(try store.outbox().isEmpty)
        #expect(try !store.isSeen(sender: Data(count: 32), messageID: Data(count: 16)))
        #expect(!store.isInTransaction)
    }
}

@Test func storeHoldsWhatSection22_1Lists() throws {
    try withDataDirectory { directory in
        let store = try ClientStore(directory: directory)

        let tables = try store.query(
            "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )

        #expect(tables.map { $0[0].text! } == [
            "app_notes", "blob_deletions", "contacts", "downloads", "files", "identity", "kept_files", "message_states",
            "messages", "one_time_prekeys", "outbox", "own_profile", "pending", "pending_replies", "profile_sends",
            "profiles", "records", "refusals", "row_numbers", "seen_ids", "sessions", "settings", "signed_prekeys",
            "timers", "uploads",
        ])
    }
}

@Test func everythingSurvivesClosingAndOpeningAgain() throws {
    try withDataDirectory { directory in
        let alice = Data(repeating: 0xA1, count: 32)
        let identity = StoredIdentity(seed: Data(repeating: 9, count: 32), identityDHPrivateKey: Data(repeating: 8, count: 32))
        let rows = (0..<3).map { OutboxRow(messageID: Data(repeating: UInt8($0), count: 16), recipient: alice, payload: Data([UInt8($0)])) }
        var sessionID: Int64 = 0

        let store = try ClientStore(directory: directory)
        try store.transaction {
            try store.saveIdentity(identity)
            try store.addContact(alice, name: "alice\u{0}bob")
            try store.setPin(alice, identityDHKey: Data(repeating: 7, count: 32))
            sessionID = try store.addSession(alice, associatedData: Data(count: 177), state: state(skipped: 2), initialHeader: Data())
            #expect(try store.addSignedPrekey(Data(repeating: 6, count: 32), madeAt: 100) == 1)
            #expect(try store.addOneTimePrekey(Data(repeating: 5, count: 32)) == 1)
            try store.addSeenID(sender: alice, messageID: Data(count: 16), seenAt: 100)
            try store.addRecord(sender: alice, ephemeralKey: Data(count: 32), sessionID: sessionID, signedPrekeyID: 1)
            for row in rows {
                try store.addToOutbox(row)
            }
            try store.logMessage(alice, direction: .outgoing, messageID: Data(count: 16), text: "hi")
        }
        store.close()

        let reopened = try ClientStore(directory: directory)
        #expect(try reopened.identity() == identity)
        #expect(try reopened.contacts() == [Contact(identityKey: alice, name: "alice\u{0}bob")])
        #expect(try reopened.pin(alice) == Data(repeating: 7, count: 32))
        let session = try #require(try reopened.session(sessionID))
        #expect(session.state == state(skipped: 2))
        #expect(session.initialHeader == Data())
        #expect(session.associatedData == Data(count: 177))
        #expect(try reopened.newestSignedPrekey() == StoredSignedPrekey(prekeyID: 1, privateKey: Data(repeating: 6, count: 32), madeAt: 100, confirmed: false))
        #expect(try reopened.oneTimePrekey(1) == Data(repeating: 5, count: 32))
        #expect(try reopened.oneTimePrekeyIDsLeft() == Int64(UInt32.max) - 1)
        #expect(try reopened.isSeen(sender: alice, messageID: Data(count: 16)))
        #expect(try reopened.record(sender: alice, ephemeralKey: Data(count: 32)) == SessionRecord(sessionID: sessionID, signedPrekeyID: 1))
        #expect(try reopened.outbox() == rows)
        #expect(try reopened.query("SELECT direction, text FROM messages") == [[.text("out"), .text("hi")]])
    }
}

@Test func sessionListKeepsItsOrderAndDropsWhatIsBehind() throws {
    try withDataDirectory { directory in
        let store = try ClientStore(directory: directory)
        let alice = Data(repeating: 0xA1, count: 32)
        try store.transaction {
            try store.addContact(alice)
            let ids = try (0..<4).map {
                try store.addSession(alice, associatedData: Data(count: 177), state: state(skipped: $0 + 1), initialHeader: nil)
            }
            #expect(try store.sessions(alice).map(\.sessionID) == ids.reversed())

            try store.acceptOnSession(ids[0], state: state(skipped: 1))
            #expect(try store.sessions(alice).map(\.sessionID) == [ids[0], ids[3], ids[2], ids[1]])

            #expect(try store.dropSessionsBehind(alice) == 2)
            #expect(try store.sessions(alice).map(\.sessionID) == [ids[0], ids[3], ids[2]])

            try store.removeContact(alice)
            #expect(try store.sessions(alice).isEmpty)
            #expect(try !store.isContact(alice))
        }
    }
}

@Test func signedPrekeyIsHeldWhileNewestOrInItsGracePeriod() throws {
    try withDataDirectory { directory in
        let store = try ClientStore(directory: directory)
        try store.transaction {
            try store.saveIdentity(StoredIdentity(seed: Data(count: 32), identityDHPrivateKey: Data(count: 32)))
            let first = try #require(try store.addSignedPrekey(Data(repeating: 1, count: 32), madeAt: 10))
            let second = try #require(try store.addSignedPrekey(Data(repeating: 2, count: 32), madeAt: 20))
            try store.confirmSignedPrekey(second)

            #expect(try store.signedPrekey(first, replacedAfter: 19) == Data(repeating: 1, count: 32))
            #expect(try store.signedPrekey(first, replacedAfter: 20) == nil)
            #expect(try store.newestSignedPrekey()?.confirmed == true)

            try store.deleteSignedPrekeys(replacedAtOrBefore: 20)
            #expect(try store.signedPrekey(first, replacedAfter: 0) == nil)
            #expect(try store.signedPrekey(second, replacedAfter: 0) == Data(repeating: 2, count: 32))

            for index in 0..<5 {
                _ = try store.addOneTimePrekey(Data(repeating: UInt8(index), count: 32))
            }
            try store.deleteLowestOneTimePrekeys(2)
            try store.deleteOneTimePrekey(5)
            #expect(try store.oneTimePrekeyCount() == 2)
            #expect(try store.oneTimePrekey(3) != nil)

            try store.query("UPDATE identity SET last_one_time_prekey_id = ?", [.integer(Int64(UInt32.max))])
            #expect(try store.addOneTimePrekey(Data(count: 32)) == nil)
            #expect(try store.oneTimePrekeyIDsLeft() == 0)
        }
    }
}
