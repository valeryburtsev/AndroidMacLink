import CryptoKit
import Foundation

/// The signed tokens a DCG client produces with its device keys.
public enum DeviceTokens {
    /// JWTs are valid from 12 hours before to 12 hours after the time of issue.
    public static let clockDrift: TimeInterval = 12 * 3600

    /// The proof sent to `/Auth/CreateIdentity` and `/Auth/SignIn` as `certificateJWT`: the
    /// service's nonce and the device certificate, signed by the device key.
    ///
    /// Claim order follows the Microsoft JWT library: custom claims, then `nbf`, `exp`, `iat`, `iss`.
    public static func nonceJWT(nonce: String, identity: DeviceCertificate, now: Date = Date()) throws -> String {
        let t = Int64(now.timeIntervalSince1970)
        return try JWT.signES384(claims: [
            ("Nonce", .string(nonce)),
            ("Certificate", .string(identity.base64)),
            ("nbf", .int(t - Int64(clockDrift))),
            ("exp", .int(t + Int64(clockDrift))),
            ("iat", .int(t)),
            ("iss", .string(identity.commonName)),
        ], key: identity.privateKey)
    }

    /// The JSON text Windows produces for the wake data map: indented by two spaces, with
    /// `": "` after keys and CRLF line breaks. The receiver parses it as JSON, so the layout
    /// should not matter, but matching the original is the conservative choice.
    public static func wakeDataText(_ entries: [(String, String)]) -> String {
        func quote(_ s: String) -> String { String(data: try! JSONEncoder().encode(s), encoding: .utf8)!.replacingOccurrences(of: "\\/", with: "/") }
        let lines = entries.map { "  \(quote($0.0)): \(quote($0.1))" }
        return "{\r\n" + lines.joined(separator: ",\r\n") + "\r\n}"
    }

    /// A JWT addressed to a peer and signed with the trust key.
    /// - Parameters:
    ///   - scope: `wake`, `hotspot.request` or `hotspot.response`.
    ///   - data: the `Data` claim, a string.
    ///   - sourceId: this device's DCG client ID.
    public static func trustJWT(scope: String, data: String, sourceId: String, trust: DeviceCertificate, now: Date = Date()) throws -> String {
        let t = Int64(now.timeIntervalSince1970)
        return try JWT.signES384(claims: [
            ("Data", .string(data)),
            ("SourceId", .string(sourceId)),
            ("Scope", .string(scope)),
            ("nbf", .int(t - Int64(clockDrift))),
            ("exp", .int(t + Int64(clockDrift))),
            ("iat", .int(t)),
            ("iss", .string(trust.commonName)),
        ], key: trust.privateKey)
    }

    /// Builds the wake push for a peer: the data map, signed by the trust key, with the token
    /// added as `DCG-CryptoWakeJwt`.
    public static func wakeRequest(targetDeviceId: String, sourceDeviceId: String, hubRegion: String?, trust: DeviceCertificate,
                                   requestNewSession: Bool = true, ignoreDisabledStatus: Bool = false,
                                   highPriority: Bool = false, now: Date = Date()) throws -> WakeRequest {
        var entries: [(String, String)] = [
            ("DCG-Environment", "Prod"),
            ("IgnoreDeviceDisabledStatus", ignoreDisabledStatus ? "True" : "False"),
            ("DCG-RequestNewSession", requestNewSession ? "True" : "False"),
        ]
        if let hubRegion { entries.append(("DCG-HubRegion", hubRegion)) }
        let jwt = try trustJWT(scope: "wake", data: wakeDataText(entries), sourceId: sourceDeviceId, trust: trust, now: now)
        var data = Dictionary(uniqueKeysWithValues: entries)
        data["DCG-CryptoWakeJwt"] = jwt
        return WakeRequest(collapseKey: "YPPWake", data: data, deviceId: targetDeviceId, priority: highPriority ? "high" : "normal", ttl: 20)
    }
}
