import Foundation
@testable import SottoCore
import Testing

/// Bob holds sessions with Alice and Carol; two messages of Alice are on the way.
private struct World {
    let clients: Clients
    let relay: Relay
    let alice: Client
    let bob: Client
    let carol: Client
    let accepted: Delivered
    let later: Delivered
    let initial: Delivered
}

private func withWorld(_ body: (World) throws -> Void) throws {
    try withClients { clients, relay in
        let alice = try clients.open("alice")
        let bob = try clients.open("bob")
        let carol = try clients.open("carol")
        try relay.publish(bob, oneTimeCount: 3)
        try relay.publish(carol)
        for (first, second) in [(alice, bob), (carol, bob), (alice, carol)] {
            try befriend(first, second)
        }
        #expect(try bob.receive(send(relay, carol, bob, "from carol")).text == "from carol")
        let accepted = try send(relay, alice, bob, "accepted")
        #expect(try bob.receive(accepted).text == "accepted")
        try send(relay, bob, alice, "reply")
        try relay.deliver(alice)

        let later = try send(relay, alice, bob, "later")
        try alice.startSession(bob.identityKey, bundle: relay.fetch(bob.identityKey))
        let initial = try send(relay, alice, bob, "initial")
        try body(World(
            clients: clients, relay: relay, alice: alice, bob: bob, carol: carol,
            accepted: accepted, later: later, initial: initial
        ))
    }
}

private func flip(_ data: Data, _ position: Int, _ bits: UInt8 = 1) -> Data {
    var flipped = data
    flipped[(position % data.count + data.count) % data.count] ^= bits
    return flipped
}

/// Alice starts a session with Carol on the X25519 keys of Bob, signed by Carol, and the
/// relay hands the message to Bob.
private func keysOfBobUnderCarolsSignature(_ world: World) throws -> (Client, Delivered) {
    let bobBundle = world.relay.fetch(world.bob.identityKey)
    let carolSeed = try seed(world.carol)
    var signedPrekey = bobBundle.signedPrekey
    signedPrekey.signature = try Identity.signSignedPrekey(seed: carolSeed, signedPrekey: signedPrekey.key)
    var pqPrekey = try #require(bobBundle.pqPrekey)
    pqPrekey.signature = try Identity.signPQPrekey(seed: carolSeed, pqPrekey: pqPrekey.key)
    let bundle = PrekeyBundle(
        identity: world.carol.identityKey,
        identityDHKey: bobBundle.identityDHKey,
        identityDHSignature: try Identity.signIdentityDHKey(seed: carolSeed, identityDHKey: bobBundle.identityDHKey),
        signedPrekey: signedPrekey,
        oneTimePrekey: bobBundle.oneTimePrekey,
        pqPrekey: pqPrekey
    )
    let outgoing = try world.alice.sendText(world.carol.identityKey, "for carol", bundle: bundle)
    return (world.bob, Delivered(sender: world.alice.identityKey, messageID: outgoing.messageID, payload: outgoing.payload))
}

private func flipInitialHeader(
    _ world: World,
    _ field: WritableKeyPath<Sotto_InitialHeader, Data>,
    _ position: Int = 0,
    _ bits: UInt8 = 1
) throws -> (Client, Delivered) {
    (world.bob, try editEnvelope(world.initial) { $0.initialHeader[keyPath: field] = flip($0.initialHeader[keyPath: field], position, bits) })
}

private func flipEnvelope(
    _ delivered: Delivered,
    _ field: WritableKeyPath<Sotto_PeerMessage, Data>,
    _ position: Int
) throws -> Delivered {
    try editEnvelope(delivered) { $0[keyPath: field] = flip($0[keyPath: field], position) }
}

private let results: KeyValuePairs<String, String> = [
    "x25519 keys of one identity under the signature of another": "DECRYPT_FAILED",
    "swapped sender of a later message": "DECRYPT_FAILED",
    "swapped sender of an initial message": "BAD_INITIAL_HEADER",
    "initial message delivered to another recipient": "UNKNOWN_ONE_TIME_PREKEY",
    "later message delivered to another recipient": "NO_SESSION",
    "changed byte in the ephemeral key": "DECRYPT_FAILED",
    "ephemeral key with the same diffie-hellman outputs": "DECRYPT_FAILED",
    "changed byte in the x25519 identity key": "BAD_INITIAL_HEADER",
    "changed byte in the signature": "BAD_INITIAL_HEADER",
    "changed byte in the ratchet key of the header": "DECRYPT_FAILED",
    "changed byte in the number of the header": "DECRYPT_FAILED",
    "changed byte in the nonce": "DECRYPT_FAILED",
    "changed byte in the nonce of an initial message": "DECRYPT_FAILED",
    "changed byte in the ciphertext": "DECRYPT_FAILED",
    "changed message id": "DECRYPT_FAILED",
    "changed message id of an initial message": "DECRYPT_FAILED",
    "stripped one-time prekey id": "DECRYPT_FAILED",
    "replay": "DUPLICATE",
    "replay after its seen id is forgotten": "DECRYPT_FAILED",
    "changed byte in the kem ciphertext": "DECRYPT_FAILED",
    "stripped kem ciphertext": "BAD_ENVELOPE",
    "changed post-quantum prekey id": "UNKNOWN_PQ_PREKEY",
    "new session made version 1": "X3DH_REFUSED",
    "later message made version 1": "DECRYPT_FAILED",
]

private func hostileCase(_ name: String, _ world: World) throws -> (Client, Delivered) {
    switch name {
    case "x25519 keys of one identity under the signature of another":
        return try keysOfBobUnderCarolsSignature(world)
    case "swapped sender of a later message":
        var delivered = world.later
        delivered.sender = world.carol.identityKey
        return (world.bob, delivered)
    case "swapped sender of an initial message":
        var delivered = world.initial
        delivered.sender = world.carol.identityKey
        return (world.bob, delivered)
    case "initial message delivered to another recipient":
        return (world.carol, world.initial)
    case "later message delivered to another recipient":
        return (world.carol, world.later)
    case "changed byte in the ephemeral key":
        return try flipInitialHeader(world, \.ephemeralKey)
    case "ephemeral key with the same diffie-hellman outputs":
        // X25519 ignores the top bit of the last byte, so the secret stays and the data differs.
        return try flipInitialHeader(world, \.ephemeralKey, -1, 0x80)
    case "changed byte in the x25519 identity key":
        return try flipInitialHeader(world, \.identityDhKey)
    case "changed byte in the signature":
        return try flipInitialHeader(world, \.identityDhSignature)
    case "changed byte in the ratchet key of the header":
        return (world.bob, try flipEnvelope(world.later, \.header, 0))
    case "changed byte in the number of the header":
        return (world.bob, try flipEnvelope(world.later, \.header, 39))
    case "changed byte in the nonce":
        return (world.bob, try flipEnvelope(world.later, \.ciphertext, 0))
    case "changed byte in the nonce of an initial message":
        return (world.bob, try flipEnvelope(world.initial, \.ciphertext, 0))
    case "changed byte in the ciphertext":
        return (world.bob, try flipEnvelope(world.later, \.ciphertext, -1))
    case "changed message id":
        var delivered = world.later
        delivered.messageID = flip(delivered.messageID, 0)
        return (world.bob, delivered)
    case "changed message id of an initial message":
        var delivered = world.initial
        delivered.messageID = flip(delivered.messageID, 15)
        return (world.bob, delivered)
    case "stripped one-time prekey id":
        return (world.bob, try editEnvelope(world.initial) { $0.initialHeader.clearOneTimePrekeyID() })
    case "replay":
        return (world.bob, world.accepted)
    case "replay after its seen id is forgotten":
        world.clients.clock.advance(Client.seenIDSeconds)
        try world.bob.forgetSeenIDs()
        return (world.bob, world.accepted)
    case "changed byte in the kem ciphertext":
        return try flipInitialHeader(world, \.kemCiphertext, 500)
    case "stripped kem ciphertext":
        return (world.bob, try editEnvelope(world.initial) { $0.initialHeader.kemCiphertext = Data() })
    case "changed post-quantum prekey id":
        return (world.bob, try editEnvelope(world.initial) { $0.initialHeader.pqPrekeyID = 99 })
    case "new session made version 1":
        return (world.bob, try editEnvelope(world.initial) { $0.version = 1 })
    case "later message made version 1":
        return (world.bob, try editEnvelope(world.later) { $0.version = 1 })
    default:
        Issue.record("no case named \(name)")
        return (world.bob, world.accepted)
    }
}

@Test(arguments: results.map(\.key))
func lyingRelayGivesNoTextAndLeavesTheStoreUnchanged(name: String) throws {
    let result = results.first { $0.key == name }!.value
    try withWorld { world in
        let (receiver, delivered) = try hostileCase(name, world)
        let storeBefore = try rows(receiver.store)

        let received = try receiver.receive(delivered)

        #expect(received == Received(ack: true, text: nil, result: result))
        #expect(try rows(receiver.store) == storeBefore)
        #expect(try world.bob.receive(world.later).text == "later")
        #expect(try world.bob.receive(world.initial).text == "initial")
    }
}

@Test func changedPrekeyIDsOfAMessageWithARecordChangeNothing() throws {
    try withWorld { world in
        #expect(try world.bob.receive(world.initial).text == "initial")
        let onTheSession = try send(world.relay, world.alice, world.bob, "same session")

        let received = try world.bob.receive(editEnvelope(onTheSession) {
            $0.initialHeader.signedPrekeyID = 99
            $0.initialHeader.clearOneTimePrekeyID()
            $0.initialHeader.pqPrekeyID = 99
        })

        #expect(received.text == "same session")
        #expect(received.result == nil)
    }
}

@Test func reorderedMessagesGiveEachTextOnce() throws {
    try withWorld { world in
        let sent = try (0..<4).map { try send(world.relay, world.alice, world.bob, "text \($0)") }

        let received = try (sent.reversed() + [sent[2]]).map(world.bob.receive)

        #expect(texts(received) == ["text 3", "text 2", "text 1", "text 0", nil])
        #expect(received.last?.result == "DUPLICATE")
        #expect(try world.bob.receive(world.later).text == "later")
    }
}

/// The property of the reference's generated deliveries, over a seeded run of the same
/// size: a contact or a random sender, random bytes or a real payload with one byte changed.
@Test func arbitraryBytesFromAnySenderEndInANamedResult() throws {
    try withWorld { world in
        let random = Randomness("arbitrary bytes")
        for _ in 0..<50 {
            let sender = [world.alice.identityKey, world.carol.identityKey, random(32)][random.below(3)]
            var payload = [world.later.payload, world.initial.payload][random.below(2)]
            if random.below(2) == 0 {
                payload = random(random.below(1001))
            } else {
                payload[random.below(payload.count)] ^= UInt8(1 + random.below(255))
            }
            let storeBefore = try rows(world.bob.store)

            let received = try world.bob.receive(Delivered(sender: sender, messageID: random(16), payload: payload))

            #expect(received.ack)
            #expect(received.text == nil)
            #expect(received.result != nil)
            #expect(try rows(world.bob.store) == storeBefore)
        }
    }
}
