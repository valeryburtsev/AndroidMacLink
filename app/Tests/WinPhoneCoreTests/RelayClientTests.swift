import XCTest
@testable import WinPhoneCore

final class RelayClientTests: XCTestCase {
    let peer = "22222222-2222-4222-8222-222222222222"

    /// Builds a started hub and relay over a socket whose peer completes every invocation and,
    /// when `autoAck` is set, acknowledges every fragment like a phone would.
    func makeRelay(autoAck: Bool = true, configuration: RelayClient.Configuration = .init()) async throws -> (RelayClient, MockWebSocket) {
        let socket = MockWebSocket()
        let peer = self.peer
        socket.onClientMessage = { data, socket in
            if data == SignalR.handshakeRequest { socket.deliver(Data("{}".utf8) + [SignalR.recordSeparator]); return }
            for frame in (try? SignalR.splitFrames(data)) ?? [] {
                guard case .invocation(_, let id?, let target, let arguments)? = try? HubMessage(frame: frame) else { continue }
                socket.deliver(.completion(headers: .map([]), invocationId: id, resultKind: 3, value: .null))
                if autoAck, target == "SendMessageAsync", case .fragment(let fragment)? = try? DcgPacket(arguments[2]) {
                    socket.deliver(RelayClientTests.inbound(from: peer, .ack(.init(sessionId: fragment.sessionId, sequenceNumber: fragment.sequenceNumber))))
                }
            }
        }
        let hub = HubConnection(socket: socket)
        try await hub.start(keepAlive: .seconds(3600))
        let relay = RelayClient(hub: hub, configuration: configuration)
        await relay.start()
        return (relay, socket)
    }

    static func inbound(from source: String, _ packet: DcgPacket) -> HubMessage {
        .invocation(headers: .map([]), invocationId: nil, target: "OnReceiveMessage",
                    arguments: [.string(source), TraceContext(parentId: nil).encoded, packet.encoded])
    }

    func sentPackets(_ socket: MockWebSocket) -> [DcgPacket] {
        socket.sentHubMessages.compactMap {
            guard case .invocation(_, _, "SendMessageAsync", let arguments) = $0 else { return nil }
            return try? DcgPacket(arguments[2])
        }
    }

    func testSmallMessageIsOneFragmentWithPhoneLinkArgumentOrder() async throws {
        let (relay, socket) = try await makeRelay()
        try await relay.send(Data([1, 2, 3]), type: .platform, to: peer)
        guard case .invocation(let headers, let id, let target, let arguments) = socket.sentHubMessages[0] else { return XCTFail() }
        XCTAssertEqual(target, "SendMessageAsync")
        XCTAssertNotNil(id)
        XCTAssertNotNil(headers["traceparent"]?.stringValue)
        XCTAssertEqual(arguments.count, 3)
        XCTAssertNotNil(TraceContext(arguments[0]), "argument 0 is the trace context")
        XCTAssertEqual(arguments[1], .string(peer), "argument 1 is the target")
        guard case .fragment(let fragment) = try DcgPacket(arguments[2]) else { return XCTFail() }
        XCTAssertEqual(fragment.raw, Data([1, 2, 3]))
        XCTAssertEqual([fragment.sequenceNumber, fragment.messageId, fragment.fragmentId, fragment.fragmentCount], [1, 1, 1, 1])
        XCTAssertEqual(fragment.messageType, .platform)
        XCTAssertEqual(fragment.sessionId.count, 36)
        await relay.close()
    }

    func testLargeMessageIsFragmentedWithContinuousSequenceNumbers() async throws {
        var configuration = RelayClient.Configuration()
        configuration.fragmentSize = 10
        let (relay, socket) = try await makeRelay(configuration: configuration)
        let payload = Data((0..<25).map { UInt8($0) })
        try await relay.send(payload, type: .app, to: peer)
        try await relay.send(Data([9]), type: .app, to: peer)
        let fragments = sentPackets(socket).compactMap { packet -> DcgPacket.Fragment? in
            if case .fragment(let f) = packet { return f }
            return nil
        }
        XCTAssertEqual(fragments.map(\.sequenceNumber), [1, 2, 3, 4])
        XCTAssertEqual(fragments.map(\.messageId), [1, 1, 1, 2])
        XCTAssertEqual(fragments.map(\.fragmentId), [1, 2, 3, 1])
        XCTAssertEqual(fragments.map(\.fragmentCount), [3, 3, 3, 1])
        XCTAssertEqual(fragments.prefix(3).reduce(Data()) { $0 + $1.raw }, payload)
        XCTAssertEqual(Set(fragments.map(\.sessionId)).count, 1, "one DCG session per peer")
        await relay.close()
    }

    func testMissingAcknowledgementIsRetriedThenFails() async throws {
        var configuration = RelayClient.Configuration()
        configuration.ackTimeout = .milliseconds(30)
        configuration.retries = 2
        let (relay, socket) = try await makeRelay(autoAck: false, configuration: configuration)
        do {
            try await relay.send(Data([1]), type: .platform, to: peer)
            XCTFail("expected timeout")
        } catch let error as RelayClient.RelayError {
            XCTAssertEqual(error, .acknowledgementTimeout(sequenceNumber: 1))
        }
        let packets = sentPackets(socket)
        XCTAssertEqual(packets.count, 3, "one attempt plus two retries")
        XCTAssertEqual(Set(packets.map { $0.encoded.encoded() }).count, 1, "retries resend the identical fragment")
        await relay.close()
    }

    func testNegativeAcknowledgementFailsWithoutRetry() async throws {
        let socket = MockWebSocket()
        let peer = self.peer
        socket.onClientMessage = { data, socket in
            if data == SignalR.handshakeRequest { socket.deliver(Data("{}".utf8) + [SignalR.recordSeparator]); return }
            for frame in (try? SignalR.splitFrames(data)) ?? [] {
                guard case .invocation(_, let id?, _, let arguments)? = try? HubMessage(frame: frame) else { continue }
                socket.deliver(.completion(headers: .map([]), invocationId: id, resultKind: 3, value: .null))
                if case .fragment(let f)? = try? DcgPacket(arguments[2]) {
                    socket.deliver(RelayClientTests.inbound(from: peer, .ack(.init(sessionId: f.sessionId, sequenceNumber: f.sequenceNumber, success: false, errorNumber: 7))))
                }
            }
        }
        let hub = HubConnection(socket: socket)
        try await hub.start(keepAlive: .seconds(3600))
        let relay = RelayClient(hub: hub)
        await relay.start()
        do {
            try await relay.send(Data([1]), type: .platform, to: peer)
            XCTFail("expected rejection")
        } catch let error as RelayClient.RelayError {
            XCTAssertEqual(error, .negativeAcknowledgement(sequenceNumber: 1, errorNumber: 7))
        }
        XCTAssertEqual(sentPackets(socket).count, 1)
        await relay.close()
    }

    func testInboundFragmentsAreAcknowledgedAndReassembled() async throws {
        let (relay, socket) = try await makeRelay()
        let session = "33333333-3333-4333-8333-333333333333"
        func fragment(_ id: Int, _ bytes: [UInt8], seq: Int) -> HubMessage {
            RelayClientTests.inbound(from: peer, .fragment(.init(sessionId: session, sequenceNumber: seq, messageId: 70, messageType: .platform,
                                                                 fragmentId: id, fragmentCount: 3, raw: Data(bytes))))
        }
        // Out of order, with a duplicate.
        socket.deliver(fragment(2, [3, 4], seq: 11))
        socket.deliver(fragment(1, [1, 2], seq: 10))
        socket.deliver(fragment(1, [1, 2], seq: 10))
        socket.deliver(fragment(3, [5], seq: 12))
        var message: RelayClient.InboundMessage?
        for await event in relay.events {
            if case .message(let m) = event { message = m; break }
        }
        XCTAssertEqual(message?.payload, Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(message?.source, peer)
        XCTAssertEqual(message?.type, .platform)

        let acked = await waitUntil { self.sentPackets(socket).count == 4 }
        XCTAssertTrue(acked, "every received fragment is acknowledged, duplicates included")
        let acks = sentPackets(socket).compactMap { packet -> DcgPacket.Ack? in
            if case .ack(let a) = packet { return a }
            return nil
        }
        XCTAssertEqual(acks.map(\.sequenceNumber).sorted(), [10, 10, 11, 12])
        XCTAssertTrue(acks.allSatisfy { $0.success && $0.sessionId == session })
        await relay.close()
    }

    func testRetransmittedMessageIsNotDeliveredTwice() async throws {
        let (relay, socket) = try await makeRelay()
        let packet = DcgPacket.fragment(.init(sessionId: "s", sequenceNumber: 5, messageId: 9, messageType: .app, fragmentId: 1, fragmentCount: 1, raw: Data([7])))
        socket.deliver(RelayClientTests.inbound(from: peer, packet))
        socket.deliver(RelayClientTests.inbound(from: peer, packet))
        socket.deliver(.invocation(headers: .map([]), invocationId: nil, target: "OnPartnerDisconnected", arguments: [.string(peer)]))
        var messages = 0
        for await event in relay.events {
            if case .message = event { messages += 1 }
            if case .partnerDisconnected = event { break }
        }
        XCTAssertEqual(messages, 1)
        let acked = await waitUntil { self.sentPackets(socket).count == 2 }
        XCTAssertTrue(acked, "the retransmission is still acknowledged")
        await relay.close()
    }

    func testInconsistentOrOversizedFragmentsAreRejected() async throws {
        var configuration = RelayClient.Configuration()
        configuration.maxMessageBytes = 4
        let (relay, socket) = try await makeRelay(configuration: configuration)
        func fragment(_ id: Int, count: Int, _ bytes: [UInt8], seq: Int, message: Int) -> HubMessage {
            RelayClientTests.inbound(from: peer, .fragment(.init(sessionId: "s", sequenceNumber: seq, messageId: message, messageType: .app,
                                                                 fragmentId: id, fragmentCount: count, raw: Data(bytes))))
        }
        socket.deliver(fragment(1, count: 2, [1], seq: 1, message: 1))
        socket.deliver(fragment(2, count: 3, [2], seq: 2, message: 1))          // count changed
        socket.deliver(fragment(5, count: 2, [2], seq: 3, message: 2))          // id out of range
        socket.deliver(fragment(1, count: 2, [1, 2, 3], seq: 4, message: 3))
        socket.deliver(fragment(2, count: 2, [4, 5], seq: 5, message: 3))       // exceeds 4 bytes
        let done = await waitUntil { self.sentPackets(socket).count == 5 }
        XCTAssertTrue(done)
        let acks = sentPackets(socket).compactMap { packet -> DcgPacket.Ack? in
            if case .ack(let a) = packet { return a }
            return nil
        }.sorted { $0.sequenceNumber < $1.sequenceNumber }
        XCTAssertEqual(acks.map(\.success), [true, false, false, true, false])
        await relay.close()
    }

    func testPresenceEventsAndSendConnected() async throws {
        let (relay, socket) = try await makeRelay()
        socket.deliver(
            .invocation(headers: .map([]), invocationId: nil, target: "OnConnected", arguments: [.map(["RegionName": .string("WestEurope"), "Partners": .array([.string(peer)])])]),
            .invocation(headers: .map([]), invocationId: nil, target: "OnPartnerConnected", arguments: [.string(peer), .null, .map(["RegionName": .string("WestEurope")])]),
            .invocation(headers: .map([]), invocationId: nil, target: "OnPartnerHeartBeat", arguments: [.string(peer), .string("Ih1wab"), .int(1_791_535_622_270)]))
        var seen: [RelayClient.Event] = []
        for await event in relay.events {
            seen.append(event)
            if seen.count == 3 { break }
        }
        XCTAssertEqual(seen, [.connected(region: "WestEurope", partners: [peer]), .partnerConnected(id: peer, region: "WestEurope"), .partnerHeartbeat(id: peer)])

        try await relay.sendConnected(to: peer)
        guard case .invocation(_, _, "SendConnectedAsync", let arguments)? = socket.sentHubMessages.last else { return XCTFail() }
        XCTAssertEqual(arguments.count, 3)
        XCTAssertEqual(arguments[1], .string(peer))
        XCTAssertEqual(arguments[2], .map([]))
        XCTAssertEqual(TraceContext(arguments[0])?.scenarioId, "SendConnectedMessage")
        await relay.close()
    }

    func testConnectionLossEndsEventsAndFailsSends() async throws {
        let (relay, socket) = try await makeRelay(autoAck: false)
        let sending = Task { try await relay.send(Data([1]), type: .platform, to: self.peer) }
        let sent = await waitUntil { self.sentPackets(socket).count == 1 }
        XCTAssertTrue(sent)
        socket.fail(URLError(.networkConnectionLost))
        do { try await sending.value; XCTFail("expected failure") } catch {}
        var sawClosed = false
        for await event in relay.events where event == .closed { sawClosed = true }
        XCTAssertTrue(sawClosed)
    }
}

final class RelayConnectorTests: XCTestCase {
    /// The three steps seen on the wire: gateway negotiate, service negotiate, WebSocket upgrade.
    func testNegotiateRedirectAndUpgrade() async throws {
        let http = MockTransport()
        http.enqueue(json: #"{"negotiateVersion":0,"url":"https://relay-eu.service.signalr.net/client/?hub=dcgrelayhub_relayhub&asrs.op=%2Frelayhub&negotiateVersion=1&asrs_request_id=REQ","accessToken":"SERVICE","availableTransports":[]}"#)
        http.enqueue(json: #"{"negotiateVersion":1,"connectionId":"cid","connectionToken":"CTOKEN","availableTransports":[{"transport":"WebSockets","transferFormats":["Text","Binary"]}]}"#)
        let socket = MockWebSocket.autoCompleting()
        let recorded = Recorder()
        let connector = RelayConnector(instance: ClientInstance(logicalDeviceId: "LID", sessionId: "SID"), http: http,
                                       webSockets: MockConnector(socket: socket) { url, headers in recorded.set(url, headers) })
        let hub = try await connector.connect(dcgToken: "DCG", partnerId: "PARTNER")
        try await hub.start(keepAlive: .seconds(3600))

        let requests = http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url.absoluteString, "https://dcg.microsoft.com/relayhub/negotiate?negotiateVersion=1")
        XCTAssertEqual(requests[0].method, "POST")
        XCTAssertEqual(requests[0].header("Authorization"), "Bearer DCG")
        XCTAssertEqual(requests[0].header("DCG-PartnerId"), "PARTNER")
        XCTAssertEqual(requests[0].header("DCG-HeartBeatFrequency"), "30")
        XCTAssertEqual(requests[0].header("X-Requested-With"), "XMLHttpRequest")
        XCTAssertNil(requests[0].body)

        let service = try XCTUnwrap(URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(service.host, "relay-eu.service.signalr.net")
        XCTAssertEqual(service.path, "/client/negotiate")
        XCTAssertEqual(service.queryItems?.map(\.name), ["hub", "asrs.op", "negotiateVersion", "asrs_request_id"])
        XCTAssertEqual(service.queryItems?.first { $0.name == "asrs.op" }?.value, "/relayhub")
        XCTAssertEqual(requests[1].header("Authorization"), "Bearer SERVICE", "the service negotiate uses the gateway's access token")

        let (url, headers) = try XCTUnwrap(recorded.value)
        let ws = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(ws.scheme, "wss")
        XCTAssertEqual(ws.path, "/client/")
        XCTAssertEqual(ws.queryItems?.map(\.name), ["hub", "asrs.op", "negotiateVersion", "asrs_request_id", "id"])
        XCTAssertEqual(ws.queryItems?.last?.value, "CTOKEN")
        XCTAssertEqual(headers.first { $0.name == "Authorization" }?.value, "Bearer SERVICE")
        XCTAssertEqual(headers.first { $0.name == "DCG-AppId" }?.value, "Microsoft.YourPhone_8wekyb3d8bbwe")
        await hub.close()
    }

    func testNegotiateFailuresAreReported() async {
        let http = MockTransport()
        http.enqueue(status: 401, json: "{}")
        let connector = RelayConnector(instance: ClientInstance(logicalDeviceId: "x"), http: http,
                                       webSockets: MockConnector(socket: MockWebSocket()) { _, _ in })
        do {
            _ = try await connector.connect(dcgToken: "bad", partnerId: nil)
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? RelayConnector.ConnectError, .http(step: "gateway negotiate", status: 401))
        }
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (URL, [(name: String, value: String)])?
    var value: (URL, [(name: String, value: String)])? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ url: URL, _ headers: [(name: String, value: String)]) { lock.lock(); stored = (url, headers); lock.unlock() }
}
