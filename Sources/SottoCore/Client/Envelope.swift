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
    case badTimer

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
        case .badTimer: "BAD_TIMER"
        }
    }
}

/// The peer envelope and the plaintext of docs/protocol.md, sections 19, 32, 35 and 38.
public enum Envelope {
    public static let version: UInt32 = 1
    public static let paddingBlock = 256
    public static let maxTextBytes = 65019
    public static let maxContentBytes = 65023
    public static let paddingMark: UInt8 = 0x80
    public static let sealingOverhead = Ratchet.messageNonceLength + Ratchet.tagLength
    public static let maxMediaTypeBytes = 127
    public static let maxFileNameBytes = 255
    public static let maxThumbnailBytes = 16384
    public static let maxCaptionBytes = 4096
    public static let maxProfileNameBytes = 256
    public static let maxAvatarBytes = 1_048_576
    public static let messageIDLength = 16
    public static let maxQuoteBytes = 256
    public static let maxTimerSeconds = 2_419_200
    public static let maxReceiptIDs = 1000
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

    /// Returns the padded plaintext of a text, a reply when it has a quote (section 38.2).
    ///
    /// - Throws: `EnvelopeError.textTooLong` when the text is longer than `maxTextBytes`, or
    ///   the content with its quote and timer longer than `maxContentBytes`;
    ///   `EnvelopeError.badTimer` when `expiresAfter` is above `maxTimerSeconds`;
    ///   `InvalidInputError` when the quote breaks its limits of section 38.2.
    public static func encodeText(_ text: String, quote: Sotto_Quote? = nil, expiresAfter: Int = 0) throws -> Data {
        guard text.utf8.count <= maxTextBytes else {
            throw EnvelopeError.textTooLong
        }
        var content = Sotto_Content()
        content.text = text
        return try paddedMessage(content, quote, expiresAfter)
    }

    /// Returns the padded plaintext of an attachment that the client filled (section 32.1).
    ///
    /// - Throws: `InvalidInputError` when a field is beyond its limit of section 32.1 or the
    ///   quote beyond its limits of section 38.2; `EnvelopeError.badTimer`.
    public static func encodeAttachment(_ attachment: Sotto_Attachment, quote: Sotto_Quote? = nil, expiresAfter: Int = 0) throws -> Data {
        try checkLimits(attachment)
        var content = Sotto_Content()
        content.attachment = attachment
        return try paddedMessage(content, quote, expiresAfter)
    }

    /// Returns the padded plaintext of an edit (section 38.2).
    ///
    /// - Throws: `EnvelopeError.textTooLong` when the content is longer than
    ///   `maxContentBytes`; `InvalidInputError` when the id is not `messageIDLength` bytes.
    public static func encodeEdit(messageID: Data, text: String) throws -> Data {
        try requireMessageID(messageID)
        var content = Sotto_Content()
        content.edit.messageID = messageID
        content.edit.text = text
        return try padded(content)
    }

    /// Returns the padded plaintext of a deletion for both (section 38.2).
    public static func encodeDeletion(messageID: Data) throws -> Data {
        try requireMessageID(messageID)
        var content = Sotto_Content()
        content.deletion.messageID = messageID
        return try padded(content)
    }

    /// Returns the padded plaintext of a delivery or a read receipt (section 38.2).
    ///
    /// - Throws: `InvalidInputError` when an id is not `messageIDLength` bytes or there are
    ///   more than `maxReceiptIDs`.
    public static func encodeReceipt(messageIDs: [Data], read: Bool) throws -> Data {
        guard messageIDs.count <= maxReceiptIDs else {
            throw InvalidInputError(message: "a receipt names at most \(maxReceiptIDs) messages")
        }
        try messageIDs.forEach(requireMessageID)
        var content = Sotto_Content()
        content.receipt.read = read
        content.receipt.messageIds = messageIDs
        return try padded(content)
    }

    /// Returns the padded plaintext of a change of the chat timer, 0 for none (section 38.2).
    ///
    /// - Throws: `EnvelopeError.badTimer` when the seconds are above `maxTimerSeconds`.
    public static func encodeTimer(seconds: Int) throws -> Data {
        try requireTimer(seconds)
        var content = Sotto_Content()
        content.timer.seconds = UInt32(seconds)
        return try padded(content)
    }

    /// The longest start of `text` that is at most `limit` bytes of UTF-8.
    public static func cut(_ text: String, to limit: Int) -> String {
        var cut = ""
        var count = 0
        for scalar in text.unicodeScalars {
            count += String(scalar).utf8.count
            guard count <= limit else {
                break
            }
            cut.unicodeScalars.append(scalar)
        }
        return cut
    }

    /// A text or an attachment with the quote and the timer of part 5, padded.
    private static func paddedMessage(_ message: Sotto_Content, _ quote: Sotto_Quote?, _ expiresAfter: Int) throws -> Data {
        try requireTimer(expiresAfter)
        var content = message
        if let quote {
            try requireMessageID(quote.messageID)
            guard quote.text.utf8.count <= maxQuoteBytes else {
                throw InvalidInputError(message: "a quote holds at most \(maxQuoteBytes) bytes of text")
            }
            content.quote = quote
        }
        content.expiresAfter = UInt32(expiresAfter)
        return try padded(content)
    }

    /// The padded plaintext of a content that fits a message whatever its session (38.4).
    private static func padded(_ content: Sotto_Content) throws -> Data {
        let serialized: Data = try content.serializedBytes()
        guard serialized.count <= maxContentBytes else {
            throw EnvelopeError.textTooLong
        }
        return pad(serialized)
    }

    private static func requireMessageID(_ messageID: Data) throws {
        guard messageID.count == messageIDLength else {
            throw InvalidInputError(message: "a message id is \(messageIDLength) bytes, not \(messageID.count)")
        }
    }

    private static func requireTimer(_ seconds: Int) throws {
        guard (0...maxTimerSeconds).contains(seconds) else {
            throw EnvelopeError.badTimer
        }
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

    /// Returns the body of a padded plaintext that `openContent` checked.
    public static func decodeContent(_ padded: Data) throws -> Sotto_Content.OneOf_Body {
        guard let body = try openContent(padded).body else {
            throw EnvelopeError.unknownContent
        }
        return body
    }

    /// Returns the content of a padded plaintext by sections 19.5, 19.6, 32.2, 35.3 and 38.3;
    /// `quote` and `expiresAfter` are cleared unless the body is a text or an attachment,
    /// which alone they go with.
    ///
    /// - Throws: `EnvelopeError.badPadding`; `.badContent` when the content does not parse, a
    ///   string that is not UTF-8 included, or a member breaks a check of section 32.2, 35.3
    ///   or 38.3; `.unknownContent` when it sets no member that this client knows.
    public static func openContent(_ padded: Data) throws -> Sotto_Content {
        var content: Sotto_Content
        do {
            content = try Sotto_Content(serializedBytes: try unpad(padded))
        } catch let error as EnvelopeError {
            throw error
        } catch {
            throw EnvelopeError.badContent
        }
        switch content.body {
        case .text, .attachment:
            if case .attachment(let attachment) = content.body {
                try checkReceived(attachment)
            }
            if content.hasQuote {
                try checkMessageID(content.quote.messageID)
            }
            try checkSeconds(content.expiresAfter)
            return content
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
        case .edit(let edit):
            try checkMessageID(edit.messageID)
        case .deletion(let deletion):
            try checkMessageID(deletion.messageID)
        case .receipt(let receipt):
            try receipt.messageIds.forEach(checkMessageID)
        case .timer(let timer):
            try checkSeconds(timer.seconds)
        case nil:
            throw EnvelopeError.unknownContent
        }
        content.clearQuote()
        content.expiresAfter = 0
        return content
    }

    private static func checkMessageID(_ messageID: Data) throws {
        guard messageID.count == messageIDLength else {
            throw EnvelopeError.badContent
        }
    }

    private static func checkSeconds(_ seconds: UInt32) throws {
        guard seconds <= maxTimerSeconds else {
            throw EnvelopeError.badContent
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
