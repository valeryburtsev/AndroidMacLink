import Foundation

/// Microsoft account sign-in through the OAuth 2.0 device authorization grant, with Phone Link's
/// own public client ID and the DCG scope. The user enters a short code at microsoft.com/link on
/// any device; this client never sees the password.
public struct MicrosoftAccount: Sendable {
    /// Phone Link's public client ID.
    public static let phoneLinkClientId = "8CF55838-E496-42C5-829B-F8D6945288F3"
    public static let scope = "https://dcg.microsoft.com/DCG.ReadWrite offline_access"
    public static let authority = URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/")!

    public var clientId: String
    public var scope: String
    public var authority: URL
    public var transport: HTTPTransport

    public init(clientId: String = MicrosoftAccount.phoneLinkClientId, scope: String = MicrosoftAccount.scope,
                authority: URL = MicrosoftAccount.authority, transport: HTTPTransport) {
        self.clientId = clientId
        self.scope = scope
        self.authority = authority
        self.transport = transport
    }

    public struct DeviceCode: Decodable, Equatable, Sendable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURI: String
        public var expiresIn: Int
        public var interval: Int
        public var message: String?

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri"
            case expiresIn = "expires_in", interval, message
        }
    }

    public struct Tokens: Decodable, Equatable, Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresIn: Int
        public var scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in", scope
        }
    }

    public enum SignInError: Error, Equatable {
        /// The user did not finish in time.
        case expired
        /// The user declined.
        case declined
        /// The refresh token is no longer valid; the user must sign in again.
        case reauthorizationRequired(String)
        case oauth(code: String, description: String?)
        case http(status: Int)
    }

    public func requestDeviceCode() async throws -> DeviceCode {
        let response = try await post("devicecode", ["client_id": clientId, "scope": scope])
        return try decode(response)
    }

    /// Polls until the user signs in. Honors `slow_down` by lengthening the interval.
    public func waitForTokens(_ code: DeviceCode, sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                              now: @Sendable () -> Date = { Date() }) async throws -> Tokens {
        var interval = max(code.interval, 1)
        let deadline = now().addingTimeInterval(TimeInterval(code.expiresIn))
        while now() < deadline {
            try await sleep(.seconds(interval))
            let response = try await post("token", [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": clientId,
                "device_code": code.deviceCode,
            ])
            if response.status == 200 { return try decode(response) }
            switch oauthError(response)?.code {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw SignInError.expired
            case "authorization_declined", "access_denied": throw SignInError.declined
            case let code?: throw SignInError.oauth(code: code, description: oauthError(response)?.description)
            case nil: throw SignInError.http(status: response.status)
            }
        }
        throw SignInError.expired
    }

    public func refresh(refreshToken: String) async throws -> Tokens {
        let response = try await post("token", [
            "grant_type": "refresh_token", "client_id": clientId, "refresh_token": refreshToken, "scope": scope,
        ])
        if response.status == 200 { return try decode(response) }
        if let error = oauthError(response) {
            if ["invalid_grant", "interaction_required"].contains(error.code) {
                throw SignInError.reauthorizationRequired(error.code)
            }
            throw SignInError.oauth(code: error.code, description: error.description)
        }
        throw SignInError.http(status: response.status)
    }

    // MARK: Plumbing

    static func formEncode(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let pairs = fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private func post(_ path: String, _ fields: [String: String]) async throws -> HTTPResponse {
        try await transport.send(HTTPRequest(
            method: "POST", url: authority.appendingPathComponent(path),
            headers: [("Content-Type", "application/x-www-form-urlencoded"), ("Accept", "application/json")],
            body: MicrosoftAccount.formEncode(fields)))
    }

    private func decode<T: Decodable>(_ response: HTTPResponse) throws -> T {
        guard response.status == 200 else {
            if let error = oauthError(response) { throw SignInError.oauth(code: error.code, description: error.description) }
            throw SignInError.http(status: response.status)
        }
        return try JSONDecoder().decode(T.self, from: response.body)
    }

    private func oauthError(_ response: HTTPResponse) -> (code: String, description: String?)? {
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let code = object["error"] as? String else { return nil }
        return (code, object["error_description"] as? String)
    }
}
