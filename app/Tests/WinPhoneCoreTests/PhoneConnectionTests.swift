import XCTest
@testable import WinPhoneCore

final class PhoneConnectionTests: XCTestCase {
    let ownId = "11111111-1111-4111-8111-111111111111"

    func fastTiming() -> PhoneConnection.Timing {
        var timing = PhoneConnection.Timing()
        timing.hubInfoWait = .milliseconds(200)
        timing.presenceGrace = .milliseconds(60)
        timing.wakeWait = .milliseconds(120)
        timing.heartbeatSeconds = 0
        return timing
    }

    func onConnected(_ socket: MockWebSocket, region: String = "WestEurope") {
        socket.deliver(.invocation(headers: .map([]), invocationId: nil, target: "OnConnected",
                                   arguments: [.map(["RegionName": .string(region), "Partners": .array([])])]))
    }

    func partnerConnected(_ socket: MockWebSocket) {
        socket.deliver(.invocation(headers: .map([]), invocationId: nil, target: "OnPartnerConnected",
                                   arguments: [.string(FakePhone.id), .null, .map(["RegionName": .string("WestEurope")])]))
    }

    func sendConnectedCount(_ socket: MockWebSocket) -> Int {
        socket.sentHubMessages.filter { if case .invocation(_, _, "SendConnectedAsync", _) = $0 { return true }; return false }.count
    }

    func makeConnection(_ phone: FakePhone, timing: PhoneConnection.Timing? = nil, wake: @escaping PhoneConnection.Wake) async throws -> PhoneConnection {
        let hub = HubConnection(socket: phone.socket)
        try await hub.start(keepAlive: .seconds(3600))
        return PhoneConnection(hub: hub, peer: FakePhone.id, ownId: ownId, timing: timing ?? fastTiming(), wake: wake)
    }

    /// The start sequence captured from Windows: announce, receive the hub region, wake with that
    /// region, the phone appears, and its announcement is answered.
    func testWakesWithTheHubRegionAndAnswersThePhonesAnnouncement() async throws {
        let phone = FakePhone()
        let wakes = WakeRecorder()
        let connection = try await makeConnection(phone) { region, high in
            await wakes.add(region, high)
            // The wake push reaches the phone, which then connects to the hub.
            self.partnerConnected(phone.socket)
        }
        let connecting = Task { try await connection.connect() }
        let announced = await waitUntil { self.sendConnectedCount(phone.socket) == 1 }
        XCTAssertTrue(announced, "presence is announced before anything else")
        onConnected(phone.socket, region: "NorthEurope")
        try await connecting.value

        let recorded = await wakes.all
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.region, "NorthEurope")
        XCTAssertEqual(recorded.first?.high, false, "the first wake has normal priority")
        let state = await connection.state
        XCTAssertEqual(state, .online)
        let answered = await waitUntil { self.sendConnectedCount(phone.socket) == 2 }
        XCTAssertTrue(answered, "the phone's announcement is answered with ours")
        await connection.close()
    }

    func testNoWakeWhenThePhoneIsAlreadyThere() async throws {
        let phone = FakePhone()
        let wakes = WakeRecorder()
        let connection = try await makeConnection(phone) { region, high in await wakes.add(region, high) }
        let connecting = Task { try await connection.connect() }
        _ = await waitUntil { self.sendConnectedCount(phone.socket) == 1 }
        onConnected(phone.socket)
        partnerConnected(phone.socket)
        try await connecting.value
        let recorded = await wakes.all
        XCTAssertTrue(recorded.isEmpty)
        await connection.close()
    }

    func testRetriesWithHighPriorityThenReportsUnreachable() async throws {
        let phone = FakePhone()
        let wakes = WakeRecorder()
        let connection = try await makeConnection(phone) { region, high in await wakes.add(region, high) }
        let connecting = Task { try await connection.connect() }
        _ = await waitUntil { self.sendConnectedCount(phone.socket) == 1 }
        onConnected(phone.socket)
        do {
            try await connecting.value
            XCTFail("expected the phone to be unreachable")
        } catch let error as PhoneConnection.ConnectionError {
            XCTAssertEqual(error, .phoneUnreachable)
        }
        let recorded = await wakes.all
        XCTAssertEqual(recorded.map(\.high), [false, true, true], "one wake, then two high-priority retries")
        let state = await connection.state
        XCTAssertEqual(state, .offline)
        await connection.close()
    }

    func testWakesWithoutARegionWhenTheHubStaysSilent() async throws {
        let phone = FakePhone()
        let wakes = WakeRecorder()
        var timing = fastTiming()
        timing.hubInfoWait = .milliseconds(40)
        timing.wakeRetries = 0
        let connection = try await makeConnection(phone, timing: timing) { region, high in
            await wakes.add(region, high)
            self.partnerConnected(phone.socket)
        }
        try await connection.connect()
        let recorded = await wakes.all
        XCTAssertEqual(recorded.count, 1)
        XCTAssertNil(recorded.first?.region)
        await connection.close()
    }

    func testIncomingDataMarksThePhonePresentAndReachesTheMessenger() async throws {
        let phone = FakePhone()
        let connection = try await makeConnection(phone) { _, _ in
            // The phone shows up by sending a request, without a presence event.
            phone.request(route: "/Unknown", payload: Data([1]))
        }
        let connecting = Task { try await connection.connect() }
        _ = await waitUntil { self.sendConnectedCount(phone.socket) == 1 }
        onConnected(phone.socket)
        try await connecting.value
        let state = await connection.state
        XCTAssertEqual(state, .online)
        // The unknown route is declined through the messenger, proving the message was routed.
        let declined = await waitUntil { phone.received(route: "/internal/response").contains { $0["_rejectedReason"] == "NotSubscribedToRoute" } }
        XCTAssertTrue(declined)
        await connection.close()
    }

    func testFeaturesWorkOverAnEstablishedConnection() async throws {
        let phone = FakePhone()
        phone.responder = { $0.route == "/SessionValidation" ? Data(hex: "0a03010203100e1803") : nil }
        let connection = try await makeConnection(phone) { _, _ in self.partnerConnected(phone.socket) }
        let connecting = Task { try await connection.connect() }
        _ = await waitUntil { self.sendConnectedCount(phone.socket) == 1 }
        onConnected(phone.socket)
        try await connecting.value
        let capabilities = try await SessionValidation.exchange(with: connection.messenger)
        XCTAssertEqual(capabilities?.persistentMessageChannelVersion, 14)
        await connection.close()
    }

    func testDisconnectAndCloseAreReported() async throws {
        let phone = FakePhone()
        let connection = try await makeConnection(phone) { _, _ in self.partnerConnected(phone.socket) }
        let connecting = Task { try await connection.connect() }
        _ = await waitUntil { self.sendConnectedCount(phone.socket) == 1 }
        onConnected(phone.socket)
        try await connecting.value
        phone.socket.deliver(.invocation(headers: .map([]), invocationId: nil, target: "OnPartnerDisconnected", arguments: [.string(FakePhone.id)]))
        let offline = await waitUntil { await connection.state == .offline }
        XCTAssertTrue(offline)
        // A heartbeat alone does not bring an absent phone back.
        phone.socket.deliver(.invocation(headers: .map([]), invocationId: nil, target: "OnPartnerHeartBeat",
                                         arguments: [.string(FakePhone.id), .string("x"), .int(1)]))
        try await Task.sleep(for: .milliseconds(40))
        let still = await connection.state
        XCTAssertEqual(still, .offline)
        phone.socket.fail(URLError(.networkConnectionLost))
        var seen: [PhoneConnection.State] = []
        for await state in connection.states { seen.append(state) }
        XCTAssertEqual(seen, [.waitingForPhone, .online, .offline, .closed])
    }
}

actor WakeRecorder {
    var all: [(region: String?, high: Bool)] = []
    func add(_ region: String?, _ high: Bool) { all.append((region, high)) }
}
