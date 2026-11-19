import Foundation
@testable import SottoCore
import Testing

// libsignal, rust/protocol/src/fingerprint.rs, test fingerprint_test_v1, at commit
// 956e1cab1d68291c92f2fcca3c29ec6c3b367e28: keys of 33 bytes, phone numbers as identifiers.
private let libsignalAliceKey = Data(hex: "0506863bc66d02b40d27b8d49ca7c09e9239236f9d7d25d6fcca5ce13c7064d868")
private let libsignalBobKey = Data(hex: "05f781b6fb32fed9ba1cf2de978d4d5da28dc34046ae814402b5c0dbd96fda907b")
private let libsignalDisplay = "300354477692869396892869876765458257569162576843440918079131"
private let libsignalAliceScanned = "1e301a0353dce3dbe7684cb8336e85136cdc0ee96219494ada305d62a7bd61df"
private let libsignalBobScanned = "d62cbf73a11592015b6b9f1682ac306fea3aaf3885b84d12bca631e9d4fb3a4d"

/// The vectors of `safety-number.json` in the order of the hand-over: one pair, then the
/// pair in which Alice holds Mallory's key in place of Bob's.
private let vectorOrder = [
    "safety-number-alice-bob", "safety-number-bob-alice", "safety-number-alice-mallory", "safety-number-mallory-alice",
]

/// The seeds whose identity keys the vectors use (protocol section 46).
private let seeds: [String: UInt8] = ["alice": 1, "mallory": 2, "bob": 3]

/// Every intermediate and output of a vector, computed from its inputs, the first input of
/// each chain before its fingerprint.
private func replay(_ vector: Vector) throws {
    let strings = try #require(vector.intermediates as? [String: String])
    let names = vector.name.split(separator: "-").suffix(2).map(String.init)
    for (side, prefix, name) in [("identity_key", "", names[0]), ("contact_identity_key", "contact_", names[1])] {
        let key = vector.hex(side)
        #expect(try Identity.deriveIdentityKey(seed: Data(repeating: seeds[name]!, count: 32)) == key, "\(vector.name) \(side)")
        let first = SafetyNumber.firstInput(key: key, stableIdentifier: Data(try Identity.encodeUserID(key).utf8))
        #expect(first.count == 130)
        try #require(first.hex == strings[prefix + "fingerprint_input"], "\(vector.name) \(prefix)fingerprint_input")
        let fingerprint = try SafetyNumber.fingerprint(identityKey: key)
        #expect(fingerprint.hex == strings[prefix + "fingerprint"], "\(vector.name) \(prefix)fingerprint")
        #expect(SafetyNumber.digits(of: fingerprint) == strings[prefix + "digits"], "\(vector.name) \(prefix)digits")
    }
    let number = try SafetyNumber(identityKey: vector.hex("identity_key"), contactIdentityKey: vector.hex("contact_identity_key"))
    #expect(number.digits == vector.outputs?["safety_number"] as? String, "\(vector.name) safety_number")
    #expect(number.qrPayload == vector.outputs?["qr_payload"] as? String, "\(vector.name) qr_payload")
    #expect(number.qrPayload.utf8.count == 151)
    #expect(number.groups.count == 12 && number.groups.joined() == number.digits)
}

@Test func safetyNumberReplaysLibsignalFirstThenEveryVectorByteForByte() throws {
    let alice = SafetyNumber.fingerprint(key: libsignalAliceKey, stableIdentifier: Data("+14152222222".utf8))
    let bob = SafetyNumber.fingerprint(key: libsignalBobKey, stableIdentifier: Data("+14153333333".utf8))
    try #require([SafetyNumber.digits(of: alice), SafetyNumber.digits(of: bob)].sorted().joined() == libsignalDisplay)
    try #require(alice.prefix(32).hex == libsignalAliceScanned)
    try #require(bob.prefix(32).hex == libsignalBobScanned)

    let vectors = try loadVectors("safety-number")
    let byName = Dictionary(uniqueKeysWithValues: vectors.map { ($0.name, $0) })
    #expect(Set(byName.keys) == Set(vectorOrder) && vectors.count == vectorOrder.count)
    for name in vectorOrder {
        let vector = try #require(byName[name])
        #expect(vector.operation == "safety-number" && vector.error == nil)
        try replay(vector)
    }

    let aliceBob = try SafetyNumber(
        identityKey: byName[vectorOrder[0]]!.hex("identity_key"), contactIdentityKey: byName[vectorOrder[0]]!.hex("contact_identity_key"))
    let bobAlice = try SafetyNumber(
        identityKey: byName[vectorOrder[1]]!.hex("identity_key"), contactIdentityKey: byName[vectorOrder[1]]!.hex("contact_identity_key"))
    let aliceMallory = try SafetyNumber(
        identityKey: byName[vectorOrder[2]]!.hex("identity_key"), contactIdentityKey: byName[vectorOrder[2]]!.hex("contact_identity_key"))
    // The two sides of a pair: one number, the halves of the payload swapped (section 44.5).
    let halves = aliceBob.qrPayload.split(separator: " ")
    #expect(aliceBob.digits == bobAlice.digits)
    #expect(bobAlice.qrPayload == "\(halves[0]) \(halves[2]) \(halves[1])")
    // An id substituted on its way gives another number than the contact's client shows,
    // and Bob's code scanned by Alice holding Mallory is no match.
    let substituted = aliceMallory.qrPayload.split(separator: " ")
    #expect(aliceMallory.digits != bobAlice.digits)
    #expect(bobAlice.qrPayload != "\(substituted[0]) \(substituted[2]) \(substituted[1])")
    // Zeros in front of a group stay (section 44.3).
    #expect(aliceBob.groups.contains("04469") && aliceBob.groups.contains("03296") && aliceBob.groups.contains("04713"))
}

@Test func markSurvivesAReopenLeavesWithTheContactAndChangesNoOtherRow() throws {
    try withPair { clients, relay, alice, bob in
        #expect(try bob.receive(send(relay, alice, bob, "a session")).text == "a session")
        #expect(try !alice.isVerified(bob.identityKey))
        let before = try rows(alice.store)

        try alice.setVerified(bob.identityKey, true)
        try alice.setVerified(bob.identityKey, true)
        var after = try rows(alice.store)
        #expect(after.removeValue(forKey: "verified_contacts") == [[.blob(bob.identityKey)]])
        var unmarked = before
        unmarked["verified_contacts"] = nil
        #expect(after == unmarked)
        #expect(try clients.open("alice").isVerified(bob.identityKey))

        try alice.setVerified(bob.identityKey, false)
        #expect(try rows(alice.store) == before)

        try alice.setVerified(bob.identityKey, true)
        try alice.removeContact(bob.identityKey)
        #expect(throws: SessionError.notAContact) { try alice.setVerified(bob.identityKey, true) }
        try alice.addContact(userID(bob))
        #expect(try !alice.isVerified(bob.identityKey))
    }
}

@Test func storeWithoutTheTableOfMarksOpensWithNoContactMarkedAndGainsIt() throws {
    try withClients { clients, _ in
        let directory = clients.folder.appendingPathComponent("older")
        let contact = Data(repeating: 3, count: 32)
        var store = try ClientStore(directory: directory)
        try store.transaction {
            try store.addContact(contact, name: "c")
            try store.query("DROP TABLE verified_contacts")
        }
        store.close()

        store = try ClientStore(directory: directory)
        #expect(try store.verifiedContacts().isEmpty)
        try store.transaction { try store.setVerified(contact, true) }
        #expect(try store.verifiedContacts() == [contact])
        store.close()
    }
}

@Test func theMarkAndARefusedKeyReachTheStateAndTheMarkStays() async throws {
    let folder = Folder()
    let directory = folder.url.appendingPathComponent("app")
    var messenger = try Messenger(directory: directory, relay: deadRelay)
    await messenger.start()
    _ = try await messenger.createIdentity()
    let peerID = String(repeating: "ab", count: 32)
    let peer = try Identity.decodeUserID(peerID)
    try await messenger.addContact(name: "peer", userID: peerID)
    func chat() async throws -> Chat {
        try #require(try await messenger.state().chats.first)
    }
    #expect(try await chat().verified == false)
    #expect(try await chat().refusedKey == nil)

    try await messenger.setVerified(true, for: peerID)
    await messenger.handle(.incoming(sender: peer, received: Received(ack: true, text: nil, result: "IDENTITY_KEY_MISMATCH")))
    let warned = try await chat()
    #expect(warned.verified && warned.refusedKey != nil && warned.messages.isEmpty)

    await messenger.close()
    messenger = try Messenger(directory: directory, relay: deadRelay)
    await messenger.start()
    let reopened = try await chat()
    #expect(reopened.verified && reopened.refusedKey == warned.refusedKey)

    try await messenger.dismissRefusedKey(peerID)
    #expect(try await chat().verified == true)
    #expect(try await chat().refusedKey == nil)
    await messenger.handle(.incoming(sender: peer, received: Received(ack: true, text: nil, result: "IDENTITY_KEY_MISMATCH")))
    try await messenger.setVerified(false, for: peerID)
    #expect(try await chat().verified == false)
    #expect(try await chat().refusedKey != nil)

    try await messenger.setVerified(true, for: peerID)
    try await messenger.deleteContact(peerID)
    try await messenger.addContact(name: "peer", userID: peerID)
    #expect(try await chat().verified == false)
    #expect(try await chat().refusedKey == nil)
    await messenger.close()
}
