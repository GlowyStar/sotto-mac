import AppKit
import ImageIO
import SottoCore
import SwiftUI

/// Pictures and sizes of the photos and files of a chat (DESIGN.md 13).
@MainActor
enum Media {
    private static let pictures = NSCache<NSString, NSImage>()
    private static let thumbnails = NSCache<NSData, NSImage>()

    /// The file of a message on this Mac: a received file, or the file a sent one was read from.
    static func localURL(_ file: ChatFile) -> URL? {
        guard let path = file.savedAs, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The picture at `url`, its orientation applied, scaled down so its longest side is at
    /// most `side` points at 2x; kept for the next draw.
    static func picture(_ url: URL, side: CGFloat) -> NSImage? {
        let key = "\(url.path)#\(Int(side))" as NSString
        if let kept = pictures.object(forKey: key) { return kept }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(side * 2),
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let made = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        pictures.setObject(made, forKey: key)
        return made
    }

    /// A received thumbnail, only when it decodes as a JPEG (protocol section 32.2).
    static func thumbnail(_ data: Data) -> NSImage? {
        guard !data.isEmpty else { return nil }
        // Keyed by the bytes themselves: two thumbnails never share an entry.
        let key = data as NSData
        if let kept = thumbnails.object(forKey: key) { return kept }
        guard let image = Thumbnail.decode(data) else { return nil }
        let made = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnails.setObject(made, forKey: key)
        return made
    }

    /// The size of a photo: from the attachment, else from the picture on this Mac.
    static func pixelSize(_ file: ChatFile) -> CGSize? {
        if file.width > 0, file.height > 0 { return CGSize(width: file.width, height: file.height) }
        guard let url = localURL(file), let image = picture(url, side: Metrics.mediaMax) else { return nil }
        return image.size
    }

    /// The frame of a photo in a bubble: its size fitted into 430 x 430, never scaled up, at
    /// least 200 wide and 100 high and at most `maxWidth` wide (DESIGN.md 13.1).
    static func photoFrame(_ file: ChatFile, maxWidth: CGFloat) -> CGSize {
        let size = pixelSize(file) ?? CGSize(width: Metrics.photoMinWidth, height: Metrics.photoMinWidth)
        let scale = min(1, Metrics.mediaMax / size.width, Metrics.mediaMax / size.height, maxWidth / size.width)
        return CGSize(
            width: min(max((size.width * scale).rounded(), Metrics.photoMinWidth), maxWidth),
            height: max((size.height * scale).rounded(), Metrics.photoMinHeight))
    }

    /// The share of the blob that is stored or downloaded; 0 before the first piece.
    static func fraction(_ file: ChatFile) -> Double {
        let total = file.total > 0 ? file.total : Blob.blobLength(file.size)
        return min(1, Double(file.done) / Double(max(total, 1)))
    }
}

/// The background of a bubble: its fill over a 2pt band of shadow.
struct BubbleBackground: View {
    let shape: BubbleShape
    let out: Bool

    var body: some View {
        ZStack {
            shape.fill(out ? Color.msgOutShadow : Color.msgInShadow).offset(y: Metrics.bubbleShadow)
            shape.fill(out ? Color.msgOutBg : Color.msgInBg)
        }
    }
}

/// The time of a message and, for an own message, its status mark.
struct TimeMark: View {
    let message: Message
    let time: String
    /// On a photo: the colours of the media overlay.
    var overlay = false
    @Environment(\.settings) private var settings

    var body: some View {
        let out = message.outgoing
        let color = overlay ? Color.mediaOverlayFg : out ? Color.msgOutDateFg : Color.msgInDateFg
        HStack(spacing: 3) {
            if message.expiresAfter > 0 {
                TimerLabel(seconds: message.expiresAfter, color: color)
                    .help(Self.timerHelp(message))
            }
            Text(message.edited ? "edited " + time : time)
                .font(Fonts.message(settings.textSize))
                .foregroundStyle(color)
            if out {
                StatusMark(
                    state: message.state,
                    waitingColor: overlay ? .mediaOverlayFg : .msgSendingIconFg,
                    storedColor: overlay ? .mediaOverlayFg : .msgStoredIconFg,
                    deliveredColor: overlay ? .mediaOverlayFg.opacity(0.7) : .msgDeliveredIconFg)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The room a bubble keeps on its last line for the time, the marks and the timer: a
    /// transparent copy of the time line in figure spaces (DESIGN.md 5.4 and 20.4).
    static func reserve(_ message: Message, time: String) -> String {
        var line = " \u{2007}" + (message.edited ? "edited " : "") + time
        if message.expiresAfter > 0 {
            line = " \u{2007}\u{2007}" + TimerChoices.short(message.expiresAfter) + line
        }
        return line + (message.outgoing ? "\u{2007}\u{2007}\u{2007}" : "")
    }

    private static func timerHelp(_ message: Message) -> String {
        let title = TimerChoices.title(message.expiresAfter)
        guard let at = message.expiresAt else {
            return message.outgoing ? "Disappears \(title) after it is sent" : "Disappears \(title) after you read it"
        }
        let left = max(0, Int(at.timeIntervalSinceNow.rounded(.up)))
        return "Disappears in \(TimerChoices.title(left) == "Off" ? "a moment" : TimerChoices.title(left))"
    }
}

/// What the circle over a photo or in a file row shows in a state (DESIGN.md 13).
@MainActor
struct CircleLook: Equatable {
    var symbol: String
    var size: CGFloat = 22
    /// Nil: no ring; 0: the turning arc before the first piece; else the share done.
    var ring: Double?
    var help = ""

    /// Nil when the state shows no circle on a photo.
    static func of(_ file: ChatFile, connected: Bool) -> CircleLook? {
        switch file.state {
        case .offered: CircleLook(symbol: "arrow.down", help: "Download")
        case .receiving: CircleLook(symbol: "xmark", size: 18, ring: Media.fraction(file), help: "Pause the download")
        case .sending:
            CircleLook(symbol: "xmark", size: 18, ring: connected ? Media.fraction(file) : nil, help: "Cancel sending")
        case .notSent: CircleLook(symbol: "arrow.clockwise", size: 20, help: "Not sent. Click to retry.")
        case .notReceived: CircleLook(symbol: "arrow.clockwise", size: 20, help: "Could not download. Click to retry.")
        case .sent, .received, .notAvailable: nil
        }
    }
}

/// A filled circle with a glyph and, while a transfer moves, a progress ring.
struct MediaCircle: View {
    let look: CircleLook
    let fill: Color
    let fillOver: Color
    let glyph: Color
    var dimmed = false
    @State private var hover = false

    var body: some View {
        ZStack {
            Circle().fill(hover ? fillOver : fill)
            Image(systemName: look.symbol)
                .font(.system(size: look.size, weight: .regular))
                .foregroundStyle(glyph)
                .opacity(dimmed ? 0.5 : 1)
                .contentTransition(.symbolEffect(.replace))
            if let ring = look.ring {
                ProgressRing(value: ring, color: glyph).transition(.opacity)
            }
        }
        .frame(width: Metrics.mediaCircle, height: Metrics.mediaCircle)
        .onHover { hover = $0 }
        .animation(Motion.mediaHover, value: hover)
        .animation(Motion.ring, value: look.ring == nil)
    }
}

/// A ring 3 thick, inset 3, clockwise from 12 o'clock; before the first piece an arc turns.
struct ProgressRing: View {
    let value: Double
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if value <= 0 {
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.7) / 0.7
                arc(0.06, 0.35).rotationEffect(.degrees(turn * 360))
            }
        } else {
            arc(0, value).animation(reduceMotion ? nil : Motion.ring, value: value)
        }
    }

    private func arc(_ from: Double, _ to: Double) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(color, style: StrokeStyle(lineWidth: Metrics.ringWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .padding(Metrics.ringInset + Metrics.ringWidth / 2)
    }
}

/// A small pill over a photo: the time, the size, "No longer available".
struct MediaPill<Content: View>: View {
    var fill = Color.mediaOverlayBg
    var padding = Metrics.mediaPillPad
    var radius = Metrics.mediaPillRadius
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius).fill(fill))
    }
}

/// A photo message: the picture, or its blurred thumbnail until the picture is here, the
/// circle of its state, and the caption under it (DESIGN.md 13.1).
struct PhotoBubble<Caption: View>: View {
    let message: Message
    let file: ChatFile
    let shape: BubbleShape
    let maxWidth: CGFloat
    let time: String
    let connected: Bool
    let tap: () -> Void
    /// The quote of a reply, over the picture (DESIGN.md 20.3).
    var header: AnyView?
    @ViewBuilder let caption: () -> Caption

    var body: some View {
        let size = Media.photoFrame(file, maxWidth: maxWidth)
        let captioned = !message.text.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                header
                    .padding(.horizontal, Metrics.quoteInset)
                    .padding(.vertical, Metrics.quoteTop)
                    .frame(width: size.width)
            }
            Button(action: tap) {
                picture(size, underTail: shape.tail && !captioned)
                    .overlay { circle }
                    .overlay(alignment: .bottomTrailing) {
                        if !captioned {
                            MediaPill { TimeMark(message: message, time: time, overlay: true) }
                                .padding(Metrics.mediaPillInset)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(CircleLook.of(file, connected: connected)?.help ?? "")
            .accessibilityLabel(message.outgoing ? "Your photo" : "Photo")
            if captioned {
                caption().frame(width: size.width, alignment: .leading)
            }
        }
        .frame(width: size.width)
        .background { BubbleBackground(shape: shape, out: message.outgoing) }
        .clipShape(shape)
    }

    /// The picture fills its frame; under the tail it reaches out to fill the tail too.
    private func picture(_ size: CGSize, underTail: Bool) -> some View {
        let reach = underTail ? Metrics.tailWidth : 0
        let local = Media.localURL(file).flatMap { Media.picture($0, side: max(size.width, size.height)) }
        return ZStack {
            if let local {
                Image(nsImage: local).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if let thumbnail = Media.thumbnail(file.thumbnail) {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    .blur(radius: min(size.width, size.height) / 10, opaque: true)
            } else {
                Color.imageBg.opacity(0.15)
            }
        }
        .frame(width: size.width + reach, height: size.height)
        .clipped()
        .offset(x: message.outgoing ? reach / 2 : -reach / 2)
        .frame(width: size.width, height: size.height)
        .animation(Motion.picture, value: local != nil)
    }

    @ViewBuilder
    private var circle: some View {
        if file.state == .notAvailable {
            MediaPill(fill: .serviceBg, padding: Metrics.servicePad, radius: 12) {
                Text("No longer available").font(Fonts.service).foregroundStyle(Color.serviceFg)
            }
        } else if let look = CircleLook.of(file, connected: connected) {
            VStack(spacing: 8) {
                MediaCircle(look: look, fill: .mediaOverlayBg, fillOver: .mediaOverlayBgOver, glyph: .mediaOverlayGlyph)
                if file.state == .offered {
                    MediaPill {
                        Text(Formats.bytes(file.size)).font(Fonts.service).foregroundStyle(Color.mediaOverlayFg)
                    }
                }
            }
            // The size pill hangs under the circle, which stays centered.
            .offset(y: file.state == .offered ? 14 : 0)
        }
    }
}

/// A file message: the circle of its state, the name, a status line and the caption under
/// them (DESIGN.md 13.2).
struct FileBubble<Caption: View>: View {
    let message: Message
    let file: ChatFile
    let shape: BubbleShape
    let maxWidth: CGFloat
    let time: String
    let connected: Bool
    let tap: () -> Void
    /// The quote of a reply, over the file (DESIGN.md 20.3).
    var header: AnyView?
    @ViewBuilder let caption: () -> Caption

    var body: some View {
        let out = message.outgoing
        let captioned = !message.text.isEmpty
        let widest = min(Metrics.mediaMax, maxWidth)
        VStack(alignment: .leading, spacing: 0) {
            if let header {
                header
                    .padding(.horizontal, Metrics.quoteInset)
                    .padding(.top, Metrics.quoteTop)
            }
            Button(action: tap) {
                HStack(alignment: .top, spacing: Metrics.fileTextX) {
                    MediaCircle(
                        look: CircleLook.of(file, connected: connected) ?? CircleLook(symbol: "doc.fill"),
                        fill: out ? .fileCircleOut : .fileCircleIn,
                        fillOver: out ? .fileCircleOutOver : .fileCircleInOver,
                        glyph: out ? .fileGlyphOut : .fileGlyphIn,
                        dimmed: file.state == .notAvailable)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name.isEmpty ? "File" : file.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(out ? Color.msgOutFg : Color.msgInFg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(status)
                            .font(.system(size: 13))
                            .foregroundStyle(statusColor)
                            .lineLimit(1)
                            .padding(.trailing, captioned ? 0 : timeReserve)
                    }
                    .padding(.top, Metrics.fileNameTop)
                    Spacer(minLength: 0)
                }
                .padding(Metrics.filePad)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(file.state == .notAvailable)
            .help(CircleLook.of(file, connected: connected)?.help ?? (file.state == .received ? "Open" : ""))
            if captioned {
                caption()
            }
        }
        .frame(width: min(max(contentWidth, Metrics.fileMinWidth), widest), alignment: .leading)
        .overlay(alignment: .bottomTrailing) {
            if !captioned {
                TimeMark(message: message, time: time)
                    .padding(.trailing, Metrics.timeRight)
                    .padding(.bottom, Metrics.timeBottom)
            }
        }
        .background { BubbleBackground(shape: shape, out: out) }
    }

    @Environment(\.settings) private var settings

    /// The width the row and the caption ask for on one line each.
    private var contentWidth: CGFloat {
        func width(_ text: String, _ font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        }
        // The circle, the texts and the spacer are three items of the row, two gaps apart.
        let row = Metrics.filePad.leading + Metrics.mediaCircle + 2 * Metrics.fileTextX + Metrics.filePad.trailing
            + max(width(file.name, .systemFont(ofSize: 13, weight: .semibold)), width(status, .systemFont(ofSize: 13)) + timeReserve)
        let caption = message.text.isEmpty ? 0
            : 2 * Metrics.bubblePadH + width(message.text, .systemFont(ofSize: CGFloat(settings.textSize))) + timeReserve + 12
        return max(row, caption)
    }

    /// The room of the time and the mark, plus the 10 the status line keeps from them.
    private var timeReserve: CGFloat {
        let width = (time as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        let reserve = (TimeMark.reserve(message, time: time) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
        return max(width, reserve).rounded(.up) + (message.outgoing ? 15 : 0) + Metrics.timeRight - Metrics.filePad.trailing + 10
    }

    private var status: String {
        switch file.state {
        case .receiving, .sending:
            if file.state == .sending && !connected { return "Waiting for connection..." }
            return Formats.bytes(Int(Double(file.size) * Media.fraction(file)), of: file.size)
        case .notSent: return "Not sent. Click to retry."
        case .notReceived: return "Could not download. Click to retry."
        case .notAvailable: return "No longer available"
        case .offered, .sent, .received: return Formats.bytes(file.size)
        }
    }

    private var statusColor: Color {
        switch file.state {
        case .notSent, .notReceived: .danger
        case .notAvailable: .windowSubFg
        default: message.outgoing ? .msgOutDateFg : .msgInDateFg
        }
    }
}

extension Formats {
    private static let units = ["B", "KB", "MB", "GB"]

    /// Decimal units as Finder writes them: one decimal under 100, none from 100 on.
    static func bytes(_ count: Int) -> String {
        let unit = unit(of: count)
        return number(count, unit) + " " + units[unit]
    }

    /// "0.4 / 1.4 MB": both sides in the unit of the total.
    static func bytes(_ done: Int, of total: Int) -> String {
        let unit = unit(of: total)
        return number(done, unit) + " / " + number(total, unit) + " " + units[unit]
    }

    private static func unit(of count: Int) -> Int {
        var unit = 0
        var value = Double(count)
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return unit
    }

    private static func number(_ count: Int, _ unit: Int) -> String {
        guard unit > 0 else { return String(count) }
        let value = Double(count) / pow(1000, Double(unit))
        return value < 100 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }
}
