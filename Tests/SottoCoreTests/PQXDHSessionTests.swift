import Foundation
@testable import SottoCore
import Testing

/// Sessions by PQXDH and the transition from X3DH: docs/protocol.md, sections 41 and 42,
/// as the reference's tests/client/test_pqxdh_sessions.py has them.

/// Alice and Bob as contacts, Bob's prekeys on the relay with one one-time post-quantum
/// prekey: the last-resort one has the id 1, the one-time one the id 2.
private func withPQPair(_ body: (Clients, Relay, Client, Client) throws -> Void) throws {
    try withClients { clients, relay in
        let alice = try clients.open("alice")
        let bob = try clients.open("bob")
        try relay.publish(bob, pqOneTimeCount: 1)
        try befriend(alice, bob)
        try body(clients, relay, alice, bob)
    }
}

private func withoutOneTimePrekey(_ bundle: PrekeyBundle) -> PrekeyBundle {
    var bundle = bundle
    bundle.oneTimePrekey = nil
    return bundle
}

/// The session of version 1 that Alice started and Bob accepted before both moved to
/// version 2: section 16 run by hand on both stores, as a client of version 1 left them.
private func makeX3DHSession(_ alice: Client, _ bob: Client, _ relay: Relay) throws {
    let bundle = withoutOneTimePrekey(relay.fetch(bob.identityKey))
    let aliceIdentity = try #require(try alice.store.identity())
    let bobIdentity = try #require(try bob.store.identity())
    let started = try X3DH.initiate(
        bundle: bundle,
        identityKey: alice.identityKey,
        identityDHPrivateKey: aliceIdentity.identityDHPrivateKey,
        ephemeralPrivateKey: Data(repeating: 0x5A, count: 32),
        contactIdentityKey: bob.identityKey,
        pinnedIdentityDHKey: nil
    )
    var header = Sotto_InitialHeader()
    header.identityDhKey = alice.identityDHKey
    header.identityDhSignature = try Identity.signIdentityDHKey(seed: aliceIdentity.seed, identityDHKey: alice.identityDHKey)
    header.ephemeralKey = started.associatedData.suffix(32)
    header.signedPrekeyID = bundle.signedPrekey.id
    let signedPrekeyPrivateKey = try #require(try bob.store.signedPrekey(bundle.signedPrekey.id, replacedAfter: 0))
    let accepted = try X3DH.respond(
        identityKey: bob.identityKey,
        identityDHPrivateKey: bobIdentity.identityDHPrivateKey,
        signedPrekeyPrivateKey: signedPrekeyPrivateKey,
        oneTimePrekeyPrivateKey: nil,
        senderIdentityKey: alice.identityKey,
        senderIdentityDHKey: header.identityDhKey,
        senderIdentityDHSignature: header.identityDhSignature,
        ephemeralKey: header.ephemeralKey,
        pinnedIdentityDHKey: nil
    )

    try alice.store.transaction {
        _ = try alice.store.addSession(
            bob.identityKey,
            associatedData: started.associatedData,
            state: Ratchet.initInitiator(
                sharedSecret: started.sharedSecret,
                signedPrekey: bundle.signedPrekey.key,
                ratchetPrivateKey: Data(repeating: 0x5B, count: 32)
            ),
            initialHeader: header.serializedBytes()
        )
        try alice.store.setPin(bob.identityKey, identityDHKey: bundle.identityDHKey)
    }
    try bob.store.transaction {
        let sessionID = try bob.store.addSession(
            alice.identityKey,
            associatedData: accepted.associatedData,
            state: Ratchet.initResponder(sharedSecret: accepted.sharedSecret, signedPrekeyPrivateKey: signedPrekeyPrivateKey),
            initialHeader: nil
        )
        try bob.store.addRecord(
            sender: alice.identityKey, ephemeralKey: header.ephemeralKey, sessionID: sessionID,
            signedPrekeyID: bundle.signedPrekey.id
        )
        try bob.store.setPin(alice.identityKey, identityDHKey: alice.identityDHKey)
    }
}

private func envelope(_ delivered: Delivered) throws -> Sotto_PeerMessage {
    try Sotto_PeerMessage(serializedBytes: delivered.payload)
}

@Test func newSessionIsPQXDHOfVersion2AndTextsGoBothWays() throws {
    try withPQPair { _, relay, alice, bob in
        let delivered = try send(relay, alice, bob, "hello")
        let sent = try envelope(delivered)

        #expect(sent.version == 2)
        #expect(sent.initialHeader.kemCiphertext.count == PQXDH.kemCiphertextLength)
        #expect(sent.initialHeader.pqPrekeyID == 2)
        #expect(try bob.receive(delivered).text == "hello")
        let reply = try send(relay, bob, alice, "hi")
        #expect(try envelope(reply).version == 2)
        #expect(try alice.receive(reply).text == "hi")
        #expect(try alice.store.sessions(bob.identityKey)[0].version == 2)
        #expect(try bob.store.sessions(alice.identityKey)[0].version == 2)
    }
}

@Test func oneTimePQPrekeyStartsOneSessionAndIsDeletedOnlyWhenAccepted() throws {
    try withPQPair { clients, relay, alice, bob in
        let carol = try clients.open("carol")
        try befriend(carol, bob)
        let bundle = withoutOneTimePrekey(relay.fetch(bob.identityKey))
        let pqPrekeyID = try #require(bundle.pqPrekey?.id)
        #expect(try heldPQOneTimePrekeyIDs(bob) == [Int64(pqPrekeyID)])
        let fromAlice = relay.send(alice, try alice.sendText(bob.identityKey, "a", bundle: bundle))
        let fromCarol = relay.send(carol, try carol.sendText(bob.identityKey, "c", bundle: bundle))

        let spoiled = try editEnvelope(fromAlice) { $0.initialHeader.kemCiphertext = Data(count: PQXDH.kemCiphertextLength) }
        #expect(try bob.receive(spoiled).result == "DECRYPT_FAILED")
        #expect(try heldPQOneTimePrekeyIDs(bob) == [Int64(pqPrekeyID)])
        #expect(try bob.receive(fromAlice).text == "a")
        #expect(try heldPQOneTimePrekeyIDs(bob).isEmpty)
        #expect(try bob.receive(fromCarol).result == "UNKNOWN_PQ_PREKEY")
    }
}

@Test func bundleWithoutAPQPrekeyEndsStartWithPQPrekeyMissingAndStoresNothing() throws {
    try withPQPair { _, relay, alice, bob in
        var stripped = relay.fetch(bob.identityKey)
        stripped.pqPrekey = nil
        let storeBefore = try rows(alice.store)

        #expect(throws: CryptoError.pqPrekeyMissing) {
            try alice.sendText(bob.identityKey, "not sent", bundle: stripped)
        }
        #expect(try rows(alice.store) == storeBefore)
    }
}

@Test func x3dhSessionMadeBeforeKeepsWorkingInBothDirections() throws {
    try withPQPair { _, relay, alice, bob in
        try makeX3DHSession(alice, bob, relay)

        let first = try send(relay, alice, bob, "on the old session")
        #expect(try envelope(first).version == 1)
        #expect(try envelope(first).hasInitialHeader)
        #expect(try bob.receive(first).text == "on the old session")
        let reply = try send(relay, bob, alice, "still old")
        #expect(try envelope(reply).version == 1)
        #expect(try alice.receive(reply).text == "still old")
        let later = try send(relay, alice, bob, "later")
        #expect(try !envelope(later).hasInitialHeader)
        #expect(try bob.receive(later).text == "later")
    }
}

@Test func newSessionOfVersion1IsRefusedAndChangesNothing() throws {
    try withPQPair { _, relay, alice, bob in
        try makeX3DHSession(alice, bob, relay)
        try bob.store.transaction {
            try bob.store.query("DELETE FROM records")
            try bob.store.query("DELETE FROM sessions")
        }
        let delivered = try send(relay, alice, bob, "of version 1")
        let storeBefore = try rows(bob.store)

        #expect(try bob.receive(delivered) == Received(ack: true, text: nil, result: "X3DH_REFUSED"))
        #expect(try rows(bob.store) == storeBefore)
    }
}

/// A store of the version before PQXDH lacks the two tables and has a signed prekey without
/// a post-quantum partner: it opens, gains them and rotates at the next login.
@Test func storeOfTheFirstVersionOpensAndRotatesToAPQPrekey() throws {
    try withClients { clients, _ in
        var carol = try clients.open("carol")
        try carol.store.transaction {
            _ = try carol.store.addSignedPrekey(Data(repeating: 0x61, count: 32), madeAt: clients.clock.now)
            try carol.store.query("DROP TABLE pq_prekeys")
            try carol.store.query("DROP TABLE pq_prekey_ids")
        }
        carol.store.close()

        carol = try clients.open("carol")
        let upload = try #require(
            try carol.prepareUpload(oneTimePrekeyCount: Client.oneTimePrekeyCap, pqOneTimePrekeyCount: Client.pqOneTimePrekeyCap)
        )

        #expect(upload.signedPrekey.id == 2)
        #expect(upload.pqPrekey?.id == 1)
        #expect(try carol.store.signedPrekey(1, replacedAfter: clients.clock.now - 1) != nil)
        try verifySignatures(upload, of: carol)
    }
}

@Test func largestUploadFitsOneFrame() throws {
    try withClients { clients, _ in
        let upload = try #require(try clients.open("carol").prepareUpload(oneTimePrekeyCount: 0, pqOneTimePrekeyCount: 0))

        let frame: Data = try Transport.uploadFrame(upload).serializedBytes()

        #expect(upload.oneTimePrekeys.count == Client.oneTimePrekeyCap)
        #expect(upload.pqOneTimePrekeys.count == Client.pqOneTimePrekeyCap)
        #expect(upload.pqPrekey != nil)
        #expect(frame.count <= Frames.maxFrameBytes)
    }
}

@Test(arguments: [(0, 40), (19, 21), (20, 0), (500, 0)])
func pqRefillTopsUpToTheCapBelowTheThreshold(count: Int, made: Int) throws {
    try withClients { clients, _ in
        let upload = try clients.open("carol").prepareUpload(
            oneTimePrekeyCount: Client.oneTimePrekeyCap, pqOneTimePrekeyCount: count
        )

        #expect((upload?.pqOneTimePrekeys.count ?? 0) == made)
    }
}

@Test func heldOneTimePQPrekeysAreBoundedAndARefusedUploadDeletesItsOwn() throws {
    try withClients { clients, _ in
        let carol = try clients.open("carol")
        let uploads = try (0..<11).map { _ in
            try #require(try carol.prepareUpload(oneTimePrekeyCount: Client.oneTimePrekeyCap, pqOneTimePrekeyCount: 0))
        }
        let held = try heldPQOneTimePrekeyIDs(carol)

        try carol.dropRefusedUpload(uploads[10])

        #expect(held.count == Client.pqOneTimePrekeyHeldMax)
        #expect(held.last == uploads[10].pqOneTimePrekeys.last.map { Int64($0.id) })
        #expect(held.first == uploads[1].pqOneTimePrekeys.first.map { Int64($0.id) })
        #expect(try heldPQOneTimePrekeyIDs(carol) == Array(held.dropLast(Client.pqOneTimePrekeyCap)))
    }
}

@Test func lastResortPQPrekeyLivesAndDiesWithItsSignedPrekey() throws {
    try withPQPair { clients, relay, alice, bob in
        var bundle = relay.fetch(bob.identityKey)
        bundle.pqPrekey = relay.prekeys[bob.identityKey]!.pqPrekey
        let lastResort = try #require(bundle.pqPrekey)
        let initial = relay.send(alice, try alice.sendText(bob.identityKey, "x", bundle: bundle))
        clients.clock.advance(Client.signedPrekeyRotationSeconds)
        let rotated = try #require(
            try bob.prepareUpload(oneTimePrekeyCount: Client.oneTimePrekeyCap, pqOneTimePrekeyCount: Client.pqOneTimePrekeyCap)
        )
        #expect(rotated.pqPrekey != nil)
        #expect(rotated.pqPrekey?.id != lastResort.id)

        clients.clock.advance(Client.signedPrekeyGraceSeconds)
        try bob.deleteExpiredPrekeys()

        #expect(try bob.store.pqPrekey(lastResort.id, replacedAfter: 0) == nil)
        #expect(try bob.receive(initial).result == "UNKNOWN_SIGNED_PREKEY")
    }
}

@Test func lastResortPQPrekeyStartsASessionDuringTheGracePeriodAndStays() throws {
    try withPQPair { clients, relay, alice, bob in
        var bundle = relay.fetch(bob.identityKey)
        bundle.pqPrekey = relay.prekeys[bob.identityKey]!.pqPrekey
        let lastResort = try #require(bundle.pqPrekey)
        let initial = relay.send(alice, try alice.sendText(bob.identityKey, "x", bundle: bundle))
        clients.clock.advance(Client.signedPrekeyRotationSeconds)
        _ = try bob.prepareUpload(oneTimePrekeyCount: Client.oneTimePrekeyCap, pqOneTimePrekeyCount: Client.pqOneTimePrekeyCap)

        #expect(try bob.receive(initial).text == "x")
        #expect(try bob.store.pqPrekey(lastResort.id, replacedAfter: 0)?.isOneTime == false)
    }
}
