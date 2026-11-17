import Foundation
@testable import SottoCore
import Testing

@Test func draftsPinsMuteAndArchiveSurviveARestart() async throws {
    let folder = Folder()
    let directory = folder.url.appendingPathComponent("app")
    let bob = String(repeating: "ab", count: 32)
    let carol = String(repeating: "cd", count: 32)
    let dave = String(repeating: "ef", count: 32)

    let first = try Messenger(directory: directory, relay: deadRelay)
    await first.start()
    _ = try await first.createIdentity()
    for (name, id) in [("bob", bob), ("carol", carol), ("dave", dave)] {
        try await first.addContact(name: name, userID: id)
    }
    try await first.setDraft("half a\nthought", for: bob)
    try await first.setDraft("gone", for: carol)
    try await first.setDraft("  \n ", for: carol)
    try await first.setPinned(bob, true)
    try await first.setPinned(carol, true)
    try await first.setMuted(dave, true)
    try await first.setArchived(dave, true)
    await first.close()

    let second = try Messenger(directory: directory, relay: deadRelay)
    await second.start()
    func chat(_ id: String) async throws -> Chat? {
        try await second.state().chats.first { $0.userID == id }
    }
    #expect(try await chat(bob)?.draft == "half a\nthought")
    #expect(try await chat(carol)?.draft == nil)
    // The chat pinned last is on top.
    #expect(try await chat(carol)?.pinned == 0)
    #expect(try await chat(bob)?.pinned == 1)
    #expect(try await chat(dave)?.pinned == nil)
    #expect(try await chat(dave)?.muted == true)
    #expect(try await chat(dave)?.archived == true)
    #expect(try await chat(bob)?.muted == false)

    // A sent text clears the draft; archiving unpins; unmuting and unpinning stick.
    try await second.send("the whole thought", to: bob)
    #expect(try await chat(bob)?.draft == nil)
    try await second.setArchived(carol, true)
    #expect(try await chat(carol)?.pinned == nil)
    #expect(try await chat(bob)?.pinned == 0)
    try await second.setMuted(dave, false)
    try await second.setPinned(bob, false)
    try await second.setDraft("again", for: dave)
    try await second.deleteContact(dave)
    await second.close()

    let notes = Notes.load(directory)
    #expect(notes.drafts == [:])
    #expect(notes.pins == [])
    #expect(notes.muted == [])
    #expect(notes.archived == [carol])
}

@Test func olderNotesLoadWithEmptyLocalState() throws {
    let old = #"{"added":{},"read":{"x":3},"times":{},"pins":"not a list"}"#
    let notes = try JSONDecoder().decode(Notes.self, from: Data(old.utf8))
    #expect(notes.read == ["x": 3])
    #expect(notes.drafts == [:] && notes.pins == [] && notes.muted == [] && notes.archived == [])
}

@Test func aMessageBringsBackAnArchivedChatUnlessItIsMuted() {
    var notes = Notes()
    notes.archive("a", true)
    notes.archive("b", true)
    notes.mute("b", true)
    let results = [notes.arrived("a"), notes.arrived("b"), notes.arrived("c")]
    #expect(results == [true, false, false])
    #expect(notes.archived == ["b"])
}

private func state(_ chats: [Chat]) -> MessengerState {
    MessengerState(userID: nil, chats: chats, link: .connected, relay: deadRelay)
}

private func incoming(_ id: Int64, _ text: String) -> ChatMessage {
    ChatMessage(id: id, outgoing: false, text: text, date: Date(), waiting: false)
}

private func chat(_ id: String, _ messages: [ChatMessage], unread: Int = 0, muted: Bool = false) -> Chat {
    Chat(userID: id, name: id.uppercased(), added: Date(), unread: unread, messages: messages, muted: muted)
}

@Test func alertsFollowTheSettingsAndSkipTheQuietAndMutedChats() {
    let before = state([chat("a", [incoming(1, "old")]), chat("b", []), chat("m", [])])
    let after = state([
        chat("a", [incoming(1, "old"), incoming(4, "new one")], unread: 2),
        chat("b", [ChatMessage(id: -1, outgoing: true, text: "mine", date: Date(), waiting: true), incoming(5, "hi")], unread: 1),
        chat("m", [incoming(6, "shh")], unread: 1, muted: true),
    ])
    var settings = AppSettings()

    #expect(Alerts.make(old: nil, new: after, settings: settings, quietChat: nil, locked: false).isEmpty)
    let all = Alerts.make(old: before, new: after, settings: settings, quietChat: nil, locked: false)
    #expect(all == [
        Alert(chatID: "a", messageID: 4, title: "A", body: "new one", sound: true),
        Alert(chatID: "b", messageID: 5, title: "B", body: "hi", sound: true),
    ])
    #expect(Alerts.make(old: before, new: after, settings: settings, quietChat: "a", locked: false).map(\.chatID) == ["b"])
    #expect(Alerts.make(old: after, new: after, settings: settings, quietChat: nil, locked: false).isEmpty)
    let burst = state([chat("a", [incoming(1, "old"), incoming(7, "one"), incoming(8, "two")], unread: 2)])
    #expect(Alerts.make(old: before, new: burst, settings: settings, quietChat: nil, locked: false).map(\.body) == ["two"])

    settings.notificationSender = false
    settings.sound = false
    #expect(Alerts.make(old: before, new: after, settings: settings, quietChat: "b", locked: false)
        == [Alert(chatID: "a", messageID: 4, title: "Sotto", body: "new one", sound: false)])
    settings.notificationSender = true
    settings.notificationPreview = false
    #expect(Alerts.make(old: before, new: after, settings: settings, quietChat: "b", locked: false).map(\.body) == ["New message"])

    // Locked with a passcode: no contents, unless the owner chose to show them.
    settings = AppSettings()
    settings.passcode = Passcode("1234")
    let locked = Alerts.make(old: before, new: after, settings: settings, quietChat: "b", locked: true)
    #expect(locked.map(\.title) == ["Sotto"] && locked.map(\.body) == ["New message"])
    settings.hideContentsWhileLocked = false
    #expect(Alerts.make(old: before, new: after, settings: settings, quietChat: "b", locked: true).map(\.body) == ["new one"])

    settings.notifications = false
    #expect(Alerts.make(old: before, new: after, settings: settings, quietChat: nil, locked: false).isEmpty)
}

@Test func theDockBadgeCountsUnreadMessagesWithMutedChats() {
    let now = state([
        chat("a", [], unread: 2),
        chat("b", [], unread: 3),
        chat("m", [], unread: 4, muted: true),
    ])
    var settings = AppSettings()
    #expect(Alerts.badge(now, settings: settings, quietChat: nil) == 9)
    #expect(Alerts.badge(now, settings: settings, quietChat: "b") == 6)
    settings.dockBadge = false
    #expect(Alerts.badge(now, settings: settings, quietChat: nil) == 0)
}
