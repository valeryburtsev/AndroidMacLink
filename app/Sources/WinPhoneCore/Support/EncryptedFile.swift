import CryptoKit
import Foundation

/// Somewhere to keep a blob between launches.
public protocol BlobCache: Sendable {
    func load() -> Data?
    func save(_ data: Data)
    func clear()
}

/// A file sealed with ChaCha20-Poly1305. The key is kept elsewhere, in the Keychain, so the
/// file alone reveals nothing and a file that was tampered with is rejected.
public struct EncryptedFile: BlobCache {
    public var url: URL
    private let key: SymmetricKey

    /// - Parameter key: 32 bytes.
    public init(url: URL, key: Data) {
        self.url = url
        self.key = SymmetricKey(data: key)
    }

    public func load() -> Data? {
        guard let sealed = try? Data(contentsOf: url), let box = try? ChaChaPoly.SealedBox(combined: sealed) else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }

    public func save(_ data: Data) {
        guard let sealed = try? ChaChaPoly.seal(data, using: key).combined else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? sealed.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Keeps a blob in memory. For tests.
public final class MemoryBlobCache: BlobCache, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    public private(set) var saveCount = 0

    public init(_ data: Data? = nil) { self.data = data }
    public func load() -> Data? { lock.withLock { data } }
    public func save(_ data: Data) { lock.withLock { self.data = data; saveCount += 1 } }
    public func clear() { lock.withLock { data = nil } }
}
