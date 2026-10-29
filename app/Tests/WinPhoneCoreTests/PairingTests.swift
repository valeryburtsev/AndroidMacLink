import XCTest
@testable import WinPhoneCore

final class PairingTests: XCTestCase {
    func capturedResponses() throws -> [Data] {
        let array = try JSONSerialization.jsonObject(with: Data(contentsOf: Fixtures.url("pairing-qr.json"))) as! [[String: Any]]
        return try array.map { try JSONSerialization.data(withJSONObject: $0) }
    }

    func makeCoordinator(_ transport: MockTransport) -> PairingCoordinator {
        let client = DCGClient(instance: ClientInstance(logicalDeviceId: "x"), transport: transport)
        return PairingCoordinator(client: client, region: "PT", msaToken: { "msa" }, pollInterval: { _ in .zero }, sleep: { _ in })
    }

    /// Replays the service's real answers from the QR pairing captured on 2026-10-09.
    func testReplaysTheCapturedQRPairing() async throws {
        let transport = MockTransport()
        for body in try capturedResponses() { transport.enqueue(body: body) }
        let steps = StepRecorder()
        let final = try await makeCoordinator(transport).run(flow: .qrCode) { step, _ in await steps.append(step) }

        let recorded = await steps.steps
        XCTAssertEqual(recorded.count, 4, "repeated states are reported once")
        guard case .showLink(let link, let linkExpiry, let manual, let pin) = recorded[0] else { return XCTFail("\(recorded[0])") }
        XCTAssertTrue(link.hasPrefix("https://dcg.microsoft.com/dl?mvc="))
        XCTAssertNotNil(linkExpiry)
        XCTAssertEqual(manual, "aka.ms/PairPC")
        XCTAssertNil(pin)
        guard case .confirmChallengePIN(let challenge, let pinExpiry) = recorded[1] else { return XCTFail("\(recorded[1])") }
        XCTAssertEqual(challenge.count, 6)
        XCTAssertNotNil(pinExpiry)
        XCTAssertEqual(recorded[2], .approvePermissionsOnPhone)
        guard case .paired(let partner) = final else { return XCTFail("\(final)") }
        XCTAssertEqual(partner?.count, 36)
        XCTAssertEqual(recorded[3], final)

        // Wire behaviour: one create, six polls, and no Complete call in this flow.
        let requests = transport.requests
        XCTAssertEqual(requests.count, 7)
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertTrue(requests[0].url.path.hasSuffix("/DevicePairingProxy/PairingSessions"))
        XCTAssertEqual(requests[0].header("clientRegionName"), "PT")
        XCTAssertNil(requests[0].header("Dcg-Token"), "session creation carries only the account token")
        let created = try JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].body)) as! [String: Any]
        XCTAssertEqual(created["flow"] as? String, "QRLINK_CHALLENGEPIN_SIGNIN")
        XCTAssertEqual(created["optionalPermission"] as? [String], ["ALL"])
        for poll in requests.dropFirst() {
            XCTAssertEqual(poll.method, "GET")
            XCTAssertNil(poll.header("clientRegionName"))
            XCTAssertFalse(poll.url.path.hasSuffix("/Complete"))
        }
    }

    func testReadyForCompleteTriggersCompleteCall() async throws {
        let transport = MockTransport()
        transport.enqueue(json: #"{"pairingSessionId":"s1","state":"PENDING_PAIRING_PIN_VALIDATE","pairingPIN":"123456","pairingLinkForSignInPINFlow":"aka.ms/PairPC"}"#)
        transport.enqueue(json: #"{"pairingSessionId":"s1","state":"READY_FOR_COMPLETE"}"#)
        transport.enqueue(json: #"{"pairingSessionId":"s1","state":"DEVICE_PAIRED","partnerDcgClientId":"phone"}"#)
        let steps = StepRecorder()
        let final = try await makeCoordinator(transport).run(flow: .manual) { step, _ in await steps.append(step) }
        XCTAssertEqual(final, .paired(partnerDcgClientId: "phone"))
        let recorded = await steps.steps
        XCTAssertEqual(recorded, [.enterPairingPIN(pin: "123456", expires: nil), .completing, .paired(partnerDcgClientId: "phone")])
        XCTAssertEqual(transport.requests.map { "\($0.method) \($0.url.lastPathComponent)" }, ["POST PairingSessions", "GET s1", "POST Complete"])
        let created = try JSONSerialization.jsonObject(with: try XCTUnwrap(transport.requests[0].body)) as! [String: Any]
        XCTAssertEqual(created["flow"] as? String, "SIGNIN_PIN")
    }

    func testEveryServiceStateMapsToAStep() {
        for state in PairingServiceState.allCases {
            let response = PairingSessionResponse(pairingSessionId: "s", state: state.rawValue, pairingLink: "https://example/dl",
                                                  challengePIN: "ABCDEF", pairingPIN: "123456")
            if case .failed(.unknownState) = response.step { XCTFail("\(state) is unmapped") }
        }
        let failures: [(PairingServiceState, PairingFailure, Bool)] = [
            (.pairingAccountMismatched, .accountMismatch, false), (.pairingLinkExpired, .linkExpired, true),
            (.pairingPinExpired, .pinExpired, true), (.pairingSessionExpired, .sessionExpired, true),
            (.pairingRequiredPermissionDenied, .requiredPermissionDenied, false),
        ]
        for (state, failure, canRestart) in failures {
            XCTAssertEqual(PairingSessionResponse(pairingSessionId: "s", state: state.rawValue).step, .failed(failure))
            XCTAssertEqual(failure.canRestart, canRestart)
        }
        XCTAssertEqual(PairingSessionResponse(pairingSessionId: "s", state: "SOMETHING_NEW").step, .failed(.unknownState("SOMETHING_NEW")))
        XCTAssertEqual(PairingSessionResponse(pairingSessionId: "s", state: "CHALLENGE_PIN_EXPIRED").step, .challengePINProblem(expired: true))
        XCTAssertEqual(PairingSessionResponse(pairingSessionId: "s", state: "CHALLENGE_PIN_VALIDATE_FAILED").step, .challengePINProblem(expired: false))
    }

    func testServiceTimestampsParse() {
        let date = PairingSessionResponse.parseTime("2026-10-09T08:40:21.9599228+00:00")
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_791_535_221))
        XCTAssertNil(PairingSessionResponse.parseTime(nil))
        XCTAssertNil(PairingSessionResponse.parseTime("yesterday"))
    }

    func testFailureStopsPolling() async throws {
        let transport = MockTransport()
        transport.enqueue(json: #"{"pairingSessionId":"s1","state":"PENDING_PAIRING_LINK_VISIT","pairingLink":"https://dcg.microsoft.com/dl?x=1"}"#)
        transport.enqueue(json: #"{"pairingSessionId":"s1","state":"PAIRING_ACCOUNT_MISMATCHED"}"#)
        let final = try await makeCoordinator(transport).run { _, _ in }
        XCTAssertEqual(final, .failed(.accountMismatch))
        XCTAssertEqual(transport.requests.count, 2)
    }
}

actor StepRecorder {
    var steps: [PairingStep] = []
    func append(_ step: PairingStep) { steps.append(step) }
}

extension PairingSessionResponse {
    init(pairingSessionId: String, state: String, pairingLink: String? = nil, challengePIN: String? = nil, pairingPIN: String? = nil) {
        var object: [String: Any] = ["pairingSessionId": pairingSessionId, "state": state]
        if let pairingLink { object["pairingLink"] = pairingLink }
        if let challengePIN { object["challengePIN"] = challengePIN }
        if let pairingPIN { object["pairingPIN"] = pairingPIN }
        self = try! JSONDecoder().decode(PairingSessionResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
