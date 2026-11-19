import Foundation
@testable import SottoCore
import Testing

/// A fresh folder under the temporary directory, removed when the test ends.
private func withFolder(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-encrypted-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private let alice = Data(repeating: 7, count: 32)

/// Writes the marker into every kind of row that holds the user's words.
private func fill(_ directory: URL, marker: String) throws -> StoredIdentity {
    let store = try ClientStore(directory: directory)
    defer { store.close() }
    _ = try Client(store: store)
    try store.transaction {
        try store.addContact(alice, name: marker)
        _ = try store.logMessage(alice, direction: .incoming, messageID: Data(repeating: 1, count: 16), text: marker)
        _ = try store.logMessage(alice, direction: .outgoing, messageID: Data(repeating: 2, count: 16), text: "re: " + marker)
        _ = try store.addPending(alice, text: marker, madeAt: 1)
        try store.setOwnProfile(OwnProfile(name: marker))
    }
    return try store.identity()!
}

/// Every row of every table, sorted, so that two stores compare by content.
private func everything(_ store: ClientStore) throws -> [String: [String]] {
    var tables: [String: [String]] = [:]
    for row in try store.query("SELECT name FROM sqlite_schema WHERE type = 'table'") {
        let name = row[0].text!
        tables[name] = try store.query("SELECT * FROM \"\(name)\"").map { "\($0)" }.sorted()
    }
    return tables
}

private func files(_ directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

/// Turns the encrypted store of `directory` into a plain store of the previous version, with
/// no wrapped key, and drops its key from memory.
private func makePlain(_ directory: URL) throws {
    let plain = directory.appendingPathComponent("plain.db")
    FileManager.default.createFile(atPath: plain.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let store = try ClientStore(directory: directory)
    try store.query("ATTACH DATABASE ? AS plain KEY ''", [.text(plain.path)])
    try store.query("SELECT sqlcipher_export('plain')")
    try store.query("DETACH DATABASE plain")
    store.close()
    let manager = FileManager.default
    try manager.removeItem(at: directory.appendingPathComponent(ClientStore.fileName))
    try manager.removeItem(at: directory.appendingPathComponent(StoreKeys.fileName))
    try manager.moveItem(at: plain, to: directory.appendingPathComponent(ClientStore.fileName))
    StoreKeys.lock(directory)
    try StoreKeys.unlock(directory, protection: .test)
}

@Test func storeIsServedBySQLCipherOverCommonCrypto() throws {
    try withFolder { folder in
        let store = try ClientStore(directory: folder)
        defer { store.close() }
        #expect(try !store.cipherVersion().isEmpty)
        #expect(try store.cipherProvider() == "commoncrypto")
        #expect(ClientStore.servingLibrary.contains("SQLCipher.framework"))
        #expect(try ClientStore.holdsEncryptedPages(store.path))
    }
}

@Test func storeFileHoldsNoMarkerInAnyForm() throws {
    try withFolder { folder in
        let marker = "sotto-marker-\(UUID().uuidString)"
        let identity = try fill(folder, marker: marker)
        let written = try files(folder).map { try Data(contentsOf: folder.appendingPathComponent($0)) }
        let utf8 = Data(marker.utf8)
        let forms: [Data] = [
            utf8,
            marker.data(using: .utf16LittleEndian)!,
            marker.data(using: .utf16BigEndian)!,
            Data(utf8.map { String(format: "%02x", $0) }.joined().utf8),
            Data(utf8.map { String(format: "%02X", $0) }.joined().utf8),
            Data(utf8.base64EncodedString().utf8),
            identity.seed,
            identity.identityDHPrivateKey,
            Data(identity.seed.map { String(format: "%02x", $0) }.joined().utf8),
        ]
        for file in written {
            for form in forms {
                #expect(file.range(of: form) == nil)
            }
        }
        let store = try ClientStore(directory: folder)
        #expect(try store.messages(alice).map(\.text) == [marker, "re: " + marker])
        store.close()
    }
}

@Test func copyOfTheFolderDoesNotOpenWithoutItsEnclaveKey() throws {
    try withFolder { folder in
        let original = folder.appendingPathComponent("original")
        _ = try fill(original, marker: "copied")
        let manager = FileManager.default

        let withoutKey = folder.appendingPathComponent("without-key")
        try manager.copyItem(at: original, to: withoutKey)
        try manager.removeItem(at: withoutKey.appendingPathComponent(StoreKeys.fileName))
        #expect(throws: StoreError.missingKey(path: withoutKey.appendingPathComponent(StoreKeys.fileName).path)) {
            try StoreKeys.unlock(withoutKey, protection: .test)
        }
        #expect(throws: StoreError.missingKey(path: withoutKey.appendingPathComponent(StoreKeys.fileName).path)) {
            try ClientStore(directory: withoutKey)
        }

        // The key of another store: the wrap opens, its key opens no page.
        let other = folder.appendingPathComponent("other")
        try ClientStore(directory: other).close()
        let otherKey = folder.appendingPathComponent("other-key")
        try manager.copyItem(at: original, to: otherKey)
        try manager.removeItem(at: otherKey.appendingPathComponent(StoreKeys.fileName))
        try manager.copyItem(
            at: other.appendingPathComponent(StoreKeys.fileName), to: otherKey.appendingPathComponent(StoreKeys.fileName))
        #expect(throws: StoreError.wrongKey) { try ClientStore(directory: otherKey) }

        // A Secure Enclave key blob that this Secure Enclave did not make, as on another Mac.
        let foreign = folder.appendingPathComponent("foreign")
        try manager.copyItem(at: original, to: foreign)
        let keyFile = foreign.appendingPathComponent(StoreKeys.fileName)
        var wrapped = try JSONDecoder().decode(StoreKeys.WrappedKey.self, from: Data(contentsOf: keyFile))
        wrapped.enclaveKey = Data(wrapped.enclaveKey.map { $0 ^ 0x5a })
        try JSONEncoder().encode(wrapped).write(to: keyFile)
        do {
            try StoreKeys.unlock(foreign, protection: .test)
            Issue.record("a foreign enclave key opened")
        } catch StoreError.enclaveRefused {
        }

        // A damaged sealed key.
        let damaged = folder.appendingPathComponent("damaged")
        try manager.copyItem(at: original, to: damaged)
        let damagedFile = damaged.appendingPathComponent(StoreKeys.fileName)
        var sealed = try JSONDecoder().decode(StoreKeys.WrappedKey.self, from: Data(contentsOf: damagedFile))
        sealed.sealedKey[0] ^= 1
        try JSONEncoder().encode(sealed).write(to: damagedFile)
        #expect(throws: StoreError.wrongKey) { try StoreKeys.unlock(damaged, protection: .test) }
    }
}

@Test func plainStoreIsEncryptedOnceAndKeepsEveryRow() throws {
    try withFolder { folder in
        let marker = "migrated-\(UUID().uuidString)"
        _ = try fill(folder, marker: marker)
        let store = try ClientStore(directory: folder)
        let before = try everything(store)
        store.close()
        try makePlain(folder)
        let path = folder.appendingPathComponent(ClientStore.fileName)
        #expect(try ClientStore.isPlain(path))
        #expect(try Data(contentsOf: path).range(of: Data(marker.utf8)) != nil)

        let migrated = try ClientStore(directory: folder)
        #expect(try everything(migrated) == before)
        migrated.close()
        #expect(try ClientStore.holdsEncryptedPages(path))
        #expect(try Data(contentsOf: path).range(of: Data(marker.utf8)) == nil)
        #expect(try files(folder) == [ClientStore.fileName, StoreKeys.fileName])
    }
}

@Test func whatAStoppedMigrationLeftIsCleared() throws {
    try withFolder { folder in
        _ = try fill(folder, marker: "stopped")
        try makePlain(folder)
        let path = folder.appendingPathComponent(ClientStore.fileName)
        let staging = path.path + ClientStore.encryptingSuffix
        let plainLink = path.path + ClientStore.plainSuffix

        // Stopped before the rename: a half copy and a link to the plain store, still the store.
        FileManager.default.createFile(atPath: staging, contents: Data("half".utf8))
        #expect(link(path.path, plainLink) == 0)
        let store = try ClientStore(directory: folder)
        #expect(try store.contacts().map(\.name) == ["stopped"])
        store.close()
        #expect(try files(folder) == [ClientStore.fileName, StoreKeys.fileName])

        // Stopped after the rename: the plain file is left beside the encrypted store.
        FileManager.default.createFile(atPath: plainLink, contents: Data("SQLite format 3\0 plain rows".utf8))
        try ClientStore(directory: folder).close()
        #expect(try files(folder) == [ClientStore.fileName, StoreKeys.fileName])
    }
}

@Test func lockOverwritesTheKeyAndTheStoreStaysShut() throws {
    try withFolder { folder in
        try ClientStore(directory: folder).close()
        let key = try #require(StoreKeys.heldKey(folder))
        #expect(key.bytes.contains { $0 != 0 })

        StoreKeys.lock(folder)
        #expect(key.bytes.allSatisfy { $0 == 0 })
        #expect(!StoreKeys.isUnlocked(folder))
        #expect(throws: StoreError.locked) { try ClientStore(directory: folder) }

        try StoreKeys.unlock(folder, protection: .test)
        try ClientStore(directory: folder).close()
    }
}

@Test func testProtectionIsRefusedForTheOwnerFolders() throws {
    let asked = ["SOTTO_STORE_PROTECTION": "test"]
    for owner in StoreKeys.ownerDirectories {
        let spellings = [
            owner, URL(fileURLWithPath: owner.path.uppercased()), owner.appendingPathComponent("x/.."),
            URL(fileURLWithPath: "/System/Volumes/Data" + owner.path),
        ]
        for spelling in spellings {
            #expect(StoreKeys.isOwnerDirectory(spelling))
            #expect(throws: StoreError.testProtectionRefused(path: spelling.path)) {
                try StoreProtection.asked(for: spelling, environment: asked)
            }
            #expect(throws: StoreError.testProtectionRefused(path: spelling.path)) {
                try StoreKeys.unlock(spelling, protection: .test)
            }
        }
        #expect(try StoreProtection.asked(for: owner, environment: [:]) == .presence)
    }
    let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere")
    #expect(try StoreProtection.asked(for: elsewhere, environment: asked) == .test)
    #expect(try StoreProtection.asked(for: elsewhere, environment: ["SOTTO_STORE_PROTECTION": "1"]) == .presence)
    #expect(try StoreProtection.asked(for: elsewhere, environment: [:]) == .presence)
}

/// A key of the other kind is refused before the Secure Enclave is asked, so neither way
/// shows a prompt.
@Test func storeNeverChangesItsKindSilently() throws {
    try withFolder { folder in
        let presence = folder.appendingPathComponent("presence")
        try ClientStore.makePrivateDirectory(presence)
        try StoreKeys.write(StoreKeys.make(.presence), to: presence.appendingPathComponent(StoreKeys.fileName))
        #expect(
            throws: StoreError.protectionMismatch(
                path: presence.appendingPathComponent(StoreKeys.fileName).path, stored: .presence, asked: .test)
        ) {
            try StoreKeys.unlock(presence, protection: .test)
        }

        let test = folder.appendingPathComponent("test")
        try ClientStore(directory: test).close()
        StoreKeys.lock(test)
        #expect(
            throws: StoreError.protectionMismatch(
                path: test.appendingPathComponent(StoreKeys.fileName).path, stored: .test, asked: .presence)
        ) {
            try StoreKeys.unlock(test, protection: .presence)
        }
    }
}

@Test func testQueriesAnswerOnlyAStoreOfTheTestKind() throws {
    try withFolder { folder in
        _ = try fill(folder, marker: "queried")
        let store = try ClientStore(directory: folder)
        defer { store.close() }
        let rows = try JSONSerialization.jsonObject(with: store.testRowsJSON("SELECT name FROM contacts")) as! [[Any]]
        #expect(rows.map { $0[0] as? String } == ["queried"])
        #expect(throws: StoreError.sqlite(code: 8, message: "attempt to write a readonly database")) {
            try store.testRowsJSON("DELETE FROM contacts")
        }
    }
}
