import CryptoKit
import Foundation
@testable import WinPhoneCore

/// A scripted DCG service: answers the identity, enrollment, device and wake endpoints with
/// the response shapes seen in the captures, checks the proofs we send, and records the calls.
final class FakeDCG: @unchecked Sendable {
    static let phoneId = FakePhone.id
    static let accountId = "44444444-4444-4444-8444-444444444444"

    let accountCertificate = try! DeviceCertificate.generate(commonName: FakeDCG.accountId)
    let phoneCertificate = try! DeviceCertificate.generate(commonName: "trust_" + FakeDCG.phoneId)
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _wakes: [[String: Any]] = []
    private var _enrollments: [[String: Any]] = []
    /// Device IDs the service knows, with the certificate they proved.
    private var identities: [String: P384.Signing.PublicKey] = [:]
    private var nonces: Set<String> = []
    /// Every device the account has, by ID, as JSON objects.
    private var devices: [String: [String: Any]] = [:]
    /// When set, `/Auth/SignIn` and `EnrollDevice` answer 403 DeviceUnlinked once each.
    var unlinkedOnce = false
    /// How many CreateIdentity calls to refuse with a collision first.
    var collisions = 0
    var msaToken = "msa-token"
    var tokenCounter = 0
    /// What sign-in says remains of the identity's certificate.
    var remainingDays = 364
    /// How `/Auth/RotateKeys` goes, once each: refused; taken, but the answer never arrives;
    /// never reached.
    var rotationRefusedOnce = false, rotationAnswerLostOnce = false, rotationUnreachableOnce = false
    private(set) var rotations = 0
    /// How a key that is no longer the one on file is turned down: never seen from the real service.
    var supersededKeyAnswersUnlinked = false
    /// The next sign-in with the right key is told to come back later.
    var throttleKnownKeyOnce = false
    struct Lost: Error {}
    /// The certificate key the service holds for a device.
    func knownKey(_ deviceId: String) -> Data? { lock.withLock { identities[deviceId]?.rawRepresentation } }

    var calls: [String] { lock.withLock { _calls } }
    var wakes: [[String: Any]] { lock.withLock { _wakes } }
    var enrollments: [[String: Any]] { lock.withLock { _enrollments } }
    var knownDevices: [String] { lock.withLock { Array(devices.keys) } }

    init(phoneLinked: Bool = true) {
        if phoneLinked {
            devices[FakeDCG.phoneId] = [
                "id": FakeDCG.phoneId, "name": "Galaxy", "osName": "Android", "osVersion": "15", "manufacture": "samsung",
                "modelName": "SM-G996B", "clientType": "LTW", "isLinked": true, "isEnabled": true,
                "capabilities": ["CLIPBOARD", "DEVICE_STATUS"], "customData": "{\"yppCapabilities\":127}",
                // As the real phone sends it: base64 broken into lines.
                "certificates": ["SelfSigned": [phoneCertificate.der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])]],
            ]
        }
    }

    func reset() { lock.withLock { _calls = [] } }

    func handle(_ request: HTTPRequest) throws -> HTTPResponse {
        let path = request.url.path
        lock.withLock { _calls.append("\(request.method) \(path)") }
        let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        func json(_ object: Any, status: Int = 200) -> HTTPResponse {
            HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }
        func error(_ status: Int, _ code: String, category: Int) -> HTTPResponse {
            json(["error": ["code": code, "message": code, "categoryCode": category]], status: status)
        }
        // REST calls carry the portal header; the relay negotiate carries its own header set.
        guard path.hasPrefix("/relayhub/") || request.header("AuthorizationPortal") == "FirstPartyAppsRepo" else {
            return error(401, "InvalidAuthHeader", category: 1)
        }

        switch (request.method, path) {
        case ("GET", "/EnvironmentDiscovery/UserServiceEnvironment"):
            return json(["serviceEnvironment": "Production"])
        case ("POST", "/Auth/GenerateNonce"):
            guard body["deviceId"] is String else { return error(400, "InvalidParameters", category: 0) }
            let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            lock.withLock { _ = nonces.insert(nonce) }
            return json(["epochTimeStamp": Int(Date().timeIntervalSince1970), "nonce": nonce])
        case ("POST", "/Auth/CreateIdentity"), ("POST", "/Auth/SignIn"):
            guard request.header("UserIdentityToken") == msaToken, request.header("Authorization") == "Bearer " + msaToken else {
                return error(401, "MsaUnauthorized", category: 1)
            }
            guard let jwt = body["certificateJWT"] as? String, let proof = FakeDCG.proof(jwt) else { return error(400, "InvalidJWT", category: 0) }
            guard lock.withLock({ nonces.remove(proof.nonce) != nil }) else { return error(400, "InvalidNonce", category: 0) }
            if path.hasSuffix("SignIn") {
                if lock.withLock({ let u = unlinkedOnce; unlinkedOnce = false; return u }) { return error(403, "DeviceUnlinked", category: 13) }
                if throttleKnownKeyOnce, lock.withLock({ identities[proof.deviceId]?.rawRepresentation }) == proof.key.rawRepresentation {
                    throttleKnownKeyOnce = false
                    return error(429, "TooManyRequests", category: 0)
                }
                // The proof must be made with the key on file, not just any key for that name.
                guard lock.withLock({ identities[proof.deviceId]?.rawRepresentation }) == proof.key.rawRepresentation else {
                    return supersededKeyAnswersUnlinked ? error(403, "DeviceUnlinked", category: 13) : error(400, "InvalidCertificate", category: 0)
                }
            } else {
                if lock.withLock({ let c = collisions; collisions = max(0, c - 1); return c > 0 }) { return error(403, "Forbidden", category: 0) }
                lock.withLock { identities[proof.deviceId] = proof.key }
            }
            tokenCounter += 1
            return json(["accessToken": "dcg-\(proof.deviceId)-\(tokenCounter)", "deviceId": proof.deviceId,
                         "tenantId": "00000000-0000-0000-0000-000000000000",
                         "epochExpirationTime": Int(Date().timeIntervalSince1970) + 86401, "keyValidRemainingDays": remainingDays])
        case ("POST", "/Auth/RotateKeys"):
            guard request.header("UserIdentityToken") == msaToken, request.header("Authorization") == "Bearer " + msaToken,
                  request.header("UserIdentityType") == "MSA" else { return error(401, "MsaUnauthorized", category: 1) }
            if rotationUnreachableOnce { rotationUnreachableOnce = false; throw Lost() }
            guard let newJWT = body["newCertificateJWT"] as? String, let oldJWT = body["oldCertificateJWT"] as? String,
                  let new = FakeDCG.proof(newJWT), let old = FakeDCG.proof(oldJWT) else { return error(400, "InvalidJWT", category: 0) }
            // One nonce in both, two different keys for one device, the old one the key on file.
            guard new.nonce == old.nonce, lock.withLock({ nonces.remove(old.nonce) != nil }) else { return error(400, "InvalidNonce", category: 0) }
            guard new.deviceId == old.deviceId, new.key.rawRepresentation != old.key.rawRepresentation,
                  lock.withLock({ identities[old.deviceId]?.rawRepresentation }) == old.key.rawRepresentation else { return error(400, "InvalidCertificate", category: 0) }
            if rotationRefusedOnce { rotationRefusedOnce = false; return error(400, "InvalidParameters", category: 0) }
            lock.withLock { identities[new.deviceId] = new.key }
            rotations += 1
            remainingDays = 364
            if rotationAnswerLostOnce { rotationAnswerLostOnce = false; throw Lost() }
            return HTTPResponse(status: 200)
        case ("POST", "/DeviceAuthProxy/EnrollDevice"), ("POST", "/DeviceAuthProxy/SetDeviceInfo"):
            guard let dcg = request.header("Dcg-Token"), let deviceId = FakeDCG.deviceId(ofToken: dcg) else { return error(401, "Unauthorized", category: 1) }
            if lock.withLock({ let u = unlinkedOnce; unlinkedOnce = false; return u }) { return error(403, "DeviceUnlinked", category: 13) }
            guard let certificates = body["certificates"] as? [String: [String]], let first = certificates["SelfSigned"]?.first,
                  let der = Data(base64Encoded: first), let name = try? DeviceCertificate.inspect(der: der).commonName,
                  name == "trust_" + deviceId, let metadata = body["metadata"] as? [String: Any] else {
                return error(400, "InvalidRequest", category: 0)
            }
            lock.withLock {
                _enrollments.append(body)
                devices[deviceId] = ["id": deviceId, "name": metadata["displayName"] ?? "", "osName": metadata["osName"] ?? "",
                                     "clientType": metadata["clientType"] ?? "", "isLinked": true, "isEnabled": true,
                                     "capabilities": metadata["capabilities"] ?? [], "customData": "",
                                     "certificates": ["SelfSigned": [first]]]
            }
            if path.hasSuffix("SetDeviceInfo") { return HTTPResponse(status: 200) }
            return json(["devices": lock.withLock { Array(devices.values) }, "accountCert": accountCertificate.base64,
                         "accountInfo": ["signInName": "user@example.com", "firstName": "U", "lastName": "S", "accountKey": "a"],
                         "rootCertificateChain": []])
        case ("GET", "/DeviceAuthProxy/GetDeviceInfoList"):
            return json(lock.withLock { Array(devices.values) })
        case ("GET", "/DeviceAuthProxy/GetAccountCert"):
            return json(["accountCert": accountCertificate.base64])
        case ("POST", "/Dispatcher/Wake"):
            guard let token = request.header("Authorization"), FakeDCG.deviceId(ofToken: String(token.dropFirst(7))) != nil else {
                return error(401, "Unauthorized", category: 1)
            }
            lock.withLock { _wakes.append(body) }
            return HTTPResponse(status: 200)
        case ("POST", "/DeviceAuthProxy/UnlinkDevice"):
            // Unlinking the phone empties the account's device list, as observed.
            lock.withLock { devices = [:] }
            return HTTPResponse(status: 200)
        case ("POST", "/relayhub/negotiate"):
            guard let token = request.header("Authorization"), FakeDCG.deviceId(ofToken: String(token.dropFirst(7))) != nil else {
                return error(401, "Unauthorized", category: 1)
            }
            return json(["negotiateVersion": 0, "accessToken": "SERVICE", "availableTransports": [],
                         "url": "https://relay.service.signalr.net/client/?hub=dcgrelayhub_relayhub&asrs.op=%2Frelayhub&negotiateVersion=1&asrs_request_id=REQ"])
        default:
            return error(404, "NotFound", category: 0)
        }
    }

    /// Decodes a nonce JWT, checks its signature with the embedded certificate, and returns
    /// what the service would learn from it.
    static func proof(_ jwt: String) -> (nonce: String, deviceId: String, key: P384.Signing.PublicKey)? {
        let parts = jwt.split(separator: ".").map(String.init)
        guard parts.count == 3, let payload = Base64URL.decode(parts[1]),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let nonce = claims["Nonce"] as? String, let certificate = claims["Certificate"] as? String,
              let der = Data(base64Encoded: certificate), let info = try? DeviceCertificate.inspect(der: der),
              let name = info.commonName, claims["iss"] as? String == name,
              JWT.verifyES384(jwt, key: info.publicKey) != nil else { return nil }
        return (nonce, name, info.publicKey)
    }

    static func deviceId(ofToken token: String) -> String? {
        let parts = token.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, parts[0] == "dcg" else { return nil }
        let rest = String(parts[1])
        return rest.count > 37 ? String(rest.prefix(36)) : nil
    }
}

/// The Microsoft login endpoints for the device-code and refresh grants.
final class FakeMSA: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String: String]] = []
    var refreshCount = 0
    var accessToken = "msa-token"
    /// When set, refreshes fail with this OAuth error code.
    var refreshError: String?
    var calls: [[String: String]] { lock.withLock { _calls } }

    func handle(_ request: HTTPRequest) throws -> HTTPResponse {
        let fields = Dictionary(uniqueKeysWithValues: String(data: request.body ?? Data(), encoding: .utf8)!
            .split(separator: "&").map { pair -> (String, String) in
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding! }
                return (kv[0], kv.count > 1 ? kv[1] : "")
            })
        lock.withLock { _calls.append(fields) }
        func json(_ object: Any, status: Int = 200) -> HTTPResponse {
            HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
        }
        switch request.url.lastPathComponent {
        case "devicecode":
            return json(["device_code": "dc", "user_code": "ABCD1234", "verification_uri": "https://www.microsoft.com/link", "expires_in": 900, "interval": 1])
        case "token":
            if fields["grant_type"] == "refresh_token" {
                if let refreshError { return json(["error": refreshError, "error_description": "nope"], status: 400) }
                refreshCount += 1
                return json(["access_token": "\(accessToken)-r\(refreshCount)", "refresh_token": "refresh-\(refreshCount)", "expires_in": 3600, "token_type": "Bearer"])
            }
            return json(["access_token": accessToken, "refresh_token": "refresh-0", "expires_in": 3600, "token_type": "Bearer"])
        default:
            return HTTPResponse(status: 404)
        }
    }
}

/// Routes requests to the fake DCG or the fake MSA by host.
final class FakeServices: HTTPTransport, @unchecked Sendable {
    let dcg = FakeDCG()
    let msa = FakeMSA()

    /// How many of the next requests are lost on the way, as when a connection drops.
    var dropsNext = 0
    private(set) var dropped = 0

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if dropsNext > 0 {
            dropsNext -= 1
            dropped += 1
            throw URLError(.networkConnectionLost)
        }
        if request.url.host == "dcg.microsoft.com" { return try dcg.handle(request) }
        if request.url.host?.hasSuffix("microsoftonline.com") == true { return try msa.handle(request) }
        if request.url.host?.hasSuffix("service.signalr.net") == true, request.url.path == "/client/negotiate" {
            guard request.header("Authorization") == "Bearer SERVICE" else { return HTTPResponse(status: 401) }
            return HTTPResponse(status: 200, body: Data(#"{"negotiateVersion":1,"connectionId":"cid","connectionToken":"CTOKEN","availableTransports":[]}"#.utf8))
        }
        return HTTPResponse(status: 404)
    }
}
