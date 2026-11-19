import AppKit
import SwiftUI

@main
struct SottoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    /// Read after `init`: a snapshot or a dump exits before the shared model opens a store.
    private var model: AppModel { AppModel.shared }

    init() {
        Snapshot.runFromArguments()
    }

    var body: some Scene {
        Window("Sotto", id: "main") {
            RootView(model: model)
        }
        .defaultSize(Metrics.windowDefault)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") { model.openSettings() }.keyboardShortcut(",")
            }
            CommandGroup(after: .appSettings) {
                Button("Lock Sotto") { model.lock() }
                    .keyboardShortcut("l")
                    .disabled(model.covered || (model.messenger == nil && model.settings.passcode == nil))
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Contact...") { model.modal = .addContact }.keyboardShortcut("n")
            }
            CommandGroup(after: .textEditing) {
                Button("Search") { model.searchFocusTick += 1 }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Search in Chat") { model.openChatSearch() }.keyboardShortcut("f")
                Button("Attach...") { model.attachMenuOpen = true }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.openChatID == nil)
            }
            if model.messenger == nil {
                mockMenu
            }
        }
    }

    private var mockMenu: some Commands {
        CommandMenu("Mock") {
            Button("Show First Launch") {
                model.modal = nil
                model.welcome = .start
            }
            Button(model.connection == .connected ? "Drop Connection" : "Restore Connection") {
                model.setConnection(model.connection == .connected ? .connecting : .connected)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.applyTheme()
            AppModel.shared.watchActivity()
            AppModel.shared.alerts?.refresh(ask: AppModel.shared.settings.notifications)
            AppModel.shared.unlockStore()
        }
    }

    /// The drafts typed in the last moment are written and the store is closed, its key
    /// overwritten, before the app quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            _ = Task {
                await AppModel.shared.closeStore()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
