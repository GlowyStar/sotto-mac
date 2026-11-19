import CryptoKit
import Foundation

/// A check that ended in a named local result of docs/protocol.md, section 11.4.
public enum CryptoError: Error, Equatable, Sendable {
    case invalidID
    case badBundle
    case identityKeyMismatch
    case loginRefused
    case zeroDH
    case badInitialHeader
    case decryptFailed
    case tooManySkipped
    case chainExhausted
    case noSendingChain
    case badBlob
    case pqPrekeyMissing

    public var result: String {
        switch self {
        case .invalidID: "INVALID_ID"
        case .badBundle: "BAD_BUNDLE"
        case .identityKeyMismatch: "IDENTITY_KEY_MISMATCH"
        case .loginRefused: "LOGIN_REFUSED"
        case .zeroDH: "ZERO_DH"
        case .badInitialHeader: "BAD_INITIAL_HEADER"
        case .decryptFailed: "DECRYPT_FAILED"
        case .tooManySkipped: "TOO_MANY_SKIPPED"
        case .chainExhausted: "CHAIN_EXHAUSTED"
        case .noSendingChain: "NO_SENDING_CHAIN"
        case .badBlob: "BAD_BLOB"
        case .pqPrekeyMissing: "PQ_PREKEY_MISSING"
        }
    }
}

/// A caller passed a value of the wrong length or form: a programming error, not a result
/// of the protocol.
public struct InvalidInputError: Error, Equatable, Sendable {
    public let message: String
}

public struct SignedPrekey: Sendable {
    public var id: UInt32
    public var key: Data
    public var signature: Data

    public init(id: UInt32, key: Data, signature: Data) {
        self.id = id
        self.key = key
        self.signature = signature
    }
}

public struct OneTimePrekey: Sendable {
    public var id: UInt32
    public var key: Data

    public init(id: UInt32, key: Data) {
        self.id = id
        self.key = key
    }
}

/// A fetched bundle, field for field the Bundle frame of section 7.11.
public struct PrekeyBundle: Sendable {
    public var identity: Data
    public var identityDHKey: Data
    public var identityDHSignature: Data
    public var signedPrekey: SignedPrekey
    public var oneTimePrekey: OneTimePrekey?
    public var pqPrekey: SignedPrekey?

    public init(
        identity: Data,
        identityDHKey: Data,
        identityDHSignature: Data,
        signedPrekey: SignedPrekey,
        oneTimePrekey: OneTimePrekey?,
        pqPrekey: SignedPrekey? = nil
    ) {
        self.identity = identity
        self.identityDHKey = identityDHKey
        self.identityDHSignature = identityDHSignature
        self.signedPrekey = signedPrekey
        self.oneTimePrekey = oneTimePrekey
        self.pqPrekey = pqPrekey
    }
}

/// The identity core of docs/protocol.md: sections 3, 4 and 5.4, steps 4 and 5 of 8.3.
public enum Identity {
    public static let keyLength = 32
    public static let nonceLength = 32
    public static let signatureLength = 64
    public static let kemPublicKeyLength = 1184
    public static let longestServerName = 255

    static let loginPrefix = Data("sotto/1 login".utf8)
    static let identityDHPrefix = Data("sotto/1 identity-dh".utf8)
    static let signedPrekeyPrefix = Data("sotto/1 signed-prekey".utf8)
    static let pqPrekeyPrefix = Data("sotto/1 ml-kem-768-prekey".utf8)
    static let prefixEnd = Data([0])

    static let topBitCleared: UInt8 = 0x7F
    static let fieldPrime = bytes(hex: "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")
    // Chalkias, Garillot, Nikolaenko, "Taming the many EdDSAs", IACR ePrint 2020/1244,
    // table 1: the points of small order, each with the top bit of the last byte cleared.
    static let smallOrder: Set<Data> = [
        "0000000000000000000000000000000000000000000000000000000000000000",
        "0100000000000000000000000000000000000000000000000000000000000000",
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
        "26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05",
        "c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a",
    ].reduce(into: []) { $0.insert(Data(bytes(hex: $1))) }

    public static func deriveIdentityKey(seed: Data) throws -> Data {
        try requireLength("seed", seed, keyLength)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation
    }

    public static func deriveX25519PublicKey(_ privateKey: Data) throws -> Data {
        try requireLength("private_key", privateKey, keyLength)
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
            .publicKey.rawRepresentation
    }

    public static func encodeUserID(_ identityKey: Data) throws -> String {
        try requireLength("identity_key", identityKey, keyLength)
        return identityKey.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the identity key of a user id by the four steps of section 3.3.
    public static func decodeUserID(_ userID: String) throws -> Data {
        let characters = Array(userID.utf8)
        let isLowercaseHex = characters.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
        guard characters.count == 2 * keyLength, isLowercaseHex else {
            throw CryptoError.invalidID
        }

        let identityKey = Data(bytes(hex: userID))
        if isExcluded(identityKey) {
            throw CryptoError.invalidID
        }
        return identityKey
    }

    public static func loginString(serverName: String, serverNonce: Data, clientNonce: Data) throws -> Data {
        guard let name = serverName.data(using: .ascii, allowLossyConversion: false),
              (1...longestServerName).contains(name.count)
        else {
            throw InvalidInputError(message: "server_name is not 1 to \(longestServerName) ASCII bytes")
        }
        try requireLength("server_nonce", serverNonce, nonceLength)
        try requireLength("client_nonce", clientNonce, nonceLength)
        return loginPrefix + prefixEnd + Data([UInt8(name.count)]) + name + serverNonce + clientNonce
    }

    public static func identityDHString(identityKey: Data, identityDHKey: Data) throws -> Data {
        try requireLength("identity_key", identityKey, keyLength)
        try requireLength("identity_dh_key", identityDHKey, keyLength)
        return identityDHPrefix + prefixEnd + identityKey + identityDHKey
    }

    public static func signedPrekeyString(identityKey: Data, signedPrekey: Data) throws -> Data {
        try requireLength("identity_key", identityKey, keyLength)
        try requireLength("signed_prekey", signedPrekey, keyLength)
        return signedPrekeyPrefix + prefixEnd + identityKey + signedPrekey
    }

    /// The string of section 4.5.
    public static func pqPrekeyString(identityKey: Data, pqPrekey: Data) throws -> Data {
        try requireLength("identity_key", identityKey, keyLength)
        try requireLength("pq_prekey", pqPrekey, kemPublicKeyLength)
        return pqPrekeyPrefix + prefixEnd + identityKey + pqPrekey
    }

    public static func signLogin(seed: Data, serverName: String, serverNonce: Data, clientNonce: Data) throws -> Data {
        let signedString = try loginString(serverName: serverName, serverNonce: serverNonce, clientNonce: clientNonce)
        return try sign(seed: seed, signedString)
    }

    /// Runs steps 4 and 5 of section 8.3 on the fields of a Login.
    public static func verifyLogin(
        identityKey: Data,
        signature: Data,
        serverName: String,
        serverNonce: Data,
        clientNonce: Data
    ) throws {
        try requireLength("identity_key", identityKey, keyLength)
        let signedString = try loginString(serverName: serverName, serverNonce: serverNonce, clientNonce: clientNonce)
        guard try verifies(identityKey, signature, signedString) else {
            throw CryptoError.loginRefused
        }
    }

    public static func signIdentityDHKey(seed: Data, identityDHKey: Data) throws -> Data {
        let signedString = try identityDHString(identityKey: deriveIdentityKey(seed: seed), identityDHKey: identityDHKey)
        return try sign(seed: seed, signedString)
    }

    public static func verifyIdentityDHKey(identityKey: Data, identityDHKey: Data, signature: Data) throws {
        let signedString = try identityDHString(identityKey: identityKey, identityDHKey: identityDHKey)
        guard try verifies(identityKey, signature, signedString) else {
            throw CryptoError.badBundle
        }
    }

    public static func signSignedPrekey(seed: Data, signedPrekey: Data) throws -> Data {
        let signedString = try signedPrekeyString(identityKey: deriveIdentityKey(seed: seed), signedPrekey: signedPrekey)
        return try sign(seed: seed, signedString)
    }

    public static func verifySignedPrekey(identityKey: Data, signedPrekey: Data, signature: Data) throws {
        let signedString = try signedPrekeyString(identityKey: identityKey, signedPrekey: signedPrekey)
        guard try verifies(identityKey, signature, signedString) else {
            throw CryptoError.badBundle
        }
    }

    public static func signPQPrekey(seed: Data, pqPrekey: Data) throws -> Data {
        let signedString = try pqPrekeyString(identityKey: deriveIdentityKey(seed: seed), pqPrekey: pqPrekey)
        return try sign(seed: seed, signedString)
    }

    public static func verifyPQPrekey(identityKey: Data, pqPrekey: Data, signature: Data) throws {
        let signedString = try pqPrekeyString(identityKey: identityKey, pqPrekey: pqPrekey)
        guard try verifies(identityKey, signature, signedString) else {
            throw CryptoError.badBundle
        }
    }

    /// Runs the first four checks of section 5.4 in order and stops at the first that fails;
    /// `PQXDH.initiate` runs checks 5 to 7 after them.
    public static func checkBundle(
        _ bundle: PrekeyBundle,
        contactIdentityKey: Data,
        pinnedIdentityDHKey: Data?
    ) throws {
        try requireLength("contact_identity_key", contactIdentityKey, keyLength)
        if let pinnedIdentityDHKey {
            try requireLength("pinned_identity_dh_key", pinnedIdentityDHKey, keyLength)
        }

        guard bundle.identity == contactIdentityKey else {
            throw CryptoError.badBundle
        }

        try verifyIdentityDHKey(
            identityKey: bundle.identity,
            identityDHKey: bundle.identityDHKey,
            signature: bundle.identityDHSignature
        )

        if let pinnedIdentityDHKey, bundle.identityDHKey != pinnedIdentityDHKey {
            throw CryptoError.identityKeyMismatch
        }

        try verifySignedPrekey(
            identityKey: bundle.identity,
            signedPrekey: bundle.signedPrekey.key,
            signature: bundle.signedPrekey.signature
        )
    }

    static func requireLength(_ name: String, _ value: Data, _ length: Int) throws {
        guard value.count == length else {
            throw InvalidInputError(message: "\(name) is \(value.count) bytes long, not \(length)")
        }
    }

    static func isExcluded(_ identityKey: Data) -> Bool {
        var y = [UInt8](identityKey)
        y[y.count - 1] &= topBitCleared

        let isNonCanonical = y[1...] == fieldPrime[1...] && y[0] >= fieldPrime[0]
        let hasSmallOrder = smallOrder.contains(Data(y))
        return isNonCanonical || hasSmallOrder
    }

    static func bytes(hex: String) -> [UInt8] {
        let digits = Array(hex.utf8)
        return stride(from: 0, to: digits.count, by: 2).map { index in
            UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16)!
        }
    }

    private static func sign(seed: Data, _ signedString: Data) throws -> Data {
        try requireLength("seed", seed, keyLength)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed).signature(for: signedString)
    }

    private static func verifies(_ identityKey: Data, _ signature: Data, _ signedString: Data) throws -> Bool {
        try requireLength("signature", signature, signatureLength)
        if isExcluded(identityKey) {
            return false
        }

        // By section 3.3 a key that the library refuses to load verifies no signature.
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: identityKey) else {
            return false
        }
        return publicKey.isValidSignature(signature, for: signedString)
    }
}
