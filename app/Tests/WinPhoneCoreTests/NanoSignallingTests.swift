import SwiftProtobuf
import XCTest
@testable import WinPhoneCore

/// The relay half of receiving a file: the phone's announcement, the request for a direct
/// connection, and the whole path from announcement to saved bytes against scripted phones.
final class NanoSignallingTests: XCTestCase {
    static let ownId = "11111111-1111-4111-8111-111111111111"
    static let keyHex = "000102030405060708090a0b0c0d0e0f", saltHex = "101112131415161718191a1b1c1d"

    /// The phone's description of a direct connection, in the shape recorded from a real one.
    static func phoneDescription(port: String = "40123") -> String {
        """
        {"connectioninformation":{"security":{"key":"\(keyHex)","salt":"\(saltHex)"},"ip":{"0":{"addr":"10.20.30.40","iname":"rmnet5"},\
        "1":{"addr":"192.168.50.7","iname":"wlan0"},"count":"2"},"port":"\(port)","keepalive":{"warningtimeout":"5000"}},\
        "connectionid":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","connectiontype":0,"multipleconnections":true}
        """
    }

    func testThePhonesDescriptionIsUnderstood() throws {
        let contract = try XCTUnwrap(NanoDirectContract(connectionDescription: Self.phoneDescription()))
        XCTAssertEqual(contract.port, 40123, "the phone writes the port as text")
        XCTAssertEqual(contract.addresses.map(\.interface), ["rmnet5", "wlan0"])
        XCTAssertEqual(contract.candidates, ["192.168.50.7"], "Wi-Fi only: the mobile data address cannot be reached from here")
        XCTAssertEqual(contract.keys, try NanoSessionKeys(keyHex: Self.keyHex, saltHex: Self.saltHex))
        // Not a direct description, or one that lacks something: refused.
        XCTAssertNil(NanoDirectContract(connectionDescription: Self.phoneDescription().replacingOccurrences(of: "\"connectiontype\":0", with: "\"connectiontype\":1")))
        XCTAssertNil(NanoDirectContract(connectionDescription: Self.phoneDescription(port: "0")))
        XCTAssertNil(NanoDirectContract(connectionDescription: Self.phoneDescription(port: "700000")))
        XCTAssertNil(NanoDirectContract(connectionDescription: #"{"connectioninformation":{},"connectionid":"x","connectiontype":0,"multipleconnections":true}"#))
        XCTAssertNil(NanoDirectContract(connectionDescription: "not json"))
    }

    func testOurDescriptionIsTheOneWindowsSends() throws {
        XCTAssertEqual(NanoSignalling.directDescription(connectionId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"),
                       #"{"connectioninformation":{},"connectionid":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","connectiontype":0,"multipleconnections":true}"#)
        let fresh = NanoSignalling.directDescription()
        XCTAssertEqual(fresh.count, 128, "the length recorded from Windows")
        XCTAssertEqual(fresh, fresh.lowercased().replacingOccurrences(of: "true", with: "true"))
    }

    /// Wraps a context-source message the way the phone sends it: a request on the route that
    /// ends in the phone's own identifier.
    static func send(_ message: PlatformSdk_V1_ContextSourceMessage, from phone: FakePhone) {
        phone.request(route: "/Context/Message/" + FakePhone.id, payload: try! message.serializedData())
    }

    static func acknowledgement() -> PlatformSdk_V1_ContextSourceMessage {
        var ack = PlatformSdk_V1_CSInitializeAckMessage()
        ack.status = .success
        var message = PlatformSdk_V1_ContextSourceMessage()
        message.csInitializeAckMessage = ack
        return message
    }

    static func description(_ text: String) -> PlatformSdk_V1_ContextSourceMessage {
        var info = PlatformSdk_V1_CSConnectionInfo()
        info.connectionInfo = text
        var message = PlatformSdk_V1_ContextSourceMessage()
        message.csConnectionInfo = info
        return message
    }

    /// A relay-level phone that plays its part of the signalling when the PC starts it.
    static func signallingPhone(port: String = "40123") -> FakePhone {
        let phone = FakePhone()
        phone.responder = { [weak phone] envelope in
            guard let route = envelope.route, route.hasPrefix("/Context/Message"), let phone,
                  let message = try? PlatformSdk_V1_ContextSourceMessage(serializedBytes: envelope.payload) else { return nil }
            switch message.type {
            case .csInitializeMessage: send(acknowledgement(), from: phone)
            case .csConnectionInfo: send(description(phoneDescription(port: port)), from: phone)
            default: break
            }
            return Data(#"{"processStatus":"Success"}"#.utf8)
        }
        return phone
    }

    func testTheAnnouncementIsAcceptedAndTheConnectionRequestedAsWindowsDoes() async throws {
        let phone = Self.signallingPhone()
        let (messenger, relay) = try await phone.connect()
        let resources = DeviceResources(messenger: messenger)
        await resources.start()
        let signalling = NanoSignalling(messenger: messenger, resources: resources, ownId: Self.ownId, peerId: FakePhone.id)
        let announced = Announced()
        await signalling.start { id in await announced.set(id) }

        // The phone announces a share with a resource request.
        var announcement = FileTransfer_V1_NanoDelegateInitRequest()
        announcement.fileTransferSessionID = "0123456789abcdef0123456789abcdef"
        var request = PlatformSdk_V1_DeviceResourceManagerMessage()
        request.resourceType = .unknown
        request.requestType = .get
        request.resourcePath = "/fileshare_android2cdeh_phase1"
        request.payload = try announcement.serializedData()
        let id = phone.request(route: "/DeviceResourceManager", payload: try request.serializedData())
        let answered = await waitUntil { phone.responses(to: id).count == 1 }
        XCTAssertTrue(answered)
        let response = try PlatformSdk_V1_DeviceResourceManagerResponseMessage(serializedBytes: phone.responses(to: id)[0].payload)
        XCTAssertEqual(response.responseType, .success)
        let accepted = try FileTransfer_V1_NanoDelegateInitResponse(serializedBytes: response.payload)
        XCTAssertEqual(accepted.status, .ok)
        XCTAssertEqual(accepted.fileTransferSessionID, "0123456789abcdef0123456789abcdef")
        let told = await waitUntil { await announced.value == "0123456789abcdef0123456789abcdef" }
        XCTAssertTrue(told)

        // The request for a direct connection.
        let contract = try await signalling.requestDirectConnection(timeout: .seconds(3))
        XCTAssertEqual(contract.port, 40123)
        XCTAssertEqual(contract.candidates, ["192.168.50.7"])
        let sent = phone.received.filter { $0.route?.hasPrefix("/Context/Message") == true }
        XCTAssertEqual(sent.map(\.route), ["/Context/Message", "/Context/Message/" + Self.ownId], "the bare route first, then the one ending in our own identifier")
        let initialize = try PlatformSdk_V1_ContextSourceMessage(serializedBytes: sent[0].payload).csInitializeMessage
        XCTAssertEqual(initialize.contextSourceID, FakePhone.id, "names the phone")
        XCTAssertEqual(initialize.transportPreference, 0)
        XCTAssertTrue(initialize.hasTraceContext)
        let ours = try PlatformSdk_V1_ContextSourceMessage(serializedBytes: sent[1].payload).csConnectionInfo
        XCTAssertTrue(ours.connectionInfo.hasPrefix(#"{"connectioninformation":{},"connectionid":""#))
        XCTAssertTrue(ours.connectionInfo.hasSuffix(#""connectiontype":0,"multipleconnections":true}"#))
        // Each of the phone's messages was answered as Windows answers them.
        let acknowledgements = phone.received.filter { $0.originalRequestId != nil && $0.payload == Data(#"{"processStatus":"Success"}"#.utf8) }
        XCTAssertEqual(acknowledgements.count, 2)
        await relay.close()
    }

    func testAPhoneThatDoesNotAnswerTheRequestIsReported() async throws {
        let phone = FakePhone()
        phone.responder = { envelope in envelope.route?.hasPrefix("/Context/Message") == true ? Data(#"{"processStatus":"Success"}"#.utf8) : nil }
        let (messenger, relay) = try await phone.connect()
        let resources = DeviceResources(messenger: messenger)
        await resources.start()
        let signalling = NanoSignalling(messenger: messenger, resources: resources, ownId: Self.ownId, peerId: FakePhone.id)
        await signalling.start { _ in }
        do {
            _ = try await signalling.requestDirectConnection(timeout: .milliseconds(300))
            XCTFail("expected no answer")
        } catch let error as NanoSignalling.SignallingError {
            XCTAssertEqual(error, .noAnswer)
        }
        await relay.close()
    }

    /// From the announcement on the relay to the bytes of the file: both halves together.
    func testAShareAnnouncedOnTheRelayArrivesOverTheDirectConnection() async throws {
        let phone = Self.signallingPhone(port: "40999")
        let (messenger, relay) = try await phone.connect()
        let resources = DeviceResources(messenger: messenger)
        await resources.start()
        let signalling = NanoSignalling(messenger: messenger, resources: resources, ownId: Self.ownId, peerId: FakePhone.id)
        let file = ScriptedNanoPhone.File(id: "44444444-dddd", name: "Holiday plan.pdf", data: Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }))
        let keys = try NanoSessionKeys(keyHex: Self.keyHex, saltHex: Self.saltHex)
        let dialled = Dialled()
        var settings = NanoConnection.Settings()
        settings.fillerCount = 5
        let receiver = PhoneFileReceiver(signalling: signalling, senderName: "Test Mac", connectionSettings: settings) { host, port in
            await dialled.set("\(host):\(port)")
            let (mac, phoneSide) = MemoryNanoTransport.pair()
            let scripted = ScriptedNanoPhone(transport: phoneSide, keys: keys, files: [file])
            await scripted.run()
            await dialled.keep(scripted)
            return mac
        }
        await receiver.start()

        var announcement = FileTransfer_V1_NanoDelegateInitRequest()
        announcement.fileTransferSessionID = "feedfacefeedfacefeedfacefeedface"
        var request = PlatformSdk_V1_DeviceResourceManagerMessage()
        request.requestType = .get
        request.resourcePath = "/fileshare_android2cdeh_phase1"
        request.payload = try announcement.serializedData()
        phone.request(route: "/DeviceResourceManager", payload: try request.serializedData())

        var updates: [PhoneFileReceiver.Update] = []
        for await update in receiver.updates {
            if case .receiving = update { continue }
            updates.append(update)
            if case .finished = update { break }
            if case .failed = update { break }
        }
        XCTAssertEqual(updates, [.started, .offered(names: ["Holiday plan.pdf"], totalBytes: 20_000), .received(ReceivedFile(name: "Holiday plan.pdf", data: file.data)), .finished(count: 1)])
        let address = await dialled.value
        XCTAssertEqual(address, "192.168.50.7:40999", "the phone's Wi-Fi address and the port it named")
        await relay.close()
    }

    func testTheAnswerToAPhoneLinkHandshakeIsUnderstoodToo() throws {
        // The same parts, not wrapped: the phone's connection service adds its own keys beside them.
        let answer = """
        {"security":{"key":"\(Self.keyHex)","salt":"\(Self.saltHex)"},"ip":{"0":{"addr":"192.168.50.7","iname":"wlan0"},"count":"1"},"port":"41000",\
        "keepalive":{"warningtimeout":"5000"},"contractVersion":{"versionMin":6,"versionMax":6},"tbst":{}}
        """
        let contract = try XCTUnwrap(NanoDirectContract(connectionDescription: answer))
        XCTAssertEqual(contract.port, 41000)
        XCTAssertEqual(contract.candidates, ["192.168.50.7"])
        XCTAssertNil(NanoDirectContract(connectionDescription: #"{"contractVersion":{"versionMin":6,"versionMax":6}}"#))
    }

    func testThePhoneLinkHandshakeRequestIsAsThePhoneReadsIt() throws {
        let sender = AppSender(displayName: "Mac", installationId: "INSTALL")
        let request = PhoneFileReceiver.handshakeRequest(sender: sender, transferId: "feedface", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(request.string("contentType"), "nanoHandshake")
        XCTAssertEqual(request.string("workflow"), "fileTransfer")
        XCTAssertEqual(request.entries["sequenceNumber"], .int64(116_444_736_000_000_000), "a Windows file time as an Int64, or the phone's cast fails")
        XCTAssertEqual(request.string("correlationVector"), "feedface")
        XCTAssertEqual(request.bool("isuserinitiated"), true)
        XCTAssertEqual(request.double("contractVersion"), 3.99)
        let handshake = try XCTUnwrap(request.string("handshake"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(handshake.utf8)) as? [String: Any])
        XCTAssertEqual((object["contractVersion"] as? [String: Any])?["versionMax"] as? Int, 6)
        XCTAssertEqual((object["settings"] as? [String: Any])?["connectionType"] as? Int, 0, "a direct connection")
        XCTAssertEqual(object["multipleConnections"] as? Bool, true)
        XCTAssertEqual((object["instanceId"] as? String)?.count, 36)
    }

    /// An offer on the Phone Link session, from the content push to the bytes.
    func testAnOfferOnThePhoneLinkSessionArrivesOverTheDirectConnection() async throws {
        let phone = FakePhone()
        phone.responder = { envelope in
            guard envelope.route == "/nanohandshake" else { return nil }
            let handshake = #"{"security":{"key":"\#(Self.keyHex)","salt":"\#(Self.saltHex)"},"ip":{"0":{"addr":"192.168.50.7","iname":"wlan0"},"count":"1"},"port":"41000","keepalive":{"warningtimeout":"5000"},"contractVersion":{"versionMin":6,"versionMax":6}}"#
            return ValueSet(["result": .int32(0), "contractVersion": .double(3.99), "handshake": .string(handshake)]).serialized()
        }
        let (messenger, relay) = try await phone.connect()
        let file = ScriptedNanoPhone.File(id: "cccc-3", name: "Ticket.pdf", data: Data((0..<9000).map { UInt8(truncatingIfNeeded: $0 &* 3) }))
        let keys = try NanoSessionKeys(keyHex: Self.keyHex, saltHex: Self.saltHex)
        let dialled = Dialled()
        var settings = NanoConnection.Settings()
        settings.fillerCount = 5
        let receiver = PhoneFileReceiver(signalling: nil, senderName: "Test Mac", connectionSettings: settings) { host, port in
            await dialled.set("\(host):\(port)")
            let (mac, phoneSide) = MemoryNanoTransport.pair()
            let scripted = ScriptedNanoPhone(transport: phoneSide, keys: keys, files: [file])
            await scripted.setLegacy(true)
            await scripted.run()
            await dialled.keep(scripted)
            return mac
        }
        let offer = LegacyFileOffer(transferId: "0123456789abcdef0123456789abcdef", items: [.init(id: "cccc-3", name: "Ticket.pdf", size: 9000)])
        let sender = AppSender(displayName: "Mac", installationId: "INSTALL")
        Task { await receiver.receive(offer: offer, messenger: messenger, sender: sender) }
        var updates: [PhoneFileReceiver.Update] = []
        for await update in receiver.updates {
            if case .receiving = update { continue }
            updates.append(update)
            if case .finished = update { break }
            if case .failed = update { break }
        }
        XCTAssertEqual(updates, [.started, .offered(names: ["Ticket.pdf"], totalBytes: 9000), .received(ReceivedFile(name: "Ticket.pdf", data: file.data)), .finished(count: 1)])
        let address = await dialled.value
        XCTAssertEqual(address, "192.168.50.7:41000")
        let sent = try XCTUnwrap(phone.received(route: "/nanohandshake").first.flatMap { try? ValueSet(serialized: $0.payload) })
        XCTAssertEqual(sent.string("correlationVector"), "0123456789abcdef0123456789abcdef", "the transfer's own identifier")
        await relay.close()
    }

    actor Announced {
        var value: String?
        func set(_ value: String) { self.value = value }
    }

    actor Dialled {
        var value: String?
        var phone: ScriptedNanoPhone?
        func set(_ value: String) { self.value = value }
        func keep(_ phone: ScriptedNanoPhone) { self.phone = phone }
    }
}

final class FileProfileTests: XCTestCase {
    func testTheCrossDeviceClientAnnouncesFileTransferOnlyWhenAsked() {
        XCTAssertFalse(ClientProfile.crossDevice.receivesFiles)
        let accepting = ClientProfile.crossDevice.acceptingFiles
        XCTAssertTrue(accepting.receivesFiles)
        XCTAssertEqual(accepting.capabilities, ["DEVICE_STATUS", "UNLINKABLE_V1", "CLIPBOARD", "FILE_TRANSFER"])
        XCTAssertEqual(accepting.acceptingFiles.capabilities.count, 4, "asked twice, listed once")
        XCTAssertTrue(accepting.offersClipboard)
        XCTAssertFalse(ClientProfile.phoneLink.receivesFiles, "its own, older capability is a different one")
    }
}
