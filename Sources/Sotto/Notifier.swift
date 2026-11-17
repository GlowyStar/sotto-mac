import AppKit
import SottoCore
import UserNotifications

/// Posts the notifications `Alerts` decides on and keeps the Dock badge. The notification
/// center exists only for a bundled app, so under `swift run`, the tests and the snapshots
/// nothing here touches it.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let available = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil

    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
        super.init()
        guard Self.available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Asks macOS once, while the setting is on, and reads whether it refused.
    func refresh(ask: Bool) {
        guard Self.available else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined, ask {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
                status = await center.notificationSettings().authorizationStatus
            }
            model?.notificationsDenied = status == .denied
        }
    }

    func post(_ alert: Alert) {
        guard Self.available else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.threadIdentifier = alert.chatID
        content.userInfo = ["chat": alert.chatID]
        if alert.sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: "\(alert.chatID)-\(alert.messageID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Takes away the notifications of a chat that was read.
    func clear(_ chatID: String) {
        guard Self.available else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications()
                .filter { $0.request.content.threadIdentifier == chatID }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    func setBadge(_ count: Int) {
        let label = count > 0 ? String(count) : nil
        if NSApp?.dockTile.badgeLabel != label { NSApp?.dockTile.badgeLabel = label }
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let chat = response.notification.request.content.userInfo["chat"] as? String else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            model?.openFromNotification(chat)
        }
    }
}
