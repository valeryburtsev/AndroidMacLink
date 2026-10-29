import XCTest
@testable import WinPhoneCore

/// Our requests are compared with the ones Phone Link sent in the captures: same verb, path,
/// query, header names in the same order, and the same JSON body shape.
final class DCGClientTests: XCTestCase {
    struct Captured: Decodable {
        let client: String, method: String, path: String
        let query: [[String]]
        let headers: [String]
    }

    let instance = ClientInstance(logicalDeviceId: ClientInstance.logicalDeviceId(seed: Data([1, 2, 3])),
                                  sessionId: "11111111-2222-4333-8444-555555555555")

    func client(_ transport: HTTPTransport = MockTransport()) -> DCGClient {
        DCGClient(instance: instance, transport: transport)
    }

    func captured() throws -> [String: (Captured, Any?)] {
        let data = try Data(contentsOf: Fixtures.url("dcg-requests.json"))
        let typed = try JSONDecoder().decode([Captured].self, from: data)
        let raw = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        var out: [String: (Captured, Any?)] = [:]
        for (entry, object) in zip(typed, raw) {
            let body = object["body"]
            out["\(entry.method) \(entry.path)"] = (entry, body is NSNull ? nil : body)
        }
        return out
    }

    func testRequestsMatchPhoneLinkOnTheWire() throws {
        let c = client()
        let id = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let enroll = EnrollDeviceRequest(certificates: ["SelfSigned": ["QUJD"]], metadata: DeviceMetadata(profile: .phoneLink, displayName: "Mac"))
        let wake = WakeRequest.reconnect(targetDeviceId: id, hubRegion: "NorthEurope", cryptoWakeJwt: "jwt")
        let none = Optional<String>.none
        let ours: [String: HTTPRequest] = [
            "GET /EnvironmentDiscovery/UserServiceEnvironment": try c.makeRequest("GET", "EnvironmentDiscovery/UserServiceEnvironment", [("api-version", "1.0.0")], .msa("m"), body: none),
            "POST /Auth/GenerateNonce": try c.makeRequest("POST", "Auth/GenerateNonce", [("api-version", "1.1.0")], .msaIdentity("m"), body: GenerateNonceRequest(deviceId: id)),
            "POST /Auth/CreateIdentity": try c.makeRequest("POST", "Auth/CreateIdentity", [("api-version", "1.1.0")], .msaIdentity("m"), body: CertificateJWTRequest(certificateJWT: "j")),
            "POST /Auth/SignIn": try c.makeRequest("POST", "Auth/SignIn", [("api-version", "1.1.0")], .msaIdentity("m"), body: CertificateJWTRequest(certificateJWT: "j")),
            "PUT /Registration/Register": try c.makeRequest("PUT", "Registration/Register", [("api-version", "2.0.0")], .deviceToken("d"),
                                                             body: RegistrationRequest(applicationId: "PL", channelId: "c", channelType: "WNS", deviceId: id)),
            "POST /DeviceAuthProxy/EnrollDevice": try c.makeRequest("POST", "DeviceAuthProxy/EnrollDevice", [("api-version", "1.5.0"), ("pop-device-key", "")],
                                                                      .msaWithDeviceToken(msa: "m", dcg: "d"), body: enroll),
            "POST /DeviceAuthProxy/SetDeviceInfo": try c.makeRequest("POST", "DeviceAuthProxy/SetDeviceInfo", [("api-version", "1.5.0"), ("pop-device-key", "")],
                                                                       .msaWithDeviceToken(msa: "m", dcg: "d"), body: enroll),
            "GET /DeviceAuthProxy/GetDeviceInfoList": try c.makeRequest("GET", "DeviceAuthProxy/GetDeviceInfoList", [("api-version", "1.5.0"), ("filter", ""), ("top", "20")], .msa("m"), body: none),
            "GET /DeviceAuthProxy/GetAccountCert": try c.makeRequest("GET", "DeviceAuthProxy/GetAccountCert", [("api-version", "1.0.0")], .msa("m"), body: none),
            "POST /DeviceAuthProxy/UnlinkDevice": try c.makeRequest("POST", "DeviceAuthProxy/UnlinkDevice", [("api-version", "1.5.0"), ("device-id", id)],
                                                                      .msaWithDeviceToken(msa: "m", dcg: "d"), body: none),
            "POST /Dispatcher/Wake": try c.makeRequest("POST", "Dispatcher/Wake", [("api-version", "1.5.0")], .deviceToken("d"), body: wake),
            "GET /CloudRelay/Relay": try c.makeRequest("GET", "CloudRelay/Relay", [("api-version", "1.0.0"), ("isOnlyStun", "false")], .deviceToken("d"), body: none),
            "POST /DevicePairingProxy/PairingSessions": try c.makeRequest("POST", "DevicePairingProxy/PairingSessions", [("Api-Version", "3.0.0")], .msa("m"),
                                                                            body: CreatePairingSessionRequest(flow: "QRLINK_CHALLENGEPIN_SIGNIN", optionalPermission: ["ALL"]),
                                                                            extraHeaders: [("clientRegionName", "PT")]),
            "GET /DevicePairingProxy/PairingSessions/{id}": try c.makeRequest("GET", "DevicePairingProxy/PairingSessions/\(id)", [("Api-Version", "3.0.0")], .msa("m"), body: none),
        ]
        let reference = try captured()
        for (key, request) in ours {
            let (expected, expectedBody) = try XCTUnwrap(reference[key], "no capture for \(key)")
            XCTAssertEqual(request.method, expected.method, key)
            let components = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.host, "dcg.microsoft.com")
            XCTAssertEqual(components.path.replacingOccurrences(of: id, with: "{id}"), expected.path, key)
            let query = (components.queryItems ?? []).map { [$0.name, ($0.value ?? "").replacingOccurrences(of: id, with: "{id}")] }
            XCTAssertEqual(query, expected.query, "query of \(key)")
            XCTAssertEqual(request.headers.map(\.name), expected.headers, "header names and order of \(key)")
            if let expectedBody {
                let body = try JSONSerialization.jsonObject(with: try XCTUnwrap(request.body, key))
                XCTAssertEqual(jsonTypes(body) as? NSDictionary, expectedBody as? NSDictionary, "body shape of \(key)")
            } else {
                XCTAssertNil(request.body, key)
            }
        }
        // Every captured REST call except the relay negotiate (covered by the relay tests) is modelled.
        XCTAssertEqual(Set(reference.keys).subtracting(ours.keys), ["POST /relayhub/negotiate"])
    }

    func testCredentialsGoWhereTheWireShowsThem() throws {
        let c = client()
        let none = Optional<String>.none
        let identity = try c.makeRequest("POST", "Auth/SignIn", [], .msaIdentity("MSA"), body: none)
        XCTAssertEqual(identity.header("Authorization"), "Bearer MSA")
        XCTAssertEqual(identity.header("UserIdentityToken"), "MSA", "no Bearer prefix on the identity token")
        XCTAssertEqual(identity.header("UserIdentityType"), "MSA")
        let enroll = try c.makeRequest("POST", "DeviceAuthProxy/EnrollDevice", [], .msaWithDeviceToken(msa: "MSA", dcg: "DCG"), body: none)
        XCTAssertEqual(enroll.header("Dcg-Token"), "DCG")
        XCTAssertEqual(enroll.header("Authorization-Type"), "MSA")
        let device = try c.makeRequest("GET", "CloudRelay/Relay", [], .deviceToken("DCG"), body: none)
        XCTAssertEqual(device.header("Authorization"), "Bearer DCG")
        XCTAssertNil(device.header("Authorization-Type"))
        XCTAssertEqual(device.header("AuthorizationPortal"), "FirstPartyAppsRepo")
        XCTAssertEqual(device.header("DCG-AppId"), "Microsoft.YourPhone_8wekyb3d8bbwe")
        XCTAssertEqual(device.header("DCG-OS"), "Windows")
        let traceparent = try XCTUnwrap(device.header("traceparent"))
        XCTAssertNotNil(traceparent.range(of: #"^00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]$"#, options: .regularExpression))
        XCTAssertEqual(device.header("tracestate"), device.header("DCG-TraceState"))
        XCTAssertEqual(Data(base64Encoded: instance.logicalDeviceId)?.count, 32)
    }

    func testEnrollmentMetadataMatchesPhoneLink() throws {
        let metadata = DeviceMetadata(profile: .phoneLink, displayName: "Mac")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as! [String: Any]
        XCTAssertEqual(object["clientType"] as? String, "PL")
        XCTAssertEqual(object["osName"] as? String, "Windows")
        XCTAssertEqual(object["capabilities"] as? [String], ["FILE_TRANSFER_ONEDRIVE", "UNLINKABLE_V1", "UNLINKABLE_V2"])
        XCTAssertEqual(object["manufacture"] as? String, "Unknown")
        XCTAssertEqual(object["consentVersion"] as? Int, 0)
        XCTAssertEqual(object["isEnabled"] as? Bool, true)
    }

    func testServiceErrorsAreTyped() async throws {
        let transport = MockTransport()
        transport.enqueue(status: 403, json: #"{"error":{"code":"DeviceUnlinked","message":"The device has been unlinked.","categoryCode":13}}"#)
        transport.enqueue(status: 500, json: "oops")
        transport.enqueue(status: 200, json: "not json")
        let c = client(transport)
        do {
            _ = try await c.deviceInfoList(msaToken: "m")
            XCTFail("expected an error")
        } catch let error as DCGError {
            XCTAssertTrue(error.isDeviceUnlinked)
            XCTAssertEqual(error, .service(status: 403, code: "DeviceUnlinked", message: "The device has been unlinked.", categoryCode: 13))
        }
        do { _ = try await c.deviceInfoList(msaToken: "m"); XCTFail() } catch let error as DCGError { XCTAssertEqual(error, .http(status: 500)) }
        do { _ = try await c.deviceInfoList(msaToken: "m"); XCTFail() } catch let error as DCGError {
            guard case .malformedResponse = error else { return XCTFail("\(error)") }
        }
    }

    func testDeviceListDecodingAndPeerCertificateChoice() async throws {
        let transport = MockTransport()
        transport.enqueue(json: """
        [{"id":"p1","osName":"Android","clientType":"LTW","isLinked":true,"capabilities":["CLIPBOARD"],
          "customData":"{\\"platform\\":\\"1\\",\\"yppCapabilities\\":127}",
          "certificates":{"SelfSigned":["AQID"],"PKI":["BAUG"]}},
         {"id":"w1","osName":"Windows","clientType":"PL","certificates":{"SelfSigned":["AQID"]}}]
        """)
        let devices = try await client(transport).deviceInfoList(msaToken: "m")
        XCTAssertEqual(devices.count, 2)
        XCTAssertTrue(devices[0].isAndroid)
        XCTAssertFalse(devices[1].isAndroid)
        XCTAssertEqual(devices[0].yppCapabilities, 127)
        XCTAssertEqual(devices[0].preferredCertificate, Data([4, 5, 6]), "PKI wins over SelfSigned")
        XCTAssertEqual(devices[1].preferredCertificate, Data([1, 2, 3]))
        XCTAssertNil(devices[1].yppCapabilities)
    }
}
