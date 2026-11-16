import Foundation
import SwiftProtobuf

/// A named local result of the peer envelope and the plaintext (section 19).
public enum EnvelopeError: Error, Equatable, Sendable {
    case unsupportedVersion
    case badEnvelope
    case badPadding
    case badContent
    case unknownContent
    case textTooLong

    public var result: String {
        switch self {
        case .unsupportedVersion: "UNSUPPORTED_VERSION"
        case .badEnvelope: "BAD_ENVELOPE"
        case .badPadding: "BAD_PADDING"
        case .badContent: "BAD_CONTENT"
        case .unknownContent: "UNKNOWN_CONTENT"
        case .textTooLong: "TEXT_TOO_LONG"
        }
    }
}

/// The peer envelope and the plaintext of docs/protocol.md, section 19.
public enum Envelope {
    public static let version: UInt32 = 1
    public static let paddingBlock = 256
    public static let maxTextBytes = 65019
    public static let paddingMark: UInt8 = 0x80
    public static let sealingOverhead = Ratchet.messageNonceLength + Ratchet.tagLength

    /// Returns P of section 19.6: the content, `80`, then `00` up to the next block.
    public static func pad(_ content: Data) -> Data {
        let paddedLength = paddingBlock * (content.count / paddingBlock + 1)
        var padded = content
        padded.append(paddingMark)
        padded.append(Data(count: paddedLength - padded.count))
        return padded
    }

    /// Returns the content in front of the last byte that is not `00`, which has to be `80`.
    public static func unpad(_ padded: Data) throws -> Data {
        guard let last = padded.lastIndex(where: { $0 != 0 }), padded[last] == paddingMark else {
            throw EnvelopeError.badPadding
        }
        return Data(padded[padded.startIndex..<last])
    }

    /// Returns the padded plaintext of a text.
    public static func encodeText(_ text: String) throws -> Data {
        guard text.utf8.count <= maxTextBytes else {
            throw EnvelopeError.textTooLong
        }
        var content = Sotto_Content()
        content.text = text
        return pad(try content.serializedBytes())
    }

    /// Returns the text of a padded plaintext by sections 19.5 and 19.6.
    public static func decodeText(_ padded: Data) throws -> String {
        let content: Sotto_Content
        do {
            content = try Sotto_Content(serializedBytes: try unpad(padded))
        } catch let error as EnvelopeError {
            throw error
        } catch {
            throw EnvelopeError.badContent
        }
        guard case .text(let text) = content.body else {
            throw EnvelopeError.unknownContent
        }
        return text
    }

    /// Turns a payload into an envelope by the three steps of section 19.4.
    public static func parse(_ payload: Data) throws -> Sotto_PeerMessage {
        let envelope: Sotto_PeerMessage
        do {
            envelope = try Sotto_PeerMessage(serializedBytes: payload)
        } catch {
            throw EnvelopeError.badEnvelope
        }

        guard envelope.version == version else {
            throw EnvelopeError.unsupportedVersion
        }

        let paddedLength = envelope.ciphertext.count - sealingOverhead
        guard envelope.header.count == Ratchet.headerLength,
              paddedLength >= paddingBlock,
              paddedLength % paddingBlock == 0
        else {
            throw EnvelopeError.badEnvelope
        }

        if envelope.hasInitialHeader {
            let initialHeader = envelope.initialHeader
            guard initialHeader.identityDhKey.count == Identity.keyLength,
                  initialHeader.identityDhSignature.count == Identity.signatureLength,
                  initialHeader.ephemeralKey.count == Identity.keyLength
            else {
                throw EnvelopeError.badEnvelope
            }
        }
        return envelope
    }
}
