import AppKit
import SwiftUI

@main
struct SottoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let model = AppModel.shared

    init() {
        Snapshot.runFromArguments()
        if CommandLine.arguments.contains("--first-launch") { AppModel.shared.welcome = .start }
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
                Button("Settings...") { model.modal = .settings }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Contact...") { model.modal = .addContact }.keyboardShortcut("n")
            }
            CommandGroup(after: .textEditing) {
                Button("Search") { model.searchFocusTick += 1 }.keyboardShortcut("f")
            }
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
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.applyTheme() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
