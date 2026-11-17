import CryptoKit
import Foundation
import ImageIO
import SottoCore
import UniformTypeIdentifiers

/// Mock contacts and chats that exercise the layout: short and long messages, several lines,
/// a link, emoji, Russian and English, groups, several days, unread counts, an empty chat,
/// outgoing messages in both states, pinned, muted and archived chats and a draft; two chats
/// hold photos and files in every state, drawn in code into a temporary folder; the user and
/// several contacts have a profile, most with a photo drawn in code.
@MainActor
enum MockData {
    /// A stable 64-hex id made from a name.
    static func id(for name: String) -> String {
        SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let calendar = Calendar.current

    /// `minutes` before now, for today's messages.
    private static func ago(_ minutes: Double) -> Date {
        Date().addingTimeInterval(-minutes * 60)
    }

    /// A time on the day `days` before today.
    private static func day(_ days: Int, _ hour: Int, _ minute: Int) -> Date {
        let start = calendar.startOfDay(for: Date())
        let dayStart = calendar.date(byAdding: .day, value: -days, to: start) ?? start
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart) ?? dayStart
    }

    private static func inc(_ text: String, _ date: Date) -> Message {
        Message(outgoing: false, text: text, date: date)
    }

    private static func out(_ text: String, _ date: Date, _ state: MessageState = .stored) -> Message {
        Message(outgoing: true, text: text, date: date, state: state)
    }

    static func fill(_ model: AppModel) {
        model.storageBytes = 3_211_264
        var contacts: [Contact] = []
        var messages: [String: [Message]] = [:]

        func add(_ name: String, unread: Int = 0, added: Date = day(30, 10, 0), _ list: [Message]) {
            let id = id(for: name)
            contacts.append(Contact(id: id, name: name, added: added, unread: unread))
            if !list.isEmpty { messages[id] = list }
        }

        add(
            "Anna Petrova", unread: 3,
            [
                inc("Привет! Ты уже посмотрел черновик?", day(2, 18, 4)),
                inc("Там всего пара страниц", day(2, 18, 5)),
                out("Ещё нет, вечером гляну", day(2, 19, 30)),
                out("Скинь ссылку ещё раз, пожалуйста", day(2, 19, 31)),
                inc("https://example.com/drafts/sotto-notes", day(2, 19, 40)),
                out("Прочитал. В целом хорошо, но третий раздел я бы сократил вдвое: там повторяется то, что уже сказано во введении, и теряется главная мысль про ключи на устройстве.", day(1, 9, 12)),
                inc("Согласна 👍", day(1, 9, 20)),
                inc("Сокращу сегодня", day(1, 9, 20)),
                out("Отлично, спасибо! 🙌", day(1, 9, 25)),
                out("Call at 5?", ago(95)),
                inc("Да, давай", ago(40)),
                inc("Only I might be a few minutes late, the train is slow today 🚆", ago(39)),
                inc("Позвоню как буду на месте", ago(38)),
            ])
        add(
            "Max Turner",
            [
                inc("Did you push the fix?", ago(300)),
                out("Yes, it's in", ago(290)),
                out("Tests are green", ago(289)),
                inc("Nice", ago(120)),
                out("Sending the build tonight", ago(12), .failed("The relay refused it (UNKNOWN_RECIPIENT).")),
            ])
        add(
            "Lena Smirnova",
            [
                inc("Купила билеты на субботу", day(1, 20, 15)),
                out("Ура! Во сколько начало?", ago(3), .waiting),
            ])
        add(
            "Dmitry K", unread: 12,
            (0..<12).map { inc("Сообщение номер \($0 + 1)", ago(Double(70 - $0 * 5))) })
        add(
            "Sam Carter",
            [
                out("How was the trip?", day(3, 11, 0)),
                inc(
                    "Long story.\nFirst the flight was delayed by four hours, then the hotel lost our booking, and on the last day it rained so hard that the whole old town was flooded.\n\nStill, the food was great and I would go back tomorrow.",
                    day(3, 13, 42)),
                out("Haha, classic", day(3, 13, 50)),
            ])
        add("Ivan", added: ago(200), [])
        add(
            "Olga", unread: 1,
            [inc("Спасибо за вчера! Было очень весело 😊", day(1, 10, 2))])
        add(
            "Tom Becker",
            [
                inc("Are we still on for Friday?", day(4, 16, 20)),
                out("Sure, same place", day(4, 16, 45)),
            ])
        add(
            "Nadia",
            [
                out("Посмотри, пожалуйста, когда будет минутка", day(5, 12, 0)),
                inc("Посмотрела, всё ок", day(5, 14, 30)),
            ])
        add(
            "Pavel Orlov", unread: 2,
            [
                inc("Добрый день", day(9, 9, 0)),
                inc("Напомните номер заказа?", day(9, 9, 1)),
            ])
        add("Kate", [out("See you there 👋", day(15, 21, 10))])
        add(
            "Arman",
            [
                inc("Qalaisyn? Как дела?", day(40, 8, 30)),
                out("Жақсы, рахмет! All good", day(40, 9, 0)),
            ])

        // Two pinned chats, a muted one, two in the archive (one of them muted) and a draft.
        func set(_ name: String, _ change: (inout Contact) -> Void) {
            if let index = contacts.firstIndex(where: { $0.name == name }) { change(&contacts[index]) }
        }
        set("Lena Smirnova") { $0.pinned = 0 }
        set("Sam Carter") { $0.pinned = 1 }
        set("Dmitry K") { $0.muted = true }
        set("Arman") { $0.archived = true }
        set("Pavel Orlov") {
            $0.archived = true
            $0.muted = true
        }
        add("Vera Lindqvist", added: day(6, 9, 0), photoMessages())
        add("Leo Fischer", added: day(6, 9, 0), fileMessages())

        // Profiles: photos received, a thumbnail only, a picture gone, a name alone.
        set("Anna Petrova") { $0.profile = UserProfile(name: "Anya", avatar: portrait("anna", hue: 0.95)) }
        set("Max Turner") { $0.profile = UserProfile(name: "Max Turner", avatar: portrait("max", hue: 0.33)) }
        set("Vera Lindqvist") { $0.profile = UserProfile(name: "Vera", avatar: landscape("vera", hue: 0.55)) }
        set("Lena Smirnova") { $0.profile = UserProfile(name: "Лена", avatar: thumbnailOnly(portrait("lena", hue: 0.08), .receiving)) }
        set("Sam Carter") { $0.profile = UserProfile(name: "Sam", avatar: thumbnailOnly(landscape("sam", hue: 0.12), .notAvailable)) }
        set("Olga") { $0.profile = UserProfile(name: "Olga S.") }
        model.profile = UserProfile(name: "Alex Morgan", avatar: portrait("me", hue: 0.58))

        model.contacts = contacts
        model.messages = messages
        model.drafts = [id(for: "Tom Becker"): "Let me check the schedule first"]
    }

    // MARK: Profiles

    private static var avatars: [String: ProfilePhoto] = [:]

    /// A head and shoulders drawn in code on a background of `hue`, made into an avatar.
    static func portrait(_ name: String, hue: Double) -> ProfilePhoto? {
        if let kept = avatars[name] { return kept }
        let side = 600
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        func colour(_ h: Double, _ s: Double, _ b: Double) -> CGColor {
            let r = hsb(h.truncatingRemainder(dividingBy: 1), s, b)
            return CGColor(colorSpace: space, components: [r.0, r.1, r.2, 1])!
        }
        let w = CGFloat(side)
        let background = CGGradient(
            colorsSpace: space, colors: [colour(hue, 0.3, 0.95), colour(hue + 0.06, 0.55, 0.7)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(background, start: CGPoint(x: 0, y: w), end: .zero, options: [])
        context.setFillColor(colour(hue + 0.5, 0.45, 0.35))
        context.fillEllipse(in: CGRect(x: w * 0.12, y: -w * 0.35, width: w * 0.76, height: w * 0.7))
        context.setFillColor(colour(0.07, 0.35, 0.92))
        context.fillEllipse(in: CGRect(x: w * 0.31, y: w * 0.3, width: w * 0.38, height: w * 0.44))
        context.setFillColor(colour(hue + 0.1, 0.6, 0.3))
        context.fillEllipse(in: CGRect(x: w * 0.29, y: w * 0.56, width: w * 0.42, height: w * 0.22))
        guard let image = context.makeImage() else { return nil }
        let made = AvatarPicture.make(image, crop: AvatarPicture.centered(image)).map { ProfilePhoto(key: name, picture: $0.picture, thumbnail: $0.thumbnail, state: .received) }
        avatars[name] = made
        return made
    }

    /// The centered square of a landscape of the demo, made into an avatar.
    static func landscape(_ name: String, hue: Double) -> ProfilePhoto? {
        if let kept = avatars[name] { return kept }
        let url = picture("avatar-\(name).jpg", width: 900, height: 600, hue: hue)
        guard let image = try? AvatarPicture.load(url),
            let made = AvatarPicture.make(image, crop: AvatarPicture.centered(image))
        else { return nil }
        let photo = ProfilePhoto(key: name, picture: made.picture, thumbnail: made.thumbnail, state: .received)
        avatars[name] = photo
        return photo
    }

    /// An avatar whose picture is not on this Mac: only its thumbnail shows.
    private static func thumbnailOnly(_ photo: ProfilePhoto?, _ state: FileState) -> ProfilePhoto? {
        photo.map { ProfilePhoto(key: $0.key + "-thumbnail", picture: nil, thumbnail: $0.thumbnail, state: state) }
    }

    /// A picture for the crop box.
    static func cropPicture() -> CGImage? {
        try? AvatarPicture.load(picture("crop.jpg", width: 1400, height: 1000, hue: 0.62))
    }

    // MARK: Photos and files

    /// The folder of the demo pictures and files, outside the repository and the data folders.
    static let mediaFolder = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-demo-media", isDirectory: true)

    /// A landscape drawn in code: sky, sun and two hills in the colours of `hue`.
    static func picture(_ name: String, width: Int, height: Int, hue: Double) -> URL {
        let url = mediaFolder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return url }
        func colour(_ h: Double, _ s: Double, _ b: Double) -> CGColor {
            let r = hsb(h.truncatingRemainder(dividingBy: 1), s, b)
            return CGColor(colorSpace: space, components: [r.0, r.1, r.2, 1])!
        }
        let w = CGFloat(width), h = CGFloat(height)
        let sky = CGGradient(colorsSpace: space, colors: [colour(hue, 0.25, 1), colour(hue + 0.05, 0.6, 0.85)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: h * 0.3), options: [.drawsAfterEndLocation])
        context.setFillColor(colour(0.12, 0.35, 1))
        context.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.58, width: min(w, h) * 0.22, height: min(w, h) * 0.22))
        for (index, level) in [0.42, 0.28].enumerated() {
            context.setFillColor(colour(hue + 0.35, 0.5, 0.55 - Double(index) * 0.18))
            context.beginPath()
            context.move(to: CGPoint(x: 0, y: 0))
            context.addLine(to: CGPoint(x: 0, y: h * level))
            context.addCurve(
                to: CGPoint(x: w, y: h * (level - 0.08)),
                control1: CGPoint(x: w * (0.3 + 0.2 * Double(index)), y: h * (level + 0.22)),
                control2: CGPoint(x: w * 0.6, y: h * (level - 0.2)))
            context.addLine(to: CGPoint(x: w, y: 0))
            context.closePath()
            context.fillPath()
        }
        if let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        {
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(destination)
        }
        return url
    }

    private static func hsb(_ h: Double, _ s: Double, _ b: Double) -> (CGFloat, CGFloat, CGFloat) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6)), p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
        let (r, g, bl) = [(b, t, p), (q, b, p), (p, b, t), (p, q, b), (t, p, b), (b, p, q)][i]
        return (CGFloat(r), CGFloat(g), CGFloat(bl))
    }

    /// A small file of the demo; `size` is what the bubble says, the bytes are few.
    static func document(_ name: String) -> URL {
        let url = mediaFolder.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { try? Data("demo".utf8).write(to: url) }
        return url
    }

    /// A file of `size` bytes that takes no room on the disk, for the "too large" row.
    static func sparse(_ name: String, size: Int) -> URL {
        let url = mediaFolder.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.truncate(atOffset: UInt64(size))
            try? handle.close()
        }
        return url
    }

    private static func photo(
        _ url: URL, _ state: FileState, size: Int, done: Double = 0, local: Bool = true
    ) -> ChatFile {
        let made = Thumbnail.make(url)
        let total = Blob.blobLength(size)
        return ChatFile(
            name: url.lastPathComponent, size: size, mediaType: "image/jpeg", state: state,
            done: Int(Double(total) * done), total: total, savedAs: local ? url.path : nil,
            width: made?.width ?? 0, height: made?.height ?? 0, thumbnail: made?.jpeg ?? Data())
    }

    private static func file(_ name: String, _ mediaType: String, _ state: FileState, size: Int, done: Double = 0) -> ChatFile {
        let total = Blob.blobLength(size)
        let local = state == .received || state == .sent || state == .sending
        return ChatFile(
            name: name, size: size, mediaType: mediaType, state: state, done: Int(Double(total) * done), total: total,
            savedAs: local ? document(name).path : nil, result: state == .notReceived ? "BAD_BLOB" : nil)
    }

    private static func media(
        _ id: String, out: Bool, _ date: Date, _ file: ChatFile, caption text: String = "", _ state: MessageState = .stored
    ) -> Message {
        Message(id: id, outgoing: out, text: text, date: date, state: state, file: file)
    }

    static func photoMessages() -> [Message] {
        let lake = picture("lake.jpg", width: 1600, height: 1067, hue: 0.55)
        let dusk = picture("dusk.jpg", width: 1200, height: 900, hue: 0.02)
        let tower = picture("tower.jpg", width: 800, height: 1200, hue: 0.7)
        let field = picture("field.jpg", width: 1500, height: 1000, hue: 0.12)
        let wide = picture("panorama.jpg", width: 2400, height: 600, hue: 0.45)
        let failed = "The file was not sent (QUOTA_FULL)."
        return [
            media("vera-1", out: false, day(1, 18, 2), photo(lake, .received, size: 1_843_200)),
            media("vera-2", out: false, day(1, 18, 3), photo(dusk, .received, size: 954_000), caption: "Вид с балкона вечером 🌅"),
            media("vera-3", out: false, day(1, 18, 4), photo(field, .offered, size: 24_500_000, local: false)),
            media("vera-4", out: false, day(1, 18, 4), photo(tower, .receiving, size: 3_400_000, done: 0.4, local: false)),
            media("vera-5", out: false, day(1, 18, 5), photo(wide, .notAvailable, size: 2_100_000, local: false)),
            media("vera-6", out: true, ago(30), photo(field, .sent, size: 1_200_000), caption: "Look at this one"),
            media("vera-7", out: true, ago(20), photo(tower, .sent, size: 3_400_000)),
            media("vera-8", out: true, ago(5), photo(lake, .notSent, size: 1_843_200), .failed(failed)),
            media("vera-9", out: true, ago(1), photo(dusk, .sending, size: 954_000, done: 0.6), .waiting),
        ]
    }

    static func fileMessages() -> [Message] {
        [
            media("leo-1", out: false, day(2, 10, 0), file("Report Q3.pdf", "application/pdf", .received, size: 1_400_000), caption: "The report for the third quarter"),
            media("leo-2", out: false, day(2, 10, 1), file("Holiday photos archive.zip", "application/zip", .offered, size: 48_300_000)),
            media("leo-3", out: false, day(2, 10, 2), file("Interview.mov", "video/quicktime", .receiving, size: 1_400_000, done: 0.3)),
            media("leo-4", out: false, day(2, 10, 3), file("Contract.docx", "", .notReceived, size: 84_000)),
            media("leo-5", out: false, day(2, 10, 4), file("Old slides.key", "", .notAvailable, size: 5_200_000)),
            media("leo-6", out: true, ago(40), file("notes.txt", "text/plain", .sent, size: 2_300)),
            media("leo-7", out: true, ago(10), file("Budget 2027 final version.xlsx", "", .notSent, size: 312_000), caption: "Second draft", .failed("The file was not sent (UNKNOWN_RECIPIENT).")),
            media("leo-8", out: true, ago(2), file("Design.sketch", "", .sending, size: 12_600_000, done: 0.35), .waiting),
        ]
    }
}
