import CryptoKit
import Foundation

/// The safety number of docs/protocol.md, part 7 (section 44): libsignal's numeric
/// fingerprint of two identity keys, and the text of its QR code. Pure code over public
/// keys; nothing of it travels.
public struct SafetyNumber: Equatable, Sendable {
    public static let iterations = 5200
    public static let qrPrefix = "sotto-safety-number-1"
    public static let groupDigits = 5
    static let hashVersion = Data([0, 0])
    static let chunkBytes = 5
    static let chunks = 6
    static let chunkModulus: UInt64 = 100_000
    static let scannedBytes = 32

    /// The 60 digits that the user and the contact both compute (section 44.3).
    public let digits: String
    /// The text of the QR code of the user's side, its own half first (section 44.4).
    public let qrPayload: String

    public init(identityKey: Data, contactIdentityKey: Data) throws {
        let own = try Self.fingerprint(identityKey: identityKey)
        let contact = try Self.fingerprint(identityKey: contactIdentityKey)
        digits = [Self.digits(of: own), Self.digits(of: contact)].sorted().joined()
        qrPayload = "\(Self.qrPrefix) \(own.prefix(Self.scannedBytes).hexString) \(contact.prefix(Self.scannedBytes).hexString)"
    }

    /// The twelve groups of five digits, in order (section 44.3).
    public var groups: [String] {
        let characters = Array(digits)
        return stride(from: 0, to: characters.count, by: Self.groupDigits).map {
            String(characters[$0 ..< $0 + Self.groupDigits])
        }
    }

    /// The first input of the chain of section 44.2: the hash version, the key, the stable
    /// identifier and the key again.
    public static func firstInput(key: Data, stableIdentifier: Data) -> Data {
        hashVersion + key + stableIdentifier + key
    }

    /// The 64 bytes of one side: SHA-512 iterated as libsignal's `get_fingerprint`.
    public static func fingerprint(key: Data, stableIdentifier: Data) -> Data {
        var digest = Data(SHA512.hash(data: firstInput(key: key, stableIdentifier: stableIdentifier)))
        for _ in 1 ..< iterations {
            var hash = SHA512()
            hash.update(data: digest)
            hash.update(data: key)
            digest = Data(hash.finalize())
        }
        return digest
    }

    /// F(IK) of section 44.2: the identity key with its user id as the stable identifier.
    public static func fingerprint(identityKey: Data) throws -> Data {
        fingerprint(key: identityKey, stableIdentifier: Data(try Identity.encodeUserID(identityKey).utf8))
    }

    /// The 30 digits of one side (section 44.3): six 5-byte big-endian pieces of bytes 0 to
    /// 29, each modulo 100000, with zeros in front.
    public static func digits(of fingerprint: Data) -> String {
        let bytes = [UInt8](fingerprint)
        return (0 ..< chunks).map { chunk in
            let piece = bytes[chunk * chunkBytes ..< (chunk + 1) * chunkBytes]
            let value = piece.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return String(format: "%05llu", value % chunkModulus)
        }.joined()
    }
}

extension Data {
    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
