import Foundation
@testable import SottoCore
import Testing

/// A count that the edits of the scripted relay share across connections.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    /// Counts one more of `kind` and returns the new count.
    func next(_ kind: String) -> Int {
        lock.withLock {
            counts[kind, default: 0] += 1
            return counts[kind]!
        }
    }
}

/// The client frames of one kind that reached the scripted relay, in their order.
private func clientFrames(_ relay: ScriptedRelay) async -> [(link: Link, frame: Sotto_ClientFrame.OneOf_Frame)] {
    await relay.sentToRelay.compactMap { sent in
        (try? Sotto_ClientFrame(serializedBytes: sent.frame).frame).map { (sent.link, $0) }
    }
}

private func putOffsets(_ relay: ScriptedRelay) async -> [UInt32] {
    await clientFrames(relay).compactMap { if case .putBlob(let put) = $0.frame { put.offset } else { nil } }
}

private func fetchOffsets(_ relay: ScriptedRelay) async -> [(connection: Int, offset: UInt32)] {
    await clientFrames(relay).compactMap {
        if case .fetchBlob(let fetch) = $0.frame { ($0.link.number, fetch.offset) } else { nil }
    }
}

/// The next `.file` event that matches.
@discardableResult
func nextFile(_ transport: Transport, _ matches: @escaping @Sendable (FileUpdate) -> Bool) async throws -> FileUpdate {
    guard case .file(let update) = try await nextEvent(transport, {
        if case .file(let update) = $0 { matches(update) } else { false }
    }) else {
        throw Timeout()
    }
    return update
}

/// Bytes that differ from piece to piece, so that a piece in the wrong place shows.
private func pattern(_ count: Int) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
}

/// Two clients on the scripted relay, Bob with a folder for received files.
private struct Pair {
    let folder = Folder()
    let relay = ScriptedRelay()

    var received: URL {
        folder.url.appendingPathComponent("received")
    }

    func key(_ name: String) throws -> Data {
        try folder.identityKey(name)
    }

    func file(_ name: String, _ data: Data) throws -> URL {
        let url = folder.url.appendingPathComponent("outgoing-\(UUID().uuidString)").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func bob() async throws -> Running {
        try await run(folder.open("bob"), relay, receivedFiles: received)
    }

    func alice() async throws -> Running {
        try await run(folder.open("alice"), relay)
    }

    /// Bob on the relay with his bundle, then Alice.
    func start() async throws -> (alice: Running, bob: Running) {
        try befriend(folder, "alice", "bob")
        let bob = try await bob()
        try await until { try await isRegistered(bob.transport) }
        return (try await alice(), bob)
    }

    func savedFiles() throws -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: received.path))?.sorted() ?? []
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct FileTests {
    @Test func fileOfSeveralPiecesIsReceivedByteForByteAndItsBlobIsDeleted() async throws {
        let pair = Pair()
        let (alice, bob) = try await pair.start()
        let content = pattern(200_000)

        let blobID = try await alice.transport.sendFile(try pair.key("bob"), file: pair.file("photo.jpg", content), caption: "look")
        let sent = try await nextFile(alice.transport) { $0.state == .sent || $0.state == .notSent }
        #expect(sent.state == .sent && sent.blobID == blobID)
        let received = try await nextFile(bob.transport) { $0.state == .received || $0.state == .notReceived }
        #expect(received.state == .received)
        #expect(try Data(contentsOf: received.path!) == content)
        #expect(received.path?.lastPathComponent == "photo.jpg")
        #expect(await putOffsets(pair.relay).count == (Blob.blobLength(content.count) + Frames.blobChunkBytes - 1) / Frames.blobChunkBytes)
        try await until { await pair.relay.blobs.isEmpty }

        let files = try await bob.transport.withClient { try $0.store.files() }
        #expect(files.map(\.state) == [.received] && files[0].savedAs == received.path?.path)
        #expect(try await textsReceived(bob.transport) == ["look"])
        #expect(try await alice.transport.withClient { try $0.store.uploads() }.isEmpty)
        await alice.stop()
        await bob.stop()
    }

    @Test func uploadCutInTheMiddleGoesOnFromTheStoredLength() async throws {
        let pair = Pair()
        let (alice, bob) = try await pair.start()
        let aliceKey = try pair.key("alice")
        let tally = Tally()
        // The answer to the second PutBlob is lost with its connection; the relay stored it.
        await pair.relay.edit(toClient: { link, message in
            if link.identity == aliceKey, serverKind(message) == "blob_stored", tally.next("stored") == 3 {
                throw Cut()
            }
            return [.message(message)]
        })
        let content = pattern(400_000)

        try await alice.transport.sendFile(try pair.key("bob"), file: pair.file("cut.bin", content))
        #expect(try await nextFile(alice.transport) { $0.state == .sent || $0.state == .notSent }.state == .sent)
        let received = try await nextFile(bob.transport) { $0.state == .received || $0.state == .notReceived }
        #expect(try Data(contentsOf: received.path!) == content)

        let offsets = await putOffsets(pair.relay)
        #expect(offsets == offsets.sorted() && Set(offsets).count == offsets.count, "no piece is sent twice")
        #expect(await pair.relay.connections >= 3)
        await alice.stop()
        await bob.stop()
    }

    @Test func downloadCutInTheMiddleGoesOnFromTheBytesItHolds() async throws {
        let pair = Pair()
        let (alice, bob) = try await pair.start()
        let bobKey = try pair.key("bob")
        let tally = Tally()
        await pair.relay.edit(toClient: { link, message in
            if link.identity == bobKey, serverKind(message) == "blob_data", tally.next("data") == 3 {
                throw Cut()
            }
            return [.message(message)]
        })
        let content = pattern(400_000)

        try await alice.transport.sendFile(try pair.key("bob"), file: pair.file("cut.bin", content))
        let received = try await nextFile(bob.transport) { $0.state == .received || $0.state == .notReceived }
        #expect(try Data(contentsOf: received.path!) == content)

        let fetches = await fetchOffsets(pair.relay)
        let first = fetches[0].connection
        let resumed = try #require(fetches.first { $0.connection != first })
        #expect(resumed.offset == UInt32(2 * Frames.blobChunkBytes), "the download goes on from the two pieces it held")
        #expect(fetches.filter { $0.offset == 0 }.count == 1)
        await alice.stop()
        await bob.stop()
    }

    @Test func clientRestartedInTheMiddleOfAnUploadAndOfADownload() async throws {
        let pair = Pair()
        var (alice, bob) = try await pair.start()
        let aliceKey = try pair.key("alice")
        let bobKey = try pair.key("bob")
        let tally = Tally()
        // Each client hangs once on a lost answer and is then stopped and opened again.
        await pair.relay.edit(toClient: { link, message in
            if link.identity == aliceKey, serverKind(message) == "blob_stored", tally.next("stored") == 3 {
                return []
            }
            if link.identity == bobKey, serverKind(message) == "blob_data", tally.next("data") == 3 {
                return []
            }
            return [.message(message)]
        })
        let content = pattern(400_000)

        try await alice.transport.sendFile(try pair.key("bob"), file: pair.file("restart.bin", content))
        try await nextFile(alice.transport) { $0.state == .sending && $0.done == Frames.blobChunkBytes }
        await alice.stop()
        alice = try await pair.alice()
        #expect(try await nextFile(alice.transport) { $0.state == .sent || $0.state == .notSent }.state == .sent)

        try await nextFile(bob.transport) { $0.state == .receiving && $0.done == 2 * Frames.blobChunkBytes }
        try await Task.sleep(nanoseconds: 100_000_000)
        await bob.stop()
        bob = try await pair.bob()
        let received = try await nextFile(bob.transport) { $0.state == .received || $0.state == .notReceived }
        #expect(try Data(contentsOf: received.path!) == content)

        let offsets = await putOffsets(pair.relay)
        #expect(offsets == offsets.sorted() && Set(offsets).count == offsets.count, "the upload goes on from the stored length")
        #expect(await fetchOffsets(pair.relay).filter { $0.offset == 0 }.count == 1, "the download goes on from the bytes it held")
        await alice.stop()
        await bob.stop()
    }

    @Test func relayThatAnnouncesNoBlobsGetsNoBlobFrame() async throws {
        let pair = Pair()
        await pair.relay.setBlobLimits(maxBytes: 0)
        let (alice, bob) = try await pair.start()

        await #expect(throws: FileError.filesUnsupported) {
            try await alice.transport.sendFile(try pair.key("bob"), file: pair.file("a.txt", pattern(10)))
        }
        #expect(await pair.relay.kinds().allSatisfy { !$0.contains("blob") })
        #expect(try await alice.transport.withClient { try $0.store.uploads() }.isEmpty)
        await alice.stop()
        await bob.stop()
    }

    @Test func transfersEndWhenALaterLoginAnnouncesNoBlobs() async throws {
        let pair = Pair()
        let (alice, bob) = try await pair.start()
        let aliceKey = try pair.key("alice")
        let bobKey = try pair.key("bob")
        let tally = Tally()
        // Bob's download and Alice's second upload hang until the relay goes down.
        await pair.relay.edit(toClient: { link, message in
            if link.identity == bobKey, serverKind(message) == "blob_data" {
                return []
            }
            if link.identity == aliceKey, serverKind(message) == "blob_stored", tally.next("stored") > 4 {
                return []
            }
            return [.message(message)]
        })
        try await alice.transport.sendFile(try pair.key("bob"), file: pair.file("first.bin", pattern(1000)))
        try await nextFile(alice.transport) { $0.state == .sent }
        _ = try await nextIncoming(bob.transport)
        try await alice.transport.sendFile(try pair.key("bob"), file: pair.file("second.bin", pattern(200_000)))
        try await nextFile(alice.transport) { $0.state == .sending && $0.done > 0 }

        await pair.relay.shutDown()
        await pair.relay.setBlobLimits(maxBytes: 0)
        await pair.relay.start()
        let upload = try await nextFile(alice.transport) { $0.state == .notSent }
        #expect(upload.fileName == "second.bin" && upload.result == "FILES_UNSUPPORTED")
        let download = try await nextFile(bob.transport) { $0.state == .notReceived }
        #expect(download.fileName == "first.bin" && download.result == "FILES_UNSUPPORTED")
        #expect(try pair.savedFiles().isEmpty)
        #expect(try await bob.transport.withClient { try $0.store.query("SELECT count(*) FROM downloads")[0][0].integer } == 0)
        #expect(try await alice.transport.withClient { try $0.store.uploads() }.isEmpty)
        await alice.stop()
        await bob.stop()
    }

    @Test func uploadOverTheQuotaIsNotSentAndItsBlobIsDeleted() async throws {
        let pair = Pair()
        await pair.relay.setBlobLimits(maxBytes: 1 << 26, quotaBytes: 1000)
        let (alice, bob) = try await pair.start()

        try await alice.transport.sendFile(try pair.key("bob"), file: pair.file("big.bin", pattern(2000)))
        let ended = try await nextFile(alice.transport) { $0.state == .notSent }
        #expect(ended.result == "QUOTA_FULL")
        let aliceKey = try pair.key("alice")
        try await until { await pair.relay.kinds(of: aliceKey).contains("delete_blob") }
        #expect(!(await pair.relay.kinds(of: aliceKey).contains("send")), "no message names the file")
        let state = try await alice.transport.withClient { try ($0.store.uploads().count, $0.store.files().map(\.state)) }
        #expect(state.0 == 0 && state.1 == [.notSent])
        await alice.stop()
        await bob.stop()
    }

    @Test func fileTooLargeIsNotSentAndSendsNoBlobFrame() async throws {
        let pair = Pair()
        await pair.relay.setBlobLimits(maxBytes: 1000)
        let (alice, bob) = try await pair.start()

        await #expect(throws: FileError.fileTooLarge) {
            try await alice.transport.sendFile(try pair.key("bob"), file: pair.file("big.bin", pattern(2000)))
        }
        #expect(await pair.relay.kinds().allSatisfy { !$0.contains("blob") })
        await alice.stop()
        await bob.stop()
    }

    @Test func alteredOrTruncatedBlobCouldNotBeReceivedAndWritesNothing() async throws {
        let pair = Pair()
        let (alice, bob) = try await pair.start()
        let bobKey = try pair.key("bob")
        let tally = Tally()
        // The first blob gets one byte changed, the second loses its last byte.
        await pair.relay.edit(toClient: { link, message in
            guard link.identity == bobKey, serverKind(message) == "blob_data" else {
                return [.message(message)]
            }
            var frame = serverFrame(message)
            if tally.next("data") == 1 {
                frame.blobData.data[frame.blobData.data.startIndex + 100] ^= 1
            } else {
                frame.blobData.data.removeLast()
            }
            return [.message(binary(frame))]
        })

        for name in ["altered.bin", "truncated.bin"] {
            try await alice.transport.sendFile(bobKey, file: pair.file(name, pattern(5000)))
            let ended = try await nextFile(bob.transport) { $0.state == .received || $0.state == .notReceived }
            #expect(ended.state == .notReceived && ended.result == "BAD_BLOB" && ended.fileName == name)
        }
        #expect(try pair.savedFiles().isEmpty)
        try await until { await pair.relay.kinds(of: bobKey).filter { $0 == "delete_blob" }.count == 2 }
        await alice.stop()
        await bob.stop()
    }

    @Test func deletedMessageOfAnUploadIsNeverSentAndItsBlobIsDeleted() async throws {
        let pair = Pair()
        let (alice, bob) = try await pair.start()
        let aliceKey = try pair.key("alice")
        let bobKey = try pair.key("bob")
        let tally = Tally()
        await pair.relay.edit(toClient: { link, message in
            if link.identity == aliceKey, serverKind(message) == "blob_stored", tally.next("stored") == 3 {
                return []
            }
            return [.message(message)]
        })
        try await alice.transport.sendFile(bobKey, file: pair.file("cancelled.bin", pattern(300_000)))
        try await nextFile(alice.transport) { $0.state == .sending && $0.done > 0 }
        try await alice.transport.withClient { client in
            let position = try client.store.messages(bobKey).last!.position
            try client.store.transaction { try client.deleteMessage(position) }
        }
        await pair.relay.shutDown()
        await pair.relay.start()

        try await until { await pair.relay.kinds(of: aliceKey).contains("delete_blob") }
        try await until { await pair.relay.blobs.isEmpty }
        let kinds = await pair.relay.kinds(of: aliceKey)
        #expect(!kinds.contains("send"), "no message names the file")
        #expect(kinds.filter { $0 == "start_blob" }.count == 1, "the upload does not start again")
        let left = try await alice.transport.withClient { try ($0.store.uploads().count, $0.store.files().count) }
        #expect(left == (0, 0))
        await alice.stop()
        await bob.stop()
    }

    @Test func expiredBlobIsNotAvailableAndItsMessageStays() async throws {
        let pair = Pair()
        try befriend(pair.folder, "alice", "bob")
        var bob = try await pair.bob()
        try await until { [bob] in try await isRegistered(bob.transport) }
        await bob.stop()
        let alice = try await pair.alice()
        try await alice.transport.sendFile(try pair.key("bob"), file: pair.file("gone.bin", pattern(3000)), caption: "kept")
        try await nextFile(alice.transport) { $0.state == .sent }
        await pair.relay.expireBlobs()

        bob = try await pair.bob()
        let ended = try await nextFile(bob.transport) { $0.state != .receiving && $0.state != .offered }
        #expect(ended.state == .notAvailable && ended.result == "BLOB_GONE")
        #expect(try await textsReceived(bob.transport) == ["kept"])
        await alice.stop()
        await bob.stop()
    }

    @Test func receivedNameNeverPicksAFolderOrOverwritesAFile() throws {
        let folder = Folder()
        let target = folder.url.appendingPathComponent("received")
        let unsafe = ["", ".", "..", "../up.txt", "a/b", "a\\b", "nul\u{0}", "bell\u{7}", "del\u{7F}", "c1\u{85}",
                      "rtl\u{202E}gpj.exe", "line\u{2028}", String(repeating: "x", count: 256)]
        for name in unsafe {
            let saved = try ReceivedFiles.save(Data("x".utf8), named: name, into: target)
            #expect(saved.deletingLastPathComponent().path == target.path)
            #expect(saved.lastPathComponent.hasPrefix(ReceivedFiles.ownName), "\(name.debugDescription)")
        }
        #expect(ReceivedFiles.isSafeName("отчёт 2026.pdf") && ReceivedFiles.isSafeName(String(repeating: "x", count: 255)))

        let first = try ReceivedFiles.save(Data("one".utf8), named: "note.txt", into: target)
        let second = try ReceivedFiles.save(Data("two".utf8), named: "note.txt", into: target)
        #expect(first.lastPathComponent == "note.txt" && second.lastPathComponent == "note (1).txt")
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")

        let outside = folder.url.appendingPathComponent("outside.txt")
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("link.txt"), withDestinationURL: outside)
        let linked = try ReceivedFiles.save(Data("three".utf8), named: "link.txt", into: target)
        #expect(linked.lastPathComponent == "link (1).txt")
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(ReceivedFiles.split("archive.tar.gz") == ("archive.tar", ".gz"))
        #expect(ReceivedFiles.split(".profile") == (".profile", ""))
    }

    @Test func receivedAttachmentThatBreaksSection32_2IsBadContent() throws {
        var attachment = Sotto_Attachment()
        attachment.blobID = Data(count: 16)
        attachment.key = Data(count: 16)
        attachment.digest = Data(count: 32)
        let good = try Envelope.encodeAttachment(attachment)
        #expect(throws: Never.self) { try Envelope.decodeContent(good) }

        let edits: [(inout Sotto_Attachment) -> Void] = [
            { $0.blobID = Data(count: 15) }, { $0.key = Data(count: 17) }, { $0.digest = Data() },
            { $0.size = UInt32(Blob.maxFileBytes + 1) },
        ]
        for edit in edits {
            var broken = attachment
            edit(&broken)
            var content = Sotto_Content()
            content.attachment = broken
            #expect(throws: EnvelopeError.badContent) { try Envelope.decodeContent(Envelope.pad(content.serializedBytes())) }
        }
        attachment.caption = String(repeating: "c", count: Envelope.maxCaptionBytes + 1)
        #expect(throws: InvalidInputError.self) { try Envelope.encodeAttachment(attachment) }
    }
}
