import Foundation
@testable import SottoCore
import Testing

private let graceCases: [(secondsAfterTheReplacement: Int64, deleted: Bool, result: String?)] = [
    (Client.signedPrekeyGraceSeconds - 1, false, nil),
    (Client.signedPrekeyGraceSeconds, false, "UNKNOWN_SIGNED_PREKEY"),
    (Client.signedPrekeyGraceSeconds, true, "UNKNOWN_SIGNED_PREKEY"),
]

@Test(arguments: 0..<3)
func initialMessageUnderAReplacedSignedPrekeyDecryptsOnlyInTheGracePeriod(index: Int) throws {
    let (secondsAfterTheReplacement, deleted, result) = graceCases[index]
    try withPair { clients, relay, alice, bob in
        let initial = try send(relay, alice, bob, "under the old key")
        let oldPrivateKey = try #require(try bob.store.signedPrekey(1, replacedAfter: 0))

        clients.clock.advance(Client.signedPrekeyRotationSeconds)
        let upload = try #require(try bob.prepareUpload(oneTimePrekeyCount: 0, pqOneTimePrekeyCount: Client.pqOneTimePrekeyCap))
        #expect(upload.signedPrekey.id == 2)
        clients.clock.advance(secondsAfterTheReplacement)
        if deleted {
            try bob.deleteExpiredPrekeys()
            #expect(try filesHolding(clients.folder.appendingPathComponent("bob"), oldPrivateKey).isEmpty)
        }
        let storeBefore = try rows(bob.store)

        let received = try bob.receive(initial)

        #expect(received.result == result)
        if result == nil {
            #expect(received.text == "under the old key")
        } else {
            #expect(received.text == nil)
            #expect(try rows(bob.store) == storeBefore)
        }
    }
}

@Test func replayedInitialMessageGivesNoTextAfterItsSessionLeftAndAfterARestart() throws {
    try withPair(bobOneTimeCount: 0) { clients, relay, alice, firstBob in
        var bob = firstBob
        let initial = try send(relay, alice, bob, "first")
        #expect(try bob.receive(initial).text == "first")
        for number in 0..<ClientStore.maxSessions {
            try alice.startSession(bob.identityKey, bundle: relay.fetch(bob.identityKey))
            #expect(try bob.receive(send(relay, alice, bob, "new \(number)")).text == "new \(number)")
        }
        clients.clock.advance(Client.seenIDSeconds)
        try bob.forgetSeenIDs()
        let storeBefore = try rows(bob.store)

        #expect(try bob.receive(initial).result == "REPLAYED_INITIAL")
        bob.store.close()
        bob = try clients.open("bob")
        #expect(try bob.receive(initial).result == "REPLAYED_INITIAL")
        #expect(try rows(bob.store) == storeBefore)

        _ = try bob.prepareUpload(oneTimePrekeyCount: 0, pqOneTimePrekeyCount: Client.pqOneTimePrekeyCap)
        clients.clock.advance(Client.signedPrekeyGraceSeconds)
        try bob.deleteExpiredPrekeys()
        #expect(try bob.store.query("SELECT count(*) FROM records") == [[.integer(Int64(ClientStore.maxSessions))]])
        #expect(try bob.receive(initial).result == "UNKNOWN_SIGNED_PREKEY")
        #expect(try bob.receive(send(relay, alice, bob, "on a listed session")).text == "on a listed session")
    }
}

@Test func removedContactAddedAgainGetsNoReplayedInitialMessage() throws {
    try withPair { clients, relay, alice, bob in
        let initial = try send(relay, alice, bob, "before the removal")
        #expect(try bob.receive(initial).text == "before the removal")

        try bob.removeContact(alice.identityKey)
        try bob.addContact(userID(alice))

        #expect(try bob.store.sessions(alice.identityKey).isEmpty)
        #expect(try bob.receive(initial).result == "DUPLICATE")
        clients.clock.advance(Client.seenIDSeconds)
        try bob.forgetSeenIDs()
        #expect(try bob.receive(initial).result == "REPLAYED_INITIAL")
    }
}

@Test func rotationFollowsTheAgeOfTheNewestSignedPrekey() throws {
    try withClients { clients, _ in
        let carol = try clients.open("carol")
        let first = try #require(try carol.prepareUpload(oneTimePrekeyCount: 0, pqOneTimePrekeyCount: Client.pqOneTimePrekeyCap))
        #expect(first.signedPrekey.id == 1)
        #expect(first.oneTimePrekeys.count == Client.oneTimePrekeyCap)

        let again = try #require(try carol.prepareUpload(oneTimePrekeyCount: Client.oneTimePrekeyCap, pqOneTimePrekeyCount: Client.pqOneTimePrekeyCap))
        var firstWithoutOneTimePrekeys = first
        firstWithoutOneTimePrekeys.oneTimePrekeys = []
        #expect(keys(again) == keys(firstWithoutOneTimePrekeys))
        try verifySignatures(again, of: carol)
        try carol.confirmUpload(first)
        clients.clock.advance(Client.signedPrekeyRotationSeconds - 1)
        #expect(try carol.prepareUpload(oneTimePrekeyCount: Client.oneTimePrekeyCap, pqOneTimePrekeyCount: Client.pqOneTimePrekeyCap) == nil)

        clients.clock.advance(1)
        let rotated = try #require(try carol.prepareUpload(oneTimePrekeyCount: Client.oneTimePrekeyCap, pqOneTimePrekeyCount: Client.pqOneTimePrekeyCap))
        #expect(rotated.signedPrekey.id == 2)
        #expect(rotated.oneTimePrekeys.isEmpty)
        #expect(rotated.identityDHKey == first.identityDHKey)
        try verifySignatures(rotated, of: carol)
    }
}

@Test(arguments: [(0, 100), (49, 51), (50, 0), (500, 0)])
func refillTopsUpToTheCapBelowTheThreshold(count: Int, made: Int) throws {
    try withClients { clients, _ in
        let carol = try clients.open("carol")
        #expect(oneTimePrekeyIDs(try carol.prepareUpload(oneTimePrekeyCount: count, pqOneTimePrekeyCount: Client.pqOneTimePrekeyCap)).count == made)
    }
}

@Test func heldOneTimePrekeysAreBoundedByDeletingTheLowestIDs() throws {
    try withPair { _, relay, alice, bob in
        let bundle = relay.fetch(bob.identityKey)
        #expect(bundle.oneTimePrekey?.id == 1)

        let uploads = try (0..<10).map { _ in try bob.prepareUpload(oneTimePrekeyCount: 0, pqOneTimePrekeyCount: Client.pqOneTimePrekeyCap) }

        #expect(oneTimePrekeyIDs(uploads.last!) == Array(902...1001))
        #expect(try heldOneTimePrekeyIDs(bob) == Array(2...1001))
        #expect(try heldOneTimePrekeyIDs(bob).count == Client.oneTimePrekeyHeldMax)
        let outgoing = try alice.sendText(bob.identityKey, "names a deleted key", bundle: bundle)
        #expect(try bob.receive(relay.send(alice, outgoing)).result == "UNKNOWN_ONE_TIME_PREKEY")
    }
}

@Test func unansweredUploadKeepsItsKeysAndARefusedOneDeletesThem() throws {
    try withClients { clients, _ in
        let carol = try clients.open("carol")
        let unanswered = oneTimePrekeyIDs(try carol.prepareUpload(oneTimePrekeyCount: 0, pqOneTimePrekeyCount: Client.pqOneTimePrekeyCap))
        let refusedUpload = try #require(try carol.prepareUpload(oneTimePrekeyCount: 0, pqOneTimePrekeyCount: Client.pqOneTimePrekeyCap))
        #expect(Set(unanswered).isDisjoint(with: oneTimePrekeyIDs(refusedUpload)))

        try carol.dropRefusedUpload(refusedUpload)

        #expect(try heldOneTimePrekeyIDs(carol) == unanswered.map(Int64.init))
        #expect(try carol.store.newestSignedPrekey() != nil)
    }
}

@Test func prekeyIDsAreNeverReusedAndStopAtTheLastID() throws {
    try withClients { clients, _ in
        let carol = try clients.open("carol")
        let first = try carol.makePrekeys(oneTimeCount: 2, pqOneTimeCount: 0)
        try carol.dropRefusedUpload(first)
        let second = try carol.makePrekeys(oneTimeCount: 1, pqOneTimeCount: 0)
        #expect(second.signedPrekey.id == 2)
        #expect(oneTimePrekeyIDs(second) == [3])

        let last = Int64(ClientStore.lastPrekeyID)
        try carol.store.transaction {
            try carol.store.query(
                "UPDATE identity SET last_signed_prekey_id = ?, last_one_time_prekey_id = ?",
                [.integer(last - 1), .integer(last - 1)]
            )
        }
        let atTheLast = try carol.makePrekeys(oneTimeCount: 2, pqOneTimeCount: 0)
        let afterTheLast = try carol.makePrekeys(oneTimeCount: 1, pqOneTimeCount: 0)

        #expect(atTheLast.signedPrekey.id == ClientStore.lastPrekeyID)
        #expect(oneTimePrekeyIDs(atTheLast) == [ClientStore.lastPrekeyID])
        #expect(afterTheLast.signedPrekey.id == ClientStore.lastPrekeyID)
        #expect(afterTheLast.oneTimePrekeys.isEmpty)
    }
}

@Test func seenIDCountsUntilItIsForgottenAfterItsTime() throws {
    try withPair { clients, relay, alice, bob in
        let delivered = try send(relay, alice, bob, "once")
        #expect(try bob.receive(delivered).text == "once")

        clients.clock.advance(Client.seenIDSeconds - 1)
        try bob.forgetSeenIDs()
        #expect(try bob.receive(delivered).result == "DUPLICATE")

        clients.clock.advance(1)
        #expect(try bob.receive(delivered).result == "DUPLICATE")
        try bob.forgetSeenIDs()
        let received = try bob.receive(delivered)
        #expect(received.text == nil)
        #expect(received.result == "DECRYPT_FAILED")
    }
}

@Test func replacedChainKeysAreInNoFileOfTheStore() throws {
    try withPair { clients, relay, alice, bob in
        try send(relay, alice, bob, "first")
        try relay.deliver(bob)
        let sendingChainKey = try #require(try alice.store.sessions(bob.identityKey)[0].state.cks)
        let receivingChainKey = try #require(try bob.store.sessions(alice.identityKey)[0].state.ckr)
        let aliceFolder = clients.folder.appendingPathComponent("alice")
        let bobFolder = clients.folder.appendingPathComponent("bob")
        // The store is encrypted: a live chain key is in no file either.
        #expect(try filesHolding(aliceFolder, sendingChainKey).isEmpty)
        #expect(try filesHolding(bobFolder, receivingChainKey).isEmpty)
        #expect(try alice.store.sessions(bob.identityKey)[0].state.cks == sendingChainKey)

        try send(relay, alice, bob, "second")
        try relay.deliver(bob)

        #expect(try filesHolding(aliceFolder, sendingChainKey).isEmpty)
        #expect(try filesHolding(bobFolder, receivingChainKey).isEmpty)
    }
}
