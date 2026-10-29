import CryptoKit
import Foundation
import Security

// Everything the app must remember between runs: the account's refresh token, one DCG identity
// per client role, the trust relationships derived from the account's device list, and a cache
// of the linked phones. It is one JSON document kept in one Keychain item, so a save is atomic
// and nothing about the account ends up in plain files.

/// A DCG identity for one client role: the device ID, the identity key and certificate used
/// with `/Auth`, and the trust key and certificate enrolled with the account.
public struct RoleIdentity: Codable, Equatable, Sendable {
    public var deviceId: String
    /// Raw P-384 private key bytes.
    public var identityKey: Data
    /// DER certificate `CN=<deviceId>`.
    public var identityCertificate: Data
    public var trustKey: Data?
    /// DER certificate `CN=trust_<deviceId>`.
    public var trustCertificate: Data?
    public var createdAt: Date
    public var lastAccessed: Date
    public var keyValidRemainingDays: Int?
    /// A key and certificate made to replace the identity's, kept from before the service is
    /// asked to take them until it is certain which of the two it holds: an answer that never
    /// arrives leaves that open.
    public var pendingIdentityKey: Data?
    public var pendingIdentityCertificate: Data?
    public var pendingIdentitySince: Date?
    /// Replacing the key is not tried again before this.
    public var nextKeyRotationCheck: Date?
    /// Hash of the metadata sent at the last successful enrollment, nil when never enrolled.
    public var enrolledMetadataHash: String?
    public var enrolledAt: Date?

    public init(deviceId: String, identityKey: Data, identityCertificate: Data, createdAt: Date) {
        self.deviceId = deviceId
        self.identityKey = identityKey
        self.identityCertificate = identityCertificate
        self.createdAt = createdAt
        lastAccessed = createdAt
    }

    public var trustClientId: String { "trust_" + deviceId }

    /// The identity key and certificate, ready to sign with.
    public func identitySigner() throws -> DeviceCertificate {
        DeviceCertificate(privateKey: try P384.Signing.PrivateKey(rawRepresentation: identityKey), der: identityCertificate, commonName: deviceId)
    }

    /// The key made to replace the identity's, where one is waiting.
    public func pendingIdentitySigner() throws -> DeviceCertificate? {
        guard let pendingIdentityKey, let pendingIdentityCertificate else { return nil }
        return DeviceCertificate(privateKey: try P384.Signing.PrivateKey(rawRepresentation: pendingIdentityKey), der: pendingIdentityCertificate, commonName: deviceId)
    }

    /// Makes the waiting key the identity's.
    public mutating func promotePendingIdentity() {
        guard let pendingIdentityKey, let pendingIdentityCertificate else { return }
        identityKey = pendingIdentityKey
        identityCertificate = pendingIdentityCertificate
        dropPendingIdentity()
    }

    public mutating func dropPendingIdentity() {
        pendingIdentityKey = nil
        pendingIdentityCertificate = nil
        pendingIdentitySince = nil
    }

    /// The trust key and certificate, or nil before enrollment.
    public func trustSigner() throws -> DeviceCertificate? {
        guard let trustKey, let trustCertificate else { return nil }
        return DeviceCertificate(privateKey: try P384.Signing.PrivateKey(rawRepresentation: trustKey), der: trustCertificate, commonName: trustClientId)
    }
}

/// Trust in one partner certificate, as Phone Link stores it: the account (type 4, `A2D`) or
/// a linked device (type 3, `AsyncD2D`), always derived from the account's device list.
public struct TrustRelationship: Codable, Equatable, Sendable {
    public enum Kind: Int, Codable, Sendable {
        case unknown = 0, classicPairing = 1, accountPairing = 2, asyncDevice = 3, account = 4
    }

    /// `trust_<own device id>`: which of our roles holds this relationship.
    public var selfClientId: String
    /// `trust_<partner dcg id>`.
    public var partnerClientId: String
    public var partnerDcgClientId: String
    public var partnerCertificate: Data
    /// The previous certificate, kept for ten minutes after a rotation.
    public var previousCertificate: Data?
    public var previousCertificateExpires: Date?
    public var kind: Kind
    public var addedAt: Date
    public var keyExpires: Date
    public var lastAccess: Date

    /// Rotation grace period for the previous partner certificate.
    public static let previousCertificateLifetime: TimeInterval = 10 * 60
    /// A relationship unused for this long is dropped.
    public static let idleLifetime: TimeInterval = 180 * 86400

    public func isValid(at now: Date) -> Bool {
        keyExpires > now && lastAccess.addingTimeInterval(TrustRelationship.idleLifetime) > now
    }
}

/// A device of the account, as cached from the device list.
public struct PeerDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var osName: String
    public var osVersion: String
    public var manufacture: String
    public var modelName: String
    public var clientType: String
    public var capabilities: [String]
    public var yppCapabilities: Int?
    public var isLinked: Bool
    public var lastSeen: Date?

    public init(_ info: DeviceInfo) {
        id = info.id
        name = info.name ?? ""
        osName = info.osName ?? ""
        osVersion = info.osVersion ?? ""
        manufacture = info.manufacture ?? "Unknown"
        modelName = info.modelName ?? "Unknown"
        clientType = info.clientType ?? ""
        capabilities = info.capabilities ?? []
        yppCapabilities = info.yppCapabilities
        isLinked = info.isLinked ?? false
        lastSeen = info.lastSeenTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public var isPhone: Bool { osName.caseInsensitiveCompare("Android") == .orderedSame }
    public var supportsAsyncTrust: Bool { osName.caseInsensitiveCompare("iOS") == .orderedSame || ((yppCapabilities ?? 0) & 0x20) != 0 }
    public var supportsIntentionalDisconnect: Bool { ((yppCapabilities ?? 0) & 0x40) != 0 }
}

/// The whole persisted document.
public struct PersistedState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = PersistedState.currentVersion
    /// 32 random bytes; `DCG-LogicalDeviceId` is derived from them.
    public var logicalDeviceSeed: Data
    /// Upper-case GUID sent as `installationId` in APP messages.
    public var installationId: String
    /// OAuth refresh token of the signed-in Microsoft account.
    public var refreshToken: String?
    /// The account's sign-in name, for display only.
    public var accountName: String?
    /// `Production` or `Beta`, from environment discovery.
    public var serviceEnvironment: String?
    /// Identities keyed by client type (`PL`, `WEA`).
    public var roles: [String: RoleIdentity] = [:]
    public var trust: [TrustRelationship] = []
    public var peers: [PeerDevice] = []
    /// The phone the user chose, if more than one is linked.
    public var selectedPeerId: String?
    /// Key for the encrypted cache of messages. Dropped at sign-out, which makes any cache
    /// file left behind unreadable.
    public var cacheKey: Data?

    public init(logicalDeviceSeed: Data = Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
                installationId: String = UUID().uuidString) {
        self.logicalDeviceSeed = logicalDeviceSeed
        self.installationId = installationId
    }

    public var isSignedIn: Bool { refreshToken != nil }

    public func relationship(selfClientId: String, partnerClientId: String) -> TrustRelationship? {
        trust.first { $0.selfClientId == selfClientId && $0.partnerClientId == partnerClientId }
    }

    public mutating func upsert(_ relationship: TrustRelationship) {
        trust.removeAll { $0.selfClientId == relationship.selfClientId && $0.partnerClientId == relationship.partnerClientId }
        trust.append(relationship)
    }

    /// Forgets a role's identity and every relationship it held. Used after `DeviceUnlinked`.
    public mutating func removeRole(_ clientType: String) {
        guard let role = roles.removeValue(forKey: clientType) else { return }
        trust.removeAll { $0.selfClientId == role.trustClientId }
    }

    /// Forgets everything about the account but keeps the installation identifiers.
    public mutating func signOut() {
        refreshToken = nil
        accountName = nil
        serviceEnvironment = nil
        roles = [:]
        trust = []
        peers = []
        selectedPeerId = nil
        cacheKey = nil
    }
}

/// Where the document is kept.
public protocol StateStore: Sendable {
    func load() throws -> PersistedState?
    func save(_ state: PersistedState) throws
    func clear() throws
}

public enum StateStoreError: Error, Equatable {
    case keychain(OSStatus)
    case corrupt
}

extension PersistedState {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public func encoded() throws -> Data { try PersistedState.encoder.encode(self) }
    public init(decoding data: Data) throws { self = try PersistedState.decoder.decode(PersistedState.self, from: data) }
}

/// One generic-password item in the user's login keychain.
public struct KeychainStateStore: StateStore {
    public var service: String
    public var account: String

    public init(service: String = "com.winphone.app", account: String = "state") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> PersistedState? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StateStoreError.keychain(status) }
        guard let data = result as? Data else { throw StateStoreError.corrupt }
        do { return try PersistedState(decoding: data) } catch { throw StateStoreError.corrupt }
    }

    static let label = "Phone Mac Link account and device identity"

    public func save(_ state: PersistedState) throws {
        let data = try state.encoded()
        // The name the item shows under in Keychain Access goes along, so that one made
        // under the app's working name takes the present one.
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: KeychainStateStore.label]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        // The name is a nicety: where the keychain will not take it, the state alone is saved.
        if status != errSecSuccess, status != errSecItemNotFound {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = KeychainStateStore.label
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw StateStoreError.keychain(status) }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StateStoreError.keychain(status) }
    }
}

/// A JSON file readable only by the owner. For the command-line probe and tests.
public struct FileStateStore: StateStore {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> PersistedState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { return try PersistedState(decoding: try Data(contentsOf: url)) } catch { throw StateStoreError.corrupt }
    }

    public func save(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try state.encoded().write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

/// Keeps the document in memory only.
public final class MemoryStateStore: StateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PersistedState?
    public private(set) var saveCount = 0

    public init(_ state: PersistedState? = nil) { self.state = state }

    public func load() throws -> PersistedState? { lock.withLock { state } }
    public func save(_ state: PersistedState) throws { lock.withLock { self.state = state; saveCount += 1 } }
    public func clear() throws { lock.withLock { state = nil } }
}

/// The in-memory copy of the document, written through to the store on every change.
public actor StateVault {
    private let store: StateStore
    public private(set) var state: PersistedState
    /// `DCG-SessionId`: one per run of the app.
    public nonisolated let sessionId = UUID().uuidString.lowercased()

    /// Loads the document, creating a fresh one on first run.
    public init(store: StateStore) throws {
        self.store = store
        if let loaded = try store.load() {
            state = loaded
        } else {
            state = PersistedState()
            try store.save(state)
        }
    }

    /// Changes the document and persists it. The change is kept in memory even if the write fails.
    @discardableResult
    public func update<T>(_ change: (inout PersistedState) throws -> T) throws -> T {
        let result = try change(&state)
        try store.save(state)
        return result
    }

    public func clear() throws {
        state = PersistedState(logicalDeviceSeed: state.logicalDeviceSeed, installationId: state.installationId)
        try store.save(state)
    }

    /// The key for the encrypted caches, created on first use.
    public func cacheKey() throws -> Data {
        if let key = state.cacheKey { return key }
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try update { $0.cacheKey = key }
        return key
    }

    public var clientInstance: ClientInstance {
        ClientInstance(logicalDeviceId: ClientInstance.logicalDeviceId(seed: state.logicalDeviceSeed), sessionId: sessionId)
    }
}
