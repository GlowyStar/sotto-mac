import CryptoKit
import Foundation

/// SK of section 16.4 and the 161 bytes of section 16.5.
public struct KeyAgreement: Sendable {
    public let sharedSecret: Data
    public let associatedData: Data
}

/// The key agreement of docs/protocol.md: sections 16.3 to 16.6, steps 1, 2, 5 to 7 of 16.8.
/// A client of version 2 makes new sessions by `PQXDH` only; this one serves the vectors
/// and the parts that PQXDH shares with it (section 41.1).
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

        let dhOutputs = try initiatorDHOutputs(
            bundle, identityDHPrivateKey: identityDHPrivateKey, ephemeralPrivateKey: ephemeralPrivateKey
        )
        return KeyAgreement(
            sharedSecret: deriveSharedSecret(dhOutputs.reduce(Data(), +), info: keyDerivationInfo),
            associatedData: try initiatorAssociatedData(
                endToEndVersion,
                bundle,
                identityKey: identityKey,
                identityDHPrivateKey: identityDHPrivateKey,
                ephemeralPrivateKey: ephemeralPrivateKey
            )
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
        try checkInitialHeader(
            senderIdentityKey,
            identityDHKey: senderIdentityDHKey,
            signature: senderIdentityDHSignature,
            pinnedIdentityDHKey: pinnedIdentityDHKey
        )

        let dhOutputs = try responderDHOutputs(
            identityDHPrivateKey: identityDHPrivateKey,
            signedPrekeyPrivateKey: signedPrekeyPrivateKey,
            oneTimePrekeyPrivateKey: oneTimePrekeyPrivateKey,
            senderIdentityDHKey: senderIdentityDHKey,
            ephemeralKey: ephemeralKey
        )
        return KeyAgreement(
            sharedSecret: deriveSharedSecret(dhOutputs.reduce(Data(), +), info: keyDerivationInfo),
            associatedData: try responderAssociatedData(
                endToEndVersion,
                identityKey: identityKey,
                identityDHPrivateKey: identityDHPrivateKey,
                senderIdentityKey: senderIdentityKey,
                senderIdentityDHKey: senderIdentityDHKey,
                ephemeralKey: ephemeralKey
            )
        )
    }

    /// Steps 1 and 2 of section 16.8, before any Diffie-Hellman value.
    static func checkInitialHeader(
        _ senderIdentityKey: Data,
        identityDHKey: Data,
        signature: Data,
        pinnedIdentityDHKey: Data?
    ) throws {
        if let pinnedIdentityDHKey {
            try Identity.requireLength("pinned_identity_dh_key", pinnedIdentityDHKey, Identity.keyLength)
        }
        do {
            try Identity.verifyIdentityDHKey(identityKey: senderIdentityKey, identityDHKey: identityDHKey, signature: signature)
        } catch CryptoError.badBundle {
            throw CryptoError.badInitialHeader
        }
        if let pinnedIdentityDHKey, identityDHKey != pinnedIdentityDHKey {
            throw CryptoError.identityKeyMismatch
        }
    }

    /// DH1 to DH4 of step 3 of section 16.6, DH4 only with a one-time prekey.
    static func initiatorDHOutputs(
        _ bundle: PrekeyBundle, identityDHPrivateKey: Data, ephemeralPrivateKey: Data
    ) throws -> [Data] {
        let signedPrekey = bundle.signedPrekey.key
        var dhOutputs = [
            try dh(privateKey: identityDHPrivateKey, publicKey: signedPrekey),
            try dh(privateKey: ephemeralPrivateKey, publicKey: bundle.identityDHKey),
            try dh(privateKey: ephemeralPrivateKey, publicKey: signedPrekey),
        ]
        if let oneTimePrekey = bundle.oneTimePrekey {
            dhOutputs.append(try dh(privateKey: ephemeralPrivateKey, publicKey: oneTimePrekey.key))
        }
        return dhOutputs
    }

    /// DH1 to DH4 of step 5 of section 16.8, DH4 only with a one-time prekey.
    static func responderDHOutputs(
        identityDHPrivateKey: Data,
        signedPrekeyPrivateKey: Data,
        oneTimePrekeyPrivateKey: Data?,
        senderIdentityDHKey: Data,
        ephemeralKey: Data
    ) throws -> [Data] {
        var dhOutputs = [
            try dh(privateKey: signedPrekeyPrivateKey, publicKey: senderIdentityDHKey),
            try dh(privateKey: identityDHPrivateKey, publicKey: ephemeralKey),
            try dh(privateKey: signedPrekeyPrivateKey, publicKey: ephemeralKey),
        ]
        if let oneTimePrekeyPrivateKey {
            dhOutputs.append(try dh(privateKey: oneTimePrekeyPrivateKey, publicKey: ephemeralKey))
        }
        return dhOutputs
    }

    /// The 161 bytes of section 16.5 under the version byte of the key agreement.
    static func initiatorAssociatedData(
        _ version: Data,
        _ bundle: PrekeyBundle,
        identityKey: Data,
        identityDHPrivateKey: Data,
        ephemeralPrivateKey: Data
    ) throws -> Data {
        let initiator = identityKey + (try Identity.deriveX25519PublicKey(identityDHPrivateKey))
        let responder = bundle.identity + bundle.identityDHKey
        return version + initiator + responder + (try Identity.deriveX25519PublicKey(ephemeralPrivateKey))
    }

    static func responderAssociatedData(
        _ version: Data,
        identityKey: Data,
        identityDHPrivateKey: Data,
        senderIdentityKey: Data,
        senderIdentityDHKey: Data,
        ephemeralKey: Data
    ) throws -> Data {
        let initiator = senderIdentityKey + senderIdentityDHKey
        let responder = identityKey + (try Identity.deriveX25519PublicKey(identityDHPrivateKey))
        return version + initiator + responder + ephemeralKey
    }

    /// SK of section 16.4, or of section 41.4 with the shared secret of the KEM.
    static func deriveSharedSecret(_ keyMaterial: Data, info: Data) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: keyMaterialPrefix + keyMaterial),
            salt: keyDerivationSalt,
            info: info,
            outputByteCount: sharedSecretLength
        ).withUnsafeBytes { Data($0) }
    }
}
