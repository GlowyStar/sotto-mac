import Foundation
import SottoCore
import Testing

private let goodInitialHeader: Sotto_InitialHeader = {
    var header = Sotto_InitialHeader()
    header.identityDhKey = Data(count: 32)
    header.identityDhSignature = Data(count: 64)
    header.ephemeralKey = Data(count: 32)
    return header
}()

private func envelope(_ change: (inout Sotto_PeerMessage) -> Void = { _ in }) throws -> Data {
    var message = Sotto_PeerMessage()
    message.version = 1
    message.header = Data(count: 40)
    message.ciphertext = Data(count: 284)
    change(&message)
    return try message.serializedBytes()
}

private func content(text: String) throws -> Data {
    var content = Sotto_Content()
    content.text = text
    return try content.serializedBytes()
}

@Test func constantsAreThoseOfSection24() {
    #expect(Envelope.paddingBlock == 256)
    #expect(Envelope.maxTextBytes == 65019)
}

@Test(arguments: [(0, 256), (1, 256), (255, 256), (256, 512)])
func paddingAddsTheMarkAndZeroBytesUpToTheNextBlock(contentLength: Int, paddedLength: Int) {
    let content = Data(repeating: 1, count: contentLength)

    let padded = Envelope.pad(content)

    #expect(padded.count == paddedLength)
    #expect(padded == content + Data([0x80]) + Data(count: paddedLength - contentLength - 1))
}

@Test func receiverTakesTheContentInFrontOfTheMarkBehindAnyZeroBytes() throws {
    for length in stride(from: 0, through: 1000, by: 37) {
        let scalars = (0..<length).map { Unicode.Scalar(UInt8(($0 * 7 + length) % 256)) }
        let text = String(String.UnicodeScalarView(scalars))
        for extraZeros in [0, 1, 255, 600] {
            let padded = try Envelope.encodeText(text) + Data(count: extraZeros)

            #expect(try Envelope.decodeText(padded) == text)
        }
    }
}

@Test(arguments: [Data(), Data(count: 256), Data([0x0A, 0x00, 0x81]) + Data(count: 253)])
func plaintextWithoutPaddingIsBadPadding(padded: Data) {
    #expect(throws: EnvelopeError.badPadding) { try Envelope.decodeText(padded) }
}

@Test func contentThatDoesNotParseOrIsNotUTF8IsBadContent() {
    for content in [Data([0x0A, 0x05, 0x61, 0x62]), Data([0x0A, 0x02, 0xFF, 0xFE])] {
        #expect(throws: EnvelopeError.badContent) { try Envelope.decodeText(Envelope.pad(content)) }
    }
}

@Test func contentWithoutAKnownMemberIsUnknownContent() {
    for content in [Data(), Data([0x12, 0x01, 0x78])] {
        #expect(throws: EnvelopeError.unknownContent) { try Envelope.decodeText(Envelope.pad(content)) }
    }
}

@Test func largestTextFills254BlocksAndOneByteMoreIsRefused() throws {
    let largest = String(repeating: "x", count: Envelope.maxTextBytes)

    #expect(try content(text: largest).count == 65023)
    #expect(try Envelope.encodeText(largest).count == 254 * Envelope.paddingBlock)
    #expect(try Envelope.encodeText("").count == Envelope.paddingBlock)
    #expect(throws: EnvelopeError.textTooLong) { try Envelope.encodeText(largest + "x") }
    #expect(throws: EnvelopeError.textTooLong) {
        try Envelope.encodeText(String(repeating: "\u{E9}", count: Envelope.maxTextBytes / 2 + 1))
    }
}

@Test func wellFormedEnvelopeParsesWithAndWithoutAnInitialHeader() throws {
    _ = try Envelope.parse(try envelope())
    _ = try Envelope.parse(try envelope { $0.ciphertext = Data(count: 28 + 512) })
    let parsed = try Envelope.parse(try envelope { $0.initialHeader = goodInitialHeader } + Data([0x2A, 0x01, 0x00]))

    #expect(parsed.initialHeader == goodInitialHeader)
}

@Test func payloadThatIsNoPeerMessageIsBadEnvelope() {
    for payload in [Data([0xFF]), Data([0x0A, 0x05, 0x61, 0x62]), Data([0x08])] {
        #expect(throws: EnvelopeError.badEnvelope) { try Envelope.parse(payload) }
    }
}

@Test(arguments: [0, 2, 3, 255, 65536, UInt32.max])
func otherVersionIsReadBeforeAnyOtherRule(version: UInt32) throws {
    let payload = try envelope {
        $0.version = version
        $0.header = Data()
        $0.ciphertext = Data()
    }

    #expect(throws: EnvelopeError.unsupportedVersion) { try Envelope.parse(payload) }
}

@Test func fieldThatBreaksItsLengthIsBadEnvelope() throws {
    let changes: [(inout Sotto_PeerMessage) -> Void] = [
        { $0.header = Data(count: 39) },
        { $0.header = Data(count: 41) },
        { $0.ciphertext = Data(count: 283) },
        { $0.ciphertext = Data(count: 285) },
        { $0.ciphertext = Data(count: 28) },
        { $0.initialHeader.identityDhKey = Data(count: 31) },
        {
            $0.initialHeader.identityDhKey = Data(count: 32)
            $0.initialHeader.identityDhSignature = Data(count: 63)
        },
        {
            $0.initialHeader.identityDhKey = Data(count: 32)
            $0.initialHeader.identityDhSignature = Data(count: 64)
            $0.initialHeader.ephemeralKey = Data()
        },
    ]
    for change in changes {
        let payload = try envelope(change)

        #expect(throws: EnvelopeError.badEnvelope) { try Envelope.parse(payload) }
    }
}
