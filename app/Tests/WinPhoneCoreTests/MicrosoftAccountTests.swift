import XCTest
@testable import WinPhoneCore

final class MicrosoftAccountTests: XCTestCase {
    let codeJSON = #"{"device_code":"DEV","user_code":"ABCD1234","verification_uri":"https://www.microsoft.com/link","expires_in":900,"interval":5,"message":"m"}"#
    let tokenJSON = #"{"token_type":"Bearer","scope":"https://dcg.microsoft.com/DCG.ReadWrite","expires_in":3600,"access_token":"AT","refresh_token":"RT"}"#

    func form(_ request: HTTPRequest) -> [String: String] {
        var out: [String: String] = [:]
        for pair in String(data: request.body ?? Data(), encoding: .utf8)!.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding! }
            out[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return out
    }

    func testDeviceCodeRequestUsesPhoneLinkClientAndDCGScope() async throws {
        let transport = MockTransport()
        transport.enqueue(json: codeJSON)
        let code = try await MicrosoftAccount(transport: transport).requestDeviceCode()
        XCTAssertEqual(code.userCode, "ABCD1234")
        XCTAssertEqual(code.verificationURI, "https://www.microsoft.com/link")
        let request = transport.requests[0]
        XCTAssertEqual(request.url.absoluteString, "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode")
        XCTAssertEqual(request.header("Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(form(request), ["client_id": "8CF55838-E496-42C5-829B-F8D6945288F3",
                                       "scope": "https://dcg.microsoft.com/DCG.ReadWrite offline_access"])
    }

    func testPollingHandlesPendingAndSlowDown() async throws {
        let transport = MockTransport()
        transport.enqueue(json: codeJSON)
        transport.enqueue(status: 400, json: #"{"error":"authorization_pending"}"#)
        transport.enqueue(status: 400, json: #"{"error":"slow_down"}"#)
        transport.enqueue(json: tokenJSON)
        let account = MicrosoftAccount(transport: transport)
        let code = try await account.requestDeviceCode()
        let sleeps = SleepRecorder()
        let tokens = try await account.waitForTokens(code, sleep: { await sleeps.add($0) })
        XCTAssertEqual(tokens.accessToken, "AT")
        XCTAssertEqual(tokens.refreshToken, "RT")
        let recorded = await sleeps.values
        XCTAssertEqual(recorded, [.seconds(5), .seconds(5), .seconds(10)], "slow_down adds five seconds")
        let poll = form(transport.requests[1])
        XCTAssertEqual(poll["grant_type"], "urn:ietf:params:oauth:grant-type:device_code")
        XCTAssertEqual(poll["device_code"], "DEV")
    }

    func testPollingStopsOnDeclineAndExpiry() async throws {
        for (error, expected) in [("authorization_declined", MicrosoftAccount.SignInError.declined), ("expired_token", .expired)] {
            let transport = MockTransport()
            transport.enqueue(json: codeJSON)
            transport.enqueue(status: 400, json: #"{"error":"\#(error)"}"#)
            let account = MicrosoftAccount(transport: transport)
            let code = try await account.requestDeviceCode()
            do {
                _ = try await account.waitForTokens(code, sleep: { _ in })
                XCTFail("expected \(expected)")
            } catch let thrown as MicrosoftAccount.SignInError {
                XCTAssertEqual(thrown, expected)
            }
        }
    }

    func testDeadlineEndsPolling() async throws {
        let transport = MockTransport()
        transport.enqueue(json: codeJSON)
        transport.handler = { _ in HTTPResponse(status: 400, body: Data(#"{"error":"authorization_pending"}"#.utf8)) }
        let account = MicrosoftAccount(transport: transport)
        let code = try await account.requestDeviceCode()
        let clock = FakeClock()
        do {
            _ = try await account.waitForTokens(code, sleep: { clock.advance($0) }, now: { clock.now })
            XCTFail("expected expiry")
        } catch let thrown as MicrosoftAccount.SignInError {
            XCTAssertEqual(thrown, .expired)
        }
        XCTAssertLessThanOrEqual(transport.requests.count, 182)
    }

    func testRefreshDistinguishesRevokedCredentials() async throws {
        let transport = MockTransport()
        transport.enqueue(json: tokenJSON)
        transport.enqueue(status: 400, json: #"{"error":"invalid_grant","error_description":"expired"}"#)
        let account = MicrosoftAccount(transport: transport)
        let tokens = try await account.refresh(refreshToken: "RT")
        XCTAssertEqual(tokens.accessToken, "AT")
        XCTAssertEqual(form(transport.requests[0])["grant_type"], "refresh_token")
        do {
            _ = try await account.refresh(refreshToken: "RT")
            XCTFail()
        } catch let thrown as MicrosoftAccount.SignInError {
            XCTAssertEqual(thrown, .reauthorizationRequired("invalid_grant"))
        }
    }

    func testFormEncodingEscapesReservedCharacters() {
        let body = String(data: MicrosoftAccount.formEncode(["scope": "https://a/b c+d&e=f"]), encoding: .utf8)
        XCTAssertEqual(body, "scope=https%3A%2F%2Fa%2Fb%20c%2Bd%26e%3Df")
    }
}

actor SleepRecorder {
    var values: [Duration] = []
    func add(_ value: Duration) { values.append(value) }
}

final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        current.addTimeInterval(TimeInterval(duration.components.seconds))
    }
}
