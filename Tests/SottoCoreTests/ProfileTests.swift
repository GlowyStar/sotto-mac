import Foundation
@testable import SottoCore
import Testing

/// An Attachment from the object of a vector: bytes in hex, numbers and strings as they are.
private func attachment(_ fields: Any?) -> Sotto_Attachment {
    let fields = fields as! [String: Any]
    var attachment = Sotto_Attachment()
    for (key, value) in fields {
        switch key {
        case "blob_id": attachment.blobID = Data(hex: value as! String)
        case "key": attachment.key = Data(hex: value as! String)
        case "digest": attachment.digest = Data(hex: value as! String)
        case "thumbnail": attachment.thumbnail = Data(hex: value as! String)
        case "size": attachment.size = (value as! NSNumber).uint32Value
        case "width": attachment.width = (value as! NSNumber).uint32Value
        case "height": attachment.height = (value as! NSNumber).uint32Value
        case "media_type": attachment.mediaType = value as! String
        case "file_name": attachment.fileName = value as! String
        case "caption": attachment.caption = value as! String
        default: Issue.record("no field \(key) in an Attachment")
        }
    }
    return attachment
}

/// vectors/profile.json (section 37), every vector replayed byte for byte.
struct ProfileVectorTests {
    @Test func everyVectorOfTheProfileFileReplaysByteForByte() throws {
        let vectors = try loadVectors("profile")
        #expect(vectors.count == 37)
        var errors = 0
        for vector in vectors {
            do {
                switch vector.operation {
                case "profile-encode":
                    let avatar = vector.inputs["avatar"].map(attachment)
                    let plaintext = try Envelope.encodeProfile(name: vector.text("name"), avatar: avatar)
                    #expect(plaintext.hex == vector.outputs?["plaintext"] as? String, "\(vector.name)")
                    #expect(try Envelope.unpad(plaintext).hex == vector.intermediates["content"] as? String, "\(vector.name)")
                case "profile-decode":
                    let plaintext = vector.hex("plaintext")
                    guard case .profile(let profile) = try Envelope.decodeContent(plaintext) else {
                        Issue.record("\(vector.name) is no profile")
                        continue
                    }
                    #expect(try Envelope.unpad(plaintext).hex == vector.intermediates["content"] as? String, "\(vector.name)")
                    #expect(profile.name == vector.outputs?["name"] as? String, "\(vector.name)")
                    #expect(profile.hasAvatar == (vector.outputs?["avatar"] != nil), "\(vector.name)")
                    if let avatar = vector.outputs?["avatar"] {
                        #expect(profile.avatar == attachment(avatar), "\(vector.name)")
                    }
                case "avatar-media-type":
                    let mediaType = try Envelope.avatarMediaType(vector.hex("image"))
                    #expect(mediaType == vector.outputs?["media_type"] as? String, "\(vector.name)")
                default:
                    Issue.record("\(vector.name): no operation \(vector.operation)")
                }
                #expect(vector.error == nil, "\(vector.name) passed")
            } catch let error as EnvelopeError {
                errors += 1
                #expect(error.result == vector.error, "\(vector.name)")
            }
        }
        #expect(errors == 22)
    }

    @Test func emptyProfileIsTheTwoBytes1a00AndDecodesAsAProfile() throws {
        let empty = try Envelope.encodeProfile(name: "", avatar: nil)
        #expect(try Envelope.unpad(empty) == Data([0x1a, 0x00]))
        guard case .profile(let profile) = try Envelope.decodeContent(empty) else {
            Issue.record("the empty profile is no profile")
            return
        }
        #expect(profile.name.isEmpty && !profile.hasAvatar)
    }
}

/// A PNG that the profile takes as an avatar.
private func picture(_ side: Int = 40) throws -> Data {
    try testPicture(width: side, height: side)
}

/// Part 4 in the session layer, over the relay of `ClientHarness`.
struct ProfileSessionTests {
    @Test func profileChangeIsOwedToEveryContactWithASessionAndIsNoMessage() throws {
        try withPair { clients, relay, alice, bob in
            let carol = try clients.open("carol")
            try befriend(alice, carol)
            try send(relay, alice, bob, "hi")
            try alice.setProfile(OwnProfile(name: "Alice"))
            #expect(try alice.store.owedProfiles() == [bob.identityKey])

            let sent = try alice.sendOwedProfiles(blobMaxBytes: 0)
            #expect(sent.map(\.recipient) == [bob.identityKey])
            #expect(try alice.store.owedProfiles().isEmpty)
            relay.send(alice, sent[0])
            let received = try relay.deliver(bob)
            #expect(received.map(\.profile?.name) == [nil, "Alice"])
            #expect(received.map(\.text) == ["hi", nil])
            #expect(try bob.profile(alice.identityKey)?.name == "Alice")
            #expect(try bob.store.messages(alice.identityKey).map(\.text) == ["hi"])
            // Bob's own profile is empty: his new session owes none.
            #expect(try bob.store.owedProfiles().isEmpty)

            // Carol gets the profile with her first session.
            try relay.publish(carol)
            try send(relay, alice, carol, "hello")
            #expect(try alice.store.owedProfiles() == [carol.identityKey])
        }
    }

    @Test func newSessionGetsTheProfileOnceInBothDirectionsAndAResetAgain() throws {
        try withPair(publishAlice: true) { _, relay, alice, bob in
            try alice.setProfile(OwnProfile(name: "Alice"))
            try bob.setProfile(OwnProfile(name: "Bob"))
            #expect(try alice.store.owedProfiles().isEmpty && bob.store.owedProfiles().isEmpty)

            try send(relay, alice, bob, "hi")
            #expect(try alice.store.owedProfiles() == [bob.identityKey])
            try relay.deliver(bob)
            #expect(try bob.store.owedProfiles() == [alice.identityKey])
            relay.send(alice, try alice.sendOwedProfiles(blobMaxBytes: 0)[0])
            relay.send(bob, try bob.sendOwedProfiles(blobMaxBytes: 0)[0])
            try relay.deliver(bob)
            try relay.deliver(alice)
            #expect(try bob.profile(alice.identityKey)?.name == "Alice")
            #expect(try alice.profile(bob.identityKey)?.name == "Bob")
            #expect(try alice.sendOwedProfiles(blobMaxBytes: 0).isEmpty && bob.sendOwedProfiles(blobMaxBytes: 0).isEmpty)

            try bob.startSession(alice.identityKey, bundle: relay.fetch(alice.identityKey))
            #expect(try bob.store.owedProfiles() == [alice.identityKey])
        }
    }

    @Test func receivedProfileReplacesTheEarlierOneWholeAndTheEmptyOneClearsIt() throws {
        try withPair { _, relay, alice, bob in
            try send(relay, alice, bob, "hi")
            let first = try picture()
            try alice.setProfile(OwnProfile(name: "Alice", avatar: first, thumbnail: Data([0xff, 0xd8, 0xff]), width: 40, height: 40))
            #expect(try alice.sendOwedProfiles(blobMaxBytes: 1 << 20).isEmpty)
            let upload = try #require(try alice.uploads().first)
            #expect(upload.profile && upload.attachment.mediaType == "image/png" && upload.attachment.width == 40)
            #expect(upload.attachment.fileName.isEmpty && upload.attachment.caption.isEmpty)

            // A change while the avatar is on its way gives the upload up.
            try alice.setProfile(OwnProfile(name: "Alice", avatar: first))
            #expect(try alice.uploads().isEmpty)
            #expect(try alice.blobDeletions().map(\.blobID) == [upload.blobID])
            #expect(try alice.store.owedProfiles() == [bob.identityKey])

            _ = try alice.sendOwedProfiles(blobMaxBytes: 1 << 20)
            let second = try #require(try alice.uploads().first)
            relay.send(alice, try alice.sendAttachment(second))
            #expect(try alice.uploads().isEmpty && alice.store.owedProfiles().isEmpty)
            #expect(try alice.store.files().isEmpty)
            let received = try relay.deliver(bob)
            #expect(received.map(\.profile?.avatar.blobID) == [nil, second.blobID])
            let avatarFile = try #require(try bob.profile(alice.identityKey)?.avatarFile)
            #expect(try bob.store.file(avatarFile)?.avatar == true)
            #expect(try bob.downloads().map(\.position) == [avatarFile])

            try alice.setProfile(OwnProfile(name: "Alice 2"))
            relay.send(alice, try alice.sendOwedProfiles(blobMaxBytes: 1 << 20)[0])
            try relay.deliver(bob)
            let replaced = try #require(try bob.profile(alice.identityKey))
            #expect(replaced.name == "Alice 2" && replaced.avatarFile == nil)
            #expect(try bob.store.file(avatarFile) == nil)
            // The earlier avatar was never downloaded: its blob is deleted.
            #expect(try bob.blobDeletions().map(\.blobID) == [second.blobID])

            try alice.setProfile(OwnProfile())
            relay.send(alice, try alice.sendOwedProfiles(blobMaxBytes: 1 << 20)[0])
            try relay.deliver(bob)
            #expect(try bob.profile(alice.identityKey) == nil)
            #expect(try bob.store.messages(alice.identityKey).map(\.text) == ["hi"])
            #expect(try bob.store.files().isEmpty)
        }
    }

    @Test func relayWithoutBlobsGetsTheProfileWithoutTheAvatar() throws {
        try withPair { _, relay, alice, bob in
            try send(relay, alice, bob, "hi")
            try alice.setProfile(OwnProfile(name: "Alice", avatar: try picture()))
            let sent = try alice.sendOwedProfiles(blobMaxBytes: 0)
            #expect(try alice.uploads().isEmpty)
            relay.send(alice, sent[0])
            let received = try relay.deliver(bob)
            #expect(received.last?.profile?.name == "Alice" && received.last?.profile?.hasAvatar == false)
        }
    }

    @Test func profileBeyondALimitOfSection352IsNotSet() throws {
        try withPair { _, _, alice, _ in
            #expect(throws: EnvelopeError.badProfileName) { try alice.setProfile(OwnProfile(name: "Alice\u{202E}")) }
            #expect(throws: EnvelopeError.badProfileName) {
                try alice.setProfile(OwnProfile(name: String(repeating: "x", count: Envelope.maxProfileNameBytes + 1)))
            }
            #expect(throws: EnvelopeError.avatarTooLarge) {
                try alice.setProfile(OwnProfile(avatar: Data([0xff, 0xd8, 0xff]) + Data(count: Envelope.maxAvatarBytes)))
            }
            #expect(throws: EnvelopeError.notAnImage) { try alice.setProfile(OwnProfile(avatar: Data("GIF89a".utf8))) }
            let own = try alice.ownProfile()
            #expect(own.isEmpty)
        }
    }

    @Test func refusedProfileLeavesNoRefusalAndARefusedTextKeepsOne() throws {
        try withPair { _, relay, alice, bob in
            let text = try send(relay, alice, bob, "hi")
            try alice.setProfile(OwnProfile(name: "Alice"))
            let profile = try alice.sendOwedProfiles(blobMaxBytes: 0)[0]
            try alice.dropRefusedSend(profile.messageID, result: "UNKNOWN_RECIPIENT")
            try alice.dropRefusedSend(text.messageID, result: "UNKNOWN_RECIPIENT")
            #expect(try alice.store.refusals() == [text.messageID: "UNKNOWN_RECIPIENT"])
            #expect(try alice.outbox().isEmpty)
        }
    }

    @Test func avatarUploadBeyondTheRelayIsGivenUpAndTheProfileOwedAgainAtOnce() throws {
        try withPair { _, relay, alice, bob in
            try send(relay, alice, bob, "hi")
            try alice.setProfile(OwnProfile(name: "Alice", avatar: try picture()))
            _ = try alice.sendOwedProfiles(blobMaxBytes: 1 << 20)
            let upload = try #require(try alice.uploads().first)
            #expect(try alice.store.owedProfiles().isEmpty)
            try alice.oweProfileWithoutUpload(upload)
            #expect(try alice.uploads().isEmpty)
            #expect(try alice.store.owedProfiles() == [bob.identityKey])
            #expect(try alice.blobDeletions().map(\.blobID) == [upload.blobID])
        }
    }

    @Test func storeOfTheSchemaBeforePart4OpensWithTheProfileTables() throws {
        let folder = Folder()
        let directory = folder.url.appendingPathComponent("older")
        let older = try ClientStore(directory: directory)
        let contact = Data(repeating: 7, count: 32)
        try older.transaction {
            try older.addContact(contact, name: "bob")
            try older.addFile(contact, incoming: true, messageID: Data(count: 16), attachment: Sotto_Attachment(), state: .offered)
        }
        for table in ["own_profile", "profiles", "profile_sends"] {
            try older.query("DROP TABLE \(table)")
        }
        older.close()

        let store = try ClientStore(directory: directory)
        #expect(try store.ownProfile().isEmpty && store.profiles().isEmpty && store.owedProfiles().isEmpty)
        #expect(try store.files().map(\.avatar) == [false])
        #expect(try store.contacts().map(\.name) == ["bob"])
    }
}

/// Part 4 through the transport: the avatar travels with the code of part 3.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ProfileTransportTests {
    let folder = Folder()
    let relay = ScriptedRelay()

    func key(_ name: String) throws -> Data {
        try folder.identityKey(name)
    }

    func profile(_ running: Running, of name: String) async throws -> ContactProfile? {
        let contact = try key(name)
        return try await running.transport.withClient { try $0.profile(contact) }
    }

    /// Bob with his bundle on the relay, stopped unless `keep`; Alice running.
    func start(keepBob: Bool = true) async throws -> (alice: Running, bob: Running?) {
        try befriend(folder, "alice", "bob")
        let bob = try await run(folder.open("bob"), relay)
        try await until { try await isRegistered(bob.transport) }
        if !keepBob {
            await bob.stop()
        }
        return (try await run(folder.open("alice"), relay), keepBob ? bob : nil)
    }

    @Test func avatarReachesTheContactWholeItsBlobIsDeletedAndChangesFollow() async throws {
        let (alice, started) = try await start()
        let bob = try #require(started)
        let avatar = try picture(64)
        try await alice.transport.setProfile(OwnProfile(name: "Alice", avatar: avatar))
        try await alice.transport.sendText(key("bob"), "hi")

        try await until { try await profile(bob, of: "alice")?.avatar == avatar }
        #expect(try await profile(bob, of: "alice")?.name == "Alice")
        #expect(try await textsReceived(bob.transport) == ["hi"])
        try await until { await relay.blobs.isEmpty }

        try await alice.transport.setProfile(OwnProfile(name: "Alice 2"))
        try await until { try await profile(bob, of: "alice").map { $0.name == "Alice 2" && $0.avatarFile == nil } == true }
        try await alice.transport.setProfile(OwnProfile())
        try await until { try await profile(bob, of: "alice") == nil }
        #expect(try await textsReceived(bob.transport) == ["hi"])
        await alice.stop()
        await bob.stop()
    }

    @Test func newerProfileTakesThePlaceOfAnAvatarOnItsWay() async throws {
        let (alice, _) = try await start(keepBob: false)
        let first = try picture(48)
        try await alice.transport.setProfile(OwnProfile(name: "Alice", avatar: first))
        try await alice.transport.sendText(key("bob"), "hi")
        try await until { try await alice.transport.withClient { try $0.uploads().isEmpty && $0.outbox().isEmpty } }
        let second = try picture(56)
        try await alice.transport.setProfile(OwnProfile(name: "Alice", avatar: second))
        try await until { try await alice.transport.withClient { try $0.uploads().isEmpty && $0.outbox().isEmpty } }

        let bob = try await run(folder.open("bob"), relay)
        try await until { try await profile(bob, of: "alice")?.avatar == second }
        try await until { await relay.blobs.isEmpty }
        #expect(try await bob.transport.withClient { try $0.store.files().count } == 1)
        await alice.stop()
        await bob.stop()
    }

    @Test func avatarThatIsNoImageOfItsMediaTypeIsNotKept() async throws {
        let (alice, started) = try await start()
        let bob = try #require(started)
        try await alice.transport.sendText(key("bob"), "hi")
        try await until { try await alice.transport.withClient { try $0.outbox().isEmpty } }
        let bobKey = try key("bob")
        // A sender that names a PNG picture a JPEG one, written past the checks of setProfile.
        try await alice.transport.withClient { client in
            try client.store.transaction {
                try client.store.setOwnProfile(OwnProfile(name: "Alice", avatar: try picture(), mediaType: "image/jpeg"))
                try client.store.oweProfile(bobKey)
            }
        }
        // A new session sends what is owed.
        _ = try await alice.transport.resetSession(key("bob"))

        let failed = try await nextFile(bob.transport) { $0.avatar && $0.state != .receiving }
        #expect(failed.state == .notReceived && failed.result == "NOT_AN_IMAGE")
        let kept = try #require(try await profile(bob, of: "alice"))
        #expect(kept.name == "Alice" && kept.avatar == nil)
        try await until { await relay.blobs.isEmpty }
        await alice.stop()
        await bob.stop()
    }
}
