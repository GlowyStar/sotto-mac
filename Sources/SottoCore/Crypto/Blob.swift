import CryptoKit
import Foundation

/// The blob cipher of docs/protocol.md, section 29: the age v1 payload of a padded file.
///
/// Pure code without input or output: the file key and the nonce are arguments, and a blob
/// that fails to open throws `CryptoError.badBlob` and returns no byte of the file.
public enum Blob {
    public static let maxFileBytes = 104_857_600
    public static let paddingMin = 256
    public static let streamChunkBytes = 65536
    public static let fileKeyLength = 16
    public static let nonceLength = 16
    public static let digestLength = 32
    public static let tagLength = 16
    public static let sealedChunkBytes = streamChunkBytes + tagLength
    static let payloadInfo = Data("payload".utf8)
    static let counterLength = 11

    /// P of section 29.2: the Padme function of max(size, `paddingMin`).
    public static func paddedLength(_ size: Int) -> Int {
        let length = max(size, paddingMin)
        let exponent = Int.bitWidth - length.leadingZeroBitCount - 1
        let sizeBits = Int.bitWidth - exponent.leadingZeroBitCount
        let mask = (1 << (exponent - sizeBits)) - 1
        return (length + mask) & ~mask
    }

    /// n of section 29.4: the chunks of the padded file.
    public static func chunkCount(_ size: Int) -> Int {
        (paddedLength(size) + streamChunkBytes - 1) / streamChunkBytes
    }

    /// B of section 29.5: the nonce, the padded file and a tag for each chunk.
    public static func blobLength(_ size: Int) -> Int {
        nonceLength + paddedLength(size) + tagLength * chunkCount(size)
    }

    /// The payload key of section 29.3.
    public static func payloadKey(fileKey: Data, nonce: Data) -> Data {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: fileKey),
            salt: nonce,
            info: payloadInfo,
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
    }

    /// The nonces of section 29.4 for `count` chunks, in their order.
    public static func chunkNonces(_ count: Int) -> [Data] {
        (0..<count).map { index in
            var nonce = Data(count: counterLength - 8)
            withUnsafeBytes(of: UInt64(index).bigEndian) { nonce.append(contentsOf: $0) }
            nonce.append(index == count - 1 ? 1 : 0)
            return nonce
        }
    }

    /// The digest of section 29.6.
    public static func digest(_ blob: Data) -> Data {
        Data(SHA256.hash(data: blob))
    }

    /// The blob of section 29.5; a new file key and nonce for every blob (section 29.1).
    ///
    /// - Throws: `InvalidInputError` when the file is longer than `maxFileBytes` or a key or
    ///   nonce is not 16 bytes.
    public static func encrypt(_ file: Data, fileKey: Data, nonce: Data) throws -> Data {
        guard file.count <= maxFileBytes else {
            throw InvalidInputError(message: "the file is \(file.count) bytes long, above \(maxFileBytes)")
        }
        guard fileKey.count == fileKeyLength, nonce.count == nonceLength else {
            throw InvalidInputError(message: "the file key and the nonce are 16 bytes each")
        }

        var plaintext = file
        plaintext.append(Data(count: paddedLength(file.count) - file.count))
        let key = SymmetricKey(data: payloadKey(fileKey: fileKey, nonce: nonce))
        var blob = nonce
        blob.reserveCapacity(blobLength(file.count))
        for (index, chunkNonce) in chunkNonces(chunkCount(file.count)).enumerated() {
            let start = plaintext.startIndex + index * streamChunkBytes
            let chunk = plaintext[start..<min(start + streamChunkBytes, plaintext.endIndex)]
            let sealed = try ChaChaPoly.seal(chunk, using: key, nonce: ChaChaPoly.Nonce(data: chunkNonce))
            blob.append(sealed.ciphertext)
            blob.append(sealed.tag)
        }
        return blob
    }

    /// Returns the file of a blob by the six steps of section 29.7.
    ///
    /// - Throws: `CryptoError.badBlob` when a step fails; no byte of the file is returned.
    public static func open(_ blob: Data, fileKey: Data, size: Int, digest expected: Data) throws -> Data {
        guard (0...maxFileBytes).contains(size), blob.count == blobLength(size) else {
            throw CryptoError.badBlob
        }
        guard digest(blob) == expected, fileKey.count == fileKeyLength else {
            throw CryptoError.badBlob
        }

        let start = blob.startIndex
        let key = SymmetricKey(data: payloadKey(fileKey: fileKey, nonce: blob[start..<start + nonceLength]))
        var plaintext = Data()
        plaintext.reserveCapacity(paddedLength(size))
        do {
            for (index, chunkNonce) in chunkNonces(chunkCount(size)).enumerated() {
                let from = start + nonceLength + index * sealedChunkBytes
                let to = min(from + sealedChunkBytes, blob.endIndex)
                let box = try ChaChaPoly.SealedBox(
                    nonce: ChaChaPoly.Nonce(data: chunkNonce),
                    ciphertext: blob[from..<to - tagLength],
                    tag: blob[to - tagLength..<to]
                )
                plaintext.append(try ChaChaPoly.open(box, using: key))
            }
        } catch {
            throw CryptoError.badBlob
        }

        guard plaintext[size...].allSatisfy({ $0 == 0 }) else {
            throw CryptoError.badBlob
        }
        return Data(plaintext.prefix(size))
    }
}
