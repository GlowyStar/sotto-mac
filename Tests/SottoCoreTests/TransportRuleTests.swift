import Foundation
@testable import SottoCore
import Testing

@Test(arguments: [
    ("wss://Relay.Example.org:8443/ws", false, "relay.example.org"),
    ("ws://127.0.0.1:8765/ws", false, "127.0.0.1"),
    ("ws://127.200.3.4/ws", false, "127.200.3.4"),
    ("ws://localhost:8765/ws", false, "localhost"),
    ("ws://[::1]:8765/ws", false, "::1"),
    ("ws://[0:0:0:0:0:0:0:1]/ws", false, "0:0:0:0:0:0:0:1"),
    ("ws://127.1:8765/ws", false, nil),
    ("ws://0127.0.0.1/ws", false, nil),
    ("ws://relay.example.org/ws", false, nil),
    ("ws://relay.example.org/ws", true, "relay.example.org"),
    ("ws://127.1:8765/ws", true, "127.1"),
    ("wss://%72elay.example.org/ws", true, nil),
    ("wss://xn--rlay-6oa.example.org/ws", false, "xn--rlay-6oa.example.org"),
    ("https://relay.example.org/ws", true, nil),
    ("ws:///ws", true, nil),
] as [(String, Bool, String?)])
func urlRulesOfSections8_2And23_1(url: String, insecure: Bool, serverName: String?) throws {
    guard let serverName else {
        #expect(throws: URLRefusedError.self) { try Transport.serverName(of: url, insecure: insecure) }
        return
    }
    #expect(try Transport.serverName(of: url, insecure: insecure) == serverName)
}

@Test func waitsFollowTheSchedules() {
    let longest = (1...8).map { Transport.retrySeconds($0, jitter: { $0 }) }
    let shortest = (1...8).map { Transport.backOffSeconds($0, jitter: { _ in 0 }) }

    #expect(longest == [1.5, 3, 6, 12, 24, 48, 90, 90])
    #expect(shortest == [1, 2, 4, 8, 16, 32, 60, 60])
    #expect(Transport.retrySeconds(10_000, jitter: { _ in 0 }) == 60)
}

@Test(arguments: [
    (1003, TransportAction.stop), (1008, .stop), (1009, .stop), (3000, .stop), (4001, .stop),
    (1000, .retry), (1001, .retry), (1006, .retry), (1011, .retry), (3008, .retry), (4999, .retry), (nil, .retry),
] as [(Int?, TransportAction)])
func closeCodesGetTheActionOfSection11_3(code: Int?, action: TransportAction) {
    #expect(Transport.closeAction(code) == action)
}

@Test(arguments: [
    (Sotto_ErrorCode.unknownRecipient.rawValue, TransportAction.stop),
    (Sotto_ErrorCode.queueFull.rawValue, .backOff),
    (Sotto_ErrorCode.storageFull.rawValue, .backOff),
    (Sotto_ErrorCode.rateLimited.rawValue, .backOff),
    (Sotto_ErrorCode.notFound.rawValue, .stop),
    (Sotto_ErrorCode.badBundle.rawValue, .stop),
    (Sotto_ErrorCode.identityKeyMismatch.rawValue, .stop),
    (0, .stop),
    (99, .stop),
])
func errorCodesGetTheActionOfSection11_2(code: Int, action: TransportAction) {
    #expect(Transport.errorAction(code) == action)
}

@Test func errorNamesAreThoseOfTheSchema() {
    #expect(Transport.errorName(Sotto_ErrorCode.rateLimited.rawValue) == "RATE_LIMITED")
    #expect(Transport.errorName(Sotto_ErrorCode.identityKeyMismatch.rawValue) == "IDENTITY_KEY_MISMATCH")
    #expect(Transport.errorName(99) == "error code 99")
}

@Test func peerTextIsPrintedWithControlCharactersEscaped() {
    let text = "\u{1b}[2J\u{1b}]0;title\u{07} \u{202e}evil\u{2069}\u{9b}\u{00}\u{7f}\nnext\u{2028}"

    #expect(printable(text) == "\\x1b[2J\\x1b]0;title\\x07 \\u202eevil\\u2069\\x9b\\x00\\x7f\\x0anext\\u2028")
    #expect(printable("plain text, \u{e9}t\u{e9} \u{1F600}") == "plain text, \u{e9}t\u{e9} \u{1F600}")
}

@Test func proxyOfTheEnvironmentIsNotUsed() throws {
    let proxies = try #require(URLSessionDialer.configuration.connectionProxyDictionary)
    for key in [kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesSOCKSEnable,
                kCFNetworkProxiesProxyAutoConfigEnable, kCFNetworkProxiesProxyAutoDiscoveryEnable] {
        #expect(proxies[key] as? Bool == false)
    }
}
