import ImageIO
import XCTest
@testable import WinPhoneCore

/// APP messages of a raw capture on this machine, decoded with the library's own codecs.
/// Captures are not part of the repository, so tests that use this skip elsewhere.
enum LocalCapture {
    struct Message {
        let fromPC: Bool
        let envelope: PlatformEnvelope
        let values: ValueSet
    }

    static func appMessages(session: String = "vm-raw-2026-10-09") throws -> [Message] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let capture = root.appendingPathComponent("captures/\(session)/flows.jsonl")
        guard let text = try? String(contentsOf: capture, encoding: .utf8) else { throw XCTSkip("no local capture") }
        var messages: [Message] = []
        for line in text.split(separator: "\n") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["type"] as? String == "ws", let raw = (record["raw_b64"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let frames = try? SignalR.splitFrames(raw) else { continue }
            for frame in frames {
                guard case .invocation(_, _, _, let arguments)? = try? HubMessage(frame: frame), arguments.count >= 3,
                      case .fragment(let fragment)? = try? DcgPacket(arguments[2]), fragment.messageType == .app, fragment.fragmentCount == 1,
                      let envelope = try? PlatformEnvelope(decoding: fragment.raw), let values = try? ValueSet(serialized: envelope.payload) else { continue }
                messages.append(Message(fromPC: record["dir"] as? String == "c2s", envelope: envelope, values: values))
            }
        }
        return messages
    }
}

final class PhotoSyncTests: XCTestCase {
    static let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
    let sender = AppSender(displayName: "Mac", installationId: "INSTALL")

    func makeSync(limits: PhotoSync.Limits = .init(), responder: (@Sendable (PlatformEnvelope) -> Data?)? = nil) async throws -> (PhotoSync, FakePhone, RelayClient) {
        let phone = FakePhone()
        phone.responder = responder
        let (messenger, relay) = try await phone.connect()
        return (PhotoSync(messenger: messenger, sender: sender, limits: limits), phone, relay)
    }

    func metadata(ids: [Int64], checksums: [Int64], sequence: Int64) -> ValueSet {
        ValueSet(["contentType": .string("mediaInfo"), "metadata": .int32(1), "itemCount": .int32(Int32(ids.count)), "mediaIds": .int64Array(ids),
                  "mediaTimes": .int64Array(ids.map { $0 * 1000 }), "checksums": .int64Array(checksums), "sequenceNumber": .int64(sequence),
                  "correlationVector": .string("cv-1"), "contractVersion": .double(3.99)])
    }

    /// A content message as the phone builds it: parallel arrays, thumbnails end to end.
    func content(ids: [Int64], thumbnails: [Data], actions: [Int32]? = nil, sequence: Int64? = nil, taken: [Int64]? = nil) -> ValueSet {
        var entries: [String: ValueSet.Value] = [:]
        entries["contentType"] = .string("mediaInfo")
        entries["mediaIds"] = .int64Array(ids)
        entries["mediaNames"] = .stringArray(ids.map { "IMG_\($0).jpg" })
        entries["mediaTimes"] = .int64Array(ids.map { $0 * 1000 })
        entries["mediaTakenTimes"] = .int64Array(taken ?? ids.map { $0 * 1_000_000 })
        entries["mediaMimeTypes"] = .stringArray(ids.map { _ in "image/jpeg" })
        entries["mediaHeights"] = .int64Array(ids.map { _ in Int64(3000) })
        entries["mediaWidths"] = .int64Array(ids.map { _ in Int64(4000) })
        entries["mediaSizes"] = .int64Array(ids.map { _ in Int64(2_000_000) })
        entries["mediaOrientations"] = .stringArray(ids.map { $0 == 50 ? "90" : "" })
        entries["mediaURIs"] = .stringArray(ids.map { "content://media/external/images/media/\($0)" })
        entries["checksums"] = .int64Array(ids.map { -$0 })
        entries["mediaActions"] = .int32Array(actions ?? ids.map { _ in Int32(-1) })
        entries["mediaThumbnailSizes"] = .int64Array(thumbnails.map { Int64($0.count) })
        var blob = Data()
        for thumbnail in thumbnails { blob.append(thumbnail) }
        entries["mediaThumbnails"] = .bytes(blob)
        if let sequence { entries["sequenceNumber"] = .int64(sequence) }
        return ValueSet(entries)
    }

    func testFullSyncAsksForTheNewestItemsAndStoresWhatArrives() async throws {
        var limits = PhotoSync.Limits()
        limits.window = 3
        limits.initialThumbnails = 2
        let (sync, _, relay) = try await makeSync(limits: limits)

        // Round one: the phone lists five IDs, newest first. We keep a window of three.
        let answer = await sync.apply(metadata(ids: [50, 40, 30, 20, 10], checksums: [-50, -40, -30, -20, -10], sequence: 7))
        XCTAssertEqual(answer.int("result"), 0)
        XCTAssertEqual(answer["itemCount"], .int32(3), "must be an Int32 above zero, or the phone sends nothing")
        XCTAssertEqual(answer["mediaIds"], .int64Array([50, 40, 30]))
        XCTAssertEqual(answer["mediaRequestedIds"], .int64Array([50, 40]), "thumbnails for the first two")
        XCTAssertEqual(answer.string("correlationVector"), "cv-1")
        XCTAssertEqual(answer.string("contentType"), "mediaInfo")
        var number = await sync.sequenceNumber
        XCTAssertEqual(number, -1, "the number is stored only after the content arrived")

        // Round two: the items, in ascending ID order as on the wire, thumbnails for two of them.
        let reply = await sync.apply(content(ids: [30, 40, 50], thumbnails: [Data(), Self.jpeg, Self.jpeg + [9]], sequence: 7))
        XCTAssertEqual(reply, ValueSet(["result": .int32(0)]))
        number = await sync.sequenceNumber
        XCTAssertEqual(number, 7)
        let photos = await sync.photos
        XCTAssertEqual(photos.map(\.id), [50, 40, 30], "sorted newest first by taken time, whatever order they came in")
        XCTAssertEqual(photos[0].thumbnail, Self.jpeg + [9])
        XCTAssertEqual(photos[1].thumbnail, Self.jpeg)
        XCTAssertNil(photos[2].thumbnail)
        XCTAssertEqual(photos[0].name, "IMG_50.jpg")
        XCTAssertEqual(photos[0].orientation, 90)
        XCTAssertEqual(photos[0].displaySize.width, 3000, "a quarter turn swaps the sides")
        XCTAssertEqual(photos[2].orientation, 0, "an empty orientation means none")
        XCTAssertTrue(photos[0].arrivesReduced)
        XCTAssertEqual(photos[0].taken, Date(timeIntervalSince1970: 50_000))
        await relay.close()
    }

    func testAnUnchangedListAnswersUpToDate() async throws {
        let (sync, _, relay) = try await makeSync()
        _ = await sync.apply(metadata(ids: [2, 1], checksums: [-2, -1], sequence: 3))
        _ = await sync.apply(content(ids: [1, 2], thumbnails: [Self.jpeg, Self.jpeg], sequence: 3))

        // Same checksums again: nothing wanted, and one photo fell out of the phone's list.
        let answer = await sync.apply(metadata(ids: [2], checksums: [-2], sequence: 4))
        XCTAssertEqual(answer["itemCount"], .int32(0))
        XCTAssertEqual(answer["mediaIds"], .int64Array([]))
        let number = await sync.sequenceNumber
        XCTAssertEqual(number, 4, "with nothing to fetch the list is current at once")
        let ids = await sync.photos.map(\.id)
        XCTAssertEqual(ids, [2], "items missing from the phone's list are dropped")

        // A changed checksum is asked for again.
        let changed = await sync.apply(metadata(ids: [2], checksums: [999], sequence: 5))
        XCTAssertEqual(changed["mediaIds"], .int64Array([2]))
        await relay.close()
    }

    func testIncrementalPushAddsUpdatesAndDeletes() async throws {
        let (sync, _, relay) = try await makeSync()
        _ = await sync.apply(content(ids: [1, 2], thumbnails: [Self.jpeg, Self.jpeg], sequence: 1))
        // Deleted items come as stubs with action 2; a new photo with action 0.
        var push = content(ids: [1, 3], thumbnails: [Data(), Self.jpeg], actions: [2, 0], sequence: 2)
        push["incremental"] = .int32(1)
        let reply = await sync.apply(push)
        XCTAssertEqual(reply.int("result"), 0)
        let ids = await sync.photos.map(\.id)
        XCTAssertEqual(ids, [3, 2])
        let number = await sync.sequenceNumber
        XCTAssertEqual(number, 2)
        await relay.close()
    }

    func testMismatchedThumbnailSizesAreRefused() async throws {
        let (sync, _, relay) = try await makeSync()
        var bad = content(ids: [1], thumbnails: [Self.jpeg], sequence: 9)
        bad["mediaThumbnailSizes"] = .int64Array([99])
        let reply = await sync.apply(bad)
        XCTAssertEqual(reply.int("result"), ScenarioResult.failure.rawValue)
        let number = await sync.sequenceNumber
        XCTAssertEqual(number, -1, "a message that failed is not recorded as received")
        await relay.close()
    }

    func testDeleteNamesTheItemsWithTheirChecksumsAndRemovesWhatThePhoneDeleted() async throws {
        let (sync, phone, relay) = try await makeSync(responder: { envelope in
            guard envelope.route == "/media/v1" else { return nil }
            // The second item had changed on the phone: a partial failure.
            return ValueSet(["result": .int32(1), "mediaSuccessfullyDeletedIds": .int64Array([11]),
                             "mediaUnsuccessfullyDeletedIds": .int64Array([12]), "contractVersion": .double(3.99)]).serialized()
        })
        _ = await sync.apply(content(ids: [11, 12, 13], thumbnails: [Self.jpeg, Self.jpeg, Self.jpeg], sequence: 4))
        let checksums = await sync.photos.reduce(into: [Int64: Int64]()) { $0[$1.id] = $1.checksum }
        do {
            try await sync.delete(ids: [12, 11, 11, 99])
            XCTFail("a partial failure is a failure")
        } catch let error as PhotoSync.PhotoError {
            XCTAssertEqual(error, .failed(.failure))
        }
        let request = try XCTUnwrap(phone.received(route: "/media/v1").first.flatMap { try? ValueSet(serialized: $0.payload) })
        XCTAssertEqual(request["requestType"], .int32(0), "its presence is what selects deletion")
        XCTAssertNil(request["contentType"])
        XCTAssertEqual(request.int64s("mediaIds"), [11, 12], "no duplicates, nothing unknown")
        XCTAssertEqual(request.int64s("checksums"), [checksums[11] ?? -1, checksums[12] ?? -1])
        XCTAssertEqual(request.double("contractVersion"), 3.99)
        let left = await sync.photos.map(\.id).sorted()
        XCTAssertEqual(left, [12, 13], "what the phone did delete is gone here too")
        await relay.close()
    }

    func testThumbnailAndImageRequestsMatchTheWire() async throws {
        let image = Self.jpeg + Data(repeating: 7, count: 100)
        let (sync, phone, relay) = try await makeSync(responder: { envelope in
            guard envelope.route == "/media/v1", let request = try? ValueSet(serialized: envelope.payload) else { return nil }
            let ids = request.int64s("mediaIds") ?? []
            switch request.string("contentType") {
            case "thumbnails":
                return ValueSet(["result": .int32(0), "contractVersion": .double(3.99), "photos_full": .bool(true), "mediaIds": .int64Array(ids),
                                 "mediaNames": .stringArray(ids.map { "IMG_\($0).jpg" }), "checksums": .int64Array(ids.map { -$0 }),
                                 "mediaActions": .int32Array(ids.map { _ in -1 }), "mediaThumbnailSizes": .int64Array(ids.map { _ in Int64(PhotoSyncTests.jpeg.count) }),
                                 "mediaThumbnails": .bytes(ids.reduce(Data()) { data, _ in data + PhotoSyncTests.jpeg })]).serialized()
            case "photos":
                // Here `mediaSizes` is the length of each image inside `content`.
                return ValueSet(["result": .int32(0), "contractVersion": .double(3.99), "photos_full": .bool(true), "mediaIds": .int64Array(ids),
                                 "mediaSizes": .int64Array([Int64(image.count)]), "content": .bytes(image)]).serialized()
            default:
                return ValueSet(["result": .int32(0), "contractVersion": .double(3.99), "photos_full": .bool(false)]).serialized()
            }
        })
        _ = await sync.apply(content(ids: Array(1...20), thumbnails: Array(repeating: Data(), count: 20), sequence: 1))

        try await sync.loadThumbnails(for: Array(1...20))
        let requests = phone.received(route: "/media/v1").compactMap { try? ValueSet(serialized: $0.payload) }
        XCTAssertEqual(requests.map { $0.int64s("mediaIds")?.count }, [16, 4], "batches of sixteen, as Phone Link sends")
        for request in requests {
            XCTAssertEqual(request.string("contentType"), "thumbnails")
            XCTAssertEqual(request.double("contractVersion"), 3.99, "the phone needs it in every request")
            XCTAssertNil(request["requestType"], "that key would turn the request into a delete")
            XCTAssertEqual(Set(request.entries.keys), ["appVersion", "contentType", "contractVersion", "correlationVector", "displayName", "ignoreResponse",
                                                       "installationId", "isuserinitiated", "mediaIds", "transportType"], "the keys Windows sent in the capture")
        }
        let loaded = await sync.photos.filter { $0.thumbnail != nil }.count
        XCTAssertEqual(loaded, 20)
        // Asking again for loaded thumbnails sends nothing.
        try await sync.loadThumbnails(for: [1, 2, 3])
        XCTAssertEqual(phone.received(route: "/media/v1").count, 2)

        let fetched = try await sync.fetchImage(id: 5)
        XCTAssertEqual(fetched.data, image)
        XCTAssertEqual(fetched.fileExtension, "jpg")
        let last = try XCTUnwrap(phone.received(route: "/media/v1").last.flatMap { try? ValueSet(serialized: $0.payload) })
        XCTAssertEqual(last.string("contentType"), "photos")
        XCTAssertEqual(last["mediaIds"], .int64Array([5]))

        try await sync.refresh()
        let access = await sync.hasFullAccess
        XCTAssertEqual(access, false, "the reply reports the phone's photo access")
        await relay.close()
    }

    func testAnEntryThePhoneCannotDrawIsMarkedAndNotAskedForAgain() async throws {
        // The phone finds both items but has no thumbnail for the second: size 0.
        let (sync, phone, relay) = try await makeSync(responder: { envelope in
            guard let request = try? ValueSet(serialized: envelope.payload), let ids = request.int64s("mediaIds") else { return nil }
            return ValueSet(["result": .int32(0), "contractVersion": .double(3.99), "mediaIds": .int64Array(ids),
                             "mediaThumbnailSizes": .int64Array(ids.map { $0 == 2 ? 0 : Int64(PhotoSyncTests.jpeg.count) }),
                             "mediaThumbnails": .bytes(ids.reduce(Data()) { $1 == 2 ? $0 : $0 + PhotoSyncTests.jpeg })]).serialized()
        })
        _ = await sync.apply(content(ids: [1, 2], thumbnails: [Data(), Data()], sequence: 1))
        try await sync.loadThumbnails(for: [1, 2])
        var photos = await sync.photos
        XCTAssertEqual(photos.first { $0.id == 1 }?.thumbnailUnavailable, false)
        XCTAssertEqual(photos.first { $0.id == 2 }?.thumbnailUnavailable, true)
        XCTAssertNil(photos.first { $0.id == 2 }?.thumbnail)
        XCTAssertEqual(phone.received(route: "/media/v1").count, 2, "one thumbnail request, then one try at the image itself")

        // A manual refresh clears the mark so the entry gets another try.
        phone.responder = { _ in ValueSet(["result": .int32(0), "contractVersion": .double(3.99)]).serialized() }
        try await sync.refresh()
        photos = await sync.photos
        XCTAssertEqual(photos.first { $0.id == 2 }?.thumbnailUnavailable, false)
        await relay.close()
    }

    /// A small real PNG, to stand in for an image the phone can send but not thumbnail.
    static func pngImage(side: Int) -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    func testAThumbnailIsMadeHereWhenThePhoneHasNone() async throws {
        let image = Self.pngImage(side: 1200)
        let (sync, phone, relay) = try await makeSync(responder: { envelope in
            guard let request = try? ValueSet(serialized: envelope.payload), let ids = request.int64s("mediaIds") else { return nil }
            if request.string("contentType") == "photos" {
                return ValueSet(["result": .int32(0), "contractVersion": .double(3.99), "mediaIds": .int64Array(ids),
                                 "mediaSizes": .int64Array([Int64(image.count)]), "content": .bytes(image)]).serialized()
            }
            // The thumbnailer has nothing for this item.
            return ValueSet(["result": .int32(0), "contractVersion": .double(3.99), "mediaIds": .int64Array(ids),
                             "mediaThumbnailSizes": .int64Array(ids.map { _ in 0 }), "mediaThumbnails": .bytes(Data())]).serialized()
        })
        _ = await sync.apply(content(ids: [7], thumbnails: [Data()], sequence: 1))
        try await sync.loadThumbnails(for: [7])
        let first = await sync.photos.first
        let photo = try XCTUnwrap(first)
        XCTAssertFalse(photo.thumbnailUnavailable)
        let thumbnail = try XCTUnwrap(photo.thumbnail)
        XCTAssertTrue(thumbnail.starts(with: [0xFF, 0xD8, 0xFF]), "a JPEG")
        XCTAssertLessThan(thumbnail.count, image.count + 50_000)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(properties?[kCGImagePropertyPixelWidth] as? Int, 512, "scaled to the phone's thumbnail size")
        XCTAssertEqual(phone.received(route: "/media/v1").map { (try? ValueSet(serialized: $0.payload))?.string("contentType") }, ["thumbnails", "photos"])
        XCTAssertNil(PhotoSync.makeThumbnail(from: Data([1, 2, 3])), "bytes that are not an image give nothing")
        await relay.close()
    }

    func testTheListAndThumbnailsSurviveARelaunch() async throws {
        let cache = MemoryBlobCache()
        let first = PhotoSync(sender: sender, cache: cache)
        _ = await first.apply(content(ids: [1, 2], thumbnails: [Self.jpeg, Data()], sequence: 6))
        let saved = await waitUntil(timeout: 5) { cache.saveCount > 0 }
        XCTAssertTrue(saved)

        let second = PhotoSync(sender: sender, cache: cache)
        let photos = await second.photos
        XCTAssertEqual(photos.map(\.id), [2, 1])
        XCTAssertEqual(photos.first { $0.id == 1 }?.thumbnail, Self.jpeg)
        let number = await second.sequenceNumber
        XCTAssertEqual(number, 6, "sent in the handshake, so the phone sends only what changed")

        // A phone whose numbering went backwards was reset.
        var dropped = await second.reconcile(phoneNumber: 9)
        XCTAssertFalse(dropped)
        dropped = await second.reconcile(phoneNumber: 2)
        XCTAssertTrue(dropped)
        let left = await second.photos
        XCTAssertTrue(left.isEmpty)
        XCTAssertNil(cache.load())
    }

    func testPermissionAndMissingImagesAreReported() async throws {
        // The scripted phone must stay alive to answer.
        let (sync, phone, relay) = try await makeSync(responder: { envelope in
            let request = try? ValueSet(serialized: envelope.payload)
            if request?.string("contentType") == "photos" {
                return ValueSet(["result": .int32(0), "contractVersion": .double(3.99), "mediaIds": .int64Array([]), "mediaSizes": .int64Array([]), "content": .bytes(Data())]).serialized()
            }
            return ValueSet(["result": .int32(7), "contractVersion": .double(3.99)]).serialized()
        })
        do { try await sync.refresh(); XCTFail("expected an error") } catch PhotoSync.PhotoError.needsPermission {}
        do { _ = try await sync.fetchImage(id: 1); XCTFail("expected an error") } catch PhotoSync.PhotoError.notFound {}
        XCTAssertEqual(phone.received(route: "/media/v1").count, 2)
        await relay.close()
    }

    func testFormatIsReadFromTheBytesNotTheName() {
        XCTAssertEqual(FetchedPhoto.fileExtension(for: Data([0xFF, 0xD8, 0xFF, 0xE1])), "jpg")
        XCTAssertEqual(FetchedPhoto.fileExtension(for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D])), "png")
        XCTAssertEqual(FetchedPhoto.fileExtension(for: Data([0, 0, 0, 0x18] + Array("ftypheic".utf8))), "heic")
        XCTAssertEqual(FetchedPhoto.fileExtension(for: Data(Array("RIFF".utf8) + [1, 2, 3, 4] + Array("WEBP".utf8))), "webp")
        XCTAssertEqual(ValueSet.split(Data([1, 2, 3]), sizes: [1, 0, 2]), [Data([1]), Data(), Data([2, 3])])
        XCTAssertNil(ValueSet.split(Data([1, 2, 3]), sizes: [1, 1]))
        XCTAssertNil(ValueSet.split(Data([1]), sizes: [-1, 2]))
    }

    /// The real thumbnail and image replies captured from the phone parse with this code, and
    /// the requests Windows sent have the keys we send. Uses the local capture; nothing from it
    /// is printed or stored.
    func testRealPhotoRepliesFromTheCaptureParse() async throws {
        let messages = try LocalCapture.appMessages()
        let requests = messages.filter { $0.fromPC && $0.envelope.route == "/media/v1" }
        guard !requests.isEmpty else { throw XCTSkip("the local capture has no photo traffic") }
        let (sync, _, relay) = try await makeSync()
        var thumbnailReplies = 0, imageReplies = 0
        for request in requests {
            guard let id = request.envelope.requestId,
                  let reply = messages.first(where: { !$0.fromPC && $0.envelope.originalRequestId == id }) else { continue }
            XCTAssertEqual(Set(request.values.entries.keys), ["appVersion", "contentType", "contractVersion", "correlationVector", "displayName", "ignoreResponse",
                                                              "installationId", "isuserinitiated", "mediaIds", "transportType"])
            XCTAssertEqual(reply.values.int("result"), 0)
            switch request.values.string("contentType") {
            case "thumbnails":
                guard let blob = reply.values.bytes("mediaThumbnails"), let sizes = reply.values.int64s("mediaThumbnailSizes") else { continue }
                let pieces = try XCTUnwrap(ValueSet.split(blob, sizes: sizes), "thumbnail sizes add up to the blob")
                XCTAssertTrue(pieces.filter { !$0.isEmpty }.allSatisfy { FetchedPhoto.fileExtension(for: $0) == "jpg" && $0.starts(with: [0xFF, 0xD8, 0xFF]) })
                let answer = await sync.apply(reply.values)
                XCTAssertEqual(answer.int("result"), 0)
                thumbnailReplies += 1
            case "photos":
                let content = try XCTUnwrap(reply.values.bytes("content"))
                let sizes = try XCTUnwrap(reply.values.int64s("mediaSizes"))
                XCTAssertNotNil(ValueSet.split(content, sizes: sizes))
                imageReplies += 1
            default:
                break
            }
        }
        XCTAssertGreaterThan(thumbnailReplies, 0)
        XCTAssertGreaterThan(imageReplies, 0)
        let photos = await sync.photos
        XCTAssertFalse(photos.isEmpty)
        XCTAssertTrue(photos.allSatisfy { !$0.name.isEmpty && $0.width > 0 && $0.taken.timeIntervalSince1970 > 1_000_000_000 })
        await relay.close()
    }
}
