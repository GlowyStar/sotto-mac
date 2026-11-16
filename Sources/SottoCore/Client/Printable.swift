import Foundation

/// Peer text for a terminal: C0, DEL, C1, bidi controls and line separators written as
/// escapes, everything else as it is.
public func printable(_ text: String) -> String {
    var output = ""
    for scalar in text.unicodeScalars {
        let code = scalar.value
        let isBidiControl = code == 0x061C || code == 0x200E || code == 0x200F
            || (0x202A...0x202E).contains(code) || (0x2066...0x2069).contains(code)
        if code < 0x20 || code == 0x7F || (0x80...0x9F).contains(code) {
            output += String(format: "\\x%02x", code)
        } else if isBidiControl || code == 0x2028 || code == 0x2029 {
            output += String(format: "\\u%04x", code)
        } else {
            output.unicodeScalars.append(scalar)
        }
    }
    return output
}
