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
    case badProfileName
    case avatarTooLarge
    case notAnImage

    public var result: String {
        switch self {
        case .unsupportedVersion: "UNSUPPORTED_VERSION"
        case .badEnvelope: "BAD_ENVELOPE"
        case .badPadding: "BAD_PADDING"
        case .badContent: "BAD_CONTENT"
        case .unknownContent: "UNKNOWN_CONTENT"
        case .textTooLong: "TEXT_TOO_LONG"
        case .badProfileName: "BAD_PROFILE_NAME"
        case .avatarTooLarge: "AVATAR_TOO_LARGE"
        case .notAnImage: "NOT_AN_IMAGE"
        }
    }
}

/// The peer envelope and the plaintext of docs/protocol.md, sections 19, 32 and 35.
public enum Envelope {
    public static let version: UInt32 = 1
    public static let paddingBlock = 256
    public static let maxTextBytes = 65019
    public static let paddingMark: UInt8 = 0x80
    public static let sealingOverhead = Ratchet.messageNonceLength + Ratchet.tagLength
    public static let maxMediaTypeBytes = 127
    public static let maxFileNameBytes = 255
    public static let maxThumbnailBytes = 16384
    public static let maxCaptionBytes = 4096
    public static let maxProfileNameBytes = 256
    public static let maxAvatarBytes = 1_048_576
    /// The media types of an avatar and the first bytes of each (section 35.2).
    public static let avatarSignatures: [(mediaType: String, signature: [UInt8])] = [
        ("image/jpeg", [0xff, 0xd8, 0xff]),
        ("image/png", [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    ]

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

    /// Returns the padded plaintext of an attachment that the client filled (section 32.1).
    ///
    /// - Throws: `InvalidInputError` when a field is beyond its limit of section 32.1.
    public static func encodeAttachment(_ attachment: Sotto_Attachment) throws -> Data {
        try checkLimits(attachment)
        var content = Sotto_Content()
        content.attachment = attachment
        return pad(try content.serializedBytes())
    }

    /// Returns the padded plaintext of the client's own profile (section 35.2).
    ///
    /// - Throws: `EnvelopeError.badProfileName`, `.avatarTooLarge` or `.notAnImage`;
    ///   `InvalidInputError` when a field of the avatar is beyond its limit of section 32.1
    ///   or it has a file name or a caption.
    public static func encodeProfile(name: String, avatar: Sotto_Attachment?) throws -> Data {
        guard isProfileName(name) else {
            throw EnvelopeError.badProfileName
        }
        var profile = Sotto_Profile()
        profile.name = name
        if let avatar {
            guard avatar.size <= maxAvatarBytes else {
                throw EnvelopeError.avatarTooLarge
            }
            guard isAvatarType(avatar.mediaType) else {
                throw EnvelopeError.notAnImage
            }
            guard avatar.fileName.isEmpty, avatar.caption.isEmpty else {
                throw InvalidInputError(message: "an avatar has no file name and no caption")
            }
            try checkLimits(avatar)
            profile.avatar = avatar
        }
        var content = Sotto_Content()
        content.profile = profile
        return pad(try content.serializedBytes())
    }

    /// Whether a name keeps the rule of section 35.2: its length and no control character.
    public static func isProfileName(_ name: String) -> Bool {
        name.utf8.count <= maxProfileNameBytes && !name.unicodeScalars.contains(where: isControl)
    }

    /// The media type of an avatar by its first bytes (section 35.2).
    ///
    /// - Throws: `EnvelopeError.notAnImage` when the bytes start with no signature.
    public static func avatarMediaType(_ image: Data) throws -> String {
        guard let found = avatarSignatures.first(where: { image.starts(with: $0.signature) }) else {
            throw EnvelopeError.notAnImage
        }
        return found.mediaType
    }

    static func isAvatarType(_ mediaType: String) -> Bool {
        avatarSignatures.contains { $0.mediaType == mediaType }
    }

    private static func checkLimits(_ attachment: Sotto_Attachment) throws {
        let breaksALimit = attachment.blobID.count != Frames.blobIDLength
            || attachment.key.count != Blob.fileKeyLength
            || attachment.digest.count != Blob.digestLength
            || attachment.size > Blob.maxFileBytes
            || attachment.mediaType.utf8.count > maxMediaTypeBytes
            || attachment.fileName.utf8.count > maxFileNameBytes
            || attachment.thumbnail.count > maxThumbnailBytes
            || attachment.caption.utf8.count > maxCaptionBytes
        guard !breaksALimit else {
            throw InvalidInputError(message: "a field of the attachment is beyond its limit of section 32.1")
        }
    }

    /// Returns the text of a padded plaintext by sections 19.5 and 19.6.
    public static func decodeText(_ padded: Data) throws -> String {
        guard case .text(let text) = try decodeContent(padded) else {
            throw EnvelopeError.unknownContent
        }
        return text
    }

    /// Returns the body of a padded plaintext by sections 19.5, 19.6, 32.2 and 35.3: a text,
    /// an attachment whose lengths hold, or a profile that passes the checks of 35.3.
    public static func decodeContent(_ padded: Data) throws -> Sotto_Content.OneOf_Body {
        let content: Sotto_Content
        do {
            content = try Sotto_Content(serializedBytes: try unpad(padded))
        } catch let error as EnvelopeError {
            throw error
        } catch {
            throw EnvelopeError.badContent
        }
        switch content.body {
        case .text(let text):
            return .text(text)
        case .attachment(let attachment):
            try checkReceived(attachment)
            return .attachment(attachment)
        case .profile(let profile):
            guard isProfileName(profile.name) else {
                throw EnvelopeError.badContent
            }
            if profile.hasAvatar {
                let avatar = profile.avatar
                try checkReceived(avatar)
                guard avatar.size <= maxAvatarBytes, isAvatarType(avatar.mediaType) else {
                    throw EnvelopeError.badContent
                }
            }
            return .profile(profile)
        case nil:
            throw EnvelopeError.unknownContent
        }
    }

    /// The checks of section 32.2.
    private static func checkReceived(_ attachment: Sotto_Attachment) throws {
        let lengths = [attachment.blobID.count, attachment.key.count, attachment.digest.count]
        guard lengths == [Frames.blobIDLength, Blob.fileKeyLength, Blob.digestLength],
              attachment.size <= Blob.maxFileBytes
        else {
            throw EnvelopeError.badContent
        }
    }

    /// A character that section 19.5 escapes: C0, DEL, C1, bidi controls, line separators.
    public static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        let code = scalar.value
        let isBidiControl = code == 0x061C || code == 0x200E || code == 0x200F
            || (0x202A...0x202E).contains(code) || (0x2066...0x2069).contains(code)
        return code < 0x20 || code == 0x7F || (0x80...0x9F).contains(code)
            || isBidiControl || code == 0x2028 || code == 0x2029
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
