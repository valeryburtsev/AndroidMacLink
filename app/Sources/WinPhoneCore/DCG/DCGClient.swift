import Foundation

/// Typed access to the DCG REST API. One method per endpoint, with the api-version, HTTP verb,
/// credentials and body each call uses on the wire (captures of 2026-10-09).
public struct DCGClient: Sendable {
    public static let productionBaseURL = URL(string: "https://dcg.microsoft.com/")!

    public var baseURL: URL
    public var profile: ClientProfile
    public var instance: ClientInstance
    public var transport: HTTPTransport

    public init(baseURL: URL = DCGClient.productionBaseURL, profile: ClientProfile = .phoneLink,
                instance: ClientInstance, transport: HTTPTransport) {
        self.baseURL = baseURL
        self.profile = profile
        self.instance = instance
        self.transport = transport
    }

    // MARK: Environment and identity

    public func serviceEnvironment(msaToken: String) async throws -> ServiceEnvironmentResponse {
        try await get("EnvironmentDiscovery/UserServiceEnvironment", [("api-version", "1.0.0")], .msa(msaToken))
    }

    public func generateNonce(deviceId: String, msaToken: String) async throws -> GenerateNonceResponse {
        try await send("POST", "Auth/GenerateNonce", [("api-version", "1.1.0")], .msaIdentity(msaToken),
                       body: GenerateNonceRequest(deviceId: deviceId))
    }

    /// Registers a new device identity. Used on first run and after `DeviceUnlinked`.
    public func createIdentity(certificateJWT: String, msaToken: String) async throws -> IdentityResponse {
        try await send("POST", "Auth/CreateIdentity", [("api-version", "1.1.0")], .msaIdentity(msaToken),
                       body: CertificateJWTRequest(certificateJWT: certificateJWT))
    }

    /// Obtains a fresh DCG token for an existing identity.
    public func signIn(certificateJWT: String, msaToken: String) async throws -> IdentityResponse {
        try await send("POST", "Auth/SignIn", [("api-version", "1.1.0")], .msaIdentity(msaToken),
                       body: CertificateJWTRequest(certificateJWT: certificateJWT))
    }

    /// Replaces the identity's key before its certificate runs out. Any 2xx is success; no
    /// body comes back.
    public func rotateKeys(newCertificateJWT: String, oldCertificateJWT: String, msaToken: String) async throws {
        try await sendIgnoringBody("POST", "Auth/RotateKeys", [("api-version", "1.1.0")], .msaIdentity(msaToken),
                                   body: RotateKeysRequest(newCertificateJWT: newCertificateJWT, oldCertificateJWT: oldCertificateJWT))
    }

    /// Registers the push channel the service uses to wake this client.
    public func register(_ request: RegistrationRequest, dcgToken: String) async throws {
        try await sendIgnoringBody("PUT", "Registration/Register", [("api-version", "2.0.0")], .deviceToken(dcgToken), body: request)
    }

    // MARK: Enrollment and devices

    public func enrollDevice(_ request: EnrollDeviceRequest, msaToken: String, dcgToken: String) async throws -> EnrollDeviceResponse {
        try await send("POST", "DeviceAuthProxy/EnrollDevice", [("api-version", "1.5.0"), ("pop-device-key", "")],
                       .msaWithDeviceToken(msa: msaToken, dcg: dcgToken), body: request)
    }

    public func setDeviceInfo(_ request: EnrollDeviceRequest, msaToken: String, dcgToken: String) async throws {
        try await sendIgnoringBody("POST", "DeviceAuthProxy/SetDeviceInfo", [("api-version", "1.5.0"), ("pop-device-key", "")],
                                   .msaWithDeviceToken(msa: msaToken, dcg: dcgToken), body: request)
    }

    /// Lists the account's devices. Phone Link asks with an empty filter and `top=20`.
    public func deviceInfoList(msaToken: String, filter: String = "", top: Int = 20) async throws -> [DeviceInfo] {
        try await get("DeviceAuthProxy/GetDeviceInfoList", [("api-version", "1.5.0"), ("filter", filter), ("top", String(top))], .msa(msaToken))
    }

    public func accountCert(msaToken: String) async throws -> AccountCertResponse {
        try await get("DeviceAuthProxy/GetAccountCert", [("api-version", "1.0.0")], .msa(msaToken))
    }

    /// Unlinks a device from the account. This also invalidates the caller's own registration.
    public func unlinkDevice(deviceId: String, msaToken: String, dcgToken: String) async throws {
        try await sendIgnoringBody("POST", "DeviceAuthProxy/UnlinkDevice", [("api-version", "1.5.0"), ("device-id", deviceId)],
                                   .msaWithDeviceToken(msa: msaToken, dcg: dcgToken), body: Optional<String>.none)
    }

    // MARK: Session support

    public func wake(_ request: WakeRequest, dcgToken: String, trace: TraceContext = TraceContext()) async throws {
        try await sendIgnoringBody("POST", "Dispatcher/Wake", [("api-version", "1.5.0")], .deviceToken(dcgToken), body: request, trace: trace)
    }

    public func cloudRelay(dcgToken: String, onlyStun: Bool = false) async throws -> CloudRelayResponse {
        try await get("CloudRelay/Relay", [("api-version", "1.0.0"), ("isOnlyStun", onlyStun ? "true" : "false")], .deviceToken(dcgToken))
    }

    // MARK: Pairing

    public func createPairingSession(_ request: CreatePairingSessionRequest, msaToken: String, region: String) async throws -> PairingSessionResponse {
        try await send("POST", "DevicePairingProxy/PairingSessions", [("Api-Version", "3.0.0")], .msa(msaToken), body: request,
                       extraHeaders: [("clientRegionName", region)])
    }

    public func pairingSession(id: String, msaToken: String) async throws -> PairingSessionResponse {
        try await get("DevicePairingProxy/PairingSessions/\(id)", [("Api-Version", "3.0.0")], .msa(msaToken))
    }

    public func refreshChallengePIN(sessionId: String, msaToken: String) async throws -> PairingSessionResponse {
        try await send("POST", "DevicePairingProxy/PairingSessions/\(sessionId)/RefreshChallengePIN", [("Api-Version", "3.0.0")],
                       .msa(msaToken), body: Optional<String>.none)
    }

    public func completePairingSession(id: String, msaToken: String) async throws -> PairingSessionResponse {
        try await send("POST", "DevicePairingProxy/PairingSessions/\(id)/Complete", [("Api-Version", "3.0.0")],
                       .msa(msaToken), body: Optional<String>.none)
    }

    // MARK: Request plumbing

    public func makeRequest<Body: Encodable>(_ method: String, _ path: String, _ query: [(String, String)],
                                             _ authorization: DCGAuthorization, body: Body?,
                                             extraHeaders: [(String, String)] = [],
                                             trace: TraceContext = TraceContext()) throws -> HTTPRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        var data: Data?
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            data = try encoder.encode(body)
        }
        var headers = DCGHeaders.build(profile: profile, instance: instance, authorization: authorization, trace: trace, hasBody: data != nil)
        // Request-specific headers sit right after the authorization block, as in the capture.
        let insertAt = headers.firstIndex { $0.name == "traceparent" } ?? headers.count
        headers.insert(contentsOf: extraHeaders.map { (name: $0.0, value: $0.1) }, at: insertAt)
        return HTTPRequest(method: method, url: components.url!, headers: headers, body: data)
    }

    private func get<Response: Decodable>(_ path: String, _ query: [(String, String)], _ authorization: DCGAuthorization) async throws -> Response {
        try await send("GET", path, query, authorization, body: Optional<String>.none)
    }

    private func send<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, _ query: [(String, String)],
                                                            _ authorization: DCGAuthorization, body: Body?,
                                                            extraHeaders: [(String, String)] = [],
                                                            trace: TraceContext = TraceContext()) async throws -> Response {
        let response = try await perform(method, path, query, authorization, body: body, extraHeaders: extraHeaders, trace: trace)
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw DCGError.malformedResponse("\(path): \(error)")
        }
    }

    private func sendIgnoringBody<Body: Encodable>(_ method: String, _ path: String, _ query: [(String, String)],
                                                   _ authorization: DCGAuthorization, body: Body?,
                                                   trace: TraceContext = TraceContext()) async throws {
        _ = try await perform(method, path, query, authorization, body: body, extraHeaders: [], trace: trace)
    }

    private func perform<Body: Encodable>(_ method: String, _ path: String, _ query: [(String, String)],
                                          _ authorization: DCGAuthorization, body: Body?,
                                          extraHeaders: [(String, String)], trace: TraceContext) async throws -> HTTPResponse {
        let request = try makeRequest(method, path, query, authorization, body: body, extraHeaders: extraHeaders, trace: trace)
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else {
            if let parsed = try? JSONDecoder().decode(DCGErrorBody.self, from: response.body) {
                throw DCGError.service(status: response.status, code: parsed.error.code, message: parsed.error.message,
                                       categoryCode: parsed.error.categoryCode)
            }
            throw DCGError.http(status: response.status)
        }
        return response
    }
}
