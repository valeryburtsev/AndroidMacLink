import SwiftProtobuf
import XCTest
@testable import WinPhoneCore

/// Ring my phone, ringer mode, Do Not Disturb and the media keys. None of these requests was
/// captured from Windows, so the tests pin the messages to the specification
/// (`protocol/specs/device-controls.md`), which follows the phone's handlers.
final class DeviceControlsTests: XCTestCase {
    static let sender = AppSender(displayName: "Mac", installationId: "INSTALL")

    /// Wraps a resource answer the way the phone does.
    static func resourceAnswer(_ payload: Data, handled: Bool = true) -> Data {
        var response = PlatformSdk_V1_DeviceResourceManagerResponseMessage()
        response.responseType = handled ? .success : .resourceHandlerNotRegistered
        response.payload = payload
        return try! response.serializedData()
    }

    static func statusAnswer(_ status: DeviceInfo_V1_DeviceStatusResponseStatus, ringer: Int32 = 2, doNotDisturb: Int32 = 1,
                             ruleEnabled: Bool? = nil, info: Bool = true) -> Data {
        var message = DeviceInfo_V1_DeviceStatusResponseMessage()
        message.status = status
        if info {
            message.info.batteryPercent = 50
            message.info.ringerMode = ringer
            message.info.doNotDisturbStatus = doNotDisturb
            if let ruleEnabled { message.info.doNotDisturbRuleEnabled = ruleEnabled }
        }
        return try! message.serializedData()
    }

    func resources(_ phone: FakePhone) async throws -> (DeviceResources, PeerMessenger) {
        let (messenger, _) = try await phone.connect()
        let resources = DeviceResources(messenger: messenger)
        await resources.start()
        return (resources, messenger)
    }

    // MARK: Ring

    func testRingRequestsAreTheTwoBytesOfTheSchema() {
        XCTAssertEqual(DeviceControls.ringRequest(on: true).hex, "0801")
        XCTAssertEqual(DeviceControls.ringRequest(on: false).hex, "0802")
    }

    func testRingIsAnUpdateOnTheRingPath() async throws {
        let phone = FakePhone()
        phone.responder = { _ in Self.resourceAnswer(Data(hex: "0801")) }
        let (resources, _) = try await resources(phone)
        try await DeviceControls.ring(true, through: resources)
        try await DeviceControls.ring(false, through: resources)
        let sent = try phone.received(route: DeviceResources.route).map { try PlatformSdk_V1_DeviceResourceManagerMessage(serializedBytes: $0.payload) }
        XCTAssertEqual(sent.map(\.resourcePath), ["/ringmyphone", "/ringmyphone"])
        XCTAssertEqual(sent.map(\.requestType), [.update, .update])
        XCTAssertEqual(sent.map(\.payload.hex), ["0801", "0802"])
    }

    func testRingFailuresAreToldApart() async throws {
        let answers: [(Data, PhoneControlError)] = [
            (Self.resourceAnswer(Data(), handled: false), .unsupported),
            (Self.resourceAnswer(Data(hex: "0802")), .unsupported),
            (Self.resourceAnswer(Data(hex: "0804")), .failed(4)),
            (Self.resourceAnswer(Data()), .failed(0)),
        ]
        for (answer, expected) in answers {
            let phone = FakePhone()
            phone.responder = { _ in answer }
            let (resources, _) = try await resources(phone)
            do {
                try await DeviceControls.ring(true, through: resources)
                XCTFail("expected \(expected)")
            } catch let error as PhoneControlError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    // MARK: Ringer and Do Not Disturb, protobuf form

    func testStatusSettingsEncodeAsTheSchemaSays() {
        XCTAssertEqual(DeviceStatusSync.Setting.doNotDisturb(true).encoded().hex, "0802")
        XCTAssertEqual(DeviceStatusSync.Setting.doNotDisturb(false).encoded().hex, "0803")
        XCTAssertEqual(DeviceStatusSync.Setting.ringer(.normal).encoded().hex, "0804")
        XCTAssertEqual(DeviceStatusSync.Setting.ringer(.vibrate).encoded().hex, "0805")
        XCTAssertEqual(DeviceStatusSync.Setting.ringer(.silent).encoded().hex, "0806")
    }

    func statusSync(_ phone: FakePhone) async throws -> DeviceStatusSync {
        let (resources, messenger) = try await resources(phone)
        let publisher = ContextPublisher(messenger: messenger, ownId: "11111111-1111-4111-8111-111111111111")
        return DeviceStatusSync(resources: resources, publisher: publisher)
    }

    func testASettingAppliesTheStateTheAnswerCarries() async throws {
        let phone = FakePhone()
        phone.responder = { _ in Self.resourceAnswer(Self.statusAnswer(.ok, ringer: 0)) }
        let sync = try await statusSync(phone)
        let status = try await sync.apply(.ringer(.silent))
        XCTAssertEqual(status?.ringer, .silent)
        let latest = await sync.latest
        XCTAssertEqual(latest?.ringer, .silent, "the answer is the new state; no further report is needed")
        let sent = try PlatformSdk_V1_DeviceResourceManagerMessage(serializedBytes: try XCTUnwrap(phone.received(route: DeviceResources.route).first).payload)
        XCTAssertEqual(sent.resourcePath, "/devicestatus")
        XCTAssertEqual(sent.requestType, .update)
        XCTAssertEqual(sent.payload.hex, "0806")
    }

    func testSettingFailuresAreToldApart() async throws {
        let cases: [(Data, DeviceStatusSync.Setting, PhoneControlError)] = [
            (Self.resourceAnswer(Self.statusAnswer(.needsPermission)), .doNotDisturb(true), .needsPermission),
            (Self.resourceAnswer(Self.statusAnswer(.syncDisabled, info: false)), .ringer(.normal), .syncDisabled),
            (Self.resourceAnswer(Self.statusAnswer(.featureNotSupported, ruleEnabled: false)), .doNotDisturb(true), .ruleDisabled),
            (Self.resourceAnswer(Self.statusAnswer(.featureNotSupported)), .ringer(.silent), .unsupported),
            (Self.resourceAnswer(Self.statusAnswer(.invalidRequestType)), .ringer(.silent), .failed(8)),
            (Self.resourceAnswer(Data(), handled: false), .ringer(.silent), .unsupported),
        ]
        for (answer, setting, expected) in cases {
            let phone = FakePhone()
            phone.responder = { _ in answer }
            let sync = try await statusSync(phone)
            do {
                try await sync.apply(setting)
                XCTFail("expected \(expected)")
            } catch let error as PhoneControlError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testASilentPhoneIsNotWaitedForLong() async throws {
        let phone = FakePhone()   // answers nothing, as when the phone's handler fails
        let sync = try await statusSync(phone)
        let start = ContinuousClock.now
        do {
            try await sync.apply(.ringer(.silent), timeout: .milliseconds(150))
            XCTFail("expected no answer")
        } catch let error as PhoneControlError {
            XCTAssertEqual(error, .noAnswer, "which lets the caller try the command Phone Link sends")
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testStatusSaysWhatCanBeChanged() throws {
        func status(_ change: (inout DeviceInfo_V1_DeviceStatus) -> Void) throws -> PhoneStatus {
            var message = DeviceInfo_V1_DeviceStatusResponseMessage()
            message.status = .ok
            message.info.batteryPercent = 50
            change(&message.info)
            return try XCTUnwrap(PhoneStatus(response: try message.serializedData()))
        }
        let plain = try status { $0.ringerMode = 2; $0.doNotDisturbStatus = 1 }
        XCTAssertTrue(plain.canSetRinger)
        XCTAssertTrue(plain.canSetDoNotDisturb, "a phone that does not report the rule reads as enabled")
        XCTAssertTrue(plain.doNotDisturbRuleEnabled)
        let slider = try status { $0.ringerMode = -5; $0.doNotDisturbStatus = 2 }
        XCTAssertFalse(slider.canSetRinger, "a phone with a hardware slider reports -5")
        XCTAssertTrue(slider.isDoNotDisturbOn)
        let ruleOff = try status { $0.ringerMode = 1; $0.doNotDisturbStatus = 1; $0.doNotDisturbRuleEnabled = false }
        XCTAssertFalse(ruleOff.canSetDoNotDisturb)
        let unknown = try status { $0.doNotDisturbStatus = 0; $0.doNotDisturbRuleEnabled = true }
        XCTAssertFalse(unknown.canSetDoNotDisturb)
    }

    func testEveryPushCarriesTheStatusAndTheDeviceStatusPushIsAnswered() async throws {
        let push = ValueSet(["contentType": .string("deviceStatus"), "batteryPercent": .int32(64), "batteryCharging": .bool(true),
                             "batteryPowerSave": .bool(false), "networkOperator": .string("testnet"), "networkSignalStrength": .int32(3),
                             "networkSignalStrengthMax": .int32(4), "wifiState": .bool(true), "wifiSignalLevel": .int32(2), "airplaneMode": .bool(false),
                             "ringerMode": .int32(0), "doNotDisturbStatus": .int32(2), "doNotDisturbRuleEnabled": .bool(true)])
        let status = try XCTUnwrap(PhoneStatus(push: push, base: PhoneStatus(network: .wifi)))
        XCTAssertEqual(status.batteryPercent, 64)
        XCTAssertTrue(status.isCharging)
        XCTAssertEqual(status.ringer, .silent)
        XCTAssertTrue(status.isDoNotDisturbOn)
        XCTAssertEqual(status.network, .wifi, "what the push does not say is kept")
        XCTAssertNil(PhoneStatus(push: ValueSet(["contentType": .string("notifications")])), "a message without the status keys is not a status")

        let phone = FakePhone()
        let (messenger, relay) = try await phone.connect()
        let sync = NotificationSync(messenger: messenger, displayName: "Mac", installationId: "INSTALL")
        await sync.start()
        // The phone's APP push, as it frames it.
        func deliver(_ values: ValueSet) -> String {
            let id = UUID().uuidString.lowercased()
            phone.deliver(PlatformEnvelope(headers: [("_requestId", id), ("_route", "/legacy/phonecontent")], payload: values.serialized(), convention: .android), type: .app)
            return id
        }
        let first = deliver(push)
        let answered = await waitUntil { phone.responses(to: first).count == 1 }
        XCTAssertTrue(answered)
        XCTAssertEqual((try? ValueSet(serialized: phone.responses(to: first)[0].payload))?.int("result"), 0, "as Phone Link answers")
        // The same status again is not reported twice; a change is.
        _ = deliver(push)
        var changed = push
        changed["ringerMode"] = .int32(2)
        let last = deliver(changed)
        _ = await waitUntil { phone.responses(to: last).count == 1 }
        var reports: [Int?] = []
        for await change in sync.changes {
            if case .statusReported(let values) = change { reports.append(values.int("ringerMode")) }
            if reports.count == 2 { break }
        }
        XCTAssertEqual(reports, [0, 2])
        await relay.close()
    }

    // MARK: Value-set commands

    func testStatusCommandCarriesTypeAndValueAsInt32() throws {
        let controls = DeviceControls(sender: Self.sender)
        let ringer = controls.statusCommand(.ringer, value: PhoneStatus.Ringer.vibrate.androidMode)
        XCTAssertEqual(ringer.string("contentType"), "deviceStatusCommand")
        XCTAssertEqual(ringer.entries["deviceStatusCommandType"], .int32(3))
        XCTAssertEqual(ringer.entries["deviceStatusCommandValue"], .int32(1))
        XCTAssertEqual(ringer.entries["contractVersion"], .double(3.99), "the phone reads it with an unchecked cast")
        XCTAssertEqual(ringer.entries["isuserinitiated"], .bool(true))
        XCTAssertEqual([PhoneStatus.Ringer.silent, .vibrate, .normal].map(\.androidMode), [0, 1, 2])
    }

    func testMediaCommandHasNoContentType() throws {
        let values = DeviceControls(sender: Self.sender).mediaCommand(.next, key: "0|com.example.music|1|null|10001")
        XCTAssertNil(values.entries["contentType"])
        XCTAssertEqual(values.entries["audioCommandValue"], .int32(3))
        XCTAssertEqual(values.string("key"), "0|com.example.music|1|null|10001")
        XCTAssertEqual(values.entries["contractVersion"], .double(3.99))
        XCTAssertEqual(values.entries["isuserinitiated"], .bool(false))
        XCTAssertEqual([MediaCommand.play, .pause, .next, .previous].map(\.rawValue), [1, 2, 3, 4])
    }

    func testValueSetCommandsGoToTheirRoutesAndMapResults() async throws {
        let phone = FakePhone()
        let results = Results([0, 0, 0, 7, 14, 13, 1])
        phone.responder = { _ in ValueSet(["result": .int32(results.next()), "contractVersion": .double(3.99)]).serialized() }
        let (messenger, _) = try await phone.connect()
        let controls = DeviceControls(sender: Self.sender)
        try await controls.setRinger(.silent, through: messenger)
        try await controls.setDoNotDisturb(true, through: messenger)
        try await controls.media(.pause, notificationKey: "k", through: messenger)
        let expected: [PhoneControlError] = [.needsPermission, .ruleDisabled, .syncDisabled, .failed(1)]
        for error in expected {
            do {
                try await controls.setDoNotDisturb(false, through: messenger)
                XCTFail("expected \(error)")
            } catch let thrown as PhoneControlError {
                XCTAssertEqual(thrown, error)
            }
        }
        let status = try phone.received(route: "/command/devicestatus").map { try ValueSet(serialized: $0.payload) }
        XCTAssertEqual(status.prefix(2).map { $0.int("deviceStatusCommandType") }, [3, 2])
        XCTAssertEqual(status.map { $0.int("deviceStatusCommandValue") }, [0, 2, 1, 1, 1, 1], "Do Not Disturb on is filter 2, off is 1")
        let audio = try phone.received(route: "/command/audio").map { try ValueSet(serialized: $0.payload) }
        XCTAssertEqual(audio.map { $0.int("audioCommandValue") }, [2])
    }

    /// The phone keeps the "sync over mobile data" setting; Phone Link flips it with command 5.
    func testSyncOverMobileDataIsCommandFiveAndReadsFromTheStatus() async throws {
        let phone = FakePhone()
        // On, off on Wi-Fi, off on mobile data (refused as "metered", which is the wanted end),
        // and on while the phone says "metered", which is a failure.
        let results = Results([0, 0, 8, 8])
        phone.responder = { _ in ValueSet(["result": .int32(results.next())]).serialized() }
        let (messenger, _) = try await phone.connect()
        let controls = DeviceControls(sender: Self.sender)
        try await controls.setSyncOverMobileData(true, through: messenger)
        try await controls.setSyncOverMobileData(false, through: messenger)
        try await controls.setSyncOverMobileData(false, through: messenger)
        do {
            try await controls.setSyncOverMobileData(true, through: messenger)
            XCTFail("expected a failure")
        } catch let thrown as PhoneControlError {
            XCTAssertEqual(thrown, .syncDisabled)
        }
        let sent = try phone.received(route: "/command/devicestatus").map { try ValueSet(serialized: $0.payload) }
        XCTAssertEqual(sent.map { $0.int("deviceStatusCommandType") }, [5, 5, 5, 5])
        XCTAssertEqual(sent.map { $0.int("deviceStatusCommandValue") }, [1, 0, 0, 1])

        // Absent from the recorded status, which is how the format writes "off".
        let recorded = try XCTUnwrap(PhoneStatus(response: Data(hex: DeviceStatusTests.phoneStatusHex)))
        XCTAssertEqual(recorded.syncOverMobileData, false)
        XCTAssertFalse(recorded.isSyncPausedOnMobileData, "on Wi-Fi nothing is held back")
        var info = DeviceInfo_V1_DeviceStatus()
        info.networkType = .cellular
        XCTAssertTrue(PhoneStatus(info).isSyncPausedOnMobileData)
        info.syncOverMeteredConnection = true
        XCTAssertFalse(PhoneStatus(info).isSyncPausedOnMobileData)
        // A push says it by key, and one that does not leaves what is known.
        let push = ValueSet(["batteryPercent": .int32(50), "ringerMode": .int32(2), "syncOverMeteredConnection": .bool(true)])
        XCTAssertEqual(PhoneStatus(push: push)?.syncOverMobileData, true)
        let silent = ValueSet(["batteryPercent": .int32(50), "ringerMode": .int32(2)])
        XCTAssertEqual(PhoneStatus(push: silent, base: PhoneStatus(syncOverMobileData: true))?.syncOverMobileData, true)
        XCTAssertNil(PhoneStatus(push: silent)?.syncOverMobileData, "not known until the phone says")
    }

    /// On mobile data with the setting off the phone sends nothing by itself; what it does
    /// send is a refusal of whatever is asked, and that is passed on as news about the phone.
    func testAMeteredRefusalIsReportedAsStatus() async throws {
        XCTAssertTrue(PeerMessenger.isMeteredRefusal(ValueSet(["result": .int32(8), "wifiState": .bool(false), "syncOverMeteredConnection": .bool(false)]).serialized()))
        XCTAssertTrue(PeerMessenger.isMeteredRefusal(ValueSet(["result": .int32(12)]).serialized()))
        XCTAssertFalse(PeerMessenger.isMeteredRefusal(ValueSet(["result": .int32(0)]).serialized()))
        XCTAssertFalse(PeerMessenger.isMeteredRefusal(Data([0x08, 0x08])), "not a value set")

        let phone = FakePhone()
        let results = Results([0, 8])
        phone.responder = { _ in ValueSet(["result": .int32(results.next()), "syncOverMeteredConnection": .bool(false)]).serialized() }
        let (messenger, relay) = try await phone.connect()
        let sync = NotificationSync(messenger: messenger, displayName: "Mac", installationId: "INSTALL")
        await sync.start()
        let controls = DeviceControls(sender: Self.sender)
        try await controls.setRinger(.normal, through: messenger)
        do {
            try await controls.setRinger(.normal, through: messenger)
            XCTFail("expected a refusal")
        } catch let thrown as PhoneControlError {
            XCTAssertEqual(thrown, .syncDisabled)
        }
        var reported: ValueSet?
        for await change in sync.changes {
            if case .statusReported(let values) = change { reported = values; break }
        }
        XCTAssertEqual(reported?.bool("syncOverMeteredConnection"), false)
        XCTAssertEqual(reported?.bool(NotificationSync.meteredNowKey), true)

        // The setting changed on the phone itself arrives as a phone command of type 0.
        phone.deliver(PlatformEnvelope(headers: [("_requestId", "p1"), ("_route", "/legacy/phonecontent")],
                                       payload: ValueSet(["contentType": .string("phoneCommand"), "phoneCommandType": .int32(0), "syncOverMeteredConnection": .bool(true)]).serialized(),
                                       convention: .android), type: .app)
        for await change in sync.changes {
            if case .statusReported(let values) = change { reported = values; break }
        }
        XCTAssertEqual(reported?.bool("syncOverMeteredConnection"), true)
        XCTAssertNil(reported?.bool(NotificationSync.meteredNowKey))
        await relay.close()
    }

    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int32]
        init(_ values: [Int32]) { self.values = values }
        func next() -> Int32 { lock.withLock { values.isEmpty ? 0 : values.removeFirst() } }
    }

    // MARK: Media sessions among the notifications

    static func mediaJSON(state: Int, title: String = "Track") -> String {
        let object: [String: Any] = ["key": "media", "packageName": "com.example.music", "appName": "Music", "postTime": 1_700_000_000_000,
                                     "title": title, "text": "Artist", "notificationClass": 2, "playbackState": state,
                                     "largeIcon": Data([0xFF, 0xD8, 0xFF]).base64EncodedString(), "flags": 0]
        return String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    func testAMediaNotificationCarriesItsPlaybackStateAndArt() throws {
        let playing = try XCTUnwrap(PhoneNotification(json: Self.mediaJSON(state: 3)))
        XCTAssertTrue(playing.isMediaSession)
        XCTAssertTrue(playing.isPlaying)
        XCTAssertEqual(playing.largeIcon, Data([0xFF, 0xD8, 0xFF]))
        let paused = try XCTUnwrap(PhoneNotification(json: Self.mediaJSON(state: 2)))
        XCTAssertFalse(paused.isPlaying)
        XCTAssertNotEqual(playing, paused, "a change of playback state is a change")
        let plain = try XCTUnwrap(PhoneNotification(json: #"{"key":"k","packageName":"p","postTime":1}"#))
        XCTAssertFalse(plain.isMediaSession)
        XCTAssertNil(plain.playbackState)
    }

    func testMediaUpdatesNeverAlertAndAreNotCleared() async throws {
        let sync = NotificationSync(displayName: "Mac", installationId: "INSTALL")
        func push(_ documents: [String], keys: [String]) async {
            _ = await sync.apply(ValueSet(["notificationKeys": .stringArray(keys), "operations": .int32Array(Array(repeating: 1, count: keys.count)),
                                           "notifications": .stringArray(documents)]))
        }
        await push([Self.mediaJSON(state: 3), #"{"key":"k","packageName":"p","postTime":1}"#], keys: ["media", "k"])
        await push([Self.mediaJSON(state: 3, title: "Next track")], keys: ["media"])
        var alerts: [String: [Bool]] = [:]
        var count = 0
        for await change in sync.changes {
            if case .upsert(let notification, let alert) = change { alerts[notification.key, default: []].append(alert) }
            count += 1
            if count == 3 { break }
        }
        XCTAssertEqual(alerts["media"], [false, false])
        XCTAssertEqual(alerts["k"], [true])
        let keys = await sync.notifications.filter { !$0.isMediaSession }.map(\.key)
        XCTAssertEqual(keys, ["k"], "Clear All lists these keys only")
    }
}

/// The controls through the whole client: which session carries what, and the ring countdown.
final class DeviceControlsLinkTests: XCTestCase {
    func connect(extra: (@Sendable (PlatformEnvelope) -> Data?)?) async throws -> (LinkController, LinkControllerTests.PhoneSockets, LinkControllerTests.EventLog, Task<Void, Never>) {
        let sockets = LinkControllerTests.PhoneSockets()
        sockets.extra = extra
        let (controller, _, _) = try await LinkControllerTests().makeController(sockets: sockets, clipboard: TestClipboard())
        let log = LinkControllerTests.EventLog()
        let pump = Task { for await event in controller.events { log.append(event) } }
        await controller.start()
        let connected = await waitUntil(timeout: 5) {
            log.events.filter { if case .connected = $0 { return true }; return false }.count == 2
        }
        XCTAssertTrue(connected)
        return (controller, sockets, log, pump)
    }

    static func resourceMessage(_ envelope: PlatformEnvelope) -> PlatformSdk_V1_DeviceResourceManagerMessage? {
        guard envelope.route == DeviceResources.route else { return nil }
        return try? PlatformSdk_V1_DeviceResourceManagerMessage(serializedBytes: envelope.payload)
    }

    func testRingingGoesOverThePhoneLinkSessionAndCountsDown() async throws {
        let (controller, sockets, log, pump) = try await connect { envelope in
            guard let message = Self.resourceMessage(envelope), message.resourcePath == DeviceControls.ringPath else { return nil }
            return DeviceControlsTests.resourceAnswer(Data(hex: "0801"))
        }
        defer { pump.cancel() }
        try await controller.ringPhone()
        let ringing = await waitUntil { log.has { if case .ringing(let until) = $0 { return until != nil }; return false } }
        XCTAssertTrue(ringing)
        let rang = sockets.phones.filter { phone in phone.received.contains { Self.resourceMessage($0)?.resourcePath == DeviceControls.ringPath } }
        XCTAssertEqual(rang.count, 1)
        XCTAssertFalse(rang[0].received(route: ConnectExchange.route).isEmpty, "the session that did the handshake is the Phone Link one")

        try await controller.stopRinging()
        let stopped = await waitUntil { log.has { if case .ringing(let until) = $0 { return until == nil }; return false } }
        XCTAssertTrue(stopped)
        let payloads = rang[0].received.compactMap { Self.resourceMessage($0) }.filter { $0.resourcePath == DeviceControls.ringPath }.map(\.payload.hex)
        XCTAssertEqual(payloads, ["0801", "0802"])
        await controller.disconnect()
    }

    func testARefusedRingReportsNoRinging() async throws {
        // The standard scripted phone has no ring handler.
        let (controller, _, log, pump) = try await connect(extra: nil)
        defer { pump.cancel() }
        do {
            try await controller.ringPhone()
            XCTFail("expected unsupported")
        } catch let error as PhoneControlError {
            XCTAssertEqual(error, .unsupported)
        }
        XCTAssertFalse(log.has { if case .ringing = $0 { return true }; return false })
        await controller.disconnect()
    }

    func testRingerChangeUsesTheStatusUpdateAndReportsTheNewState() async throws {
        let (controller, sockets, log, pump) = try await connect { envelope in
            guard let message = Self.resourceMessage(envelope), message.resourcePath == DeviceStatusSync.phonePath, message.requestType == .update else { return nil }
            return DeviceControlsTests.resourceAnswer(DeviceControlsTests.statusAnswer(.ok, ringer: 0))
        }
        defer { pump.cancel() }
        try await controller.setRinger(.silent)
        let reported = await waitUntil { log.has { if case .phoneStatus(let status) = $0 { return status.ringer == .silent }; return false } }
        XCTAssertTrue(reported)
        XCTAssertTrue(sockets.phones.allSatisfy { $0.received(route: DeviceControls.statusCommandRoute).isEmpty }, "no second command when the first worked")
        await controller.disconnect()
    }

    func testAPhoneWithoutTheStatusUpdateGetsTheCommandPhoneLinkSends() async throws {
        let (controller, sockets, _, pump) = try await connect { envelope in
            if let message = Self.resourceMessage(envelope), message.resourcePath == DeviceStatusSync.phonePath, message.requestType == .update {
                return DeviceControlsTests.resourceAnswer(Data(), handled: false)
            }
            if envelope.route == DeviceControls.statusCommandRoute || envelope.route == DeviceControls.audioRoute {
                return ValueSet(["result": .int32(0), "contractVersion": .double(3.99)]).serialized()
            }
            return nil
        }
        defer { pump.cancel() }
        try await controller.setDoNotDisturb(true)
        let commands = sockets.phones.flatMap { $0.received(route: DeviceControls.statusCommandRoute) }.compactMap { try? ValueSet(serialized: $0.payload) }
        XCTAssertEqual(commands.map { $0.int("deviceStatusCommandType") }, [2])
        XCTAssertEqual(commands.map { $0.int("deviceStatusCommandValue") }, [2])

        try await controller.media(.next, notificationKey: "media")
        let keys = sockets.phones.flatMap { $0.received(route: DeviceControls.audioRoute) }.compactMap { try? ValueSet(serialized: $0.payload) }
        XCTAssertEqual(keys.map { $0.int("audioCommandValue") }, [3])
        XCTAssertEqual(keys.first?.string("key"), "media")
        await controller.disconnect()
    }
}
