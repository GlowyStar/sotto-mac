import CryptoKit
import Foundation

/// SK of section 16.4 and the 161 bytes of section 16.5.
public struct KeyAgreement: Sendable {
    public let sharedSecret: Data
    public let associatedData: Data
}

/// The key agreement of docs/protocol.md: sections 16.3 to 16.6, steps 1, 2, 5 to 7 of 16.8.
public enum X3DH {
    static let endToEndVersion = Data([0x01])
    static let keyMaterialPrefix = Data(repeating: 0xFF, count: 32)
    static let keyDerivationSalt = Data(count: 32)
    static let keyDerivationInfo = Data("sotto/1 x3dh".utf8)
    static let sharedSecretLength = 32

    /// Returns DH(k, P) of section 16.3; an output of 32 zero bytes ends in ZERO_DH.
    public static func dh(privateKey: Data, publicKey: Data) throws -> Data {
        try Identity.requireLength("private_key", privateKey, Identity.keyLength)
        try Identity.requireLength("public_key", publicKey, Identity.keyLength)
        let ownKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)

        let output: Data
        do {
            output = try ownKey.sharedSecretFromKeyAgreement(with: peerKey).withUnsafeBytes { Data($0) }
        } catch {
            throw CryptoError.zeroDH
        }

        guard output.reduce(0, |) != 0 else {
            throw CryptoError.zeroDH
        }
        return output
    }

    /// Runs steps 1 to 6 of section 16.6 on a bundle fetched for a contact.
    public static func initiate(
        bundle: PrekeyBundle,
        identityKey: Data,
        identityDHPrivateKey: Data,
        ephemeralPrivateKey: Data,
        contactIdentityKey: Data,
        pinnedIdentityDHKey: Data?
    ) throws -> KeyAgreement {
        try Identity.requireLength("identity_key", identityKey, Identity.keyLength)
        try Identity.checkBundle(
            bundle,
            contactIdentityKey: contactIdentityKey,
            pinnedIdentityDHKey: pinnedIdentityDHKey
        )

        let signedPrekey = bundle.signedPrekey.key
        var dhOutputs = [
            try dh(privateKey: identityDHPrivateKey, publicKey: signedPrekey),
            try dh(privateKey: ephemeralPrivateKey, publicKey: bundle.identityDHKey),
            try dh(privateKey: ephemeralPrivateKey, publicKey: signedPrekey),
        ]
        if let oneTimePrekey = bundle.oneTimePrekey {
            dhOutputs.append(try dh(privateKey: ephemeralPrivateKey, publicKey: oneTimePrekey.key))
        }

        let initiator = identityKey + (try Identity.deriveX25519PublicKey(identityDHPrivateKey))
        let responder = bundle.identity + bundle.identityDHKey
        let ephemeralKey = try Identity.deriveX25519PublicKey(ephemeralPrivateKey)
        return KeyAgreement(
            sharedSecret: deriveSharedSecret(dhOutputs),
            associatedData: endToEndVersion + initiator + responder + ephemeralKey
        )
    }

    /// Runs steps 1, 2 and 5 to 7 of section 16.8 on an initial header.
    public static func respond(
        identityKey: Data,
        identityDHPrivateKey: Data,
        signedPrekeyPrivateKey: Data,
        oneTimePrekeyPrivateKey: Data?,
        senderIdentityKey: Data,
        senderIdentityDHKey: Data,
        senderIdentityDHSignature: Data,
        ephemeralKey: Data,
        pinnedIdentityDHKey: Data?
    ) throws -> KeyAgreement {
        try Identity.requireLength("identity_key", identityKey, Identity.keyLength)
        try Identity.requireLength("ephemeral_key", ephemeralKey, Identity.keyLength)
        if let pinnedIdentityDHKey {
            try Identity.requireLength("pinned_identity_dh_key", pinnedIdentityDHKey, Identity.keyLength)
        }

        do {
            try Identity.verifyIdentityDHKey(
                identityKey: senderIdentityKey,
                identityDHKey: senderIdentityDHKey,
                signature: senderIdentityDHSignature
            )
        } catch CryptoError.badBundle {
            throw CryptoError.badInitialHeader
        }

        if let pinnedIdentityDHKey, senderIdentityDHKey != pinnedIdentityDHKey {
            throw CryptoError.identityKeyMismatch
        }

        var dhOutputs = [
            try dh(privateKey: signedPrekeyPrivateKey, publicKey: senderIdentityDHKey),
            try dh(privateKey: identityDHPrivateKey, publicKey: ephemeralKey),
            try dh(privateKey: signedPrekeyPrivateKey, publicKey: ephemeralKey),
        ]
        if let oneTimePrekeyPrivateKey {
            dhOutputs.append(try dh(privateKey: oneTimePrekeyPrivateKey, publicKey: ephemeralKey))
        }

        let initiator = senderIdentityKey + senderIdentityDHKey
        let responder = identityKey + (try Identity.deriveX25519PublicKey(identityDHPrivateKey))
        return KeyAgreement(
            sharedSecret: deriveSharedSecret(dhOutputs),
            associatedData: endToEndVersion + initiator + responder + ephemeralKey
        )
    }

    private static func deriveSharedSecret(_ dhOutputs: [Data]) -> Data {
        let inputKeyMaterial = dhOutputs.reduce(keyMaterialPrefix, +)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: keyDerivationSalt,
            info: keyDerivationInfo,
            outputByteCount: sharedSecretLength
        ).withUnsafeBytes { Data($0) }
    }
}
