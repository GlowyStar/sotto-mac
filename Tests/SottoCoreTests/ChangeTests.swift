import Foundation
@testable import SottoCore
import Testing

// Part 5 (sections 38 and 39) between two clients over the dictionary relay, as the
// reference tests it in tests/client/test_changes.py.

private let hour = 3600
private let marker = "part five marker 7d21"

/// A text sent and delivered; its position at the sender and at the recipient.
@discardableResult
private func say(_ relay: Relay, _ sender: Client, _ recipient: Client, _ text: String, replyTo: Int64? = nil) throws -> (Int64, Int64) {
    let bundle = try sender.hasSession(recipient.identityKey) ? nil : relay.fetch(recipient.identityKey)
    let outgoing = try sender.sendText(recipient.identityKey, text, bundle: bundle, replyTo: replyTo)
    relay.send(sender, outgoing)
    return (try #require(outgoing.position), try #require(one(relay, recipient).position))
}

private func one(_ relay: Relay, _ client: Client) throws -> Received {
    let received = try relay.deliver(client)
    try #require(received.count == 1)
    return received[0]
}

/// Seals a plaintext of the sender's choice, as a client that breaks part 5 can, and hands
/// it to the caller instead of the queue of the relay.
private func forge(_ sender: Client, _ recipient: Client, _ plaintext: Data) throws -> Delivered {
    let outgoing = try sender.send(recipient.identityKey, paddedPlaintext: plaintext, text: "forged", bundle: nil)
    return Delivered(sender: sender.identityKey, messageID: outgoing.messageID, payload: outgoing.payload)
}

@discardableResult
private func sendReceipts(_ relay: Relay, _ sender: Client) throws -> Int {
    let sent = try sender.sendOwedReceipts()
    sent.forEach { relay.send(sender, $0) }
    return sent.count
}

/// An attachment sent as if its blob were complete; its position at the sender.
private func sendFile(_ relay: Relay, _ sender: Client, _ recipient: Client, _ caption: String) throws -> Int64 {
    let upload = try sender.startUpload(
        recipient.identityKey, file: Data("the bytes of a file".utf8), blobMaxBytes: Blob.maxFileBytes,
        fileName: "notes.txt", caption: caption
    )
    let outgoing = try sender.sendAttachment(upload)
    relay.send(sender, outgoing)
    return try #require(outgoing.position)
}

private func texts(_ client: Client) throws -> [[SQLValue]] {
    try client.store.query("SELECT direction, text FROM messages ORDER BY position")
}

private func text(_ client: Client, _ position: Int64) throws -> String? {
    try client.store.message(position)?.text
}

@Test func replyCarriesAQuoteThatShowsWithoutTheOriginal() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (question, atBob) = try say(relay, alice, bob, "are you coming?")
        relay.send(bob, try bob.sendText(alice.identityKey, "yes", replyTo: atBob))
        let answered = try one(relay, alice)
        let lost = try bob.sendText(alice.identityKey, "the lost one")
        relay.send(bob, lost)
        relay.queues.removeAll()
        relay.send(bob, try bob.sendText(alice.identityKey, "about it", replyTo: lost.position))
        let unseen = try one(relay, alice)

        #expect(answered.text == "yes")
        #expect(answered.quote == Quoted(position: question, text: "are you coming?"))
        #expect(unseen.quote == Quoted(position: nil, text: "the lost one"))
        let kept = try alice.store.query(
            "SELECT quote_direction, quote_text FROM message_states WHERE quote_id IS NOT NULL ORDER BY written_at, quote_text"
        )
        #expect(kept == [[.text("out"), .text("are you coming?")], [.text("in"), .text("the lost one")]])
    }
}

@Test func replyToAMessageOfAnotherChatOrToNoneIsRefused() throws {
    try withPair(publishAlice: true) { clients, relay, alice, bob in
        let carol = try clients.open("carol")
        try relay.publish(carol)
        try befriend(alice, carol)
        let (_, atAlice) = try say(relay, carol, alice, "from carol")
        try say(relay, alice, bob, "hi")
        let outbox = try alice.outbox()

        for position in [atAlice, 999] {
            #expect(throws: ChangeError.noSuchMessage) { try alice.sendText(bob.identityKey, "answer", replyTo: position) }
        }
        #expect(try alice.outbox() == outbox)
    }
}

@Test func editReplacesTheTextAtBothSidesAndOnlyTheAuthorEdits() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (atAlice, atBob) = try say(relay, alice, bob, "see you at 7")
        let (_, bobsOwn) = try say(relay, bob, alice, "ok")
        relay.send(alice, try alice.edit(bob.identityKey, atAlice, "see you at 8"))
        let edited = try one(relay, bob)
        #expect(throws: ChangeError.notOwnMessage) { try bob.edit(alice.identityKey, atBob, "forged") }
        #expect(throws: ChangeError.noSuchMessage) { try bob.edit(alice.identityKey, bobsOwn + 100, "forged") }
        let id = try #require(try alice.store.message(atAlice)).messageID
        _ = try alice.receive(forge(bob, alice, Envelope.encodeEdit(messageID: id, text: "x")))

        #expect(edited.position == atBob && edited.text == "see you at 8" && edited.edited && !edited.isANewMessage)
        #expect(try text(alice, atAlice) == "see you at 8" && text(bob, atBob) == "see you at 8")
    }
}

@Test func editsStopAfterMaxEditsAndEditSeconds() throws {
    try withPair(publishAlice: true) { clients, relay, alice, bob in
        let (atAlice, atBob) = try say(relay, alice, bob, "draft")
        for count in 0..<Client.maxEdits {
            relay.send(alice, try alice.edit(bob.identityKey, atAlice, "draft \(count)"))
        }
        try relay.deliver(bob)
        #expect(throws: ChangeError.tooManyEdits) { try alice.edit(bob.identityKey, atAlice, "one more") }
        let id = try #require(try alice.store.message(atAlice)).messageID
        let ignored = try bob.receive(forge(alice, bob, Envelope.encodeEdit(messageID: id, text: "beyond")))
        let (later, _) = try say(relay, alice, bob, "later")
        clients.clock.advance(Client.editSeconds + 1)

        #expect(throws: ChangeError.editTooLate) { try alice.edit(bob.identityKey, later, "too late") }
        #expect(ignored.position == nil)
        #expect(try text(bob, atBob) == "draft \(Client.maxEdits - 1)")
    }
}

@Test func editOfAnAttachmentReplacesItsCaption() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        try say(relay, alice, bob, "a file follows")
        let atAlice = try sendFile(relay, alice, bob, "the plan")
        let offered = try one(relay, bob)
        relay.send(alice, try alice.edit(bob.identityKey, atAlice, "the new plan"))
        let edited = try one(relay, bob)
        #expect(throws: EnvelopeError.textTooLong) {
            try alice.edit(bob.identityKey, atAlice, String(repeating: "x", count: Envelope.maxCaptionBytes + 1))
        }

        #expect(offered.attachment?.caption == "the plan")
        #expect(edited.position == offered.position && edited.text == "the new plan")
        let file = try #require(try bob.store.files().first { $0.incoming })
        #expect(file.attachment.caption == "the new plan")
        #expect(try text(bob, #require(offered.position)) == "the new plan")
        #expect(try alice.store.files().first?.attachment.caption == "the new plan")
    }
}

@Test func deleteForBothRemovesTheMessageAndItsFileAtBothSides() throws {
    try withPair(publishAlice: true) { clients, relay, alice, bob in
        let (atAlice, atBob) = try say(relay, alice, bob, marker)
        let fileAtAlice = try sendFile(relay, alice, bob, "a caption")
        let offered = try one(relay, bob)
        let saved = clients.folder.appendingPathComponent("saved.txt")
        try Data("the bytes of a file".utf8).write(to: saved)
        let file = try #require(try bob.store.files().first { $0.incoming })
        try bob.store.transaction { try bob.store.setFileState(file.position, .received, savedAs: saved.path) }
        let secondFileAtAlice = try sendFile(relay, alice, bob, "not downloaded")
        let notDownloaded = try one(relay, bob)

        for position in [atAlice, fileAtAlice, secondFileAtAlice] {
            relay.send(alice, try alice.delete(bob.identityKey, position))
        }
        let deleted = try relay.deliver(bob)

        #expect(deleted.map(\.position) == [atBob, offered.position, notDownloaded.position])
        #expect(deleted.allSatisfy { $0.deleted })
        #expect(try texts(alice).isEmpty && texts(bob).isEmpty)
        #expect(try alice.store.files().isEmpty && bob.store.files().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: saved.path))
        #expect(try alice.blobDeletions().count == 2)
        #expect(try bob.blobDeletions().count == 1)
        for name in ["alice", "bob"] {
            #expect(try filesHolding(clients.folder.appendingPathComponent(name), Data(marker.utf8)).isEmpty)
        }
    }
}

@Test func positionOfAMessageThatIsGoneIsNeverGivenAgain() throws {
    try withPair(publishAlice: true) { clients, relay, alice, bob in
        try say(relay, alice, bob, "a session")
        let (lastAtAlice, lastAtBob) = try say(relay, alice, bob, "the last one")
        relay.send(alice, try alice.delete(bob.identityKey, lastAtAlice))
        try relay.deliver(bob)
        let (nextAtAlice, nextAtBob) = try say(relay, alice, bob, "after it")
        relay.send(alice, try alice.delete(bob.identityKey, nextAtAlice))
        try relay.deliver(bob)
        let pending = try bob.store.transaction { try bob.store.addPending(alice.identityKey, text: "p", madeAt: 0) }
        try bob.store.transaction { try bob.store.removePending(pending) }

        let bobAgain = try clients.open("bob")
        relay.send(alice, try alice.sendText(bob.identityKey, "after a restart"))
        let afterRestart = try #require(try relay.deliver(bobAgain).first?.position)
        let nextPending = try bobAgain.store.transaction { try bobAgain.store.addPending(alice.identityKey, text: "q", madeAt: 0) }

        #expect(nextAtAlice > lastAtAlice)
        #expect(nextAtBob > lastAtBob)
        #expect(afterRestart > nextAtBob)
        #expect(nextPending > pending)
    }
}

@Test func onlyTheAuthorDeletes() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (atAlice, atBob) = try say(relay, alice, bob, "mine")
        let id = try #require(try alice.store.message(atAlice)).messageID

        #expect(throws: ChangeError.notOwnMessage) { try bob.delete(alice.identityKey, atBob) }
        _ = try alice.receive(forge(bob, alice, Envelope.encodeDeletion(messageID: id)))

        #expect(try text(alice, atAlice) == "mine" && text(bob, atBob) == "mine")
    }
}

@Test func quoteOfAMessageThatIsGoneKeepsNoText() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (atAlice, atBob) = try say(relay, alice, bob, "regret")
        relay.send(bob, try bob.sendText(alice.identityKey, "noted", replyTo: atBob))
        relay.send(alice, try alice.delete(bob.identityKey, atAlice))
        let crossing = try alice.sendText(bob.identityKey, "the second")
        relay.send(alice, crossing)
        let secondAtBob = try #require(try relay.deliver(bob).last?.position)
        relay.send(bob, try bob.sendText(alice.identityKey, "too late", replyTo: secondAtBob))
        relay.send(alice, try alice.delete(bob.identityKey, #require(crossing.position)))
        let replies = try relay.deliver(alice)
        try relay.deliver(bob)

        #expect(replies.map(\.quote) == [Quoted(position: nil, text: nil), Quoted(position: nil, text: nil)])
        for client in [alice, bob] {
            let quotes = try client.store.query("SELECT quote_text FROM message_states WHERE quote_id IS NOT NULL")
            #expect(quotes == [[.null], [.null]])
        }
    }
}

@Test func deliveryReceiptMarksDeliveredThenReadAndNeverGoesBack() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (first, firstAtBob) = try say(relay, alice, bob, "first")
        let (second, secondAtBob) = try say(relay, alice, bob, "second")
        let firstID = try #require(try alice.store.message(first)).messageID
        let beforeAnyReceipt = try alice.sentPosition(firstID)

        #expect(try sendReceipts(relay, bob) == 1)
        let delivered = try one(relay, alice)
        try bob.markRead(alice.identityKey, [firstAtBob, secondAtBob])
        #expect(try sendReceipts(relay, bob) == 1)
        let read = try one(relay, alice)
        let stale = try alice.receive(forge(bob, alice, Envelope.encodeReceipt(messageIDs: [firstID], read: false)))

        #expect(beforeAnyReceipt == first)
        #expect(try alice.sentPosition(firstID) == nil)
        #expect(delivered.marked == [first, second] && !delivered.read)
        #expect(read.marked == [first, second] && read.read)
        #expect(stale.marked.isEmpty)
        #expect(try [first, second].map { try alice.store.message($0)?.receipt } == [.read, .read])
        #expect(try sendReceipts(relay, bob) == 0)
    }
}

@Test func readReceiptAloneCountsAsDelivered() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (sent, atBob) = try say(relay, alice, bob, "hi")
        try bob.markRead(alice.identityKey, [atBob])
        try sendReceipts(relay, bob)
        let read = try one(relay, alice)

        #expect(read.marked == [sent] && read.read)
    }
}

@Test func readReceiptsOffSendNoneAndThePeerSeesDelivered() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (first, firstAtBob) = try say(relay, alice, bob, "first")
        try bob.markRead(alice.identityKey, [firstAtBob])
        try bob.setReadReceipts(false)
        let (second, secondAtBob) = try say(relay, alice, bob, "second")
        try bob.markRead(alice.identityKey, [secondAtBob])
        try sendReceipts(relay, bob)
        let received = try relay.deliver(alice)

        #expect(try !bob.readReceipts())
        #expect(received.map(\.marked) == [[first, second]] && received.allSatisfy { !$0.read })
    }
}

@Test func receiptsGoOneMessagePerContactAndKindAndAreBounded() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let positions = try (0..<3).map { try say(relay, alice, bob, "text \($0)").0 }
        let (readAtAlice, readAtBob) = try say(relay, alice, bob, "read")
        try bob.markRead(alice.identityKey, [readAtBob])

        #expect(try sendReceipts(relay, bob) == 2)
        let received = try relay.deliver(alice)
        #expect(received.map(\.marked) == [positions, [readAtAlice]])
        #expect(received.map(\.read) == [false, true])

        // One id more than a receipt holds goes as two receipts.
        try bob.store.transaction {
            for index in 0...Envelope.maxReceiptIDs {
                let id = Data(String(format: "%016d", index).utf8)
                try bob.store.logMessage(alice.identityKey, direction: .incoming, messageID: id, text: "")
                try bob.store.saveState(alice.identityKey, incoming: true, messageID: id, state: NewState(writtenAt: 0, owed: .delivered))
            }
        }
        #expect(try sendReceipts(relay, bob) == 2)
    }
}

@Test func changesAreNoMessageAndGetNoReceipt() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (atAlice, _) = try say(relay, alice, bob, "hello")
        try sendReceipts(relay, bob)
        relay.send(alice, try alice.edit(bob.identityKey, atAlice, "hello!"))
        relay.send(alice, try alice.setTimer(bob.identityKey, seconds: hour))
        relay.send(alice, try alice.delete(bob.identityKey, atAlice))
        let changes = try relay.deliver(bob)
        let receipt = try one(relay, alice)

        #expect((changes + [receipt]).allSatisfy { !$0.isANewMessage })
        #expect(try texts(alice).isEmpty && texts(bob).isEmpty)
        #expect(try sendReceipts(relay, bob) == 0 && sendReceipts(relay, alice) == 0)
    }
}

@Test func receiptThatDoesNotDecryptMarksNothing() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (sent, _) = try say(relay, alice, bob, "hi")
        let outgoing = try #require(try bob.sendOwedReceipts().first)
        let receipt = relay.send(bob, outgoing)
        relay.queues.removeAll()

        let forged = try alice.receive(editEnvelope(receipt) { $0.ciphertext[$0.ciphertext.count - 1] ^= 1 })
        let genuine = try alice.receive(receipt)

        #expect(forged.result == "DECRYPT_FAILED" && forged.marked.isEmpty)
        #expect(genuine.marked == [sent])
    }
}

@Test func timerAppliesToMessagesSentAfterTheChange() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (before, _) = try say(relay, alice, bob, "before")
        relay.send(alice, try alice.setTimer(bob.identityKey, seconds: hour))
        let crossing = try bob.sendText(alice.identityKey, "crossing")
        let setAtBob = try one(relay, bob)
        relay.send(alice, try alice.sendText(bob.identityKey, "after"))
        let afterAtBob = try one(relay, bob)
        relay.send(bob, crossing)
        relay.send(bob, try bob.sendText(alice.identityKey, "answer"))
        let atAlice = try relay.deliver(alice)

        #expect(setAtBob.timer == hour)
        #expect(try alice.timer(bob.identityKey) == hour && bob.timer(alice.identityKey) == hour)
        #expect(afterAtBob.expiresAfter == hour)
        #expect(atAlice.map(\.expiresAfter) == [0, hour])
        #expect(try alice.store.message(before)?.expiresAt == nil)
        #expect(throws: EnvelopeError.badTimer) { try alice.setTimer(bob.identityKey, seconds: Envelope.maxTimerSeconds + 1) }
    }
}

@Test func timerCountsFromReadingAtTheReceiverAndFromSendingAtTheSender() throws {
    try withPair(publishAlice: true) { clients, relay, alice, bob in
        try say(relay, alice, bob, "a session")
        relay.send(alice, try alice.setTimer(bob.identityKey, seconds: 60))
        try relay.deliver(bob)
        let (atAlice, atBob) = try say(relay, alice, bob, "soon gone")
        let (unreadAtAlice, unreadAtBob) = try say(relay, alice, bob, "never read")
        clients.clock.advance(30)
        try bob.markRead(alice.identityKey, [atBob])
        clients.clock.advance(31)

        #expect(try alice.expireMessages() == [atAlice, unreadAtAlice])
        #expect(try bob.expireMessages().isEmpty)
        clients.clock.advance(30)
        #expect(try bob.expireMessages() == [atBob])
        clients.clock.advance(Int64(10 * hour))
        #expect(try bob.expireMessages().isEmpty)
        #expect(try text(bob, unreadAtBob) == "never read")
    }
}

@Test func expiredMessageGoesAfterARestartAndIsInNoFileOfTheStore() throws {
    try withPair(publishAlice: true) { clients, relay, alice, bob in
        try say(relay, alice, bob, "a session")
        relay.send(alice, try alice.setTimer(bob.identityKey, seconds: hour))
        try relay.deliver(bob)
        let (atAlice, atBob) = try say(relay, alice, bob, marker)
        relay.send(bob, try bob.sendText(alice.identityKey, "quoting", replyTo: atBob))
        try relay.deliver(alice)
        try bob.markRead(alice.identityKey, [atBob])
        clients.clock.advance(Int64(hour))

        let (aliceAgain, bobAgain) = (try clients.open("alice"), try clients.open("bob"))

        #expect(try aliceAgain.store.message(atAlice) == nil)
        #expect(try bobAgain.store.message(atBob) == nil)
        for name in ["alice", "bob"] {
            #expect(try filesHolding(clients.folder.appendingPathComponent(name), Data(marker.utf8)).isEmpty)
        }
    }
}

@Test func expiredAttachmentTakesItsFileAndItsBlob() throws {
    try withPair(publishAlice: true) { clients, relay, alice, bob in
        try say(relay, alice, bob, "files follow")
        relay.send(alice, try alice.setTimer(bob.identityKey, seconds: 60))
        try relay.deliver(bob)
        _ = try sendFile(relay, alice, bob, "kept on disk")
        let onDisk = try #require(try one(relay, bob).position)
        _ = try sendFile(relay, alice, bob, "never fetched")
        let offered = try #require(try one(relay, bob).position)
        let saved = clients.folder.appendingPathComponent("kept.txt")
        try Data("the bytes of a file".utf8).write(to: saved)
        let incoming = try bob.store.files().filter(\.incoming)
        try bob.store.transaction { try bob.store.setFileState(incoming[0].position, .received, savedAs: saved.path) }
        try bob.markRead(alice.identityKey, [onDisk, offered])
        clients.clock.advance(60)

        #expect(try bob.expireMessages() == [onDisk, offered])
        #expect(try !alice.expireMessages().isEmpty)
        #expect(try bob.store.files().isEmpty && alice.store.files().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: saved.path))
        #expect(try bob.blobDeletions().map(\.blobID) == [incoming[1].attachment.blobID])
        #expect(try alice.blobDeletions().isEmpty)
    }
}

@Test func editAndDeletionBeforeTheirMessageAreAppliedWhenItArrives() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        try say(relay, alice, bob, "a session")
        let first = try alice.sendText(bob.identityKey, "first")
        let edit = try alice.edit(bob.identityKey, #require(first.position), "first, edited")
        let second = try alice.sendText(bob.identityKey, marker)
        let deletion = try alice.delete(bob.identityKey, #require(second.position))
        for outgoing in [edit, deletion, first, second] {
            relay.send(alice, outgoing)
        }
        let received = try relay.deliver(bob)

        #expect(received[0].position == nil && received[1].position == nil)
        #expect(received[2].text == "first, edited" && received[2].isANewMessage)
        #expect(received[3].text == nil && received[3].position == nil)
        #expect(try texts(bob) == [[.text("in"), .text("a session")], [.text("in"), .text("first, edited")]])
    }
}

@Test func changesNameMessagesAcrossASessionReset() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (atAlice, atBob) = try say(relay, alice, bob, "on the first session")
        try bob.startSession(alice.identityKey, bundle: relay.fetch(alice.identityKey))
        try say(relay, bob, alice, "on a new session")
        relay.send(alice, try alice.edit(bob.identityKey, atAlice, "edited on the new one"))
        let edited = try one(relay, bob)

        #expect(try bob.store.sessions(alice.identityKey).count == 2)
        #expect(edited.position == atBob && edited.text == "edited on the new one")
    }
}

@Test func changeForAMessageThatIsGoneIsDropped() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (atAlice, atBob) = try say(relay, alice, bob, "short-lived")
        let id = try #require(try alice.store.message(atAlice)).messageID
        relay.send(alice, try alice.delete(bob.identityKey, atAlice))
        try sendReceipts(relay, bob)
        let receipt = try one(relay, alice)
        try relay.deliver(bob)

        let edited = try bob.receive(forge(alice, bob, Envelope.encodeEdit(messageID: id, text: "x")))

        #expect(receipt.marked.isEmpty)
        #expect(edited.position == nil)
        #expect(try bob.store.message(atBob) == nil)
    }
}

@Test func tracesAreForgottenWithTheSeenIDs() throws {
    try withPair(publishAlice: true) { clients, relay, alice, bob in
        try say(relay, alice, bob, "a session")
        let never = try alice.sendText(bob.identityKey, "never arrives")
        relay.send(alice, try alice.delete(bob.identityKey, #require(never.position)))
        try relay.deliver(bob)
        let traces = "SELECT count(*) FROM message_states WHERE gone = 1"
        #expect(try bob.store.query(traces) == [[.integer(1)]])

        clients.clock.advance(Client.seenIDSeconds)
        try bob.forgetSeenIDs()

        #expect(try bob.store.query(traces) == [[.integer(0)]])
    }
}

@Test func storeOfThePreviousVersionOpensAndTakesPart5() throws {
    try withPair(publishAlice: true) { clients, relay, alice, bob in
        let (atAlice, atBob) = try say(relay, alice, bob, "from before")
        let (ownAtBob, _) = try say(relay, bob, alice, "also from before")
        try bob.store.transaction {
            for table in ["message_states", "timers", "settings", "row_numbers", "pending_replies"] {
                try bob.store.query("DROP TABLE \(table)")
            }
            try bob.store.query("DROP INDEX messages_by_id")
        }
        bob.store.close()

        let reopened = try clients.open("bob")
        relay.send(alice, try alice.delete(bob.identityKey, atAlice))
        try sendReceipts(relay, alice)
        let received = try relay.deliver(reopened)

        #expect(received.map(\.deleted) == [true, false])
        #expect(received[0].position == atBob && received[1].marked.isEmpty)
        #expect(try reopened.readReceipts() && reopened.timer(alice.identityKey) == 0)
        #expect(try texts(reopened) == [[.text("out"), .text("also from before")]])
        #expect(throws: ChangeError.editTooLate) { try reopened.edit(alice.identityKey, ownAtBob, "now") }
    }
}

@Test func deleteForMeLeavesATraceThatDropsALaterEdit() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (atAlice, atBob) = try say(relay, alice, bob, "kept at alice")
        try bob.store.transaction { try bob.deleteMessage(atBob) }
        relay.send(alice, try alice.edit(bob.identityKey, atAlice, "edited"))
        let edited = try one(relay, bob)

        #expect(edited.position == nil)
        #expect(try texts(bob).isEmpty)
        #expect(try text(alice, atAlice) == "edited")
    }
}

@Test func replyWithAFileCarriesItsQuoteAndTheTimerOfItsSend() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let (_, question) = try say(relay, bob, alice, "send me the plan")
        let upload = try alice.startUpload(
            bob.identityKey, file: Data("plan".utf8), blobMaxBytes: Blob.maxFileBytes, fileName: "plan.txt", replyTo: question
        )
        relay.send(alice, try alice.setTimer(bob.identityKey, seconds: hour))
        let sent = try alice.sendAttachment(upload)
        relay.send(alice, sent)
        let received = try relay.deliver(bob)

        #expect(received[0].timer == hour)
        #expect(received[1].attachment != nil && received[1].expiresAfter == hour)
        #expect(received[1].quote?.text == "send me the plan" && received[1].quote?.position != nil)
        let position = try #require(sent.position)
        let state = try #require(try alice.store.message(position))
        #expect(state.expiresAfter == hour && state.expiresAt == state.writtenAt.map { $0 + Int64(hour) })
    }
}

@Test func counterOfAStoreBeforeItStartsAtItsHighestRows() throws {
    try withClients { clients, _ in
        let directory = clients.folder.appendingPathComponent("old")
        let contact = Data(repeating: 3, count: 32)
        var store = try ClientStore(directory: directory)
        let newest = try store.transaction {
            try store.addContact(contact, name: "c")
            _ = try store.logMessage(contact, direction: .incoming, messageID: Data(repeating: 1, count: 16), text: "first")
            let newest = try store.logMessage(contact, direction: .incoming, messageID: Data(repeating: 2, count: 16), text: "newest")
            let pending = try store.addPending(contact, text: "waits", madeAt: 0)
            try store.query("DROP TABLE row_numbers")
            return (newest, pending)
        }
        store.close()

        store = try ClientStore(directory: directory)
        try store.transaction {
            try store.removeMessage(try #require(try store.message(newest.0)), at: 0)
            try store.removePending(newest.1)
        }
        let next = try store.transaction {
            (try store.logMessage(contact, direction: .incoming, messageID: Data(repeating: 4, count: 16), text: "next"),
             try store.addPending(contact, text: "next", madeAt: 0))
        }
        store.close()

        #expect(next.0 > newest.0)
        #expect(next.1 > newest.1)
    }
}
