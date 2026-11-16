import CryptoKit
import Foundation
import SottoCore
import Testing

private let protocolDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Protocol")

@Test func manifestMatchesCopiedFiles() throws {
    let manifest = try String(contentsOf: protocolDir.appendingPathComponent("MANIFEST"), encoding: .utf8)
    let lines = manifest.split(separator: "\n")
    #expect(lines.first?.hasPrefix("sotto ") == true)
    let entries = lines.dropFirst()
    #expect(entries.count == 4)
    for line in entries {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        try #require(parts.count == 2)
        let data = try Data(contentsOf: protocolDir.appendingPathComponent(String(parts[1])))
        let sum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(sum == String(parts[0]), "\(parts[1]) differs from the manifest")
    }
}

@Test func clientFrameRoundTrip() throws {
    var login = Sotto_Login()
    login.identityKey = Data(repeating: 0x11, count: 32)
    login.clientNonce = Data(repeating: 0x22, count: 32)
    login.signature = Data(repeating: 0x33, count: 64)
    var frame = Sotto_ClientFrame()
    frame.login = login

    let bytes: Data = try frame.serializedBytes()
    let decoded = try Sotto_ClientFrame(serializedBytes: bytes)
    #expect(decoded == frame)
    #expect(decoded.login.signature.count == 64)
    // Field 1 of ClientFrame, length-delimited: the oneof case is on the wire.
    #expect(bytes.first == 0x0A)
}
