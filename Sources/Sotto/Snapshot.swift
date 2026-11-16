import AppKit
import SottoCore
import SwiftUI

/// `--snapshot <folder>`: draws the window content for a fixed set of states into PNG files at
/// 2x, offscreen and without showing a window, then exits (0 when every file was written).
/// With `--data-dir` the states come from that store, read without a connection; without it,
/// from the mock data. `--dump` with `--data-dir` prints the state of the store as JSON.
@MainActor
enum Snapshot {
    private struct Shot {
        let name: String
        var size = CGSize(width: 900, height: 640)
        var dark = false
        let setUp: (AppModel) -> Void
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
        Shot(name: "settings") { $0.modal = .settings },
        Shot(name: "settings-dark", dark: true) { $0.modal = .settings },
    ]

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
