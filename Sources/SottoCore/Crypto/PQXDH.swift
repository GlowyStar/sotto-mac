import CryptoKit
import Foundation

/// (CT, SS) of PQKEM-ENC: the ciphertext and the shared secret it carries.
public struct Encapsulation: Sendable {
    public let ciphertext: Data
    public let sharedSecret: Data

    public init(ciphertext: Data, sharedSecret: Data) {
        self.ciphertext = ciphertext
        self.sharedSecret = sharedSecret
    }
}

/// SK and the session associated data of section 41.4, and what the initial header of
/// section 41.6 adds: the ciphertext and the id of the post-quantum prekey.
public struct PQKeyAgreement: Sendable {
    public let sharedSecret: Data
    public let associatedData: Data
    public let kemCiphertext: Data
    public let pqPrekeyID: UInt32
}

/// The post-quantum key agreement of docs/protocol.md, section 41: PQXDH with ML-KEM-768 of
/// CryptoKit.
public enum PQXDH {
    public typealias Encapsulate = (MLKEM768.PublicKey) throws -> Encapsulation

    static let endToEndVersion = Data([0x02])
    static let keyDerivationInfo = Data("sotto/2 pqxdh_CURVE25519_SHA-256_ML-KEM-768".utf8)
    public static let kemSeedLength = 64
    public static let kemCiphertextLength = 1088

    /// ML-KEM.Encaps of FIPS 203 with the random bytes of the library.
    public static func encapsulateRandomly(_ publicKey: MLKEM768.PublicKey) throws -> Encapsulation {
        let result = try publicKey.encapsulate()
        return Encapsulation(ciphertext: result.encapsulated, sharedSecret: result.sharedSecret.withUnsafeBytes { Data($0) })
    }

    /// The encapsulation key of a 64-byte seed d || z (FIPS 203, ML-KEM.KeyGen_internal).
    public static func kemPublicKey(seed: Data) throws -> Data {
        try Identity.requireLength("seed", seed, kemSeedLength)
        return try MLKEM768.PrivateKey(seedRepresentation: seed, publicKey: nil).publicKey.rawRepresentation
    }

    /// Checks 5 to 7 of section 5.4, after the four of `Identity.checkBundle`: the
    /// encapsulation key of the bundle and its id.
    static func checkPQPrekey(_ bundle: PrekeyBundle) throws -> (MLKEM768.PublicKey, UInt32) {
        guard let pqPrekey = bundle.pqPrekey else {
            throw CryptoError.pqPrekeyMissing
        }
        try Identity.verifyPQPrekey(identityKey: bundle.identity, pqPrekey: pqPrekey.key, signature: pqPrekey.signature)

        // CryptoKit runs the modulus check of FIPS 203, section 7.2, when it encapsulates,
        // not when it loads a key: one encapsulation, dropped, is the check of section 41.3.
        do {
            let publicKey = try MLKEM768.PublicKey(rawRepresentation: pqPrekey.key)
            _ = try publicKey.encapsulate()
            return (publicKey, pqPrekey.id)
        } catch {
            throw CryptoError.badBundle
        }
    }

    /// Runs steps 1 to 7 of section 41.5 on a bundle fetched for a contact. `encapsulate`
    /// is PQKEM-ENC; a test vector gives one with the recorded result.
    public static func initiate(
        bundle: PrekeyBundle,
        identityKey: Data,
        identityDHPrivateKey: Data,
        ephemeralPrivateKey: Data,
        contactIdentityKey: Data,
        pinnedIdentityDHKey: Data?,
        encapsulate: Encapsulate = encapsulateRandomly
    ) throws -> PQKeyAgreement {
        try Identity.requireLength("identity_key", identityKey, Identity.keyLength)
        try Identity.checkBundle(bundle, contactIdentityKey: contactIdentityKey, pinnedIdentityDHKey: pinnedIdentityDHKey)
        let (publicKey, pqPrekeyID) = try checkPQPrekey(bundle)

        let dhOutputs = try X3DH.initiatorDHOutputs(
            bundle, identityDHPrivateKey: identityDHPrivateKey, ephemeralPrivateKey: ephemeralPrivateKey
        )
        let encapsulation: Encapsulation
        do {
            encapsulation = try encapsulate(publicKey)
        } catch {
            throw CryptoError.badBundle
        }
        try Identity.requireLength("kem_ciphertext", encapsulation.ciphertext, kemCiphertextLength)

        let keyMaterial = dhOutputs.reduce(Data(), +) + encapsulation.sharedSecret
        return PQKeyAgreement(
            sharedSecret: X3DH.deriveSharedSecret(keyMaterial, info: keyDerivationInfo),
            associatedData: try X3DH.initiatorAssociatedData(
                endToEndVersion,
                bundle,
                identityKey: identityKey,
                identityDHPrivateKey: identityDHPrivateKey,
                ephemeralPrivateKey: ephemeralPrivateKey
            ),
            kemCiphertext: encapsulation.ciphertext,
            pqPrekeyID: pqPrekeyID
        )
    }

    /// Runs steps 1, 4 and 5 of section 41.7 on an initial header of version 2, with the
    /// seed of the post-quantum prekey that `pq_prekey_id` names.
    public static func respond(
        identityKey: Data,
        identityDHPrivateKey: Data,
        signedPrekeyPrivateKey: Data,
        oneTimePrekeyPrivateKey: Data?,
        pqPrekeySeed: Data,
        senderIdentityKey: Data,
        senderIdentityDHKey: Data,
        senderIdentityDHSignature: Data,
        ephemeralKey: Data,
        kemCiphertext: Data,
        pinnedIdentityDHKey: Data?
    ) throws -> KeyAgreement {
        try Identity.requireLength("identity_key", identityKey, Identity.keyLength)
        try Identity.requireLength("ephemeral_key", ephemeralKey, Identity.keyLength)
        try Identity.requireLength("pq_prekey_seed", pqPrekeySeed, kemSeedLength)
        try Identity.requireLength("kem_ciphertext", kemCiphertext, kemCiphertextLength)
        try X3DH.checkInitialHeader(
            senderIdentityKey,
            identityDHKey: senderIdentityDHKey,
            signature: senderIdentityDHSignature,
            pinnedIdentityDHKey: pinnedIdentityDHKey
        )

        let dhOutputs = try X3DH.responderDHOutputs(
            identityDHPrivateKey: identityDHPrivateKey,
            signedPrekeyPrivateKey: signedPrekeyPrivateKey,
            oneTimePrekeyPrivateKey: oneTimePrekeyPrivateKey,
            senderIdentityDHKey: senderIdentityDHKey,
            ephemeralKey: ephemeralKey
        )
        // ML-KEM rejects implicitly: another ciphertext of the right length gives another
        // secret and no error. A throw of the library ends as a message that does not decrypt.
        let kemSharedSecret: Data
        do {
            kemSharedSecret = try MLKEM768.PrivateKey(seedRepresentation: pqPrekeySeed, publicKey: nil)
                .decapsulate(kemCiphertext).withUnsafeBytes { Data($0) }
        } catch {
            throw CryptoError.decryptFailed
        }

        return KeyAgreement(
            sharedSecret: X3DH.deriveSharedSecret(dhOutputs.reduce(Data(), +) + kemSharedSecret, info: keyDerivationInfo),
            associatedData: try X3DH.responderAssociatedData(
                endToEndVersion,
                identityKey: identityKey,
                identityDHPrivateKey: identityDHPrivateKey,
                senderIdentityKey: senderIdentityKey,
                senderIdentityDHKey: senderIdentityDHKey,
                ephemeralKey: ephemeralKey
            )
        )
    }
}
