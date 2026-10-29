import SwiftProtobuf
import XCTest
@testable import WinPhoneCore

final class PlatformTests: XCTestCase {
    func testSessionValidationBytesMatchTheWire() {
        XCTAssertEqual(SessionValidation.requestPayload().hex, "0a0101")
        // The phone's real answer: capabilities [1, 2, 3], versions 14 and 3.
        let parsed = SessionValidation.parseResponse(Data(hex: "0a03010203100e1803"))
        XCTAssertEqual(parsed, .init(sessionValidation: true, persistentMessageChannelVersion: 14, nanoTransportPreferenceVersion: 3))
        XCTAssertNil(SessionValidation.parseResponse(Data()))
        XCTAssertEqual(SessionValidation.parseResponse(Data(hex: "0a0101")),
                       .init(sessionValidation: true, persistentMessageChannelVersion: nil, nanoTransportPreferenceVersion: nil))
    }

    func testSessionValidationExchange() async throws {
        let phone = FakePhone()
        phone.responder = { $0.route == "/SessionValidation" ? Data(hex: "0a03010203100e1803") : nil }
        let (messenger, relay) = try await phone.connect()
        let capabilities = try await SessionValidation.exchange(with: messenger)
        XCTAssertEqual(capabilities?.nanoTransportPreferenceVersion, 3)
        XCTAssertEqual(phone.received(route: "/SessionValidation").first?.payload.hex, "0a0101")
        await relay.close()
    }

    /// Our resource request must be byte-identical to the one Phone Link's companion sent
    /// (capture of 2026-10-09): type UNKNOWN, GET, the inner message, then the path.
    func testResourceRequestBytesMatchTheWire() async throws {
        let phone = FakePhone()
        phone.responder = { _ in Data(hex: "0a0210011001") }   // the phone's real "status OK" answer
        let (messenger, relay) = try await phone.connect()
        let resources = DeviceResources(messenger: messenger)
        var inner = Clipboard_V1_ClipboardRequestMessage()
        inner.requestType = .featureOff
        let payload = try await resources.request("/clipboard", payload: try inner.serializedData())
        XCTAssertEqual(phone.received(route: "/DeviceResourceManager").first?.payload.hex, "080410011a020803220a2f636c6970626f617264")
        XCTAssertEqual(payload.hex, "1001")
        XCTAssertEqual(try Clipboard_V1_ClipboardResponseMessage(serializedBytes: payload).status, .ok)
        await relay.close()
    }

    func testUnsupportedResourceIsReported() async throws {
        let phone = FakePhone()
        phone.responder = { _ in Data(hex: "1002") }   // response_type RESOURCE_HANDLER_NOT_REGISTERED
        let (messenger, relay) = try await phone.connect()
        do {
            _ = try await DeviceResources(messenger: messenger).request("/nope")
            XCTFail("expected failure")
        } catch let error as DeviceResources.ResourceError {
            XCTAssertEqual(error, .unsupportedResource("/nope"))
        }
        await relay.close()
    }

    func testIncomingResourceRequestsAreServedOrDeclined() async throws {
        let phone = FakePhone()
        let (messenger, relay) = try await phone.connect()
        let resources = DeviceResources(messenger: messenger)
        await resources.start()
        await resources.serve("/remotedevicestatus") { request in
            XCTAssertEqual(request.type, .get)
            XCTAssertEqual(request.query, "since=2")
            return Data([0x08, 0x01])
        }
        var served = PlatformSdk_V1_DeviceResourceManagerMessage()
        served.resourceType = .unknown; served.requestType = .get; served.resourcePath = "/remotedevicestatus?since=2"
        let servedId = phone.request(route: "/DeviceResourceManager", payload: try served.serializedData())
        var unknown = served
        unknown.resourcePath = "/wallpaper"
        let unknownId = phone.request(route: "/DeviceResourceManager", payload: try unknown.serializedData())

        let answered = await waitUntil { phone.responses(to: servedId).count == 1 && phone.responses(to: unknownId).count == 1 }
        XCTAssertTrue(answered)
        let ok = try PlatformSdk_V1_DeviceResourceManagerResponseMessage(serializedBytes: phone.responses(to: servedId)[0].payload)
        XCTAssertEqual(ok.responseType, .success)
        XCTAssertEqual(ok.payload, Data([0x08, 0x01]))
        let declined = try PlatformSdk_V1_DeviceResourceManagerResponseMessage(serializedBytes: phone.responses(to: unknownId)[0].payload)
        XCTAssertEqual(declined.responseType, .resourceHandlerNotRegistered)
        XCTAssertTrue(declined.payload.isEmpty)
        XCTAssertEqual(phone.responses(to: servedId)[0]["ms-content-type"], "application/x-binary")
        await relay.close()
    }

    func testPublishAndSubscribe() async throws {
        let phone = FakePhone()
        let (messenger, relay) = try await phone.connect()
        let ownId = "11111111-1111-4111-8111-111111111111"
        let publisher = ContextPublisher(messenger: messenger, ownId: ownId)
        await publisher.start()
        let seen = PublicationRecorder()
        await publisher.subscribe(.deviceStatus) { await seen.add($0) }

        // Outbound: the message goes in `data`, with our ID as publisher and versions 1.1.
        try await publisher.publish(.clipboard, body: Data([1, 2, 3]))
        let sent = try PlatformSdk_V1_MsaepMessage(serializedBytes: try XCTUnwrap(phone.received(route: "/Context/Publish").first).payload)
        XCTAssertEqual(sent.messageTag, 9)
        XCTAssertEqual(sent.dcgClientID, ownId)
        XCTAssertEqual(sent.messageID.count, 36)
        XCTAssertEqual([sent.platformMajorVersion, sent.platformMinorVersion], [1, 1])
        let sentPayload = try PlatformSdk_V1_PubSubPayload(serializedBytes: sent.payload)
        XCTAssertEqual(sentPayload.data, Data([1, 2, 3]))
        XCTAssertTrue(sentPayload.additional.isEmpty)

        // Inbound: the phone uses `additional`; a repeated message ID is dropped; each is acknowledged with {}.
        func publication(tag: Int32, id: String, additional: [UInt8]) throws -> Data {
            var payload = PlatformSdk_V1_PubSubPayload(); payload.additional = Data(additional)
            var message = PlatformSdk_V1_MsaepMessage()
            message.messageTag = tag; message.dcgClientID = FakePhone.id; message.messageID = id; message.payload = try payload.serializedData()
            return try message.serializedData()
        }
        let first = phone.request(route: "/Context/Publish", payload: try publication(tag: 8, id: "m1", additional: [7]))
        phone.request(route: "/Context/Publish", payload: try publication(tag: 8, id: "m1", additional: [7]))
        phone.request(route: "/Context/Publish", payload: try publication(tag: 8, id: "m2", additional: [8]))
        phone.request(route: "/Context/Publish", payload: try publication(tag: 4, id: "m3", additional: [9]))   // no subscriber
        let delivered = await waitUntil { await seen.items.count == 2 && phone.received(route: "/internal/response").count == 4 }
        XCTAssertTrue(delivered)
        let items = await seen.items
        XCTAssertEqual(items.map(\.body), [Data([7]), Data([8])])
        XCTAssertEqual(items.first?.publisher, FakePhone.id)
        let ack = try XCTUnwrap(phone.responses(to: first).first)
        XCTAssertEqual(ack.payload, Data("{}".utf8))
        XCTAssertEqual(ack["ms-content-type"], "text/json")
        await relay.close()
    }
}

actor PublicationRecorder {
    var items: [ContextPublisher.Publication] = []
    func add(_ item: ContextPublisher.Publication) { items.append(item) }
}

final class ClipboardSyncTests: XCTestCase {
    let ownId = "11111111-1111-4111-8111-111111111111"

    struct Rig {
        let phone: FakePhone
        let relay: RelayClient
        let sync: ClipboardSync
        let clipboard: TestClipboard
    }

    /// `phoneClip` is what the fake phone returns for a CONTENT request.
    func makeRig(local: ClipboardContent? = nil, phoneClip: ClipboardContent? = .text("from phone")) async throws -> Rig {
        let phone = FakePhone()
        phone.responder = { envelope in
            guard envelope.route == "/DeviceResourceManager",
                  let outer = try? PlatformSdk_V1_DeviceResourceManagerMessage(serializedBytes: envelope.payload),
                  let request = try? Clipboard_V1_ClipboardRequestMessage(serializedBytes: outer.payload) else { return nil }
            var response = Clipboard_V1_ClipboardResponseMessage()
            response.correlationID = request.correlationID
            switch request.requestType {
            case .content:
                if let phoneClip { response.status = .ok; response.clipboardItem = [phoneClip.item] }
                else { response.status = .invalidContent; response.errorType = .reject; response.errorDetail = "NoClipData" }
            case .status: response.status = .invalidClipboardRequestType     // this phone build rejects STATUS
            default: response.status = .ok
            }
            var wrapper = PlatformSdk_V1_DeviceResourceManagerResponseMessage()
            wrapper.payload = try! response.serializedData(); wrapper.responseType = .success
            return try! wrapper.serializedData()
        }
        let (messenger, relay) = try await phone.connect()
        let resources = DeviceResources(messenger: messenger)
        await resources.start()
        let publisher = ContextPublisher(messenger: messenger, ownId: ownId)
        await publisher.start()
        let clipboard = TestClipboard(local)
        let sync = ClipboardSync(resources: resources, publisher: publisher, local: clipboard)
        try await sync.start()
        return Rig(phone: phone, relay: relay, sync: sync, clipboard: clipboard)
    }

    func clipboardRequests(_ phone: FakePhone) -> [Clipboard_V1_ClipboardRequestMessage] {
        phone.received(route: "/DeviceResourceManager").compactMap {
            guard let outer = try? PlatformSdk_V1_DeviceResourceManagerMessage(serializedBytes: $0.payload) else { return nil }
            return try? Clipboard_V1_ClipboardRequestMessage(serializedBytes: outer.payload)
        }
    }

    func phoneRequest(_ phone: FakePhone, _ type: Clipboard_V1_ClipboardRequestType, correlation: String, drmType: PlatformSdk_V1_ProtoDeviceResourceRequestType = .get) throws -> String {
        var inner = Clipboard_V1_ClipboardRequestMessage(); inner.requestType = type; inner.correlationID = correlation
        var outer = PlatformSdk_V1_DeviceResourceManagerMessage()
        outer.resourceType = .unknown; outer.requestType = drmType; outer.payload = try inner.serializedData(); outer.resourcePath = "/clipboard"
        return phone.request(route: "/DeviceResourceManager", payload: try outer.serializedData())
    }

    func answer(_ phone: FakePhone, to id: String) async throws -> Clipboard_V1_ClipboardResponseMessage {
        let arrived = await waitUntil { phone.responses(to: id).count == 1 }
        XCTAssertTrue(arrived)
        let wrapper = try PlatformSdk_V1_DeviceResourceManagerResponseMessage(serializedBytes: phone.responses(to: id)[0].payload)
        XCTAssertEqual(wrapper.responseType, .success)
        return try Clipboard_V1_ClipboardResponseMessage(serializedBytes: wrapper.payload)
    }

    func testStartAnnouncesFeatureOn() async throws {
        let rig = try await makeRig()
        // Same bytes as the captured FEATURE_OFF request, with request type 2 instead of 3.
        XCTAssertEqual(rig.phone.received(route: "/DeviceResourceManager").first?.payload.hex, "080410011a020802220a2f636c6970626f617264")
        await rig.relay.close()
    }

    /// The phone's real STATUS question, byte for byte, and the shape of the real answer.
    func testAnswersTheCapturedStatusRequest() async throws {
        let rig = try await makeRig()
        let id = rig.phone.request(route: "/DeviceResourceManager",
                                   payload: Data(hex: "080410011a140805121064623666626238333536323832396136220a2f636c6970626f617264"))
        let arrived = await waitUntil { rig.phone.responses(to: id).count == 1 }
        XCTAssertTrue(arrived)
        // Captured Windows answer (feature off): 0a14 1009 1a10 <correlation> 1001. Ours says on: 1008.
        XCTAssertEqual(rig.phone.responses(to: id)[0].payload.hex, "0a1410081a10646236666262383335363238323961361001")
        try await rig.sync.setEnabled(false)
        let again = rig.phone.request(route: "/DeviceResourceManager",
                                      payload: Data(hex: "080410011a140805121064623666626238333536323832396136220a2f636c6970626f617264"))
        let second = await waitUntil { rig.phone.responses(to: again).count == 1 }
        XCTAssertTrue(second)
        XCTAssertEqual(rig.phone.responses(to: again)[0].payload.hex, "0a1410091a10646236666262383335363238323961361001",
                       "identical to the answer captured from Windows with the feature off")
        await rig.relay.close()
    }

    func testLocalCopyIsAnnouncedThenServedOnRequest() async throws {
        let rig = try await makeRig(local: .text("hello from mac"))
        try await rig.sync.localClipboardChanged()
        let publish = try XCTUnwrap(rig.phone.received(route: "/Context/Publish").first)
        let message = try PlatformSdk_V1_MsaepMessage(serializedBytes: publish.payload)
        XCTAssertEqual(message.messageTag, 9)
        XCTAssertEqual(message.dcgClientID, ownId)
        let body = try Clipboard_V1_ClipboardResponseMessage(serializedBytes: try PlatformSdk_V1_PubSubPayload(serializedBytes: message.payload).data)
        XCTAssertEqual(body.status, .clipboardChange)
        XCTAssertEqual(body.correlationID.count, 32)
        XCTAssertTrue(body.clipboardItem.isEmpty, "content is never pushed, only announced")

        // The phone then asks for the content with the announced correlation ID.
        let response = try await answer(rig.phone, to: try phoneRequest(rig.phone, .content, correlation: body.correlationID))
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.correlationID, body.correlationID)
        XCTAssertEqual(response.clipboardItem.count, 1)
        XCTAssertEqual(response.clipboardItem[0].itemType, .textPlain)
        XCTAssertEqual(response.clipboardItem[0].text, "hello from mac")
        XCTAssertTrue(response.clipboardItem[0].hasCreatedTime)

        // Announcing the same content again is pointless and is skipped.
        try await rig.sync.localClipboardChanged()
        XCTAssertEqual(rig.phone.received(route: "/Context/Publish").count, 1)
        await rig.relay.close()
    }

    func testContentTypesAndLimits() async throws {
        let rig = try await makeRig(local: .html("<b>x</b>"))
        var response = try await answer(rig.phone, to: try phoneRequest(rig.phone, .content, correlation: "c1"))
        XCTAssertEqual(response.clipboardItem.first?.itemType, .textHtml)
        XCTAssertEqual(response.clipboardItem.first?.text, "<b>x</b>")

        await rig.clipboard.set(.image(Data([0x89, 0x50, 0x4E, 0x47])))
        response = try await answer(rig.phone, to: try phoneRequest(rig.phone, .content, correlation: "c2"))
        XCTAssertEqual(response.clipboardItem.first?.itemType, .image)
        XCTAssertEqual(response.clipboardItem.first?.imageBytes, Data([0x89, 0x50, 0x4E, 0x47]))

        await rig.clipboard.set(.text(String(repeating: "x", count: ClipboardContent.maxTextUnits)))
        response = try await answer(rig.phone, to: try phoneRequest(rig.phone, .content, correlation: "c3"))
        XCTAssertEqual(response.status, .invalidContent)
        XCTAssertEqual(response.errorType, .reject)
        XCTAssertEqual(response.errorDetail, "SizeExceed")

        await rig.clipboard.set(.image(Data(count: ClipboardContent.maxImageBytes + 1)))
        try await rig.sync.localClipboardChanged()
        XCTAssertTrue(rig.phone.received(route: "/Context/Publish").isEmpty, "oversized content is not announced")

        await rig.clipboard.set(nil)
        response = try await answer(rig.phone, to: try phoneRequest(rig.phone, .content, correlation: "c4"))
        XCTAssertEqual(response.status, .invalidContent)
        XCTAssertEqual(response.errorDetail, "NoClipData")
        await rig.relay.close()
    }

    func testProtocolErrorsGetTheStatusCodesThePhoneUses() async throws {
        let rig = try await makeRig(local: .text("x"))
        var response = try await answer(rig.phone, to: try phoneRequest(rig.phone, .content, correlation: "c", drmType: .update))
        XCTAssertEqual(response.status, .invalidDeviceResourceRequestType)
        response = try await answer(rig.phone, to: try phoneRequest(rig.phone, .unspecified, correlation: "c9"))
        XCTAssertEqual(response.status, .invalidClipboardRequestType)
        XCTAssertEqual(response.correlationID, "c9")
        var outer = PlatformSdk_V1_DeviceResourceManagerMessage()
        outer.resourceType = .unknown; outer.requestType = .get; outer.payload = Data([0xFF, 0xFF, 0xFF]); outer.resourcePath = "/clipboard"
        response = try await answer(rig.phone, to: rig.phone.request(route: "/DeviceResourceManager", payload: try outer.serializedData()))
        XCTAssertEqual(response.status, .unrecognizedPayload)
        await rig.relay.close()
    }

    func testPhoneCopyIsPulledAndNotEchoedBack() async throws {
        let rig = try await makeRig(local: .text("old"), phoneClip: .text("from phone"))
        var change = Clipboard_V1_ClipboardResponseMessage()
        change.status = .clipboardChange; change.correlationID = "0123456789abcdef0123456789abcdef"
        var payload = PlatformSdk_V1_PubSubPayload(); payload.additional = try change.serializedData()
        var message = PlatformSdk_V1_MsaepMessage()
        message.messageTag = 9; message.dcgClientID = FakePhone.id; message.messageID = "m1"; message.payload = try payload.serializedData()
        rig.phone.request(route: "/Context/Publish", payload: try message.serializedData())

        let written = await waitUntil { await rig.clipboard.writes == [.text("from phone")] }
        XCTAssertTrue(written)
        let contentRequests = clipboardRequests(rig.phone).filter { $0.requestType == .content }
        XCTAssertEqual(contentRequests.map(\.correlationID), ["0123456789abcdef0123456789abcdef"], "the pull echoes the announced correlation ID")

        // The pasteboard change caused by that write must not be announced back to the phone.
        try await rig.sync.localClipboardChanged()
        XCTAssertTrue(rig.phone.received(route: "/Context/Publish").isEmpty)
        // A real local change afterwards is announced.
        await rig.clipboard.set(.text("typed on mac"))
        try await rig.sync.localClipboardChanged()
        XCTAssertEqual(rig.phone.received(route: "/Context/Publish").count, 1)
        await rig.relay.close()
    }

    func testPullFailuresAndPeerFeatureState() async throws {
        let rig = try await makeRig(phoneClip: nil)
        do {
            try await rig.sync.pull()
            XCTFail("expected refusal")
        } catch let error as ClipboardSync.SyncError {
            XCTAssertEqual(error, .refused(status: 7, detail: "NoClipData"))
        }
        let writes = await rig.clipboard.writes
        XCTAssertTrue(writes.isEmpty)

        // The phone can announce its feature state through a publication or a request.
        var off = Clipboard_V1_ClipboardResponseMessage(); off.status = .featureOff
        var payload = PlatformSdk_V1_PubSubPayload(); payload.additional = try off.serializedData()
        var message = PlatformSdk_V1_MsaepMessage()
        message.messageTag = 9; message.dcgClientID = FakePhone.id; message.messageID = "s1"; message.payload = try payload.serializedData()
        rig.phone.request(route: "/Context/Publish", payload: try message.serializedData())
        let sawOff = await waitUntil { await rig.sync.peerState == .off }
        XCTAssertTrue(sawOff)
        let response = try await answer(rig.phone, to: try phoneRequest(rig.phone, .featureOn, correlation: ""))
        XCTAssertEqual(response.status, .ok)
        let state = await rig.sync.peerState
        XCTAssertEqual(state, .on)
        await rig.relay.close()
    }

    func testDisabledSyncNeitherAnnouncesNorServes() async throws {
        let rig = try await makeRig(local: .text("secret"))
        try await rig.sync.setEnabled(false)
        XCTAssertEqual(clipboardRequests(rig.phone).map(\.requestType), [.featureOn, .featureOff])
        try await rig.sync.localClipboardChanged()
        XCTAssertTrue(rig.phone.received(route: "/Context/Publish").isEmpty)
        let response = try await answer(rig.phone, to: try phoneRequest(rig.phone, .content, correlation: "c"))
        XCTAssertEqual(response.status, .featureOff)
        XCTAssertTrue(response.clipboardItem.isEmpty)
        await rig.relay.close()
    }
}
