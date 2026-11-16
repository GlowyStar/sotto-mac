import AppKit
import SwiftUI

/// `--snapshot <folder>`: draws the window content for a fixed set of states into PNG files at
/// 2x, offscreen and without showing a window, then exits (0 when every file was written).
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

    static func runFromArguments() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot") else { return }
        guard flag + 1 < arguments.count else { exit(2) }
        let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var failed = false
        for shot in shots {
            if !render(shot, to: folder.appendingPathComponent(shot.name + ".png")) {
                FileHandle.standardError.write(Data("snapshot failed: \(shot.name)\n".utf8))
                failed = true
            }
        }
        exit(failed ? 1 : 0)
    }

    private static func render(_ shot: Shot, to url: URL) -> Bool {
        let model = AppModel()
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
