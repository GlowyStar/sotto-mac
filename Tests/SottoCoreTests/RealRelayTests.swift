import Foundation
@testable import SottoCore
import Testing

/// `sotto-relay` of the Python project next to this repository, run as a subprocess on a
/// free port with its database in a folder of its own.
final class RealRelay: @unchecked Sendable {
    static let python = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("../../python/sotto").standardizedFileURL
    static let executable = python.appendingPathComponent(".venv/bin/sotto-relay")
    static let isAvailable = FileManager.default.isExecutableFile(atPath: executable.path)

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sotto-relay-\(UUID().uuidString)")
    let port: Int
    private let process: Process

    var url: String {
        "ws://127.0.0.1:\(port)/ws"
    }

    var database: URL {
        folder.appendingPathComponent("relay.db")
    }

    init() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        port = try Self.freePort()
        process = Process()
        process.executableURL = Self.executable
        process.environment = [
            "RELAY_DATABASE": folder.appendingPathComponent("relay.db").path,
            "RELAY_PORT": String(port),
            "PATH": "/usr/bin:/bin",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let health = URL(string: "http://127.0.0.1:\(port)/healthz")!
        let session = URLSession(configuration: URLSessionDialer.configuration)
        try await until {
            let answer = try? await session.data(from: health)
            return (answer?.1 as? HTTPURLResponse)?.statusCode == 200
        }
    }

    /// Ends the process with SIGTERM, waits for it and removes its folder.
    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: folder)
    }

    private static func freePort() throws -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else {
            throw SocketError.closed(code: nil)
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

@Suite(
    .serialized,
    .timeLimit(.minutes(1)),
    .enabled(if: RealRelay.isAvailable, "the Python project with its .venv is not at ../../python/sotto")
)
struct RealRelayTests {
    let folder = Folder()

    func key(_ name: String) throws -> Data {
        try folder.identityKey(name)
    }

    @Test func loginUploadAndAMessageBetweenTwoSwiftClients() async throws {
        let relay = try await RealRelay()
        defer { relay.stop() }
        try befriend(folder, "alice", "bob")
        let bob = try await run(folder.open("bob"), URLSessionDialer(), url: relay.url)
        let alice = try await run(folder.open("alice"), URLSessionDialer(), url: relay.url)
        try await until { try await isRegistered(bob.transport) }
        try await until { try await isRegistered(alice.transport) }

        try await alice.transport.sendText(key("bob"), "hello bob")
        #expect(try await nextText(bob.transport) == (key("alice"), "hello bob"))
        try await bob.transport.sendText(key("alice"), "hello alice")
        #expect(try await nextText(alice.transport) == (key("bob"), "hello alice"))
        try await until { try await outbox(alice.transport).isEmpty }
        await alice.stop()
        await bob.stop()
    }

    @Test func offlinePeerReceivesAfterItConnectsAndTheMarkerIsInNoFileOfTheRelay() async throws {
        let relay = try await RealRelay()
        defer { relay.stop() }
        try befriend(folder, "alice", "bob")
        var bob = try await run(folder.open("bob"), URLSessionDialer(), url: relay.url)
        try await until { [bob] in try await isRegistered(bob.transport) }
        await bob.stop()

        let marker = "sotto marker 4f1c9e"
        let alice = try await run(folder.open("alice"), URLSessionDialer(), url: relay.url)
        try await alice.transport.sendText(key("bob"), marker)
        try await until { try await outbox(alice.transport).isEmpty }
        await alice.stop()

        let forms = [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian].map { marker.data(using: $0)! }
        func traces() throws -> Int {
            let files = try FileManager.default.contentsOfDirectory(at: relay.folder, includingPropertiesForKeys: nil)
            return try files.map { try Data(contentsOf: $0) }.filter { content in
                forms.contains { content.range(of: $0) != nil }
            }.count
        }
        #expect(try traces() == 0)

        bob = try await run(folder.open("bob"), URLSessionDialer(), url: relay.url)
        #expect(try await nextText(bob.transport) == (key("alice"), marker))
        await bob.stop()
        #expect(try traces() == 0)
    }

    @Test func replacedLoginIsClosedWith4001AndStops() async throws {
        let relay = try await RealRelay()
        defer { relay.stop() }
        _ = try folder.open("alice")
        try FileManager.default.copyItem(
            at: folder.url.appendingPathComponent("alice"),
            to: folder.url.appendingPathComponent("alice-again")
        )
        let first = try await run(folder.open("alice"), URLSessionDialer(), url: relay.url)

        let second = try await run(folder.open("alice-again"), URLSessionDialer(), url: relay.url)
        _ = await first.task.result

        #expect(try await nextEvent(first.transport) { _ in true } == .stopped(reason: "the relay closed the connection with 4001"))
        await second.stop()
    }
}
