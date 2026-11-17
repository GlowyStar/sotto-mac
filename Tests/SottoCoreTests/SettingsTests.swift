import Foundation
@testable import SottoCore
import Testing

@Test func everySettingSurvivesARestart() async throws {
    let folder = Folder()
    let directory = folder.url.appendingPathComponent("app")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try Notes(read: ["x": 3]).save(directory)
    let first = try Messenger(directory: directory, relay: deadRelay)
    #expect(first.launchSettings == nil)
    await first.start()

    var changed = AppSettings()
    changed.notifications = false
    changed.notificationSender = false
    changed.notificationPreview = false
    changed.sound = false
    changed.dockBadge = false
    changed.theme = .dark
    changed.textSize = 17
    changed.background = .rose
    changed.sendWithCommandEnter = true
    changed.clock24 = false
    changed.autoDownloadPhotos = 0
    changed.autoDownloadFiles = 50
    changed.downloadFolder = "/tmp/sotto-downloads"
    changed.askWhereToSave = true
    changed.passcode = Passcode("1234")
    changed.autoLockMinutes = 5
    changed.lockOnSleep = false
    changed.hideContentsWhileLocked = false
    // Every stored property differs from its default, so a field left out of the coding
    // keys or the decoder fails here.
    let defaults = Mirror(reflecting: AppSettings()).children.map { String(describing: $0.value) }
    let values = Mirror(reflecting: changed).children.map { String(describing: $0.value) }
    #expect(zip(defaults, values).allSatisfy { $0 != $1 })
    #expect(values.count == AppSettings.CodingKeys.allCases.count)

    try await first.saveSettings(changed)
    try await first.setRelay("wss://relay.example.org/ws")
    await first.close()

    let second = try Messenger(directory: directory, relay: deadRelay)
    #expect(second.launchSettings == changed)
    #expect(await second.relay == "wss://relay.example.org/ws")
    #expect(second.launchSettings?.passcode?.matches("1234") == true)
    #expect(second.launchSettings?.passcode?.matches("12345") == false)
    #expect(Notes.load(directory).read == ["x": 3])
}

@Test func missingAndUnknownSettingsTakeTheirDefaults() throws {
    let old = #"{"added":{},"read":{"x":3},"times":{}}"#
    let notes = try JSONDecoder().decode(Notes.self, from: Data(old.utf8))
    #expect(notes.read == ["x": 3])
    #expect(notes.settings == nil)

    let partial = #"{"theme":"dark","textSize":99,"background":"neon","sound":"loud"}"#
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(partial.utf8))
    var expected = AppSettings()
    expected.theme = .dark
    expected.textSize = AppSettings.textSizes.upperBound
    #expect(settings == expected)
}

@Test func aPasscodeIsSaltedAndChecked() {
    let one = Passcode("secret")
    let two = Passcode("secret")
    #expect(one.salt != two.salt)
    #expect(one.code != two.code)
    #expect(one.matches("secret") && two.matches("secret"))
    #expect(!one.matches("Secret"))
}

@Test func eraseDeletesTheStoreAndKeepsForeignFiles() async throws {
    let folder = Folder()
    let directory = folder.url.appendingPathComponent("app")
    let messenger = try Messenger(directory: directory, relay: deadRelay)
    await messenger.start()
    _ = try await messenger.createIdentity()
    try await messenger.saveSettings(AppSettings())
    await messenger.close()
    let foreign = directory.appendingPathComponent("keep.txt")
    try Data("mine".utf8).write(to: foreign)

    try Messenger.erase(directory: directory)
    #expect(FileManager.default.fileExists(atPath: foreign.path))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(ClientStore.fileName).path))
    let reopened = try Messenger(directory: directory, relay: deadRelay)
    #expect(!reopened.hadIdentity)
    #expect(reopened.launchSettings == nil)

    try FileManager.default.removeItem(at: foreign)
    try Messenger.erase(directory: directory)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}
