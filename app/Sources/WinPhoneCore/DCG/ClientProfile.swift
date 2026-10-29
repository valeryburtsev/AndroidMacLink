import CryptoKit
import Foundation

/// How this client presents itself to DCG. The service schema only knows Windows, Android and iOS
/// clients, so we present the values Phone Link itself sends (capture of 2026-10-09).
public struct ClientProfile: Equatable, Sendable {
    /// `DCG-AppId`.
    public var appId: String
    /// `DCG-AppVersion` and `metadata.clientVersion`.
    public var appVersion: String
    /// `DCG-RingName`.
    public var ringName: String
    /// `DCG-OS` and `metadata.osName`.
    public var osName: String
    /// `DCG-OSVersion` and `metadata.osVersion`.
    public var osVersion: String
    /// `metadata.clientType` and `Registration.applicationId`.
    public var clientType: String
    /// `metadata.capabilities`.
    public var capabilities: [String]

    public init(appId: String, appVersion: String, ringName: String, osName: String, osVersion: String,
                clientType: String, capabilities: [String]) {
        self.appId = appId
        self.appVersion = appVersion
        self.ringName = ringName
        self.osName = osName
        self.osVersion = osVersion
        self.clientType = clientType
        self.capabilities = capabilities
    }

    /// Phone Link 1.26072.257.0 on Windows 11, as observed on the wire. The phone sends
    /// notifications only to a client of this type.
    public static let phoneLink = ClientProfile(
        appId: "Microsoft.YourPhone_8wekyb3d8bbwe",
        appVersion: "1.26072.257.0",
        ringName: "Public",
        osName: "Windows",
        osVersion: "10.0.26200",
        clientType: "PL",
        capabilities: ["FILE_TRANSFER_ONEDRIVE", "UNLINKABLE_V1", "UNLINKABLE_V2"])

    /// One client for everything: Phone Link's identity with the clipboard capability added.
    /// Windows never enrolls this combination, but the LinkMyPhone project reports from live
    /// runs that a phone gives such a client both notifications and the cross-device clipboard.
    /// Cheaper than two roles (one enrollment, one socket); unverified by us.
    public static let unified: ClientProfile = {
        var profile = ClientProfile.phoneLink
        profile.capabilities.append("CLIPBOARD")
        return profile
    }()

    /// Whether this client carries the cross-device clipboard and device status.
    public var offersClipboard: Bool { capabilities.contains("CLIPBOARD") }
    /// Whether the phone sends this client notifications.
    public var receivesNotifications: Bool { clientType == "PL" }
    /// Whether the phone offers this client as a target for sharing files. For a
    /// cross-device client it does so only when this capability is listed.
    public var receivesFiles: Bool { capabilities.contains(ClientProfile.fileTransferCapability) }
    public static let fileTransferCapability = "FILE_TRANSFER"

    /// The same client, also announcing that it takes files shared from the phone.
    public var acceptingFiles: ClientProfile {
        guard !receivesFiles else { return self }
        var profile = self
        profile.capabilities.append(ClientProfile.fileTransferCapability)
        return profile
    }

    /// Cross Device Experience Host 1.26082.74.0, the second client Windows runs. The phone
    /// offers the cross-device clipboard only to a client of this type that lists `CLIPBOARD`.
    /// Windows also lists file transfer, remote control and hotspot; those are left out until
    /// implemented, so the phone does not offer features that would fail.
    public static let crossDevice = ClientProfile(
        appId: "MicrosoftWindows.CrossDevice_cw5n1h2txyewy",
        appVersion: "1.26082.74.0",
        ringName: "Public",
        osName: "Windows",
        osVersion: "10.0.26200",
        clientType: "WEA",
        capabilities: ["DEVICE_STATUS", "UNLINKABLE_V1", "CLIPBOARD"])
}

/// Identifiers that stay fixed for an installation or a run and appear on every DCG request.
public struct ClientInstance: Equatable, Sendable {
    /// `DCG-LogicalDeviceId`: base64 of 32 bytes, stable for this installation.
    public var logicalDeviceId: String
    /// `DCG-SessionId`: a UUID per app run.
    public var sessionId: String

    public init(logicalDeviceId: String, sessionId: String = UUID().uuidString.lowercased()) {
        self.logicalDeviceId = logicalDeviceId
        self.sessionId = sessionId
    }

    /// Derives a logical device ID from a persisted random seed.
    public static func logicalDeviceId(seed: Data) -> String {
        Data(SHA256.hash(data: seed)).base64EncodedString()
    }
}

/// Which credentials a DCG request carries. The four combinations below are the only ones seen.
public enum DCGAuthorization: Sendable {
    /// `Authorization: Bearer <MSA>` + `Authorization-Type: MSA`.
    case msa(String)
    /// As `.msa`, plus `UserIdentityType: MSA` and `UserIdentityToken: <MSA>`. Used by `/Auth/*`.
    case msaIdentity(String)
    /// As `.msa`, plus `Dcg-Token: <DCG token>`. Used by enrollment and device changes.
    case msaWithDeviceToken(msa: String, dcg: String)
    /// `Authorization: Bearer <DCG token>`. Used once the device has an identity.
    case deviceToken(String)
}

public enum DCGHeaders {
    public static let authorizationPortal = "FirstPartyAppsRepo"

    /// Builds the header set Phone Link sends on DCG REST calls.
    /// - Parameter scenario: optional `ypScenarioId` / `ypTriggerId` pair for the trace state.
    public static func build(profile: ClientProfile, instance: ClientInstance, authorization: DCGAuthorization,
                             trace: TraceContext = TraceContext(), hasBody: Bool) -> [(name: String, value: String)] {
        var headers: [(name: String, value: String)] = []
        switch authorization {
        case .msa(let token):
            headers.append(("Authorization", "Bearer " + token))
            headers.append(("Authorization-Type", "MSA"))
        case .msaIdentity(let token):
            headers.append(("UserIdentityType", "MSA"))
            headers.append(("UserIdentityToken", token))
            headers.append(("Authorization", "Bearer " + token))
            headers.append(("Authorization-Type", "MSA"))
        case .msaWithDeviceToken(let msa, let dcg):
            headers.append(("Authorization", "Bearer " + msa))
            headers.append(("Authorization-Type", "MSA"))
            headers.append(("Dcg-Token", dcg))
        case .deviceToken:
            break
        }
        let spanId = trace.parentId ?? TraceContext.randomHex(bytes: 8)
        var state: [String] = []
        if let scenario = trace.scenarioId { state.append("ypScenarioId=\(scenario)") }
        if let trigger = trace.triggerId { state.append("ypTriggerId=\(trigger)") }
        state.append("yppHttpParent=\(spanId)")
        let traceState = state.joined(separator: ",")
        headers.append(("traceparent", trace.traceparent(spanId: spanId)))
        headers.append(("tracestate", traceState))
        headers.append(("DCG-TraceState", traceState))
        headers.append(("Accept", "application/json"))
        if case .deviceToken(let token) = authorization { headers.append(("Authorization", "Bearer " + token)) }
        headers.append(("AuthorizationPortal", authorizationPortal))
        headers.append(("DCG-LogicalDeviceId", instance.logicalDeviceId))
        headers.append(("DCG-AppVersion", profile.appVersion))
        headers.append(("DCG-AppId", profile.appId))
        headers.append(("DCG-SessionId", instance.sessionId))
        headers.append(("DCG-RingName", profile.ringName))
        headers.append(("DCG-OS", profile.osName))
        headers.append(("DCG-OSVersion", profile.osVersion))
        if hasBody { headers.append(("Content-Type", "application/json")) }
        return headers
    }
}
