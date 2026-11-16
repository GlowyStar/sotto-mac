import Foundation
import SwiftProtobuf

/// A binary message from the relay that section 7.3 calls a malformed frame.
public enum FrameError: Error, Equatable, Sendable {
    case malformed(String)
    /// A Hello whose version is not 1, read before its other fields (section 14.1).
    case unknownVersion(UInt32)
}

/// The parse step of a client for the frames of the relay (section 7.3).
public enum Frames {
    public static let relayProtocolVersion: UInt32 = 1
    public static let messageIDLength = 16
    public static let maxFrameBytes = 65536
    public static let maxPayloadBytes = maxFrameBytes - 64

    /// Returns the frame that a binary message from the relay holds.
    public static func readServerFrame(_ message: Data) throws -> Sotto_ServerFrame.OneOf_Frame {
        let envelope: Sotto_ServerFrame
        do {
            envelope = try Sotto_ServerFrame(serializedBytes: message)
        } catch {
            throw FrameError.malformed("the message is not a ServerFrame")
        }

        guard let frame = envelope.frame else {
            throw FrameError.malformed("no frame of the schema is set")
        }
        switch frame {
        case .hello(let hello):
            guard hello.version == relayProtocolVersion else {
                throw FrameError.unknownVersion(hello.version)
            }
            try requireLength("nonce", hello.nonce, Identity.nonceLength)
        case .bundle(let bundle):
            try checkBundle(bundle)
        case .stored(let stored):
            try requireLength("message_id", stored.messageID, messageIDLength)
        case .deliver(let deliver):
            try requireLength("message_id", deliver.messageID, messageIDLength)
            try requireLength("sender", deliver.sender, Identity.keyLength)
            guard (1...maxPayloadBytes).contains(deliver.payload.count) else {
                throw FrameError.malformed("payload is \(deliver.payload.count) bytes long, not 1 to \(maxPayloadBytes)")
            }
        case .error(let error):
            try requireLength("message_id", error.messageID, 0, messageIDLength)
            try requireLength("identity", error.identity, 0, Identity.keyLength)
            if !error.messageID.isEmpty && !error.identity.isEmpty {
                throw FrameError.malformed("the error names a Send and a FetchBundle")
            }
        case .loggedIn, .bundleStored:
            break
        }
        return frame
    }

    private static func checkBundle(_ bundle: Sotto_Bundle) throws {
        guard bundle.hasSignedPrekey else {
            throw FrameError.malformed("the bundle has no signed prekey")
        }
        try requireLength("identity", bundle.identity, Identity.keyLength)
        try requireLength("identity_dh_key", bundle.identityDhKey, Identity.keyLength)
        try requireLength("identity_dh_signature", bundle.identityDhSignature, Identity.signatureLength)
        try requireLength("signed_prekey.key", bundle.signedPrekey.key, Identity.keyLength)
        try requireLength("signed_prekey.signature", bundle.signedPrekey.signature, Identity.signatureLength)
        if bundle.hasOneTimePrekey {
            try requireLength("one_time_prekey.key", bundle.oneTimePrekey.key, Identity.keyLength)
        }
    }

    private static func requireLength(_ field: String, _ value: Data, _ lengths: Int...) throws {
        guard lengths.contains(value.count) else {
            throw FrameError.malformed("\(field) is \(value.count) bytes long, not \(lengths)")
        }
    }
}
