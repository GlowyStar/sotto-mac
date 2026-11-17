import Foundation

/// Received files on disk by docs/protocol.md, section 32.2: the name of the peer never
/// picks a folder and a file is never written over another.
public enum ReceivedFiles {
    public static let folderMode: mode_t = 0o700
    public static let fileMode: mode_t = 0o600
    public static let ownName = "received-file"

    /// Whether a received name keeps the rule of section 32.2.
    public static func isSafeName(_ name: String) -> Bool {
        let isTooLong = name.utf8.count > Envelope.maxFileNameBytes
        let isAFolderName = name.isEmpty || name == "." || name == ".."
        let hasABadCharacter = name.unicodeScalars.contains { $0 == "/" || $0 == "\\" || Envelope.isControl($0) }
        return !(isTooLong || isAFolderName || hasABadCharacter)
    }

    /// Writes a received file into `folder` under a free name and returns its path.
    ///
    /// The name is the sent one when it passes `isSafeName`, else one of the client's own; a
    /// name that is taken gets a number, ` (1)` and up, in front of its suffix. A write that
    /// fails leaves no file.
    public static func save(_ data: Data, named fileName: String, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: folderMode]
        )
        let name = isSafeName(fileName) ? fileName : ownName
        let (stem, suffix) = split(name)

        var number = 0
        while true {
            var candidate = number == 0 ? name : "\(stem) (\(number))\(suffix)"
            if candidate.utf8.count > Envelope.maxFileNameBytes {
                candidate = "\(ownName) (\(number))"
            }
            let path = folder.appendingPathComponent(candidate)
            number += 1
            let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, fileMode)
            if descriptor < 0 {
                if errno == EEXIST {
                    continue
                }
                throw StoreError.system(path: path.path, errno: errno)
            }
            let written = data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                    if count <= 0 {
                        return false
                    }
                    offset += count
                }
                return true
            }
            let failure = errno
            let synced = written && fsync(descriptor) == 0
            close(descriptor)
            guard synced else {
                unlink(path.path)
                throw StoreError.system(path: path.path, errno: written ? errno : failure)
            }
            return path
        }
    }

    /// The stem and the suffix of a name as Python's `pathlib` splits them.
    static func split(_ name: String) -> (stem: String, suffix: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else {
            return (name, "")
        }
        return (String(name[..<dot]), String(name[dot...]))
    }
}
