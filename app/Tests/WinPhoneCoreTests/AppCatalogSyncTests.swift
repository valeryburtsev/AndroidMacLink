import XCTest
@testable import WinPhoneCore

final class AppCatalogSyncTests: XCTestCase {
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2])

    func list(ids: [Int64], checksums: [Int64], sequence: Int64 = 2, recent: Int64 = 3) -> ValueSet {
        ValueSet(["contentType": .string("phoneApps"), "metadata": .int32(1), "itemCount": .int32(Int32(ids.count + 1)),
                  "phoneAppsIds": .int64Array(ids), "checksums": .int64Array(checksums), "sequenceNumber": .int64(sequence),
                  "recentAppsIds": .int64Array([99]), "recentAppsChecksums": .int64Array([1]), "recentAppsSequenceNumber": .int64(recent),
                  "correlationVector": .string("cv")])
    }

    func batch(_ apps: [(id: Int64, package: String, name: String, icon: Data, action: Int32?)], sequence: Int64? = nil) -> ValueSet {
        var entries: [String: ValueSet.Value] = [:]
        entries["contentType"] = .string("phoneApps")
        entries["itemCount"] = .int32(Int32(apps.count))
        entries["phoneAppsIds"] = .int64Array(apps.map(\.id))
        entries["appPackageNames"] = .stringArray(apps.map(\.package))
        entries["appNames"] = .stringArray(apps.map(\.name))
        entries["appVersions"] = .stringArray(apps.map { _ in "1.0" })
        entries["checksums"] = .int64Array(apps.map { $0.id * 10 })
        entries["iconSizes"] = .int64Array(apps.map { Int64($0.icon.count) })
        var blob = Data()
        for app in apps { blob.append(app.icon) }
        entries["content"] = .bytes(blob)
        if apps.contains(where: { $0.action != nil }) {
            entries["actions"] = .int32Array(apps.map { $0.action ?? -1 })
            entries["incremental"] = .int32(1)
        }
        if let sequence { entries["sequenceNumber"] = .int64(sequence) }
        return ValueSet(entries)
    }

    func testFirstSyncAsksForEveryAppAndLaterOnesOnlyForWhatChanged() async {
        let sync = AppCatalogSync()
        let answer = await sync.apply(list(ids: [5, 6, 7], checksums: [50, 60, 70]))
        XCTAssertEqual(answer["itemCount"], .int32(3), "an Int32; zero would end the sync")
        XCTAssertEqual(answer["phoneAppsIds"], .int64Array([5, 6, 7]))
        XCTAssertNil(answer["phoneAppsETag"], "that key belongs to an older protocol and must not be sent")
        XCTAssertNil(answer["recentAppsIds"], "recently used apps are not fetched")
        var numbers = await sync.sequenceNumbers
        XCTAssertEqual(numbers, ["phoneApps": -1, "recentApps": 3], "the recent-apps number is held so the phone need not offer the list each time")

        // Two batches; the last carries the number.
        _ = await sync.apply(batch([(5, "com.example.chat", "Chat", Self.png, nil), (6, "com.example.mail", "Mail", Self.png + [9], nil)]))
        let reply = await sync.apply(batch([(7, "com.example.maps", "Maps", Data(), nil)], sequence: 2))
        XCTAssertEqual(reply, ValueSet(["result": .int32(0)]))
        numbers = await sync.sequenceNumbers
        XCTAssertEqual(numbers["phoneApps"], 2)
        var apps = await sync.byPackage
        XCTAssertEqual(apps["com.example.mail"]?.icon, Self.png + [9], "icons are cut out of the block by their sizes")
        XCTAssertEqual(apps["com.example.chat"]?.name, "Chat")
        XCTAssertNil(apps["com.example.maps"]?.icon)

        // Next list: one app changed, one removed, one without an icon is asked for again.
        let next = await sync.apply(list(ids: [5, 7], checksums: [51, 70], sequence: 4))
        XCTAssertEqual(next["phoneAppsIds"], .int64Array([5, 7]))
        apps = await sync.byPackage
        XCTAssertNil(apps["com.example.mail"], "an app missing from the list was removed from the phone")
    }

    func testIncrementalChangesAndRecentAppMessages() async {
        let sync = AppCatalogSync()
        _ = await sync.apply(batch([(5, "com.example.chat", "Chat", Self.png, nil), (6, "com.example.mail", "Mail", Self.png, nil)], sequence: 2))
        // Removed apps come with their ID only; an update without icon bytes keeps the old icon.
        _ = await sync.apply(batch([(6, "", "", Data(), 2), (5, "com.example.chat", "Chat 2", Data(), 1), (8, "com.example.new", "New", Self.png, 0)], sequence: 3))
        let apps = await sync.byPackage
        XCTAssertEqual(Set(apps.keys), ["com.example.chat", "com.example.new"])
        XCTAssertEqual(apps["com.example.chat"]?.name, "Chat 2")
        XCTAssertEqual(apps["com.example.chat"]?.icon, Self.png)
        // A message that only lists recently used apps changes nothing but its number.
        let reply = await sync.apply(ValueSet(["contentType": .string("phoneApps"), "recentAppsItemCount": .int32(1), "recentAppsSequenceNumber": .int64(9),
                                               "recentAppsPackageNames": .stringArray(["com.example.chat"])]))
        XCTAssertEqual(reply.int("result"), 0)
        let numbers = await sync.sequenceNumbers
        XCTAssertEqual(numbers, ["phoneApps": 3, "recentApps": 9])
        let after = await sync.byPackage
        XCTAssertEqual(after.count, 2)
    }

    func testTheCatalogueSurvivesARelaunch() async {
        let cache = MemoryBlobCache()
        let first = AppCatalogSync(cache: cache)
        _ = await first.apply(batch([(5, "com.example.chat", "Chat", Self.png, nil)], sequence: 2))
        let saved = await waitUntil(timeout: 5) { cache.saveCount > 0 }
        XCTAssertTrue(saved)
        let second = AppCatalogSync(cache: cache)
        let apps = await second.byPackage
        XCTAssertEqual(apps["com.example.chat"]?.icon, Self.png)
        let answer = await second.apply(list(ids: [5], checksums: [50]))
        XCTAssertEqual(answer["itemCount"], .int32(0), "nothing to fetch: the phone renders no icon")
        let dropped = await second.reconcile(phoneNumbers: ["phoneApps": 0])
        XCTAssertTrue(dropped)
    }

    /// The first app sync Windows did with the phone, from the pairing capture on this machine.
    /// Only counts and formats are checked; no app or package name is printed or stored.
    func testTheRealAppSyncFromTheCaptureParses() async throws {
        let messages = try LocalCapture.pairingAppMessages()
        let pushes = messages.filter { !$0.fromPC && $0.values.string("contentType") == "phoneApps" }
        guard let list = pushes.first(where: { $0.values.entries["metadata"] != nil }) else { throw XCTSkip("the pairing capture has no app sync") }
        let sync = AppCatalogSync()
        let answer = await sync.apply(list.values)
        let listed = list.values.int64s("phoneAppsIds")?.count ?? 0
        XCTAssertGreaterThan(listed, 10)
        XCTAssertEqual(answer.int64s("phoneAppsIds"), list.values.int64s("phoneAppsIds"), "a first sync asks for every app, in the listed order")
        if let theirs = messages.first(where: { $0.fromPC && $0.envelope.originalRequestId == list.envelope.requestId }) {
            XCTAssertEqual(theirs.values.int64s("phoneAppsIds"), answer.int64s("phoneAppsIds"), "the same request Windows made")
            XCTAssertTrue(Set(answer.entries.keys).isSubset(of: Set(theirs.values.entries.keys)))
        }
        for push in pushes where push.values.entries["metadata"] == nil {
            let reply = await sync.apply(push.values)
            XCTAssertEqual(reply, ValueSet(["result": .int32(0)]))
        }
        let apps = await sync.byPackage
        XCTAssertEqual(apps.count, listed)
        let icons = apps.values.compactMap(\.icon)
        XCTAssertGreaterThan(icons.count, listed * 9 / 10)
        XCTAssertTrue(icons.allSatisfy { $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) }, "every icon is a PNG")
        XCTAssertTrue(apps.values.allSatisfy { !$0.name.isEmpty })
        let numbers = await sync.sequenceNumbers
        XCTAssertGreaterThanOrEqual(numbers["phoneApps"] ?? -1, 0)
        XCTAssertGreaterThanOrEqual(numbers["recentApps"] ?? -1, 0)
        let again = await sync.apply(list.values)
        XCTAssertEqual(again["itemCount"], .int32(0))
    }
}
