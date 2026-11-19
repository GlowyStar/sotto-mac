import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// What the Secure Enclave key that wraps a store key asks for before each use
/// (docs/key-storage.md).
public enum StoreProtection: String, Codable, Sendable {
    /// Touch ID or the Mac password.
    case presence
    /// Nothing: the stores of tests and scripts, never an owner directory.
    case test

    /// The variable that asks for `.test`; only the value `test` counts.
    public static let environmentVariable = "SOTTO_STORE_PROTECTION"

    /// The protection a launch asks for in `directory`: `.test` when the environment says so,
    /// refused for an owner directory; `.presence` otherwise.
    public static func asked(
        for directory: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> StoreProtection {
        guard environment[environmentVariable] == StoreProtection.test.rawValue else { return .presence }
        if StoreKeys.isOwnerDirectory(directory) {
            throw StoreError.testProtectionRefused(path: directory.path)
        }
        return .test
    }
}

/// The store keys of this process, by data directory: a random 256-bit key per store, kept on
/// disk only wrapped (HPKE, RFC 9180, P256_SHA256_AES_GCM_256, to a Secure Enclave key), and
/// in memory only between `unlock` and `lock`.
public enum StoreKeys {
    public static let fileName = "store.key"
    static let keyLength = 32
    static let wrapVersion = 1

    /// The default data directories of the app and of `sotto-mac`: the owner's real data,
    /// which only `.presence` may protect.
    public static let ownerDirectories: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/Sotto", isDirectory: true),
            home.appendingPathComponent(".sotto-mac", isDirectory: true),
        ]
    }()

    /// Unwraps the key of the store in `directory` and keeps it until `lock`, making the key
    /// first when the directory has none. With `.presence` the Secure Enclave asks for Touch
    /// ID or the Mac password, unless `context` was already evaluated.
    public static func unlock(_ directory: URL, protection: StoreProtection, context: LAContext? = nil) throws {
        guard SecureEnclave.isAvailable else { throw StoreError.noSecureEnclave }
        if protection == .test, isOwnerDirectory(directory) {
            throw StoreError.testProtectionRefused(path: directory.path)
        }
        try ClientStore.makePrivateDirectory(directory)
        let file = directory.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: file.path) {
            let store = directory.appendingPathComponent(ClientStore.fileName)
            if try ClientStore.holdsEncryptedPages(store) {
                throw StoreError.missingKey(path: file.path)
            }
            try write(enclave.withLock { try make(protection) }, to: file)
        }
        guard let wrapped = try? JSONDecoder().decode(WrappedKey.self, from: Data(contentsOf: file)),
            wrapped.version == wrapVersion
        else { throw StoreError.damagedKey(path: file.path) }
        guard wrapped.protection == protection else {
            throw StoreError.protectionMismatch(path: file.path, stored: wrapped.protection, asked: protection)
        }
        let key = try enclave.withLock { try unwrap(wrapped, context: context) }
        if case .open(let old, _) = registry.set(directory, .open(key, protection)) {
            old.wipe()
        }
    }

    /// Drops the key of `directory`; the store opens again only after `unlock`.
    public static func lock(_ directory: URL) {
        if case .open(let key, _) = registry.set(directory, .locked) {
            key.wipe()
        }
    }

    /// The key bytes held for `directory`, for the tests of `lock`.
    static func heldKey(_ directory: URL) -> KeyBytes? {
        if case .open(let key, _) = registry.get(directory) { key } else { nil }
    }

    public static func isUnlocked(_ directory: URL) -> Bool {
        if case .open = registry.get(directory) { true } else { false }
    }

    /// The protection of the key held for `directory`; nil while it is locked.
    public static func protection(_ directory: URL) -> StoreProtection? {
        if case .open(_, let protection) = registry.get(directory) { protection } else { nil }
    }

    /// Whether `directory` is one of `ownerDirectories`, also by another spelling of the
    /// path or through a link, and also before it exists (by its parent and its name).
    public static func isOwnerDirectory(_ directory: URL) -> Bool {
        func same(_ a: URL, _ b: URL) -> Bool {
            var first = stat()
            var second = stat()
            return stat(a.path, &first) == 0 && stat(b.path, &second) == 0 && first.st_dev == second.st_dev
                && first.st_ino == second.st_ino
        }
        let directory = directory.standardizedFileURL
        return ownerDirectories.contains { owner in
            canonical(owner).lowercased() == canonical(directory).lowercased() || same(owner, directory)
                || (owner.lastPathComponent.lowercased() == directory.lastPathComponent.lowercased()
                    && same(owner.deletingLastPathComponent(), directory.deletingLastPathComponent()))
        }
    }

    /// Runs `body` with the raw key of `directory` spelled as SQLCipher takes it, `x'<hex>'`,
    /// in a buffer that is overwritten afterwards. A directory that was never unlocked nor
    /// locked in this process is unlocked here when the environment asks for `.test`.
    static func withKeyLiteral<T>(_ directory: URL, _ body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
        if registry.get(directory) == nil, try StoreProtection.asked(for: directory) == .test {
            try unlock(directory, protection: .test)
        }
        guard case .open(let key, _) = registry.get(directory) else { throw StoreError.locked }
        let literal = KeyBytes(count: keyLength * 2 + 3)
        let hex = Array("0123456789abcdef".utf8)
        let out = literal.bytes
        out[0] = UInt8(ascii: "x")
        out[1] = UInt8(ascii: "'")
        for (index, byte) in key.bytes.enumerated() {
            out[2 + index * 2] = hex[Int(byte >> 4)]
            out[3 + index * 2] = hex[Int(byte & 0x0f)]
        }
        out[out.count - 1] = UInt8(ascii: "'")
        return try body(UnsafeRawBufferPointer(out))
    }

    // MARK: The wrap

    struct WrappedKey: Codable {
        var version: Int
        var protection: StoreProtection
        /// `dataRepresentation` of the Secure Enclave key: usable only by the Secure Enclave
        /// that made it.
        var enclaveKey: Data
        var encapsulatedKey: Data
        var sealedKey: Data
    }

    static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256

    static func info(_ protection: StoreProtection) -> Data {
        Data("sotto-mac store key \(wrapVersion) \(protection.rawValue)".utf8)
    }

    static func make(_ protection: StoreProtection) throws -> WrappedKey {
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if protection == .presence { flags.insert(.userPresence) }
        var failure: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &failure)
        else { throw StoreError.enclaveRefused(reason: "\(failure!.takeRetainedValue())") }
        let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)

        var storeKey = Data(count: keyLength)
        defer { wipe(&storeKey) }
        let made = storeKey.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, keyLength, $0.baseAddress!) }
        guard made == errSecSuccess else { throw StoreError.enclaveRefused(reason: "no random bytes: \(made)") }
        var sender = try HPKE.Sender(recipientKey: enclaveKey.publicKey, ciphersuite: suite, info: info(protection))
        let sealed = try sender.seal(storeKey)
        return WrappedKey(
            version: wrapVersion, protection: protection, enclaveKey: enclaveKey.dataRepresentation,
            encapsulatedKey: sender.encapsulatedKey, sealedKey: sealed)
    }

    static func unwrap(_ wrapped: WrappedKey, context: LAContext?) throws -> KeyBytes {
        let recipient: HPKE.Recipient
        do {
            let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: wrapped.enclaveKey, authenticationContext: context)
            recipient = try HPKE.Recipient(
                privateKey: enclaveKey, ciphersuite: suite, info: info(wrapped.protection),
                encapsulatedKey: wrapped.encapsulatedKey)
        } catch {
            throw StoreError.enclaveRefused(reason: "\(error)")
        }
        var opener = recipient
        var opened: Data
        do {
            opened = try opener.open(wrapped.sealedKey)
        } catch {
            throw StoreError.wrongKey
        }
        defer { wipe(&opened) }
        guard opened.count == keyLength else { throw StoreError.wrongKey }
        let key = KeyBytes(count: keyLength)
        _ = opened.copyBytes(to: key.bytes)
        return key
    }

    /// Puts the wrapped key in place by a link, which never replaces a key that another
    /// opener put there first: every opener then unwraps the one key the file holds.
    static func write(_ wrapped: WrappedKey, to file: URL) throws {
        let staging = file.appendingPathExtension(UUID().uuidString)
        let descriptor = open(staging.path, O_WRONLY | O_CREAT | O_EXCL, ClientStore.fileMode)
        guard descriptor >= 0 else { throw StoreError.system(path: staging.path, errno: errno) }
        defer { unlink(staging.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: JSONEncoder().encode(wrapped))
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else { throw StoreError.system(path: staging.path, errno: errno) }
        try handle.close()
        guard link(staging.path, file.path) == 0 || errno == EEXIST else {
            throw StoreError.system(path: file.path, errno: errno)
        }
        try ClientStore.fullSync(file.deletingLastPathComponent())
    }

    static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    }

    // MARK: Memory

    /// Bytes that stay out of swap where the system allows it and are overwritten when
    /// dropped.
    final class KeyBytes: @unchecked Sendable {
        let bytes: UnsafeMutableBufferPointer<UInt8>

        init(count: Int) {
            bytes = .allocate(capacity: count)
            bytes.initialize(repeating: 0)
            mlock(bytes.baseAddress, count)
        }

        func wipe() {
            memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
        }

        deinit {
            wipe()
            munlock(bytes.baseAddress, bytes.count)
            bytes.deallocate()
        }
    }

    enum Entry {
        case open(KeyBytes, StoreProtection)
        case locked
    }

    final class Registry: @unchecked Sendable {
        private let guardLock = NSLock()
        private var entries: [String: Entry] = [:]

        func get(_ directory: URL) -> Entry? {
            guardLock.withLock { entries[canonical(directory)] }
        }

        /// Returns the entry it replaced.
        @discardableResult
        func set(_ directory: URL, _ entry: Entry) -> Entry? {
            guardLock.withLock { entries.updateValue(entry, forKey: canonical(directory)) }
        }
    }

    static let registry = Registry()
    /// One Secure Enclave operation at a time: parallel ones from one process were seen to
    /// stall in CryptoTokenKit.
    static let enclave = NSLock()

    static func canonical(_ directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
