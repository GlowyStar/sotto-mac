import Foundation

private let vectorsDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Protocol/vectors")

/// One vector of a file of section 15.2.
struct Vector {
    let name: String
    let operation: String
    let inputs: [String: Any]
    let intermediates: [String: Any]
    let outputs: [String: Any]?
    let error: String?

    func hex(_ key: String) -> Data {
        Data(hex: inputs[key] as! String)
    }

    func optionalHex(_ key: String) -> Data? {
        (inputs[key] as? String).map { Data(hex: $0) }
    }

    func text(_ key: String) -> String {
        inputs[key] as! String
    }

    func prekeyID(_ key: String) -> UInt32 {
        UInt32((inputs[key] as! NSNumber).uint64Value)
    }
}

func loadVectors(_ file: String) throws -> [Vector] {
    let data = try Data(contentsOf: vectorsDirectory.appendingPathComponent("\(file).json"))
    let document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    return (document["vectors"] as! [[String: Any]]).map { fields in
        Vector(
            name: fields["name"] as! String,
            operation: fields["operation"] as! String,
            inputs: fields["inputs"] as! [String: Any],
            intermediates: fields["intermediates"] as! [String: Any],
            outputs: fields["outputs"] as? [String: Any],
            error: fields["error"] as? String
        )
    }
}

extension Data {
    init(hex: String) {
        let digits = Array(hex.utf8)
        self.init(stride(from: 0, to: digits.count, by: 2).map { index in
            UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16)!
        })
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
