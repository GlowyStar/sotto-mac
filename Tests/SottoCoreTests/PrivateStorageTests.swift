import Foundation
@testable import SottoCore
import Testing

/// Every regular file under `directory`, with its bytes.
private func filesUnder(_ directory: URL) -> [(URL, Data)] {
    let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    var found: [(URL, Data)] = []
    while let url = walker?.nextObject() as? URL {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, let data = FileManager.default.contents(atPath: url.path) {
            found.append((url, data))
        }
    }
    return found
}

@Test func anOldAppJSONMovesIntoTheStoreOnceAndKeepsOnlyTheTheme() async throws {
    let folder = Folder()
    let directory = folder.url.appendingPathComponent("app")
    let bob = String(repeating: "ab", count: 32)
    _ = try ClientStore(directory: directory)
    let old = """
        {"relay":"wss://relay.example.org/ws","read":{"\(bob)":7},"added":{"\(bob)":1700000000000},"times":{"7":1700000000001},
        "drafts":{"\(bob)":"a draft marker"},"pins":["\(bob)"],"muted":["\(bob)"],"archived":["\(bob)"],
        "timerChanges":{"\(bob)":[{"at":1700000000002,"seconds":30,"own":true}]},
        "settings":{"theme":"dark","notifications":false,"notificationSender":true,"notificationPreview":true,"textSize":17}}
        """
    let file = directory.appendingPathComponent(Messenger.notesFile)
    try Data(old.utf8).write(to: file)

    let first = try Messenger(directory: directory, relay: deadRelay)
    #expect(first.tookInOlderNotes, "the app takes away the notifications of the older version")
    #expect(await first.relay == "wss://relay.example.org/ws")
    let settings = try #require(first.launchSettings)
    #expect(settings.theme == .dark && settings.textSize == 17 && !settings.notifications, "chosen settings stay")
    #expect(!settings.notificationSender && !settings.notificationPreview, "an old file shows no name and no text")
    await first.close()

    #expect(try String(contentsOf: file, encoding: .utf8) == #"{"theme":"dark"}"#)
    let notes = try #require(try Notes.load(ClientStore(directory: directory)))
    #expect(notes.drafts == [bob: "a draft marker"] && notes.read == [bob: 7] && notes.times == ["7": 1_700_000_000_001])
    #expect(notes.pins == [bob] && notes.muted == [bob] && notes.archived == [bob] && notes.timerChanges[bob]?.count == 1)

    // Once only: an app.json written later by an older version brings nothing back.
    try Data(old.replacingOccurrences(of: "a draft marker", with: "a later draft").utf8).write(to: file)
    let second = try Messenger(directory: directory, relay: deadRelay)
    #expect(!second.tookInOlderNotes)
    await second.close()
    #expect(try Notes.load(ClientStore(directory: directory))?.drafts == [bob: "a draft marker"])
    #expect(try String(contentsOf: file, encoding: .utf8) == #"{"theme":"dark"}"#)
}

@Test func anAppJSONThatDoesNotOpenForWritingIsReplacedAndTheStoreOpens() async throws {
    let folder = Folder()
    for kind in ["read only", "link"] {
        let directory = folder.url.appendingPathComponent(kind)
        _ = try ClientStore(directory: directory)
        let file = directory.appendingPathComponent(Messenger.notesFile)
        let old = Data(#"{"drafts":{"x":"a draft"},"settings":{"theme":"dark"}}"#.utf8)
        let elsewhere = folder.url.appendingPathComponent("elsewhere-\(kind).json")
        if kind == "link" {
            try old.write(to: elsewhere)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        } else {
            try old.write(to: file)
            chmod(file.path, 0o400)
        }
        let messenger = try Messenger(directory: directory, relay: deadRelay)
        await messenger.close()
        #expect(try String(contentsOf: file, encoding: .utf8) == #"{"theme":"dark"}"#, "\(kind)")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == nil, "app.json is a plain file now")
        if kind == "link" {
            #expect(FileManager.default.contents(atPath: elsewhere.path) == old, "the file a link names is not touched")
        }
    }
}

@Test func aKeptFileGoesInAndOutInPieces() throws {
    let folder = Folder()
    let store = try ClientStore(directory: folder.url.appendingPathComponent("app"))
    let bytes = Data((0..<(2 * ClientStore.keptPieceBytes + 12345)).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 9) })
    let position = try store.transaction {
        try store.addContact(Data(repeating: 4, count: 32), name: "bob")
        let made = try store.addFile(
            Data(repeating: 4, count: 32), incoming: true, messageID: Data([1]), attachment: Sotto_Attachment(), state: .received,
            savedAs: "/somewhere"
        )
        // A slice that starts past index 0, as `Data` from a larger buffer does.
        try store.keepFile(made, (Data([9]) + bytes).dropFirst())
        return made
    }
    #expect(try store.keptFile(position) == bytes && store.file(position)?.savedAs == nil)
    var pieces: [Data] = []
    #expect(try store.readKeptFile(position) { pieces.append($0) })
    #expect(pieces.map(\.count) == [ClientStore.keptPieceBytes, ClientStore.keptPieceBytes, 12345])
    #expect(Data(pieces.joined()) == bytes)
    #expect(try !store.readKeptFile(position + 1) { _ in })
}

@Test func pastedPicturesOfAnOlderVersionMoveIntoTheStore() throws {
    let folder = Folder()
    let directory = folder.url.appendingPathComponent("app")
    let pasted = directory.appendingPathComponent(Messenger.pastedFolder, isDirectory: true)
    let store = try ClientStore(directory: directory)
    try FileManager.default.createDirectory(at: pasted, withIntermediateDirectories: true)
    let picture = try testPicture(width: 40, height: 30, noise: true)
    let sentFrom = pasted.appendingPathComponent("Pasted image 2026-11-01 10.00.00.png")
    try picture.write(to: sentFrom)
    try Data("never sent".utf8).write(to: pasted.appendingPathComponent("Pasted image 2026-11-02 10.00.00.png"))
    let elsewhere = folder.url.appendingPathComponent("mine.png")
    try picture.write(to: elsewhere)
    let bob = Data(repeating: 3, count: 32)
    let (inPasted, ownFile) = try store.transaction {
        try store.addContact(bob, name: "bob")
        return (
            try store.addFile(bob, incoming: false, messageID: Data([1]), attachment: Sotto_Attachment(), state: .sent, savedAs: sentFrom.path),
            try store.addFile(bob, incoming: false, messageID: Data([2]), attachment: Sotto_Attachment(), state: .sent, savedAs: elsewhere.path)
        )
    }

    _ = try Messenger(directory: directory, relay: deadRelay)
    #expect(!FileManager.default.fileExists(atPath: pasted.path))
    #expect(try store.keptFile(inPasted) == picture)
    #expect(try store.file(inPasted)?.savedAs == nil && store.file(inPasted)?.kept == true)
    #expect(try store.file(ownFile)?.savedAs == elsewhere.path && store.keptFile(ownFile) == nil, "the user's own file stays his")
    #expect(FileManager.default.contents(atPath: elsewhere.path) == picture)

    // The kept bytes go with their file.
    try store.transaction { try store.deleteFile(inPasted) }
    #expect(try store.keptFile(inPasted) == nil)
}

/// A copy written for another app to open is overwritten and removed as soon as its message
/// is gone: deleted, then expired; the others go when the messenger closes.
@Test func anOpenedCopyGoesWhenItsMessageIsDeletedOrExpires() async throws {
    let folder = Folder()
    let directory = folder.url.appendingPathComponent("app")
    // A ws address off loopback is refused, so the messenger runs on a client alone.
    let messenger = try Messenger(directory: directory, relay: "ws://relay.example.org/ws")
    await messenger.start()
    _ = try await messenger.createIdentity()
    let bob = Data(repeating: 7, count: 32)
    let other = try ClientStore(directory: directory)
    try other.transaction { try other.addContact(bob, name: "bob") }
    func received(_ id: UInt8, _ bytes: Data) throws -> Int64 {
        try other.transaction {
            let position = try other.logMessage(bob, direction: .incoming, messageID: Data([id]), text: "")
            let file = try other.addFile(bob, incoming: true, messageID: Data([id]), attachment: Sotto_Attachment(), state: .received)
            try other.keepFile(file, bytes)
            return position
        }
    }
    let deleted = try received(1, Data("deleted for me".utf8))
    let expiring = try received(2, Data("under a timer".utf8))
    let staying = try received(3, Data("stays until the close".utf8))
    try await until { try await messenger.state().chats.first?.messages.count == 3 }

    var opened: [URL] = []
    for position in [deleted, expiring, staying] {
        opened.append(try #require(try await messenger.openCopy(position, named: "notes.txt")))
    }
    let copies = opened
    #expect(copies.map { $0.deletingLastPathComponent().lastPathComponent } == Array(repeating: Messenger.openedFolder, count: 3))
    #expect(FileManager.default.contents(atPath: copies[0].path) == Data("deleted for me".utf8))
    // A second name of the first copy sees what is written over it.
    let witness = folder.url.appendingPathComponent("witness")
    #expect(link(copies[0].path, witness.path) == 0)

    try await messenger.deleteMessage(deleted)
    #expect(!FileManager.default.fileExists(atPath: copies[0].path))
    #expect(FileManager.default.contents(atPath: witness.path) == Data(count: 14), "the copy was overwritten")
    #expect(FileManager.default.fileExists(atPath: copies[1].path))

    let now = Int64(Date().timeIntervalSince1970)
    try other.transaction {
        try other.saveState(bob, incoming: true, messageID: Data([2]), state: NewState(writtenAt: now, expiresAfter: 1, expiresAt: now + 1))
    }
    try await until { !FileManager.default.fileExists(atPath: copies[1].path) }
    #expect(try await messenger.state().chats.first?.messages.map(\.id) == [staying])
    #expect(FileManager.default.fileExists(atPath: copies[2].path))

    other.close()
    await messenger.close()
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(Messenger.openedFolder).path))
}

extension MessengerRelayTests {
    @Test func nothingOfTheChatsIsReadableInTheDataFolder() async throws {
        let relay = try await RealRelay()
        defer { relay.stop() }
        let downloads = folder.url.appendingPathComponent("downloads")
        let messenger = try Messenger(directory: appDirectory, relay: relay.url, receivedFiles: downloads)
        await messenger.start()
        let appID = try await messenger.createIdentity()
        let appKey = try Identity.decodeUserID(appID)
        try folder.open("peer").addContact(appID)
        let peerID = try folder.userID("peer")
        try await messenger.addContact(name: "peer", userID: peerID)
        var settings = AppSettings()
        settings.theme = .light
        try await messenger.saveSettings(settings)
        try await waitFor(messenger) { $0.link == .connected }
        let peerFiles = folder.url.appendingPathComponent("peer-received")
        let peer = try await run(folder.open("peer"), URLSessionDialer(), url: relay.url, receivedFiles: peerFiles)
        try await until { try await isRegistered(peer.transport) }

        let markers = ["an outgoing marker text", "an incoming marker text", "a draft marker text", "a caption marker text"]
        try await messenger.send(markers[0], to: peerID)
        #expect(try await nextText(peer.transport) == (appKey, markers[0]))
        try await peer.transport.sendText(appKey, markers[1])
        try await waitFor(messenger) { $0.chats.first?.messages.contains { $0.text == markers[1] } == true }
        try await messenger.setDraft(markers[2], for: peerID)

        let picture = try testPicture(width: 64, height: 48, noise: true)
        let pastedAt = try await messenger.sendFile(
            named: "Pasted image.png", contents: picture, caption: markers[3], to: peerID, mediaType: "image/png"
        )
        let arrived = try await nextFile(peer.transport) { $0.state == .received }
        #expect(try Data(contentsOf: arrived.path!) == picture)
        #expect(try await messenger.contents(pastedAt) == picture, "the store keeps the pasted picture")

        let received = Data(String(repeating: "a received file marker\n", count: 200).utf8)
        let incoming = folder.url.appendingPathComponent("from peer.txt")
        try received.write(to: incoming)
        try await peer.transport.sendFile(appKey, file: incoming)
        try await waitFor(messenger) { $0.chats.first?.messages.last?.file?.state == .received }
        let message = try #require(try await chat(messenger)?.messages.last)
        #expect(message.file?.kept == true && message.file?.savedAs == nil)
        #expect(try await messenger.contents(message.id) == received, "the received file opens from the store")
        let (copy, descriptor) = try ReceivedFiles.create(named: "copy.txt", into: folder.url.appendingPathComponent("saved"))
        #expect(try await messenger.writeContents(message.id, to: descriptor))
        try ReceivedFiles.finish(copy, descriptor)
        #expect(FileManager.default.contents(atPath: copy.path) == received, "Save as writes it from the store")
        await messenger.close()
        await peer.stop()

        #expect(!FileManager.default.fileExists(atPath: downloads.path), "nothing went to the download folder")
        let files = filesUnder(appDirectory)
        #expect(Set(files.map(\.0.lastPathComponent)) == [ClientStore.fileName, StoreKeys.fileName, Vault.fileName, Messenger.notesFile])
        let secrets = markers.map { Data($0.utf8) } + [Data("a received file marker".utf8), picture.subdata(in: 100..<164)]
        for (url, data) in files {
            #expect(!secrets.contains { data.range(of: $0) != nil }, "\(url.lastPathComponent) holds a text of the chat or the picture")
        }
        #expect(files.first { $0.0.lastPathComponent == Messenger.notesFile }?.1 == Data(#"{"theme":"light"}"#.utf8))
    }
}
