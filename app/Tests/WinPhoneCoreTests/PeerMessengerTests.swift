import XCTest
@testable import WinPhoneCore

final class PeerMessengerTests: XCTestCase {
    let peer = "22222222-2222-4222-8222-222222222222"

    /// A relay over a scripted socket. `onEnvelope` sees every envelope the client sends and may
    /// return an envelope for the "phone" to send back.
    func makeMessenger(timeout: Duration = .seconds(5),
                       onEnvelope: @escaping @Sendable (PlatformEnvelope, RelayMessageType) -> PlatformEnvelope?) async throws -> (PeerMessenger, RelayClient, MockWebSocket) {
        let socket = MockWebSocket()
        let peer = self.peer
        socket.onClientMessage = { data, socket in
            if data == SignalR.handshakeRequest { socket.deliver(Data("{}".utf8) + [SignalR.recordSeparator]); return }
            for frame in (try? SignalR.splitFrames(data)) ?? [] {
                guard case .invocation(_, let id?, let target, let arguments)? = try? HubMessage(frame: frame) else { continue }
                socket.deliver(.completion(headers: .map([]), invocationId: id, resultKind: 3, value: .null))
                guard target == "SendMessageAsync", case .fragment(let fragment)? = try? DcgPacket(arguments[2]) else { continue }
                socket.deliver(RelayClientTests.inbound(from: peer, .ack(.init(sessionId: fragment.sessionId, sequenceNumber: fragment.sequenceNumber))))
                guard let envelope = try? PlatformEnvelope(decoding: fragment.raw), let reply = onEnvelope(envelope, fragment.messageType) else { continue }
                socket.deliver(RelayClientTests.inbound(from: peer, .fragment(.init(
                    sessionId: "phone-session", sequenceNumber: Int.random(in: 1...1_000_000), messageId: Int.random(in: 1...1_000_000),
                    messageType: fragment.messageType, fragmentId: 1, fragmentCount: 1, raw: reply.encoded()))))
            }
        }
        let hub = HubConnection(socket: socket)
        try await hub.start(keepAlive: .seconds(3600))
        let relay = RelayClient(hub: hub)
        await relay.start()
        let messenger = PeerMessenger(relay: relay, peer: peer, requestTimeout: timeout)
        Task {
            for await event in relay.events {
                if case .message(let message) = event { await messenger.receive(message) }
                if event == .closed { await messenger.connectionLost() }
            }
        }
        return (messenger, relay, socket)
    }

    func androidResponse(to request: PlatformEnvelope, payload: Data, rejected: String? = nil) -> PlatformEnvelope {
        var headers: [(key: String, value: String)] = [("ms-content-type", "application/x-binary"), ("_route", "/internal/response"),
                                                       ("_originalRequestId", request.requestId ?? "")]
        if let rejected { headers.append(("_rejectedReason", rejected)) }
        return PlatformEnvelope(headers: headers, payload: payload, convention: .android)
    }

    func testPlatformRequestUsesPhoneLinkHeaderOrderAndGetsItsResponse() async throws {
        let seen = EnvelopeRecorder()
        let (messenger, relay, _) = try await makeMessenger { envelope, type in
            seen.add(envelope, type)
            return self.androidResponse(to: envelope, payload: Data([0x0A, 0x03, 0x01, 0x02, 0x03, 0x10, 0x0E, 0x18, 0x03]))
        }
        let response = try await messenger.request(route: "/SessionValidation", payload: Data([0x0A, 0x01, 0x01]))
        XCTAssertEqual(response.payload.hex, "0a03010203100e1803")
        XCTAssertEqual(response.convention, .android)
        let (sent, type) = try XCTUnwrap(seen.all.first)
        XCTAssertEqual(type, .platform)
        XCTAssertEqual(sent.headers.map(\.key), ["_route", "ms-content-type", "_requestId", "_rejectionVersion"])
        XCTAssertEqual(sent["_requestId"], "1", "decimal counter")
        XCTAssertEqual(sent["ms-content-type"], "application/x-binary")
        XCTAssertEqual(sent["_rejectionVersion"], "1")
        XCTAssertEqual(sent.convention, .windows)
        _ = try await messenger.request(route: "/SessionValidation", payload: Data())
        XCTAssertEqual(seen.all.last?.0["_requestId"], "2")
        await relay.close()
    }

    func testAppRequestUsesGuidIdAndAppMessageType() async throws {
        let seen = EnvelopeRecorder()
        let (messenger, relay, _) = try await makeMessenger { envelope, type in
            seen.add(envelope, type)
            return PlatformEnvelope(headers: [("_route", "/internal/response"), ("_originalRequestId", envelope.requestId ?? "")], payload: Data([1]), convention: .android)
        }
        let response = try await messenger.appRequest(route: "/connect/v1", payload: Data([9]))
        XCTAssertEqual(response.payload, Data([1]))
        let (sent, type) = try XCTUnwrap(seen.all.first)
        XCTAssertEqual(type, .app)
        XCTAssertEqual(sent.route, "/connect/v1")
        XCTAssertEqual(sent.requestId?.count, 36)
        XCTAssertNil(sent["ms-content-type"])
        await relay.close()
    }

    func testRejectionBecomesAnError() async throws {
        let (messenger, relay, _) = try await makeMessenger { envelope, _ in
            self.androidResponse(to: envelope, payload: Data("{}".utf8), rejected: "NotSubscribedToRoute")
        }
        do {
            _ = try await messenger.request(route: "/Nope", payload: Data())
            XCTFail("expected rejection")
        } catch let error as PeerMessenger.MessagingError {
            XCTAssertEqual(error, .rejected(reason: "NotSubscribedToRoute"))
        }
        await relay.close()
    }

    func testRejectedReasonNoneIsSuccess() async throws {
        let (messenger, relay, _) = try await makeMessenger { envelope, _ in
            self.androidResponse(to: envelope, payload: Data([5]), rejected: "None")
        }
        let response = try await messenger.request(route: "/x", payload: Data())
        XCTAssertEqual(response.payload, Data([5]))
        await relay.close()
    }

    func testRequestTimesOut() async throws {
        let (messenger, relay, _) = try await makeMessenger(timeout: .milliseconds(40)) { _, _ in nil }
        do {
            _ = try await messenger.request(route: "/slow", payload: Data())
            XCTFail("expected timeout")
        } catch let error as PeerMessenger.MessagingError {
            XCTAssertEqual(error, .timedOut(route: "/slow"))
        }
        await relay.close()
    }

    func testIncomingRequestsReachHandlersAndCanBeAnswered() async throws {
        let seen = EnvelopeRecorder()
        let (messenger, relay, socket) = try await makeMessenger { envelope, type in seen.add(envelope, type); return nil }
        let received = EnvelopeRecorder()
        await messenger.handle("/Context/Publish") { request, messenger in
            received.add(request.envelope, request.type)
            try? await messenger.respond(to: request, payload: Data([0xAA]))
        }
        await messenger.handle("/Context/Message", prefix: true) { request, _ in received.add(request.envelope, request.type) }

        func deliver(route: String, id: String?) {
            var headers: [(key: String, value: String)] = [("ms-content-type", "application/x-binary"), ("_route", route), ("_rejectionVersion", "1")]
            if let id { headers.append(("_requestId", id)) }
            socket.deliver(RelayClientTests.inbound(from: peer, .fragment(.init(
                sessionId: "p", sequenceNumber: Int.random(in: 1...1_000_000), messageId: Int.random(in: 1...1_000_000), messageType: .platform,
                fragmentId: 1, fragmentCount: 1, raw: PlatformEnvelope(headers: headers, payload: Data([1]), convention: .android).encoded()))))
        }
        deliver(route: "/Context/Publish", id: "abc")
        deliver(route: "/Context/Message/1234", id: "def")
        deliver(route: "/Unknown/Route", id: "ghi")

        let done = await waitUntil { seen.all.count == 2 && received.all.count == 2 }
        XCTAssertTrue(done)
        XCTAssertEqual(received.all.map { $0.0.route }, ["/Context/Publish", "/Context/Message/1234"])
        // The two responses travel on different paths and may arrive in either order,
        // so each is looked up by the request it answers.
        let responses = seen.all.map(\.0)
        let served = try XCTUnwrap(responses.first { $0.originalRequestId == "abc" })
        let declined = try XCTUnwrap(responses.first { $0.originalRequestId == "ghi" })
        // Binary response: header order as Phone Link sends it.
        XCTAssertEqual(served.headers.map(\.key), ["_originalRequestId", "_route", "ms-content-type", "_rejectionVersion"])
        XCTAssertEqual(served.route, "/internal/response")
        XCTAssertEqual(served.payload, Data([0xAA]))
        // Unknown route: an empty JSON object with the rejection reason.
        XCTAssertEqual(declined["_rejectedReason"], "NotSubscribedToRoute")
        XCTAssertEqual(declined["ms-content-type"], "text/json")
        XCTAssertEqual(declined.payload, Data("{}".utf8))
        await relay.close()
    }

    func testConnectionLossFailsPendingRequests() async throws {
        let (messenger, _, socket) = try await makeMessenger { _, _ in nil }
        let pending = Task { try await messenger.request(route: "/x", payload: Data()) }
        let sent = await waitUntil { socket.sentHubMessages.count >= 1 }
        XCTAssertTrue(sent)
        try await Task.sleep(for: .milliseconds(20))
        socket.fail(URLError(.networkConnectionLost))
        do { _ = try await pending.value; XCTFail("expected failure") } catch {}
    }
}

final class EnvelopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(PlatformEnvelope, RelayMessageType)] = []
    var all: [(PlatformEnvelope, RelayMessageType)] { lock.lock(); defer { lock.unlock() }; return items }
    func add(_ envelope: PlatformEnvelope, _ type: RelayMessageType) { lock.lock(); items.append((envelope, type)); lock.unlock() }
}
