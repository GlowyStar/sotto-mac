import Foundation
import SottoCore
import Testing

/// SplitMix64: a fixed seed gives the same run every time.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func bytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &self) })
    }
}

private struct Message {
    let header: Data
    let ciphertext: Data
    let associatedData: Data
    let paddedPlaintext: Data
}

private final class Session {
    var initiator: RatchetState
    var responder: RatchetState
    var random: SeededGenerator

    init(seed: UInt64) throws {
        random = SeededGenerator(state: seed)
        let sharedSecret = random.bytes(32)
        let signedPrekeyPrivateKey = random.bytes(32)
        initiator = try Ratchet.initInitiator(
            sharedSecret: sharedSecret,
            signedPrekey: Identity.deriveX25519PublicKey(signedPrekeyPrivateKey),
            ratchetPrivateKey: random.bytes(32)
        )
        responder = try Ratchet.initResponder(sharedSecret: sharedSecret, signedPrekeyPrivateKey: signedPrekeyPrivateKey)
    }

    func send(_ state: inout RatchetState) throws -> Message {
        let associatedData = random.bytes(Ratchet.callerAssociatedDataLength)
        let paddedPlaintext = random.bytes(256)
        let encrypted = try Ratchet.encrypt(
            state, paddedPlaintext: paddedPlaintext, associatedData: associatedData, nonce: random.bytes(12)
        )
        state = encrypted.state
        return Message(
            header: encrypted.header,
            ciphertext: encrypted.ciphertext,
            associatedData: associatedData,
            paddedPlaintext: paddedPlaintext
        )
    }

    func receive(_ message: Message, _ state: inout RatchetState) throws -> Decrypted {
        let decrypted = try Ratchet.decrypt(
            state,
            header: message.header,
            ciphertext: message.ciphertext,
            associatedData: message.associatedData,
            ratchetPrivateKey: random.bytes(32)
        )
        #expect(decrypted.paddedPlaintext == message.paddedPlaintext)
        state = decrypted.state
        return decrypted
    }

    /// Decrypts a message that must fail and checks that the state is the same afterwards.
    func refuse(_ message: Message, _ state: RatchetState, with result: CryptoError) {
        let copy = state
        #expect(throws: result) {
            _ = try Ratchet.decrypt(
                state,
                header: message.header,
                ciphertext: message.ciphertext,
                associatedData: message.associatedData,
                ratchetPrivateKey: random.bytes(32)
            )
        }
        #expect(state == copy)
    }
}

private func flipping(_ data: Data, at index: Int) -> Data {
    var copy = data
    copy[index] ^= 0x01
    return copy
}

// The encodings of the X25519 points of small order, with the top bit clear and set.
private let smallOrderKeys = [
    "0000000000000000000000000000000000000000000000000000000000000000",
    "0000000000000000000000000000000000000000000000000000000000000080",
    "0100000000000000000000000000000000000000000000000000000000000000",
    "0100000000000000000000000000000000000000000000000000000000000080",
    "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800",
    "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b880",
    "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157",
    "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f11d7",
    "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f",
    "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
].map { Data(hex: $0) }

@Test func everyZeroX25519ResultEndsInZeroDH() throws {
    var random = SeededGenerator(state: 1)
    for key in smallOrderKeys {
        #expect(throws: CryptoError.zeroDH) { try X3DH.dh(privateKey: random.bytes(32), publicKey: key) }
        #expect(throws: CryptoError.zeroDH) {
            try Ratchet.initInitiator(sharedSecret: random.bytes(32), signedPrekey: key, ratchetPrivateKey: random.bytes(32))
        }
    }
    #expect(try X3DH.dh(privateKey: random.bytes(32), publicKey: random.bytes(32)).count == 32)
}

@Test func aRatchetKeyOfSmallOrderIsRefusedAndChangesNothing() throws {
    let session = try Session(seed: 2)
    let message = try session.send(&session.initiator)
    var header = message.header
    header.replaceSubrange(0..<32, with: smallOrderKeys[4])
    let forged = Message(
        header: header, ciphertext: message.ciphertext,
        associatedData: message.associatedData, paddedPlaintext: message.paddedPlaintext
    )
    session.refuse(forged, session.responder, with: .zeroDH)
    _ = try session.receive(message, &session.responder)
}

@Test func aForgedHeaderOrCiphertextLeavesTheStateUnchanged() throws {
    let session = try Session(seed: 3)
    let first = try session.send(&session.initiator)
    _ = try session.receive(first, &session.responder)
    let message = try session.send(&session.initiator)
    let reply = try session.send(&session.responder)

    for index in [5, 33, 39] {
        let forged = Message(
            header: flipping(message.header, at: index), ciphertext: message.ciphertext,
            associatedData: message.associatedData, paddedPlaintext: message.paddedPlaintext
        )
        session.refuse(forged, session.responder, with: .decryptFailed)
    }
    for index in [0, 11, 12, 40, message.ciphertext.count - 1] {
        let forged = Message(
            header: message.header, ciphertext: flipping(message.ciphertext, at: index),
            associatedData: message.associatedData, paddedPlaintext: message.paddedPlaintext
        )
        session.refuse(forged, session.responder, with: .decryptFailed)
    }
    let otherData = Message(
        header: message.header, ciphertext: message.ciphertext,
        associatedData: flipping(message.associatedData, at: 0), paddedPlaintext: message.paddedPlaintext
    )
    session.refuse(otherData, session.responder, with: .decryptFailed)
    let truncated = Message(
        header: message.header, ciphertext: message.ciphertext.prefix(27),
        associatedData: message.associatedData, paddedPlaintext: message.paddedPlaintext
    )
    session.refuse(truncated, session.responder, with: .decryptFailed)

    _ = try session.receive(message, &session.responder)
    _ = try session.receive(reply, &session.initiator)
}

@Test func aMessageKeyIsUsedOnce() throws {
    let session = try Session(seed: 4)
    let first = try session.send(&session.initiator)
    let second = try session.send(&session.initiator)
    let third = try session.send(&session.initiator)

    _ = try session.receive(third, &session.responder)
    _ = try session.receive(first, &session.responder)
    session.refuse(third, session.responder, with: .decryptFailed)
    session.refuse(first, session.responder, with: .decryptFailed)
    _ = try session.receive(second, &session.responder)
    session.refuse(second, session.responder, with: .decryptFailed)
    #expect(session.responder.mkskipped.isEmpty)
}

@Test func theResponderCannotEncryptAndTheChainEndsBeforeTheLastNumber() throws {
    let session = try Session(seed: 5)
    #expect(throws: CryptoError.noSendingChain) { try session.send(&session.responder) }

    var exhausted = session.initiator
    exhausted.ns = Ratchet.lastMessageNumber
    #expect(throws: CryptoError.chainExhausted) { try session.send(&exhausted) }
    exhausted.ns = Ratchet.lastMessageNumber - 1
    let last = try session.send(&exhausted)
    #expect(last.header.suffix(4) == Data([0xFF, 0xFF, 0xFF, 0xFE]))

    var header = last.header
    header.replaceSubrange(36..<40, with: Data([0xFF, 0xFF, 0xFF, 0xFF]))
    let beyond = Message(
        header: header, ciphertext: last.ciphertext,
        associatedData: last.associatedData, paddedPlaintext: last.paddedPlaintext
    )
    session.refuse(beyond, session.responder, with: .chainExhausted)
}

@Test func theSkipLimitAndTheCapOfSkippedKeysHold() throws {
    let session = try Session(seed: 6)
    var messages: [Message] = []
    for _ in 0...2003 {
        messages.append(try session.send(&session.initiator))
    }

    session.refuse(messages[1001], session.responder, with: .tooManySkipped)
    var decrypted = try session.receive(messages[1000], &session.responder)
    #expect(decrypted.purged == 0)
    #expect(session.responder.mkskipped.count == 1000)

    session.refuse(messages[2002], session.responder, with: .tooManySkipped)
    decrypted = try session.receive(messages[2001], &session.responder)
    #expect(decrypted.purged == 0)
    #expect(session.responder.mkskipped.count == Ratchet.skippedKeysCap)

    decrypted = try session.receive(messages[2003], &session.responder)
    #expect(decrypted.purged == 1)
    #expect(session.responder.mkskipped.count == Ratchet.skippedKeysCap)
    #expect(session.responder.mkskipped.first?.number == 1)
    session.refuse(messages[0], session.responder, with: .decryptFailed)
    for index in [1, 999, 1001, 1500, 2000, 2002] {
        _ = try session.receive(messages[index], &session.responder)
    }
}

@Test func skippedKeysArePurgedWithTheFifthDHRatchetStep() throws {
    let session = try Session(seed: 7)
    let lost = try session.send(&session.initiator)
    _ = try session.receive(try session.send(&session.initiator), &session.responder)
    #expect(session.responder.mkskipped.map(\.step) == [1])

    var purged: [Int] = []
    for _ in 0..<5 {
        _ = try session.receive(try session.send(&session.responder), &session.initiator)
        purged.append(try session.receive(try session.send(&session.initiator), &session.responder).purged)
        if session.responder.dhsteps == 5 {
            #expect(session.responder.mkskipped.count == 1)
        }
    }
    #expect(session.responder.dhsteps == 6)
    #expect(purged == [0, 0, 0, 0, 1])
    #expect(session.responder.mkskipped.isEmpty)
    session.refuse(lost, session.responder, with: .decryptFailed)
}

/// Two parties send from either side; messages are delivered in any order, dropped or
/// duplicated. A delivery must succeed exactly when its key is still held, and a refused
/// delivery must change nothing.
@Test func aRandomExchangeKeepsTheInvariants() throws {
    let session = try Session(seed: 0x5077_0016)
    var choices = SeededGenerator(state: 16)
    var toResponder: [Message] = []
    var toInitiator: [Message] = []
    var seenKeys: [Set<Data>] = [[], [session.initiator.dhr!]]
    var delivered = 0
    var outOfOrder = 0
    var refused = 0

    func expectedToDecrypt(_ message: Message, _ state: RatchetState, _ seen: Set<Data>) -> Bool {
        let ratchetKey = message.header.prefix(32)
        let number = message.header.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let isSkipped = state.mkskipped.contains { $0.ratchetKey == ratchetKey && $0.number == number }
        let isAhead = ratchetKey == state.dhr && state.ckr != nil && number >= state.nr
        let isNew = ratchetKey != state.dhr && !seen.contains(Data(ratchetKey))
        return isSkipped || isAhead || isNew
    }

    for round in 0..<3000 {
        let toInitiatorSide = Bool.random(using: &choices)
        switch Int.random(in: 0..<10, using: &choices) {
        case 0...3:
            if toInitiatorSide, session.responder.cks != nil, session.responder.ns < 200 {
                toInitiator.append(try session.send(&session.responder))
            } else if !toInitiatorSide, session.initiator.ns < 200 {
                toResponder.append(try session.send(&session.initiator))
            }
        case 4:
            if toInitiatorSide, !toInitiator.isEmpty {
                toInitiator.remove(at: Int.random(in: toInitiator.indices, using: &choices))
            } else if !toInitiatorSide, !toResponder.isEmpty {
                toResponder.remove(at: Int.random(in: toResponder.indices, using: &choices))
            }
        default:
            let queue = toInitiatorSide ? toInitiator : toResponder
            guard !queue.isEmpty else { continue }
            let index = Int.random(in: queue.indices, using: &choices)
            let message = queue[index]
            let keepsACopy = Int.random(in: 0..<4, using: &choices) == 0
            if !keepsACopy {
                if toInitiatorSide { toInitiator.remove(at: index) } else { toResponder.remove(at: index) }
            }
            if index != 0 { outOfOrder += 1 }

            let side = toInitiatorSide ? 0 : 1
            let state = toInitiatorSide ? session.initiator : session.responder
            if expectedToDecrypt(message, state, seenKeys[side]) {
                if toInitiatorSide {
                    _ = try session.receive(message, &session.initiator)
                    seenKeys[side].insert(session.initiator.dhr!)
                } else {
                    _ = try session.receive(message, &session.responder)
                    seenKeys[side].insert(session.responder.dhr!)
                }
                delivered += 1
            } else {
                session.refuse(message, state, with: .decryptFailed)
                refused += 1
            }
        }

        #expect(session.initiator.mkskipped.count <= Ratchet.skippedKeysCap)
        #expect(session.responder.mkskipped.count <= Ratchet.skippedKeysCap)
        if round % 100 == 0 {
            for state in [session.initiator, session.responder] {
                let stored = try JSONEncoder().encode(state)
                #expect(try JSONDecoder().decode(RatchetState.self, from: stored) == state)
            }
        }
    }
    #expect(delivered > 500)
    #expect(outOfOrder > 100)
    #expect(refused > 20)
    #expect(session.responder.dhsteps > 10)
}
