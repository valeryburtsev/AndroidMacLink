import Foundation

// Request and response bodies of the DCG REST API, with field names exactly as on the wire
// (captures of 2026-10-09). Unknown response fields are ignored; optional ones are optional.

public struct DCGErrorBody: Decodable, Equatable, Sendable {
    public struct Detail: Decodable, Equatable, Sendable {
        public var code: String?
        public var message: String?
        public var categoryCode: Int?
    }
    public var error: Detail
}

public enum DCGError: Error, Equatable {
    /// The service answered with an error body. `code` is e.g. `DeviceUnlinked`.
    case service(status: Int, code: String?, message: String?, categoryCode: Int?)
    /// A non-success status without a recognizable error body.
    case http(status: Int)
    case malformedResponse(String)

    /// The device's registration was removed, for example because the phone was unlinked.
    /// The client must create a new identity and enroll again.
    public var isDeviceUnlinked: Bool {
        if case .service(_, let code, _, _) = self { return code == "DeviceUnlinked" }
        return false
    }
}

public struct ServiceEnvironmentResponse: Decodable, Equatable, Sendable {
    public var serviceEnvironment: String
}

public struct GenerateNonceRequest: Encodable, Sendable { public var deviceId: String }

public struct GenerateNonceResponse: Decodable, Equatable, Sendable {
    public var epochTimeStamp: Int64?
    public var nonce: String
}

public struct CertificateJWTRequest: Encodable, Sendable { public var certificateJWT: String }

/// The same nonce proved twice: with a new key, and with the key the service knows.
public struct RotateKeysRequest: Encodable, Sendable {
    public var newCertificateJWT: String
    public var oldCertificateJWT: String
}

public struct IdentityResponse: Decodable, Equatable, Sendable {
    /// The DCG token, sent later as `Dcg-Token` or as a bearer token.
    public var accessToken: String
    /// The DCG client ID of this device.
    public var deviceId: String
    public var tenantId: String?
    public var epochExpirationTime: Int64?
    public var keyValidRemainingDays: Int?
}

public struct RegistrationRequest: Encodable, Sendable {
    public var applicationId: String
    public var channelId: String
    public var channelType: String
    public var deviceId: String
}

public struct DeviceMetadata: Codable, Equatable, Sendable {
    public var capabilities: [String]
    public var clientType: String
    public var clientVersion: String
    public var consentVersion: Int
    public var customData: String
    public var displayName: String
    public var isEnabled: Bool
    public var manufacture: String
    public var modelName: String
    public var modelVersion: String
    public var osName: String
    public var osVersion: String

    public init(profile: ClientProfile, displayName: String) {
        capabilities = profile.capabilities
        clientType = profile.clientType
        clientVersion = profile.appVersion
        consentVersion = 0
        customData = ""
        self.displayName = displayName
        isEnabled = true
        manufacture = "Unknown"
        modelName = "Unknown"
        modelVersion = "Unknown"
        osName = profile.osName
        osVersion = profile.osVersion
    }
}

public struct EnrollDeviceRequest: Encodable, Sendable {
    /// Certificate lists by kind. Clients enroll their trust certificate under `SelfSigned`,
    /// as standard base64 of the DER bytes.
    public var certificates: [String: [String]]
    public var metadata: DeviceMetadata
}

public struct DeviceInfo: Decodable, Equatable, Sendable {
    /// The device's DCG client ID.
    public var id: String
    public var registrationTime: Int64?
    public var distinguishedDeviceId: String?
    public var globalDeviceId: String?
    public var name: String?
    public var osName: String?
    public var osVersion: String?
    public var manufacture: String?
    public var modelName: String?
    public var modelVersion: String?
    public var clientType: String?
    public var clientVersion: String?
    public var isLinked: Bool?
    public var consentVersion: Int?
    public var isEnabled: Bool?
    public var lastSeenTime: Int64?
    public var capabilities: [String]?
    public var customData: String?
    public var certificates: [String: [String]]?

    public var isAndroid: Bool { osName?.caseInsensitiveCompare("Android") == .orderedSame }

    /// The certificate to trust for this peer: the first `PKI` one if present, else the first
    /// `SelfSigned` one.
    public var preferredCertificate: Data? {
        for kind in ["PKI", "SelfSigned"] {
            // The phone's certificate is MIME-style base64 with line breaks; skip the whitespace.
            if let first = certificates?[kind]?.first, let der = Data(base64Encoded: first, options: .ignoreUnknownCharacters), !der.isEmpty { return der }
        }
        return nil
    }

    /// `yppCapabilities` from the JSON in `customData`, if present.
    public var yppCapabilities: Int? {
        guard let data = customData?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["yppCapabilities"] as? Int
    }
}

public struct AccountInfo: Decodable, Equatable, Sendable {
    public var signInName: String?
    public var firstName: String?
    public var lastName: String?
    public var accountKey: String?
}

public struct EnrollDeviceResponse: Decodable, Equatable, Sendable {
    public var devices: [DeviceInfo]?
    /// Base64 DER certificate of the account. Its common name is the account's DCG client ID.
    public var accountCert: String
    public var accountInfo: AccountInfo?
    public var rootCertificateChain: [String]?
}

public struct AccountCertResponse: Decodable, Equatable, Sendable { public var accountCert: String }

public struct WakeRequest: Encodable, Sendable {
    public var collapseKey: String
    public var data: [String: String]
    public var deviceId: String
    public var priority: String
    public var ttl: Int

    public init(collapseKey: String, data: [String: String], deviceId: String, priority: String, ttl: Int) {
        self.collapseKey = collapseKey
        self.data = data
        self.deviceId = deviceId
        self.priority = priority
        self.ttl = ttl
    }

    /// The wake push Phone Link sends when it reconnects: collapse key `YPPWake`, normal priority,
    /// 20 second lifetime, and a data map naming the environment, the hub region the PC is
    /// connected to, and a wake token signed by the PC's trust key.
    public static func reconnect(targetDeviceId: String, hubRegion: String, cryptoWakeJwt: String,
                                 requestNewSession: Bool = true) -> WakeRequest {
        WakeRequest(collapseKey: "YPPWake",
                    data: ["DCG-Environment": "Prod",
                           "IgnoreDeviceDisabledStatus": "False",
                           "DCG-RequestNewSession": requestNewSession ? "True" : "False",
                           "DCG-HubRegion": hubRegion,
                           "DCG-CryptoWakeJwt": cryptoWakeJwt],
                    deviceId: targetDeviceId, priority: "normal", ttl: 20)
    }
}

public struct CloudRelayResponse: Decodable, Equatable, Sendable {
    public struct Stun: Decodable, Equatable, Sendable { public var urls: [String] }
    public struct Turn: Decodable, Equatable, Sendable {
        public var urls: [String]
        public var username: String
        public var credential: String
        public var turnExpireTime: Int64?
    }
    public var stunInfo: Stun?
    public var turnCredential: Turn?
}

public struct RelayNegotiateResponse: Decodable, Equatable, Sendable {
    public var negotiateVersion: Int?
    /// Set when the gateway redirects to Azure SignalR Service.
    public var url: String?
    public var accessToken: String?
    public var connectionId: String?
    public var connectionToken: String?
}

// MARK: Pairing

public struct CreatePairingSessionRequest: Encodable, Sendable {
    public var flow: String
    public var optionalPermission: [String]
}

public struct PairingSessionResponse: Decodable, Equatable, Sendable {
    public var pairingSessionId: String
    public var pairingSessionExpireTime: String?
    public var currentServiceTime: String?
    public var flow: String?
    public var nextFlow: String?
    public var requiredPermission: [String]?
    public var optionalPermission: [String]?
    public var state: String
    public var failureType: String?
    public var pairingLink: String?
    public var pairingLinkExpireTime: String?
    public var pairingLinkForSignInPINFlow: String?
    public var challengePIN: String?
    public var challengePINExpireTime: String?
    public var pairingPIN: String?
    public var pairingPINExpireTime: String?
    public var isReadyToComplete: Bool?
    public var clientAppId: String?
    public var region: String?
    public var partnerDeviceKey: String?
    public var partnerDcgClientId: String?
    public var partnerDeviceVisitMode: String?
}
