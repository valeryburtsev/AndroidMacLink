import SwiftProtobuf
import XCTest
@testable import WinPhoneCore

final class ValueSetTests: XCTestCase {
    func testRoundTripOfEveryModelledType() throws {
        let nested = ValueSet(["inner": .string("x")])
        let values = ValueSet([
            "i32": .int32(-5), "i64": .int64(1_791_534_262_000), "d": .double(3.99), "b": .bool(true), "s": .string("héllo"),
            "ia": .int32Array([1, 2, 3]), "la": .int64Array([10, 20]), "sa": .stringArray(["a", ""]), "o": .object(nested),
            "emptyArray": .stringArray([]),
        ])
        let decoded = try ValueSet(serialized: values.serialized())
        XCTAssertEqual(decoded, values)
        XCTAssertEqual(decoded.int("i32"), -5)
        XCTAssertEqual(decoded.int("i64"), 1_791_534_262_000)
        XCTAssertEqual(decoded.double("d"), 3.99)
        XCTAssertEqual(decoded.strings("sa"), ["a", ""])
        XCTAssertNil(decoded.string("i32"), "accessors are type-strict")
    }

    func testWireFormMatchesTheSchema() throws {
        // entries { key: "result" value { value_type: Int32 (4), int32_value: 7 } }
        let bytes = ValueSet(["result": .int32(7)]).serialized()
        // 0a 0e            entries, 14 bytes
        //   0a 06 "result" key
        //   12 04          value, 4 bytes
        //     08 04        value_type = Int32
        //     28 07        int32_value = 7
        XCTAssertEqual(bytes.hex, "0a0e0a06726573756c74120408042807")
        let message = try Pbvalueset_ValueSet(serializedBytes: bytes)
        XCTAssertEqual(message.entries["result"]?.valueType, .int32)
        XCTAssertEqual(message.entries["result"]?.int32Value, 7)
    }

    func testUnmodelledTypesSurviveARoundTrip() throws {
        var variant = Pbvalueset_DataVariant()
        variant.valueType = .guid
        variant.guidValue = "11111111-2222-4333-8444-555555555555"
        var message = Pbvalueset_ValueSet()
        message.entries["g"] = variant
        let decoded = try ValueSet(serialized: try message.serializedData())
        XCTAssertEqual(decoded["g"], .other(variant))
        XCTAssertEqual(try Pbvalueset_ValueSet(serializedBytes: decoded.serialized()), message)
    }

    /// Decodes every APP payload in the local captures, when they are present. The captures are
    /// not part of the repository, so this is skipped elsewhere.
    func testRealAppPayloadsDecode() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let capture = root.appendingPathComponent("captures/vm-pairing-2026-10-09/flows.jsonl")
        guard let text = try? String(contentsOf: capture, encoding: .utf8) else { throw XCTSkip("no local capture") }
        var decoded = 0, withContract = 0
        var routes: Set<String> = []
        for line in text.split(separator: "\n") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["type"] as? String == "ws", let frames = record["frames"] as? [[String: Any]] else { continue }
            for frame in frames {
                for argument in frame["arguments"] as? [Any] ?? [] {
                    guard let packet = argument as? [String: Any], let properties = packet["Properties"] as? [String: Any],
                          (properties["MessageType"] as? NSNumber)?.intValue == 0, (properties["FragmentCount"] as? NSNumber)?.intValue == 1,
                          let raw = packet["Raw"] as? [String: Any], let base64 = raw["bytes_b64"] as? String,
                          let bytes = Data(base64Encoded: base64) else { continue }
                    let envelope = try PlatformEnvelope(decoding: bytes)
                    if envelope["_isGzippedCompressed"]?.lowercased() == "true" { continue }
                    let values = try ValueSet(serialized: envelope.payload)
                    decoded += 1
                    if let route = envelope.route { routes.insert(route) }
                    if let version = values.double("contractVersion") {
                        XCTAssertEqual(version, 3.99)
                        withContract += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(decoded, 4)
        XCTAssertGreaterThan(withContract, 2)
        XCTAssertTrue(routes.contains("/connect/v1"), "\(routes)")
    }
}

final class PhoneNotificationTests: XCTestCase {
    static let messagingJSON = """
    {"key":"0|com.example.chat|42|null|10123","id":42,"groupKey":"g","packageName":"com.example.chat","appName":"Chat",
     "postTime":1791534262123,"timestamp":1791534262000,"isClearable":true,"isGroup":false,"isOngoing":false,"flags":0,
     "priority":1,"eventCount":0,"importance":4,"featureFlags":3,"platform":0,"version":"35","notificationClass":0,
     "template":"android.app.Notification$MessagingStyle","title":"Ada","text":"See you at 5",
     "messages":["Hi","See you at 5"],"senderNames":["Ada","Ada"],
     "notificationActions":[{"actionName":"Reply","isActionInlineReply":true,"actionIndex":0},
                            {"actionName":"Mark as read","isActionInlineReply":false,"actionIndex":2}]}
    """

    func testParsesTheDocumentedSchema() throws {
        let n = try XCTUnwrap(PhoneNotification(json: Self.messagingJSON))
        XCTAssertEqual(n.key, "0|com.example.chat|42|null|10123")
        XCTAssertEqual(n.packageName, "com.example.chat")
        XCTAssertEqual(n.appName, "Chat")
        XCTAssertEqual(n.postTime, 1_791_534_262_123)
        XCTAssertEqual(n.title, "Ada")
        XCTAssertEqual(n.importance, 4)
        XCTAssertEqual(n.messages.map(\.text), ["Hi", "See you at 5"])
        XCTAssertEqual(n.displayBody, "Ada: See you at 5")
        XCTAssertEqual(n.replyAction, .init(name: "Reply", isInlineReply: true, index: 0))
        XCTAssertEqual(n.buttonActions, [.init(name: "Mark as read", isInlineReply: false, index: 2)], "action indexes may have gaps")
    }

    func testBodyFallsBackThroughTheTextFields() throws {
        func make(_ extra: String) throws -> PhoneNotification {
            try XCTUnwrap(PhoneNotification(json: #"{"key":"k","packageName":"p","postTime":1\#(extra)}"#))
        }
        XCTAssertEqual(try make("").displayBody, "")
        XCTAssertEqual(try make(#","text":"short""#).displayBody, "short")
        XCTAssertEqual(try make(#","text":"short","bigText":"long form""#).displayBody, "long form")
        XCTAssertEqual(try make(#","text":"short","textLines":["a","b"]"#).displayBody, "a\nb")
        XCTAssertEqual(try make("").appName, "")
        XCTAssertNil(try make("").replyAction)
    }

    func testRequiredFields() {
        XCTAssertNil(PhoneNotification(json: #"{"packageName":"p","postTime":1}"#))
        XCTAssertNil(PhoneNotification(json: #"{"key":"k","postTime":1}"#))
        XCTAssertNil(PhoneNotification(json: #"{"key":"k","packageName":"p"}"#))
        XCTAssertNil(PhoneNotification(json: ""))
        XCTAssertNil(PhoneNotification(json: "[1,2]"))
    }

    func testAtMostThreeButtons() throws {
        let actions = (0..<6).map { #"{"actionName":"A\#($0)","isActionInlineReply":false,"actionIndex":\#($0)}"# }.joined(separator: ",")
        let n = try XCTUnwrap(PhoneNotification(json: #"{"key":"k","packageName":"p","postTime":1,"notificationActions":[\#(actions)]}"#))
        XCTAssertEqual(n.buttonActions.map(\.name), ["A0", "A1", "A2"])
    }
}

final class NotificationSyncTests: XCTestCase {
    struct Rig {
        let phone: FakePhone
        let relay: RelayClient
        let sync: NotificationSync
    }

    /// `result` is what the fake phone answers to `/notifications` commands.
    func makeRig(result: Int32 = 0) async throws -> Rig {
        let phone = FakePhone()
        phone.responder = { envelope in
            guard envelope.route == "/notifications" else { return nil }
            return ValueSet(["result": .int32(result), "contractVersion": .double(3.99)]).serialized()
        }
        let (messenger, relay) = try await phone.connect()
        let sync = NotificationSync(messenger: messenger, displayName: "Mac", installationId: "install-1")
        await sync.start()
        return Rig(phone: phone, relay: relay, sync: sync)
    }

    func push(_ phone: FakePhone, keys: [String], operations: [Int32], documents: [String], contentType: String = "notifications") -> String {
        let values = ValueSet([
            "contentType": .string(contentType), "contractVersion": .double(3.99), "correlationVector": .string("cv"),
            "installationId": .string("phone"), "displayName": .string("Phone"), "dedupeID": .string(""), "retryCount": .int32(0),
            "incremental": .int32(1), "notificationKeys": .stringArray(keys), "operations": .int32Array(operations),
            "notifications": .stringArray(documents),
        ])
        let id = UUID().uuidString.lowercased()
        phone.deliver(PlatformEnvelope(headers: [("_requestId", id), ("_route", "/legacy/phonecontent")], payload: values.serialized(), convention: .android), type: .app)
        return id
    }

    func json(_ key: String, postTime: Int64 = 100, text: String = "t") -> String {
        #"{"key":"\#(key)","packageName":"com.example","appName":"Example","postTime":\#(postTime),"text":"\#(text)"}"#
    }

    func reply(_ phone: FakePhone, to id: String) async throws -> (PlatformEnvelope, ValueSet) {
        let arrived = await waitUntil { phone.responses(to: id).count == 1 }
        XCTAssertTrue(arrived)
        let envelope = phone.responses(to: id)[0]
        return (envelope, try ValueSet(serialized: envelope.payload))
    }

    func testPushIsAppliedAndAnsweredWithResultZero() async throws {
        let rig = try await makeRig()
        let id = push(rig.phone, keys: ["a", "b"], operations: [1, 3], documents: [json("a", postTime: 200), json("b", postTime: 100)])
        let (envelope, values) = try await reply(rig.phone, to: id)
        XCTAssertEqual(values.int("result"), 0)
        XCTAssertEqual(envelope.route, "/internal/response")
        XCTAssertNil(envelope["ms-content-type"], "APP messages carry no content type")
        let known = await rig.sync.notifications
        XCTAssertEqual(known.map(\.key), ["a", "b"], "newest first")

        var changes: [NotificationSync.Change] = []
        for await change in rig.sync.changes {
            changes.append(change)
            if changes.count == 2 { break }
        }
        guard case .upsert(let first, let firstAlert) = changes[0], case .upsert(let second, let secondAlert) = changes[1] else { return XCTFail() }
        XCTAssertEqual([first.key, second.key], ["a", "b"])
        XCTAssertTrue(firstAlert, "operation 1 is a new notification")
        XCTAssertFalse(secondAlert, "operation 3 already existed on the phone")
        await rig.relay.close()
    }

    func testRemovalAndUpdate() async throws {
        let rig = try await makeRig()
        _ = try await reply(rig.phone, to: push(rig.phone, keys: ["a"], operations: [1], documents: [json("a", text: "one")]))
        _ = try await reply(rig.phone, to: push(rig.phone, keys: ["a"], operations: [1], documents: [json("a", text: "two")]))
        var known = await rig.sync.notifications
        XCTAssertEqual(known.map(\.text), ["two"], "an update replaces by key")
        // A removal for a key we never saw is normal and must not be reported.
        _ = try await reply(rig.phone, to: push(rig.phone, keys: ["a", "never-seen"], operations: [2, 2], documents: ["", ""]))
        known = await rig.sync.notifications
        XCTAssertTrue(known.isEmpty)
        var changes: [NotificationSync.Change] = []
        for await change in rig.sync.changes {
            changes.append(change)
            if changes.count == 3 { break }
        }
        XCTAssertEqual(changes.last, .removed(key: "a"))
        await rig.relay.close()
    }

    func testMalformedPushIsAnsweredWithAnEmptySet() async throws {
        let rig = try await makeRig()
        let id = push(rig.phone, keys: ["a", "b"], operations: [1], documents: [json("a")])     // lengths differ
        let (_, values) = try await reply(rig.phone, to: id)
        XCTAssertTrue(values.entries.isEmpty)
        let known = await rig.sync.notifications
        XCTAssertTrue(known.isEmpty)
        // An unparseable document is skipped; the rest of the batch is applied.
        _ = try await reply(rig.phone, to: push(rig.phone, keys: ["bad", "ok"], operations: [1, 1], documents: ["{not json", json("ok")]))
        let after = await rig.sync.notifications
        XCTAssertEqual(after.map(\.key), ["ok"])
        await rig.relay.close()
    }

    func testOtherContentTypesOnTheSameRouteAreNotMistakenForNotifications() async throws {
        let rig = try await makeRig()
        let id = push(rig.phone, keys: [], operations: [], documents: [], contentType: "messages")
        let (_, values) = try await reply(rig.phone, to: id)
        XCTAssertEqual(values.int("result"), ScenarioResult.unknownType.rawValue)
        await rig.relay.close()
    }

    func commands(_ phone: FakePhone) -> [ValueSet] {
        phone.received(route: "/notifications").compactMap { try? ValueSet(serialized: $0.payload) }
    }

    func testCommandsCarryTheDocumentedKeys() async throws {
        let rig = try await makeRig()
        _ = try await reply(rig.phone, to: push(rig.phone, keys: ["a", "b"], operations: [1, 1], documents: [json("a", postTime: 200), json("b", postTime: 100)]))

        try await rig.sync.dismiss(key: "a")
        try await rig.sync.clear()
        try await rig.sync.clear(keys: ["a", "b"])
        try await rig.sync.reconcile()
        try await rig.sync.openOnPhone(key: "a")
        try await rig.sync.invoke(action: .init(name: "Mark as read", isInlineReply: false, index: 2), key: "a")
        try await rig.sync.reply("on my way", to: "a", action: .init(name: "Reply", isInlineReply: true, index: 0))

        let sent = commands(rig.phone)
        XCTAssertEqual(sent.count, 7)
        for values in sent {
            XCTAssertEqual(values.string("contentType"), "notifications")
            XCTAssertEqual(values.double("contractVersion"), 3.99)
            XCTAssertEqual(values.string("correlationVector")?.count, 16)
            XCTAssertEqual(values.string("displayName"), "Mac")
            XCTAssertEqual(values.string("installationId"), "install-1")
            XCTAssertEqual(values.string("appVersion"), "1.26072.257.0")
            XCTAssertEqual(values.int("transportType"), 0)
        }
        XCTAssertEqual(sent.map { $0.int("operation") }, [2, 4, 4, 3, 5, 5, 5])
        XCTAssertEqual(sent[0].string("key"), "a")
        XCTAssertEqual(sent[1].strings("notificationKeys"), ["a", "b"], "clear all lists every key held, as Windows does")
        XCTAssertEqual(sent[2].strings("notificationKeys"), ["a", "b"])
        XCTAssertEqual(sent[3].strings("notificationKeys"), ["a", "b"])
        XCTAssertEqual(sent[3].int64s("postTimes"), [200, 100], "post times parallel the keys")
        XCTAssertEqual(sent[3].int("notificationKeysCount"), 2)
        XCTAssertNil(sent[4]["actionIndex"], "opening on the phone carries no action")
        XCTAssertEqual(sent[5].int("actionIndex"), 2)
        XCTAssertNil(sent[5]["inlineReplyMessage"])
        XCTAssertEqual(sent[6].int("actionIndex"), 0)
        XCTAssertEqual(sent[6].string("inlineReplyMessage"), "on my way")

        // Envelope shape of an APP request, as captured: GUID request ID, route, rejection version.
        let envelope = rig.phone.received(route: "/notifications")[0]
        XCTAssertEqual(envelope.headers.map(\.key), ["_requestId", "_route", "_rejectionVersion"])
        await rig.relay.close()
    }

    func testReconcileWithNothingKnownRequestsAFullList() async throws {
        let rig = try await makeRig()
        try await rig.sync.reconcile()
        let sent = try XCTUnwrap(commands(rig.phone).first)
        XCTAssertEqual(sent.strings("notificationKeys"), [])
        XCTAssertEqual(sent.int64s("postTimes"), [])
        await rig.relay.close()
    }

    func testAButtonThePhoneCannotPressAlthoughItHoldsTheRightIsNotBlamedOnAPermission() async throws {
        // As on 2026-10-13: the button answered "needs permission", and asked silently the
        // phone said it holds "appear on top".
        let phone = FakePhone()
        phone.responder = { envelope in
            switch envelope.route {
            case "/notifications": return ValueSet(["result": .int32(7), "contractVersion": .double(3.99)]).serialized()
            case "/permission": return ValueSet(["result": .int32(Int32(ScenarioResult.userAccepted.rawValue)), "contractVersion": .double(3.99)]).serialized()
            default: return nil
            }
        }
        let (messenger, relay) = try await phone.connect()
        let sync = NotificationSync(messenger: messenger, displayName: "Mac", installationId: "install-1")
        await sync.start()
        await sync.setRetryPause(.milliseconds(10))
        do {
            try await sync.invoke(action: .init(name: "Mark as read", isInlineReply: false, index: 2), key: "a")
            XCTFail()
        } catch let error as NotificationSync.CommandError {
            XCTAssertEqual(error, .cannotStartInBackground)
            let words = LinkController.describe(error)
            XCTAssertTrue(words.contains("Restarting"))
            XCTAssertFalse(words.contains("Allow"), "nothing to allow: it is held")
        }
        await relay.close()
    }

    func testPermissionAndFailureResults() async throws {
        var rig = try await makeRig(result: 7)
        do { try await rig.sync.dismiss(key: "a"); XCTFail() } catch let error as NotificationSync.CommandError { XCTAssertEqual(error, .needsPermission) }
        await rig.relay.close()

        rig = try await makeRig(result: 1)
        do { try await rig.sync.dismiss(key: "a"); XCTFail() } catch let error as NotificationSync.CommandError { XCTAssertEqual(error, .failed(.failure)) }
        await rig.relay.close()

        // For a button, "needs permission" is the phone asking its user for "appear on top"
        // (seen on 2026-10-13 with "Mark as read"); a reply is sent without it.
        rig = try await makeRig(result: 7)
        await rig.sync.setRetryPause(.milliseconds(10))
        do {
            try await rig.sync.invoke(action: .init(name: "Mark as read", isInlineReply: false, index: 2), key: "a")
            XCTFail()
        } catch let error as NotificationSync.CommandError {
            XCTAssertEqual(error, .needsAppearOnTop)
            XCTAssertTrue(LinkController.describe(error).contains("appear on top"))
        }
        XCTAssertEqual(commands(rig.phone).filter { $0.int("operation") == 5 }.count, 2, "tried once more before giving up")
        XCTAssertFalse(LinkController.describe(NotificationSync.CommandError.failed(.failure)).contains("failed("), "in words, not the error's name")
        XCTAssertFalse(LinkController.describe(NotificationSync.CommandError.needsPermission).contains("needsPermission"))
        await rig.relay.close()

        // Result 20 means the action brought an app to the foreground: fine for an action, not for a dismiss.
        rig = try await makeRig(result: 20)
        try await rig.sync.invoke(action: .init(name: "Open", isInlineReply: false, index: 1), key: "a")
        do { try await rig.sync.dismiss(key: "a"); XCTFail() } catch let error as NotificationSync.CommandError { XCTAssertEqual(error, .failed(.appLaunched)) }
        await rig.relay.close()

        // Results Phone Link treats as finished: cancelled or coalesced.
        rig = try await makeRig(result: 11)
        try await rig.sync.dismiss(key: "a")
        await rig.relay.close()
    }
}

/// Checks against the notification exchange captured between the phone and Windows on
/// 2026-10-09 (test notifications posted from the adb shell; names replaced, lengths kept).
final class CapturedNotificationTests: XCTestCase {
    struct Entry: Decodable { let dir: String, route: String, hex: String }

    func entries() throws -> [Entry] {
        try JSONDecoder().decode([Entry].self, from: Data(contentsOf: Fixtures.url("notifications.json")))
    }

    func makeSync() -> NotificationSync {
        let hub = HubConnection(socket: MockWebSocket.autoCompleting())
        let messenger = PeerMessenger(relay: RelayClient(hub: hub), peer: FakePhone.id)
        return NotificationSync(messenger: messenger, displayName: "Mac", installationId: "I")
    }

    func testRealPushesParseAndOurRepliesEqualTheOnesWindowsSent() async throws {
        let all = try entries()
        let pushes = all.filter { $0.dir == "s2c" && $0.route == NotificationSync.pushRoute }
        let replies = all.filter { $0.dir == "c2s" && $0.route == PeerMessenger.responseRoute }
        XCTAssertEqual(pushes.count, 6)
        XCTAssertEqual(replies.count, 6)
        let sync = makeSync()
        var changes: [NotificationSync.Change] = []
        let collector = Task { () -> [NotificationSync.Change] in
            var seen: [NotificationSync.Change] = []
            for await change in sync.changes { seen.append(change); if seen.count == 6 { break } }
            return seen
        }
        for (push, reply) in zip(pushes, replies) {
            let request = try PlatformEnvelope(decoding: Data(hex: push.hex))
            // The phone's APP requests carry only a request ID and the route.
            XCTAssertEqual(request.headers.map(\.key), ["_requestId", "_route"])
            let values = try ValueSet(serialized: request.payload)
            XCTAssertEqual(values.string("contentType"), "notifications")
            XCTAssertEqual(values.int32s("operations"), [1])
            XCTAssertEqual(values.strings("notificationKeys")?.count, 1)

            let answer = await sync.apply(values)
            let ours = try XCTUnwrap(PeerMessenger.responseEnvelope(to: request, payload: answer.serialized(), contentType: nil, result: answer.int("result")))
            XCTAssertEqual(ours.encoded().hex, reply.hex, "our reply is byte-identical to the one Windows sent")
        }
        changes = await collector.value
        let notifications = changes.compactMap { change -> (PhoneNotification, Bool)? in
            if case .upsert(let n, let alert) = change { return (n, alert) }
            return nil
        }
        XCTAssertEqual(notifications.count, 6)
        let first = notifications[0].0
        XCTAssertEqual(first.key, "0|com.android.shell|2020|winphone1|2000")
        XCTAssertEqual(first.packageName, "com.android.shell")
        XCTAssertEqual(first.appName, "Shell")
        XCTAssertEqual(first.title, "WinPhone test 1")
        XCTAssertEqual(first.displayBody, "Hello from the Mac, message 1")
        XCTAssertEqual(first.importance, 3)
        XCTAssertTrue(first.isClearable)
        XCTAssertFalse(first.isOngoing)
        XCTAssertEqual(first.notificationClass, 0)
        XCTAssertTrue(first.actions.isEmpty)

        // Each test notification was posted twice, four seconds apart (two runs of the helper
        // overlapped), so every key arrives as a post and then as an update. Both alert.
        XCTAssertEqual(notifications.filter(\.1).count, 6)
        XCTAssertEqual(Set(notifications.map(\.0.key)).count, 3)
        let stored = await sync.notifications
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(stored.map(\.title), ["WinPhone test 3", "WinPhone test 2", "WinPhone test 1"], "newest first")
    }

    func testAnUpdateAlertsAgainUnlessAndroidSaysOnce() async {
        let sync = makeSync()
        func push(_ text: String, flags: Int = 0, time: Int = 1) -> ValueSet {
            let json = #"{"key":"k","packageName":"p","postTime":\#(time),"text":"\#(text)","flags":\#(flags)}"#
            return ValueSet(["notificationKeys": .stringArray(["k"]), "operations": .int32Array([1]), "notifications": .stringArray([json])])
        }
        let collector = Task { () -> [Bool] in
            var alerts: [Bool] = []
            for await change in sync.changes {
                if case .upsert(_, let alert) = change { alerts.append(alert) }
                if alerts.count == 4 { break }
            }
            return alerts
        }
        _ = await sync.apply(push("one"))
        _ = await sync.apply(push("one", time: 2))
        _ = await sync.apply(push("two", time: 3))
        _ = await sync.apply(push("three", flags: 8, time: 4))
        let alerts = await collector.value
        XCTAssertEqual(alerts, [true, true, true, false], "only the flagged update stays quiet")
    }
}

/// The commands Windows sent when the user opened the notification list, dismissed one test
/// notification and the phone confirmed (capture of 2026-10-09, 12:49; names replaced).
final class CapturedNotificationCommandTests: XCTestCase {
    struct Entry: Decodable { let dir: String, route: String, hex: String }

    func entries() throws -> [(Entry, PlatformEnvelope, ValueSet)] {
        let all = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: Fixtures.url("notification-commands.json")))
        return try all.map { entry in
            let envelope = try PlatformEnvelope(decoding: Data(hex: entry.hex))
            return (entry, envelope, try ValueSet(serialized: envelope.payload))
        }
    }

    /// A sync that presents itself with the captured PC's identity, so only random fields differ.
    func makeSync(like real: ValueSet) -> NotificationSync {
        let hub = HubConnection(socket: MockWebSocket.autoCompleting())
        let messenger = PeerMessenger(relay: RelayClient(hub: hub), peer: FakePhone.id)
        return NotificationSync(messenger: messenger, displayName: real.string("displayName") ?? "", appVersion: real.string("appVersion") ?? "",
                                installationId: real.string("installationId") ?? "")
    }

    /// Equal except for the values that are random per request.
    func assertSameShape(_ ours: ValueSet, _ real: ValueSet, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        var a = ours, b = real
        for key in ["correlationVector", "permissionSessionId"] {
            XCTAssertEqual(a.string(key)?.count, b.string(key)?.count, "\(what): length of \(key)", file: file, line: line)
            a[key] = nil; b[key] = nil
        }
        XCTAssertEqual(a, b, what, file: file, line: line)
    }

    func testOurCommandsEqualTheOnesWindowsSent() async throws {
        let all = try entries()
        let commands = all.filter { $0.0.dir == "c2s" && $0.0.route != PeerMessenger.responseRoute }
        XCTAssertEqual(commands.map(\.0.route), ["/permission", "/notifications", "/notifications"])
        let sync = makeSync(like: commands[0].2)

        // Envelope: request ID, then route, then the rejection version.
        for (_, envelope, _) in commands {
            let ours = PeerMessenger.appRequestEnvelope(route: envelope.route ?? "", id: envelope.requestId ?? "", payload: envelope.payload)
            XCTAssertEqual(ours.encoded(), envelope.encoded())
            XCTAssertEqual(envelope.headers.map(\.key), ["_requestId", "_route", "_rejectionVersion"])
        }

        // 1. The permission question, asked aloud the first time.
        let permission = await sync.permissionPayload(silent: false)
        assertSameShape(permission, commands[0].2, "permission request")
        XCTAssertEqual(commands[0].2.string("permissionSessionId")?.first, "{")

        // 2. Reconcile with the three test notifications the PC already held, newest first.
        let pushes = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: Fixtures.url("notifications.json")))
            .filter { $0.dir == "s2c" }
        for push in pushes {
            _ = await sync.apply(try ValueSet(serialized: PlatformEnvelope(decoding: Data(hex: push.hex)).payload))
        }
        let reconcile = await sync.commandPayload(3, sync.reconcileFields())
        assertSameShape(reconcile, commands[1].2, "reconcile")
        XCTAssertEqual(commands[1].2.int64s("postTimes")?.count, 3)

        // 3. Dismiss one notification.
        let key = try XCTUnwrap(commands[2].2.string("key"))
        let dismiss = await sync.commandPayload(2, ["key": .string(key)])
        assertSameShape(dismiss, commands[2].2, "dismiss")
        XCTAssertEqual(commands[2].2.bool("isuserinitiated"), false)
    }

    func testThePhonesAnswersAreUnderstood() async throws {
        let all = try entries()
        let sync = makeSync(like: all[0].2)
        // The phone answers a permission request with "user accepted" once access is granted,
        // and commands with success plus its contract version.
        let answers = all.filter { $0.0.dir == "s2c" && $0.0.route == PeerMessenger.responseRoute }
        XCTAssertEqual(answers.map { $0.2.int("result") }, [ScenarioResult.userAccepted.rawValue, 0, 0])
        XCTAssertTrue(answers.allSatisfy { $0.1.headers.map(\.key) == ["_originalRequestId", "_route"] })

        let collector = Task { () -> [NotificationSync.Change] in
            var seen: [NotificationSync.Change] = []
            for await change in sync.changes { seen.append(change); if seen.count == 3 { break } }
            return seen
        }
        let pushes = all.filter { $0.0.dir == "s2c" && $0.0.route == NotificationSync.pushRoute }
        let replies = all.filter { $0.0.dir == "c2s" && $0.0.route == PeerMessenger.responseRoute }
        XCTAssertEqual(pushes.count, 2)

        // A permission push: notification access (type 64) is now granted (state 0).
        XCTAssertEqual(pushes[0].2.string("contentType"), "permissions")
        let first = await sync.applyPermissions(pushes[0].2)
        // Then hold the notification that the removal push refers to, and apply the removal.
        let key = try XCTUnwrap(pushes[1].2.strings("notificationKeys")?.first)
        _ = await sync.apply(ValueSet(["notificationKeys": .stringArray([key]), "operations": .int32Array([3]),
                                       "notifications": .stringArray([#"{"key":"\#(key)","packageName":"p","postTime":1}"#])]))
        XCTAssertEqual(pushes[1].2.int32s("operations"), [2])
        XCTAssertEqual(pushes[1].2.strings("notifications"), [""], "a removal carries an empty document")
        let second = await sync.apply(pushes[1].2)

        // Our replies to both pushes are the bytes Windows sent.
        for ((_, request, _), (answer, (_, real, _))) in zip(pushes, zip([first, second], replies)) {
            let ours = try XCTUnwrap(PeerMessenger.responseEnvelope(to: request, payload: answer.serialized(), contentType: nil, result: answer.int("result")))
            XCTAssertEqual(ours.encoded().hex, real.encoded().hex)
        }
        let changes = await collector.value
        XCTAssertEqual(changes.first, .accessChanged(granted: true))
        XCTAssertEqual(changes.last, .removed(key: key))
        let left = await sync.notifications
        XCTAssertTrue(left.isEmpty)
    }

    func testClearAllListsEveryKnownKey() async {
        let sync = makeSync(like: ValueSet(["displayName": .string("d"), "appVersion": .string("v"), "installationId": .string("i")]))
        for n in 1...3 {
            _ = await sync.apply(ValueSet(["notificationKeys": .stringArray(["k\(n)"]), "operations": .int32Array([1]),
                                           "notifications": .stringArray([#"{"key":"k\#(n)","packageName":"p","postTime":\#(n)}"#])]))
        }
        let keys = await sync.notifications.map(\.key)
        let payload = await sync.commandPayload(4, sync.clearFields(keys))
        XCTAssertEqual(payload.int("operation"), 4)
        XCTAssertEqual(payload.int("notificationKeysCount"), 3, "Windows sent the count of the keys it held, six in the capture")
        XCTAssertEqual(payload.strings("notificationKeys"), ["k3", "k2", "k1"])
        XCTAssertEqual(payload.bool("isuserinitiated"), false)
    }
}

final class SensitiveNotificationPermissionTests: XCTestCase {
    func makeSync(displayName: String = "Mac", appVersion: String = "v", installationId: String = "I") -> NotificationSync {
        let hub = HubConnection(socket: MockWebSocket.autoCompleting())
        return NotificationSync(messenger: PeerMessenger(relay: RelayClient(hub: hub), peer: FakePhone.id), displayName: displayName,
                                appVersion: appVersion, installationId: installationId)
    }

    func testTheRequestNamesTheSensitivePermissionAndIsNotSilent() async {
        let sync = makeSync()
        let request = await sync.permissionPayload(silent: false, type: NotificationSync.sensitiveNotificationPermission)
        XCTAssertEqual(request["permissionType"], .int32(Int32.min), "the top bit of the phone's permission mask")
        XCTAssertEqual(request.bool("silent"), false, "not silent, so the phone shows its dialog")
        XCTAssertEqual(request.string("contentType"), "permission")
    }

    func testThePhonesDecisionArrivesAsAPermissionPush() async {
        let sync = makeSync()
        let collector = Task { () -> [NotificationSync.Change] in
            var seen: [NotificationSync.Change] = []
            for await change in sync.changes { seen.append(change); if seen.count == 3 { break } }
            return seen
        }
        let reply = await sync.applyPermissions(ValueSet(["permissionTypes": .int32Array([Int32.min, 64, 1, Int32.min]), "permissionStates": .int32Array([0, 1, 0, 1])]))
        XCTAssertEqual(reply.int("result"), 0)
        let changes = await collector.value
        XCTAssertEqual(changes, [.sensitiveAccessChanged(granted: true), .accessChanged(granted: false), .sensitiveAccessChanged(granted: false)],
                       "state 0 is granted; other permission types are ignored here")
    }

    func testThePhoneReportsTheDialogsOutcomeAsACommand() async {
        let sync = makeSync()
        let collector = Task { () -> [NotificationSync.Change] in
            var seen: [NotificationSync.Change] = []
            for await change in sync.changes { seen.append(change); if seen.count == 2 { break } }
            return seen
        }
        func command(_ scenario: String, type: Int32 = 7) -> ValueSet {
            ValueSet(["contentType": .string("phoneCommand"), "phoneCommandType": .int32(type), "notificationsSensitivePermissionScenario": .string(scenario)])
        }
        // Shown: nothing to conclude yet. Closing the dialog counts as denied.
        let shown = await sync.applyPhoneCommand(command("notifications_sensitive_permission_launched"))
        let denied = await sync.applyPhoneCommand(command("notifications_sensitive_permission_denied"))
        let other = await sync.applyPhoneCommand(command("notifications_sensitive_permission_denied", type: 4))
        let granted = await sync.applyPhoneCommand(command("notifications_sensitive_permission_granted"))
        for reply in [shown, denied, other, granted] { XCTAssertEqual(reply, ValueSet(["result": .int32(0)]), "every command is acknowledged") }
        let changes = await collector.value
        XCTAssertEqual(changes, [.sensitiveAccessChanged(granted: false), .sensitiveAccessChanged(granted: true)])
    }

    /// The command the phone sent when its dialog was closed, and how Windows answered it.
    func testTheCapturedDeniedCommandIsUnderstood() async throws {
        let messages = try LocalCapture.appMessages()
        // The capture keeps growing; take the newest "denied" command that Windows is seen answering.
        let pushes = messages.filter { !$0.fromPC && $0.values.string("contentType") == "phoneCommand"
            && $0.values.string("notificationsSensitivePermissionScenario") == "notifications_sensitive_permission_denied" }
        var pair: (push: LocalCapture.Message, answer: LocalCapture.Message)?
        for push in pushes.reversed() {
            if let answer = messages.first(where: { $0.fromPC && $0.envelope.originalRequestId == push.envelope.requestId }) {
                pair = (push, answer)
                break
            }
        }
        guard let (push, answer) = pair else { throw XCTSkip("the local capture has no answered phone command") }
        let sync = makeSync()
        let collector = Task { () -> NotificationSync.Change? in
            for await change in sync.changes { return change }
            return nil
        }
        let reply = await sync.applyPhoneCommand(push.values)
        let ours = try XCTUnwrap(PeerMessenger.responseEnvelope(to: push.envelope, payload: reply.serialized(), contentType: nil, result: reply.int("result")))
        XCTAssertEqual(ours.encoded(), answer.envelope.encoded(), "our acknowledgement is the one Windows sent, byte for byte")
        let change = await collector.value
        XCTAssertEqual(change, .sensitiveAccessChanged(granted: false))
    }

    /// The request Windows sent when Setup was pressed in Phone Link, from the local capture.
    func testOurRequestEqualsTheOneWindowsSent() async throws {
        let messages = try LocalCapture.appMessages()
        guard let real = messages.last(where: { $0.fromPC && $0.envelope.route == "/permission" && $0.values.int("permissionType") == Int(Int32.min) }) else {
            throw XCTSkip("the local capture has no request for the sensitive-notification permission")
        }
        let sync = makeSync(displayName: real.values.string("displayName") ?? "", appVersion: real.values.string("appVersion") ?? "",
                            installationId: real.values.string("installationId") ?? "")
        var ours = await sync.permissionPayload(silent: false, type: NotificationSync.sensitiveNotificationPermission)
        var theirs = real.values
        for key in ["correlationVector", "permissionSessionId"] {
            XCTAssertEqual(ours.string(key)?.count, theirs.string(key)?.count, key)
            ours[key] = nil; theirs[key] = nil
        }
        XCTAssertEqual(ours, theirs)
    }
}

final class NotificationReconnectTests: XCTestCase {
    /// After a reconnect the same engine tells the phone what it holds, and the phone answers
    /// with removals for what was dismissed meanwhile.
    func testWhatWasDismissedDuringAGapIsRemovedAfterReconnecting() async throws {
        let sync = NotificationSync(displayName: "Mac", installationId: "I")
        let first = FakePhone()
        let (messenger, relay) = try await first.connect()
        await sync.attach(messenger)
        _ = await sync.apply(ValueSet(["notificationKeys": .stringArray(["a", "b"]), "operations": .int32Array([1, 1]),
                                       "notifications": .stringArray([#"{"key":"a","packageName":"p","postTime":10}"#, #"{"key":"b","packageName":"p","postTime":20}"#])]))
        await relay.close()

        // A new connection. The phone answers the reconcile request, then pushes a removal.
        let second = FakePhone()
        second.responder = { envelope in
            envelope.route == "/notifications" ? ValueSet(["result": .int32(0), "contractVersion": .double(3.99)]).serialized() : nil
        }
        let (replacement, secondRelay) = try await second.connect()
        await sync.attach(replacement)
        try await sync.reconcile()
        let request = try XCTUnwrap(second.received(route: "/notifications").first.flatMap { try? ValueSet(serialized: $0.payload) })
        XCTAssertEqual(request.int("operation"), 3)
        XCTAssertEqual(request.strings("notificationKeys"), ["b", "a"], "what we still hold from before the gap, newest first")
        XCTAssertEqual(request.int64s("postTimes"), [20, 10])

        let id = UUID().uuidString.lowercased()
        let removal = ValueSet(["contentType": .string("notifications"), "notificationKeys": .stringArray(["a"]), "operations": .int32Array([2]), "notifications": .stringArray([""])])
        second.deliver(PlatformEnvelope(headers: [("_requestId", id), ("_route", "/legacy/phonecontent")], payload: removal.serialized(), convention: .android), type: .app)
        let removed = await waitUntil { await sync.notifications.map(\.key) == ["b"] }
        XCTAssertTrue(removed, "pushes on the new connection reach the same engine")
        await secondRelay.close()
    }
}
