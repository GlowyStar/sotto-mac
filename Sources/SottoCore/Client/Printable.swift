import Foundation

/// Peer text for a terminal: C0, DEL, C1, bidi controls and line separators written as
/// escapes, everything else as it is.
public func printable(_ text: String) -> String {
    var output = ""
    for scalar in text.unicodeScalars {
        let code = scalar.value
        if !Envelope.isControl(scalar) {
            output.unicodeScalars.append(scalar)
        } else if code <= 0xFF {
            output += String(format: "\\x%02x", code)
        } else {
            output += String(format: "\\u%04x", code)
        }
    }
    return output
}
