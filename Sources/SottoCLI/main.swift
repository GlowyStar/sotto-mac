import Foundation
import LocalAuthentication
import SottoCore

// The command line of the client: `sotto-mac`, one data directory per identity, the same
// commands, output lines and exit codes as the `sotto` command of the reference. Peer text
// reaches the terminal only through `printable`. Received files go into the folder
// `received` of the data directory (section 32.2). `chat` prints every message with its
// position in the log, which the commands of part 5 take (section 39.8), and counts a
// message as read once it printed it. The store opens only after Touch ID or the Mac
// password, unless the run asks for the test kind (docs/key-storage.md); `test-query`, left
// out of the help, answers the checks of the scripts from a store of that kind only.

let defaultRelay = "ws://127.0.0.1:8765/ws"
let defaultDataDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".sotto-mac").path
let quit = "/quit"
let quitGraceSeconds = 2.0
// UNKNOWN_CONTENT may be a later member of Content that is no message (section 20.3).
let silentResults: Set<String> = ["DUPLICATE", "NOT_A_CONTACT", "UNKNOWN_CONTENT"]
let receivedFolder = "received"
let progressSteps = 10
let chatCommands = "commands: /reply N text, /edit N text, /delete N, /timer [off|30s|5m|1h|1d|1w], /quit"
let timerUnits: [(unit: String, seconds: Int)] = [("w", 604_800), ("d", 86400), ("h", 3600), ("m", 60), ("s", 1)]
let quoteShown = 60
let usage = """
    usage: sotto-mac [-h] [--data-dir DATA_DIR] {init,id,add,contacts,chat,reset,send-file,read-receipts} ...
    """
let help = """
    \(usage)

    End-to-end encrypted chat through a sotto relay.

    commands:
      init                  make a new identity and print its user id
      id                    print the user id of the identity
      add NAME USER_ID      add a contact by its user id under a local name
      contacts              list the contacts
      chat NAME             chat with a contact; /quit or end of input ends; \(chatCommands)
      reset NAME            start a new session with a contact
      send-file NAME PATH   send a file to a contact and wait until it is sent or not sent
      read-receipts [on|off]
                            show, or turn on or off, the read receipts contacts get

    options:
      -h, --help            show this help message and exit
      --data-dir DATA_DIR   the directory of the identity (default: \(defaultDataDirectory))
      --relay URL           of chat, reset and send-file: the URL of the relay
                            (default: \(defaultRelay))
      --insecure            of chat, reset and send-file: allow a ws:// URL to a host that
                            is not a loopback host: no TLS
      --caption TEXT        of send-file: a text shown with the file
    """

/// A command cannot run; the text is for the person at the terminal.
struct CommandError: Error {
    let message: String
}

struct UsageError: Error {
    let message: String
}

struct Arguments {
    var dataDirectory = defaultDataDirectory
    var command = ""
    var positionals: [String] = []
    var relay = defaultRelay
    var insecure = false
    var caption = ""
}

func say(_ line: String) {
    print(line)
}

func complain(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

func parse(_ words: [String]) throws -> Arguments {
    var arguments = Arguments()
    var rest = words[...]
    func value(_ option: String) throws -> String {
        guard let next = rest.popFirst() else {
            throw UsageError(message: "argument \(option): expected one argument")
        }
        return next
    }

    while let word = rest.first, word.hasPrefix("-") {
        rest.removeFirst()
        if word == "-h" || word == "--help" {
            say(help)
            exit(0)
        } else if word == "--data-dir" {
            arguments.dataDirectory = try value(word)
        } else if word.hasPrefix("--data-dir=") {
            arguments.dataDirectory = String(word.dropFirst("--data-dir=".count))
        } else {
            throw UsageError(message: "unrecognized arguments: \(word)")
        }
    }
    guard let command = rest.popFirst() else {
        throw UsageError(message: "the following arguments are required: command")
    }
    let positionalCounts = [
        "init": 0, "id": 0, "add": 2, "contacts": 0, "chat": 1, "reset": 1, "send-file": 2, "read-receipts": 1,
        "test-query": 1,
    ]
    guard let wanted = positionalCounts[command] else {
        throw UsageError(message: "argument command: invalid choice: '\(command)'")
    }
    arguments.command = command
    let takesRelay = command == "chat" || command == "reset" || command == "send-file"

    while let word = rest.popFirst() {
        if word == "-h" || word == "--help" {
            say(help)
            exit(0)
        } else if takesRelay && word == "--relay" {
            arguments.relay = try value(word)
        } else if takesRelay && word.hasPrefix("--relay=") {
            arguments.relay = String(word.dropFirst("--relay=".count))
        } else if takesRelay && word == "--insecure" {
            arguments.insecure = true
        } else if command == "send-file" && word == "--caption" {
            arguments.caption = try value(word)
        } else if command == "send-file" && word.hasPrefix("--caption=") {
            arguments.caption = String(word.dropFirst("--caption=".count))
        } else if word.hasPrefix("-") || arguments.positionals.count == wanted {
            throw UsageError(message: "unrecognized arguments: \(word)")
        } else {
            arguments.positionals.append(word)
        }
    }
    if command == "read-receipts" {
        guard arguments.positionals.allSatisfy({ $0 == "on" || $0 == "off" }) else {
            throw UsageError(message: "argument state: invalid choice: '\(arguments.positionals[0])' (choose from 'on', 'off')")
        }
        return arguments
    }
    guard arguments.positionals.count == wanted else {
        throw UsageError(message: "the following arguments are required: \(["add": "name, user_id", "chat": "name", "reset": "name", "send-file": "name, path"][command]!)")
    }
    return arguments
}

func storeDirectory(_ arguments: Arguments) -> URL {
    URL(fileURLWithPath: arguments.dataDirectory, isDirectory: true)
}

func openStore(_ arguments: Arguments) throws -> ClientStore {
    let directory = storeDirectory(arguments)
    do {
        if !StoreKeys.isUnlocked(directory) {
            let context = LAContext()
            context.localizedReason = "open the chats of \(arguments.dataDirectory)"
            try StoreKeys.unlock(directory, protection: StoreProtection.asked(for: directory), context: context)
        }
        return try ClientStore(directory: directory)
    } catch StoreError.wideMode(let path, let mode) {
        throw CommandError(message: "\(arguments.dataDirectory) or its store is open to others: \(path) has mode \(String(format: "%04o", mode)): the group or others have a right")
    }
}

/// The client of the data directory.
func openClient(_ arguments: Arguments) throws -> Client {
    let path = storeDirectory(arguments).appendingPathComponent(ClientStore.fileName).path
    guard FileManager.default.fileExists(atPath: path) else {
        throw CommandError(message: "\(arguments.dataDirectory) holds no identity; run sotto-mac init")
    }
    return try Client(store: openStore(arguments))
}

func names(_ client: Client) throws -> [Data: String] {
    var names: [Data: String] = [:]
    for contact in try client.store.contacts() {
        names[contact.identityKey] = contact.name ?? ""
    }
    return names
}

func contactNamed(_ client: Client, _ name: String) throws -> Data {
    guard let contact = try client.store.contacts().first(where: { $0.name == name }) else {
        throw CommandError(message: "no contact is named \(name); sotto-mac add names one")
    }
    return contact.identityKey
}

func makeTransport(_ client: sending Client, _ arguments: Arguments) throws -> Transport {
    do {
        return try Transport(
            client: client,
            url: arguments.relay,
            insecure: arguments.insecure,
            downloads: .folder(storeDirectory(arguments).appendingPathComponent(receivedFolder))
        )
    } catch let error as URLRefusedError {
        throw CommandError(message: "the relay URL is refused: \(error.message)")
    }
}

func displayName(_ contact: Data, _ names: [Data: String]) -> String {
    if let name = names[contact], !name.isEmpty {
        return name
    }
    return (try? Identity.encodeUserID(contact)) ?? ""
}

/// Prints an event; `progress` keeps the tenth of each transfer last printed.
func printEvent(_ event: TransportEvent, _ names: [Data: String], _ progress: inout [Data: Int]) {
    switch event {
    case .connected:
        say("connected")
    case .incoming(let sender, let received):
        let name = displayName(sender, names)
        if received.missing > 0 {
            say("\(name): \(received.missing) earlier messages can never be read")
        }
        printReceived(received, name)
    case .written(_, let position, let text, let replyTo, let expiresAfter):
        let reply = replyTo.map { ", replying to #\($0)" } ?? ""
        say("\(messageHead(position, "you", expiresAfter))\(reply): \(printable(text))")
    case .sent(let position):
        say("#\(position) sent")
    case .expired(let positions):
        positions.forEach { say("#\($0) disappeared") }
    case .refused(let result, nil):
        say("the relay refused the prekey upload (\(result))")
    case .refused(let result, let contact?):
        say("not sent to \(displayName(contact, names)): the relay refused it (\(result))")
    case .retrying(let seconds):
        say("not connected; next attempt in \(String(format: "%.0f", seconds)) s")
    case .stopped(let reason):
        say("stopped: \(reason)")
    case .transferFailed(let reason):
        say("a transfer stopped and goes on after the next login: \(reason)")
    case .file(let update):
        printFileUpdate(update, displayName(update.contact, names), &progress)
    }
}

/// One line for a message, a change of part 5 or a failure; several for a receipt.
func printReceived(_ received: Received, _ name: String) {
    if received.edited {
        say("#\(received.position ?? 0) \(name) edited: \(printable(received.text ?? ""))")
    } else if received.deleted {
        say("#\(received.position ?? 0) \(name) deleted the message")
    } else if !received.marked.isEmpty {
        received.marked.forEach { say("#\($0) \(received.read ? "read" : "delivered")") }
    } else if let timer = received.timer {
        say("\(name) set the timer: \(describeTimer(timer))")
    } else if let text = received.text {
        say("\(receivedHead(received, name)): \(printable(text))")
    } else if let profile = received.profile {
        say("\(name): \(describeProfile(profile))")
    } else if let attachment = received.attachment {
        let caption = attachment.caption.isEmpty ? "" : ": \(printable(attachment.caption))"
        say("\(receivedHead(received, name)): file \(printable(attachment.fileName)), \(attachment.size) bytes\(caption)")
    } else if let result = received.result, !silentResults.contains(result) {
        say("\(name): a message could not be read (\(result))")
    }
}

func receivedHead(_ received: Received, _ name: String) -> String {
    let head = messageHead(received.position, name, received.expiresAfter)
    guard let quote = received.quote else {
        return head
    }
    return "\(head), replying to \(describeQuote(quote))"
}

/// `#12 alice`, with the timer of the message as `(1h)` behind it when it has one.
func messageHead(_ position: Int64?, _ who: String, _ expiresAfter: Int) -> String {
    var head = position.map { "#\($0) \(who)" } ?? who
    if expiresAfter > 0 {
        head += " (\(describeTimer(expiresAfter)))"
    }
    return head
}

func describeQuote(_ quote: Quoted) -> String {
    guard let text = quote.text else {
        return "a message that is gone"
    }
    let shown = String(text.prefix(quoteShown)) + (text.count > quoteShown ? "..." : "")
    let quoted = "\"\(printable(shown))\""
    return quote.position.map { "#\($0) \(quoted)" } ?? quoted
}

/// `off`, or the seconds in the largest unit that divides them.
func describeTimer(_ seconds: Int) -> String {
    guard seconds > 0 else {
        return "off"
    }
    let unit = timerUnits.first { seconds % $0.seconds == 0 }!
    return "\(seconds / unit.seconds)\(unit.unit)"
}

/// The seconds of `off` or of a number with a unit, such as `5m`.
func parseTimer(_ text: String) throws -> Int {
    if text == "off" {
        return 0
    }
    guard let unit = timerUnits.first(where: { text.hasSuffix($0.unit) }),
        case let digits = text.dropLast(), (1...7).contains(digits.count), digits.allSatisfy(\.isASCII),
        let count = Int(digits), count >= 0
    else {
        throw CommandError(message: chatCommands)
    }
    return count * unit.seconds
}

/// One line about a profile that arrived, as the reference prints it.
func describeProfile(_ profile: Sotto_Profile) -> String {
    guard !profile.name.isEmpty || profile.hasAvatar else {
        return "profile cleared"
    }
    let named = profile.name.isEmpty ? "profile without a name" : "profile \"\(printable(profile.name))\""
    return "\(named), \(profile.hasAvatar ? "with an avatar" : "no avatar")"
}

func printFileUpdate(_ update: FileUpdate, _ name: String, _ progress: inout [Data: Int]) {
    if update.avatar {
        // Only the end of an avatar transfer that failed: the profile line said the rest.
        switch update.state {
        case .notSent: say("your avatar was not sent to \(name) (\(update.result ?? ""))")
        case .notReceived, .notAvailable: say("\(name): the avatar \(update.state.rawValue) (\(update.result ?? ""))")
        default: break
        }
        return
    }
    let fileName = printable(update.fileName)
    switch update.state {
    case .sending, .receiving:
        let tenth = progressSteps * update.done / max(update.total, 1)
        if progress[update.blobID] == tenth {
            return
        }
        progress[update.blobID] = tenth
        say("\(update.state.rawValue) \(fileName), \(name): \(100 * tenth / progressSteps)%")
    case .received:
        say("\(name): \(fileName) saved as \(printable(update.path?.path ?? ""))")
    case .sent:
        say("sent \(fileName) to \(name)")
    default:
        say("\(update.state.rawValue): \(fileName), \(name) (\(update.result ?? ""))")
    }
}

/// The first of several outcomes; the others are left to run.
func first(_ one: @escaping @Sendable () async -> Outcome, _ other: @escaping @Sendable () async -> Outcome) async -> Outcome {
    let (stream, sink) = AsyncStream<Outcome>.makeStream()
    for outcome in [one, other] {
        Task { sink.yield(await outcome()) }
    }
    var iterator = stream.makeAsyncIterator()
    return await iterator.next()!
}

/// Feeds stdin to a stream from a thread of its own; /quit or the end of input ends both
/// streams, the second one at once and the first one after its lines.
func readLines() -> (lines: AsyncStream<String>, leaving: AsyncStream<Void>) {
    let (lines, sink) = AsyncStream<String>.makeStream()
    let (leaving, leave) = AsyncStream<Void>.makeStream()
    Thread {
        while var line = readLine(strippingNewline: true) {
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            if line == quit {
                break
            }
            sink.yield(line)
        }
        sink.finish()
        leave.finish()
    }.start()
    return (lines, leaving)
}

func sendLine(_ transport: Transport, _ contact: Data, _ line: String) async {
    do {
        try await runLine(transport, contact, line)
    } catch let error as CommandError {
        say(error.message)
    } catch EnvelopeError.textTooLong {
        say("not sent: the text is too long")
    } catch let error as RefusedError {
        say("not sent: the relay refused the bundle (\(error.result))")
    } catch let error as CryptoError {
        say("not sent: \(error.result)")
    } catch let error as ChangeError {
        say("not sent: \(error.result)")
    } catch let error as EnvelopeError {
        say("not sent: \(error.result)")
    } catch let error as SessionError {
        say("not sent: \(error.result)")
    } catch is CancellationError {
        return
    } catch {
        complain("sotto-mac: \(error)")
        exit(1)
    }
}

/// Sends a typed line as a text, or runs the chat command of part 5 that it starts with.
func runLine(_ transport: Transport, _ contact: Data, _ line: String) async throws {
    guard line.hasPrefix("/") else {
        try await transport.sendText(contact, line)
        return
    }
    let (command, rest) = split(line)
    switch command {
    case "/reply":
        let (position, text) = try positionAndText(rest)
        try await transport.sendText(contact, text, replyTo: position)
    case "/edit":
        let (position, text) = try positionAndText(rest)
        try await transport.edit(contact, position, text)
        say("#\(position) you edited: \(printable(text))")
    case "/delete":
        let position = try number(rest)
        try await transport.delete(contact, position)
        say("#\(position) deleted for both")
    case "/timer":
        if !rest.isEmpty {
            try await transport.setTimer(contact, seconds: parseTimer(rest))
        }
        say("timer: \(describeTimer(try await transport.withClient { try $0.timer(contact) }))")
    default:
        throw CommandError(message: chatCommands)
    }
}

/// The text up to the first space, and the text after it.
func split(_ text: String) -> (String, String) {
    guard let space = text.firstIndex(of: " ") else {
        return (text, "")
    }
    return (String(text[..<space]), String(text[text.index(after: space)...]))
}

func positionAndText(_ rest: String) throws -> (Int64, String) {
    let (position, text) = split(rest)
    guard !text.isEmpty else {
        throw CommandError(message: chatCommands)
    }
    return (try number(position), text)
}

func number(_ text: String) throws -> Int64 {
    guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int64(text) else {
        throw CommandError(message: chatCommands)
    }
    return value
}

/// Prints an event of `chat`; a message of the chat that it printed counts as read (39.5).
func show(_ transport: Transport, _ event: TransportEvent, _ names: [Data: String], _ progress: inout [Data: Int]) async {
    printEvent(event, names, &progress)
    if case .incoming(let sender, let received) = event, received.isANewMessage, let position = received.position {
        try? await transport.markRead(sender, [position])
    }
}

/// Ends the transport and prints what it reported.
func finish(_ transport: Transport, _ runner: Task<Void, Error>, _ names: [Data: String], printer: Task<Void, Never>?) async {
    await transport.stop()
    runner.cancel()
    if case .failure(let error) = await runner.result, !(error is CancellationError) {
        complain("sotto-mac: \(error)")
    }
    if let printer {
        await printer.value
    } else {
        var progress: [Data: Int] = [:]
        for await event in transport.events {
            printEvent(event, names, &progress)
        }
    }
}

func chat(_ arguments: Arguments) async throws -> Int32 {
    let client = try openClient(arguments)
    let contact = try contactNamed(client, arguments.positionals[0])
    let names = try names(client)
    say("timer: \(describeTimer(try client.timer(contact)))")
    let transport = try makeTransport(client, arguments)

    let runner = Task { try await transport.run() }
    let printer = Task {
        var progress: [Data: Int] = [:]
        for await event in transport.events {
            await show(transport, event, names, &progress)
        }
    }
    let (lines, leaving) = readLines()
    let typing = Task {
        for await line in lines where !line.isEmpty {
            await sendLine(transport, contact, line)
        }
    }

    let outcome = await first(
        { _ = await runner.result; return .stopped },
        { for await _ in leaving {}; return .leaving }
    )
    if outcome == .leaving {
        // The lines typed before /quit go out, unless a send waits for the relay.
        _ = await first(
            { await typing.value; return .done },
            { try? await Task.sleep(nanoseconds: UInt64(quitGraceSeconds * 1_000_000_000)); return .done }
        )
    }
    typing.cancel()
    await finish(transport, runner, names, printer: printer)
    return outcome == .stopped ? 1 : 0
}

enum Outcome: Sendable {
    case stopped, leaving, done
}

func reset(_ arguments: Arguments) async throws -> Int32 {
    let name = arguments.positionals[0]
    let client = try openClient(arguments)
    let contact = try contactNamed(client, name)
    let names = try names(client)
    let transport = try makeTransport(client, arguments)

    let runner = Task { try await transport.run() }
    let resetting = Task { try await transport.resetSession(contact) }
    _ = await first(
        { _ = await runner.result; return .stopped },
        { _ = await resetting.result; return .done }
    )
    await finish(transport, runner, names, printer: nil)

    switch await resetting.result {
    case .success(let missing):
        say("a new session with \(name) starts with the next message")
        if missing > 0 {
            say("\(name): \(missing) earlier messages can never be read")
        }
        return 0
    case .failure(let error as RefusedError):
        throw CommandError(message: "the relay has no bundle of \(name): \(error.result)")
    case .failure(let error as CryptoError):
        throw CommandError(message: "the bundle of \(name) is refused: \(error.result)")
    case .failure(is CancellationError):
        return 1
    case .failure(let error):
        throw error
    }
}

/// Sends a file and prints the events until it is sent or not sent. A file whose sending
/// stops with the command goes on at the next `chat` or `send-file`.
func sendFile(_ arguments: Arguments) async throws -> Int32 {
    let client = try openClient(arguments)
    let contact = try contactNamed(client, arguments.positionals[0])
    let path = URL(fileURLWithPath: arguments.positionals[1])
    let names = try names(client)
    let transport = try makeTransport(client, arguments)
    let caption = arguments.caption

    let runner = Task { try await transport.run() }
    let sending = Task { try await transport.sendFile(contact, file: path, caption: caption) }
    let outcome = await first(
        { _ = await runner.result; return .stopped },
        { _ = await sending.result; return .done }
    )
    if outcome == .stopped {
        await finish(transport, runner, names, printer: nil)
        return 1
    }

    let blobID: Data
    do {
        blobID = try await sending.value
    } catch {
        await transport.stop()
        runner.cancel()
        _ = await runner.result
        switch error {
        case let error as FileError: throw CommandError(message: "not sent: \(error.result)")
        case let error as SessionError: throw CommandError(message: "not sent: \(error.result)")
        case is InvalidInputError: throw CommandError(message: "not sent: the caption is too long")
        default: throw CommandError(message: "cannot read \(arguments.positionals[1]): \(readFailure(error))")
        }
    }

    var progress: [Data: Int] = [:]
    var status: Int32 = 1
    for await event in transport.events {
        printEvent(event, names, &progress)
        if case .transferFailed = event {
            break
        }
        if case .file(let update) = event, update.blobID == blobID, update.state == .sent || update.state == .notSent {
            status = update.state == .sent ? 0 : 1
            break
        }
    }
    await transport.stop()
    runner.cancel()
    _ = await runner.result
    return status
}

/// The text of the system error under an error of reading a file.
func readFailure(_ error: Error) -> String {
    let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
    if let underlying, underlying.domain == NSPOSIXErrorDomain {
        return String(cString: strerror(Int32(underlying.code)))
    }
    return (error as NSError).localizedDescription
}

func run(_ arguments: Arguments) async throws -> Int32 {
    switch arguments.command {
    case "init":
        let path = storeDirectory(arguments).appendingPathComponent(ClientStore.fileName).path
        if FileManager.default.fileExists(atPath: path) {
            throw CommandError(message: "\(arguments.dataDirectory) already holds an identity")
        }
        let client = try Client(store: openStore(arguments))
        say(try Identity.encodeUserID(client.identityKey))
    case "id":
        say(try Identity.encodeUserID(openClient(arguments).identityKey))
    case "add":
        let (name, userID) = (arguments.positionals[0], arguments.positionals[1])
        guard name.range(of: #"^[A-Za-z0-9_.-]{1,32}$"#, options: .regularExpression) != nil else {
            throw CommandError(message: "a name is 1 to 32 letters, digits, '.', '_' or '-'")
        }
        let client = try openClient(arguments)
        if try names(client).values.contains(name) {
            throw CommandError(message: "the name \(name) is taken")
        }
        let contact: Data
        do {
            contact = try client.addContact(userID, name: name)
        } catch is CryptoError {
            throw CommandError(message: "that is not a user id")
        } catch is OwnIdentityError {
            throw CommandError(message: "that is the id of this identity")
        }
        say("\(try names(client)[contact] ?? "") \(try Identity.encodeUserID(contact))")
    case "contacts":
        for contact in try openClient(arguments).store.contacts() {
            say("\(contact.name ?? "") \(try Identity.encodeUserID(contact.identityKey))")
        }
    case "chat":
        return try await chat(arguments)
    case "read-receipts":
        let client = try openClient(arguments)
        if let state = arguments.positionals.first {
            try client.setReadReceipts(state == "on")
        }
        say("read receipts: \(try client.readReceipts() ? "on" : "off")")
    case "send-file":
        return try await sendFile(arguments)
    case "test-query":
        let store = try openStore(arguments)
        defer { store.close() }
        FileHandle.standardOutput.write(try store.testRowsJSON(arguments.positionals[0]) + Data("\n".utf8))
    default:
        return try await reset(arguments)
    }
    return 0
}

setvbuf(stdout, nil, _IOLBF, 0)
let status: Int32
do {
    status = try await run(parse(Array(CommandLine.arguments.dropFirst())))
} catch let error as UsageError {
    complain(usage)
    complain("sotto-mac: error: \(error.message)")
    status = 2
} catch let error as CommandError {
    complain("sotto-mac: \(error.message)")
    status = 1
} catch {
    complain("sotto-mac: \(error)")
    status = 1
}
exit(status)
