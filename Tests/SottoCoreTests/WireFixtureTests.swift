import Foundation
import SottoCore
import Testing

/// Replays Fixtures/wire.json, the bytes that the Python client built and what it made of
/// them (scripts/make-wire-fixtures.py).
private func cases(_ section: String, count: Int) throws -> [[String: Any]] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/wire.json")
    let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let found = document[section] as! [[String: Any]]
    #expect(found.count == count, "\(section) holds \(found.count) cases")
    return found
}

private func outcome(of frame: Sotto_ServerFrame.OneOf_Frame) throws -> (kind: String, bytes: Data) {
    switch frame {
    case .hello(let hello): ("hello", try hello.serializedBytes())
    case .loggedIn(let loggedIn): ("logged_in", try loggedIn.serializedBytes())
    case .bundleStored(let bundleStored): ("bundle_stored", try bundleStored.serializedBytes())
    case .bundle(let bundle): ("bundle", try bundle.serializedBytes())
    case .stored(let stored): ("stored", try stored.serializedBytes())
    case .deliver(let deliver): ("deliver", try deliver.serializedBytes())
    case .error(let error): ("error", try error.serializedBytes())
    case .blobStored(let stored): ("blob_stored", try stored.serializedBytes())
    case .blobData(let data): ("blob_data", try data.serializedBytes())
    }
}

@Test func serverFramesAreReadAsThePythonClientReadsThem() throws {
    for fixture in try cases("server_frames", count: 361) {
        let name = fixture["name"] as! String
        let message = Data(hex: fixture["hex"] as! String)
        do {
            let (kind, bytes) = try outcome(of: Frames.readServerFrame(message))
            #expect(fixture["kind"] as? String == kind, "\(name)")
            #expect(fixture["frame"] as? String == bytes.hex, "\(name)")
        } catch FrameError.unknownVersion(let version) {
            #expect(fixture["error"] as? String == "UnknownVersionError", "\(name)")
            #expect((fixture["version"] as? NSNumber)?.uint32Value == version, "\(name)")
        } catch FrameError.malformed {
            #expect(fixture["error"] as? String == "MalformedFrameError", "\(name)")
        }
    }
}

@Test func peerMessagesAreParsedAsThePythonClientParsesThem() throws {
    for fixture in try cases("peer_messages", count: 322) {
        let name = fixture["name"] as! String
        let payload = Data(hex: fixture["hex"] as! String)
        do {
            let parsed: Data = try Envelope.parse(payload).serializedBytes()
            #expect(fixture["message"] as? String == parsed.hex, "\(name)")
        } catch let error as EnvelopeError {
            #expect(fixture["error"] as? String == error.result, "\(name)")
        }
    }
}

@Test func paddedPlaintextsAreDecodedAsThePythonClientDecodesThem() throws {
    for fixture in try cases("padded", count: 121) {
        let name = fixture["name"] as! String
        do {
            switch try Envelope.decodeContent(Data(hex: fixture["hex"] as! String)) {
            case .text(let text):
                #expect(fixture["text"] as? String == text, "\(name)")
            case .attachment(let attachment):
                #expect(fixture["attachment"] as? String == (try attachment.serializedBytes() as Data).hex, "\(name)")
            case .profile:
                Issue.record("\(name) decoded as a profile")
            }
        } catch {
            #expect(fixture["error"] as? String == (error as? EnvelopeError)?.result, "\(name)")
        }
    }
}

@Test func textsArePaddedAsThePythonClientPadsThem() throws {
    for fixture in try cases("texts", count: 7) {
        let name = fixture["name"] as! String
        do {
            let padded = try Envelope.encodeText(fixture["text"] as! String)
            #expect(fixture["padded"] as? String == padded.hex, "\(name)")
        } catch {
            #expect(fixture["error"] as? String == (error as? EnvelopeError)?.result, "\(name)")
        }
    }
}
