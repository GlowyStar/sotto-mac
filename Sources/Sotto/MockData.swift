import CryptoKit
import Foundation

/// Mock contacts and chats that exercise the layout: short and long messages, several lines,
/// a link, emoji, Russian and English, groups, several days, unread counts, an empty chat and
/// outgoing messages in both states.
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

        model.contacts = contacts
        model.messages = messages
    }
}
