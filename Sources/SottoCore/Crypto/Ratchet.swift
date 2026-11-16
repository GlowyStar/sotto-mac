import CryptoKit
import Foundation

/// An entry of MKSKIPPED (section 17.8).
public struct SkippedKey: Codable, Equatable, Sendable {
    public var ratchetKey: Data
    public var number: UInt32
    public var messageKey: Data
    public var step: UInt64

    public init(ratchetKey: Data, number: UInt32, messageKey: Data, step: UInt64) {
        self.ratchetKey = ratchetKey
        self.number = number
        self.messageKey = messageKey
        self.step = step
    }
}

/// The variables of section 17.2; nil is the value "empty".
public struct RatchetState: Codable, Equatable, Sendable {
    public var dhsPrivateKey: Data
    public var dhsPublicKey: Data
    public var dhr: Data?
    public var rk: Data
    public var cks: Data?
    public var ckr: Data?
    public var ns: UInt32
    public var nr: UInt32
    public var pn: UInt32
    public var dhsteps: UInt64
    public var mkskipped: [SkippedKey]
}

public struct Encrypted: Sendable {
    public let state: RatchetState
    public let header: Data
    public let ciphertext: Data
}

public struct Decrypted: Sendable {
    public let state: RatchetState
    public let paddedPlaintext: Data
    public let purged: Int
}

/// The Double Ratchet of docs/protocol.md, sections 17 and 18.
///
/// A state machine without input or output of its own: every function takes the state and
/// every random value as arguments and returns a new state. A call that throws returns
/// nothing, so the state the caller holds stays as it was.
public enum Ratchet {
    public static let maxSkip = 1000
    public static let skippedKeysCap = 2000
    public static let skippedKeySteps: UInt64 = 5

    public static let headerLength = 40
    public static let callerAssociatedDataLength = 177
    public static let messageNonceLength = 12
    public static let tagLength = 16
    public static let lastMessageNumber = UInt32.max

    static let rootKDFInfo = Data("sotto/1 ratchet".utf8)
    static let rootKDFLength = 64
    static let messageKeyInput = Data([0x01])
    static let chainKeyInput = Data([0x02])

    /// Returns the new root key and the chain key of KDF_RK (section 17.4).
    public static func kdfRK(_ rk: Data, _ dhOutput: Data) -> (rootKey: Data, chainKey: Data) {
        let output = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: dhOutput),
            salt: rk,
            info: rootKDFInfo,
            outputByteCount: rootKDFLength
        ).withUnsafeBytes { Data($0) }
        return (Data(output.prefix(Identity.keyLength)), Data(output.suffix(Identity.keyLength)))
    }

    /// Returns the message key and the next chain key of KDF_CK (section 17.4).
    public static func kdfCK(_ ck: Data) -> (messageKey: Data, chainKey: Data) {
        let key = SymmetricKey(data: ck)
        let messageKey = Data(HMAC<SHA256>.authenticationCode(for: messageKeyInput, using: key))
        return (messageKey, Data(HMAC<SHA256>.authenticationCode(for: chainKeyInput, using: key)))
    }

    /// The state of an initiator after section 17.3.
    public static func initInitiator(sharedSecret: Data, signedPrekey: Data, ratchetPrivateKey: Data) throws -> RatchetState {
        try Identity.requireLength("shared_secret", sharedSecret, Identity.keyLength)
        let (rootKey, chainKey) = kdfRK(sharedSecret, try X3DH.dh(privateKey: ratchetPrivateKey, publicKey: signedPrekey))
        return RatchetState(
            dhsPrivateKey: ratchetPrivateKey,
            dhsPublicKey: try Identity.deriveX25519PublicKey(ratchetPrivateKey),
            dhr: signedPrekey,
            rk: rootKey,
            cks: chainKey,
            ckr: nil,
            ns: 0,
            nr: 0,
            pn: 0,
            dhsteps: 0,
            mkskipped: []
        )
    }

    /// The state of a responder after section 17.3: it cannot encrypt yet.
    public static func initResponder(sharedSecret: Data, signedPrekeyPrivateKey: Data) throws -> RatchetState {
        try Identity.requireLength("shared_secret", sharedSecret, Identity.keyLength)
        return RatchetState(
            dhsPrivateKey: signedPrekeyPrivateKey,
            dhsPublicKey: try Identity.deriveX25519PublicKey(signedPrekeyPrivateKey),
            dhr: nil,
            rk: sharedSecret,
            cks: nil,
            ckr: nil,
            ns: 0,
            nr: 0,
            pn: 0,
            dhsteps: 0,
            mkskipped: []
        )
    }

    /// Runs the steps of section 17.6 and returns the new state, the 40 bytes of the header
    /// and the `ciphertext` field of section 18.3.
    public static func encrypt(
        _ state: RatchetState,
        paddedPlaintext: Data,
        associatedData: Data,
        nonce: Data
    ) throws -> Encrypted {
        try Identity.requireLength("associated_data", associatedData, callerAssociatedDataLength)
        try Identity.requireLength("nonce", nonce, messageNonceLength)
        guard let cks = state.cks else {
            throw CryptoError.noSendingChain
        }
        guard state.ns != lastMessageNumber else {
            throw CryptoError.chainExhausted
        }

        let (messageKey, nextChainKey) = kdfCK(cks)
        let header = state.dhsPublicKey + bigEndian(state.pn) + bigEndian(state.ns)
        let sealed = try ChaChaPoly.seal(
            paddedPlaintext,
            using: SymmetricKey(data: messageKey),
            nonce: ChaChaPoly.Nonce(data: nonce),
            authenticating: associatedData + header
        )

        var newState = state
        newState.cks = nextChainKey
        newState.ns += 1
        return Encrypted(state: newState, header: header, ciphertext: sealed.combined)
    }

    /// Runs the steps of section 17.7 on a copy of the state and returns the new state, the
    /// padded plaintext and the number of skipped keys that the cap and the purge of
    /// section 17.8 removed.
    public static func decrypt(
        _ state: RatchetState,
        header: Data,
        ciphertext: Data,
        associatedData: Data,
        ratchetPrivateKey: Data
    ) throws -> Decrypted {
        try Identity.requireLength("header", header, headerLength)
        try Identity.requireLength("associated_data", associatedData, callerAssociatedDataLength)
        try Identity.requireLength("ratchet_private_key", ratchetPrivateKey, Identity.keyLength)
        let headerBytes = [UInt8](header)
        let ratchetKey = Data(headerBytes[0..<32])
        let previousCount = number(headerBytes[32..<36])
        let number = number(headerBytes[36..<40])
        let sealedWith = associatedData + header

        if number == lastMessageNumber {
            throw CryptoError.chainExhausted
        }
        if let index = state.mkskipped.firstIndex(where: { $0.ratchetKey == ratchetKey && $0.number == number }) {
            let paddedPlaintext = try open(state.mkskipped[index].messageKey, ciphertext, sealedWith)
            var newState = state
            newState.mkskipped.remove(at: index)
            return Decrypted(state: newState, paddedPlaintext: paddedPlaintext, purged: 0)
        }

        var receiving = Receiving(state: state)
        if ratchetKey == state.dhr {
            try checkCurrentChain(state, number)
        } else {
            try checkNewChain(state, previousCount, number)
            try receiving.step(ratchetKey, previousCount, ratchetPrivateKey)
        }
        try receiving.skip(until: number)
        let messageKey = try receiving.nextMessageKey()
        let paddedPlaintext = try open(messageKey, ciphertext, sealedWith)

        return Decrypted(state: receiving.state, paddedPlaintext: paddedPlaintext, purged: receiving.purged)
    }

    private static func checkCurrentChain(_ state: RatchetState, _ number: UInt32) throws {
        guard state.ckr != nil else {
            throw CryptoError.decryptFailed
        }
        if number < state.nr {
            throw CryptoError.decryptFailed
        }
        if Int(number) > Int(state.nr) + maxSkip {
            throw CryptoError.tooManySkipped
        }
    }

    private static func checkNewChain(_ state: RatchetState, _ previousCount: UInt32, _ number: UInt32) throws {
        if Int(previousCount) > Int(state.nr) + maxSkip {
            throw CryptoError.tooManySkipped
        }
        if Int(number) > maxSkip {
            throw CryptoError.tooManySkipped
        }
    }

    private static func open(_ messageKey: Data, _ ciphertext: Data, _ associatedData: Data) throws -> Data {
        guard ciphertext.count >= messageNonceLength + tagLength else {
            throw CryptoError.decryptFailed
        }
        do {
            let box = try ChaChaPoly.SealedBox(combined: ciphertext)
            return try ChaChaPoly.open(box, using: SymmetricKey(data: messageKey), authenticating: associatedData)
        } catch {
            throw CryptoError.decryptFailed
        }
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func number(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// The copy of the state that steps 5 to 7 of section 17.7 change.
    private struct Receiving {
        var state: RatchetState
        var purged = 0

        /// The DH ratchet step, step 5 of section 17.7.
        mutating func step(_ ratchetKey: Data, _ previousCount: UInt32, _ privateKey: Data) throws {
            if state.ckr != nil {
                try skip(until: previousCount)
            }
            state.pn = state.ns
            state.ns = 0
            state.nr = 0
            state.dhr = ratchetKey
            (state.rk, state.ckr) = kdfRK(state.rk, try X3DH.dh(privateKey: state.dhsPrivateKey, publicKey: ratchetKey))
            state.dhsPrivateKey = privateKey
            state.dhsPublicKey = try Identity.deriveX25519PublicKey(privateKey)
            (state.rk, state.cks) = kdfRK(state.rk, try X3DH.dh(privateKey: privateKey, publicKey: ratchetKey))
            state.dhsteps += 1

            let kept = state.mkskipped.filter { $0.step + skippedKeySteps > state.dhsteps }
            purged += state.mkskipped.count - kept.count
            state.mkskipped = kept
        }

        /// Skips one key of the receiving chain (section 17.8) while Nr is below `number`.
        mutating func skip(until number: UInt32) throws {
            while state.nr < number {
                guard let ratchetKey = state.dhr else {
                    throw CryptoError.decryptFailed
                }
                let skippedNumber = state.nr
                let messageKey = try nextMessageKey()
                state.mkskipped.removeAll { $0.ratchetKey == ratchetKey && $0.number == skippedNumber }
                if state.mkskipped.count == skippedKeysCap {
                    state.mkskipped.removeFirst()
                    purged += 1
                }
                state.mkskipped.append(
                    SkippedKey(ratchetKey: ratchetKey, number: skippedNumber, messageKey: messageKey, step: state.dhsteps)
                )
            }
        }

        mutating func nextMessageKey() throws -> Data {
            guard let ckr = state.ckr else {
                throw CryptoError.decryptFailed
            }
            let messageKey: Data
            (messageKey, state.ckr) = kdfCK(ckr)
            state.nr += 1
            return messageKey
        }
    }
}
