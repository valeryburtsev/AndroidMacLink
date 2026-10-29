import CryptoKit
import Foundation

/// Keeps one client role (Phone Link or Cross Device) registered with DCG: creates and signs in
/// its device identity, enrolls it with the account, keeps the trust relationships in step with
/// the account's device list, and sends wake pushes to a phone.
///
/// The sequence and the retry rules follow `protocol/specs/identity-enrollment-trust.md`.
public actor IdentityService {
    public enum IdentityError: Error, Equatable {
        /// The service kept refusing a new device ID.
        case identityCreationFailed
        /// The account certificate in the enrollment response could not be parsed.
        case accountCertificateInvalid
        /// No trust relationship exists with the peer, so no wake token can be produced.
        case peerNotTrusted(String)
        case notEnrolled
    }

    public struct Timing: Sendable {
        /// Tokens are renewed this long before they expire.
        public var tokenLeeway: TimeInterval = 10 * 60
        /// An identity unused for this long is replaced instead of signed in.
        public var identityLifetime: TimeInterval = 180 * 86400
        /// The trust certificate is replaced once less than this remains of its validity.
        public var trustRotationBeforeExpiry: TimeInterval = 182 * 86400
        /// The identity's key is replaced once the service says no more days than this remain
        /// of its certificate: half its year, as Phone Link has it.
        public var keyRotationRemainingDays = 182
        /// After a try that failed, the next is not before this.
        public var keyRotationRetry: TimeInterval = 86400
        /// A key made for a replacement that may or may not have gone through is kept this
        /// long while the old one still signs in.
        public var pendingKeyLifetime: TimeInterval = 2 * 86400
        public var createRetries = 3
        public var nonceRetries = 3
        public init() {}
    }

    public nonisolated let profile: ClientProfile
    public nonisolated let clientType: String
    private let client: DCGClient
    private let account: AccountSession
    private let vault: StateVault
    private let displayName: String
    private let timing: Timing
    private let now: @Sendable () -> Date
    private var token: (value: String, expires: Date)?

    public init(profile: ClientProfile, client: DCGClient, account: AccountSession, vault: StateVault, displayName: String,
                timing: Timing = Timing(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.profile = profile
        clientType = profile.clientType
        self.client = client
        self.account = account
        self.vault = vault
        self.displayName = displayName
        self.timing = timing
        self.now = now
    }

    // MARK: State

    public var identity: RoleIdentity? {
        get async { await vault.state.roles[clientType] }
    }

    public var deviceId: String? {
        get async { await identity?.deviceId }
    }

    public var isEnrolled: Bool {
        get async { await identity?.enrolledAt != nil }
    }

    // MARK: Tokens

    /// A current DCG access token, signing in or creating the identity as needed.
    public func dcgToken() async throws -> String {
        if let token, token.expires.timeIntervalSince(now()) > timing.tokenLeeway { return token.value }
        return try await signIn()
    }

    /// The sign-in under way, shared by everyone who asks meanwhile: two at once could each
    /// offer the service a new key, and only one of them would learn which it took.
    private var signingIn: Task<String, Error>?

    /// Forces a new sign-in, for example after the relay answered 401.
    @discardableResult
    public func signIn() async throws -> String {
        if let signingIn { return try await signingIn.value }
        let task = Task { try await self.signInAlone() }
        signingIn = task
        defer { signingIn = nil }
        return try await task.value
    }

    private func signInAlone() async throws -> String {
        token = nil
        try await discoverEnvironmentIfNeeded()
        let msa = try await account.token()
        if let existing = await identity, now().timeIntervalSince(existing.lastAccessed) < timing.identityLifetime {
            do {
                return try await signIn(existing, msa: msa)
            } catch let error as DCGError where error.isRefusalOfTheKey {
                // A replacement of the key whose answer was lost may have gone through: the
                // service then knows the key that was made for it, and no longer this one.
                // How it turns the old key down was never seen, so any refusal leads here.
                if existing.pendingIdentityKey != nil, let token = try await signInWithPendingKey(msa: msa) { return token }
                guard error.isDeviceUnlinked || error.isInvalidCertificate else { throw error }
                try await forgetIdentity()
            }
        }
        return try await createIdentity(msa: msa)
    }

    private func signIn(_ existing: RoleIdentity, msa: String) async throws -> String {
        let certificate = try existing.identitySigner()
        let response = try await withNonceRetries(deviceId: existing.deviceId, msa: msa) { jwt in
            try await client.signIn(certificateJWT: jwt, msaToken: msa)
        } certificate: { certificate }
        guard response.deviceId == existing.deviceId else { throw IdentityError.identityCreationFailed }
        try await vault.update { state in
            state.roles[clientType]?.lastAccessed = now()
            state.roles[clientType]?.keyValidRemainingDays = response.keyValidRemainingDays
            // The old key still signs in long after a replacement was tried: it did not go through.
            if let since = state.roles[clientType]?.pendingIdentitySince, now().timeIntervalSince(since) > timing.pendingKeyLifetime {
                state.roles[clientType]?.dropPendingIdentity()
            }
        }
        let token = remember(response)
        await rotateKeysIfDue(msa: msa)
        return token
    }

    /// Signs in with the key that was made for a replacement, and keeps it if the service
    /// knows it.
    private func signInWithPendingKey(msa: String) async throws -> String? {
        guard var role = await identity, role.pendingIdentityKey != nil else { return nil }
        role.promotePendingIdentity()
        let certificate = try role.identitySigner()
        do {
            let response = try await withNonceRetries(deviceId: role.deviceId, msa: msa) { jwt in
                try await client.signIn(certificateJWT: jwt, msaToken: msa)
            } certificate: { certificate }
            guard response.deviceId == role.deviceId else { return nil }
            diag("identity", "the service knows the replacement key; keeping it")
            try await vault.update { state in
                state.roles[clientType]?.promotePendingIdentity()
                state.roles[clientType]?.lastAccessed = now()
                state.roles[clientType]?.keyValidRemainingDays = response.keyValidRemainingDays
                state.roles[clientType]?.nextKeyRotationCheck = nil
            }
            return remember(response)
        } catch let error as DCGError where error.isDeviceUnlinked || error.isInvalidCertificate {
            // Only these say that the service does not know this key either. Anything else
            // (a throttle, an outage with an error body) is no verdict, and is passed on
            // with the identity left as it is.
            return nil
        }
    }

    // MARK: Replacing the identity's key

    /// Whether the identity's key is due for replacement: by the days the service gave at
    /// sign-in, or, where it gave none, by the certificate's own dates.
    static func keyRotationDue(_ role: RoleIdentity, timing: Timing, now: Date) -> Bool {
        if let next = role.nextKeyRotationCheck, now < next { return false }
        if let days = role.keyValidRemainingDays, days >= 0 { return days <= timing.keyRotationRemainingDays }
        guard let notAfter = try? DeviceCertificate.inspect(der: role.identityCertificate).notAfter else { return false }
        return notAfter.timeIntervalSince(now) <= TimeInterval(timing.keyRotationRemainingDays) * 86400
    }

    /// Replaces the key after a sign-in when it is due. A failure leaves the identity as it
    /// was and never fails the sign-in; the next try is a day later.
    private func rotateKeysIfDue(msa: String) async {
        guard let role = await identity, IdentityService.keyRotationDue(role, timing: timing, now: now()) else { return }
        diag("identity", "the identity's key is due for replacement")
        // A key from a try whose outcome stayed open is offered again: there is never more
        // than one candidate beside the key in use.
        let candidate: DeviceCertificate
        do {
            if let waiting = try role.pendingIdentitySigner() {
                candidate = waiting
            } else {
                candidate = try DeviceCertificate.generate(commonName: role.deviceId, now: now())
                // Kept before the service is asked. If it cannot be kept, the service is not asked.
                do {
                    try await vault.update { state in
                        state.roles[clientType]?.pendingIdentityKey = candidate.privateKey.rawRepresentation
                        state.roles[clientType]?.pendingIdentityCertificate = candidate.der
                        state.roles[clientType]?.pendingIdentitySince = now()
                    }
                } catch {
                    try? await vault.update { $0.roles[clientType]?.dropPendingIdentity() }
                    throw error
                }
            }
            try await rotateKeys(role, to: candidate, msa: msa)
        } catch {
            // A plain refusal means the service kept the old key; anything else leaves it open.
            var refused = false
            if case DCGError.service(let status, _, _, _) = error, (400..<500).contains(status) { refused = true }
            diag("identity", "replacing the identity's key failed\(refused ? ": refused" : ""); trying again later")
            try? await vault.update { state in
                state.roles[clientType]?.nextKeyRotationCheck = now().addingTimeInterval(timing.keyRotationRetry)
                if refused { state.roles[clientType]?.dropPendingIdentity() }
            }
            return
        }
        diag("identity", "the identity's key was replaced")
    }

    /// `/Auth/RotateKeys`: one nonce, proved with the key the service knows and with a new one
    /// for the same device ID (`protocol/specs/identity-enrollment-trust.md` 8.4).
    private func rotateKeys(_ role: RoleIdentity, to new: DeviceCertificate, msa: String) async throws {
        let old = try role.identitySigner()
        var attempt = 0
        while true {
            let nonce = try await client.generateNonce(deviceId: role.deviceId, msaToken: msa)
            let oldProof = try DeviceTokens.nonceJWT(nonce: nonce.nonce, identity: old, now: now())
            let newProof = try DeviceTokens.nonceJWT(nonce: nonce.nonce, identity: new, now: now())
            do {
                try await client.rotateKeys(newCertificateJWT: newProof, oldCertificateJWT: oldProof, msaToken: msa)
                break
            } catch let error as DCGError where error.isInvalidNonce && attempt < timing.nonceRetries {
                attempt += 1
            }
        }
        // The service took this very key: it is the identity's now, whatever else is kept.
        // Should the write fail, the key stays in memory and on disk as the waiting one,
        // and the next sign-in finds its way to it.
        try? await vault.update { state in
            state.roles[clientType]?.identityKey = new.privateKey.rawRepresentation
            state.roles[clientType]?.identityCertificate = new.der
            state.roles[clientType]?.dropPendingIdentity()
            // How long the new key lasts is told at the next sign-in.
            state.roles[clientType]?.keyValidRemainingDays = nil
            state.roles[clientType]?.nextKeyRotationCheck = nil
        }
    }

    private func createIdentity(msa: String) async throws -> String {
        for _ in 0...timing.createRetries {
            let deviceId = UUID().uuidString.lowercased()
            let certificate = try DeviceCertificate.generate(commonName: deviceId, now: now())
            do {
                let response = try await withNonceRetries(deviceId: deviceId, msa: msa) { jwt in
                    try await client.createIdentity(certificateJWT: jwt, msaToken: msa)
                } certificate: { certificate }
                var role = RoleIdentity(deviceId: response.deviceId, identityKey: certificate.privateKey.rawRepresentation,
                                        identityCertificate: certificate.der, createdAt: now())
                role.keyValidRemainingDays = response.keyValidRemainingDays
                try await vault.update { state in
                    state.removeRole(clientType)
                    state.roles[clientType] = role
                }
                return remember(response)
            } catch let error as DCGError {
                // A 403 of another category means the service already knows this ID. Try another.
                if case .service(403, _, _, let category) = error, category != 7, category != 13 { continue }
                throw error
            }
        }
        throw IdentityError.identityCreationFailed
    }

    /// Runs the nonce and proof exchange, retrying when the service rejects the nonce.
    private func withNonceRetries(deviceId: String, msa: String,
                                  _ call: (String) async throws -> IdentityResponse,
                                  certificate: () -> DeviceCertificate) async throws -> IdentityResponse {
        var attempt = 0
        while true {
            let nonce = try await client.generateNonce(deviceId: deviceId, msaToken: msa)
            let jwt = try DeviceTokens.nonceJWT(nonce: nonce.nonce, identity: certificate(), now: now())
            do {
                return try await call(jwt)
            } catch let error as DCGError where error.isInvalidNonce && attempt < timing.nonceRetries {
                attempt += 1
            }
        }
    }

    private func remember(_ response: IdentityResponse) -> String {
        let expires = response.epochExpirationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? now().addingTimeInterval(86400)
        token = (response.accessToken, expires)
        return response.accessToken
    }

    private func discoverEnvironmentIfNeeded() async throws {
        guard await vault.state.serviceEnvironment == nil else { return }
        let environment = try await client.serviceEnvironment(msaToken: try await account.token())
        try await vault.update { $0.serviceEnvironment = environment.serviceEnvironment }
    }

    // MARK: Enrollment

    /// Makes sure the role is enrolled with the account and its trust is current. Safe to call
    /// on every start; it only talks to the service when something is missing or stale.
    @discardableResult
    public func ensureReady() async throws -> [PeerDevice] {
        _ = try await dcgToken()
        try await enrollIfNeeded()
        return try await syncPeers()
    }

    public func enrollIfNeeded() async throws {
        let metadata = DeviceMetadata(profile: profile, displayName: displayName)
        let hash = IdentityService.hash(metadata)
        if let identity = await identity, identity.enrolledMetadataHash == hash, identity.enrolledAt != nil,
           try identity.trustSigner() != nil { return }
        try await enroll()
    }

    /// Uploads the trust certificate and metadata, then stores the account certificate.
    public func enroll() async throws {
        let dcg = try await dcgToken()
        guard let identity = await identity else { throw IdentityError.notEnrolled }
        let trust = try currentOrNewTrustCertificate(identity)
        let metadata = DeviceMetadata(profile: profile, displayName: displayName)
        let request = EnrollDeviceRequest(certificates: ["SelfSigned": [trust.certificate.base64]], metadata: metadata)
        let response: EnrollDeviceResponse
        do {
            response = try await client.enrollDevice(request, msaToken: try await account.token(), dcgToken: dcg)
        } catch let error as DCGError where error.isDeviceUnlinked {
            try await forgetIdentity()
            throw error
        }
        try await vault.update { state in
            if trust.isNew {
                state.roles[clientType]?.trustKey = trust.certificate.privateKey.rawRepresentation
                state.roles[clientType]?.trustCertificate = trust.certificate.der
            }
            state.roles[clientType]?.enrolledMetadataHash = IdentityService.hash(metadata)
            state.roles[clientType]?.enrolledAt = now()
            if let name = response.accountInfo?.signInName, !name.isEmpty { state.accountName = name }
        }
        try await trustAccount(certificateBase64: response.accountCert, selfClientId: identity.trustClientId)
        if let devices = response.devices { try await syncRelationships(devices, selfClientId: identity.trustClientId) }
    }

    private func currentOrNewTrustCertificate(_ identity: RoleIdentity) throws -> (certificate: DeviceCertificate, isNew: Bool) {
        if let existing = try identity.trustSigner() {
            let notAfter = try DeviceCertificate.inspect(der: existing.der).notAfter ?? .distantPast
            if notAfter.timeIntervalSince(now()) > timing.trustRotationBeforeExpiry { return (existing, false) }
        }
        return (try DeviceCertificate.generate(commonName: identity.trustClientId, now: now()), true)
    }

    static func hash(_ metadata: DeviceMetadata) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(metadata)) ?? Data()
        return Data(SHA256.hash(data: data)).base64EncodedString()
    }

    // MARK: Trust

    /// Refreshes the device list, updates the relationships and the peer cache, and returns the
    /// linked phones.
    @discardableResult
    public func syncPeers() async throws -> [PeerDevice] {
        guard let identity = await identity else { throw IdentityError.notEnrolled }
        let msa = try await account.token()
        let devices: [DeviceInfo]
        do {
            devices = try await client.deviceInfoList(msaToken: msa)
        } catch let error as DCGError where error.isDeviceUnlinked {
            try await forgetIdentity()
            throw error
        }
        try await syncRelationships(devices, selfClientId: identity.trustClientId)
        let accountCert = try await client.accountCert(msaToken: msa)
        try await trustAccount(certificateBase64: accountCert.accountCert, selfClientId: identity.trustClientId)
        return await vault.state.peers.filter(\.isPhone)
    }

    private func trustAccount(certificateBase64: String, selfClientId: String) async throws {
        guard let der = Data(base64Encoded: certificateBase64, options: .ignoreUnknownCharacters),
              let name = try? DeviceCertificate.inspect(der: der).commonName else { throw IdentityError.accountCertificateInvalid }
        try await vault.update { state in
            IdentityService.trust(&state, selfClientId: selfClientId, partnerDcgClientId: name, certificate: der, kind: .account, now: now())
        }
    }

    /// Applies the device list: one `AsyncD2D` relationship per linked peer, stale ones removed.
    private func syncRelationships(_ devices: [DeviceInfo], selfClientId: String) async throws {
        let ownIds = Set(await vault.state.roles.values.map(\.deviceId))
        let candidates = devices.filter { $0.isLinked == true && !ownIds.contains($0.id) }
        let candidateIds = Set(candidates.map { "trust_" + $0.id })
        try await vault.update { state in
            state.trust.removeAll { $0.selfClientId == selfClientId && $0.kind == .asyncDevice && !candidateIds.contains($0.partnerClientId) }
            for device in candidates {
                guard let certificate = device.preferredCertificate else { continue }
                IdentityService.trust(&state, selfClientId: selfClientId, partnerDcgClientId: device.id, certificate: certificate,
                                      kind: .asyncDevice, now: now())
            }
            state.peers = devices.filter { !ownIds.contains($0.id) }.map(PeerDevice.init)
        }
    }

    static func trust(_ state: inout PersistedState, selfClientId: String, partnerDcgClientId: String, certificate: Data,
                      kind: TrustRelationship.Kind, now: Date) {
        let partnerClientId = "trust_" + partnerDcgClientId
        let notAfter = (try? DeviceCertificate.inspect(der: certificate).notAfter) ?? now.addingTimeInterval(365 * 86400)
        let keyExpires = min(notAfter, now.addingTimeInterval(365 * 86400))
        if var existing = state.relationship(selfClientId: selfClientId, partnerClientId: partnerClientId) {
            if existing.partnerCertificate != certificate {
                existing.previousCertificate = existing.partnerCertificate
                existing.previousCertificateExpires = now.addingTimeInterval(TrustRelationship.previousCertificateLifetime)
                existing.partnerCertificate = certificate
                existing.keyExpires = keyExpires
            }
            existing.lastAccess = now
            if existing.kind == .unknown { existing.kind = kind }
            state.upsert(existing)
        } else {
            state.upsert(TrustRelationship(selfClientId: selfClientId, partnerClientId: partnerClientId, partnerDcgClientId: partnerDcgClientId,
                                           partnerCertificate: certificate, kind: kind, addedAt: now, keyExpires: keyExpires, lastAccess: now))
        }
    }

    /// The certificate a peer signs with, for verifying what it sends us.
    public func peerCertificate(_ peerDcgClientId: String) async -> Data? {
        guard let identity = await identity else { return nil }
        return await vault.state.relationship(selfClientId: identity.trustClientId, partnerClientId: "trust_" + peerDcgClientId)?.partnerCertificate
    }

    // MARK: The phone's hotspot

    /// A request to the phone's hotspot service, signed with this role's trust key, with the
    /// phone's certificate to check the answer by.
    public func hotspotExchange(peer: String, kind: HotspotExchange.Kind) async throws -> HotspotExchange {
        guard let identity = await identity, let trust = try identity.trustSigner() else { throw IdentityError.notEnrolled }
        guard let certificate = await peerCertificate(peer) else { throw IdentityError.peerNotTrusted(peer) }
        return try HotspotExchange(kind: kind, ownId: identity.deviceId, trust: trust, phoneCertificate: certificate, now: now())
    }

    // MARK: Wake

    /// Builds and sends the signed wake push for a phone.
    public func wake(peer: String, hubRegion: String?, highPriority: Bool, requestNewSession: Bool = true) async throws {
        guard let identity = await identity, let trust = try identity.trustSigner() else { throw IdentityError.notEnrolled }
        guard await vault.state.relationship(selfClientId: identity.trustClientId, partnerClientId: "trust_" + peer) != nil else {
            throw IdentityError.peerNotTrusted(peer)
        }
        let request = try DeviceTokens.wakeRequest(targetDeviceId: peer, sourceDeviceId: identity.deviceId, hubRegion: hubRegion, trust: trust,
                                                   requestNewSession: requestNewSession, highPriority: highPriority, now: now())
        try await client.wake(request, dcgToken: try await dcgToken(),
                              trace: TraceContext(scenarioId: "connectApi", triggerId: highPriority ? "WakeRetry" : "StartSession"))
    }

    // MARK: Unlinking

    /// Unlinks a phone from the account. The service then drops every device of the account,
    /// so our own identities are forgotten too and recreated on the next `ensureReady`.
    public func unlink(peer: String) async throws {
        try await client.unlinkDevice(deviceId: peer, msaToken: try await account.token(), dcgToken: try await dcgToken())
        try await vault.update { state in
            for role in Array(state.roles.keys) { state.removeRole(role) }
            state.peers.removeAll { $0.id == peer }
        }
        token = nil
    }

    /// Drops this role's identity after the service reported it unlinked.
    public func forgetIdentity() async throws {
        token = nil
        try await vault.update { $0.removeRole(clientType) }
    }
}

public extension DCGError {
    /// `/Auth` rejected the nonce; the exchange may be retried.
    var isInvalidNonce: Bool {
        if case .service(400, let code, _, _) = self { return code == "InvalidNonce" }
        return false
    }

    /// `/Auth` rejected the certificate; the identity must be created again.
    var isInvalidCertificate: Bool {
        if case .service(400, let code, _, _) = self { return code == "InvalidCertificate" }
        return false
    }

    /// The service turned the proof down for what it is, not for a stale nonce or account
    /// token: the device is unlinked, the certificate unknown, or some other plain refusal.
    var isRefusalOfTheKey: Bool {
        if isInvalidNonce || isUnauthorized { return false }
        if case .service(let status, _, _, _) = self { return (400..<500).contains(status) }
        return false
    }

    /// The credentials were refused. For an MSA-authenticated call, the account token is stale.
    var isUnauthorized: Bool {
        if case .service(401, _, _, _) = self { return true }
        if case .http(401) = self { return true }
        return false
    }
}
