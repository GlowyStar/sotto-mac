import CryptoKit
import Foundation

/// The settings of the app (DESIGN.md 11), kept in `app.json` with the other notes of
/// `Messenger`. A key that is missing or unreadable takes its default, so an older file and
/// a newer one both load.
public struct AppSettings: Codable, Equatable, Sendable {
    public enum Theme: String, Codable, CaseIterable, Sendable {
        case system, light, dark
    }

    public enum Background: String, Codable, CaseIterable, Sendable {
        case standard = "default", mist, sand, rose, slate, plain
    }

    public static let textSizes = 12...20
    /// The stops of the auto-download sliders in MB; 0 is off.
    public static let downloadStops = [0, 1, 5, 10, 25, 50, 100]
    public static let autoLockStops = [1, 5, 60, 300]

    // Notifications (posted from SOTTO-36 on)
    public var notifications = true
    public var notificationSender = true
    public var notificationPreview = true
    public var sound = true
    public var dockBadge = true
    // Chat settings
    public var theme = Theme.system
    public var textSize = 13
    public var background = Background.standard
    public var sendWithCommandEnter = false
    /// Nil follows the locale.
    public var clock24: Bool?
    // Data and storage (used from SOTTO-32 on); sizes in MB, 0 is off
    public var autoDownloadPhotos = 10
    public var autoDownloadFiles = 10
    /// Nil is the user's Downloads folder.
    public var downloadFolder: String?
    public var askWhereToSave = false
    // Privacy and security
    public var passcode: Passcode?
    public var autoLockMinutes = 60
    public var lockOnSleep = true
    public var hideContentsWhileLocked = true

    public init() {}

    enum CodingKeys: String, CodingKey, CaseIterable {
        case notifications, notificationSender, notificationPreview, sound, dockBadge
        case theme, textSize, background, sendWithCommandEnter, clock24
        case autoDownloadPhotos, autoDownloadFiles, downloadFolder, askWhereToSave
        case passcode, autoLockMinutes, lockOnSleep, hideContentsWhileLocked
    }

    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? keys.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        let defaults = AppSettings()
        notifications = value(.notifications, defaults.notifications)
        notificationSender = value(.notificationSender, defaults.notificationSender)
        notificationPreview = value(.notificationPreview, defaults.notificationPreview)
        sound = value(.sound, defaults.sound)
        dockBadge = value(.dockBadge, defaults.dockBadge)
        theme = value(.theme, defaults.theme)
        textSize = min(max(value(.textSize, defaults.textSize), Self.textSizes.lowerBound), Self.textSizes.upperBound)
        background = value(.background, defaults.background)
        sendWithCommandEnter = value(.sendWithCommandEnter, defaults.sendWithCommandEnter)
        clock24 = value(.clock24, defaults.clock24)
        autoDownloadPhotos = value(.autoDownloadPhotos, defaults.autoDownloadPhotos)
        autoDownloadFiles = value(.autoDownloadFiles, defaults.autoDownloadFiles)
        downloadFolder = value(.downloadFolder, defaults.downloadFolder)
        askWhereToSave = value(.askWhereToSave, defaults.askWhereToSave)
        passcode = value(.passcode, defaults.passcode)
        autoLockMinutes = value(.autoLockMinutes, defaults.autoLockMinutes)
        lockOnSleep = value(.lockOnSleep, defaults.lockOnSleep)
        hideContentsWhileLocked = value(.hideContentsWhileLocked, defaults.hideContentsWhileLocked)
    }
}

/// The local passcode: an HMAC-SHA256 of the text under a random salt. It locks the window
/// only; the store itself is not encrypted with it (docs/key-storage.md).
public struct Passcode: Codable, Equatable, Sendable {
    public static let minimumLength = 4

    public let salt: Data
    public let code: Data

    public init(_ text: String) {
        salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        code = Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: salt)))
    }

    public func matches(_ text: String) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Data(text.utf8), using: SymmetricKey(data: salt))
    }
}
