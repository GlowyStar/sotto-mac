import Foundation
@testable import SottoCore
import Testing

// Part 5 through the transport and a scripted relay: the events that a console or the app
// shows (section 39.5 and 39.6).

private func incoming(_ transport: Transport, _ wanted: @escaping @Sendable (Received) -> Bool) async throws -> Received {
    guard case .incoming(_, let received) = try await nextEvent(transport, {
        if case .incoming(_, let received) = $0 { wanted(received) } else { false }
    }) else {
        throw Timeout()
    }
    return received
}

@Suite(.timeLimit(.minutes(1)))
struct ChangeTransportTests {
    let folder = Folder()
    let relay = ScriptedRelay()

    @Test func twoTransportsSeeSentDeliveredReadAndAMessageDisappear() async throws {
        try befriend(folder, "alice", "bob")
        let (alice, bob) = try (folder.identityKey("alice"), folder.identityKey("bob"))
        let bobLink = try await run(folder.open("bob"), relay)
        try await until { try await isRegistered(bobLink.transport) }
        let aliceLink = try await run(folder.open("alice"), relay)

        try await bobLink.transport.setReadReceipts(false)
        try await aliceLink.transport.sendText(bob, "hello")
        guard case .written(_, let position, let text, nil, 0) = try await nextEvent(aliceLink.transport, {
            if case .written = $0 { true } else { false }
        }) else {
            Issue.record("no written event")
            return
        }
        let sent = try await nextEvent(aliceLink.transport) { if case .sent = $0 { true } else { false } }
        let shown = try await incoming(bobLink.transport) { $0.isANewMessage }
        try await bobLink.transport.markRead(alice, [#require(shown.position)])
        let delivered = try await incoming(aliceLink.transport) { !$0.marked.isEmpty }

        try await bobLink.transport.setReadReceipts(true)
        try await aliceLink.transport.sendText(bob, "again")
        let again = try await incoming(bobLink.transport) { $0.isANewMessage }
        try await bobLink.transport.markRead(alice, [#require(again.position)])
        let read = try await incoming(aliceLink.transport) { $0.read }

        try await bobLink.transport.setTimer(alice, seconds: 1)
        let timer = try await incoming(aliceLink.transport) { $0.timer != nil }
        try await aliceLink.transport.sendText(bob, "vanishing")
        guard case .written(_, let own, _, _, let expiresAfter) = try await nextEvent(aliceLink.transport, {
            if case .written = $0 { true } else { false }
        }) else {
            Issue.record("no written event")
            return
        }
        let vanishing = try await incoming(bobLink.transport) { $0.isANewMessage }
        let vanishingAtBob = try #require(vanishing.position)
        try await bobLink.transport.markRead(alice, [vanishingAtBob])
        folder.clock.advance(2)
        let goneAtAlice = try await nextEvent(aliceLink.transport) { if case .expired = $0 { true } else { false } }
        let goneAtBob = try await nextEvent(bobLink.transport) { if case .expired = $0 { true } else { false } }

        #expect(text == "hello" && sent == .sent(position: position))
        #expect(delivered.marked == [position] && !delivered.read)
        #expect(read.read && read.marked.count == 1)
        #expect(timer.timer == 1 && vanishing.expiresAfter == 1 && expiresAfter == 1)
        #expect(goneAtAlice == .expired(positions: [own]))
        #expect(goneAtBob == .expired(positions: [vanishingAtBob]))
        #expect(try await aliceLink.transport.withClient { try $0.store.message(own) } == nil)
        await aliceLink.stop()
        await bobLink.stop()
    }

    @Test func failedExpiryEndsTheRunOfTheTransport() async throws {
        let link = try await run(folder.open("alice"), relay)
        try await link.transport.withClient { try $0.store.query("DROP TABLE message_states") }

        let stopped = try await nextEvent(link.transport) { if case .stopped = $0 { true } else { false } }

        guard case .stopped(let reason) = stopped else {
            return
        }
        #expect(reason.hasPrefix("the expiry of messages failed"))
        _ = await link.task.result
    }
}
