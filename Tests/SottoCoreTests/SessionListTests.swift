import Foundation
@testable import SottoCore
import Testing

private func headSessionData(_ client: Client, _ contact: Client) throws -> Data {
    try client.store.sessions(contact.identityKey)[0].associatedData
}

private func sessionData(_ client: Client, _ contact: Client) throws -> Set<Data> {
    Set(try client.store.sessions(contact.identityKey).map(\.associatedData))
}

private func reset(_ relay: Relay, _ client: Client, _ contact: Client) throws -> Int {
    try relay.publish(contact)
    return try client.startSession(contact.identityKey, bundle: relay.fetch(contact.identityKey))
}

@Test func bothSidesStartingAtOnceSendAndReceiveInBothDirections() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        try send(relay, alice, bob, "alice starts")
        try send(relay, bob, alice, "bob starts")

        #expect(try texts(relay.deliver(bob)) == ["alice starts"])
        #expect(try texts(relay.deliver(alice)) == ["bob starts"])
        #expect(try alice.store.sessions(bob.identityKey).count == 2)
        #expect(try sessionData(alice, bob) == sessionData(bob, alice))

        for number in 0..<3 {
            try send(relay, alice, bob, "crossing to bob \(number)")
            try send(relay, bob, alice, "crossing to alice \(number)")
            #expect(try texts(relay.deliver(bob)) == ["crossing to bob \(number)"])
            #expect(try texts(relay.deliver(alice)) == ["crossing to alice \(number)"])
        }

        try send(relay, alice, bob, "alone to bob")
        #expect(try texts(relay.deliver(bob)) == ["alone to bob"])
        try send(relay, bob, alice, "alone to alice")
        #expect(try texts(relay.deliver(alice)) == ["alone to alice"])
        #expect(try headSessionData(alice, bob) == headSessionData(bob, alice))
    }
}

@Test func fourthSessionDropsTheOldestAndReportsItsMissingMessages() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let lost = try send(relay, alice, bob, "lost on the first session")
        let first = try send(relay, alice, bob, "first session")
        #expect(try bob.receive(first).text == "first session")

        var received: [Received] = []
        for number in 0..<ClientStore.maxSessions {
            #expect(try reset(relay, alice, bob) == 0)
            received.append(try bob.receive(send(relay, alice, bob, "session \(number + 2)")))
        }

        #expect(texts(received) == ["session 2", "session 3", "session 4"])
        #expect(received.map(\.missing) == [0, 0, 1])
        #expect(try bob.store.sessions(alice.identityKey).count == ClientStore.maxSessions)
        #expect(try alice.store.sessions(bob.identityKey).count == ClientStore.maxSessions)
        #expect(try sessionData(alice, bob) == sessionData(bob, alice))
        #expect(try bob.receive(lost).result == "REPLAYED_INITIAL")
    }
}

@Test func resetKeepsTheOlderSessionsAndSendsOnTheNewOne() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        try send(relay, alice, bob, "before the reset")
        try relay.deliver(bob)
        try send(relay, bob, alice, "reply")
        try relay.deliver(alice)
        let onTheWay = try send(relay, alice, bob, "on the way")

        _ = try reset(relay, alice, bob)
        let afterReset = try send(relay, alice, bob, "after the reset")

        #expect(try initialHeader(of: onTheWay) == nil)
        #expect(try initialHeader(of: afterReset) != nil)
        #expect(try texts(relay.deliver(bob)) == ["on the way", "after the reset"])
        #expect(try bob.store.sessions(alice.identityKey).count == 2)
    }
}

@Test func purgedSkippedKeysAreReportedAsMissing() throws {
    try withPair(publishAlice: true) { _, relay, alice, bob in
        let skipped = try send(relay, alice, bob, "skipped")
        #expect(try bob.receive(send(relay, alice, bob, "arrives")).text == "arrives")

        var missing: [Int] = []
        for number in 0...Int(Ratchet.skippedKeySteps) {
            try send(relay, bob, alice, "to alice \(number)")
            try relay.deliver(alice)
            let received = try bob.receive(send(relay, alice, bob, "to bob \(number)"))
            #expect(received.text == "to bob \(number)")
            missing.append(received.missing)
        }

        #expect(missing.reduce(0, +) == 1)
        #expect(try bob.receive(skipped).result == "DECRYPT_FAILED")
    }
}
