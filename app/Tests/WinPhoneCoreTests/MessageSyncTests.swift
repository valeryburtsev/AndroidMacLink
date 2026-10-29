import CoreGraphics
import ImageIO
import XCTest
@testable import WinPhoneCore

final class MessageSyncTests: XCTestCase {
    let sender = AppSender(displayName: "Mac", installationId: "INSTALL")

    func makeSync(responder: (@Sendable (PlatformEnvelope) -> Data?)? = nil) async throws -> (MessageSync, FakePhone, RelayClient) {
        let phone = FakePhone()
        phone.responder = responder
        let (messenger, relay) = try await phone.connect()
        return (MessageSync(messenger: messenger, sender: sender), phone, relay)
    }

    func firstConversation(_ sync: MessageSync) async throws -> Conversation {
        let all = await sync.conversations
        return try XCTUnwrap(all.first)
    }

    /// A content batch as the phone builds it. Every object is present, as on the wire.
    func batch(sms: [(id: Int64, thread: Int64, box: Int32, date: Int64, body: String, address: String, read: Bool, action: Int32)] = [],
               threads: [(id: Int64, recipients: String, action: Int32)] = [], addresses: [(String, String)] = [],
               acks: [Int64] = [], numbers: [String: Int64]? = nil) -> ValueSet {
        var smsObject: [String: ValueSet.Value] = [:]
        smsObject["itemCount"] = .int32(Int32(sms.count))
        smsObject["messageIds"] = .int64Array(sms.map(\.id))
        smsObject["threadIds"] = .int64Array(sms.map(\.thread))
        smsObject["messageTypes"] = .int32Array(sms.map(\.box))
        smsObject["dates"] = .int64Array(sms.map(\.date))
        smsObject["bodies"] = .stringArray(sms.map(\.body))
        smsObject["fromAddresses"] = .stringArray(sms.map { $0.box == 1 ? $0.address : "" })
        smsObject["toAddresses"] = .stringArray(sms.map { $0.box == 1 ? "" : $0.address })
        smsObject["readFlags"] = .boolArray(sms.map(\.read))
        smsObject["subscriptionIds"] = .int64Array(sms.map { _ in Int64(1) })
        smsObject["actions"] = .int32Array(sms.map(\.action))
        var threadObject: [String: ValueSet.Value] = [:]
        threadObject["ids"] = .int64Array(threads.map(\.id))
        threadObject["recipientIds"] = .stringArray(threads.map(\.recipients))
        threadObject["actions"] = .int32Array(threads.map(\.action))
        var entries: [String: ValueSet.Value] = [:]
        entries["contentType"] = .string("messaging")
        entries["incremental"] = .int32(1)
        entries["smsMessages"] = .object(ValueSet(smsObject))
        entries["conversations"] = .object(ValueSet(threadObject))
        entries["canonicalAddresses"] = .object(ValueSet(["ids": .stringArray(addresses.map(\.0)), "addresses": .stringArray(addresses.map(\.1))]))
        entries["subscriptions"] = .object(ValueSet(["ids": .int64Array([1]), "names": .stringArray(["SIM"]), "numbers": .stringArray([""]),
                                                     "simSlotIndices": .int64Array([0]), "isDefaultSmsSubscriptions": .boolArray([true]), "actions": .int32Array([-1])]))
        entries["acks"] = .object(ValueSet(["ids": .int64Array(acks)]))
        if let numbers { entries["sequenceNumbers"] = .object(ValueSet(numbers.mapValues { ValueSet.Value.int64($0) })) }
        return ValueSet(entries)
    }

    func testFullSyncAsksForEverythingNewAndBuildsConversations() async throws {
        let (sync, _, relay) = try await makeSync()
        let metadata = ValueSet([
            "contentType": .string("messaging"), "metadata": .int32(1), "itemCount": .int32(5), "correlationVector": .string("cv-9"),
            "messagingSmsIds": .int64Array([11, 12]), "messagingSmsChecksums": .int64Array([1, 0]), "messagingUnreadSmsIds": .int64Array([12]),
            "messagingMmsIds": .int64Array([]), "messagingMmsChecksums": .int64Array([]),
            "messagingConversationIds": .int64Array([5, 6]), "messagingConversationChecksums": .int64Array([77, 78]),
            "messagingSubscriptionIds": .int64Array([1]), "messagingSubscriptionChecksums": .int64Array([9]),
            "sequenceNumbers": .object(ValueSet(["sms": .int64(4), "mms": .int64(0), "conversation": .int64(2), "subscription": .int64(1)])),
        ])
        let answer = await sync.apply(metadata)
        XCTAssertEqual(answer.int("result"), 0)
        XCTAssertEqual(answer["itemCount"], .int32(3), "an Int32 above zero, or the phone sends no content")
        XCTAssertEqual(answer["messagingSmsIds"], .int64Array([11, 12]))
        XCTAssertEqual(answer["messagingMmsIds"], .int64Array([]))
        XCTAssertEqual(answer["messagingMmsPartIds"], .int64Array([]), "every key is sent, empty when nothing is wanted")
        XCTAssertEqual(answer["messagingConversationIds"], .int64Array([]),
                       "threads are never asked for: the phone lists thousands and sends the relevant ones with the messages anyway")
        XCTAssertEqual(answer["messagingSubscriptionIds"], .int64Array([1]))
        XCTAssertEqual(answer.string("correlationVector"), "cv-9")
        var numbers = await sync.sequenceNumbers
        XCTAssertEqual(numbers["sms"], -1, "numbers are stored when the content has arrived")

        let reply = await sync.apply(batch(
            sms: [(11, 5, 2, 1_000_000, "on my way", "+100", true, 1), (12, 5, 1, 2_000_000, "ok", "+100", false, 1)],
            threads: [(5, "40", 1), (6, "41 42", 1)], addresses: [("40", "+100"), ("41", "+200"), ("42", "+300")],
            numbers: ["sms": 4, "mms": 0, "conversation": 2, "subscription": 1]))
        XCTAssertEqual(reply, ValueSet(["result": .int32(0)]))
        numbers = await sync.sequenceNumbers
        XCTAssertEqual(numbers, ["sms": 4, "mms": 0, "conversation": 2, "subscription": 1])

        let conversations = await sync.conversations
        XCTAssertEqual(conversations.count, 1, "a thread without messages is not listed")
        let thread = conversations[0]
        XCTAssertEqual(thread.id, 5)
        XCTAssertEqual(thread.title, "+100")
        XCTAssertEqual(thread.messages.map(\.body), ["on my way", "ok"], "oldest first")
        XCTAssertEqual(thread.messages.map(\.isIncoming), [false, true], "mailbox 1 is received, 2 is sent")
        XCTAssertEqual(thread.unreadCount, 1)
        XCTAssertEqual(thread.lastMessage?.date, Date(timeIntervalSince1970: 2000), "dates are milliseconds")
        let subscriptions = await sync.subscriptions
        XCTAssertEqual(subscriptions.first?.isDefaultForSMS, true)

        // A second full sync with the same state wants only the opaque-checksum items again,
        // and a read flag that changed on the phone is asked for.
        let again = await sync.apply(metadata)
        XCTAssertEqual(again["messagingSmsIds"], .int64Array([]), "both messages are held with matching read flags")
        var changed = metadata
        changed["messagingSmsChecksums"] = .int64Array([1, 1])
        let reread = await sync.apply(changed)
        XCTAssertEqual(reread["messagingSmsIds"], .int64Array([12]))
        await relay.close()
    }

    func testIncrementalChangesAndDeletions() async throws {
        let (sync, _, relay) = try await makeSync()
        _ = await sync.apply(batch(sms: [(1, 5, 1, 1000, "a", "+100", false, 0), (2, 5, 1, 2000, "b", "+100", false, 0)],
                                   threads: [(5, "40", 1)], addresses: [("40", "+100")], numbers: ["sms": 2]))
        // Read on the phone: action 1 with the flag set. Deleted: action 2, other fields zero.
        _ = await sync.apply(batch(sms: [(1, 5, 1, 1000, "a", "+100", true, 1), (2, 0, 0, 0, "", "", false, 2)], numbers: ["sms": 3]))
        let thread = try await firstConversation(sync)
        XCTAssertEqual(thread.messages.map(\.messageId), [1])
        XCTAssertEqual(thread.unreadCount, 0)
        let number = await sync.sequenceNumbers["sms"]
        XCTAssertEqual(number, 3)

        // A metadata round that no longer lists a message removes it.
        _ = await sync.apply(ValueSet(["metadata": .int32(1), "messagingSmsIds": .int64Array([]), "messagingSmsChecksums": .int64Array([]),
                                       "messagingConversationIds": .int64Array([]), "messagingSubscriptionIds": .int64Array([])]))
        let left = await sync.conversations
        XCTAssertTrue(left.isEmpty)
        await relay.close()
    }

    func testMMSTextComesFromItsTextParts() async throws {
        let (sync, _, relay) = try await makeSync()
        var push = batch(threads: [(8, "40", 1)], addresses: [("40", "+100")])
        push["mmsMessages"] = .object(ValueSet(["messageIds": .int64Array([3]), "threadIds": .int64Array([8]), "messageBoxTypes": .int32Array([1]),
                                                "dates": .int64Array([5000]), "fromAddresses": .stringArray(["+100"]), "toAddresses": .stringArray([""]),
                                                "subjects": .stringArray([""]), "readFlags": .boolArray([false]), "actions": .int32Array([0])]))
        push["mmsParts"] = .object(ValueSet(["messageIds": .int64Array([3, 3, 3]), "contentTypes": .stringArray(["application/smil", "text/plain", "image/jpeg"]),
                                             "texts": .stringArray(["<smil/>", "look at this", ""])]))
        _ = await sync.apply(push)
        let mmsThread = try await firstConversation(sync)
        let message = try XCTUnwrap(mmsThread.messages.first)
        XCTAssertEqual(message.kind, .mms)
        XCTAssertEqual(message.body, "look at this")
        XCTAssertEqual(message.attachmentCount, 1, "the picture counts, the layout part does not")
        XCTAssertEqual(message.id, "mms-3", "SMS and MMS number separately")
        await relay.close()
    }

    func testSendShowsAPlaceholderUntilThePhoneAcknowledges() async throws {
        let (sync, phone, relay) = try await makeSync(responder: { envelope in
            guard envelope.route == "/chat/v1" else { return nil }
            return ValueSet(["result": .int32(0), "contractVersion": .double(3.99)]).serialized()
        })
        _ = await sync.apply(batch(sms: [(1, 5, 1, 1000, "hi", "+100", true, 0)], threads: [(5, "40", 1)], addresses: [("40", "+100")]))
        try await sync.send("hello back", threadId: 5)

        let request = try XCTUnwrap(phone.received(route: "/chat/v1").first.flatMap { try? ValueSet(serialized: $0.payload) })
        XCTAssertEqual(request["requestType"], .int32(2))
        // 64-bit, or the phone's cast fails; and never a number an earlier run used, because
        // the phone repeats its old acknowledgements.
        guard case .int64(let sendId)? = request["id"] else { return XCTFail("the send ID must be an Int64") }
        XCTAssertGreaterThan(sendId, 1_000_000)
        XCTAssertEqual(request["threadId"], .int64(5))
        XCTAssertEqual(request["subscriptionId"], .int32(1), "32-bit; the phone's default SIM for texts, as Windows names it")
        XCTAssertEqual(request.bool("isuserinitiated"), true)
        XCTAssertEqual(request.string("body"), "hello back")
        XCTAssertEqual(request.string("tempId")?.count, 36)
        XCTAssertNil(request["recipients"], "a reply names the thread, not the recipients")
        XCTAssertEqual(request.object("configuration"), ConnectExchange.messagingConfiguration)
        XCTAssertEqual(request.double("contractVersion"), 3.99)

        var thread = try await firstConversation(sync)
        XCTAssertEqual(thread.pending.map(\.body), ["hello back"], "shown as sending until the phone confirms")
        XCTAssertEqual(thread.pending.first?.state, .sending)

        // The phone pushes the real message with the acknowledgement.
        // An acknowledgement left over from an earlier run changes nothing.
        _ = await sync.apply(batch(acks: [1, 2]))
        thread = try await firstConversation(sync)
        XCTAssertEqual(thread.pending.first?.state, .sending)
        _ = await sync.apply(batch(sms: [(2, 5, 2, 3000, "hello back", "+100", true, 0)], acks: [1, 2, sendId], numbers: ["sms": 9]))
        thread = try await firstConversation(sync)
        XCTAssertTrue(thread.pending.isEmpty)
        XCTAssertEqual(thread.messages.map(\.body), ["hi", "hello back"])
        // The phone repeats old acknowledgements; they do nothing.
        _ = await sync.apply(batch(acks: [1, 2, sendId]))
        await relay.close()
    }

    /// A real, tiny JPEG made here, so previews can be produced from it.
    static let picture: Data = {
        let width = 8, height = 8
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }()

    func firstMessage(_ sync: MessageSync) async throws -> PhoneMessage {
        let conversation = try await firstConversation(sync)
        return try XCTUnwrap(conversation.messages.first)
    }

    func mmsBatch(parts: ValueSet, withMessage: Bool = true) -> ValueSet {
        var push = batch()
        if withMessage {
            push["mmsMessages"] = .object(ValueSet(["messageIds": .int64Array([3]), "threadIds": .int64Array([8]), "messageBoxTypes": .int32Array([1]),
                                                    "dates": .int64Array([5000]), "subjects": .stringArray([""]), "fromAddresses": .stringArray(["+300"]),
                                                    "toAddresses": .stringArray([""]), "readFlags": .boolArray([true]), "subscriptionIds": .int64Array([1]),
                                                    "actions": .int32Array([0])]))
        }
        push["mmsParts"] = .object(parts)
        return push
    }

    func testPictureMessagePartsBecomeAttachmentsAndBytesArriveOnRequest() async throws {
        let picture = Self.picture
        let fetched = ValueSet([
            "messageIds": .int64Array([3]), "partIds": .int64Array([72]), "contentTypes": .stringArray(["image/jpeg"]), "texts": .stringArray([""]),
            "names": .stringArray([""]), "fileNames": .stringArray(["beach.jpg"]), "sizes": .int64Array([Int64(picture.count)]),
            "contentByteSizes": .int32Array([Int32(picture.count)]), "contentBytes": .bytes(picture),
        ])
        let holder = SyncHolder()
        let phone = FakePhone()
        phone.responder = { [weak self] envelope in
            guard envelope.route == "/chat/v1", let self else { return nil }
            // As the phone does: push the parts with their bytes, then answer the request.
            holder.apply(self.mmsBatch(parts: fetched, withMessage: false))
            return ValueSet(["result": .int32(0), "contractVersion": .double(3.99)]).serialized()
        }
        let (messenger, relay) = try await phone.connect()
        let sync = MessageSync(messenger: messenger, sender: sender)
        holder.sync = sync

        // The automatic sync describes the parts without their bytes: sizes of -1.
        _ = await sync.apply(mmsBatch(parts: ValueSet([
            "messageIds": .int64Array([3, 3, 3, 3]), "partIds": .int64Array([70, 71, 72, 73]),
            "contentTypes": .stringArray(["application/smil", "text/plain", "image/jpeg", "video/mp4"]),
            "texts": .stringArray(["", "Look at this", "", ""]), "names": .stringArray(["", "", "", "clip"]),
            "fileNames": .stringArray(["", "", "beach.jpg", ""]), "sizes": .int64Array([120, 0, Int64(picture.count), 900_000]),
            "contentByteSizes": .int32Array([-1, -1, -1, -1]),
        ])))
        var message = try await firstMessage(sync)
        XCTAssertEqual(message.body, "Look at this")
        XCTAssertEqual(message.attachments.map(\.id), [72, 73], "layout and text parts are not attachments")
        XCTAssertEqual(message.attachments.map(\.fileName), ["beach.jpg", "clip"])
        XCTAssertEqual(message.attachmentCount, 2)
        XCTAssertNil(message.attachments[0].preview)
        XCTAssertTrue(message.attachments[0].isImage)
        XCTAssertFalse(message.attachments[1].isImage)

        let data = try await sync.attachmentData(partId: 72)
        XCTAssertEqual(data, picture)
        let request = try XCTUnwrap(phone.received(route: "/chat/v1").first.flatMap { try? ValueSet(serialized: $0.payload) })
        XCTAssertEqual(request["requestType"], .int32(1))
        XCTAssertEqual(request["requestedItems"], .int32(1))
        XCTAssertEqual(request["messagingMmsPartIds"], .int64Array([72]))
        XCTAssertEqual(request.strings("subcontentTypes"), ["messagesMmsMedia"])
        XCTAssertEqual(request.object("configuration"), ConnectExchange.messagingConfiguration, "the same switches as ever, or the phone resets its sync state")

        message = try await firstMessage(sync)
        XCTAssertNotNil(message.attachments[0].preview, "a picture whose bytes were seen keeps a preview")
        XCTAssertEqual(message.attachments.map(\.id), [72, 73])
        XCTAssertEqual(message.body, "Look at this", "a batch of parts alone changes nothing else")
        // A second request is served from memory.
        _ = try await sync.attachmentData(partId: 72)
        XCTAssertEqual(phone.received(route: "/chat/v1").count, 1)
        // The parts described again without bytes keep the preview.
        _ = await sync.apply(mmsBatch(parts: ValueSet([
            "messageIds": .int64Array([3]), "partIds": .int64Array([72]), "contentTypes": .stringArray(["image/jpeg"]), "texts": .stringArray([""]),
            "fileNames": .stringArray(["beach.jpg"]), "sizes": .int64Array([Int64(picture.count)]), "contentByteSizes": .int32Array([-1]),
        ])))
        message = try await firstMessage(sync)
        XCTAssertNotNil(message.attachments[0].preview)
        await relay.close()
    }

    /// Lets a scripted phone push into the sync from its answering closure.
    final class SyncHolder: @unchecked Sendable {
        var sync: MessageSync?
        private let group = DispatchGroup()
        func apply(_ values: ValueSet) {
            guard let sync else { return }
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached { _ = await sync.apply(values); semaphore.signal() }
            semaphore.wait()
        }
    }

    func testInlineBytesAreSlicedInArrayOrderAndABadSizeIsNotFollowed() async throws {
        let (sync, _, relay) = try await makeSync()
        let picture = Self.picture
        // A text part with bytes comes first; the picture's bytes follow it in the blob.
        _ = await sync.apply(mmsBatch(parts: ValueSet([
            "messageIds": .int64Array([3, 3, 3]), "partIds": .int64Array([1, 2, 3]),
            "contentTypes": .stringArray(["text/plain", "image/jpeg", "image/png"]), "texts": .stringArray(["hi", "", ""]),
            "fileNames": .stringArray(["", "a.jpg", "b.png"]), "sizes": .int64Array([2, Int64(picture.count), 50]),
            "contentByteSizes": .int32Array([2, Int32(picture.count), 1_000_000]),
            "contentBytes": .bytes(Data("hi".utf8) + picture),
        ])))
        let message = try await firstMessage(sync)
        XCTAssertNotNil(message.attachments.first { $0.id == 2 }?.preview)
        XCTAssertNil(message.attachments.first { $0.id == 3 }?.preview, "a size beyond the data yields no bytes and no crash")
        let held = try await sync.attachmentData(partId: 2)
        XCTAssertEqual(held, picture)
        await relay.close()
    }

    func testAPictureMessageKnownOnlyByItsCountIsAskedForAgain() async throws {
        let holder = SyncHolder()
        let phone = FakePhone()
        phone.responder = { [weak self] envelope in
            guard envelope.route == "/chat/v1", let self else { return nil }
            holder.apply(self.mmsBatch(parts: ValueSet([
                "messageIds": .int64Array([3]), "partIds": .int64Array([72]), "contentTypes": .stringArray(["image/jpeg"]), "texts": .stringArray([""]),
                "fileNames": .stringArray(["beach.jpg"]), "sizes": .int64Array([900]), "contentByteSizes": .int32Array([-1]),
            ])))
            return ValueSet(["result": .int32(0), "contractVersion": .double(3.99)]).serialized()
        }
        let (messenger, relay) = try await phone.connect()
        // As an older cache left it: the count, no parts.
        let counted = PhoneMessage(kind: .mms, messageId: 3, threadId: 8, date: Date(timeIntervalSince1970: 5), body: "", isIncoming: true, isRead: true,
                                   address: "+300", subscriptionId: 1, attachmentCount: 1)
        let old = try JSONEncoder().encode(MessageSync.Snapshot(sequenceNumbers: ["sms": 3, "mms": 1, "conversation": 2, "subscription": 1], sms: [],
                                                                mms: [counted], threads: [:], addresses: [:], subscriptions: []))
        let cache = MemoryBlobCache()
        cache.save(old)
        let sync = MessageSync(messenger: messenger, sender: sender, cache: cache)
        holder.sync = sync
        var message = try await firstMessage(sync)
        XCTAssertEqual(message.attachmentCount, 1)
        XCTAssertTrue(message.attachments.isEmpty)

        try await sync.describeAttachments(of: 3)
        let request = try XCTUnwrap(phone.received(route: "/chat/v1").first.flatMap { try? ValueSet(serialized: $0.payload) })
        XCTAssertEqual(request["requestType"], .int32(1))
        XCTAssertEqual(request["messagingMmsIds"], .int64Array([3]))
        XCTAssertEqual(request.object("configuration"), ConnectExchange.messagingConfiguration)
        message = try await firstMessage(sync)
        XCTAssertEqual(message.attachments.map(\.fileName), ["beach.jpg"])

        // And a list round asks for such a message even though its checksum is unchanged.
        let other = MessageSync(sender: sender, cache: { let c = MemoryBlobCache(); c.save(old); return c }())
        let answer = await other.apply(ValueSet(["contentType": .string("messaging"), "metadata": .int32(1),
                                                 "messagingMmsIds": .int64Array([3]), "messagingMmsChecksums": .int64Array([1]),
                                                 "messagingSmsIds": .int64Array([]), "messagingSmsChecksums": .int64Array([])]))
        XCTAssertEqual(answer.int64s("messagingMmsIds"), [3])
        await relay.close()
    }

    func testACacheWrittenBeforeAttachmentsWereKeptStillReads() throws {
        let old = #"{"kind":"mms","messageId":3,"threadId":8,"date":0,"body":"x","isIncoming":true,"isRead":true,"address":"+1","subscriptionId":1,"attachmentCount":2}"#
        let message = try JSONDecoder().decode(PhoneMessage.self, from: Data(old.utf8))
        XCTAssertEqual(message.attachmentCount, 2)
        XCTAssertTrue(message.attachments.isEmpty)
    }

    func testAPictureGoesInsideTheSendRequest() async throws {
        let (sync, phone, relay) = try await makeSync(responder: { envelope in
            guard envelope.route == "/chat/v1" else { return nil }
            return ValueSet(["result": .int32(0), "contractVersion": .double(3.99)]).serialized()
        })
        let first = OutgoingAttachment(name: "a.jpg", contentType: "image/jpeg", data: Data([1, 2, 3]))
        let second = OutgoingAttachment(name: "b.jpg", contentType: "image/jpeg", data: Data([4, 5]))
        try await sync.send("", threadId: 5, attachments: [first, second])
        let request = try XCTUnwrap(phone.received(route: "/chat/v1").first.flatMap { try? ValueSet(serialized: $0.payload) })
        XCTAssertEqual(request["requestType"], .int32(2))
        XCTAssertNil(request["body"], "left out when there is no text, as Windows does")
        XCTAssertEqual(request["partCount"], .int32(2))
        XCTAssertEqual(request.strings("partNames"), ["a.jpg", "b.jpg"])
        XCTAssertEqual(request.strings("partContentTypes"), ["image/jpeg", "image/jpeg"])
        XCTAssertEqual(request.int32s("partByteCounts"), [3, 2])
        XCTAssertEqual(request.bytes("partBytes"), Data([1, 2, 3, 4, 5]), "end to end, in order")
        XCTAssertEqual(request.strings("partContentIds"), ["", ""])
        let pending = await sync.conversations.first?.pending.first
        XCTAssertEqual(pending?.attachmentCount, 2)
        // A plain text carries none of the part keys.
        try await sync.send("just text", threadId: 5)
        let text = try XCTUnwrap(phone.received(route: "/chat/v1").last.flatMap { try? ValueSet(serialized: $0.payload) })
        XCTAssertNil(text["partCount"])
        XCTAssertEqual(text.string("body"), "just text")
        await relay.close()
    }

    func testAMessageThePhoneAcceptedSurvivesAReconnectUntilItIsAcknowledged() async throws {
        let (sync, phone, relay) = try await makeSync(responder: { envelope in
            guard envelope.route == "/chat/v1" else { return nil }
            return ValueSet(["result": .int32(0), "contractVersion": .double(3.99)]).serialized()
        })
        try await sync.send("on its way", threadId: 5)
        let request = try XCTUnwrap(phone.received(route: "/chat/v1").first.flatMap { try? ValueSet(serialized: $0.payload) })
        guard case .int64(let sendId)? = request["id"] else { return XCTFail("no send ID") }
        let other = FakePhone()
        let (replacement, otherRelay) = try await other.connect()
        await sync.attach(replacement)
        var state = await sync.conversations.first?.pending.first?.state
        XCTAssertEqual(state, .sending, "the phone took it; a reconnect does not make it a failure")
        _ = await sync.apply(batch(acks: [sendId]))
        state = await sync.conversations.first?.pending.first?.state
        XCTAssertNil(state)
        await relay.close()
        await otherRelay.close()
    }

    func testValuesFromThePhoneThatDoNotFitNeverTrap() async throws {
        // Sizes whose sum overflows.
        XCTAssertNil(ValueSet.split(Data([1, 2]), sizes: [Int64.max, 1]))
        XCTAssertNil(ValueSet.split(Data([1, 2]), sizes: [-1, 3]))
        XCTAssertEqual(ValueSet.split(Data([1, 2, 3]), sizes: [1, 2]), [Data([1]), Data([2, 3])])
        // A date at the end of time.
        XCTAssertEqual(MessageSync.milliseconds(Date(timeIntervalSince1970: Double(Int64.max))), .max)
        XCTAssertEqual(MessageSync.milliseconds(Date(timeIntervalSince1970: 1.5)), 1500)
        XCTAssertEqual(MessageSync.milliseconds(Date(timeIntervalSince1970: .nan)), 0)
        // An action index beyond 32 bits is not offered.
        let notification = try XCTUnwrap(PhoneNotification(json: #"{"key":"k","packageName":"p","postTime":1,"notificationActions":[{"actionName":"Big","actionIndex":3000000000},{"actionName":"Ok","actionIndex":2}]}"#))
        XCTAssertEqual(notification.actions.map(\.name), ["Ok"])
    }

    func testANewConversationNamesItsRecipientsAndFailuresAreKept() async throws {
        let (sync, phone, relay) = try await makeSync(responder: { envelope in
            guard envelope.route == "/chat/v1" else { return nil }
            return ValueSet(["result": .int32(1), "sendMessageFailureReason": .int32(2), "contractVersion": .double(3.99)]).serialized()
        })
        do {
            try await sync.send("first message", recipients: ["+555"])
            XCTFail("expected a failure")
        } catch MessageSync.SendError.failed(let reason) {
            XCTAssertEqual(reason, 2)
            XCTAssertEqual(MessageSync.describeFailure(reason), "The phone has no SIM card.")
        }
        let request = try XCTUnwrap(phone.received(route: "/chat/v1").first.flatMap { try? ValueSet(serialized: $0.payload) })
        XCTAssertEqual(request["recipients"], .stringArray(["+555"]))
        XCTAssertNil(request["threadId"], "no thread exists yet")
        var conversation = try await firstConversation(sync)
        XCTAssertEqual(conversation.title, "+555")
        XCTAssertEqual(conversation.pending.first?.state, .failed(reason: 2), "a failed message stays visible")
        await sync.discardFailed(id: conversation.pending[0].id)
        let empty = await sync.conversations
        XCTAssertTrue(empty.isEmpty)
        conversation.pending = []
        await relay.close()
    }

    func testConnectRequestAndReply() throws {
        let request = ConnectExchange.request(sender: sender, sequenceNumbers: ["sms": -1, "mms": -1, "conversation": 3, "subscription": -1])
        XCTAssertEqual(request.string("contentType"), "connect")
        XCTAssertEqual(request.object("sequenceNumbers")?["conversation"], .int64(3), "Int64, as the phone casts it")
        XCTAssertEqual(request.object("sequenceNumbers")?.entries.count, 4, "only the listed types are synced")
        let configuration = try XCTUnwrap(request.object("configuration"))
        XCTAssertEqual(configuration.bool("SequencedContentSyncs"), true)
        XCTAssertEqual(configuration.bool("MessagingSync"), true)
        XCTAssertEqual(configuration["TaskContinuityVersion"], .uint32(1))
        XCTAssertEqual(request.object("attributes")?.string("flightRing"), "Public")

        let reply = ValueSet([
            "result": .int32(0), "sms": .int64(7), "mms": .int64(0), "conversation": .int64(2),
            "permissions": .object(ValueSet(["messaging": .bool(true), "photos": .bool(true), "notifications": .bool(false)])),
            "capabilities": .object(ValueSet(["messaging": .int32(48), "photos": .int32(3)])),
        ])
        let info = ConnectExchange.parse(reply)
        XCTAssertEqual(info.result, .success)
        XCTAssertTrue(info.messagingAllowed)
        XCTAssertFalse(info.notificationsAllowed)
        XCTAssertTrue(info.canSendMessages, "bit 16 of the messaging capabilities")
        XCTAssertEqual(info.sequenceNumbers["sms"], 7)
    }

    /// Checks against what Windows and the phone really exchanged, from the capture on this
    /// machine. Nothing from the capture is printed or stored.
    func testAgainstTheRealConnectAndSendFromTheCapture() async throws {
        let messages = try LocalCapture.appMessages()
        guard let connect = messages.first(where: { $0.fromPC && $0.envelope.route == "/connect/v1" }),
              let send = messages.first(where: { $0.fromPC && $0.envelope.route == "/chat/v1" }) else { throw XCTSkip("the local capture lacks a connect or a send") }

        // Our configuration is the one Windows sent, value for value.
        XCTAssertEqual(ConnectExchange.configuration, connect.values.object("configuration"))
        let ours = ConnectExchange.request(sender: sender, sequenceNumbers: ["sms": -1])
        let telemetry: Set<String> = ["EffectiveSampleRate", "UploadSampleRate", "sampleId"]
        XCTAssertEqual(Set(ours.entries.keys), Set(connect.values.entries.keys).subtracting(telemetry))
        XCTAssertEqual(ours.object("attributes").map { Set($0.entries.keys) }, connect.values.object("attributes").map { Set($0.entries.keys) })
        let theirNumbers = try XCTUnwrap(connect.values.object("sequenceNumbers"))
        XCTAssertTrue(theirNumbers.entries.values.allSatisfy { if case .int64 = $0 { return true }; return false })
        if let reply = messages.first(where: { !$0.fromPC && $0.envelope.originalRequestId == connect.envelope.requestId }) {
            let info = ConnectExchange.parse(reply.values)
            XCTAssertEqual(info.result, .success)
            XCTAssertTrue(info.messagingAllowed)
            XCTAssertTrue(info.canSendMessages)
            XCTAssertNotNil(info.sequenceNumbers["sms"])
        }

        // Our send request has the fields and types of the one Windows sent.
        let (sync, _, relay) = try await makeSync()
        let real = send.values
        let mine = await sync.sendRequest(body: real.string("body") ?? "", threadId: real.int("threadId").map(Int64.init), recipients: [],
                                          subscriptionId: Int32(real.int("subscriptionId") ?? -1), id: Int64(real.int("id") ?? 0), tempId: real.string("tempId") ?? "")
        var a = mine, b = real
        for key in ["correlationVector", "displayName", "installationId", "appVersion"] { a[key] = nil; b[key] = nil }
        XCTAssertEqual(a, b, "same keys, types and values as the captured request")

        // The push that followed the send parses: one sent message, acknowledged, numbers stored.
        // The one that carries the acknowledgement of this send together with a message.
        let pushes = messages.filter { !$0.fromPC && $0.envelope.route == "/legacy/phonecontent" && $0.values.string("contentType") == "messaging" }
        let push = try XCTUnwrap(pushes.first { ($0.values.object("smsMessages")?.int64s("messageIds")?.count ?? 0) > 0
            && $0.values.object("acks")?.int64s("ids")?.isEmpty == false })
        let reply = await sync.apply(push.values)
        XCTAssertEqual(reply, ValueSet(["result": .int32(0)]))
        let conversations = await sync.conversations
        XCTAssertFalse(conversations.isEmpty)
        let message = try XCTUnwrap(conversations.first?.messages.last)
        XCTAssertFalse(message.isIncoming, "it was sent from the phone")
        XCTAssertTrue(message.isRead)
        XCTAssertFalse(message.address.isEmpty)
        XCTAssertGreaterThan(message.date.timeIntervalSince1970, 1_700_000_000)
        XCTAssertFalse(conversations[0].participants.isEmpty, "the thread's recipients resolve through the address table")
        let numbers = await sync.sequenceNumbers
        XCTAssertGreaterThan(numbers["sms"] ?? -1, 0)
        XCTAssertEqual(push.values.object("acks")?.int64s("ids"), [Int64(real.int("id") ?? -1)], "the phone acknowledged the send by its id")
        await relay.close()
    }
}

final class MessageCacheTests: XCTestCase {
    let sender = AppSender(displayName: "Mac", installationId: "INSTALL")

    func smsBatch(id: Int64, body: String, sequence: Int64) -> ValueSet {
        var sms: [String: ValueSet.Value] = [:]
        sms["messageIds"] = .int64Array([id])
        sms["threadIds"] = .int64Array([5])
        sms["messageTypes"] = .int32Array([1])
        sms["dates"] = .int64Array([id * 1000])
        sms["bodies"] = .stringArray([body])
        sms["fromAddresses"] = .stringArray(["+100"])
        sms["toAddresses"] = .stringArray([""])
        sms["readFlags"] = .boolArray([false])
        sms["actions"] = .int32Array([0])
        return ValueSet(["smsMessages": .object(ValueSet(sms)),
                         "conversations": .object(ValueSet(["ids": .int64Array([5]), "recipientIds": .stringArray(["40"]), "actions": .int32Array([1])])),
                         "canonicalAddresses": .object(ValueSet(["ids": .stringArray(["40"]), "addresses": .stringArray(["+100"])])),
                         "sequenceNumbers": .object(ValueSet(["sms": .int64(sequence), "mms": .int64(0), "conversation": .int64(2), "subscription": .int64(1)]))])
    }

    func testEncryptedFileRoundTripsAndRejectsTheWrongKeyOrATamperedFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("winphone-tests-\(UUID().uuidString)/messages.cache")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let key = Data((0..<32).map { UInt8($0) })
        let file = EncryptedFile(url: url, key: key)
        XCTAssertNil(file.load())
        let secret = Data("a private message".utf8)
        file.save(secret)
        XCTAssertEqual(file.load(), secret)
        let onDisk = try Data(contentsOf: url)
        XCTAssertNil(onDisk.range(of: secret), "the text is not readable in the file")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertNil(EncryptedFile(url: url, key: Data(repeating: 9, count: 32)).load(), "another key opens nothing")
        var tampered = onDisk
        tampered[tampered.count / 2] ^= 1
        try tampered.write(to: url)
        XCTAssertNil(file.load(), "a changed file is rejected, not half-read")
        file.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMessagesSurviveARelaunchAndOnlyNewOnesAreAskedFor() async throws {
        let cache = MemoryBlobCache()
        let first = MessageSync(sender: sender, cache: cache)
        _ = await first.apply(smsBatch(id: 1, body: "hello", sequence: 7))
        let saved = await waitUntil { cache.saveCount > 0 }
        XCTAssertTrue(saved, "written shortly after the batch")

        // A new launch: the same cache, no connection yet.
        let second = MessageSync(sender: sender, cache: cache)
        let conversations = await second.conversations
        XCTAssertEqual(conversations.first?.messages.map(\.body), ["hello"], "shown before the phone is reached")
        XCTAssertEqual(conversations.first?.title, "+100")
        let numbers = await second.sequenceNumbers
        XCTAssertEqual(numbers["sms"], 7, "sent in the handshake, so the phone sends only what is newer")

        // A full list from the phone now wants nothing we already hold.
        let answer = await second.apply(ValueSet(["metadata": .int32(1), "messagingSmsIds": .int64Array([1, 2]), "messagingSmsChecksums": .int64Array([0, 0]),
                                                  "messagingSubscriptionIds": .int64Array([])]))
        XCTAssertEqual(answer["messagingSmsIds"], .int64Array([2]))
    }

    func testAPhoneWhoseNumberingStartedOverDiscardsTheCache() async {
        let cache = MemoryBlobCache()
        let sync = MessageSync(sender: sender, cache: cache)
        _ = await sync.apply(smsBatch(id: 1, body: "hello", sequence: 7))
        var dropped = await sync.reconcile(phoneNumbers: ["sms": 9, "mms": 0, "conversation": 2, "subscription": 1])
        XCTAssertFalse(dropped, "a phone that is ahead is normal")
        dropped = await sync.reconcile(phoneNumbers: ["sms": 3, "mms": 0, "conversation": 2, "subscription": 1])
        XCTAssertTrue(dropped, "a phone that is behind us was reset")
        let conversations = await sync.conversations
        XCTAssertTrue(conversations.isEmpty)
        let numbers = await sync.sequenceNumbers
        XCTAssertEqual(numbers["sms"], -1, "the next handshake asks for everything")
        XCTAssertNil(cache.load())
    }

    func testAMessageStillSendingWhenTheConnectionIsReplacedIsShownAsFailed() async throws {
        let phone = FakePhone()   // never answers the send
        let (messenger, relay) = try await phone.connect()
        let sync = MessageSync(messenger: messenger, sender: sender)
        let sending = Task { try? await sync.send("hello", threadId: 5) }
        let shown = await waitUntil { await sync.conversations.first?.pending.first?.state == .sending }
        XCTAssertTrue(shown)
        let other = FakePhone()
        let (replacement, otherRelay) = try await other.connect()
        await sync.attach(replacement)
        let state = await sync.conversations.first?.pending.first?.state
        XCTAssertEqual(state, .failed(reason: nil), "nobody will answer the old request")
        sending.cancel()
        await relay.close()
        await otherRelay.close()
    }
}
