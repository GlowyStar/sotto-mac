import AppKit
import SwiftUI

// Every colour, size and font of the interface lives here (DESIGN.md sections 2 to 5): a change
// of the look is an edit of this file.

extension Color {
    /// A colour that follows the appearance it is drawn in: `light` and `dark` are `RRGGBB` or
    /// `RRGGBBAA` hex.
    static func token(_ light: String, _ dark: String) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
    }

    static let windowBg = token("ffffff", "17212b")
    static let windowFg = token("000000", "f5f5f5")
    static let windowSubFg = token("999999", "708499")
    static let windowBoldFg = token("222222", "e9e8e8")
    static let windowBgOver = token("f1f1f1", "232e3c")
    static let windowBgRipple = token("e5e5e5", "24303d")
    static let titleBg = token("f1f1f1", "242f3d")
    static let titleFg = token("3e3c3e", "91a3b3")
    static let titleFgInactive = token("acacac", "6d7883")
    static let divider = token("00000018", "04080e56")
    static let listBg = token("ffffff", "17212b")
    static let rowBgOver = token("f1f1f1", "202b36")
    static let rowBgActive = token("419fd9", "2b5278")
    static let rowNameFg = token("222222", "f5f5f5")
    static let rowTextFg = token("999999", "7f91a4")
    static let rowDateFg = token("999999", "8696a8")
    static let rowFgActive = token("ffffff", "ffffff")
    static let rowSentIconFg = token("5dc452", "72bcfd")
    static let badgeBg = token("40a7e3", "4082bc")
    static let badgeFg = token("ffffff", "ffffff")
    static let badgeBgActive = token("ffffff", "ffffff")
    static let badgeFgActive = token("419fd9", "2a5378")
    static let chatBgTop = token("dfe7d6", "0e1621")
    static let chatBgBottom = token("cfdcc3", "0e1621")
    static let msgInBg = token("ffffff", "182533")
    static let msgOutBg = token("effdde", "2b5278")
    static let msgInFg = token("000000", "f5f5f5")
    static let msgOutFg = token("000000", "e4ecf2")
    static let msgInDateFg = token("a0acb6", "6d7f8f")
    static let msgOutDateFg = token("6db566", "7da8d3")
    static let msgInLinkFg = token("168acd", "70baf5")
    static let msgOutLinkFg = token("168acd", "83caff")
    static let msgInShadow = token("748ea229", "748ea200")
    static let msgOutShadow = token("3ac3461d", "00000000")
    static let msgStoredIconFg = token("57b84c", "6bbfff")
    static let msgSendingIconFg = token("98d292", "70a4d2")
    static let serviceBg = token("517c417f", "213040d5")
    static let serviceFg = token("ffffff", "ffffff")
    static let unreadBarBg = token("fcfbfa", "182433")
    static let unreadBarFg = token("538bb4", "ffffff")
    static let unreadBarBorder = token("00000018", "03080d00")
    static let topBarBg = token("ffffff", "17212b")
    static let composeBg = token("ffffff", "17212b")
    static let composeIconFg = token("999999", "6c7883")
    static let composeIconFgOver = token("8a8a8a", "7c90a4")
    static let placeholderFg = token("999999", "6d7883")
    static let placeholderFgActive = token("aaaaaa", "4f5b67")
    static let searchBg = token("f1f1f1", "242f3d")
    static let searchBgActive = token("ffffff", "242f3d")
    static let searchBorderActive = token("e5e5e5", "242f3d")
    static let accent = token("40a7e3", "5288c1")
    static let accentOver = token("39a5db", "2f6ea5")
    static let accentText = token("168acd", "6ab3f3")
    static let lightButtonBgOver = token("e3f1fa", "26394d")
    static let danger = token("d14e4e", "ec3942")
    static let dangerBgOver = token("fcdfde", "3b2228")
    static let fieldError = token("d84d4d", "dc3d3d")
    static let fieldGood = token("4ab44a", "5598db")
    static let activeLine = token("37a1de", "6396cb")
    static let toDownBg = token("ffffff", "1d2b3a")
    static let toDownFg = token("999999", "adb4ba")
    static let menuIconFg = token("999999", "6c7883")
    static let boxBg = token("ffffff", "17212b")
    static let boxTitleFg = token("404040", "ebebeb")
    static let layerBg = token("0000007f", "0000007f")
    static let shadow = token("00000018", "04080e56")
    static let toastBg = token("2c3033e5", "000000b2")
    static let toastFg = token("ffffff", "ffffff")
    // Reduced transparency: the toast with full alpha; the dim behind a box stays a dim.
    static let toastBgOpaque = token("2c3033", "000000")
    static let avatarFg = token("ffffff", "ffffff")
}

extension NSColor {
    convenience init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        let hasAlpha = hex.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255, alpha: hasAlpha ? CGFloat(value & 0xff) / 255 : 1)
    }
}

/// Avatar gradients (DESIGN.md 3, "Avatar colours"), indexed as in the spec; slot 2 is unused.
enum AvatarPalette {
    static let colors: [Int: (top: String, bottom: String)] = [
        0: ("ff845e", "d45246"), 1: ("9ad164", "46ba43"), 3: ("5caffa", "408acf"),
        4: ("b694f9", "6c61df"), 5: ("ff8aac", "d95574"), 6: ("5bcbe3", "359ad4"),
        7: ("febb5b", "f68136"),
    ]
    static let order = [0, 7, 4, 1, 6, 3, 5]

    /// The first 8 bytes of the id as a big-endian number, modulo 7, mapped through `order`.
    static func index(for id: String) -> Int {
        let prefix = UInt64(id.prefix(16), radix: 16) ?? 0
        return order[Int(prefix % 7)]
    }
}

/// Sizes in points (DESIGN.md 2 and 5).
enum Metrics {
    // Window and layout
    static let windowMin = CGSize(width: 380, height: 480)
    static let windowDefault = CGSize(width: 800, height: 600)
    static let listMin: CGFloat = 260
    static let listMax: CGFloat = 540
    static let listDefault: CGFloat = 320
    static let chatMin: CGFloat = 380
    static let twoColumnThreshold: CGFloat = 640
    static let titleStrip: CGFloat = 28

    // Chat list row
    static let rowHeight: CGFloat = 62
    static let rowPadding: CGFloat = 10
    static let rowPadTop: CGFloat = 8
    static let rowAvatar: CGFloat = 46
    static let rowTextX: CGFloat = 68
    static let rowNameTop: CGFloat = 10
    static let rowPreviewTop: CGFloat = 34
    static let rowGap: CGFloat = 6
    static let rowMarkBox: CGFloat = 16
    static let rowMarkGap: CGFloat = 3
    static let badgeHeight: CGFloat = 19
    static let badgePadding: CGFloat = 5

    // List top bar and search
    static let topBarHeight: CGFloat = 54
    static let menuButton: CGFloat = 40
    static let menuButtonLeft: CGFloat = 7
    static let searchHeight: CGFloat = 35
    static let searchRadius: CGFloat = 18
    static let searchOuter: CGFloat = 7
    static let searchTextLeft: CGFloat = 12
    static let searchTextRight: CGFloat = 30
    static let connectionBar: CGFloat = 37

    // Chat header
    static let headerAvatar: CGFloat = 40
    static let headerAvatarLeft: CGFloat = 16
    static let headerTitleGap: CGFloat = 12
    static let headerButton: CGFloat = 40

    // Bubbles
    static let bubbleMaxWidth: CGFloat = 430
    static let bubblePadH: CGFloat = 11
    static let bubblePadV: CGFloat = 8
    static let bubbleNear: CGFloat = 16
    static let bubbleFar: CGFloat = 56
    static let groupTopSpace: CGFloat = 6
    static let messageBottomSpace: CGFloat = 2
    static let radiusLarge: CGFloat = 16
    static let radiusSmall: CGFloat = 6
    static let bubbleShadow: CGFloat = 2
    static let tailWidth: CGFloat = 8
    static let tailHeight: CGFloat = 12
    static let timeRight: CGFloat = 9
    static let timeBottom: CGFloat = 8
    static let groupGap: TimeInterval = 5 * 60

    // Separators and scroll button
    static let servicePad = EdgeInsets(top: 3, leading: 12, bottom: 4, trailing: 12)
    static let dateTop: CGFloat = 10
    static let dateBottom: CGFloat = 2
    static let unreadBand: CGFloat = 32
    static let unreadMargin: CGFloat = 8
    static let toDownCircle: CGFloat = 44
    static let toDownRight: CGFloat = 12
    static let toDownBottom: CGFloat = 10
    static let toDownThreshold: CGFloat = 480
    static let toDownBadge: CGFloat = 22
    static let floatingDateTop: CGFloat = 8
    static let floatingDateHold = Duration.milliseconds(200)

    // Compose
    static let composeHeight: CGFloat = 46
    static let fieldMin: CGFloat = 36
    static let fieldMax: CGFloat = 224
    static let fieldLeft: CGFloat = 16
    static let fieldPadV: CGFloat = 5
    static let sendWidth: CGFloat = 44
    static let sendRight: CGFloat = 2
    static let listToCompose: CGFloat = 8

    // Boxes and toast
    static let boxWidth: CGFloat = 320
    static let boxWideWidth: CGFloat = 364
    static let boxRadius: CGFloat = 8
    static let boxTitleHeight: CGFloat = 48
    static let boxPad: CGFloat = 24
    static let buttonHeight: CGFloat = 34
    static let buttonPadH: CGFloat = 15
    static let buttonRadius: CGFloat = 6
    static let fieldHeight: CGFloat = 32
    static let toastPad = EdgeInsets(top: 13, leading: 19, bottom: 12, trailing: 19)
    static let toastMaxWidth: CGFloat = 480
    static let toastAbove: CGFloat = 40
    static let toastHold: Duration = .milliseconds(1500)

    // Contact panel
    static let panelWidth: CGFloat = 320
    static let panelRow: CGFloat = 44
    static let bigAvatar: CGFloat = 80
}

/// Fonts by role (DESIGN.md 4). `lineSpacing` turns the system line box into the spec's.
enum Fonts {
    static let rowName = Font.system(size: 13, weight: .semibold)
    static let rowText = Font.system(size: 13)
    static let badge = Font.system(size: 12, weight: .bold)
    static let headerTitle = Font.system(size: 14, weight: .semibold)
    static let headerSubtitle = Font.system(size: 13)
    static let message = Font.system(size: 13)
    static let messageLineSpacing: CGFloat = 2.5
    static let time = Font.system(size: 13)
    static let service = Font.system(size: 13, weight: .semibold)
    static var compose: NSFont { .systemFont(ofSize: 13) }
    static let boxTitle = Font.system(size: 16, weight: .semibold)
    static let boxBody = Font.system(size: 14)
    static let button = Font.system(size: 14, weight: .semibold)
    static let label = Font.system(size: 13)
    static let sectionLabel = Font.system(size: 13, weight: .semibold)
    static let welcomeTitle = Font.system(size: 20, weight: .semibold)
    static let id = Font.system(size: 14, design: .monospaced)
    static let idField = Font.system(size: 13, design: .monospaced)
    static let title = Font.system(size: 13)

    static func initials(for size: CGFloat) -> Font {
        .system(size: size >= 80 ? 28 : size >= 46 ? 17 : 15, weight: .semibold)
    }
}

/// Animations of DESIGN.md 6; under reduced motion every one becomes a short cross-fade.
enum Motion {
    static let hover = Animation.easeOut(duration: 0.12)
    static let column = Animation.smooth(duration: 0.12)
    static let box = Animation.smooth(duration: 0.2)
    static let toastIn = Animation.easeOut(duration: 0.2)
    static let toastOut = Animation.easeIn(duration: 1.0)
    static let toDown = Animation.smooth(duration: 0.15)
    static let compose = Animation.smooth(duration: 0.1)
    static let connection = Animation.smooth(duration: 0.2)
    static let reorder = Animation.spring(response: 0.3, dampingFraction: 1.0)
    static let newMessage = Animation.smooth(duration: 0.2)
    static let floatingDate = Animation.easeOut(duration: 0.2)
    static let reduced = Animation.easeInOut(duration: 0.15)

    static func pick(_ animation: Animation, reduce: Bool) -> Animation { reduce ? reduced : animation }
}
