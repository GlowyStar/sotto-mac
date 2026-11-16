import Foundation
@testable import SottoCore
import Testing

private let longestPayload = 65472

private func content(_ text: String?) throws -> Data {
    var content = Sotto_Content()
    if let text {
        content.text = text
    }
    return try content.serializedBytes()
}

@Test func firstMessagesToAnOfflinePeerDecryptInOrderAndTheReplyEndsTheHeader() throws {
    try withPair { _, relay, alice, bob in
        let sent = try (0..<3).map { try send(relay, alice, bob, "text \($0)") }
        let headers = try sent.map(initialHeader(of:))

        #expect(try texts(relay.deliver(bob)) == ["text 0", "text 1", "text 2"])
        let first = try #require(headers[0])
        #expect(Array(headers[1...]) == Array(headers[..<2]))
        #expect(first.identityDhKey == alice.identityDHKey)
        #expect(first.signedPrekeyID == relay.prekeys[bob.identityKey]!.signedPrekey.id)
        #expect(first.oneTimePrekeyID == 1)
        try Identity.verifyIdentityDHKey(
            identityKey: alice.identityKey,
            identityDHKey: first.identityDhKey,
            signature: first.identityDhSignature
        )

        try send(relay, bob, alice, "reply")
        #expect(try initialHeader(of: send(relay, alice, bob, "after the reply")) != nil)
        #expect(try texts(relay.deliver(alice)) == ["reply"])
        #expect(try initialHeader(of: send(relay, alice, bob, "after the decryption")) == nil)
        #expect(try initialHeader(of: send(relay, bob, alice, "from the responder")) == nil)
        #expect(try texts(relay.deliver(bob)) == ["after the reply", "after the decryption"])
    }
}

@Test func twoClientsExchangeTextsInBothDirections() throws {
    try withPair { _, relay, alice, bob in
        for round in 0..<4 {
            try send(relay, alice, bob, "to bob \(round)")
            try send(relay, alice, bob, "to bob \(round), again")
            #expect(try texts(relay.deliver(bob)) == ["to bob \(round)", "to bob \(round), again"])
            try send(relay, bob, alice, "to alice \(round)")
            #expect(try texts(relay.deliver(alice)) == ["to alice \(round)"])
        }

        let logged = try bob.store.query("SELECT direction, count(*) FROM messages GROUP BY direction ORDER BY direction")
        #expect(logged == [[.text("in"), .integer(8)], [.text("out"), .integer(4)]])
    }
}

@Test func envelopeDeliveredTwiceGivesOneTextAndTwoAcks() throws {
    try withPair { _, relay, alice, bob in
        let delivered = try send(relay, alice, bob, "once")
        let first = try bob.receive(delivered)
        let storeAfterFirst = try rows(bob.store)
        let second = try bob.receive(delivered)

        #expect(first == Received(ack: true, text: "once", result: nil))
        #expect(second == Received(ack: true, text: nil, result: "DUPLICATE"))
        #expect(try rows(bob.store) == storeAfterFirst)
    }
}

@Test(arguments: [1, 0])
func replayedInitialMessageGivesNoSecondText(oneTimeCount: Int) throws {
    try withPair(bobOneTimeCount: oneTimeCount) { _, relay, alice, bob in
        let initial = try send(relay, alice, bob, "first")
        #expect(try bob.receive(initial).text == "first")

        try bob.store.transaction { try bob.store.query("DELETE FROM seen_ids") }
        #expect(try bob.receive(initial).result == "DECRYPT_FAILED")

        for number in 0..<ClientStore.maxSessions {
            try relay.publish(bob, oneTimeCount: oneTimeCount)
            try alice.startSession(bob.identityKey, bundle: relay.fetch(bob.identityKey))
            #expect(try bob.receive(send(relay, alice, bob, "new \(number)")).text == "new \(number)")
        }
        let storeBefore = try rows(bob.store)

        #expect(try bob.receive(initial).result == "REPLAYED_INITIAL")
        #expect(try rows(bob.store) == storeBefore)
    }
}

@Test func laterMessageFindsItsSessionWithAndWithoutTheInitialHeader() throws {
    try withPair { _, relay, alice, bob in
        let sent = try (0..<3).map { try send(relay, alice, bob, "text \($0)") }
        let stripped = try editEnvelope(sent[2]) { $0.clearInitialHeader() }

        #expect(try bob.receive(sent[0]).text == "text 0")
        #expect(try bob.receive(stripped).text == "text 2")
        #expect(try bob.receive(sent[1]).text == "text 1")
        #expect(try bob.store.sessions(alice.identityKey).count == 1)
    }
}

@Test func bundleOfAnotherIdentityIsRefused() throws {
    try withPair { clients, relay, alice, bob in
        let carol = try clients.open("carol")
        try relay.publish(carol)
        var bundle = relay.fetch(bob.identityKey)
        bundle.identity = carol.identityKey
        let storeBefore = try rows(alice.store)

        #expect(throws: CryptoError.badBundle) { try alice.sendText(bob.identityKey, "hello", bundle: bundle) }
        #expect(try rows(alice.store) == storeBefore)
    }
}

@Test func bundleWithAnotherX25519KeyThanThePinIsRefused() throws {
    try withPair { _, relay, alice, bob in
        try send(relay, alice, bob, "pins the key")
        #expect(try alice.store.pin(bob.identityKey) == bob.identityDHKey)
        let otherKey = try Identity.deriveX25519PublicKey(Data(0..<32))
        var bundle = relay.fetch(bob.identityKey)
        bundle.identityDHKey = otherKey
        bundle.identityDHSignature = try Identity.signIdentityDHKey(seed: seed(bob), identityDHKey: otherKey)
        let storeBefore = try rows(alice.store)

        #expect(throws: CryptoError.identityKeyMismatch) { try alice.startSession(bob.identityKey, bundle: bundle) }
        #expect(try rows(alice.store) == storeBefore)
    }
}

@Test func keyAgreementThatFailsAfterTheChecksStoresNoSessionAndNoPin() throws {
    try withPair { _, relay, alice, bob in
        let smallOrderKey = Data(count: 32)
        var bundle = relay.fetch(bob.identityKey)
        bundle.signedPrekey = SignedPrekey(
            id: bundle.signedPrekey.id,
            key: smallOrderKey,
            signature: try Identity.signSignedPrekey(seed: seed(bob), signedPrekey: smallOrderKey)
        )
        let storeBefore = try rows(alice.store)

        #expect(throws: CryptoError.zeroDH) { try alice.sendText(bob.identityKey, "hello", bundle: bundle) }
        #expect(try rows(alice.store) == storeBefore)
    }
}

@Test func strangerIsAckedBeforeAByteIsParsed() throws {
    try withPair { clients, relay, _, bob in
        let carol = try clients.open("carol")
        try carol.addContact(userID(bob))
        let real = try send(relay, carol, bob, "from a stranger")
        let garbage = Delivered(sender: carol.identityKey, messageID: real.messageID, payload: Data([0xFF]))
        let storeBefore = try rows(bob.store)

        for delivered in [real, garbage] {
            #expect(try bob.receive(delivered) == Received(ack: true, text: nil, result: "NOT_A_CONTACT"))
        }
        #expect(try rows(bob.store) == storeBefore)
    }
}

@Test func textToAStrangerIsRefused() throws {
    try withClients { clients, _ in
        let alice = try clients.open("alice")
        let carol = try clients.open("carol")
        #expect(throws: SessionError.notAContact) { try alice.sendText(carol.identityKey, "hello") }
    }
}

@Test func invalidIDAddsNoContact() throws {
    try withClients { clients, _ in
        let alice = try clients.open("alice")
        let storeBefore = try rows(alice.store)

        #expect(throws: CryptoError.invalidID) { try alice.addContact(String(repeating: "0", count: 63)) }
        #expect(try rows(alice.store) == storeBefore)
    }
}

@Test func ownIDIsNeverAContact() throws {
    try withClients { clients, _ in
        let alice = try clients.open("alice")
        #expect(throws: OwnIdentityError()) { try alice.addContact(userID(alice)) }
    }
}

@Test func substitutedOneTimePrekeyEndsInADecryptFailureAndKeepsThePrekey() throws {
    try withPair { _, relay, alice, bob in
        var bundle = relay.fetch(bob.identityKey)
        let original = try #require(bundle.oneTimePrekey)
        bundle.oneTimePrekey = OneTimePrekey(id: original.id, key: try Identity.deriveX25519PublicKey(Data(1...32)))
        let outgoing = try alice.sendText(bob.identityKey, "hello", bundle: bundle)
        let storeBefore = try rows(bob.store)

        let received = try bob.receive(relay.send(alice, outgoing))

        #expect(received == Received(ack: true, text: nil, result: "DECRYPT_FAILED"))
        #expect(try rows(bob.store) == storeBefore)
        #expect(try bob.store.oneTimePrekey(original.id) != nil)
    }
}

@Test func oneTimePrekeyHandedToTwoInitiatorsStartsOneSession() throws {
    try withPair { clients, relay, alice, bob in
        let carol = try clients.open("carol")
        try befriend(carol, bob)
        let bundle = relay.fetch(bob.identityKey)
        let fromAlice = relay.send(alice, try alice.sendText(bob.identityKey, "alice", bundle: bundle))
        let fromCarol = relay.send(carol, try carol.sendText(bob.identityKey, "carol", bundle: bundle))

        #expect(try bob.receive(fromAlice).text == "alice")
        #expect(try bob.receive(fromCarol).result == "UNKNOWN_ONE_TIME_PREKEY")
        #expect(try bob.store.sessions(carol.identityKey).isEmpty)
    }
}

@Test func unknownSignedPrekeyIDIsRefused() throws {
    try withPair { _, relay, alice, bob in
        var bundle = relay.fetch(bob.identityKey)
        bundle.signedPrekey.id = 99
        let outgoing = try alice.sendText(bob.identityKey, "hello", bundle: bundle)

        #expect(try bob.receive(relay.send(alice, outgoing)).result == "UNKNOWN_SIGNED_PREKEY")
    }
}

@Test(arguments: [("signature", "BAD_INITIAL_HEADER"), ("key under its signature", "IDENTITY_KEY_MISMATCH")])
func initialHeaderThatFailsStep1Or2ChangesNothing(change: String, result: String) throws {
    try withPair { _, relay, alice, bob in
        #expect(try bob.receive(send(relay, alice, bob, "pins the key")).text == "pins the key")
        let otherKey = try Identity.deriveX25519PublicKey(Data(0..<32))
        let otherSignature = try Identity.signIdentityDHKey(seed: seed(alice), identityDHKey: otherKey)

        let delivered = try editEnvelope(send(relay, alice, bob, "second")) { envelope in
            if change == "signature" {
                envelope.initialHeader.identityDhSignature = Data(count: 64)
            } else {
                envelope.initialHeader.identityDhKey = otherKey
                envelope.initialHeader.identityDhSignature = otherSignature
            }
        }
        let storeBefore = try rows(bob.store)

        #expect(try bob.receive(delivered).result == result)
        #expect(try rows(bob.store) == storeBefore)
    }
}

@Test func messageWithoutInitialHeaderFromAContactWithoutSessionIsNoSession() throws {
    try withPair { _, relay, alice, bob in
        let delivered = try editEnvelope(send(relay, alice, bob, "hello")) { $0.clearInitialHeader() }
        let storeBefore = try rows(bob.store)

        #expect(try bob.receive(delivered).result == "NO_SESSION")
        #expect(try rows(bob.store) == storeBefore)
    }
}

@Test(arguments: [UInt32(0), 2])
func otherVersionIsAckedAndChangesNothing(version: UInt32) throws {
    try withPair { _, relay, alice, bob in
        let delivered = try editEnvelope(send(relay, alice, bob, "hello")) { $0.version = version }
        let storeBefore = try rows(bob.store)

        #expect(try bob.receive(delivered) == Received(ack: true, text: nil, result: "UNSUPPORTED_VERSION"))
        #expect(try rows(bob.store) == storeBefore)
    }
}

/// A trigger makes the store fail at the seen id, inside the transaction of the message,
/// after its other writes: the point where the client stops.
@Test(arguments: ["initial", "later"])
func crashBetweenDecryptionAndCommitChangesNothingAndTheMessageDecryptsAgain(message: String) throws {
    try withPair { _, relay, alice, bob in
        if message == "later" {
            #expect(try bob.receive(send(relay, alice, bob, "first")).text == "first")
            try send(relay, bob, alice, "reply")
            try relay.deliver(alice)
        }
        let delivered = try send(relay, alice, bob, "survives the crash")
        try bob.store.query("CREATE TEMP TRIGGER crash BEFORE INSERT ON seen_ids BEGIN SELECT RAISE(ABORT, 'stopped'); END")
        let storeBefore = try rows(bob.store)

        #expect(throws: StoreError.self) { try bob.receive(delivered) }
        #expect(try rows(bob.store) == storeBefore)

        try bob.store.query("DROP TRIGGER crash")
        #expect(try bob.receive(delivered).text == "survives the crash")
    }
}

@Test func outboxBytesSentAgainAfterACrashGiveOneText() throws {
    try withPair { clients, relay, alice, bob in
        let lost = try alice.sendText(bob.identityKey, "lost", bundle: relay.fetch(bob.identityKey))
        let stored = try alice.sendText(bob.identityKey, "stored before the crash")
        relay.send(alice, stored)
        alice.store.close()

        let restarted = try clients.open("alice")
        let outbox = try restarted.outbox()
        #expect(outbox == [lost, stored])
        for outgoing in outbox {
            relay.send(restarted, outgoing)
        }

        let received = try relay.deliver(bob)
        #expect(received.map(\.text) == ["stored before the crash", "lost", nil])
        #expect(received.map(\.result) == [nil, nil, "DUPLICATE"])
        for outgoing in outbox {
            try restarted.confirmStored(outgoing.messageID)
        }
        #expect(try restarted.outbox().isEmpty)
    }
}

@Test func textTooLongIsRefusedBeforeAnyBundleOrKeyAgreement() throws {
    try withPair { _, _, alice, bob in
        let storeBefore = try rows(alice.store)

        #expect(throws: EnvelopeError.textTooLong) {
            try alice.sendText(bob.identityKey, String(repeating: "x", count: Envelope.maxTextBytes + 1))
        }
        #expect(try rows(alice.store) == storeBefore)
    }
}

@Test func largestTextFitsAPayloadWithAnInitialHeader() throws {
    try withPair { _, relay, alice, bob in
        let text = String(repeating: "\u{E9}", count: Envelope.maxTextBytes / 2) + "x"
        let delivered = try send(relay, alice, bob, text)
        let envelope = try Sotto_PeerMessage(serializedBytes: delivered.payload)

        #expect(text.utf8.count == Envelope.maxTextBytes)
        #expect(envelope.hasInitialHeader)
        #expect(envelope.ciphertext.count == 65052)
        #expect(delivered.payload.count <= longestPayload)
        #expect(try bob.receive(delivered).text == text)
    }
}

@Test func receiverAppliesNoLimitToAText() throws {
    try withPair { _, relay, alice, bob in
        let text = String(repeating: "x", count: Envelope.maxTextBytes * 2)
        let outgoing = try alice.send(
            bob.identityKey,
            paddedPlaintext: Envelope.pad(content(text)),
            text: text,
            bundle: relay.fetch(bob.identityKey)
        )

        #expect(try bob.receive(relay.send(alice, outgoing)).text == text)
    }
}

@Test(arguments: 0..<3)
func messageWithoutATextSavesItsStateAndSeenIDAndLogsNothing(index: Int) throws {
    let cases: [(Data, String)] = [
        (Data(count: 256), "BAD_PADDING"),
        (Envelope.pad(Data([0x0A, 0x02, 0xFF, 0xFE])), "BAD_CONTENT"),
        (Envelope.pad(try content(nil)), "UNKNOWN_CONTENT"),
    ]
    let (plaintext, result) = cases[index]
    try withPair { _, relay, alice, bob in
        let outgoing = try alice.send(
            bob.identityKey,
            paddedPlaintext: plaintext,
            text: "never read",
            bundle: relay.fetch(bob.identityKey)
        )
        let delivered = relay.send(alice, outgoing)

        #expect(try bob.receive(delivered) == Received(ack: true, text: nil, result: result))
        #expect(try bob.store.isSeen(sender: alice.identityKey, messageID: delivered.messageID))
        #expect(try bob.store.query("SELECT count(*) FROM messages") == [[.integer(0)]])
        #expect(try bob.receive(send(relay, alice, bob, "next")).text == "next")
    }
}

@Test func storedResponderSessionHoldsNeitherTheSecretNorTheSignedPrekey() throws {
    try withPair { _, relay, alice, bob in
        let delivered = try send(relay, alice, bob, "hello")
        let header = try #require(try initialHeader(of: delivered))
        let bobIdentity = try #require(try bob.store.identity())
        let signedPrekeyPrivateKey = try #require(try bob.store.signedPrekey(header.signedPrekeyID, replacedAfter: 0))
        let agreement = try X3DH.respond(
            identityKey: bob.identityKey,
            identityDHPrivateKey: bobIdentity.identityDHPrivateKey,
            signedPrekeyPrivateKey: signedPrekeyPrivateKey,
            oneTimePrekeyPrivateKey: try bob.store.oneTimePrekey(header.oneTimePrekeyID),
            senderIdentityKey: alice.identityKey,
            senderIdentityDHKey: header.identityDhKey,
            senderIdentityDHSignature: header.identityDhSignature,
            ephemeralKey: header.ephemeralKey,
            pinnedIdentityDHKey: nil
        )

        #expect(try bob.receive(delivered).text == "hello")
        let state = Data(try bob.store.query("SELECT state FROM sessions")[0][0].text!.utf8)
        for secret in [agreement.sharedSecret, signedPrekeyPrivateKey] {
            #expect(!storedForms(secret).contains { state.range(of: $0) != nil })
        }
        #expect(try bob.store.oneTimePrekey(header.oneTimePrekeyID) == nil)
        #expect(try bob.store.pin(alice.identityKey) == alice.identityDHKey)
    }
}

/// The property of the reference's generated payloads, over a seeded run of the same size:
/// random bytes or a real payload with one byte replaced, under a random message id.
@Test func arbitraryPayloadEndsInANamedResultAndAnUnchangedStore() throws {
    try withPair { _, relay, alice, bob in
        #expect(try bob.receive(send(relay, alice, bob, "first")).text == "first")
        let real = try send(relay, alice, bob, "second")
        let random = Randomness("arbitrary payload")

        for _ in 0..<100 {
            var payload: Data
            if random.below(2) == 0 {
                payload = random(random.below(1001))
            } else {
                payload = real.payload
                payload[random.below(payload.count)] = UInt8(random.below(256))
            }
            let delivered = Delivered(sender: alice.identityKey, messageID: random(16), payload: payload)
            let storeBefore = try rows(bob.store)

            let received = try bob.receive(delivered)

            #expect(received.ack)
            #expect(received.text == nil)
            #expect(received.result != nil)
            #expect(try rows(bob.store) == storeBefore)
        }
    }
}

@Test func storeRestartsWithTheSession() throws {
    try withPair { clients, relay, alice, bob in
        try send(relay, alice, bob, "before")
        try relay.deliver(bob)
        bob.store.close()

        let restarted = try clients.open("bob")
        #expect(restarted.identityKey == bob.identityKey)
        #expect(try restarted.receive(send(relay, alice, restarted, "after")).text == "after")
    }
}
