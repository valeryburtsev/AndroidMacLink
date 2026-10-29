import CryptoKit
import Security
import XCTest
@testable import WinPhoneCore

/// The hotspot request and its answer, against a phone played from its own code
/// (`protocol/specs/hotspot.md`). Names and passwords are made up.
final class InstantHotspotTests: XCTestCase {
    let ownId = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
    let mac = try! DeviceCertificate.generate(commonName: "trust_aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa")
    let phone = try! DeviceCertificate.generate(commonName: "trust_" + FakePhone.id)

    /// What the phone learns from a request, checking it as the phone does.
    func read(_ exchange: HotspotExchange) throws -> (type: SideChannel_V1_SideChannelHotspotRequestType, nonce: String, publicKey: Data?) {
        var buffer = exchange.request
        let message = try XCTUnwrap(try SideChannelFraming.take(from: &buffer))
        XCTAssertTrue(buffer.isEmpty, "one message, nothing after it")
        let request = try SideChannel_V1_SideChannelClientRequest(serializedBytes: message)
        XCTAssertEqual(request.context.traceID.count, 32)
        let token = try XCTUnwrap(JWT.verifyES384(request.authorization.signedJwtPayload, key: mac.privateKey.publicKey), "signed with the computer's trust key")
        XCTAssertEqual(token.claims["Scope"] as? String, "hotspot.request")
        XCTAssertEqual(token.claims["SourceId"] as? String, ownId)
        let data = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((token.claims["Data"] as? String ?? "").utf8)) as? [String: String])
        XCTAssertEqual(data["DCG-Environment"], "Prod")
        let nonce = try XCTUnwrap(data["nonce"])
        XCTAssertEqual(Data(base64Encoded: nonce)?.count, 128)
        return (request.hotspotRequest.type, nonce, data["publicKey"].flatMap { Data(base64Encoded: $0) })
    }

    /// The phone's answer with a name and password, encrypted to the key the request carried.
    func answer(nonce: String, publicKey: Data?, ssid: String = "Ada’s Galaxy", password: String = "correct horse", signer: DeviceCertificate? = nil,
                scope: String = "hotspot.response") throws -> Data {
        var response = SideChannel_V1_SideChannelServerResponse()
        response.ok = true
        response.hotspotResponse.status = .success
        response.hotspotResponse.reservation.status = .supported
        response.hotspotResponse.reservation.nonce = nonce
        if let publicKey {
            // The bare key is what follows the 24 bytes that name the algorithm.
            XCTAssertEqual(publicKey.prefix(24).map { String(format: "%02x", $0) }.joined(), "30820122300d06092a864886f70d01010105000382010f00")
            var error: Unmanaged<CFError>?
            let key = try XCTUnwrap(SecKeyCreateWithData(publicKey.dropFirst(24) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &error))
            let sealed = try XCTUnwrap(SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA256, Data((ssid + password).utf8) as CFData, &error) as Data?)
            let data = DeviceTokens.wakeDataText([("encryptedCredentials", sealed.base64EncodedString()), ("encryptedSsidLength", String(ssid.utf16.count))])
            response.authorization.signedJwtPayload = try DeviceTokens.trustJWT(scope: scope, data: data, sourceId: FakePhone.id, trust: signer ?? phone)
            response.hotspotResponse.type = .credentials
        } else {
            response.hotspotResponse.type = .capableStatus
        }
        var message = SideChannel_V1_SideChannelServerMessage()
        message.requestResponse = response
        return try message.serializedData()
    }

    func testMessagesAreFramedByTheirLength() throws {
        let short = Data([1, 2, 3]), long = Data((0..<300).map { UInt8(truncatingIfNeeded: $0) })
        XCTAssertEqual([UInt8](SideChannelFraming.frame(short)), [3, 1, 2, 3])
        XCTAssertEqual([UInt8](SideChannelFraming.frame(long).prefix(2)), [0xAC, 0x02], "300 as a varint")
        // Arriving in pieces, and two in one piece.
        var buffer = Data()
        let stream = SideChannelFraming.frame(long) + SideChannelFraming.frame(short)
        buffer.append(stream.prefix(1))
        XCTAssertNil(try SideChannelFraming.take(from: &buffer))
        buffer.append(stream.dropFirst(1).prefix(150))
        XCTAssertNil(try SideChannelFraming.take(from: &buffer))
        buffer.append(stream.dropFirst(151))
        XCTAssertEqual(try SideChannelFraming.take(from: &buffer), long)
        XCTAssertEqual(try SideChannelFraming.take(from: &buffer), short)
        XCTAssertNil(try SideChannelFraming.take(from: &buffer))
        var absurd = Data([0xFF, 0xFF, 0xFF, 0xFF, 0x7F])
        XCTAssertThrowsError(try SideChannelFraming.take(from: &absurd))
    }

    func testThePlainQuestionNeedsNoSignatureAndItsAnswerNamesTheServices() throws {
        var framed = SideChannelCapabilities.request
        let message = try XCTUnwrap(try SideChannelFraming.take(from: &framed))
        let request = try SideChannel_V1_SideChannelClientRequest(serializedBytes: message)
        XCTAssertNotNil(request.request.flatMap { if case .capabilityRequest = $0 { return true } else { return nil } })
        XCTAssertFalse(request.hasAuthorization, "nothing is signed")

        var answer = SideChannel_V1_SideChannelServerMessage()
        answer.requestResponse.ok = true
        answer.requestResponse.capabilityResponse.capabilities = [.wake, .hotspot]
        XCTAssertEqual(try SideChannelCapabilities.services(in: answer.serializedData()), [1, 2])
        answer.requestResponse.ok = false
        XCTAssertThrowsError(try SideChannelCapabilities.services(in: answer.serializedData()))
    }

    func testThePhoneAppsOwnBluetoothPermissionIsItsTypeTwentySix() {
        // A type's bit is its number less one: 7 is the notification listener (64), 32 the
        // sensitive notifications (the top bit), 26 Bluetooth.
        XCTAssertEqual(NotificationSync.notificationPermission, 1 << (7 - 1))
        XCTAssertEqual(NotificationSync.sensitiveNotificationPermission, Int32(truncatingIfNeeded: 1 << (32 - 1)))
        XCTAssertEqual(NotificationSync.bluetoothPermission, 1 << (26 - 1))
    }

    func testTheHotspotIsAskedForAndItsNameAndPasswordComeBack() throws {
        let exchange = try HotspotExchange(kind: .credentials, ownId: ownId, trust: mac, phoneCertificate: phone.der)
        let request = try read(exchange)
        XCTAssertEqual(request.type, .credentials)
        let key = try XCTUnwrap(request.publicKey, "a key for the phone to encrypt to")
        let reply = try exchange.answer(try answer(nonce: request.nonce, publicKey: key))
        XCTAssertEqual(reply, .credentials(HotspotCredentials(ssid: "Ada’s Galaxy", password: "correct horse")), "the name ends where the phone says, counted its way")
        // Every request has its own nonce and its own key.
        let again = try read(try HotspotExchange(kind: .credentials, ownId: ownId, trust: mac, phoneCertificate: phone.der))
        XCTAssertNotEqual(again.nonce, request.nonce)
        XCTAssertNotEqual(again.publicKey, key)
    }

    func testAskingWhetherThePhoneCouldSwitchesNothingOn() throws {
        let exchange = try HotspotExchange(kind: .status, ownId: ownId, trust: mac, phoneCertificate: phone.der)
        let request = try read(exchange)
        XCTAssertEqual(request.type, .capableStatus)
        XCTAssertNil(request.publicKey)
        XCTAssertEqual(try exchange.answer(try answer(nonce: request.nonce, publicKey: nil)), .capable)
    }

    func testAnAnswerThatIsNotThePhonesOrNotToThisRequestIsTurnedDown() throws {
        let exchange = try HotspotExchange(kind: .credentials, ownId: ownId, trust: mac, phoneCertificate: phone.der)
        let request = try read(exchange)
        let key = try XCTUnwrap(request.publicKey)
        func refused(_ message: Data, _ expected: HotspotError, _ why: String) {
            XCTAssertThrowsError(try exchange.answer(message), why) { XCTAssertEqual($0 as? HotspotError, expected, why) }
        }
        refused(try answer(nonce: "another", publicKey: key), .forged, "the nonce of another request")
        let stranger = try DeviceCertificate.generate(commonName: "trust_" + FakePhone.id)
        refused(try answer(nonce: request.nonce, publicKey: key, signer: stranger), .forged, "signed by someone with the phone's name")
        refused(try answer(nonce: request.nonce, publicKey: key, scope: "wake"), .forged, "a token for something else")
        // Encrypted to another key: it does not open.
        let other = try HotspotKey()
        refused(try answer(nonce: request.nonce, publicKey: other.publicKeyInfo), .forged, "not encrypted to this request's key")
        refused(try answer(nonce: request.nonce, publicKey: key, password: "short"), .implausible, "no Wi-Fi password is that short")
        refused(Data([9, 9, 9]), .malformed, "not a message at all")
    }

    func testThePhonesReasonsForNotSharingAreTold() throws {
        let exchange = try HotspotExchange(kind: .credentials, ownId: ownId, trust: mac, phoneCertificate: phone.der)
        let nonce = try read(exchange).nonce
        func failing(_ change: (inout SideChannel_V1_SideChannelServerResponse) -> Void) throws -> Data {
            var response = SideChannel_V1_SideChannelServerResponse()
            response.ok = false
            response.error.type = .scenarioServiceError
            response.hotspotResponse.reservation.nonce = nonce
            change(&response)
            var message = SideChannel_V1_SideChannelServerMessage()
            message.requestResponse = response
            return try message.serializedData()
        }
        XCTAssertThrowsError(try exchange.answer(try failing { $0.hotspotResponse.status = .notHotspotCapable; $0.hotspotResponse.reservation.status = .dataSaverIsEnabled })) {
            XCTAssertEqual($0 as? HotspotError, .notCapable(.dataSaver))
        }
        XCTAssertThrowsError(try exchange.answer(try failing { $0.hotspotResponse.status = .untrusted })) { XCTAssertEqual($0 as? HotspotError, .untrusted) }
        XCTAssertThrowsError(try exchange.answer(try failing { $0.error.type = .cryptoTrustTimeout; $0.hotspotResponse.status = .errorOther })) {
            XCTAssertEqual($0 as? HotspotError, .refused(status: 2, error: 7))
        }
        XCTAssertFalse(HotspotObstacle.passwordNotSet.explanation.isEmpty)
        XCTAssertTrue(HotspotReadiness(consent: true, channelOpen: true).isReady)
        XCTAssertFalse(HotspotReadiness(consent: true, channelOpen: false).isReady)
    }

    /// Whether the phone is set up for it comes with its status, and again when its user answers.
    func testThePhonesWordOnItsSetUpIsKept() {
        var status = PhoneStatus()
        XCTAssertNil(status.hotspot, "nothing said yet")
        XCTAssertFalse(status.applyHotspot(ValueSet(["batteryPercent": .int32(50)])))
        XCTAssertTrue(status.applyHotspot(ValueSet(["hotspotUserConsent": .bool(false), "oemBluetoothRfcommServerOpen": .bool(false)])))
        XCTAssertEqual(status.hotspot, HotspotReadiness(consent: false, channelOpen: false))
        // The user said yes on the phone: the two come one after the other.
        XCTAssertTrue(status.applyHotspot(ValueSet(["hotspotUserConsent": .bool(true)])))
        XCTAssertEqual(status.hotspot, HotspotReadiness(consent: true, channelOpen: false))
        XCTAssertTrue(status.applyHotspot(ValueSet(["oemBluetoothRfcommServerOpen": .bool(true)])))
        XCTAssertEqual(status.hotspot?.isReady, true)
        // A full status push carries them along with the rest.
        let pushed = PhoneStatus(push: ValueSet(["batteryPercent": .int32(80), "ringerMode": .int32(2), "hotspotUserConsent": .bool(true), "oemBluetoothRfcommServerOpen": .bool(true)]))
        XCTAssertEqual(pushed?.hotspot?.isReady, true)
        XCTAssertNil(PhoneStatus(push: ValueSet(["batteryPercent": .int32(80), "ringerMode": .int32(2)]))?.hotspot)
    }

    /// The phone reads the contract version of every such request first and answers none
    /// without it: the set-up request carries the fields all of them carry.
    func testTheSetUpRequestCarriesWhatThePhoneReadsFirst() {
        let request = LinkController.hotspotSetupRequest(from: AppSender(displayName: "Mac", installationId: "i"))
        XCTAssertEqual(request.bool("isuserinitiated"), true)
        XCTAssertNotNil(request.entries["contractVersion"])
        XCTAssertNotNil(request.string("correlationVector"))
        XCTAssertNil(request.entries["contentType"], "no content type: this is no content request")
    }
}
