import CryptoKit
import XCTest
@testable import WinPhoneCore

final class IdentityServiceTests: XCTestCase {
    struct Stack {
        let services = FakeServices()
        let store = MemoryStateStore()
        let vault: StateVault
        let account: AccountSession

        init(signedIn: Bool = true) throws {
            var state = PersistedState()
            if signedIn { state.refreshToken = "refresh-0" }
            try store.save(state)
            vault = try StateVault(store: store)
            account = AccountSession(account: MicrosoftAccount(transport: services), vault: vault)
            services.dcg.msaToken = "msa-token-r1"
        }

        func identity(_ profile: ClientProfile = .phoneLink) async -> IdentityService {
            let instance = await vault.clientInstance
            return IdentityService(profile: profile, client: DCGClient(profile: profile, instance: instance, transport: services),
                                   account: account, vault: vault, displayName: "Mac")
        }
    }

    func testFirstRunFollowsTheCapturedSequence() async throws {
        let stack = try Stack()
        let identity = await stack.identity()
        try await identity.ensureReady()

        XCTAssertEqual(stack.services.dcg.calls, [
            "GET /EnvironmentDiscovery/UserServiceEnvironment",
            "POST /Auth/GenerateNonce",
            "POST /Auth/CreateIdentity",
            "POST /DeviceAuthProxy/EnrollDevice",
            "GET /DeviceAuthProxy/GetDeviceInfoList",
            "GET /DeviceAuthProxy/GetAccountCert",
        ], "Register is skipped on purpose: there is no push channel")

        let state = await stack.vault.state
        let role = try XCTUnwrap(state.roles["PL"])
        XCTAssertEqual(role.deviceId.count, 36)
        XCTAssertNotNil(role.trustCertificate, "trust certificate persisted after a successful enrollment")
        XCTAssertNotNil(role.enrolledAt)
        XCTAssertEqual(state.serviceEnvironment, "Production")
        XCTAssertEqual(state.accountName, "user@example.com")
        XCTAssertEqual(state.peers.map(\.id), [FakeDCG.phoneId], "our own entry is not a peer")
        XCTAssertEqual(state.peers.first?.yppCapabilities, 127)
        XCTAssertTrue(state.peers.first?.supportsAsyncTrust ?? false)

        let kinds = Dictionary(uniqueKeysWithValues: state.trust.map { ($0.partnerClientId, $0.kind) })
        XCTAssertEqual(kinds, ["trust_" + FakeDCG.accountId: .account, "trust_" + FakeDCG.phoneId: .asyncDevice])
        XCTAssertTrue(state.trust.allSatisfy { $0.selfClientId == role.trustClientId })
        XCTAssertEqual(state.trust.first { $0.kind == .account }?.partnerCertificate, stack.services.dcg.accountCertificate.der)

        // The enrollment body carried our metadata and the trust certificate.
        let enrollment = try XCTUnwrap(stack.services.dcg.enrollments.first)
        let metadata = try XCTUnwrap(enrollment["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["clientType"] as? String, "PL")
        XCTAssertEqual(metadata["displayName"] as? String, "Mac")
        XCTAssertEqual(stack.store.saveCount > 3, true, "state is written through on every change")
    }

    func testLaterRunSignsInWithoutRecreatingOrEnrolling() async throws {
        let stack = try Stack()
        try await (await stack.identity()).ensureReady()
        stack.services.dcg.reset()

        // A new process: fresh service object, same vault.
        let again = await stack.identity()
        try await again.ensureReady()
        XCTAssertEqual(stack.services.dcg.calls, [
            "POST /Auth/GenerateNonce",
            "POST /Auth/SignIn",
            "GET /DeviceAuthProxy/GetDeviceInfoList",
            "GET /DeviceAuthProxy/GetAccountCert",
        ])
        // Tokens are cached in memory until shortly before expiry.
        stack.services.dcg.reset()
        _ = try await again.dcgToken()
        XCTAssertEqual(stack.services.dcg.calls, [])
    }

    func testUnlinkedIdentityIsRecreated() async throws {
        let stack = try Stack()
        let first = await stack.identity()
        try await first.ensureReady()
        let oldIdValue = await first.deviceId
        let oldId = try XCTUnwrap(oldIdValue)
        stack.services.dcg.reset()
        stack.services.dcg.unlinkedOnce = true

        let again = await stack.identity()
        try await again.ensureReady()
        XCTAssertEqual(stack.services.dcg.calls, [
            "POST /Auth/GenerateNonce",
            "POST /Auth/SignIn",
            "POST /Auth/GenerateNonce",
            "POST /Auth/CreateIdentity",
            "POST /DeviceAuthProxy/EnrollDevice",
            "GET /DeviceAuthProxy/GetDeviceInfoList",
            "GET /DeviceAuthProxy/GetAccountCert",
        ], "403/13 means: discard the identity and start from the first-run sequence")
        let newIdValue = await again.deviceId
        let newId = try XCTUnwrap(newIdValue)
        XCTAssertNotEqual(oldId, newId)
        let state = await stack.vault.state
        XCTAssertFalse(state.trust.contains { $0.selfClientId == "trust_" + oldId }, "old relationships are gone")
        XCTAssertTrue(state.trust.contains { $0.selfClientId == "trust_" + newId })
    }

    func testDeviceIdCollisionPicksAnotherId() async throws {
        let stack = try Stack()
        stack.services.dcg.collisions = 2
        try await (await stack.identity()).ensureReady()
        let creates = stack.services.dcg.calls.filter { $0 == "POST /Auth/CreateIdentity" }
        XCTAssertEqual(creates.count, 3)
        XCTAssertEqual(stack.services.dcg.knownDevices.count, 2, "phone plus exactly one registration of ours")
    }

    func testTwoRolesShareTheAccountAndHaveSeparateIdentities() async throws {
        let stack = try Stack()
        let pl = await stack.identity(.phoneLink)
        let wea = await stack.identity(.crossDevice)
        try await pl.ensureReady()
        try await wea.ensureReady()
        let state = await stack.vault.state
        XCTAssertEqual(Set(state.roles.keys), ["PL", "WEA"])
        XCTAssertNotEqual(state.roles["PL"]?.deviceId, state.roles["WEA"]?.deviceId)
        XCTAssertEqual(state.peers.map(\.id), [FakeDCG.phoneId], "neither of our own entries counts as a peer")
        XCTAssertEqual(state.trust.filter { $0.kind == .asyncDevice }.count, 2, "each role trusts the phone")
        let metadata = stack.services.dcg.enrollments.compactMap { ($0["metadata"] as? [String: Any])?["clientType"] as? String }
        XCTAssertEqual(Set(metadata), ["PL", "WEA"])
        XCTAssertTrue(stack.services.dcg.calls.filter { $0.hasSuffix("UserServiceEnvironment") }.count == 1, "discovery once per account")
    }

    func testWakeIsSignedWithTheTrustKeyAndAddressedToThePhone() async throws {
        let stack = try Stack()
        let identity = await stack.identity()
        try await identity.ensureReady()
        try await identity.wake(peer: FakeDCG.phoneId, hubRegion: "NorthEurope", highPriority: false)
        try await identity.wake(peer: FakeDCG.phoneId, hubRegion: nil, highPriority: true)

        let wakes = stack.services.dcg.wakes
        XCTAssertEqual(wakes.count, 2)
        XCTAssertEqual(wakes[0]["deviceId"] as? String, FakeDCG.phoneId)
        XCTAssertEqual(wakes[0]["collapseKey"] as? String, "YPPWake")
        XCTAssertEqual(wakes[0]["priority"] as? String, "normal")
        XCTAssertEqual(wakes[1]["priority"] as? String, "high")
        XCTAssertEqual(wakes[0]["ttl"] as? Int, 20)
        let data = try XCTUnwrap(wakes[0]["data"] as? [String: String])
        XCTAssertEqual(data["DCG-HubRegion"], "NorthEurope")
        XCTAssertNil((wakes[1]["data"] as? [String: String])?["DCG-HubRegion"])

        // The phone verifies the token with the certificate we enrolled.
        let roles = await stack.vault.state.roles
        let role = try XCTUnwrap(roles["PL"])
        let enrolledDer = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap((stack.services.dcg.enrollments[0]["certificates"] as? [String: [String]])?["SelfSigned"]?.first)))
        let key = try DeviceCertificate.inspect(der: enrolledDer).publicKey
        let verified = try XCTUnwrap(JWT.verifyES384(try XCTUnwrap(data["DCG-CryptoWakeJwt"]), key: key))
        XCTAssertEqual(verified.claims["iss"] as? String, role.trustClientId)
        XCTAssertEqual(verified.claims["SourceId"] as? String, role.deviceId)
        XCTAssertEqual(verified.claims["Scope"] as? String, "wake")
        let signed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data((verified.claims["Data"] as? String ?? "").utf8)) as? [String: String])
        XCTAssertEqual(signed, data.filter { $0.key != "DCG-CryptoWakeJwt" }, "the signed map equals the outer data map")

        do {
            try await identity.wake(peer: "unknown-peer", hubRegion: nil, highPriority: false)
            XCTFail("expected a refusal")
        } catch IdentityService.IdentityError.peerNotTrusted(let peer) {
            XCTAssertEqual(peer, "unknown-peer")
        }
    }

    func testEnrollmentRepeatsWhenMetadataChanges() async throws {
        let stack = try Stack()
        try await (await stack.identity()).ensureReady()
        stack.services.dcg.reset()
        let instance = await stack.vault.clientInstance
        var renamed = ClientProfile.phoneLink
        renamed.capabilities.append("SOMETHING_NEW")
        let changed = IdentityService(profile: renamed, client: DCGClient(profile: renamed, instance: instance, transport: stack.services),
                                      account: stack.account, vault: stack.vault, displayName: "Mac")
        try await changed.ensureReady()
        XCTAssertTrue(stack.services.dcg.calls.contains("POST /DeviceAuthProxy/EnrollDevice"))
    }

    func testUnlinkForgetsOurIdentities() async throws {
        let stack = try Stack()
        let identity = await stack.identity()
        try await identity.ensureReady()
        try await identity.unlink(peer: FakeDCG.phoneId)
        let state = await stack.vault.state
        XCTAssertTrue(state.roles.isEmpty)
        XCTAssertTrue(state.trust.isEmpty)
        XCTAssertTrue(state.isSignedIn, "the account stays signed in")
    }

    func testSignInRequiredWhenNoAccount() async throws {
        let stack = try Stack(signedIn: false)
        do {
            try await (await stack.identity()).ensureReady()
            XCTFail("expected an error")
        } catch AccountSession.AccountError.notSignedIn {}
        XCTAssertEqual(stack.services.dcg.calls, [])
    }
}

final class AccountSessionTests: XCTestCase {
    func testRefreshRotatesAndStoresTheRefreshToken() async throws {
        let services = FakeServices()
        let store = MemoryStateStore()
        var state = PersistedState()
        state.refreshToken = "refresh-0"
        try store.save(state)
        let vault = try StateVault(store: store)
        var clock = Date()
        let now: @Sendable () -> Date = { clock }
        let session = AccountSession(account: MicrosoftAccount(transport: services), vault: vault, now: now)

        let first = try await session.token()
        XCTAssertEqual(first, "msa-token-r1")
        XCTAssertEqual(services.msa.calls.last?["refresh_token"], "refresh-0")
        XCTAssertEqual(services.msa.calls.last?["scope"], MicrosoftAccount.scope)
        let stored = await vault.state.refreshToken
        XCTAssertEqual(stored, "refresh-1", "the rotated token replaces the old one")
        let cached = try await session.token()
        XCTAssertEqual(cached, "msa-token-r1", "cached")
        XCTAssertEqual(services.msa.refreshCount, 1)

        clock = clock.addingTimeInterval(3600 - 60)
        let renewed = try await session.token()
        XCTAssertEqual(renewed, "msa-token-r2", "renewed before expiry")
        XCTAssertEqual(services.msa.calls.last?["refresh_token"], "refresh-1")
    }

    func testDeadRefreshTokenAsksForANewSignIn() async throws {
        let services = FakeServices()
        services.msa.refreshError = "invalid_grant"
        let store = MemoryStateStore()
        var state = PersistedState()
        state.refreshToken = "refresh-0"
        try store.save(state)
        let vault = try StateVault(store: store)
        let session = AccountSession(account: MicrosoftAccount(transport: services), vault: vault)
        do {
            _ = try await session.token()
            XCTFail("expected an error")
        } catch MicrosoftAccount.SignInError.reauthorizationRequired {}
        let signedIn = await vault.state.isSignedIn
        XCTAssertFalse(signedIn)
    }

    func testDeviceCodeSignInStoresTokens() async throws {
        let services = FakeServices()
        let vault = try StateVault(store: MemoryStateStore())
        let session = AccountSession(account: MicrosoftAccount(transport: services), vault: vault)
        let code = try await session.beginSignIn()
        XCTAssertEqual(code.userCode, "ABCD1234")
        try await session.finishSignIn(code)
        let stored = await vault.state.refreshToken
        XCTAssertEqual(stored, "refresh-0")
        let token = try await session.token()
        XCTAssertEqual(token, "msa-token")
    }
}

final class StateStoreTests: XCTestCase {
    func sample() throws -> PersistedState {
        var state = PersistedState()
        state.refreshToken = "r"
        state.accountName = "user@example.com"
        let certificate = try DeviceCertificate.generate(commonName: "dev")
        var role = RoleIdentity(deviceId: "dev", identityKey: certificate.privateKey.rawRepresentation, identityCertificate: certificate.der, createdAt: Date())
        role.trustKey = certificate.privateKey.rawRepresentation
        role.trustCertificate = certificate.der
        state.roles["PL"] = role
        state.trust = [TrustRelationship(selfClientId: "trust_dev", partnerClientId: "trust_p", partnerDcgClientId: "p", partnerCertificate: certificate.der,
                                         kind: .asyncDevice, addedAt: Date(), keyExpires: Date().addingTimeInterval(100), lastAccess: Date())]
        return state
    }

    func testFileStoreRoundTripsAndIsPrivate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("winphone-tests-\(UUID().uuidString)/state.json")
        let store = FileStateStore(url: url)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertNil(try store.load())
        let state = try sample()
        try store.save(state)
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded.refreshToken, state.refreshToken)
        XCTAssertEqual(loaded.roles["PL"]?.deviceId, "dev")
        XCTAssertEqual(loaded.trust, state.trust.map { var t = $0; t.addedAt = Date(timeIntervalSince1970: floor(t.addedAt.timeIntervalSince1970)); return t }.map { _ in loaded.trust[0] })
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        _ = try loaded.roles["PL"]?.identitySigner()
        XCTAssertNotNil(try loaded.roles["PL"]?.trustSigner())
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testVaultWritesThroughAndKeepsInstallationOnClear() async throws {
        let store = MemoryStateStore()
        let vault = try StateVault(store: store)
        let seed = await vault.state.logicalDeviceSeed
        XCTAssertEqual(seed.count, 32)
        XCTAssertEqual(store.saveCount, 1, "a fresh document is persisted at once")
        try await vault.update { $0.refreshToken = "r" }
        XCTAssertEqual(try store.load()?.refreshToken, "r")
        try await vault.clear()
        XCTAssertNil(try store.load()?.refreshToken)
        XCTAssertEqual(try store.load()?.logicalDeviceSeed, seed, "the logical device ID survives a sign-out")
        let instance = await vault.clientInstance
        XCTAssertEqual(instance.logicalDeviceId, ClientInstance.logicalDeviceId(seed: seed))
        let again = await vault.clientInstance
        XCTAssertEqual(instance.sessionId, again.sessionId, "one session ID per run")
    }

    /// Talks to the real login keychain, so it only runs when asked for.
    func testKeychainStoreRoundTrips() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WINPHONE_KEYCHAIN_TESTS"] == "1", "set WINPHONE_KEYCHAIN_TESTS=1")
        let store = KeychainStateStore(service: "com.winphone.tests", account: UUID().uuidString)
        defer { try? store.clear() }
        XCTAssertNil(try store.load())
        let state = try sample()
        try store.save(state)
        XCTAssertEqual(try store.load()?.refreshToken, "r")
        var changed = state
        changed.refreshToken = "r2"
        try store.save(changed)
        XCTAssertEqual(try store.load()?.refreshToken, "r2", "a second save updates the existing item")
        try store.clear()
        XCTAssertNil(try store.load())
    }
}

/// Replacing the identity's key (`/Auth/RotateKeys`): built from Phone Link's code, never seen
/// on the wire, so every outcome is played against the scripted service.
final class KeyRotationTests: XCTestCase {
    typealias Stack = IdentityServiceTests.Stack

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date()
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date += seconds } }
    }

    func identity(_ stack: Stack, clock: Clock) async -> IdentityService {
        let instance = await stack.vault.clientInstance
        return IdentityService(profile: .phoneLink, client: DCGClient(profile: .phoneLink, instance: instance, transport: stack.services),
                               account: stack.account, vault: stack.vault, displayName: "Mac", now: { clock.now })
    }

    func role(_ stack: Stack) async throws -> RoleIdentity {
        let state = await stack.vault.state
        return try XCTUnwrap(state.roles["PL"])
    }

    func testTheKeyIsReplacedOnceHalfItsYearIsGone() async throws {
        let stack = try Stack()
        let clock = Clock()
        try await (await identity(stack, clock: clock)).ensureReady()
        let before = try await role(stack)
        XCTAssertFalse(stack.services.dcg.calls.contains("POST /Auth/RotateKeys"), "a new key is left alone")
        XCTAssertFalse(IdentityService.keyRotationDue(before, timing: .init(), now: clock.now))

        // Half a year on, the service says so at sign-in.
        stack.services.dcg.remainingDays = 182
        stack.services.dcg.reset()
        let later = await identity(stack, clock: clock)
        let token = try await later.signIn()
        XCTAssertEqual(stack.services.dcg.calls, ["POST /Auth/GenerateNonce", "POST /Auth/SignIn", "POST /Auth/GenerateNonce", "POST /Auth/RotateKeys"])
        XCTAssertFalse(token.isEmpty)
        let after = try await role(stack)
        XCTAssertEqual(after.deviceId, before.deviceId, "the same device, a new key")
        XCTAssertNotEqual(after.identityKey, before.identityKey)
        XCTAssertNotEqual(after.identityCertificate, before.identityCertificate)
        XCTAssertNil(after.pendingIdentityKey)
        XCTAssertEqual(try DeviceCertificate.inspect(der: after.identityCertificate).commonName, before.deviceId)
        XCTAssertEqual(stack.services.dcg.knownKey(before.deviceId), try after.identitySigner().privateKey.publicKey.rawRepresentation, "the service holds the new key")
        XCTAssertEqual(after.trustCertificate, before.trustCertificate, "the trust certificate is another matter")

        // The next launch signs in with the new key, and does not replace it again.
        stack.services.dcg.reset()
        _ = try await (await identity(stack, clock: clock)).signIn()
        XCTAssertEqual(stack.services.dcg.calls, ["POST /Auth/GenerateNonce", "POST /Auth/SignIn"])
        XCTAssertEqual(stack.services.dcg.rotations, 1)
    }

    func testARefusedReplacementKeepsTheOldKeyAndWaitsADay() async throws {
        let stack = try Stack()
        let clock = Clock()
        try await (await identity(stack, clock: clock)).ensureReady()
        let before = try await role(stack)
        stack.services.dcg.remainingDays = 100
        stack.services.dcg.rotationRefusedOnce = true
        let service = await identity(stack, clock: clock)
        let token = try await service.signIn()
        XCTAssertFalse(token.isEmpty, "the sign-in itself is not harmed")
        var now = try await role(stack)
        XCTAssertEqual(now.identityKey, before.identityKey)
        XCTAssertNil(now.pendingIdentityKey, "a refused key is thrown away")
        XCTAssertNotNil(now.nextKeyRotationCheck)

        // Signing in again the same day does not ask again.
        stack.services.dcg.reset()
        _ = try await service.signIn()
        XCTAssertEqual(stack.services.dcg.calls, ["POST /Auth/GenerateNonce", "POST /Auth/SignIn"])
        // A day later it does, and this time it is taken.
        clock.advance(86_400 + 60)
        _ = try await service.signIn()
        now = try await role(stack)
        XCTAssertNotEqual(now.identityKey, before.identityKey)
        XCTAssertEqual(stack.services.dcg.rotations, 1)
    }

    /// The service took the new key, but the answer never arrived: nothing here knows that.
    /// The next sign-in with the old key is turned down, and the kept key gets in.
    func testAReplacementWhoseAnswerWasLostIsFoundOutAtTheNextSignIn() async throws {
        let stack = try Stack()
        let clock = Clock()
        try await (await identity(stack, clock: clock)).ensureReady()
        let before = try await role(stack)
        stack.services.dcg.remainingDays = 10
        stack.services.dcg.rotationAnswerLostOnce = true
        _ = try await (await identity(stack, clock: clock)).signIn()
        let between = try await role(stack)
        XCTAssertEqual(between.identityKey, before.identityKey, "still the old key in use")
        let kept = try XCTUnwrap(between.pendingIdentityKey, "the new key is kept, since the service may hold it")
        XCTAssertEqual(stack.services.dcg.rotations, 1)

        stack.services.dcg.reset()
        let again = await identity(stack, clock: clock)
        try await again.ensureReady()
        XCTAssertEqual(Array(stack.services.dcg.calls.prefix(4)), ["POST /Auth/GenerateNonce", "POST /Auth/SignIn", "POST /Auth/GenerateNonce", "POST /Auth/SignIn"])
        XCTAssertFalse(stack.services.dcg.calls.contains("POST /Auth/CreateIdentity"), "the identity is not thrown away")
        let after = try await role(stack)
        XCTAssertEqual(after.deviceId, before.deviceId)
        XCTAssertEqual(after.identityKey, kept)
        XCTAssertNil(after.pendingIdentityKey)
        XCTAssertNotNil(after.enrolledAt, "enrollment and trust are as they were")
        XCTAssertEqual(stack.services.dcg.rotations, 1)
    }

    /// The request never reached the service. The old key goes on signing in; the key made
    /// for the replacement is offered again at the next try, and forgotten if none comes.
    func testAReplacementThatNeverReachedTheServiceIsTriedAgainWithTheSameKey() async throws {
        let stack = try Stack()
        let clock = Clock()
        try await (await identity(stack, clock: clock)).ensureReady()
        let before = try await role(stack)
        stack.services.dcg.remainingDays = 50
        stack.services.dcg.rotationUnreachableOnce = true
        let service = await identity(stack, clock: clock)
        _ = try await service.signIn()
        let between = try await role(stack)
        let kept = try XCTUnwrap(between.pendingIdentityKey)
        XCTAssertEqual(stack.services.dcg.rotations, 0)
        // The old key still signs in; within the day nothing more is tried, and the key is kept.
        _ = try await service.signIn()
        let sameDayRole = try await role(stack)
        XCTAssertEqual(sameDayRole.pendingIdentityKey, kept)
        // A day later the same key is offered, and taken.
        clock.advance(86_400 + 60)
        _ = try await service.signIn()
        let after = try await role(stack)
        XCTAssertEqual(after.identityKey, kept, "no second candidate was made")
        XCTAssertNil(after.pendingIdentityKey)
        XCTAssertEqual(after.deviceId, before.deviceId)
        XCTAssertEqual(stack.services.dcg.rotations, 1)
    }

    func testAKeptKeyIsForgottenWhenTheOldOneGoesOnWorking() async throws {
        let stack = try Stack()
        let clock = Clock()
        try await (await identity(stack, clock: clock)).ensureReady()
        stack.services.dcg.remainingDays = 50
        stack.services.dcg.rotationUnreachableOnce = true
        let service = await identity(stack, clock: clock)
        _ = try await service.signIn()
        let kept = try await role(stack).pendingIdentityKey
        XCTAssertNotNil(kept)
        // The service stops asking for a new key (as if it had been another device's doing),
        // and days pass with the old key signing in.
        stack.services.dcg.remainingDays = 364
        clock.advance(3 * 86_400)
        _ = try await service.signIn()
        let after = try await role(stack)
        XCTAssertNil(after.pendingIdentityKey)
        XCTAssertEqual(stack.services.dcg.rotations, 0)
    }

    /// Several parts of the app ask for a token at once when it has run out. They share one
    /// sign-in, so the service is offered one new key, once.
    func testSignInsAtTheSameTimeShareOneReplacement() async throws {
        let stack = try Stack()
        let clock = Clock()
        try await (await identity(stack, clock: clock)).ensureReady()
        let before = try await role(stack)
        stack.services.dcg.remainingDays = 30
        stack.services.dcg.reset()
        let service = await identity(stack, clock: clock)
        async let first = service.signIn()
        async let second = service.signIn()
        async let third = service.dcgToken()
        let tokens = try await [first, second, third]
        XCTAssertEqual(Set(tokens).count, 1, "one sign-in, one token for all")
        XCTAssertEqual(stack.services.dcg.calls.filter { $0 == "POST /Auth/SignIn" }.count, 1)
        XCTAssertEqual(stack.services.dcg.calls.filter { $0 == "POST /Auth/RotateKeys" }.count, 1)
        let after = try await role(stack)
        XCTAssertNil(after.pendingIdentityKey)
        XCTAssertNotEqual(after.identityKey, before.identityKey)
        XCTAssertEqual(stack.services.dcg.knownKey(before.deviceId), try after.identitySigner().privateKey.publicKey.rawRepresentation, "the key in use is the one the service took")
        // And the next sign-in is a plain one.
        stack.services.dcg.reset()
        _ = try await service.signIn()
        XCTAssertEqual(stack.services.dcg.calls, ["POST /Auth/GenerateNonce", "POST /Auth/SignIn"])
    }

    /// However the service turns down a key it has replaced, the kept key is tried before
    /// the identity is given up.
    func testTheKeptKeyIsTriedWhateverTheRefusalIsCalled() async throws {
        let stack = try Stack()
        let clock = Clock()
        try await (await identity(stack, clock: clock)).ensureReady()
        let before = try await role(stack)
        stack.services.dcg.remainingDays = 10
        stack.services.dcg.rotationAnswerLostOnce = true
        _ = try await (await identity(stack, clock: clock)).signIn()
        let kept = try await role(stack).pendingIdentityKey
        stack.services.dcg.supersededKeyAnswersUnlinked = true
        stack.services.dcg.reset()
        try await (await identity(stack, clock: clock)).ensureReady()
        XCTAssertFalse(stack.services.dcg.calls.contains("POST /Auth/CreateIdentity"))
        let after = try await role(stack)
        XCTAssertEqual(after.deviceId, before.deviceId)
        XCTAssertEqual(after.identityKey, kept)
    }

    /// The kept key is the right one, but the service is busy when it is tried. That is no
    /// verdict on the key: the identity stays, and the next sign-in gets in with it.
    func testATroubledTryOfTheKeptKeyDoesNotCostTheIdentity() async throws {
        let stack = try Stack()
        let clock = Clock()
        try await (await identity(stack, clock: clock)).ensureReady()
        let before = try await role(stack)
        stack.services.dcg.remainingDays = 10
        stack.services.dcg.rotationAnswerLostOnce = true
        _ = try await (await identity(stack, clock: clock)).signIn()
        let kept = try await role(stack).pendingIdentityKey
        XCTAssertNotNil(kept)
        stack.services.dcg.throttleKnownKeyOnce = true
        stack.services.dcg.reset()
        let service = await identity(stack, clock: clock)
        do {
            _ = try await service.signIn()
            XCTFail("signed in although the service said to come back later")
        } catch {
            guard case DCGError.service(429, _, _, _) = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(stack.services.dcg.calls.contains("POST /Auth/CreateIdentity"), "no new identity over a busy service")
        let between = try await role(stack)
        XCTAssertEqual(between.deviceId, before.deviceId)
        XCTAssertEqual(between.pendingIdentityKey, kept, "the kept key is still kept")
        _ = try await service.signIn()
        let after = try await role(stack)
        XCTAssertEqual(after.deviceId, before.deviceId)
        XCTAssertEqual(after.identityKey, kept)
        XCTAssertNil(after.pendingIdentityKey)
    }

    func testWithoutTheServicesCountTheCertificatesOwnDatesDecide() async throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let certificate = try DeviceCertificate.generate(commonName: "11111111-1111-4111-8111-111111111111", now: created)
        var role = RoleIdentity(deviceId: "11111111-1111-4111-8111-111111111111", identityKey: certificate.privateKey.rawRepresentation,
                                identityCertificate: certificate.der, createdAt: created)
        let timing = IdentityService.Timing()
        XCTAssertFalse(IdentityService.keyRotationDue(role, timing: timing, now: created.addingTimeInterval(100 * 86_400)))
        XCTAssertTrue(IdentityService.keyRotationDue(role, timing: timing, now: created.addingTimeInterval(200 * 86_400)))
        // The service's count, where there is one, goes first.
        role.keyValidRemainingDays = 300
        XCTAssertFalse(IdentityService.keyRotationDue(role, timing: timing, now: created.addingTimeInterval(200 * 86_400)))
        role.keyValidRemainingDays = 182
        XCTAssertTrue(IdentityService.keyRotationDue(role, timing: timing, now: created))
        role.nextKeyRotationCheck = created.addingTimeInterval(3600)
        XCTAssertFalse(IdentityService.keyRotationDue(role, timing: timing, now: created), "not again before the day is over")
        // What was stored before these fields existed still reads.
        let old = try JSONDecoder().decode(RoleIdentity.self, from: Data(#"{"deviceId":"d","identityKey":"AA==","identityCertificate":"AA==","createdAt":0,"lastAccessed":0}"#.utf8))
        XCTAssertNil(old.pendingIdentityKey)
        XCTAssertNil(old.nextKeyRotationCheck)
    }
}
