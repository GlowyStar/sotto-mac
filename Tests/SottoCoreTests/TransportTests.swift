import Foundation
@testable import SottoCore
import Testing

private let marker = "sotto marker 4f1c9e"

private func errorFrame(_ code: Sotto_ErrorCode, messageID: Data = Data(), identity: Data = Data()) -> Sotto_ServerFrame {
    var frame = Sotto_ServerFrame()
    frame.error.code = code
    frame.error.messageID = messageID
    frame.error.identity = identity
    return frame
}

@Suite(.timeLimit(.minutes(1)))
struct TransportTests {
    let folder = Folder()
    let relay = ScriptedRelay()

    func key(_ name: String) throws -> Data {
        try folder.identityKey(name)
    }

    @Test func twoClientsExchangeTextsInBothDirections() async throws {
        try befriend(folder, "alice", "bob")
        let bob = try await run(folder.open("bob"), relay)
        let alice = try await run(folder.open("alice"), relay)
        try await until { try await isRegistered(bob.transport) }

        try await alice.transport.sendText(key("bob"), "hello bob")
        #expect(try await nextText(bob.transport) == (key("alice"), "hello bob"))
        try await bob.transport.sendText(key("alice"), "hello alice")
        #expect(try await nextText(alice.transport) == (key("bob"), "hello alice"))

        try await until { try await outbox(alice.transport).isEmpty }
        try await until { try await outbox(bob.transport).isEmpty }
        await alice.stop()
        await bob.stop()
    }

    @Test func offlinePeerReceivesAfterItStarts() async throws {
        try befriend(folder, "alice", "bob")
        var bob = try await run(folder.open("bob"), relay)
        try await until { [bob] in try await isRegistered(bob.transport) }
        await bob.stop()

        let alice = try await run(folder.open("alice"), relay)
        try await alice.transport.sendText(key("bob"), "while you were away")
        try await until { try await outbox(alice.transport).isEmpty }
        await alice.stop()

        bob = try await run(folder.open("bob"), relay)
        #expect(try await nextText(bob.transport) == (key("alice"), "while you were away"))
        await bob.stop()
    }

    @Test func relayRestartedInTheMiddleOfAConversationLosesNothing() async throws {
        try befriend(folder, "alice", "bob")
        let bob = try await run(folder.open("bob"), relay)
        let alice = try await run(folder.open("alice"), relay)
        try await until { try await isRegistered(bob.transport) }
        try await alice.transport.sendText(key("bob"), "before")
        #expect(try await nextText(bob.transport) == (key("alice"), "before"))

        await relay.shutDown()
        try await nextEvent(alice.transport) { if case .retrying = $0 { true } else { false } }
        try await alice.transport.sendText(key("bob"), "during")
        #expect(try await outbox(alice.transport).count == 1)

        await relay.start()
        #expect(try await nextText(bob.transport) == (key("alice"), "during"))
        try await nextEvent(alice.transport) { $0 == .connected }
        try await bob.transport.sendText(key("alice"), "after")
        #expect(try await nextText(alice.transport) == (key("bob"), "after"))
        try await until { try await outbox(alice.transport).isEmpty }
        try await until { try await outbox(bob.transport).isEmpty }
        await alice.stop()
        await bob.stop()
    }

    @Test func clientKilledBetweenCommitAndStoredDeliversOneText() async throws {
        try befriend(folder, "alice", "bob")
        let alice = try key("alice")
        let bob = try await run(folder.open("bob"), relay)
        try await until { try await isRegistered(bob.transport) }
        let cut = Flag()
        await relay.edit(toClient: { link, message in
            if link.identity == alice, serverKind(message) == "stored", cut.setOnce() {
                throw Cut()
            }
            return [.message(message)]
        })

        var link = try await run(folder.open("alice"), relay)
        try await link.transport.sendText(key("bob"), "once")
        try await until { cut.isSet }
        await link.stop()

        link = try await run(folder.open("alice"), relay)
        try await until { [link] in try await outbox(link.transport).isEmpty }
        #expect(try await nextText(bob.transport) == (alice, "once"))
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(try await textsReceived(bob.transport) == ["once"])
        await link.stop()
        await bob.stop()
    }

    @Test func connectionCutBetweenDeliverAndAckGivesOneText() async throws {
        try befriend(folder, "alice", "bob")
        let bobKey = try key("bob")
        let cut = Flag()
        await relay.edit(toRelay: { link, message in
            if link.identity == bobKey, case .binary(let data) = message,
               case .ack = try Sotto_ClientFrame(serializedBytes: data).frame, cut.setOnce() {
                throw Cut()
            }
            return message
        })
        let bob = try await run(folder.open("bob"), relay)
        try await until { try await isRegistered(bob.transport) }
        let alice = try await run(folder.open("alice"), relay)
        try await alice.transport.sendText(bobKey, "only once")
        await alice.stop()

        #expect(try await nextText(bob.transport) == (key("alice"), "only once"))
        let copy = try await nextIncoming(bob.transport)
        try await until { await relay.queues[bobKey, default: []].isEmpty }

        #expect(copy.received.result == "DUPLICATE")
        #expect(try await textsReceived(bob.transport) == ["only once"])
        await bob.stop()
    }

    @Test func deliverIsAckedOnlyAfterItIsSaved() async throws {
        try befriend(folder, "alice", "bob")
        let bobKey = try key("bob")
        let bobFolder = folder.url.appendingPathComponent("bob")
        let seenAtAck = Box<[String]>([])
        await relay.edit(toRelay: { link, message in
            if link.identity == bobKey, case .binary(let data) = message,
               case .ack = try Sotto_ClientFrame(serializedBytes: data).frame {
                let rows = try ClientStore(directory: bobFolder).query("SELECT text FROM messages WHERE direction = 'in'")
                seenAtAck.value = rows.map { $0[0].text! }
            }
            return message
        })
        let bob = try await run(folder.open("bob"), relay)
        try await until { try await isRegistered(bob.transport) }
        let alice = try await run(folder.open("alice"), relay)
        try await alice.transport.sendText(bobKey, "saved first")
        _ = try await nextText(bob.transport)
        try await until { await relay.queues[bobKey, default: []].isEmpty }

        #expect(seenAtAck.value == ["saved first"])
        await alice.stop()
        await bob.stop()
    }

    @Test func markerTextIsInNoFrameSentToTheRelay() async throws {
        try befriend(folder, "alice", "bob")
        let bob = try await run(folder.open("bob"), relay)
        try await until { try await isRegistered(bob.transport) }
        let alice = try await run(folder.open("alice"), relay)
        try await alice.transport.sendText(key("bob"), marker)
        #expect(try await nextText(bob.transport) == (key("alice"), marker))

        let forms = [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian].map { marker.data(using: $0)! }
        let frames = await relay.sentToRelay.map(\.frame)
        #expect(!frames.contains { frame in forms.contains { frame.range(of: $0) != nil } })
        await alice.stop()
        await bob.stop()
    }

    @Test(arguments: ["swapped sender", "flipped ciphertext byte"])
    func tamperedDeliverGivesNoTextAndNoNewHandshake(tampering: String) async throws {
        try befriend(folder, "alice", "bob")
        _ = try folder.open("carol")
        let (alice, bob, carol) = try (key("alice"), key("bob"), key("carol"))
        try folder.open("bob").addContact(folder.userID("carol"))
        let tamperingOn = Flag()
        await relay.edit(toClient: { link, message in
            guard tamperingOn.isSet, link.identity == bob, serverKind(message) == "deliver" else {
                return [.message(message)]
            }
            var frame = serverFrame(message)
            if tampering == "swapped sender" {
                frame.deliver.sender = carol
            } else {
                var envelope = try Sotto_PeerMessage(serializedBytes: frame.deliver.payload)
                envelope.ciphertext[envelope.ciphertext.count - 1] ^= 1
                frame.deliver.payload = try envelope.serializedBytes()
            }
            return [.message(binary(frame))]
        })

        let bobLink = try await run(folder.open("bob"), relay)
        try await until { try await isRegistered(bobLink.transport) }
        let aliceLink = try await run(folder.open("alice"), relay)
        try await aliceLink.transport.sendText(bob, "first")
        #expect(try await nextText(bobLink.transport) == (alice, "first"))
        try await bobLink.transport.sendText(alice, "reply")
        #expect(try await nextText(aliceLink.transport) == (bob, "reply"))
        // The delivery receipt of Alice for "reply" (section 39.5) reaches Bob before the
        // tampering starts, so that the tampered Deliver is the one of "tampered".
        _ = try await nextEvent(bobLink.transport) {
            if case .incoming(_, let received) = $0 { !received.marked.isEmpty } else { false }
        }
        let sessions = try await (sessionCount(aliceLink.transport, bob), sessionCount(bobLink.transport, alice))

        tamperingOn.set()
        try await aliceLink.transport.sendText(bob, "tampered")
        let tampered = try await nextIncoming(bobLink.transport)
        tamperingOn.clear()
        try await aliceLink.transport.sendText(bob, "untouched")
        #expect(try await nextText(bobLink.transport) == (alice, "untouched"))

        #expect(tampered.received.text == nil)
        #expect(tampered.received.result == (tampering == "swapped sender" ? "NO_SESSION" : "DECRYPT_FAILED"))
        #expect(try await textsReceived(bobLink.transport) == ["first", "untouched"])
        #expect(try await (sessionCount(aliceLink.transport, bob), sessionCount(bobLink.transport, alice)) == sessions)
        #expect(try await sessionCount(bobLink.transport, carol) == 0)
        #expect(await !relay.kinds(of: bob).contains("fetch_bundle"))
        await aliceLink.stop()
        await bobLink.stop()
    }

    @Test func substitutedBundleIsRefusedAndNothingIsSent() async throws {
        try befriend(folder, "alice", "bob")
        let (alice, bob) = try (key("alice"), key("bob"))
        let bobLink = try await run(folder.open("bob"), relay)
        try await until { try await isRegistered(bobLink.transport) }
        await bobLink.stop()
        await relay.edit(toClient: { _, message in
            guard serverKind(message) == "bundle" else {
                return [.message(message)]
            }
            var frame = serverFrame(message)
            frame.bundle.signedPrekey.key = try Identity.deriveX25519PublicKey(Client.systemRandomBytes(32))
            return [.message(binary(frame))]
        })

        let aliceLink = try await run(folder.open("alice"), relay)
        await #expect(throws: CryptoError.badBundle) { try await aliceLink.transport.sendText(bob, "never sent") }

        #expect(try await sessionCount(aliceLink.transport, bob) == 0)
        #expect(try await outbox(aliceLink.transport).isEmpty)
        #expect(await !relay.kinds(of: alice).contains("send"))
        await aliceLink.stop()
    }

    @Test(arguments: [
        (SocketMessage.binary(Data([0xFF, 0xFF])), 1008),
        (.binary(Data()), 1008),
        (.text("a text message"), 1003),
        (nil, 1009),
    ] as [(SocketMessage?, Int)])
    func brokenServerFrameClosesWithItsCodeAndTheClientReconnects(broken: SocketMessage?, closeCode: Int) async throws {
        await relay.edit(toClient: { link, message in
            guard link.number == 1 else {
                return [.message(message)]
            }
            return [broken.map { .message($0) } ?? .tooBig]
        })

        let alice = try await run(folder.open("alice"), relay)
        await alice.stop()

        #expect(await relay.clientCloseCodes[1] == closeCode)
        #expect(await relay.connections == 2)
    }

    @Test func unknownRelayVersionEndsWith1000AndStops() async throws {
        await relay.edit(toClient: { _, message in
            guard serverKind(message) == "hello" else {
                return [.message(message)]
            }
            var frame = serverFrame(message)
            frame.hello.version = 2
            return [.message(binary(frame))]
        })

        let transport = try makeTransport(folder.open("alice"), relay)
        try await within { try await transport.run() }

        var events: [TransportEvent] = []
        for await event in transport.events {
            events.append(event)
        }
        #expect(events == [.stopped(reason: "the relay speaks protocol version 2")])
        #expect(await relay.clientCloseCodes == [1: 1000])
        #expect(await relay.connections == 1)
    }

    @Test func replacedClientStops() async throws {
        let alice = try await run(folder.open("alice"), relay)
        await relay.replace(try key("alice"))
        _ = await alice.task.result

        #expect(try await nextEvent(alice.transport) { _ in true } == .stopped(reason: "the relay closed the connection with 4001"))
    }

    @Test(arguments: [
        (Sotto_ErrorCode.rateLimited, true),
        (.storageFull, true),
        (.queueFull, false),
    ])
    func refusedSendIsSentAgainAfterTheBackOff(code: Sotto_ErrorCode, holdsOthers: Bool) async throws {
        try befriend(folder, "alice", "bob")
        let (alice, bob) = try (key("alice"), key("bob"))
        let bobLink = try await run(folder.open("bob"), relay)
        let aliceLink = try await run(folder.open("alice"), relay, scale: 0.3)
        try await until { try await isRegistered(bobLink.transport) }
        try await until { try await isRegistered(aliceLink.transport) }
        try await aliceLink.transport.sendText(bob, "one")
        try await until { await relay.kinds(of: alice).contains("send") }
        // The delivery receipt of Bob goes first, so that the refusal is of a text of Alice.
        try await until { await relay.kinds(of: bob).contains("send") }

        await relay.refuseSends([code.rawValue])
        try await aliceLink.transport.sendText(bob, "two")
        try await Task.sleep(nanoseconds: 100_000_000)
        try await aliceLink.transport.sendText(bob, "three")

        #expect(try await nextText(bobLink.transport) == (alice, "one"))
        let later = try await [nextText(bobLink.transport).1, nextText(bobLink.transport).1]
        try await until { try await outbox(aliceLink.transport).isEmpty }
        let sends = await relay.sentToRelay.filter { $0.link.identity == alice }.compactMap { sent -> Data? in
            guard case .send(let send) = try? Sotto_ClientFrame(serializedBytes: sent.frame).frame else {
                return nil
            }
            return send.messageID
        }

        #expect(sends.count == 4)
        if holdsOthers {
            #expect(later == ["two", "three"])
            #expect(sends[1] == sends[2])
        } else {
            #expect(later == ["three", "two"])
            #expect(sends[1] == sends[3])
        }
        await aliceLink.stop()
        await bobLink.stop()
    }

    @Test func refusedSendIsDroppedAndReported() async throws {
        try befriend(folder, "alice", "bob")
        let bob = try key("bob")
        let bobLink = try await run(folder.open("bob"), relay)
        try await until { try await isRegistered(bobLink.transport) }
        await bobLink.stop()
        let alice = try await run(folder.open("alice"), relay)
        await relay.refuseSends([Sotto_ErrorCode.unknownRecipient.rawValue])

        try await alice.transport.sendText(bob, "nobody")

        #expect(try await nextEvent(alice.transport) { if case .refused = $0 { true } else { false } }
            == .refused(result: "UNKNOWN_RECIPIENT", contact: bob))
        #expect(try await outbox(alice.transport).isEmpty)
        await alice.stop()
    }

    @Test func fetchOfAnUnregisteredContactIsRefused() async throws {
        try befriend(folder, "alice", "carol")
        let alice = try await run(folder.open("alice"), relay)

        await #expect(throws: RefusedError(result: "NOT_FOUND")) {
            try await alice.transport.sendText(key("carol"), "nobody home")
        }
        #expect(try await outbox(alice.transport).isEmpty)
        await alice.stop()
    }

    @Test(arguments: ["LoggedIn first", "second Hello", "second LoggedIn", "Stored before the LoggedIn"])
    func frameOutOfItsStateClosesWith1008(state: String) async throws {
        var loggedIn = Sotto_ServerFrame()
        loggedIn.loggedIn = Sotto_LoggedIn()
        var stored = Sotto_ServerFrame()
        stored.stored.messageID = Data(count: 16)
        let (loggedInMessage, storedMessage) = (binary(loggedIn), binary(stored))
        await relay.edit(toClient: { link, message in
            guard link.number == 1 else {
                return [.message(message)]
            }
            switch (state, serverKind(message)) {
            case ("LoggedIn first", "hello"): return [.message(loggedInMessage)]
            case ("second Hello", "hello"), ("second LoggedIn", "logged_in"): return [.message(message), .message(message)]
            case ("Stored before the LoggedIn", "logged_in"): return [.message(storedMessage), .message(message)]
            default: return [.message(message)]
            }
        })

        let alice = try await run(folder.open("alice"), relay)
        try await until { await relay.connections == 2 }
        await alice.stop()

        #expect(await relay.clientCloseCodes[1] == 1008)
        #expect(await relay.connections == 2)
    }

    @Test func answerThatMatchesNoRequestIsIgnored() async throws {
        try befriend(folder, "alice", "bob")
        let (alice, bob) = try (key("alice"), key("bob"))
        var stray = Sotto_ServerFrame()
        stray.stored.messageID = Data(count: 16)
        let strays = [
            binary(stray),
            binary(errorFrame(.unknownRecipient, messageID: Data(count: 16))),
            binary(errorFrame(.notFound, identity: Data(count: 32))),
        ]
        await relay.edit(toClient: { link, message in
            guard link.identity == alice, serverKind(message) == "logged_in" else {
                return [.message(message)]
            }
            return [.message(message)] + strays.map { .message($0) }
        })
        let bobLink = try await run(folder.open("bob"), relay)
        try await until { try await isRegistered(bobLink.transport) }
        let aliceLink = try await run(folder.open("alice"), relay)

        try await aliceLink.transport.sendText(bob, "still here")
        #expect(try await nextText(bobLink.transport) == (alice, "still here"))
        try await until { try await outbox(aliceLink.transport).isEmpty }

        #expect(await relay.connections == 2)
        await aliceLink.stop()
        await bobLink.stop()
    }

    @Test func stepsAfterTheLoginUploadOnceThenSendTheOutbox() async throws {
        try befriend(folder, "alice", "bob")
        let (alice, bob) = try (key("alice"), key("bob"))
        let bobLink = try await run(folder.open("bob"), relay)
        try await until { try await isRegistered(bobLink.transport) }

        var aliceLink = try await run(folder.open("alice"), relay)
        try await aliceLink.transport.sendText(bob, "first")
        #expect(try await nextText(bobLink.transport) == (alice, "first"))
        try await bobLink.transport.sendText(alice, "reply")
        #expect(try await nextText(aliceLink.transport) == (bob, "reply"))
        await aliceLink.stop()

        let seenBefore = Int64(folder.clock.now)
        folder.clock.advance(Client.seenIDSeconds)
        _ = try folder.open("alice").sendText(bob, "second")
        aliceLink = try await run(folder.open("alice"), relay)
        try await until { [aliceLink] in try await outbox(aliceLink.transport).isEmpty }
        await aliceLink.stop()
        aliceLink = try await run(folder.open("alice"), relay)
        try await Task.sleep(nanoseconds: 200_000_000)
        await aliceLink.stop()

        // Bob holds connection 1; Alice's three runs are connections 2, 3 and 4.
        #expect(await relay.connections == 4)
        #expect(Array(await relay.kinds(2).prefix(4)) == ["login", "upload_bundle", "fetch_bundle", "send"])
        // The acks are of the delivery receipt of Bob, whenever it arrives, and a second send
        // may be the delivery receipt Alice owed Bob for "reply" (section 39.5).
        let third = await relay.kinds(3).filter { $0 != "ack" }
        #expect(Array(third.prefix(3)) == ["login", "upload_bundle", "send"])
        #expect(third.count <= 4 && third.dropFirst(2).allSatisfy { $0 == "send" })
        #expect(await relay.kinds(4).filter { $0 != "ack" } == ["login"])
        let uploads = await relay.sentToRelay.filter { $0.link.number > 1 }.compactMap { sent -> Sotto_UploadBundle? in
            guard case .uploadBundle(let upload) = try? Sotto_ClientFrame(serializedBytes: sent.frame).frame else {
                return nil
            }
            return upload
        }
        try #require(uploads.count == 2)
        #expect((uploads[0].oneTimePrekeys.count, uploads[1].oneTimePrekeys.count) == (100, 0))
        #expect(uploads[0].signedPrekey.id != uploads[1].signedPrekey.id)

        let store = try ClientStore(directory: folder.url.appendingPathComponent("alice"))
        #expect(try store.query("SELECT count(*) FROM seen_ids WHERE seen_at <= ?", [.integer(seenBefore)])[0][0].integer == 0)
        let identity = try #require(try store.identity())
        var privateKeys = [identity.seed, identity.identityDHPrivateKey]
        for table in ["signed_prekeys", "one_time_prekeys"] {
            privateKeys += try store.query("SELECT private_key FROM \(table)").map { $0[0].data! }
        }
        let frames = await relay.sentToRelay.map(\.frame)
        #expect(!privateKeys.contains { key in frames.contains { $0.range(of: key) != nil } })
    }

    @Test(arguments: ["no answer", "Back off"])
    func uploadOpenWhenTheConnectionEndsIsNotSentAgain(ending: String) async throws {
        let refusal = binary(errorFrame(.rateLimited))
        await relay.edit(toClient: { link, message in
            guard link.number == 1, serverKind(message) == "bundle_stored" else {
                return [.message(message)]
            }
            if ending == "no answer" {
                throw Cut()
            }
            return [.message(refusal)]
        })

        let alice = Running(try makeTransport(folder.open("alice"), relay, scale: 0.5))
        if ending == "Back off" {
            try await until { await relay.uploads().count == 1 }
            try await Task.sleep(nanoseconds: 100_000_000)
            await relay.close(1, code: 1011)
        }
        try await until { try await isRegistered(alice.transport) }
        let kept = try await alice.transport.withClient { try $0.store.oneTimePrekeyCount() }
        await alice.stop()

        let uploads = await relay.uploads()
        try #require(uploads.count == 2)
        #expect(await relay.kinds(1) == ["login", "upload_bundle"])
        #expect((uploads[0].oneTimePrekeys.count, uploads[1].oneTimePrekeys.count) == (100, 0))
        #expect(uploads[0].signedPrekey.id == uploads[1].signedPrekey.id)
        #expect(uploads[0].signedPrekey.key == uploads[1].signedPrekey.key)
        #expect(kept == (ending == "no answer" ? 100 : 0))
    }

    @Test func expiredSignedPrekeyIsDeletedAtStartBeforeAnyDial() async throws {
        let client = try folder.open("alice")
        _ = try client.makePrekeys(oneTimeCount: 0)
        folder.clock.advance(1)
        _ = try client.makePrekeys(oneTimeCount: 0)
        folder.clock.advance(Client.signedPrekeyGraceSeconds + 1)
        #expect(try client.store.query("SELECT count(*) FROM signed_prekeys")[0][0].integer == 2)

        let alice = Running(try makeTransport(client, NoRelay()))
        try await until {
            try await alice.transport.withClient { try $0.store.query("SELECT count(*) FROM signed_prekeys")[0][0].integer == 1 }
        }
        await alice.stop()

        var events: [TransportEvent] = []
        for await event in alice.transport.events {
            events.append(event)
        }
        #expect(!events.contains(.connected))
    }
}

/// A flag that edits of the scripted relay can read from its actor.
final class Flag: Sendable {
    private let box = Box(false)

    var isSet: Bool {
        box.value
    }

    func set() {
        box.value = true
    }

    func clear() {
        box.value = false
    }

    /// Sets the flag; true only for the call that set it.
    func setOnce() -> Bool {
        box.swap(true) == false
    }
}

final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func swap(_ new: Value) -> Value {
        lock.withLock {
            let old = stored
            stored = new
            return old
        }
    }
}
