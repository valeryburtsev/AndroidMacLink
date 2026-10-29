import XCTest
@testable import WinPhoneCore

extension LocalCapture {
    /// APP messages of the pairing capture, which stores decoded frames instead of raw bytes.
    static func pairingAppMessages() throws -> [Message] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let capture = root.appendingPathComponent("captures/vm-pairing-2026-10-09/flows.jsonl")
        guard let text = try? String(contentsOf: capture, encoding: .utf8) else { throw XCTSkip("no local pairing capture") }
        var messages: [Message] = []
        for line in text.split(separator: "\n") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["type"] as? String == "ws", let frames = record["frames"] as? [[String: Any]] else { continue }
            for frame in frames {
                for argument in frame["arguments"] as? [Any] ?? [] {
                    guard let packet = argument as? [String: Any], let properties = packet["Properties"] as? [String: Any],
                          (properties["MessageType"] as? NSNumber)?.intValue == 0, (properties["FragmentCount"] as? NSNumber)?.intValue == 1,
                          let raw = packet["Raw"] as? [String: Any], let base64 = raw["bytes_b64"] as? String, let bytes = Data(base64Encoded: base64),
                          var envelope = try? PlatformEnvelope(decoding: bytes) else { continue }
                    if envelope["_isGzippedCompressed"]?.lowercased() == "true" {
                        guard let inflated = Gzip.decompress(envelope.payload) else { continue }
                        envelope.payload = inflated
                    }
                    guard let values = try? ValueSet(serialized: envelope.payload) else { continue }
                    messages.append(Message(fromPC: record["dir"] as? String == "c2s", envelope: envelope, values: values))
                }
            }
        }
        return messages
    }
}

final class ContactSyncTests: XCTestCase {
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])

    func metadata(contacts: [(Int64, Int64)], numbers: [(Int64, Int64)], emails: [(Int64, Int64)] = [], sequence: Int64 = 4) -> ValueSet {
        var entries: [String: ValueSet.Value] = [:]
        entries["contentType"] = .string("contactsV2")
        entries["metadata"] = .int32(1)
        entries["correlationVector"] = .string("cv")
        entries["contactIds"] = .int64Array(contacts.map(\.0))
        entries["contactChecksums"] = .int64Array(contacts.map(\.1))
        entries["phoneNumberIds"] = .int64Array(numbers.map(\.0))
        entries["phoneNumberChecksums"] = .int64Array(numbers.map(\.1))
        entries["contactEmailAddressIds"] = .int64Array(emails.map(\.0))
        entries["contactEmailAddressChecksums"] = .int64Array(emails.map(\.1))
        entries["contactPostalAddressIds"] = .int64Array([9])
        entries["contactPostalAddressChecksums"] = .int64Array([1])
        entries["sequenceNumbers"] = .object(ValueSet(Dictionary(uniqueKeysWithValues: ContactSync.sequenceKeys.map { ($0, ValueSet.Value.int64(sequence)) })))
        return ValueSet(entries)
    }

    func batch(contacts: [(id: Int64, name: String, photo: Data, action: Int32)], numbers: [(id: Int64, contact: Int64, number: String, checksum: Int64, action: Int32)],
               emails: [(id: Int64, contact: Int64, address: String)] = [], sequence: Int64? = 4) -> ValueSet {
        var c: [String: ValueSet.Value] = [:]
        c["contactIds"] = .int64Array(contacts.map(\.id))
        c["displayNames"] = .stringArray(contacts.map(\.name))
        c["companies"] = .stringArray(contacts.map { _ in "" })
        // As on the phone: this checksum differs from the list's for a contact with a photo.
        c["checksums"] = .int64Array(contacts.map { $0.photo.isEmpty ? 7 : 999 })
        c["actions"] = .int32Array(contacts.map(\.action))
        c["thumbnailSizes"] = .int64Array(contacts.map { Int64($0.photo.count) })
        var blob = Data()
        for contact in contacts { blob.append(contact.photo) }
        c["thumbnails"] = .bytes(blob)
        var n: [String: ValueSet.Value] = [:]
        n["phoneNumberIds"] = .int64Array(numbers.map(\.id))
        n["contactIds"] = .int64Array(numbers.map(\.contact))
        n["phoneNumbers"] = .stringArray(numbers.map(\.number))
        n["displayNumbers"] = .stringArray(numbers.map(\.number))
        n["checksums"] = .int64Array(numbers.map(\.checksum))
        n["actions"] = .int32Array(numbers.map(\.action))
        var e: [String: ValueSet.Value] = [:]
        e["contactEmailAddressIds"] = .int64Array(emails.map(\.id))
        e["contactIds"] = .int64Array(emails.map(\.contact))
        e["emailAddresses"] = .stringArray(emails.map(\.address))
        e["checksums"] = .int64Array(emails.map { _ in 1 })
        e["actions"] = .int32Array(emails.map { _ in 1 })
        var entries: [String: ValueSet.Value] = ["contentType": .string("contactsV2"), "contacts": .object(ValueSet(c)),
                                                 "phoneNumbers": .object(ValueSet(n)), "emailAddresses": .object(ValueSet(e))]
        if let sequence {
            // In a batch this object also carries unrelated keys.
            var numbers = Dictionary(uniqueKeysWithValues: ContactSync.sequenceKeys.map { ($0, ValueSet.Value.int64(sequence)) })
            numbers["contentType"] = .string("contactsV2")
            numbers["retryCount"] = .int32(0)
            entries["sequenceNumbers"] = .object(ValueSet(numbers))
        }
        return ValueSet(entries)
    }

    func testFullSyncAsksForContactsNumbersAndEmailOnly() async {
        let sync = ContactSync()
        let answer = await sync.apply(metadata(contacts: [(1, 7), (2, 50)], numbers: [(10, 3), (11, 3)], emails: [(20, 1)]))
        XCTAssertEqual(answer["itemCount"], .int32(5), "an Int32 above zero, or the phone sends nothing")
        XCTAssertEqual(answer["contactIds"], .int64Array([1, 2]))
        XCTAssertEqual(answer["phoneNumberIds"], .int64Array([10, 11]))
        XCTAssertEqual(answer["contactEmailAddressIds"], .int64Array([20]))
        XCTAssertEqual(answer["contactPostalAddressIds"], .int64Array([]), "an empty list makes the phone skip the table")
        XCTAssertEqual(answer["contactDateIds"], .int64Array([]))
        XCTAssertEqual(answer["contactUrlIds"], .int64Array([]))
        XCTAssertEqual(answer.string("correlationVector"), "cv")
        var numbers = await sync.sequenceNumbers
        XCTAssertEqual(numbers["contact"], -1)

        let reply = await sync.apply(batch(contacts: [(1, "Ada Lovelace", Data(), -1), (2, "Grace Hopper", Self.jpeg, -1)],
                                           numbers: [(10, 1, "+15550100", 3, 1), (11, 2, "+27821234567", 3, 1)], emails: [(20, 2, "Grace@Example.com")]))
        XCTAssertEqual(reply, ValueSet(["result": .int32(0)]))
        numbers = await sync.sequenceNumbers
        XCTAssertEqual(Set(numbers.keys), Set(ContactSync.sequenceKeys), "all six are kept, or the next handshake forces a full sync")
        XCTAssertEqual(numbers["postaladdress"], 4)

        let book = await sync.book
        XCTAssertEqual(book.name(for: "+1 555 0100"), "Ada Lovelace", "spaces and punctuation do not matter")
        XCTAssertEqual(book.name(for: "+1 (555) 0100"), "Ada Lovelace")
        XCTAssertEqual(book.contact(for: "+27821234567")?.photo, Self.jpeg, "the photo is cut out of the block by its size")
        XCTAssertNil(book.contact(for: "+15550100")?.photo)
        XCTAssertEqual(book.name(for: "grace@example.com"), "Grace Hopper", "e-mail addresses match without regard to case")
        XCTAssertNil(book.name(for: "+15550199"))

        // The same list again wants nothing, although the batch's checksum for the contact
        // with a photo differed from the list's.
        let again = await sync.apply(metadata(contacts: [(1, 7), (2, 50)], numbers: [(10, 3), (11, 3)], emails: [(20, 1)], sequence: 5))
        XCTAssertEqual(again["itemCount"], .int32(0))
        numbers = await sync.sequenceNumbers
        XCTAssertEqual(numbers["contact"], 5, "with nothing to fetch the list's numbers apply at once")
    }

    func testChangesDeletionsAndRowsMissingFromTheList() async {
        let sync = ContactSync()
        _ = await sync.apply(metadata(contacts: [(1, 7), (2, 8)], numbers: [(10, 3), (11, 3)]))
        _ = await sync.apply(batch(contacts: [(1, "Ada", Data(), -1), (2, "Grace", Data(), -1)], numbers: [(10, 1, "+15550100", 3, 1), (11, 2, "+15550101", 3, 1)]))
        // An incremental push: a number deleted, a contact renamed.
        _ = await sync.apply(batch(contacts: [(2, "Grace H.", Data(), 1)], numbers: [(10, 0, "", 0, 2)], sequence: 6))
        var book = await sync.book
        XCTAssertNil(book.name(for: "+15550100"))
        XCTAssertEqual(book.name(for: "+15550101"), "Grace H.")
        // A later full list without contact 2 drops it and its number is asked for again only if changed.
        let answer = await sync.apply(metadata(contacts: [(1, 7)], numbers: [(11, 4)]))
        XCTAssertEqual(answer["contactIds"], .int64Array([]))
        XCTAssertEqual(answer["phoneNumberIds"], .int64Array([11]), "its checksum changed")
        book = await sync.book
        XCTAssertNil(book.name(for: "+15550101"), "the number's contact is gone")
    }

    func testNumberMatching() {
        let book = ContactBook(contacts: [PhoneContact(id: 1, displayName: "Ada"), PhoneContact(id: 2, displayName: ""), PhoneContact(id: 3, displayName: "Bank"),
                                          PhoneContact(id: 4, displayName: "", company: "Acme Ltd")],
                               numbers: [("+27 82 123 4567", 1), ("+27821234567", 2), ("12345", 3), ("MyBank", 3), ("+15550142", 4)], emails: [])
        XCTAssertEqual(ContactBook.key(forNumber: " +27 (82) 123-4567 "), "+27821234567")
        XCTAssertEqual(ContactBook.key(forNumber: "082 123 4567"), "0821234567")
        XCTAssertEqual(ContactBook.key(forNumber: "MyBank"), "mybank")
        XCTAssertEqual(book.name(for: "+27821234567"), "Ada", "of two contacts with the number, the one with a name")
        XCTAssertEqual(book.name(for: "082 123 4567"), "Ada", "written the national way, against a stored international number")
        XCTAssertEqual(book.name(for: "821234567"), "Ada")
        XCTAssertNil(book.name(for: "1234567"), "a mere tail of the number is not a match")
        XCTAssertNil(book.name(for: "0991234567"))
        XCTAssertEqual(book.name(for: "12345"), "Bank", "short codes compare as they are")
        XCTAssertEqual(book.name(for: "mybank"), "Bank", "sender names ignore case")
        XCTAssertEqual(book.name(for: "+1 555 0142"), "Acme Ltd", "a contact without a name shows its company")
        XCTAssertNil(book.name(for: ""))
        XCTAssertNil(book.name(for: "+++"))
    }

    func testRecipientsAreFoundByNameOrDigits() {
        let book = ContactBook(contacts: [PhoneContact(id: 1, displayName: "Ada Lovelace"), PhoneContact(id: 2, displayName: "Adam Smith"),
                                          PhoneContact(id: 3, displayName: "Grace Hopper"), PhoneContact(id: 4, displayName: "")],
                               numbers: [("+15550100", 1), ("+15550199", 1), ("+15550142", 2), ("+27821234567", 3), ("+15550000", 4)], emails: [],
                               displayNumbers: [("+1 555 0100", 1), ("+1 555 0199", 1), ("+1 555 0142", 2), ("082 123 4567", 3), ("+1 555 0000", 4)])
        XCTAssertEqual(book.recipients(matching: "ada").map(\.number), ["+1 555 0100", "+1 555 0199", "+1 555 0142"], "by name, each number its own entry")
        XCTAssertEqual(book.recipients(matching: "GRACE").map(\.contact.name), ["Grace Hopper"])
        XCTAssertEqual(book.recipients(matching: "0142").map(\.contact.name), ["Adam Smith"], "by digits of the number")
        XCTAssertEqual(book.recipients(matching: "123 45").map(\.number), ["082 123 4567"], "the number is offered as the user wrote it")
        XCTAssertTrue(book.recipients(matching: "").isEmpty)
        XCTAssertTrue(book.recipients(matching: "55").isEmpty, "too few digits to be a search")
        XCTAssertTrue(book.recipients(matching: "0000").isEmpty, "a contact without a name is not offered")
        XCTAssertEqual(book.recipients(matching: "a", limit: 2).count, 2)
    }

    func testContactsSurviveARelaunch() async throws {
        let cache = MemoryBlobCache()
        let first = ContactSync(cache: cache)
        _ = await first.apply(metadata(contacts: [(1, 7)], numbers: [(10, 3)]))
        _ = await first.apply(batch(contacts: [(1, "Ada", Self.jpeg, -1)], numbers: [(10, 1, "+15550100", 3, 1)], sequence: 8))
        let saved = await waitUntil(timeout: 5) { cache.saveCount > 0 }
        XCTAssertTrue(saved)
        let second = ContactSync(cache: cache)
        let book = await second.book
        XCTAssertEqual(book.name(for: "+15550100"), "Ada")
        XCTAssertEqual(book.contact(for: "+15550100")?.photo, Self.jpeg)
        let numbers = await second.sequenceNumbers
        XCTAssertEqual(numbers["phonenumber"], 8)
        let dropped = await second.reconcile(phoneNumbers: ["contact": 2])
        XCTAssertTrue(dropped, "a phone whose numbering went backwards was reset")
        let empty = await second.book
        XCTAssertTrue(empty.isEmpty)
    }

    /// The first contact sync Windows did with the phone, from the pairing capture on this
    /// machine. Only counts and joins are checked; no name or number is printed or stored.
    func testTheRealContactSyncFromTheCaptureParses() async throws {
        let messages = try LocalCapture.pairingAppMessages()
        let pushes = messages.filter { !$0.fromPC && $0.values.string("contentType") == "contactsV2" }
        guard let list = pushes.first(where: { $0.values.entries["metadata"] != nil }) else { throw XCTSkip("the pairing capture has no contact sync") }
        let sync = ContactSync()
        let answer = await sync.apply(list.values)
        let listed = list.values.int64s("contactIds")?.count ?? 0
        XCTAssertGreaterThan(listed, 0)
        XCTAssertEqual(answer.int64s("contactIds")?.count, listed, "a first sync asks for every contact")
        // What Windows answered has the keys we answer with.
        if let theirs = messages.first(where: { $0.fromPC && $0.envelope.originalRequestId == list.envelope.requestId }) {
            XCTAssertEqual(Set(theirs.values.entries.keys), Set(answer.entries.keys))
            XCTAssertEqual(theirs.values.int64s("contactIds"), answer.int64s("contactIds"))
            XCTAssertEqual(theirs.values.int64s("phoneNumberIds"), answer.int64s("phoneNumberIds"))
        }
        for batch in pushes where batch.values.entries["metadata"] == nil {
            let reply = await sync.apply(batch.values)
            XCTAssertEqual(reply, ValueSet(["result": .int32(0)]))
        }
        let book = await sync.book
        XCTAssertEqual(book.contacts.count, listed)
        XCTAssertTrue(book.contacts.values.contains { $0.photo?.starts(with: [0xFF, 0xD8, 0xFF]) == true }, "photos are JPEGs cut out by their sizes")
        let numbers = await sync.sequenceNumbers
        XCTAssertTrue(ContactSync.sequenceKeys.allSatisfy { (numbers[$0] ?? -1) >= 0 }, "\(numbers)")
        // Every listed list now wants nothing.
        let again = await sync.apply(list.values)
        XCTAssertEqual(again["itemCount"], .int32(0), "the checksums kept are the list's, so nothing is asked for twice")
    }
}
