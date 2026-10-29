import SwiftProtobuf
import XCTest
@testable import WinPhoneCore

final class DeviceStatusTests: XCTestCase {
    /// The phone's real status message from the capture, with the ten-character operator name
    /// replaced by a made-up one of the same length.
    static let phoneStatusHex = "0801122608511001200c2801320a" + Data("testnet 01".utf8).hex + "3804400450015804600168128001019001"+"01"
    /// The resource-manager wrapper around it, as the phone sent it.
    static let wrappedHex = "0a2a" + phoneStatusHex + "1001"

    func testParsesTheCapturedPhoneStatus() throws {
        let status = try XCTUnwrap(PhoneStatus(response: Data(hex: Self.phoneStatusHex)))
        XCTAssertEqual(status.batteryPercent, 81)
        XCTAssertTrue(status.isCharging)
        XCTAssertFalse(status.isPowerSaving)
        XCTAssertEqual(status.networkOperator, "testnet 01")
        XCTAssertEqual([status.signalBars, status.signalBarsMax], [4, 4])
        XCTAssertTrue(status.wifiEnabled)
        XCTAssertEqual(status.wifiLevel, 4)
        XCTAssertEqual(status.network, .wifi)
        XCTAssertFalse(status.airplaneMode)
        XCTAssertEqual(status.ringerMode, 1)
    }

    func testNonOKAndMalformedResponsesAreRejected() {
        XCTAssertNil(PhoneStatus(response: Data(hex: "0805")), "status SYNC_DISABLED")
        XCTAssertNil(PhoneStatus(response: Data(hex: "0801")), "OK without info")
        XCTAssertNil(PhoneStatus(response: Data([0xFF, 0xFF])))
    }

    /// Windows answers the phone's question about the PC with battery -1 and network type
    /// ETHERNET: `0801 120e 08 ff..01 8001 02`. Ours must be byte-identical for the same values.
    func testOwnStatusMatchesTheBytesWindowsSends() {
        XCTAssertEqual(DeviceStatusSync.OwnStatus(batteryPercent: nil, network: .ethernet).encoded().hex, "0801120e08ffffffffffffffffff01800102")
        let laptop = try? DeviceInfo_V1_DeviceStatusResponseMessage(serializedBytes: DeviceStatusSync.OwnStatus(batteryPercent: 64, isCharging: true).encoded())
        XCTAssertEqual(laptop?.info.batteryPercent, 64)
        XCTAssertEqual(laptop?.info.batteryCharging, true)
        XCTAssertEqual(laptop?.info.networkType, .wifi)
    }

    func testRefreshRequestMatchesTheWireAndUpdatesArrive() async throws {
        let phone = FakePhone()
        phone.responder = { $0.route == "/DeviceResourceManager" ? Data(hex: Self.wrappedHex) : nil }
        let (messenger, relay) = try await phone.connect()
        let resources = DeviceResources(messenger: messenger)
        await resources.start()
        let publisher = ContextPublisher(messenger: messenger, ownId: "11111111-1111-4111-8111-111111111111")
        await publisher.start()
        let sync = DeviceStatusSync(resources: resources, publisher: publisher) { .init(batteryPercent: nil, network: .ethernet) }
        await sync.start()

        let status = try await sync.refresh()
        XCTAssertEqual(status?.batteryPercent, 81)
        // The captured request: type UNKNOWN, GET, no payload field, path "/devicestatus".
        XCTAssertEqual(phone.received(route: "/DeviceResourceManager").first?.payload.hex, "08041001220d2f646576696365737461747573")

        // A publication with tag 8 carries the same message in `additional`.
        var changed = try DeviceInfo_V1_DeviceStatusResponseMessage(serializedBytes: Data(hex: Self.phoneStatusHex))
        changed.info.batteryPercent = 80
        changed.info.batteryCharging = false
        var payload = PlatformSdk_V1_PubSubPayload(); payload.additional = try changed.serializedData()
        var message = PlatformSdk_V1_MsaepMessage()
        message.messageTag = 8; message.dcgClientID = FakePhone.id; message.messageID = "s1"; message.payload = try payload.serializedData()
        phone.request(route: "/Context/Publish", payload: try message.serializedData())
        let updated = await waitUntil { await sync.latest?.batteryPercent == 80 }
        XCTAssertTrue(updated)
        var seen: [Int?] = []
        for await update in sync.updates {
            seen.append(update.batteryPercent)
            if seen.count == 2 { break }
        }
        XCTAssertEqual(seen, [81, 80])

        // The phone's real question about the PC, and our answer in Windows' form.
        let id = phone.request(route: "/DeviceResourceManager", payload: Data(hex: "0804100122132f72656d6f7465646576696365737461747573"))
        let answered = await waitUntil { phone.responses(to: id).count == 1 }
        XCTAssertTrue(answered)
        XCTAssertEqual(phone.responses(to: id)[0].payload.hex, "0a120801120e08ffffffffffffffffff018001021001",
                       "identical to the answer captured from Windows")
        await relay.close()
    }
}
