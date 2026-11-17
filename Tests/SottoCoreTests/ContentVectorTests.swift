import Foundation
@testable import SottoCore
import Testing

/// vectors/content.json (section 40), every vector replayed byte for byte.
struct ContentVectorTests {
    @Test func everyVectorOfTheContentFileReplaysByteForByte() throws {
        let vectors = try loadVectors("content")
        #expect(vectors.count == 47)
        var errors: [String: Int] = [:]
        for vector in vectors {
            do {
                switch vector.operation {
                case "content-encode":
                    let plaintext = try encode(vector.inputs)
                    #expect(plaintext.hex == vector.outputs?["plaintext"] as? String, "\(vector.name)")
                    #expect(try Envelope.unpad(plaintext).hex == vector.intermediates["content"] as? String, "\(vector.name)")
                case "content-decode":
                    let plaintext = vector.hex("plaintext")
                    let content = try Envelope.openContent(plaintext)
                    #expect(try Envelope.unpad(plaintext).hex == vector.intermediates["content"] as? String, "\(vector.name)")
                    #expect(
                        NSDictionary(dictionary: fields(content)) == NSDictionary(dictionary: vector.outputs ?? [:]),
                        "\(vector.name): \(fields(content))"
                    )
                default:
                    Issue.record("\(vector.name): no operation \(vector.operation)")
                }
                #expect(vector.error == nil, "\(vector.name) passed")
            } catch let error as EnvelopeError {
                errors[error.result, default: 0] += 1
                #expect(error.result == vector.error, "\(vector.name)")
            }
        }
        #expect(errors == ["TEXT_TOO_LONG": 2, "BAD_TIMER": 2, "BAD_CONTENT": 8, "UNKNOWN_CONTENT": 2])
    }

    @Test func receiverReadsNoQuoteAndNoTimerBesideAnEdit() throws {
        var content = Sotto_Content()
        content.edit.messageID = Data(repeating: 1, count: 16)
        content.quote.messageID = Data(count: 15)
        content.expiresAfter = UInt32(Envelope.maxTimerSeconds + 1)
        let opened = try Envelope.openContent(Envelope.pad(content.serializedBytes()))
        #expect(!opened.hasQuote && opened.expiresAfter == 0)
        guard case .edit = opened.body else {
            Issue.record("the edit is gone")
            return
        }
    }

    @Test func senderRefusesAQuoteBeyondItsLimits() {
        var quote = Sotto_Quote()
        quote.messageID = Data(count: 15)
        #expect(throws: InvalidInputError.self) { try Envelope.encodeText("hi", quote: quote) }
        quote.messageID = Data(count: 16)
        quote.text = String(repeating: "x", count: Envelope.maxQuoteBytes + 1)
        #expect(throws: InvalidInputError.self) { try Envelope.encodeText("hi", quote: quote) }
        #expect(throws: InvalidInputError.self) {
            try Envelope.encodeReceipt(messageIDs: Array(repeating: Data(count: 16), count: Envelope.maxReceiptIDs + 1), read: false)
        }
        #expect(throws: InvalidInputError.self) { try Envelope.encodeDeletion(messageID: Data(count: 17)) }
    }

    @Test func cutKeepsTheLongestStartOfWholeCharacters() {
        #expect(Envelope.cut("éa", to: 1) == "")
        #expect(Envelope.cut("aé", to: 2) == "a")
        #expect(Envelope.cut("aé", to: 3) == "aé")
    }

    /// Calls the encoder of the member that the inputs set (section 40).
    private func encode(_ inputs: [String: Any]) throws -> Data {
        let quote = (inputs["quote"] as? [String: Any]).map(self.quote)
        let expiresAfter = (inputs["expires_after"] as? NSNumber)?.intValue ?? 0
        if let text = inputs["text"] as? String {
            return try Envelope.encodeText(text, quote: quote, expiresAfter: expiresAfter)
        }
        if let attachment = inputs["attachment"] as? [String: Any] {
            return try Envelope.encodeAttachment(self.attachment(attachment), quote: quote, expiresAfter: expiresAfter)
        }
        if let edit = inputs["edit"] as? [String: Any] {
            return try Envelope.encodeEdit(messageID: Data(hex: edit["message_id"] as! String), text: edit["text"] as? String ?? "")
        }
        if let deletion = inputs["deletion"] as? [String: Any] {
            return try Envelope.encodeDeletion(messageID: Data(hex: deletion["message_id"] as! String))
        }
        if let receipt = inputs["receipt"] as? [String: Any] {
            let ids = (receipt["message_ids"] as? [String] ?? []).map { Data(hex: $0) }
            return try Envelope.encodeReceipt(messageIDs: ids, read: receipt["read"] as? Bool ?? false)
        }
        let timer = inputs["timer"] as! [String: Any]
        return try Envelope.encodeTimer(seconds: (timer["seconds"] as? NSNumber)?.intValue ?? 0)
    }

    private func quote(_ fields: [String: Any]) -> Sotto_Quote {
        var quote = Sotto_Quote()
        quote.messageID = Data(hex: fields["message_id"] as! String)
        quote.own = fields["own"] as? Bool ?? false
        quote.text = fields["text"] as? String ?? ""
        return quote
    }

    private func attachment(_ fields: [String: Any]) -> Sotto_Attachment {
        var attachment = Sotto_Attachment()
        for (key, value) in fields {
            switch key {
            case "blob_id": attachment.blobID = Data(hex: value as! String)
            case "key": attachment.key = Data(hex: value as! String)
            case "digest": attachment.digest = Data(hex: value as! String)
            case "thumbnail": attachment.thumbnail = Data(hex: value as! String)
            case "size": attachment.size = (value as! NSNumber).uint32Value
            case "width": attachment.width = (value as! NSNumber).uint32Value
            case "height": attachment.height = (value as! NSNumber).uint32Value
            case "media_type": attachment.mediaType = value as! String
            case "file_name": attachment.fileName = value as! String
            case "caption": attachment.caption = value as! String
            default: Issue.record("no field \(key) in an Attachment")
            }
        }
        return attachment
    }

    /// The fields that the receiver reads, in the shape of the vectors: set fields only.
    private func fields(_ content: Sotto_Content) -> [String: Any] {
        var fields: [String: Any] = [:]
        switch content.body {
        case .text(let text):
            fields["text"] = text
        case .attachment(let attachment):
            var object: [String: Any] = [
                "blob_id": attachment.blobID.hex, "key": attachment.key.hex, "digest": attachment.digest.hex,
                "size": NSNumber(value: attachment.size),
            ]
            if !attachment.mediaType.isEmpty { object["media_type"] = attachment.mediaType }
            if !attachment.fileName.isEmpty { object["file_name"] = attachment.fileName }
            if !attachment.caption.isEmpty { object["caption"] = attachment.caption }
            if !attachment.thumbnail.isEmpty { object["thumbnail"] = attachment.thumbnail.hex }
            if attachment.width > 0 { object["width"] = NSNumber(value: attachment.width) }
            if attachment.height > 0 { object["height"] = NSNumber(value: attachment.height) }
            fields["attachment"] = object
        case .edit(let edit):
            var object: [String: Any] = ["message_id": edit.messageID.hex]
            if !edit.text.isEmpty { object["text"] = edit.text }
            fields["edit"] = object
        case .deletion(let deletion):
            fields["deletion"] = ["message_id": deletion.messageID.hex]
        case .receipt(let receipt):
            var object: [String: Any] = [:]
            if receipt.read { object["read"] = true }
            if !receipt.messageIds.isEmpty { object["message_ids"] = receipt.messageIds.map(\.hex) }
            fields["receipt"] = object
        case .timer(let timer):
            fields["timer"] = timer.seconds > 0 ? ["seconds": NSNumber(value: timer.seconds)] : [String: Any]()
        case .profile, nil:
            Issue.record("a content of part 5 decoded as \(String(describing: content.body))")
        }
        if content.hasQuote {
            var object: [String: Any] = ["message_id": content.quote.messageID.hex]
            if content.quote.own { object["own"] = true }
            if !content.quote.text.isEmpty { object["text"] = content.quote.text }
            fields["quote"] = object
        }
        if content.expiresAfter > 0 {
            fields["expires_after"] = NSNumber(value: content.expiresAfter)
        }
        return fields
    }
}
