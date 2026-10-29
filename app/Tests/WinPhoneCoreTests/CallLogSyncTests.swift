import XCTest
@testable import WinPhoneCore

/// The call history. No capture holds any of this exchange (Windows had the feature off), so
/// the tests pin the messages to `protocol/specs/calls.md`.
final class CallLogSyncTests: XCTestCase {
    let sender = AppSender(displayName: "Mac", installationId: "INSTALL")

    func metadata(ids: [Int64], checksums: [Int64], sequence: Int64) -> ValueSet {
        ValueSet(["contentType": .string("callLogs"), "metadata": .int32(1), "itemCount": .int32(Int32(ids.count)), "callLogsIds": .int64Array(ids),
                  "callLogsLastUpdatedTimes": .int64Array(checksums), "sequenceNumber": .int64(sequence), "correlationVector": .string("cv-9")])
    }

    func batch(_ rows: [(id: Int64, number: String, date: Int64, duration: Int64, type: Int32, read: Bool, checksum: Int64)],
               actions: [Int32]? = nil, sequence: Int64? = nil) -> ValueSet {
        var entries: [String: ValueSet.Value] = [
            "contentType": .string("callLogs"), "itemCount": .int32(Int32(rows.count)), "callLogsIds": .int64Array(rows.map(\.id)),
            "callLogsPhoneNumbers": .stringArray(rows.map(\.number)), "callLogsDate": .int64Array(rows.map(\.date)),
            "callLogsDuration": .int64Array(rows.map(\.duration)), "callLogsType": .int32Array(rows.map(\.type)),
            "callLogsRead": .boolArray(rows.map(\.read)), "callLogsPhoneAccountIds": .stringArray(rows.map { _ in "1" }),
            "callLogsLastUpdatedTimes": .int64Array(rows.map(\.checksum)),
        ]
        if let actions { entries["actions"] = .int32Array(actions); entries["incremental"] = .int32(1) }
        if let sequence { entries["sequenceNumber"] = .int64(sequence) }
        return ValueSet(entries)
    }

    func testFullSyncAsksForWhatIsMissingAndStoresTheNumberWithTheLastBatch() async throws {
        let sync = CallLogSync(sender: sender)
        let answer = await sync.apply(metadata(ids: [1, 2, 3], checksums: [10, 20, 30], sequence: 7))
        XCTAssertEqual(answer["result"], .int32(0))
        XCTAssertEqual(answer["itemCount"], .int32(3), "an Int32, or the phone's cast fails")
        XCTAssertEqual(answer["callLogsIds"], .int64Array([1, 2, 3]), "the same key as in the list")
        XCTAssertEqual(answer.string("correlationVector"), "cv-9")
        var number = await sync.sequenceNumber
        XCTAssertEqual(number, -1, "not up to date until the rows have come")

        _ = await sync.apply(batch([(3, "+15550100", 3000, 0, 3, false, 30), (2, "", 2000, 0, 5, true, 20)]))
        number = await sync.sequenceNumber
        XCTAssertEqual(number, -1)
        // The first row was deleted on the phone in between and never arrives; the number does.
        let reply = await sync.apply(batch([], sequence: 7))
        XCTAssertEqual(reply["result"], .int32(0))
        number = await sync.sequenceNumber
        XCTAssertEqual(number, 7)
        let calls = await sync.list
        XCTAssertEqual(calls.map(\.id), [3, 2], "newest first")
        XCTAssertEqual(calls.map(\.kind), [.missed, .declined])
        XCTAssertEqual(calls[0].date, Date(timeIntervalSince1970: 3))
        XCTAssertFalse(calls[0].isRead)
    }

    func testALaterListDropsWhatIsGoneAndAsksOnlyForWhatChanged() async throws {
        let sync = CallLogSync(sender: sender)
        _ = await sync.apply(batch([(1, "+1", 1000, 5, 1, true, 10), (2, "+2", 2000, 0, 2, true, 20), (3, "+3", 3000, 0, 3, false, 30)], sequence: 4))
        let answer = await sync.apply(metadata(ids: [2, 3, 4], checksums: [20, 31, 40], sequence: 9))
        XCTAssertEqual(answer["callLogsIds"], .int64Array([3, 4]), "one changed, one new")
        XCTAssertEqual(answer["itemCount"], .int32(2))
        let left = await sync.list.map(\.id)
        XCTAssertEqual(left, [3, 2], "the call that aged out of the phone's list is gone")

        // Nothing wanted: an empty Int64 array, count 0, and the number is kept at once.
        _ = await sync.apply(batch([(3, "+3", 3000, 0, 3, true, 31), (4, "+4", 4000, 60, 1, true, 40)], sequence: 9))
        let upToDate = await sync.apply(metadata(ids: [2, 3, 4], checksums: [20, 31, 40], sequence: 12))
        XCTAssertEqual(upToDate["itemCount"], .int32(0))
        XCTAssertEqual(upToDate["callLogsIds"], .int64Array([]))
        let number = await sync.sequenceNumber
        XCTAssertEqual(number, 12)
    }

    func testIncrementalBatchesCreateUpdateAndDelete() async throws {
        let sync = CallLogSync(sender: sender)
        _ = await sync.apply(batch([(1, "+1", 1000, 5, 1, true, 10), (2, "+2", 2000, 0, 3, false, 20)], sequence: 4))
        // Deletions first, then updates, then creations, as the phone orders them.
        _ = await sync.apply(batch([(1, "", 0, 0, 0, false, 0), (2, "+2", 2000, 0, 3, true, 21), (5, "+5", 5000, 30, 2, true, 50), (6, "+6", 6000, 0, 6, true, 60)],
                                   actions: [2, 1, 0, 0], sequence: 5))
        let calls = await sync.list
        XCTAssertEqual(calls.map(\.id), [5, 2], "a blocked call is not listed, as in Phone Link")
        XCTAssertTrue(calls[1].isRead)
        XCTAssertEqual(calls[0].kind, .outgoing)
        let number = await sync.sequenceNumber
        XCTAssertEqual(number, 5)
    }

    func testTheHistoryIsKeptBetweenLaunchesAndDroppedWhenThePhoneStartsOver() async throws {
        let cache = MemoryBlobCache()
        let first = CallLogSync(sender: sender, cache: cache)
        _ = await first.apply(batch([(1, "+1", 1000, 5, 1, true, 10)], sequence: 4))
        try await Task.sleep(for: .milliseconds(1300))
        let second = CallLogSync(sender: sender, cache: cache)
        var number = await second.sequenceNumber
        XCTAssertEqual(number, 4)
        let kept = await second.list.map(\.id)
        XCTAssertEqual(kept, [1])
        var dropped = await second.reconcile(phoneNumber: 6, sent: 4)
        XCTAssertFalse(dropped)
        dropped = await second.reconcile(phoneNumber: 2, sent: 4)
        XCTAssertTrue(dropped)
        number = await second.sequenceNumber
        XCTAssertEqual(number, -1)
        XCTAssertNil(cache.load())
    }

    func testTheHandshakeNamesCallLogsOnlyWithTheSwitchOn() throws {
        let numbers: [String: Int64] = ["sms": 3, "call_logs": -1]
        let off = ConnectExchange.request(sender: sender, sequenceNumbers: numbers)
        XCTAssertEqual(off.object("configuration")?.bool("CallLogs"), false)
        XCTAssertNil(off.object("sequenceNumbers")?.entries["call_logs"], "with the switch off the key can hang the phone's handshake")
        XCTAssertEqual(off.object("configuration"), ConnectExchange.configuration, "unchanged from what Windows sent")

        let on = ConnectExchange.request(sender: sender, sequenceNumbers: numbers, callLogs: true)
        XCTAssertEqual(on.object("configuration")?.bool("CallLogs"), true)
        XCTAssertEqual(on.object("sequenceNumbers")?.entries["call_logs"], .int64(-1))
        var expected = ConnectExchange.configuration
        expected["CallLogs"] = .bool(true)
        XCTAssertEqual(on.object("configuration"), expected, "no other switch moves")
    }

    func testRefreshAndDialRequests() async throws {
        let phone = FakePhone()
        phone.responder = { envelope in
            switch envelope.route {
            case "/calling": return ValueSet(["result": .int32(7), "contractVersion": .double(3.99)]).serialized()
            case "/calling/dial": return ValueSet(["result": .int32(0), "contractVersion": .double(3.99)]).serialized()
            default: return nil
            }
        }
        let (messenger, relay) = try await phone.connect()
        let sync = CallLogSync(sender: sender)
        await sync.attach(messenger)
        try await sync.dial("*100#")
        let dial = try XCTUnwrap(phone.received(route: "/calling/dial").first.flatMap { try? ValueSet(serialized: $0.payload) })
        XCTAssertEqual(dial.string("contentType"), "dialOnPhone")
        XCTAssertEqual(dial.string("phoneNumber"), "*100%23", "a bare # would cut the number short on the phone")
        XCTAssertEqual(dial.double("contractVersion"), 3.99)
        do {
            try await sync.refresh()
            XCTFail("expected the permission error")
        } catch let error as CallLogSync.CallError {
            XCTAssertEqual(error, .needsPermission)
        }
        let refresh = try XCTUnwrap(phone.received(route: "/calling").first.flatMap { try? ValueSet(serialized: $0.payload) })
        XCTAssertEqual(refresh.string("contentType"), "callLogs")
        XCTAssertEqual(refresh.bool("isuserinitiated"), true)
        await relay.close()
    }

    /// Through the whole client: the switch decides what the handshake says and who answers
    /// the phone's call log pushes.
    func runSession(callLogs: Bool) async throws -> (handshake: ValueSet, answer: ValueSet, calls: [PhoneCall]?) {
        let sockets = LinkControllerTests.PhoneSockets()
        let (controller, _, _) = try await LinkControllerTests().makeController(sockets: sockets, clipboard: TestClipboard(), callLogs: callLogs)
        let log = LinkControllerTests.EventLog()
        let pump = Task { for await event in controller.events { log.append(event) } }
        defer { pump.cancel() }
        await controller.start()
        func phoneLink() -> FakePhone? { sockets.phones.first { !$0.received(route: ConnectExchange.route).isEmpty } }
        let shaken = await waitUntil(timeout: 5) { phoneLink() != nil }
        XCTAssertTrue(shaken)
        let phone = try XCTUnwrap(phoneLink())
        let handshake = try ValueSet(serialized: try XCTUnwrap(phone.received(route: ConnectExchange.route).first).payload)
        let id = UUID().uuidString.lowercased()
        phone.deliver(PlatformEnvelope(headers: [("_requestId", id), ("_route", "/legacy/phonecontent")],
                                       payload: metadata(ids: [1], checksums: [10], sequence: 3).serialized(), convention: .android), type: .app)
        let answered = await waitUntil { phone.responses(to: id).count == 1 }
        XCTAssertTrue(answered)
        let answer = try ValueSet(serialized: phone.responses(to: id)[0].payload)
        if callLogs {
            let next = UUID().uuidString.lowercased()
            phone.deliver(PlatformEnvelope(headers: [("_requestId", next), ("_route", "/legacy/phonecontent")],
                                           payload: batch([(1, "+15550100", 1000, 12, 1, true, 10)], sequence: 3).serialized(), convention: .android), type: .app)
            _ = await waitUntil { log.has { if case .calls(let calls) = $0 { return calls.count == 1 }; return false } }
        }
        var calls: [PhoneCall]?
        for event in log.events { if case .calls(let list) = event { calls = list } }
        await controller.disconnect()
        return (handshake, answer, calls)
    }

    func testWithTheSwitchOffNothingAboutCallsChanges() async throws {
        let (handshake, answer, calls) = try await runSession(callLogs: false)
        XCTAssertEqual(handshake.object("configuration")?.bool("CallLogs"), false)
        XCTAssertNil(handshake.object("sequenceNumbers")?.entries["call_logs"])
        XCTAssertEqual(answer["itemCount"], .int32(0), "an unasked call log list is answered \"nothing wanted\"")
        XCTAssertNil(calls)
    }

    func testWithTheSwitchOnTheHistoryIsAskedForAndShown() async throws {
        let (handshake, answer, calls) = try await runSession(callLogs: true)
        XCTAssertEqual(handshake.object("configuration")?.bool("CallLogs"), true)
        XCTAssertEqual(handshake.object("sequenceNumbers")?.entries["call_logs"], .int64(-1))
        XCTAssertEqual(answer["callLogsIds"], .int64Array([1]))
        XCTAssertEqual(calls?.map(\.number), ["+15550100"])
    }
}
