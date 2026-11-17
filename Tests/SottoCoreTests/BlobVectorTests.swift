import Foundation
import SottoCore
import Testing

private func number(_ value: Any?) -> Int {
    (value as! NSNumber).intValue
}

private func hex(_ fields: [String: Any]?, _ key: String) -> String {
    fields?[key] as! String
}

/// vectors/blob.json (section 34), every vector replayed byte for byte.
struct BlobVectorTests {
    @Test func everyVectorOfTheBlobFileReplaysByteForByte() throws {
        let vectors = try loadVectors("blob")
        #expect(vectors.count == 43)
        var errors = 0
        for vector in vectors {
            switch vector.operation {
            case "blob-length":
                let size = number(vector.inputs["size"])
                #expect(Blob.paddedLength(size) == number(vector.outputs?["padded_length"]), "\(vector.name)")
                #expect(Blob.blobLength(size) == number(vector.outputs?["blob_length"]), "\(vector.name)")
            case "blob-encrypt":
                let file = vector.hex("file")
                let fileKey = vector.hex("file_key")
                let nonce = vector.hex("nonce")
                #expect(Blob.paddedLength(file.count) == number(vector.intermediates["padded_length"]), "\(vector.name)")
                #expect(Blob.payloadKey(fileKey: fileKey, nonce: nonce).hex == hex(vector.intermediates, "payload_key"))
                #expect(
                    Blob.chunkNonces(Blob.chunkCount(file.count)).map(\.hex)
                        == vector.intermediates["chunk_nonces"] as! [String],
                    "\(vector.name)"
                )
                let blob = try Blob.encrypt(file, fileKey: fileKey, nonce: nonce)
                #expect(blob.hex == hex(vector.outputs, "blob"), "\(vector.name)")
                #expect(Blob.digest(blob).hex == hex(vector.outputs, "digest"), "\(vector.name)")
            case "blob-open":
                let blob = vector.hex("blob")
                let fileKey = vector.hex("file_key")
                if let payloadKey = vector.intermediates["payload_key"] as? String {
                    #expect(Blob.payloadKey(fileKey: fileKey, nonce: blob.prefix(Blob.nonceLength)).hex == payloadKey)
                }
                do {
                    let file = try Blob.open(
                        blob, fileKey: fileKey, size: number(vector.inputs["size"]), digest: vector.hex("digest")
                    )
                    #expect(vector.error == nil, "\(vector.name) opened")
                    #expect(file.hex == hex(vector.outputs, "file"), "\(vector.name)")
                } catch let error as CryptoError {
                    errors += 1
                    #expect(error.result == vector.error, "\(vector.name)")
                }
            default:
                Issue.record("\(vector.name): no operation \(vector.operation)")
            }
        }
        #expect(errors == 10)
    }

    @Test func fileAboveTheLargestIsNotEncrypted() {
        #expect(throws: InvalidInputError.self) {
            try Blob.encrypt(Data(count: Blob.maxFileBytes + 1), fileKey: Data(count: 16), nonce: Data(count: 16))
        }
    }
}
