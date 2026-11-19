import AppKit
import SottoCore
import SwiftUI

/// `--snapshot <folder>`: draws the window content for a fixed set of states into PNG files at
/// 2x, offscreen and without showing a window, then exits (0 when every file was written).
/// With `--data-dir` the states come from that store, read without a connection; without it,
/// from the mock data. `--only PREFIX` draws only the shots whose name starts with it. `--dump`
/// with `--data-dir` prints the state of the store as JSON.
@MainActor
enum Snapshot {
    private struct Shot {
        let name: String
        var size = CGSize(width: 900, height: 640)
        var dark = false
        let setUp: (AppModel) -> Void
    }

    private static func open(_ model: AppModel, _ name: String) {
        if let contact = model.contacts.first(where: { $0.name == name }) { model.openChat(contact.id) }
    }

    private static func photos(_ model: AppModel) { open(model, "Vera Lindqvist") }
    private static func files(_ model: AppModel) { open(model, "Leo Fischer") }

    private static func view(_ model: AppModel, _ messageID: String) {
        photos(model)
        model.viewer = ViewerItem(chatID: model.openChatID ?? "", messageID: messageID)
    }

    private static func openRich(_ model: AppModel) {
        if let anna = model.contacts.first(where: { $0.name == "Anna Petrova" }) { model.openChat(anna.id) }
    }

    private static let shots: [Shot] = [
        Shot(name: "main-light") { openRich($0) },
        Shot(name: "main-dark", dark: true) {
            openRich($0)
            $0.connection = .connecting
        },
        Shot(name: "empty") { _ in },
        Shot(name: "long-light") { model in
            if let sam = model.contacts.first(where: { $0.name == "Sam Carter" }) { model.openChat(sam.id) }
        },
        Shot(name: "narrow-chat", size: CGSize(width: 380, height: 600)) { openRich($0) },
        Shot(name: "narrow-list", size: CGSize(width: 380, height: 600), dark: true) { _ in },
        Shot(name: "first-launch") { $0.welcome = .start },
        Shot(name: "my-id") { $0.modal = .myID },
        Shot(name: "add-contact") { $0.modal = .addContact },
        Shot(name: "contact-panel", size: CGSize(width: 1100, height: 640)) { model in
            openRich(model)
            model.panelOpen = true
        },
        Shot(name: "contact-box", dark: true) { model in
            openRich(model)
            model.modal = .contactInfo(model.openChatID ?? "")
        },
        Shot(name: "settings") { $0.openSettings() },
        Shot(name: "settings-dark", dark: true) { $0.openSettings() },
        Shot(name: "settings-narrow", size: CGSize(width: 380, height: 600)) { $0.openSettings() },
        Shot(name: "settings-notifications") { page($0, .notifications) },
        Shot(name: "settings-notifications-on", dark: true) { model in
            model.settings.notificationSender = true
            model.settings.notificationPreview = true
            page(model, .notifications)
        },
        Shot(name: "settings-chats", size: CGSize(width: 900, height: 1180)) { page($0, .chats) },
        Shot(name: "settings-chats-dark", size: CGSize(width: 900, height: 1180), dark: true) { model in
            model.settings.textSize = 17
            model.settings.background = .mist
            model.settings.sendWithCommandEnter = true
            model.settings.clock24 = false
            page(model, .chats)
        },
        Shot(name: "settings-data", size: CGSize(width: 900, height: 980)) { page($0, .data) },
        Shot(name: "settings-data-dark", size: CGSize(width: 900, height: 980), dark: true) { model in
            model.settings.saveReceivedFiles = true
            page(model, .data)
        },
        Shot(name: "settings-privacy") { page($0, .privacy) },
        Shot(name: "settings-privacy-on") { model in
            model.settings.passcode = Passcode("1234")
            page(model, .privacy)
        },
        Shot(name: "settings-connection") { model in
            model.connection = .connecting
            page(model, .connection)
        },
        Shot(name: "settings-advanced", dark: true) { page($0, .advanced) },
        Shot(name: "settings-passcode") { model in
            page(model, .privacy)
            model.settingsDialog = .passcode
        },
        Shot(name: "settings-autolock", dark: true) { model in
            model.settings.passcode = Passcode("1234")
            page(model, .privacy)
            model.settingsDialog = .autoLock
        },
        Shot(name: "settings-reset") { model in
            page(model, .advanced)
            model.settingsDialog = .reset
        },
        Shot(name: "lock-screen") { model in
            model.settings.passcode = Passcode("1234")
            model.lock()
        },
        Shot(name: "store-locked") { $0.storeLocked = true },
        Shot(name: "store-locked-dark", dark: true) { model in
            model.storeLocked = true
            model.unlockFailure = "The Secure Enclave did not open the store key."
        },
        Shot(name: "main-custom") { model in
            model.settings.textSize = 16
            model.settings.background = .sand
            model.settings.clock24 = false
            openRich(model)
        },
        Shot(name: "main-custom-dark", dark: true) { model in
            model.settings.background = .rose
            openRich(model)
        },
        // SOTTO-36: list marks, archive, search, notifications refused.
        Shot(name: "list-marks", size: CGSize(width: 900, height: 900)) { _ in },
        Shot(name: "list-marks-dark", size: CGSize(width: 900, height: 900), dark: true) { model in
            if let lena = model.contacts.first(where: { $0.name == "Lena Smirnova" }) { model.openChat(lena.id) }
        },
        Shot(name: "archive") { $0.archiveOpen = true },
        Shot(name: "search-messages", size: CGSize(width: 900, height: 900)) { $0.search = "an" },
        Shot(name: "search-messages-dark", dark: true) { $0.search = "сообщение номер 1" },
        Shot(name: "chat-search") { model in
            openRich(model)
            model.chatSearch = "да"
            model.stepChatSearch(0)
        },
        Shot(name: "chat-search-dark", dark: true) { model in
            openRich(model)
            model.chatSearch = "nothing like this"
        },
        Shot(name: "chat-draft") { model in
            if let tom = model.contacts.first(where: { $0.name == "Tom Becker" }) { model.openChat(tom.id) }
        },
        Shot(name: "settings-notifications-denied") { model in
            model.notificationsDenied = true
            page(model, .notifications)
        },
        // SOTTO-32: photos and files in every state, attaching, the viewer.
        Shot(name: "media-photos", size: CGSize(width: 900, height: 2300)) { photos($0) },
        Shot(name: "media-photos-dark", size: CGSize(width: 900, height: 2300), dark: true) { photos($0) },
        Shot(name: "media-files", size: CGSize(width: 900, height: 1000)) { files($0) },
        Shot(name: "media-files-dark", size: CGSize(width: 900, height: 1000), dark: true) { files($0) },
        Shot(name: "media-offline", size: CGSize(width: 900, height: 1000)) { model in
            files(model)
            model.connection = .connecting
        },
        Shot(name: "media-offline-dark", dark: true) { model in
            photos(model)
            model.connection = .connecting
        },
        Shot(name: "media-narrow", size: CGSize(width: 380, height: 700)) { photos($0) },
        Shot(name: "attach-menu") { model in
            files(model)
            model.attachMenuOpen = true
        },
        Shot(name: "attach-menu-dark", dark: true) { model in
            photos(model)
            model.attachMenuOpen = true
        },
        Shot(name: "send-photo", size: CGSize(width: 900, height: 700)) { model in
            photos(model)
            model.stage([MockData.picture("dusk.jpg", width: 1200, height: 900, hue: 0.02)])
        },
        Shot(name: "send-photo-as-file-dark", dark: true) { model in
            photos(model)
            model.stage([MockData.picture("dusk.jpg", width: 1200, height: 900, hue: 0.02)])
            model.sendAsFile = true
        },
        Shot(name: "send-file") { model in
            files(model)
            model.stage([MockData.document("Quarterly report.pdf")])
        },
        Shot(name: "send-files", size: CGSize(width: 900, height: 700)) { model in
            files(model)
            model.stage([
                MockData.document("Report Q3.pdf"), MockData.picture("lake.jpg", width: 1600, height: 1067, hue: 0.55),
                MockData.document("notes.txt"), MockData.sparse("Disk image.dmg", size: 120_000_000),
                MockData.sparse("empty.txt", size: 0),
            ])
        },
        Shot(name: "send-files-dark", size: CGSize(width: 900, height: 700), dark: true) { model in
            files(model)
            model.stage([MockData.document("Report Q3.pdf"), MockData.document("Contract.docx")])
        },
        Shot(name: "drop") { model in
            files(model)
            model.drop = DropState(pictures: false, hover: .photos)
        },
        Shot(name: "drop-photos-dark", dark: true) { model in
            photos(model)
            model.drop = DropState(pictures: true, hover: .photos)
        },
        Shot(name: "drop-photos-files", size: CGSize(width: 900, height: 400)) { model in
            photos(model)
            model.drop = DropState(pictures: true, hover: .files)
        },
        Shot(name: "viewer") { view($0, "vera-1") },
        Shot(name: "viewer-caption-dark", dark: true) { view($0, "vera-2") },
        Shot(name: "viewer-loading") { view($0, "vera-4") },
        // SOTTO-34: the profile and the avatars with a photo.
        Shot(name: "profile-settings") { $0.openSettings() },
        Shot(name: "profile-settings-dark", dark: true) { $0.openSettings() },
        Shot(name: "profile-settings-empty") { model in
            model.profile = UserProfile()
            model.openSettings()
        },
        Shot(name: "profile-settings-empty-dark", dark: true) { model in
            model.profile = UserProfile()
            model.openSettings()
        },
        Shot(name: "profile-edit", size: CGSize(width: 900, height: 900)) { editProfile($0) },
        Shot(name: "profile-edit-dark", size: CGSize(width: 900, height: 900), dark: true) { editProfile($0) },
        Shot(name: "profile-edit-changed", size: CGSize(width: 900, height: 900)) { changedProfile($0) },
        Shot(name: "profile-edit-changed-dark", size: CGSize(width: 900, height: 900), dark: true) { changedProfile($0) },
        Shot(name: "profile-discard") { model in
            changedProfile(model)
            model.settingsDialog = .discardProfile
        },
        Shot(name: "profile-discard-dark", dark: true) { model in
            changedProfile(model)
            model.settingsDialog = .discardProfile
        },
        Shot(name: "profile-crop", size: CGSize(width: 900, height: 700)) { crop($0) },
        Shot(name: "profile-crop-dark", size: CGSize(width: 900, height: 700), dark: true) { crop($0) },
        Shot(name: "profile-qr", size: CGSize(width: 900, height: 700)) { model in
            model.openSettings()
            model.settingsDialog = .qrCode
        },
        Shot(name: "profile-qr-dark", size: CGSize(width: 900, height: 700), dark: true) { model in
            editProfile(model)
            model.settingsDialog = .qrCode
        },
        Shot(name: "profile-my-id") { $0.modal = .myID },
        Shot(name: "profile-my-id-dark", dark: true) { $0.modal = .myID },
        Shot(name: "avatars-chat", size: CGSize(width: 1100, height: 700)) { model in
            openRich(model)
            model.panelOpen = true
        },
        Shot(name: "avatars-chat-dark", size: CGSize(width: 1100, height: 700), dark: true) { model in
            openRich(model)
            model.panelOpen = true
        },
        Shot(name: "avatars-photos", size: CGSize(width: 900, height: 900)) { photos($0) },
        Shot(name: "avatars-photos-dark", size: CGSize(width: 900, height: 900), dark: true) { model in
            if let max = model.contacts.first(where: { $0.name == "Max Turner" }) { model.openChat(max.id) }
        },
        Shot(name: "avatars-viewer") { model in
            openRich(model)
            model.avatarViewer = model.openChat?.profile?.avatar
        },
        Shot(name: "avatars-viewer-dark", dark: true) { model in
            photos(model)
            model.avatarViewer = model.openChat?.profile?.avatar
        },
        // SOTTO-40: replies, edits, the marks of part 5, delete for both and the timer.
        Shot(name: "changes-chat", size: CGSize(width: 900, height: 980)) { nora($0) },
        Shot(name: "changes-chat-dark", size: CGSize(width: 900, height: 980), dark: true) { nora($0) },
        Shot(name: "changes-reply") { model in
            nora(model)
            model.startReply("nora-7", in: model.openChatID ?? "")
        },
        Shot(name: "changes-reply-dark", dark: true) { model in
            nora(model)
            model.startReply("nora-9", in: model.openChatID ?? "")
        },
        Shot(name: "changes-edit") { model in
            nora(model)
            model.startEdit("nora-9", in: model.openChatID ?? "")
        },
        Shot(name: "changes-edit-dark", dark: true) { model in
            nora(model)
            model.startEdit("nora-9", in: model.openChatID ?? "")
        },
        Shot(name: "changes-delete-own") { model in
            nora(model)
            model.modal = .deleteMessage(model.openChatID ?? "", "nora-9")
        },
        Shot(name: "changes-delete-own-dark", dark: true) { model in
            nora(model)
            model.modal = .deleteMessage(model.openChatID ?? "", "nora-9")
        },
        Shot(name: "changes-delete-incoming") { model in
            nora(model)
            model.modal = .deleteMessage(model.openChatID ?? "", "nora-7")
        },
        Shot(name: "changes-delete-incoming-dark", dark: true) { model in
            nora(model)
            model.modal = .deleteMessage(model.openChatID ?? "", "nora-7")
        },
        Shot(name: "changes-timer-box", size: CGSize(width: 900, height: 700)) { model in
            nora(model)
            model.modal = .timer(model.openChatID ?? "")
        },
        Shot(name: "changes-timer-box-dark", size: CGSize(width: 900, height: 700), dark: true) { model in
            nora(model)
            model.modal = .timer(model.openChatID ?? "")
        },
        Shot(name: "changes-panel", size: CGSize(width: 1100, height: 700)) { model in
            nora(model)
            model.panelOpen = true
        },
        Shot(name: "changes-panel-dark", size: CGSize(width: 1100, height: 700), dark: true) { model in
            nora(model)
            model.panelOpen = true
        },
        Shot(name: "changes-media", size: CGSize(width: 900, height: 2400)) { photos($0) },
        Shot(name: "changes-media-dark", size: CGSize(width: 900, height: 2400), dark: true) { photos($0) },
        Shot(name: "changes-files", size: CGSize(width: 900, height: 1100)) { files($0) },
        Shot(name: "changes-files-dark", size: CGSize(width: 900, height: 1100), dark: true) { files($0) },
        Shot(name: "changes-privacy", size: CGSize(width: 900, height: 760)) { model in
            model.readReceipts = false
            page(model, .privacy)
        },
        Shot(name: "changes-privacy-dark", size: CGSize(width: 900, height: 760), dark: true) { page($0, .privacy) },
        Shot(name: "changes-narrow", size: CGSize(width: 380, height: 700)) { model in
            nora(model)
            model.startReply("nora-3", in: model.openChatID ?? "")
        },
        Shot(name: "changes-narrow-dark", size: CGSize(width: 380, height: 700), dark: true) { model in
            nora(model)
            model.startEdit("nora-8", in: model.openChatID ?? "")
        },
        // SOTTO-47: the safety number row of the panel, the verify box, the verified mark and
        // the warning of a refused key.
        Shot(name: "verify-panel", size: CGSize(width: 1100, height: 900)) { model in
            openRich(model)
            model.panelOpen = true
        },
        Shot(name: "verify-panel-dark", size: CGSize(width: 1100, height: 900), dark: true) { model in
            openRich(model)
            model.panelOpen = true
        },
        Shot(name: "verify-box", size: CGSize(width: 900, height: 760)) { model in
            nora(model)
            model.modal = .verify(model.openChatID ?? "")
        },
        Shot(name: "verify-box-dark", size: CGSize(width: 900, height: 760), dark: true) { model in
            openRich(model)
            model.modal = .verify(model.openChatID ?? "")
        },
        Shot(name: "verify-box-low", size: CGSize(width: 600, height: 480)) { model in
            nora(model)
            model.modal = .verify(model.openChatID ?? "")
        },
        Shot(name: "verify-warning") { maxTurner($0) },
        Shot(name: "verify-warning-dark", dark: true) { maxTurner($0) },
        Shot(name: "verify-warning-narrow", size: CGSize(width: 380, height: 700)) { maxTurner($0) },
        Shot(name: "verify-warning-unverified", dark: true) { model in
            maxTurner(model)
            model.setVerified(false, model.openChatID ?? "")
        },
        // SOTTO-25: a selection in an incoming and an outgoing bubble, a link under the pointer.
        Shot(name: "text-selection") { select($0) },
        Shot(name: "text-selection-dark", dark: true) { select($0) },
        Shot(name: "text-link-hover", size: CGSize(width: 900, height: 760)) { hoverLink($0) },
        Shot(name: "text-link-hover-dark", size: CGSize(width: 900, height: 760), dark: true) { hoverLink($0) },
    ]

    private static func select(_ model: AppModel) {
        openRich(model)
        BubbleTextView.staged = [
            "Only I might be a few minutes late, the train is slow today 🚆": (NSRange(location: 5, length: 28), false),
            "Прочитал. В целом хорошо, но третий раздел я бы сократил вдвое: там повторяется то, что уже сказано во введении, и теряется главная мысль про ключи на устройстве.":
                (NSRange(location: 18, length: 70), false),
        ]
    }

    private static func hoverLink(_ model: AppModel) {
        openRich(model)
        BubbleTextView.staged = ["https://example.com/drafts/sotto-notes": (NSRange(location: 0, length: 0), true)]
    }

    private static func nora(_ model: AppModel) { open(model, "Nora Weiss") }

    private static func maxTurner(_ model: AppModel) { open(model, "Max Turner") }

    private static func editProfile(_ model: AppModel) {
        model.openSettings()
        model.openProfile()
    }

    private static func changedProfile(_ model: AppModel) {
        editProfile(model)
        model.profileDraft?.name = "Alexandra Morgan-Whitfield of the Northern Isles, Esq."
        model.profileDraft?.avatar = nil
    }

    private static func crop(_ model: AppModel) {
        editProfile(model)
        model.cropSource = MockData.cropPicture().map(CropSource.init)
        model.settingsDialog = .crop
    }

    private static func page(_ model: AppModel, _ page: SettingsPage) {
        model.openSettings()
        model.settingsPage = page
    }

    /// The pictures of a real store: the list, and the chat of the latest activity opened.
    private static let realShots: [Shot] = [
        Shot(name: "real-list") { _ in },
        Shot(name: "real-chat") { model in
            if let latest = model.sortedContacts.first { model.openChat(latest.id) }
        },
        Shot(name: "real-chat-dark", dark: true) { model in
            if let latest = model.sortedContacts.first { model.openChat(latest.id) }
        },
    ]

    static func runFromArguments() {
        let launch = Launch.current
        if let directory = launch.dataDirectory,
            launch.dump || launch.snapshot != nil || launch.storeInfo || launch.safetyNumberOf != nil
        {
            do {
                try StoreKeys.unlock(directory, protection: StoreProtection.asked(for: directory))
            } catch {
                FileHandle.standardError.write(Data("the store does not open: \(error)\n".utf8))
                exit(1)
            }
        }
        if let name = launch.safetyNumberOf {
            guard let directory = launch.dataDirectory else { exit(2) }
            do {
                let model = AppModel(mock: false)
                model.apply(try Messenger.peek(directory: directory, relay: launch.relay))
                guard let contact = model.contacts.first(where: { $0.name == name }),
                    let number = model.safetyNumber(contact.id)
                else {
                    FileHandle.standardError.write(Data("no contact named \(name)\n".utf8))
                    exit(1)
                }
                // The rows of the contact panel, then the text of the code of the verify box.
                let rows = IDBlock.lines(number.digits, group: SafetyNumber.groupDigits)
                FileHandle.standardOutput.write(Data((rows + ["qr payload: \(number.qrPayload)"]).joined(separator: "\n").utf8 + [10]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("safety number failed: \(error)\n".utf8))
                exit(1)
            }
        }
        if launch.storeInfo {
            guard let directory = launch.dataDirectory else { exit(2) }
            do {
                let store = try ClientStore(directory: directory)
                let info = [
                    "cipherVersion": try store.cipherVersion(), "cipherProvider": try store.cipherProvider(),
                    "library": ClientStore.servingLibrary,
                ]
                store.close()
                let json = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
                FileHandle.standardOutput.write(json + Data("\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("store info failed: \(error)\n".utf8))
                exit(1)
            }
        }
        if launch.dump {
            guard let directory = launch.dataDirectory else { exit(2) }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .millisecondsSince1970
                let json = try encoder.encode(Messenger.peek(directory: directory, relay: launch.relay))
                FileHandle.standardOutput.write(json + Data("\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("dump failed: \(error)\n".utf8))
                exit(1)
            }
        }
        guard let folder = launch.snapshot else {
            if CommandLine.arguments.contains("--snapshot") { exit(2) }
            return
        }
        var shots = shots
        var makeModel = { AppModel() }
        if let directory = launch.dataDirectory {
            do {
                let state = try Messenger.peek(directory: directory, relay: launch.relay)
                shots = realShots
                makeModel = {
                    let model = AppModel(mock: false)
                    model.apply(state)
                    if state.userID == nil { model.welcome = .start }
                    return model
                }
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--only"), index + 1 < CommandLine.arguments.count {
            shots = shots.filter { $0.name.hasPrefix(CommandLine.arguments[index + 1]) }
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var failed = false
        for shot in shots {
            if !render(shot, model: makeModel(), to: folder.appendingPathComponent(shot.name + ".png")) {
                FileHandle.standardError.write(Data("snapshot failed: \(shot.name)\n".utf8))
                failed = true
            }
        }
        exit(failed ? 1 : 0)
    }

    private static func render(_ shot: Shot, model: AppModel, to url: URL) -> Bool {
        BubbleTextView.staged = [:]
        shot.setUp(model)
        let view = NSHostingView(rootView: RootView(model: model))
        view.appearance = NSAppearance(named: shot.dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: shot.size), styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = view.appearance
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        view.layoutSubtreeIfNeeded()
        let pixels = (Int(shot.size.width) * 2, Int(shot.size.height) * 2)
        guard
            let picture = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels.0, pixelsHigh: pixels.1, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        picture.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: picture)
        window.close()
        guard let png = picture.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
