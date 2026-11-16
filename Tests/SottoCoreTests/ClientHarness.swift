import CryptoKit
import Foundation
@testable import SottoCore

/// Random bytes that a test can repeat: SHA-256 of a label and a counter.
final class Randomness {
    let label: Data
    var count: UInt64 = 0

    init(_ label: String) {
        self.label = Data(label.utf8)
    }

    func callAsFunction(_ length: Int) -> Data {
        var output = Data()
        while output.count < length {
            count += 1
            output += Data(SHA256.hash(data: label + withUnsafeBytes(of: count.bigEndian) { Data($0) }))
        }
        return Data(output.prefix(length))
    }

    func below(_ bound: Int) -> Int {
        Int(self(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) } % UInt64(bound))
    }
}

/// The one clock of every client of a test; the test moves it by hand.
final class TestClock {
    var now: Int64 = 1_800_000_000

    func advance(_ seconds: Int64) {
        now += seconds
    }
}

/// Makes clients under one folder; `withClients` closes their stores and removes the folder.
final class Clients {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-session-\(UUID().uuidString)")
    let clock = TestClock()
    private var stores: [ClientStore] = []

    /// Opens the client of a name; a second call is a restart on the same store.
    func open(_ name: String) throws -> Client {
        let store = try ClientStore(directory: folder.appendingPathComponent(name))
        stores.append(store)
        let randomness = Randomness(name)
        let clock = clock
        return try Client(store: store, randomBytes: { randomness($0) }, clock: { TimeInterval(clock.now) })
    }

    func close() {
        stores.forEach { $0.close() }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// The relay as a dictionary: prekeys to hand out and a queue per recipient.
final class Relay {
    var prekeys: [Data: PrekeyUpload] = [:]
    var queues: [Data: [Delivered]] = [:]

    func publish(_ client: Client, oneTimeCount: Int = 1) throws {
        prekeys[client.identityKey] = try client.makePrekeys(oneTimeCount: oneTimeCount)
    }

    /// Hands out the bundle with the first one-time prekey, which leaves the relay.
    func fetch(_ identity: Data) -> PrekeyBundle {
        var upload = prekeys[identity]!
        let oneTimePrekey = upload.oneTimePrekeys.first
        upload.oneTimePrekeys = Array(upload.oneTimePrekeys.dropFirst())
        prekeys[identity] = upload
        return PrekeyBundle(
            identity: identity,
            identityDHKey: upload.identityDHKey,
            identityDHSignature: upload.identityDHSignature,
            signedPrekey: upload.signedPrekey,
            oneTimePrekey: oneTimePrekey
        )
    }

    @discardableResult
    func send(_ sender: Client, _ outgoing: Outgoing) -> Delivered {
        let delivered = Delivered(sender: sender.identityKey, messageID: outgoing.messageID, payload: outgoing.payload)
        queues[outgoing.recipient, default: []].append(delivered)
        return delivered
    }

    /// Delivers the queue of a client in order and empties it.
    @discardableResult
    func deliver(_ client: Client) throws -> [Received] {
        let queue = queues.removeValue(forKey: client.identityKey) ?? []
        return try queue.map(client.receive)
    }
}

func withClients(_ body: (Clients, Relay) throws -> Void) throws {
    let clients = Clients()
    defer { clients.close() }
    try body(clients, Relay())
}

/// Alice and Bob as contacts, Bob's prekeys on the relay.
func withPair(
    publishAlice: Bool = false,
    bobOneTimeCount: Int = 1,
    _ body: (Clients, Relay, Client, Client) throws -> Void
) throws {
    try withClients { clients, relay in
        let alice = try clients.open("alice")
        if publishAlice {
            try relay.publish(alice)
        }
        let bob = try clients.open("bob")
        try relay.publish(bob, oneTimeCount: bobOneTimeCount)
        try befriend(alice, bob)
        try body(clients, relay, alice, bob)
    }
}

func userID(_ client: Client) throws -> String {
    try Identity.encodeUserID(client.identityKey)
}

func befriend(_ first: Client, _ second: Client) throws {
    try first.addContact(userID(second))
    try second.addContact(userID(first))
}

/// L1 at the sender, with a bundle from the relay when it has no session.
@discardableResult
func send(_ relay: Relay, _ sender: Client, _ recipient: Client, _ text: String) throws -> Delivered {
    let bundle = try sender.hasSession(recipient.identityKey) ? nil : relay.fetch(recipient.identityKey)
    return relay.send(sender, try sender.sendText(recipient.identityKey, text, bundle: bundle))
}

/// Every row of every table, to compare a store before and after.
func rows(_ store: ClientStore) throws -> [String: [[SQLValue]]] {
    var tables: [String: [[SQLValue]]] = [:]
    for table in try store.query("SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name") {
        let name = table[0].text!
        tables[name] = try store.query("SELECT * FROM \"\(name)\"")
    }
    return tables
}

/// The forms in which the store can hold a value: its bytes, hex text, and the base64 of
/// the JSON of a ratchet state with and without escaped slashes.
func storedForms(_ value: Data) -> [Data] {
    let base64 = value.base64EncodedString()
    return [
        value,
        Data(value.map { String(format: "%02x", $0) }.joined().utf8),
        Data(base64.utf8),
        Data(base64.replacingOccurrences(of: "/", with: "\\/").utf8),
    ]
}

/// The files of a client folder that hold the value in one of its stored forms.
func filesHolding(_ folder: URL, _ value: Data) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted().filter { name in
        let content = try Data(contentsOf: folder.appendingPathComponent(name))
        return storedForms(value).contains { content.range(of: $0) != nil }
    }
}

func texts(_ received: [Received]) -> [String?] {
    received.map(\.text)
}

func editEnvelope(_ delivered: Delivered, _ edit: (inout Sotto_PeerMessage) -> Void) throws -> Delivered {
    var envelope = try Sotto_PeerMessage(serializedBytes: delivered.payload)
    edit(&envelope)
    var edited = delivered
    edited.payload = try envelope.serializedBytes()
    return edited
}

func initialHeader(of delivered: Delivered) throws -> Sotto_InitialHeader? {
    let envelope = try Sotto_PeerMessage(serializedBytes: delivered.payload)
    return envelope.hasInitialHeader ? envelope.initialHeader : nil
}

/// The keys of an upload; signatures are checked apart, as two signatures of one string
/// differ (section 4.1, rule 5).
func keys(_ upload: PrekeyUpload) -> [Data] {
    [upload.identityDHKey, upload.signedPrekey.key, withUnsafeBytes(of: upload.signedPrekey.id) { Data($0) }]
        + upload.oneTimePrekeys.flatMap { [$0.key, withUnsafeBytes(of: $0.id) { Data($0) }] }
}

func verifySignatures(_ upload: PrekeyUpload, of client: Client) throws {
    try Identity.verifyIdentityDHKey(
        identityKey: client.identityKey,
        identityDHKey: upload.identityDHKey,
        signature: upload.identityDHSignature
    )
    try Identity.verifySignedPrekey(
        identityKey: client.identityKey,
        signedPrekey: upload.signedPrekey.key,
        signature: upload.signedPrekey.signature
    )
}

func oneTimePrekeyIDs(_ upload: PrekeyUpload?) -> [UInt32] {
    upload!.oneTimePrekeys.map(\.id)
}

func heldOneTimePrekeyIDs(_ client: Client) throws -> [Int64] {
    try client.store.query("SELECT prekey_id FROM one_time_prekeys ORDER BY prekey_id").map { $0[0].integer! }
}

func seed(_ client: Client) throws -> Data {
    try client.store.identity()!.seed
}
