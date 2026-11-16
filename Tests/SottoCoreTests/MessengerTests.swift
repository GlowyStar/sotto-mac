import Foundation
@testable import SottoCore
import Testing

/// A loopback port where nothing listens.
let deadRelay = "ws://127.0.0.1:9/ws"

@Test func storeReadsRenamesAndDeletesLoggedMessages() throws {
    let folder = Folder()
    let store = try ClientStore(directory: folder.url.appendingPathComponent("alice"))
    let bob = Data(repeating: 1, count: 32)
    let carol = Data(repeating: 2, count: 32)
    try store.transaction {
        try store.addContact(bob, name: "bob")
        try store.addContact(carol, name: "carol")
        try store.logMessage(bob, direction: .outgoing, messageID: Data([1]), text: "one")
        try store.logMessage(carol, direction: .incoming, messageID: Data([2]), text: "other")
        try store.logMessage(bob, direction: .incoming, messageID: Data([3]), text: "two")
    }
    let logged = try store.messages(bob)
    #expect(logged.map(\.text) == ["one", "two"])
    #expect(logged.map(\.direction) == [.outgoing, .incoming])
    #expect(logged.map(\.messageID) == [Data([1]), Data([3])])
    #expect(logged[0].position < logged[1].position)

    try store.transaction {
        try store.deleteMessage(logged[0].position)
        try store.renameContact(bob, name: "robert")
    }
    #expect(try store.messages(bob).map(\.text) == ["two"])
    #expect(try store.contacts().map(\.name) == ["carol", "robert"])

    try store.transaction { try store.deleteMessages(bob) }
    #expect(try store.messages(bob).isEmpty)
    #expect(try store.messages(carol).map(\.text) == ["other"])
}

@Test func aWriteWaitsForAReaderOfTheSameFile() async throws {
    let folder = Folder()
    let directory = folder.url.appendingPathComponent("alice")
    let reader = try ClientStore(directory: directory)
    try reader.query("BEGIN")
    try reader.query("SELECT count(*) FROM contacts")
    let written = Task.detached {
        let writer = try ClientStore(directory: directory)
        try writer.transaction { try writer.addContact(Data(repeating: 1, count: 32), name: "bob") }
        return try writer.contacts().count
    }
    try await Task.sleep(nanoseconds: 200_000_000)
    try reader.query("COMMIT")
    #expect(try await written.value == 1)
}

@Test func newContactsAndRelayAddressesAreChecked() async throws {
    let folder = Folder()
    let messenger = try Messenger(directory: folder.url.appendingPathComponent("app"), relay: deadRelay)
    #expect(!messenger.hadIdentity)
    await messenger.start()
    #expect(try await messenger.state().userID == nil)
    let own = try await messenger.createIdentity()
    let bob = String(repeating: "ab", count: 32)

    let cases: [(String, String, ContactError)] = [
        ("bob", "abc", .wrongLength),
        ("bob", String(repeating: "g", count: 64), .notHex),
        ("bob", own, .ownID),
        ("  ", bob, .emptyName),
    ]
    for (name, id, problem) in cases {
        await #expect(throws: problem) { try await messenger.addContact(name: name, userID: id) }
    }
    try await messenger.addContact(name: " bob ", userID: " " + bob.uppercased())
    await #expect(throws: ContactError.alreadySaved("bob")) {
        try await messenger.addContact(name: "robert", userID: bob)
    }
    await #expect(throws: ContactError.nameTaken("bob")) {
        try await messenger.addContact(name: "bob", userID: String(repeating: "cd", count: 32))
    }
    let chats = try await messenger.state().chats
    #expect(chats.map(\.userID) == [bob])
    #expect(chats.map(\.name) == ["bob"])
    #expect(chats.map(\.unread) == [0])

    await #expect(throws: URLRefusedError.self) { try await messenger.setRelay("ws://relay.example.org/ws") }
    #expect(await messenger.relay == deadRelay)
    await messenger.close()
}

@Suite(
    .serialized,
    .timeLimit(.minutes(1)),
    .enabled(if: RealRelay.isAvailable, "the Python project with its .venv is not at ../../python/sotto")
)
struct MessengerRelayTests {
    let folder = Folder()

    var appDirectory: URL {
        folder.url.appendingPathComponent("app")
    }

    func chat(_ messenger: Messenger) async throws -> Chat? {
        try await messenger.state().chats.first
    }

    func waitFor(_ messenger: Messenger, _ holds: @escaping @Sendable (MessengerState) -> Bool) async throws {
        try await until { holds(try await messenger.state()) }
    }

    @Test func textsBothWaysUnreadOfflineSendRestartResetAndDelete() async throws {
        let relay = try await RealRelay()
        defer { relay.stop() }
        var messenger = try Messenger(directory: appDirectory, relay: relay.url)
        await messenger.start()
        let appID = try await messenger.createIdentity()
        let appKey = try Identity.decodeUserID(appID)
        try folder.open("peer").addContact(appID)
        let peerID = try folder.userID("peer")
        try await messenger.addContact(name: "peer", userID: peerID)
        try await waitFor(messenger) { $0.link == .connected }
        let peer = try await run(folder.open("peer"), URLSessionDialer(), url: relay.url)
        try await until { try await isRegistered(peer.transport) }

        try await messenger.send("hello peer", to: peerID)
        #expect(try await nextText(peer.transport) == (appKey, "hello peer"))
        try await waitFor(messenger) { $0.chats.first?.messages.last?.waiting == false }

        try await peer.transport.sendText(appKey, "hello app")
        try await waitFor(messenger) { $0.chats.first?.unread == 1 }
        let received = try #require(try await chat(messenger))
        #expect(received.messages.map(\.text) == ["hello peer", "hello app"])
        #expect(received.messages.map(\.outgoing) == [true, false])
        #expect(received.messages[0].date <= received.messages[1].date)
        try await messenger.markRead(peerID)
        #expect(try await chat(messenger)?.unread == 0)

        try await messenger.setRelay(deadRelay)
        try await messenger.send("sent while away", to: peerID)
        #expect(try await chat(messenger)?.messages.last?.waiting == true)
        try await messenger.setRelay(relay.url)
        #expect(try await nextText(peer.transport) == (appKey, "sent while away"))
        try await waitFor(messenger) { $0.chats.first?.messages.last?.waiting == false }

        try await peer.transport.sendText(appKey, "before the restart")
        try await waitFor(messenger) { $0.chats.first?.unread == 1 }
        let before = try await messenger.state()
        await messenger.close()
        messenger = try Messenger(directory: appDirectory, relay: deadRelay)
        #expect(messenger.hadIdentity)
        #expect(await messenger.relay == relay.url)
        #expect(try await messenger.state().chats == before.chats)
        await messenger.start()
        try await waitFor(messenger) { $0.link == .connected }

        try await messenger.resetSession(peerID)
        try await messenger.send("after the reset", to: peerID)
        #expect(try await nextText(peer.transport) == (appKey, "after the reset"))

        try await messenger.deleteContact(peerID)
        #expect(try await messenger.state().chats.isEmpty)
        try await peer.transport.sendText(appKey, "after the delete")
        try await until { try await outbox(peer.transport).isEmpty }
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(try await messenger.state().chats.isEmpty)
        await messenger.close()
        await peer.stop()
    }

    @Test func aTextWithoutASessionWaitsOfflineAcrossARestartAndLeavesOnceConnected() async throws {
        let relay = try await RealRelay()
        defer { relay.stop() }
        var messenger = try Messenger(directory: appDirectory, relay: deadRelay)
        await messenger.start()
        let appID = try await messenger.createIdentity()
        let appKey = try Identity.decodeUserID(appID)
        try folder.open("peer").addContact(appID)
        let peerID = try folder.userID("peer")
        try await messenger.addContact(name: "peer", userID: peerID)
        let peer = try await run(folder.open("peer"), URLSessionDialer(), url: relay.url)
        try await until { try await isRegistered(peer.transport) }

        try await messenger.send("typed while offline", to: peerID)
        let typed = try #require(try await chat(messenger)?.messages.last)
        #expect(typed.text == "typed while offline")
        #expect(typed.outgoing && typed.waiting && typed.failure == nil)
        #expect(typed.id < 0)

        await messenger.close()
        #expect(try Messenger.peek(directory: appDirectory, relay: deadRelay).chats.first?.messages == [typed])
        messenger = try Messenger(directory: appDirectory, relay: deadRelay)
        await messenger.start()
        #expect(try await chat(messenger)?.messages == [typed])

        try await messenger.setRelay(relay.url)
        #expect(try await nextText(peer.transport) == (appKey, "typed while offline"))
        try await waitFor(messenger) { $0.chats.first?.messages.last?.waiting == false }
        let sent = try #require(try await chat(messenger)?.messages)
        #expect(sent.count == 1)
        #expect(sent[0].id > 0 && sent[0].text == typed.text && sent[0].date == typed.date)
        #expect(sent[0].failure == nil)
        await messenger.close()
        await peer.stop()
    }

    @Test func refusedTextsEndAsNotSentWithTheReasonAcrossARestart() async throws {
        let relay = try await RealRelay()
        defer { relay.stop() }
        let other = try await RealRelay()
        defer { other.stop() }
        let messenger = try Messenger(directory: appDirectory, relay: relay.url)
        await messenger.start()
        let appID = try await messenger.createIdentity()
        try folder.open("peer").addContact(appID)
        _ = try folder.open("ghost")
        let peerID = try folder.userID("peer")
        let ghostID = try folder.userID("ghost")
        try await messenger.addContact(name: "peer", userID: peerID)
        try await messenger.addContact(name: "ghost", userID: ghostID)
        let peer = try await run(folder.open("peer"), URLSessionDialer(), url: relay.url)
        try await until { try await isRegistered(peer.transport) }
        try await waitFor(messenger) { $0.link == .connected }

        @Sendable func last(_ userID: String) async throws -> ChatMessage? {
            try await messenger.state().chats.first { $0.userID == userID }?.messages.last
        }

        try await messenger.send("to nobody", to: ghostID)
        try await until { try await last(ghostID)?.failure != nil }
        #expect(try await last(ghostID)?.failure == "The relay refused it (NOT_FOUND).")
        #expect(try await last(ghostID)?.waiting == false)

        try await messenger.send("over the first relay", to: peerID)
        try await waitFor(messenger) { $0.chats.first { $0.userID == peerID }?.messages.last?.waiting == false }
        try await messenger.setRelay(other.url)
        try await waitFor(messenger) { $0.link == .connected }
        try await messenger.send("over a relay that does not know peer", to: peerID)
        try await until { try await last(peerID)?.failure != nil }
        let refused = try #require(try await last(peerID))
        #expect(refused.failure == "The relay refused it (UNKNOWN_RECIPIENT).")
        #expect(refused.id > 0 && !refused.waiting)

        let before = try await messenger.state().chats
        await messenger.close()
        let reopened = try Messenger(directory: appDirectory, relay: deadRelay)
        #expect(try await reopened.state().chats == before)
        await reopened.close()
        await peer.stop()
    }

    @Test func aLoginOfTheSameIdentityElsewhereStopsWithAnExplanation() async throws {
        let relay = try await RealRelay()
        defer { relay.stop() }
        let messenger = try Messenger(directory: appDirectory, relay: relay.url)
        await messenger.start()
        _ = try await messenger.createIdentity()
        try await waitFor(messenger) { $0.link == .connected }
        try FileManager.default.copyItem(at: appDirectory, to: folder.url.appendingPathComponent("again"))

        let second = try await run(folder.open("again"), URLSessionDialer(), url: relay.url)
        try await waitFor(messenger) {
            $0.link == .stopped("This id is in use on another device: the relay closed this connection.")
        }
        await second.stop()
        await messenger.close()
    }
}
