import Foundation
import SottoCore
import Testing

private let keyMaterialPrefix = Data(repeating: 0xFF, count: 32)
private let unusedRandomBytes = Data(count: 32)

private func strings(_ fields: [String: Any]?) -> [String: String]? {
    fields as? [String: String]
}

private func bundle(of vector: Vector) -> PrekeyBundle {
    var oneTimePrekey: OneTimePrekey?
    if vector.inputs["one_time_prekey_id"] != nil {
        oneTimePrekey = OneTimePrekey(id: vector.prekeyID("one_time_prekey_id"), key: vector.hex("one_time_prekey_key"))
    }
    return PrekeyBundle(
        identity: vector.hex("identity"),
        identityDHKey: vector.hex("identity_dh_key"),
        identityDHSignature: vector.hex("identity_dh_signature"),
        signedPrekey: SignedPrekey(
            id: vector.prekeyID("signed_prekey_id"),
            key: vector.hex("signed_prekey_key"),
            signature: vector.hex("signed_prekey_signature")
        ),
        oneTimePrekey: oneTimePrekey
    )
}

/// Runs a vector and compares its outputs, or the named result of a negative vector.
private func expectOutcome(of vector: Vector, _ replay: () throws -> [String: String]) throws {
    do {
        let outputs = try replay()
        #expect(vector.error == nil, "\(vector.name) did not fail")
        #expect(outputs == strings(vector.outputs), "\(vector.name)")
    } catch let error as CryptoError {
        #expect(error.result == vector.error, "\(vector.name)")
    }
}

// MARK: identity.json

private func replayIdentity(_ vector: Vector) throws -> [String: String] {
    switch vector.operation {
    case "identity-key":
        let identityKey = try Identity.deriveIdentityKey(seed: vector.hex("seed"))
        return ["identity_key": identityKey.hex, "user_id": try Identity.encodeUserID(identityKey)]
    case "x25519-public-key":
        return ["public_key": try Identity.deriveX25519PublicKey(vector.hex("private_key")).hex]
    case "decode-user-id":
        return ["identity_key": try Identity.decodeUserID(vector.text("user_id")).hex]
    case "verify-login":
        try Identity.verifyLogin(
            identityKey: vector.hex("identity_key"),
            signature: vector.hex("signature"),
            serverName: vector.text("server_name"),
            serverNonce: vector.hex("server_nonce"),
            clientNonce: vector.hex("client_nonce")
        )
        return [:]
    case "check-bundle":
        try Identity.checkBundle(
            bundle(of: vector),
            contactIdentityKey: Identity.decodeUserID(vector.text("contact_id")),
            pinnedIdentityDHKey: vector.optionalHex("pinned_identity_dh_key")
        )
        return [:]
    default:
        Issue.record("\(vector.name): no operation \(vector.operation)")
        return [:]
    }
}

private func signedStringsOfIdentity(_ vector: Vector) throws -> [String: String] {
    switch vector.operation {
    case "verify-login":
        let loginString = try Identity.loginString(
            serverName: vector.text("server_name"),
            serverNonce: vector.hex("server_nonce"),
            clientNonce: vector.hex("client_nonce")
        )
        return ["login_string": loginString.hex]
    case "check-bundle":
        let identity = vector.hex("identity")
        return [
            "identity_dh_string": try Identity.identityDHString(identityKey: identity, identityDHKey: vector.hex("identity_dh_key")).hex,
            "signed_prekey_string": try Identity.signedPrekeyString(identityKey: identity, signedPrekey: vector.hex("signed_prekey_key")).hex,
        ]
    default:
        return [:]
    }
}

@Test func identityVectorsReplayByteForByte() throws {
    let vectors = try loadVectors("identity")
    #expect(vectors.count == 79)

    var replayed = 0
    for vector in vectors {
        try expectOutcome(of: vector) { try replayIdentity(vector) }
        #expect(try signedStringsOfIdentity(vector) == strings(vector.intermediates), "\(vector.name)")
        replayed += 1
    }
    #expect(replayed == 79)
}

// MARK: x3dh.json

private func replayX3DH(_ vector: Vector) throws -> [String: String] {
    let agreement: KeyAgreement
    switch vector.operation {
    case "x3dh-initiate":
        agreement = try X3DH.initiate(
            bundle: bundle(of: vector),
            identityKey: vector.hex("identity_key"),
            identityDHPrivateKey: vector.hex("identity_dh_private_key"),
            ephemeralPrivateKey: vector.hex("ephemeral_private_key"),
            contactIdentityKey: Identity.decodeUserID(vector.text("contact_id")),
            pinnedIdentityDHKey: nil
        )
    case "x3dh-respond":
        agreement = try X3DH.respond(
            identityKey: vector.hex("identity_key"),
            identityDHPrivateKey: vector.hex("identity_dh_private_key"),
            signedPrekeyPrivateKey: vector.hex("signed_prekey_private_key"),
            oneTimePrekeyPrivateKey: vector.optionalHex("one_time_prekey_private_key"),
            senderIdentityKey: vector.hex("sender"),
            senderIdentityDHKey: vector.hex("identity_dh_key"),
            senderIdentityDHSignature: vector.hex("identity_dh_signature"),
            ephemeralKey: vector.hex("ephemeral_key"),
            pinnedIdentityDHKey: nil
        )
    default:
        Issue.record("\(vector.name): no operation \(vector.operation)")
        return [:]
    }
    return ["sk": agreement.sharedSecret.hex, "session_associated_data": agreement.associatedData.hex]
}

/// DH1 to DH4 by the `dh` of the core, in the order of sections 16.6 and 16.8.
private func dhOutputs(of vector: Vector) throws -> [Data] {
    let pairs = vector.operation == "x3dh-initiate"
        ? [
            ("identity_dh_private_key", "signed_prekey_key"),
            ("ephemeral_private_key", "identity_dh_key"),
            ("ephemeral_private_key", "signed_prekey_key"),
            ("ephemeral_private_key", "one_time_prekey_key"),
        ]
        : [
            ("signed_prekey_private_key", "identity_dh_key"),
            ("identity_dh_private_key", "ephemeral_key"),
            ("signed_prekey_private_key", "ephemeral_key"),
            ("one_time_prekey_private_key", "ephemeral_key"),
        ]
    return try pairs.compactMap { privateKey, publicKey in
        guard let ownKey = vector.optionalHex(privateKey), let peerKey = vector.optionalHex(publicKey) else {
            return nil
        }
        return try X3DH.dh(privateKey: ownKey, publicKey: peerKey)
    }
}

private func intermediatesOfX3DH(_ vector: Vector) throws -> [String: String] {
    let identityDHKey = vector.hex("identity_dh_key")
    var computed: [String: String]
    if vector.operation == "x3dh-initiate" {
        let identity = vector.hex("identity")
        computed = [
            "identity_dh_string": try Identity.identityDHString(identityKey: identity, identityDHKey: identityDHKey).hex,
            "signed_prekey_string": try Identity.signedPrekeyString(identityKey: identity, signedPrekey: vector.hex("signed_prekey_key")).hex,
        ]
    } else {
        computed = [
            "identity_dh_string": try Identity.identityDHString(identityKey: vector.hex("sender"), identityDHKey: identityDHKey).hex
        ]
    }
    if vector.outputs != nil {
        let outputs = try dhOutputs(of: vector)
        for (index, output) in outputs.enumerated() {
            computed["dh\(index + 1)"] = output.hex
        }
        computed["input_key_material"] = outputs.reduce(keyMaterialPrefix, +).hex
    }
    return computed
}

@Test func x3dhVectorsReplayByteForByte() throws {
    let vectors = try loadVectors("x3dh")
    #expect(vectors.count == 12)

    var replayed = 0
    for vector in vectors {
        try expectOutcome(of: vector) { try replayX3DH(vector) }
        #expect(try intermediatesOfX3DH(vector) == strings(vector.intermediates), "\(vector.name)")
        replayed += 1
    }
    #expect(replayed == 12)
}

// MARK: ratchet.json

private func entries(_ value: Any?) -> [SkippedKey] {
    (value as! [[String: Any]]).map { entry in
        SkippedKey(
            ratchetKey: Data(hex: entry["ratchet_key"] as! String),
            number: UInt32((entry["number"] as! NSNumber).uint64Value),
            messageKey: Data(hex: entry["message_key"] as! String),
            step: (entry["step"] as! NSNumber).uint64Value
        )
    }
}

/// Compares every recorded intermediate value of a decryption with the values of the core.
private func expectIntermediatesOfDecryption(
    _ vector: Vector,
    before: RatchetState,
    after: RatchetState,
    associatedData: Data
) throws {
    let recorded = vector.intermediates
    let header = vector.hex("header")
    let ratchetKey = header.prefix(32)
    let number = header.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    var computed: [String: String] = [:]

    if let ratchetPrivateKey = vector.optionalHex("ratchet_private_key") {
        let dhReceiving = try X3DH.dh(privateKey: before.dhsPrivateKey, publicKey: Data(ratchetKey))
        let receiving = Ratchet.kdfRK(before.rk, dhReceiving)
        let dhSending = try X3DH.dh(privateKey: ratchetPrivateKey, publicKey: Data(ratchetKey))
        let sending = Ratchet.kdfRK(receiving.rootKey, dhSending)
        #expect(sending.rootKey == after.rk && sending.chainKey == after.cks, "\(vector.name)")
        computed = [
            "dh_receiving": dhReceiving.hex,
            "root_key_receiving": receiving.rootKey.hex,
            "chain_key_receiving": receiving.chainKey.hex,
            "ratchet_key": after.dhsPublicKey.hex,
            "dh_sending": dhSending.hex,
            "root_key_sending": after.rk.hex,
            "chain_key_sending": after.cks!.hex,
        ]
    }

    let removed = before.mkskipped.filter { !after.mkskipped.contains($0) }
    let used = removed.filter { $0.ratchetKey == ratchetKey && $0.number == number }
    let messageKey: Data
    if let entry = used.first {
        messageKey = entry.messageKey
    } else {
        let chainKey = Data(hex: recorded["chain_key"] as! String)
        let derived = Ratchet.kdfCK(chainKey)
        #expect(derived.chainKey == after.ckr, "\(vector.name)")
        messageKey = derived.messageKey
        computed["chain_key"] = chainKey.hex
    }
    computed["message_key"] = messageKey.hex
    computed["associated_data"] = (associatedData + header).hex

    var recordedStrings = recorded
    recordedStrings["stored_skipped_keys"] = nil
    recordedStrings["purged_skipped_keys"] = nil
    #expect(computed == strings(recordedStrings), "\(vector.name)")

    let stored = after.mkskipped.filter { !before.mkskipped.contains($0) }
    #expect(stored == entries(recorded["stored_skipped_keys"]), "\(vector.name)")
    #expect(removed.filter { !used.contains($0) } == entries(recorded["purged_skipped_keys"]), "\(vector.name)")
}

@Test func ratchetVectorsReplayAsOneConversation() throws {
    let vectors = try loadVectors("ratchet")
    #expect(vectors.count == 49)

    var states: [String: RatchetState] = [:]
    var sessionData: [String: Data] = [:]
    var replayed = 0
    for vector in vectors {
        switch vector.operation {
        case "ratchet-init-initiator":
            let after = try Ratchet.initInitiator(
                sharedSecret: vector.hex("sk"),
                signedPrekey: vector.hex("signed_prekey_key"),
                ratchetPrivateKey: vector.hex("ratchet_private_key")
            )
            let dhOutput = try X3DH.dh(privateKey: vector.hex("ratchet_private_key"), publicKey: after.dhr!)
            let derived = Ratchet.kdfRK(vector.hex("sk"), dhOutput)
            #expect(derived.rootKey == after.rk && derived.chainKey == after.cks)
            let computed = [
                "ratchet_key": after.dhsPublicKey.hex,
                "dh": dhOutput.hex,
                "root_key": derived.rootKey.hex,
                "chain_key": derived.chainKey.hex,
            ]
            #expect(computed == strings(vector.intermediates), "\(vector.name)")
            states["initiator"] = after
            sessionData["initiator"] = vector.hex("session_associated_data")

        case "ratchet-init-responder":
            let after = try Ratchet.initResponder(
                sharedSecret: vector.hex("sk"),
                signedPrekeyPrivateKey: vector.hex("signed_prekey_private_key")
            )
            #expect(["ratchet_key": after.dhsPublicKey.hex] == strings(vector.intermediates), "\(vector.name)")
            states["responder"] = after
            sessionData["responder"] = vector.hex("session_associated_data")

        case "ratchet-encrypt":
            let party = vector.text("party")
            let before = try #require(states[party])
            let associatedData = try #require(sessionData[party]) + vector.hex("message_id")
            do {
                let encrypted = try Ratchet.encrypt(
                    before,
                    paddedPlaintext: vector.hex("padded_plaintext"),
                    associatedData: associatedData,
                    nonce: vector.hex("nonce")
                )
                #expect(vector.error == nil, "\(vector.name) did not fail")
                #expect(["ciphertext": encrypted.ciphertext.hex] == strings(vector.outputs), "\(vector.name)")
                let chainKey = try #require(before.cks)
                let computed = [
                    "chain_key": chainKey.hex,
                    "message_key": Ratchet.kdfCK(chainKey).messageKey.hex,
                    "header": encrypted.header.hex,
                    "associated_data": (associatedData + encrypted.header).hex,
                ]
                #expect(computed == strings(vector.intermediates), "\(vector.name)")
                states[party] = encrypted.state
            } catch let error as CryptoError {
                #expect(error.result == vector.error, "\(vector.name)")
                #expect(vector.intermediates.isEmpty, "\(vector.name)")
            }

        case "ratchet-decrypt":
            let party = vector.text("party")
            let before = try #require(states[party])
            let associatedData = try #require(sessionData[party]) + vector.hex("message_id")
            do {
                let decrypted = try Ratchet.decrypt(
                    before,
                    header: vector.hex("header"),
                    ciphertext: vector.hex("ciphertext"),
                    associatedData: associatedData,
                    ratchetPrivateKey: vector.optionalHex("ratchet_private_key") ?? unusedRandomBytes
                )
                #expect(vector.error == nil, "\(vector.name) did not fail")
                let outputs = try #require(vector.outputs)
                #expect(decrypted.paddedPlaintext.hex == outputs["padded_plaintext"] as? String, "\(vector.name)")
                #expect(decrypted.purged == (outputs["purged_count"] as? NSNumber)?.intValue, "\(vector.name)")
                try expectIntermediatesOfDecryption(
                    vector, before: before, after: decrypted.state, associatedData: associatedData
                )
                states[party] = decrypted.state
            } catch let error as CryptoError {
                #expect(error.result == vector.error, "\(vector.name)")
                #expect(vector.intermediates.isEmpty, "\(vector.name)")
            }

        default:
            Issue.record("\(vector.name): no operation \(vector.operation)")
        }
        replayed += 1
    }
    #expect(replayed == 49)
}
