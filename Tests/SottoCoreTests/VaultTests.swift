import Foundation
@testable import SottoCore
import Testing

private let phrase = "the owner's own phrase"

/// Alice's data folder with a chat with Bob over the relay of the harness: a text each way,
/// Bob's session started from Alice's bundle, and a file of Bob that Alice's store keeps.
private struct AliceAndBob {
    let relay: Relay
    let alice: Client
    let bob: Client
    let texts: [String]
    let file: Data

    var directory: URL { alice.store.directory }
    var bobID: String { (try? Identity.encodeUserID(bob.identityKey)) ?? "" }

    init(_ clients: Clients) throws {
        relay = Relay()
        alice = try clients.open("alice")
        try relay.publish(alice)
        bob = try clients.open("bob")
        try relay.publish(bob)
        try befriend(alice, bob)
        texts = ["first words of bob", "an answer of alice", "a caption of bob"]
        try send(relay, bob, alice, texts[0])
        try relay.deliver(alice)
        try send(relay, alice, bob, texts[1])
        try relay.deliver(bob)
        file = Data("the bytes of a file that bob sent".utf8)
        let upload = try bob.startUpload(alice.identityKey, file: file, blobMaxBytes: 1 << 20, fileName: "notes.txt", caption: texts[2])
        let blob = try bob.readUpload(upload.blobID, offset: 0, length: upload.length)
        relay.send(bob, try bob.sendAttachment(upload))
        try relay.deliver(alice)
        guard let offered = try alice.downloads().first else { throw Timeout() }
        try alice.beginDownload(offered.position)
        try alice.saveDownloadPiece(offered.position, blob)
        try alice.finishDownload(offered.position, folder: nil)
    }
}

/// The values of every table of the store that hold one of the secrets, as "table: value";
/// a table added later is read the same way.
private func holding(_ store: ClientStore, _ secrets: [Data]) throws -> [String] {
    var found: [String] = []
    for table in try store.query("SELECT name FROM sqlite_schema WHERE type = 'table'") {
        let name = table[0].text!
        for row in try store.query("SELECT * FROM \"\(name)\"") {
            for value in row {
                let bytes: Data? = switch value {
                case .blob(let data): data
                case .text(let text): Data(text.utf8)
                default: nil
                }
                if let bytes, secrets.contains(where: { bytes.range(of: $0) != nil }) {
                    found.append("\(name): \(value)")
                }
            }
        }
    }
    return found
}

@Test func onlyItsPhraseOpensTheVaultAndTheDecoyFailsAsAWrongPhraseDoes() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-vault-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    try ClientStore(directory: folder).close()
    let file = Vault.path(folder)
    let decoy = try Data(contentsOf: file)
    #expect(!decoy.starts(with: ClientStore.plainHeader), "the decoy is random from its first byte")

    func refusal(_ phrase: String) -> (StoreError?, TimeInterval) {
        let start = Date()
        do {
            try Vault.open(folder, phrase: phrase).close()
            return (nil, Date().timeIntervalSince(start))
        } catch {
            return (error as? StoreError, Date().timeIntervalSince(start))
        }
    }
    let onTheDecoy = refusal(phrase)
    _ = try Vault.make(folder, phrase: phrase)
    let made = try Data(contentsOf: file)
    #expect(made.count == decoy.count, "an empty vault has the size of the decoy")
    #expect(!made.starts(with: ClientStore.plainHeader) && made.prefix(16) != decoy.prefix(16))

    let wrong = refusal(phrase + " and more")
    #expect(onTheDecoy.0 == .wrongKey && wrong.0 == .wrongKey)
    #expect(onTheDecoy.1 > 0.1 && wrong.1 > 0.1, "the key derivation runs in both cases")
    #expect(refusal(phrase).0 == nil)
    #expect(refusal("  \(phrase)\n").0 == nil, "the spaces around the phrase do not count")
    #expect(refusal("seven c").0 == .wrongKey)
}

@Test func aHiddenChatLeavesNoTraceInTheMainStoreAndComesBackWhole() async throws {
    let clients = Clients()
    defer { clients.close() }
    let chat = try AliceAndBob(clients)
    let messenger = try Messenger(directory: chat.directory, relay: deadRelay)
    await messenger.start()
    try await messenger.setDraft("a draft for bob", for: chat.bobID)
    try await messenger.markRead(chat.bobID)
    try await messenger.setPinned(chat.bobID, true)
    let before = try #require(try await messenger.state().chats.first)
    #expect(before.messages.map(\.text) == chat.texts && before.draft != nil && before.unread == 0 && before.pinned == 0)

    let main = try ClientStore(directory: chat.directory)
    defer { main.close() }
    let secrets = storedForms(chat.bob.identityKey) + chat.texts.map { Data($0.utf8) } + [chat.file, Data("a draft for bob".utf8)]
    #expect(try holding(main, secrets).count > 10, "the scan finds the chat while it is there")

    #expect(try await messenger.hideChat(chat.bobID, phrase: phrase) == false, "no vault opens with the phrase yet")
    #expect(try await messenger.state().chats.count == 1)
    #expect(try await messenger.hideChat(chat.bobID, phrase: phrase, makeNew: true))
    #expect(try await messenger.state().chats.isEmpty)
    #expect(try holding(main, secrets) == [])

    #expect(try await messenger.openVault(phrase))
    var shown = before
    shown.hidden = true
    #expect(try await messenger.state().chats == [shown])
    try await messenger.unhideChat(chat.bobID)
    let back = try #require(try await messenger.state().chats.first)
    #expect(back == before)
    #expect(try await messenger.contents(try #require(back.messages.last).id) == chat.file)
    let vault = try Vault.open(chat.directory, phrase: phrase)
    defer { vault.close() }
    #expect(try holding(vault, secrets) == [], "nothing of the chat stays in the vault")
    await messenger.close()
}

@Test func aHideStoppedBetweenTheVaultCommitAndTheMainDeleteEndsWholeAtTheNextOpen() async throws {
    let clients = Clients()
    defer { clients.close() }
    let chat = try AliceAndBob(clients)
    let main = chat.alice.store
    try main.transaction { try main.setInboxPublicKey(try Vault.make(chat.directory, phrase: phrase)) }
    let vault = try Vault.open(chat.directory, phrase: phrase)
    try vault.transaction {
        try Vault.copyRows(of: chat.bob.identityKey, from: main, to: vault)
        try vault.setVaultMove(chat.bob.identityKey, hiding: true)
    }
    vault.close()
    // The stop came before the delete; the main store goes on and takes a message of Bob.
    try send(chat.relay, chat.bob, chat.alice, "after the stop")
    try chat.relay.deliver(chat.alice)
    let sessions = try main.sessions(chat.bob.identityKey).count

    let messenger = try Messenger(directory: chat.directory, relay: deadRelay)
    await messenger.start()
    #expect(try await messenger.state().chats.map(\.hidden) == [false], "the main store shows the chat until the vault opens")
    #expect(try await messenger.openVault(phrase))
    let hidden = try #require(try await messenger.state().chats.first)
    #expect(hidden.hidden)
    #expect(hidden.messages.map(\.text) == chat.texts + ["after the stop"])
    #expect(try !main.isContact(chat.bob.identityKey) && main.messages(chat.bob.identityKey).isEmpty)
    let reopened = try Vault.open(chat.directory, phrase: phrase)
    defer { reopened.close() }
    #expect(try reopened.sessions(chat.bob.identityKey).count == sessions)
    #expect(try reopened.vaultMoves().isEmpty)
    await messenger.close()
}

@Test func aOneTimePrekeyThatTheVaultUsedIsGoneFromTheMainStore() throws {
    try withPair { clients, relay, alice, bob in
        try relay.publish(alice, oneTimeCount: 2, pqOneTimeCount: 2)
        _ = try Vault.make(alice.store.directory, phrase: phrase)
        let vault = try Vault.open(alice.store.directory, phrase: phrase)
        defer { vault.close() }
        vault.counter = alice.store
        try Vault.hide(bob.identityKey, main: alice.store, vault: vault, notes: (Data("{}".utf8), Data("{}".utf8)))
        try Vault.syncPrekeys(main: alice.store, vault: vault)
        let hidden = try alice.sibling(over: vault)

        let delivered = try send(relay, bob, alice, "a new session through the vault")
        let header = try #require(try initialHeader(of: delivered))
        #expect(try alice.store.oneTimePrekey(header.oneTimePrekeyID) != nil)
        #expect(try heldPQOneTimePrekeyIDs(alice).contains(Int64(header.pqPrekeyID)))
        #expect(try alice.receive(delivered).result == "NOT_A_CONTACT", "the main store has no Bob")
        #expect(try hidden.receive(delivered).text == "a new session through the vault")
        try Vault.syncPrekeys(main: alice.store, vault: vault)
        #expect(try alice.store.oneTimePrekey(header.oneTimePrekeyID) == nil)
        #expect(try !heldPQOneTimePrekeyIDs(alice).contains(Int64(header.pqPrekeyID)))
        #expect(try vault.oneTimePrekey(header.oneTimePrekeyID) == nil)

        // Keys the main store makes later reach the vault and stay in the main store.
        try relay.publish(alice, oneTimeCount: 1, pqOneTimeCount: 1)
        let made = try heldOneTimePrekeyIDs(alice)
        try Vault.syncPrekeys(main: alice.store, vault: vault)
        #expect(try heldOneTimePrekeyIDs(alice) == made)
        #expect(try vault.query("SELECT prekey_id FROM one_time_prekeys ORDER BY prekey_id").map { $0[0].integer! } == made)
    }
}

@Test func positionsOfTheVaultComeFromTheMainCounterAndAreNeverGivenTwice() throws {
    try withPair { _, _, alice, bob in
        _ = try Vault.make(alice.store.directory, phrase: phrase)
        let vault = try Vault.open(alice.store.directory, phrase: phrase)
        defer { vault.close() }
        vault.counter = alice.store
        try Vault.hide(bob.identityKey, main: alice.store, vault: vault, notes: (Data("{}".utf8), Data("{}".utf8)))
        var given: [Int64] = []
        for index in 0..<3 {
            given.append(try vault.transaction { try vault.logMessage(bob.identityKey, direction: .incoming, messageID: Data([UInt8(index)]), text: "") })
            given.append(try alice.store.transaction {
                try alice.store.logMessage(Data(repeating: 9, count: 32), direction: .incoming, messageID: Data([UInt8(index)]), text: "")
            })
        }
        #expect(Set(given).count == given.count && given == given.sorted())
    }
}

@Test func aLockClosesTheVault() async throws {
    let clients = Clients()
    defer { clients.close() }
    let chat = try AliceAndBob(clients)
    var messenger = try Messenger(directory: chat.directory, relay: deadRelay)
    await messenger.start()
    #expect(try await messenger.hideChat(chat.bobID, phrase: phrase, makeNew: true))
    #expect(try await messenger.openVault(phrase))
    #expect(try await messenger.state().chats.map(\.hidden) == [true])

    // Every lock of the app closes the messenger, and with it the vault.
    await messenger.close()
    messenger = try Messenger(directory: chat.directory, relay: deadRelay)
    await messenger.start()
    #expect(try await messenger.state().chats.isEmpty)
    #expect(try await messenger.openVault(phrase))
    #expect(try await messenger.state().chats.map(\.hidden) == [true])
    await messenger.close()
}

@Test func aHiddenChatNotifiesWithoutItsNameOrTextOrId() {
    let message = ChatMessage(id: 7, outgoing: false, text: "a hidden text", date: Date(), waiting: false)
    let chat = { (messages: [ChatMessage]) in
        var chat = Chat(userID: "id of the chat", name: "a hidden name", added: Date(), unread: messages.count, messages: messages)
        chat.hidden = true
        return chat
    }
    let old = MessengerState(chats: [chat([])], link: .connected, relay: "")
    let new = MessengerState(chats: [chat([message])], link: .connected, relay: "")
    var settings = AppSettings()
    settings.notificationSender = true
    settings.notificationPreview = true
    let alerts = Alerts.make(old: old, new: new, settings: settings, quietChat: nil, locked: false)
    #expect(alerts.map(\.title) == [Alerts.hiddenTitle] && alerts.map(\.body) == [Alerts.hiddenBody])
    #expect(alerts.map(\.identifier) == ["\(Alerts.hiddenThread)-7"] && alerts.map(\.thread) == [Alerts.hiddenThread])
    #expect(Alerts.changed(old: new, new: MessengerState(chats: [], link: .connected, relay: "")) == ["\(Alerts.hiddenThread)-7"])
}

@Suite(
    .serialized,
    .timeLimit(.minutes(1)),
    .enabled(if: RealRelay.isAvailable, "the Python project with its .venv is not at ../../python/sotto or SOTTO_PYTHON_PROJECT")
)
struct HiddenChatRelayTests {
    let folder = Folder()

    var appDirectory: URL {
        folder.url.appendingPathComponent("app")
    }

    /// The envelopes of the sealed inbox of the app, read with a connection of their own.
    func sealed() throws -> [(position: Int64, sealed: Data)] {
        let store = try ClientStore(directory: appDirectory)
        defer { store.close() }
        return try store.sealedInbox()
    }

    /// The app and a peer with a session between them, and the peer's id.
    func pair(_ relay: RealRelay) async throws -> (Messenger, Running, String, Data) {
        let messenger = try Messenger(directory: appDirectory, relay: relay.url)
        await messenger.start()
        let appID = try await messenger.createIdentity()
        let appKey = try Identity.decodeUserID(appID)
        try folder.open("peer").addContact(appID)
        let peerID = try folder.userID("peer")
        try await messenger.addContact(name: "peer", userID: peerID)
        try await until { try await messenger.state().link == .connected }
        let peer = try await run(folder.open("peer"), URLSessionDialer(), url: relay.url)
        try await until { try await isRegistered(peer.transport) }
        try await messenger.send("hello peer", to: peerID)
        #expect(try await nextText(peer.transport) == (appKey, "hello peer"))
        return (messenger, peer, peerID, appKey)
    }

    @Test func aMessageWhileTheVaultIsClosedWaitsSealedAndReachesTheChatWithItsReceiptWhenItOpens() async throws {
        let relay = try await RealRelay()
        defer { relay.stop() }
        let (messenger, peer, peerID, appKey) = try await pair(relay)
        #expect(try await messenger.hideChat(peerID, phrase: phrase, makeNew: true))

        let text = "written while the chat is hidden"
        try await peer.transport.sendText(appKey, text)
        try await until { try await outbox(peer.transport).isEmpty }
        let main = try ClientStore(directory: appDirectory)
        defer { main.close() }
        let key = try Vault.open(appDirectory, phrase: phrase).inboxKey()?.privateKey
        let peerKey = try folder.identityKey("peer")
        try await until { [self] in try sealed().contains { Vault.open($0.sealed, privateKey: key ?? Data())?.sender == peerKey } }
        #expect(try holding(main, storedForms(peerKey) + [Data(text.utf8)]) == [])
        #expect(try await messenger.state().chats.isEmpty)
        @Sendable func receipt() async throws -> ReceiptKind? {
            try await peer.transport.withClient { try $0.store.messages(appKey).last { !$0.incoming }?.receipt }
        }
        #expect(try await receipt() == nil)

        #expect(try await messenger.openVault(phrase))
        try await until { try await messenger.state().chats.first?.messages.last?.text == text }
        #expect(try await messenger.state().chats.first?.hidden == true)
        #expect(try main.sealedInbox().isEmpty)
        try await until { try await receipt() == .delivered }
        await messenger.close()
        await peer.stop()
    }

    @Test func aHiddenChatSendsWhileOpenAndATextQueuedBeforeACloseLeavesAfterTheNextOpen() async throws {
        let relay = try await RealRelay()
        defer { relay.stop() }
        var (messenger, peer, peerID, appKey) = try await pair(relay)
        #expect(try await messenger.hideChat(peerID, phrase: phrase, makeNew: true))
        #expect(try await messenger.openVault(phrase))
        try await messenger.send("from the hidden chat", to: peerID)
        #expect(try await nextText(peer.transport) == (appKey, "from the hidden chat"))

        await messenger.close()
        messenger = try Messenger(directory: appDirectory, relay: deadRelay)
        await messenger.start()
        #expect(try await messenger.openVault(phrase))
        try await messenger.send("queued before the close", to: peerID)
        try await until { [messenger] in try await messenger.state().chats.first?.messages.last.map { $0.id > 0 && $0.waiting } == true }
        await messenger.close()

        messenger = try Messenger(directory: appDirectory, relay: relay.url)
        await messenger.start()
        try await until { [messenger] in try await messenger.state().link == .connected }
        #expect(try await messenger.openVault(phrase))
        #expect(try await nextText(peer.transport) == (appKey, "queued before the close"))
        try await until { [messenger] in try await messenger.state().chats.first?.messages.last?.waiting == false }
        await messenger.close()
        await peer.stop()
    }
}
