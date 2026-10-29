import SwiftProtobuf
import XCTest
@testable import WinPhoneCore

/// The whole stack against the fake service and two fake phone sockets, one per client role.
final class LinkControllerTests: XCTestCase {
    /// Hands out one fake phone per relay connection and announces presence on each.
    final class PhoneSockets: WebSocketConnector, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var phones: [FakePhone] = []
        private(set) var urls: [URL] = []
        /// Answers tried before the standard ones, for a test's own routes.
        var extra: (@Sendable (PlatformEnvelope) -> Data?)?
        /// How long opening a socket takes, to hold a session in mid-connect.
        var connectDelay: Duration?

        func connect(url: URL, headers: [(name: String, value: String)]) async throws -> WebSocketConnection {
            if let connectDelay { try? await Task.sleep(for: connectDelay) }
            let phone = FakePhone()
            let original = phone.socket.onClientMessage
            phone.socket.onClientMessage = { data, socket in
                original?(data, socket)
                guard data == SignalR.handshakeRequest else { return }
                // The hub reports in and the phone is already present, as in a warm reconnect.
                socket.deliver(.invocation(headers: .map([]), invocationId: nil, target: "OnConnected",
                                           arguments: [.map(["RegionName": .string("WestEurope"), "Partners": .array([.string(FakePhone.id)])])]))
                socket.deliver(.invocation(headers: .map([]), invocationId: nil, target: "OnPartnerConnected",
                                           arguments: [.string(FakePhone.id), .null, .map(["RegionName": .string("WestEurope")])]))
            }
            let extra = extra
            phone.responder = { envelope in extra?(envelope) ?? PhoneSockets.answer(envelope) }
            lock.withLock { phones.append(phone); urls.append(url) }
            return phone.socket
        }

        /// What the phone answers: clipboard and status requests, notification commands, probes.
        static let answer: @Sendable (PlatformEnvelope) -> Data? = { envelope in
            switch envelope.route {
            case DeviceResources.route:
                guard let message = try? PlatformSdk_V1_DeviceResourceManagerMessage(serializedBytes: envelope.payload) else { return nil }
                var response = PlatformSdk_V1_DeviceResourceManagerResponseMessage()
                response.responseType = .success
                switch message.resourcePath {
                case ClipboardSync.resourcePath:
                    let request = try? Clipboard_V1_ClipboardRequestMessage(serializedBytes: message.payload)
                    var clip = Clipboard_V1_ClipboardResponseMessage()
                    clip.status = .ok
                    clip.correlationID = request?.correlationID ?? ""
                    if request?.requestType == .content {
                        var item = Clipboard_V1_ClipboardItem()
                        item.itemType = .textPlain
                        item.text = "from phone"
                        clip.clipboardItem = [item]
                    }
                    response.payload = try! clip.serializedData()
                case DeviceStatusSync.phonePath:
                    var status = DeviceInfo_V1_DeviceStatusResponseMessage()
                    status.status = .ok
                    status.info.batteryPercent = 77
                    response.payload = try! status.serializedData()
                default:
                    response.responseType = .resourceHandlerNotRegistered
                }
                return try! response.serializedData()
            case SessionValidation.route:
                var response = PlatformSdk_V1_ProtoPlatformSessionValidationResponse()
                response.platformCapabilities = [.sessionValidation]
                return try! response.serializedData()
            case NotificationSync.commandRoute:
                return ValueSet(["result": .int32(0), "contractVersion": .double(3.99)]).serialized()
            case ConnectExchange.route:
                // The phone's own numbers; they are never behind what it has sent.
                return ValueSet(["result": .int32(0), "contractVersion": .double(3.99), "sms": .int64(7),
                                 "permissions": .object(ValueSet(["messaging": .bool(true), "photos": .bool(true)]))]).serialized()
            case PhotoSync.route, MessageSync.route:
                return ValueSet(["result": .int32(0), "contractVersion": .double(3.99), "photos_full": .bool(true)]).serialized()
            case NotificationSync.permissionRoute:
                // "User accepted": notification access is granted, as in the capture.
                return ValueSet(["result": .int32(4), "contractVersion": .double(3.99)]).serialized()
            default:
                return nil
            }
        }
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [LinkController.Event] = []
        var events: [LinkController.Event] { lock.withLock { _events } }
        func append(_ event: LinkController.Event) { lock.withLock { _events.append(event) } }
        func has(_ predicate: (LinkController.Event) -> Bool) -> Bool { events.contains(where: predicate) }
    }

    func makeController(sockets: PhoneSockets, clipboard: TestClipboard, roles: [ClientProfile] = [.crossDevice, .phoneLink],
                        callLogs: Bool = false) async throws -> (LinkController, FakeServices, StateVault) {
        let services = FakeServices()
        services.dcg.msaToken = "msa-token-r1"
        let store = MemoryStateStore()
        var state = PersistedState()
        state.refreshToken = "refresh-0"
        try store.save(state)
        let vault = try StateVault(store: store)
        var dependencies = RoleSession.Dependencies(http: services, webSockets: sockets, instance: await vault.clientInstance,
                                                   displayName: "Mac", installationId: "INSTALL", localClipboard: clipboard)
        dependencies.callLogsEnabled = { callLogs }
        dependencies.timing.hubInfoWait = .milliseconds(500)
        dependencies.timing.presenceGrace = .milliseconds(50)
        dependencies.timing.wakeWait = .milliseconds(200)
        dependencies.timing.heartbeatSeconds = 0
        var reconnect = LinkController.Reconnect()
        reconnect.initialDelay = .milliseconds(50)
        let controller = await LinkController(vault: vault, msa: MicrosoftAccount(transport: services), dependencies: dependencies, roles: roles, reconnect: reconnect)
        return (controller, services, vault)
    }

    func testStartConnectsBothRolesAndRunsTheirFeatures() async throws {
        let sockets = PhoneSockets()
        let clipboard = TestClipboard(.text("hello from the mac"))
        let (controller, services, vault) = try await makeController(sockets: sockets, clipboard: clipboard)
        let log = EventLog()
        let pump = Task { for await event in controller.events { log.append(event) } }
        defer { pump.cancel() }
        await controller.start()

        let connected = await waitUntil(timeout: 5) {
            log.events.filter { if case .connected = $0 { return true }; return false }.count == 2
        }
        XCTAssertTrue(connected, "both roles came online: \(log.events)")
        XCTAssertTrue(log.has { if case .signedIn = $0 { return true }; return false })
        XCTAssertTrue(log.has { if case .phones(let phones) = $0 { return phones.map(\.id) == [FakeDCG.phoneId] }; return false })

        // One identity per role, both enrolled, two relay connections with the right app IDs.
        let state = await vault.state
        XCTAssertEqual(Set(state.roles.keys), ["PL", "WEA"])
        XCTAssertEqual(sockets.phones.count, 2)
        let negotiates = services.dcg.calls.filter { $0 == "POST /relayhub/negotiate" }
        XCTAssertEqual(negotiates.count, 2)
        XCTAssertEqual(services.dcg.wakes.count, 0, "the phone was present, so no wake was needed")

        // The cross-device role turned the clipboard on, asked for the status and probed capabilities.
        let wea = try XCTUnwrap(sockets.phones.first { phone in phone.received(route: DeviceResources.route).contains { _ in true } })
        let featureOn = await waitUntil(timeout: 3) {
            wea.received(route: DeviceResources.route).contains { envelope in
                (try? PlatformSdk_V1_DeviceResourceManagerMessage(serializedBytes: envelope.payload))?.resourcePath == ClipboardSync.resourcePath
            }
        }
        XCTAssertTrue(featureOn)
        let statusAsked = await waitUntil(timeout: 3) {
            wea.received(route: DeviceResources.route).contains { envelope in
                (try? PlatformSdk_V1_DeviceResourceManagerMessage(serializedBytes: envelope.payload))?.resourcePath == DeviceStatusSync.phonePath
            }
        }
        XCTAssertTrue(statusAsked)
        let statusSeen = await waitUntil(timeout: 3) { log.has { if case .phoneStatus(let s) = $0 { return s.batteryPercent == 77 }; return false } }
        XCTAssertTrue(statusSeen)

        // The Phone Link role asked the phone to reconcile notifications.
        let pl = try XCTUnwrap(sockets.phones.first { $0 !== wea })
        let reconciled = await waitUntil(timeout: 3) {
            pl.received(route: NotificationSync.commandRoute).contains { (try? ValueSet(serialized: $0.payload))?.int("operation") == 3 }
        }
        XCTAssertTrue(reconciled)
        XCTAssertTrue(log.has { if case .notificationAccess(true) = $0 { return true }; return false })

        // A notification pushed by the phone reaches the interface and is answered.
        let json = #"{"key":"k1","packageName":"com.example","appName":"Example","postTime":1700000000000,"title":"Hi","text":"There"}"#
        let push = ValueSet(["contentType": .string("notifications"), "notificationKeys": .stringArray(["k1"]),
                             "operations": .int32Array([1]), "notifications": .stringArray([json]), "itemCount": .int32(1)])
        let requestId = UUID().uuidString.lowercased()
        pl.deliver(PlatformEnvelope(headers: [("_route", NotificationSync.pushRoute), ("_rejectionVersion", "1"), ("_requestId", requestId)],
                                    payload: push.serialized(), convention: .android), type: .app)
        let notified = await waitUntil(timeout: 3) {
            log.has { if case .notification(.upsert(let n, true)) = $0 { return n.key == "k1" && n.title == "Hi" }; return false }
        }
        XCTAssertTrue(notified)
        let answered = await waitUntil(timeout: 3) { !pl.responses(to: requestId).isEmpty }
        XCTAssertTrue(answered)
        XCTAssertEqual((try? ValueSet(serialized: pl.responses(to: requestId)[0].payload))?.int("result"), 0)

        // The phone announces a clipboard change; we pull it and write it locally.
        var change = Clipboard_V1_ClipboardResponseMessage()
        change.status = .clipboardChange
        change.correlationID = "abcd"
        var payload = PlatformSdk_V1_PubSubPayload()
        payload.additional = try change.serializedData()
        var message = PlatformSdk_V1_MsaepMessage()
        message.messageTag = ContextPublisher.Tag.clipboard.rawValue
        message.dcgClientID = FakePhone.id
        message.messageID = "m1"
        message.payload = try payload.serializedData()
        wea.request(route: ContextPublisher.route, payload: try message.serializedData())
        let pulled = await waitUntil(timeout: 3) { log.has { if case .clipboardReceived(.text("from phone")) = $0 { return true }; return false } }
        XCTAssertTrue(pulled)
        let writes = await clipboard.writes
        XCTAssertEqual(writes.last, .text("from phone"))

        await controller.disconnect()
    }

    /// Seen on 2026-10-12: one request to the service was lost at launch, and the app stopped
    /// at an error page. A lost connection is tried again by itself.
    func testARequestLostAtLaunchIsTriedAgainInsteadOfStoppingAtAnError() async throws {
        let sockets = PhoneSockets()
        let (controller, services, _) = try await makeController(sockets: sockets, clipboard: TestClipboard(.text("x")))
        services.dropsNext = 2
        let log = EventLog()
        let pump = Task { for await event in controller.events { log.append(event) } }
        defer { pump.cancel() }
        let starting = Task { await controller.start() }
        let connected = await waitUntil(timeout: 12) {
            log.events.filter { if case .connected = $0 { return true }; return false }.count == 2
        }
        XCTAssertTrue(connected, "both roles came online after the lost requests")
        XCTAssertEqual(services.dropped, 2)
        XCTAssertFalse(log.has { if case .failed = $0 { return true }; return false }, "no error page for a lost connection")
        await starting.value
        await controller.disconnect()

        XCTAssertTrue(LinkController.isNetworkTrouble(URLError(.notConnectedToInternet)))
        XCTAssertFalse(LinkController.isNetworkTrouble(DCGError.http(status: 500)))
        XCTAssertEqual(LinkController.networkRetryWait(after: 0), .seconds(1))
        XCTAssertEqual(LinkController.networkRetryWait(after: 99), .seconds(60))
        let told = LinkController.describe(URLError(.networkConnectionLost))
        XCTAssertTrue(told.contains("could not be reached"))
        XCTAssertFalse(told.contains("NSURLErrorDomain"), "no raw error text for the user")
    }

    func testASingleUnifiedClientRunsBothFeatureSetsOnOneSocket() async throws {
        let sockets = PhoneSockets()
        let (controller, services, vault) = try await makeController(sockets: sockets, clipboard: TestClipboard(), roles: [.unified])
        let log = EventLog()
        let pump = Task { for await event in controller.events { log.append(event) } }
        defer { pump.cancel() }
        await controller.start()
        let connected = await waitUntil(timeout: 5) { log.has { if case .connected(_, "PL") = $0 { return true }; return false } }
        XCTAssertTrue(connected)
        let state = await vault.state
        XCTAssertEqual(Array(state.roles.keys), ["PL"], "one identity")
        let metadata = try XCTUnwrap(services.dcg.enrollments.first?["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["clientType"] as? String, "PL")
        XCTAssertEqual((metadata["capabilities"] as? [String])?.contains("CLIPBOARD"), true)
        let both = await waitUntil(timeout: 3) {
            guard let phone = sockets.phones.first else { return false }
            let clipboardOn = phone.received(route: DeviceResources.route).contains {
                (try? PlatformSdk_V1_DeviceResourceManagerMessage(serializedBytes: $0.payload))?.resourcePath == ClipboardSync.resourcePath
            }
            let reconciled = phone.received(route: NotificationSync.commandRoute).contains { (try? ValueSet(serialized: $0.payload))?.int("operation") == 3 }
            return clipboardOn && reconciled
        }
        XCTAssertTrue(both, "clipboard and notifications ran over the same connection")
        XCTAssertEqual(sockets.phones.count, 1)
        await controller.disconnect()
    }

    func testContentAndSequenceNumbersSurviveAReconnect() async throws {
        let sockets = PhoneSockets()
        let (controller, _, _) = try await makeController(sockets: sockets, clipboard: TestClipboard(), roles: [.phoneLink])
        let log = EventLog()
        let pump = Task { for await event in controller.events { log.append(event) } }
        defer { pump.cancel() }
        await controller.start()
        let connected = await waitUntil(timeout: 5) { log.has { if case .connected = $0 { return true }; return false } }
        XCTAssertTrue(connected)
        let first = try XCTUnwrap(sockets.phones.first)
        func connectRequests(_ phone: FakePhone) -> [ValueSet] { phone.received(route: ConnectExchange.route).compactMap { try? ValueSet(serialized: $0.payload) } }
        let asked = await waitUntil(timeout: 3) { !connectRequests(first).isEmpty }
        XCTAssertTrue(asked)
        let initial = try XCTUnwrap(connectRequests(first).first?.object("sequenceNumbers"))
        XCTAssertEqual(initial["sms"], .int64(-1), "nothing held yet")
        XCTAssertEqual(initial["media_info"], .int64(-1))
        XCTAssertEqual(initial["contact"], .int64(-1))
        XCTAssertEqual(initial["phoneApps"], .int64(-1))
        XCTAssertEqual(Set(initial.entries.keys), ["sms", "mms", "conversation", "subscription", "media_info", "contact", "phonenumber", "emailaddress",
                                                   "postaladdress", "contactdate", "contacturl", "phoneApps", "recentApps"])

        // The phone pushes one text with its sequence numbers.
        var sms: [String: ValueSet.Value] = [:]
        sms["messageIds"] = .int64Array([1]); sms["threadIds"] = .int64Array([5]); sms["messageTypes"] = .int32Array([1])
        sms["dates"] = .int64Array([1000]); sms["bodies"] = .stringArray(["hello"]); sms["fromAddresses"] = .stringArray(["+100"])
        sms["toAddresses"] = .stringArray([""]); sms["readFlags"] = .boolArray([false]); sms["actions"] = .int32Array([0])
        let push = ValueSet(["contentType": .string("messaging"), "smsMessages": .object(ValueSet(sms)),
                             "sequenceNumbers": .object(ValueSet(["sms": .int64(7), "mms": .int64(0), "conversation": .int64(2), "subscription": .int64(1)]))])
        first.deliver(PlatformEnvelope(headers: [("_requestId", UUID().uuidString.lowercased()), ("_route", "/legacy/phonecontent")],
                                       payload: push.serialized(), convention: .android), type: .app)
        let received = await waitUntil(timeout: 3) { log.has { if case .conversations(let list) = $0 { return list.first?.messages.count == 1 }; return false } }
        XCTAssertTrue(received)

        // The connection drops; a new one is made. The handshake now states what is held.
        first.socket.fail(URLError(.networkConnectionLost))
        let reconnected = await waitUntil(timeout: 5) { sockets.phones.count == 2 && !connectRequests(sockets.phones[1]).isEmpty }
        XCTAssertTrue(reconnected)
        let later = try XCTUnwrap(connectRequests(sockets.phones[1]).first?.object("sequenceNumbers"))
        XCTAssertEqual(later["sms"], .int64(7), "the phone is told what we hold and sends only what is newer")
        XCTAssertEqual(later["conversation"], .int64(2))
        XCTAssertEqual(later["media_info"], .int64(-1))
        // The text is still there, without a new sync.
        let lastList = log.events.reversed().compactMap { event -> [Conversation]? in if case .conversations(let list) = event { return list }; return nil }.first
        XCTAssertEqual(lastList?.first?.messages.map(\.body), ["hello"])
        await controller.disconnect()
    }

    /// Two connects close together, as after a wake followed by the network returning: the
    /// sessions of the first are still opening their sockets when the second replaces them.
    func testASessionReplacedWhileConnectingStaysOutOfTheWay() async throws {
        let sockets = PhoneSockets()
        sockets.connectDelay = .milliseconds(250)
        let (controller, _, _) = try await makeController(sockets: sockets, clipboard: TestClipboard())
        let log = EventLog()
        let pump = Task { for await event in controller.events { log.append(event) } }
        defer { pump.cancel() }
        await controller.start()
        await controller.connectIfPossible()
        func connectedCount() -> Int { log.events.filter { if case .connected = $0 { return true }; return false }.count }
        let up = await waitUntil(timeout: 5) { connectedCount() == 2 }
        XCTAssertTrue(up)
        // Give the replaced sessions time to finish whatever they were doing.
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(connectedCount(), 2, "the replaced sessions announce nothing: \(log.events)")
        XCTAssertFalse(log.has { if case .disconnected = $0 { return true }; return false }, "nor do they report a loss")

        // The shared features belong to the live Phone Link session: a push arrives through
        // it, and a command leaves through it.
        let live = try XCTUnwrap(sockets.phones.last { !$0.received(route: ConnectExchange.route).isEmpty })
        let document = #"{"key":"k1","packageName":"p","appName":"App","postTime":5,"title":"t"}"#
        let push = ValueSet(["contentType": .string("notifications"), "notificationKeys": .stringArray(["k1"]), "operations": .int32Array([1]),
                             "notifications": .stringArray([document])])
        live.deliver(PlatformEnvelope(headers: [("_requestId", UUID().uuidString.lowercased()), ("_route", "/legacy/phonecontent")],
                                      payload: push.serialized(), convention: .android), type: .app)
        let shown = await waitUntil(timeout: 3) { log.has { if case .notification(.upsert(let n, _)) = $0 { return n.key == "k1" }; return false } }
        XCTAssertTrue(shown)
        try await controller.dismiss(notificationKey: "k1")
        let commands = live.received(route: NotificationSync.commandRoute).compactMap { try? ValueSet(serialized: $0.payload) }
        XCTAssertTrue(commands.contains { $0.int("operation") == 2 && $0.string("key") == "k1" }, "the dismiss went out on the live connection")
        // Status events still flow: the live cross-device session's forwarders were not ended.
        XCTAssertTrue(log.has { if case .phoneStatus = $0 { return true }; return false })
        await controller.disconnect()
    }

    func testATextSentBetweenConnectionsShowsAsFailedInsteadOfVanishing() async throws {
        let sockets = PhoneSockets()
        let (controller, _, _) = try await makeController(sockets: sockets, clipboard: TestClipboard(), roles: [.phoneLink])
        let log = EventLog()
        let pump = Task { for await event in controller.events { log.append(event) } }
        defer { pump.cancel() }
        await controller.start()
        _ = await waitUntil(timeout: 5) { log.has { if case .connected = $0 { return true }; return false } }
        await controller.disconnect()
        do {
            try await controller.sendMessage("are you there", threadId: 5)
            XCTFail("nothing can be sent without a connection")
        } catch {}
        let kept = await waitUntil(timeout: 2) {
            log.has { if case .conversations(let list) = $0 { return list.contains { $0.pending.contains { $0.body == "are you there" && $0.state == .failed(reason: nil) } } }; return false }
        }
        XCTAssertTrue(kept, "the text is on screen, marked as not sent")
    }

    func testPhoneLeavingTriggersAReconnectWithAWake() async throws {
        let sockets = PhoneSockets()
        let (controller, services, _) = try await makeController(sockets: sockets, clipboard: TestClipboard())
        let log = EventLog()
        let pump = Task { for await event in controller.events { log.append(event) } }
        defer { pump.cancel() }
        await controller.start()
        _ = await waitUntil(timeout: 5) { log.events.filter { if case .connected = $0 { return true }; return false }.count == 2 }

        // The relay drops one socket: the role reports the loss and comes back on a new one.
        sockets.phones[0].socket.fail(URLError(.networkConnectionLost))
        let dropped = await waitUntil(timeout: 3) { log.has { if case .disconnected = $0 { return true }; return false } }
        XCTAssertTrue(dropped)
        let back = await waitUntil(timeout: 5) { sockets.phones.count == 3 && log.events.filter { if case .connected = $0 { return true }; return false }.count == 3 }
        XCTAssertTrue(back, "\(log.events)")
        XCTAssertEqual(services.dcg.calls.filter { $0 == "POST /relayhub/negotiate" }.count, 3)
        await controller.disconnect()
    }

    func testSignOutForgetsEverythingAndReportsIt() async throws {
        let sockets = PhoneSockets()
        let (controller, _, vault) = try await makeController(sockets: sockets, clipboard: TestClipboard())
        let log = EventLog()
        let pump = Task { for await event in controller.events { log.append(event) } }
        defer { pump.cancel() }
        await controller.start()
        _ = await waitUntil(timeout: 5) { log.events.filter { if case .connected = $0 { return true }; return false }.count == 2 }
        await controller.signOut()
        let state = await vault.state
        XCTAssertFalse(state.isSignedIn)
        XCTAssertTrue(state.roles.isEmpty)
        let reported = await waitUntil { log.has { if case .signedOut = $0 { return true }; return false } }
        XCTAssertTrue(reported)
    }
}
