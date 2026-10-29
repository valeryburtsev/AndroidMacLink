import XCTest
@testable import WinPhoneCore

final class HubConnectionTests: XCTestCase {
    func testHandshakeThenInvocationCompletes() async throws {
        let socket = MockWebSocket.autoCompleting()
        let hub = HubConnection(socket: socket)
        try await hub.start(keepAlive: .seconds(3600))
        XCTAssertEqual(socket.sent.first, SignalR.handshakeRequest)

        let result = try await hub.invoke("SendConnectedAsync", arguments: [.string("target"), .map([])])
        XCTAssertEqual(result, .null)
        _ = try await hub.invoke("SendConnectedAsync", arguments: [])
        let sent = socket.sentHubMessages
        XCTAssertEqual(sent.count, 2)
        guard case .invocation(_, let firstId, let target, let arguments) = sent[0], case .invocation(_, let secondId, _, _) = sent[1] else { return XCTFail() }
        XCTAssertEqual(firstId, "1")
        XCTAssertEqual(secondId, "2")
        XCTAssertEqual(target, "SendConnectedAsync")
        XCTAssertEqual(arguments, [.string("target"), .map([])])
        await hub.close()
    }

    func testFramesCoalescedWithTheHandshakeAreNotLost() async throws {
        let socket = MockWebSocket()
        let onConnected = HubMessage.invocation(headers: .map([]), invocationId: nil, target: "OnConnected",
                                                arguments: [.map(["RegionName": .string("WestEurope"), "Partners": .array([])])])
        socket.onClientMessage = { data, socket in
            if data == SignalR.handshakeRequest { socket.deliver(Data("{}".utf8) + [SignalR.recordSeparator] + onConnected.framed) }
        }
        let hub = HubConnection(socket: socket)
        try await hub.start(keepAlive: .seconds(3600))
        var iterator = hub.events.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.target, "OnConnected")
        XCTAssertEqual(first?.arguments.first?["RegionName"]?.stringValue, "WestEurope")
        await hub.close()
    }

    func testInboundInvocationsArriveInOrderAcrossMessages() async throws {
        let socket = MockWebSocket.autoCompleting()
        let hub = HubConnection(socket: socket)
        try await hub.start(keepAlive: .seconds(3600))
        func event(_ n: Int) -> HubMessage { .invocation(headers: .map([]), invocationId: nil, target: "OnPartnerHeartBeat", arguments: [.int(Int64(n))]) }
        socket.deliver(event(1), .ping, event(2))
        socket.deliver(event(3))
        var seen: [Int64] = []
        for await invocation in hub.events {
            seen.append(invocation.arguments[0].intValue!)
            if seen.count == 3 { break }
        }
        XCTAssertEqual(seen, [1, 2, 3])
        await hub.close()
    }

    func testErrorCompletionThrows() async throws {
        let socket = MockWebSocket()
        socket.onClientMessage = { data, socket in
            if data == SignalR.handshakeRequest { socket.deliver(Data("{}".utf8) + [SignalR.recordSeparator]); return }
            socket.deliver(.completion(headers: .map([]), invocationId: "1", resultKind: 1, value: .string("target is offline")))
        }
        let hub = HubConnection(socket: socket)
        try await hub.start(keepAlive: .seconds(3600))
        do {
            _ = try await hub.invoke("SendMessageAsync", arguments: [])
            XCTFail("expected failure")
        } catch let error as HubConnection.HubError {
            XCTAssertEqual(error, .invocationFailed("target is offline"))
        }
        await hub.close()
    }

    func testConnectionLossFailsPendingInvocationsAndEndsEvents() async throws {
        let socket = MockWebSocket()
        socket.onClientMessage = { data, socket in
            if data == SignalR.handshakeRequest { socket.deliver(Data("{}".utf8) + [SignalR.recordSeparator]) }
        }
        let hub = HubConnection(socket: socket)
        try await hub.start(keepAlive: .seconds(3600))
        let pending = Task { try await hub.invoke("SendMessageAsync", arguments: []) }
        let sentInvocation = await waitUntil { socket.sentHubMessages.count == 1 }
        XCTAssertTrue(sentInvocation)
        socket.fail(URLError(.networkConnectionLost))
        do {
            _ = try await pending.value
            XCTFail("expected failure")
        } catch let error as HubConnection.HubError {
            guard case .closed = error else { return XCTFail("\(error)") }
        }
        for await _ in hub.events { XCTFail("no events expected") }
        let closed = await hub.isClosed
        XCTAssertTrue(closed)
        do { _ = try await hub.invoke("x", arguments: []); XCTFail() } catch {}
    }

    func testHandshakeRejectionIsReported() async {
        let socket = MockWebSocket()
        socket.onClientMessage = { _, socket in socket.deliver(Data(#"{"error":"Requested protocol 'messagepack' is not available."}"#.utf8) + [SignalR.recordSeparator]) }
        do {
            try await HubConnection(socket: socket).start()
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? SignalR.FramingError, .handshakeRejected("Requested protocol 'messagepack' is not available."))
        }
    }

    func testKeepAlivePingsAreSent() async throws {
        let socket = MockWebSocket.autoCompleting()
        let hub = HubConnection(socket: socket)
        try await hub.start(keepAlive: .milliseconds(20))
        let pinged = await waitUntil { socket.sentHubMessages.filter { $0 == .ping }.count >= 2 }
        XCTAssertTrue(pinged)
        await hub.close()
    }
}
