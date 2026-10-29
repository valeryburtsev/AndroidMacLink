import XCTest
@testable import WinPhoneCore

/// The phone's files as a list to browse, against a phone scripted from its own code
/// (`protocol/specs/file-transfer.md` section 6). Names and paths are made up.
final class PhoneFilesTests: XCTestCase {
    /// Answers `/filesmetadata` as the phone's handlers do.
    final class Phone: @unchecked Sendable {
        private let lock = NSLock()
        var rows: [PhoneFiles_V1_FileMetadata] = []
        var batchSize = 2
        var sequence: Int64 = 40
        var permission = true
        var disabled = false
        /// Answers "start over" this many times in the middle of a list.
        var restarts = 0
        var changes: [PhoneFiles_V1_IncrementalFileSync] = []
        private(set) var asked: [String] = []
        var onConfiguration: (@Sendable (Data) async -> Void)?
        /// How long the answer to the question about the set-up takes, after the publication.
        var syncDelay = Duration.zero
        var silentAboutSetUp = false
        /// How long an answer to a question about changes takes.
        var delay = Duration.zero

        static func row(_ id: Int64, _ path: String, folder: Bool = false, kind: PhoneFiles_V1_FileType = .document, size: Int64 = 10) -> PhoneFiles_V1_FileMetadata {
            var row = PhoneFiles_V1_FileMetadata()
            row.id = id
            row.uri = "content://media/external/file/\(id)"
            row.name = (path as NSString).lastPathComponent
            row.path = path
            row.fileType = folder ? .none : kind
            row.size = folder ? 0 : size
            row.modifiedTime.seconds = 1_790_000_000 + id
            row.checksum = id * 7
            row.isDirectory = folder
            return row
        }

        func note(_ what: String) { lock.withLock { asked.append(what) } }
        var log: [String] { lock.withLock { asked } }

        func answer(_ type: DeviceResources.RequestType, _ payload: Data) async throws -> Data {
            switch type {
            case .sync:
                note("sync")
                var configuration = PhoneFiles_V1_FilesResponsePayload()
                configuration.fileConfiguration.capability = true
                configuration.fileConfiguration.permission = permission
                // The answer comes only once the configuration has been published and taken.
                if !silentAboutSetUp { await onConfiguration?(try configuration.serializedData()) }
                // As the real phone: the answer waits until every linked computer has the
                // publication, which for one that is switched off is a long wait.
                if syncDelay > .zero { try? await Task.sleep(for: syncDelay) }
                var response = PhoneFiles_V1_FilesSyncResponse()
                response.status = disabled ? .featureDisabled : .success
                return try response.serializedData()
            case .get:
                let request = try PhoneFiles_V1_FilesGetRequest(serializedBytes: payload)
                var response = PhoneFiles_V1_FilesGetResponse()
                response.requestID = request.requestID
                if disabled {
                    response.status = .featureDisabled
                    return try response.serializedData()
                }
                switch request.request {
                case .filesMetadataSyncRequest(let ask)? where ask.syncType == .fullSync:
                    guard permission else { response.status = .noPermission; break }
                    let start = Int(ask.batchContinuationToken.dropFirst(2)) ?? 0
                    note("full from \(start)\(ask.isUserInitiated ? ", rescan" : "")\(ask.supportsBatchedResponse ? "" : ", unbatched")")
                    if start > 0, restarts > 0 {
                        restarts -= 1
                        response.status = .batchRestartRequired
                        break
                    }
                    let end = min(rows.count, start + batchSize)
                    var full = PhoneFiles_V1_FullFileSyncPayload()
                    full.metadata = Array(rows[start..<end])
                    full.estimatedTotalItems = Int32(rows.count)
                    full.batchIndex = Int32(start / batchSize)
                    if end < rows.count {
                        full.hasMoreBatches_p = true
                        full.batchContinuationToken = "t-\(end)"
                        full.provisionalEndingSequenceNumber = sequence
                    } else {
                        full.endingSequenceNumber = sequence
                    }
                    response.filesMetadataSyncResponse.fullSync = full
                    response.status = .success
                case .filesMetadataSyncRequest(let ask)?:
                    note("changes since \(ask.seqNum)\(ask.isNoEngagementSync ? ", quietly" : "")")
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    guard ask.seqNum == sequence else { response.status = .syncFailed; break }
                    var incremental = PhoneFiles_V1_IncrementalFileSyncPayload()
                    incremental.syncOperation = changes
                    incremental.startingSequenceNumber = sequence
                    sequence += Int64(changes.count)
                    incremental.endingSequenceNumber = sequence
                    changes = []
                    response.filesMetadataSyncResponse.incrementalSync = incremental
                    response.status = .success
                case .thumbnailRequest(let ask)?:
                    note("preview \(ask.width)x\(ask.height)")
                    guard let row = rows.first(where: { $0.uri == ask.targetUri }) else { response.status = .notFound; break }
                    guard row.checksum == ask.targetChecksum else { response.status = .checksumMismatch; break }
                    response.thumbnailResponse.thumbnail = Data([0xFF, 0xD8, 0xFF, UInt8(truncatingIfNeeded: row.id)])
                    response.thumbnailResponse.status = .success
                    response.status = .success
                default:
                    response.status = .requestNotSet
                }
                return try response.serializedData()
            default:
                return Data()
            }
        }
    }

    actor Seen {
        var states: [PhoneFilesSync.State] = [], lists: [[PhoneFile]] = [], storage: [Int64] = []
        func add(_ update: PhoneFilesSync.Update) {
            switch update {
            case .state(let state): states.append(state)
            case .files(let files): lists.append(files.sorted { $0.id < $1.id })
            case .storage(let available, _): storage.append(available)
            }
        }
    }

    func make(_ phone: Phone) -> (PhoneFilesSync, Seen, Task<Void, Never>) {
        let sync = PhoneFilesSync { type, payload in try await phone.answer(type, payload) }
        phone.onConfiguration = { [weak sync] body in await sync?.published(body) }
        let seen = Seen()
        let watching = Task { for await update in sync.updates { await seen.add(update) } }
        return (sync, seen, watching)
    }

    let rows = [
        Phone.row(1, "/storage/emulated/0/Download", folder: true),
        Phone.row(2, "/storage/emulated/0/Download/report.pdf", size: 2_000),
        Phone.row(3, "/storage/emulated/0/DCIM/Camera/IMG_10.jpg", kind: .image, size: 3_000_000),
        Phone.row(4, "/storage/emulated/0/DCIM/Camera/IMG_9.jpg", kind: .image),
        Phone.row(5, "/storage/emulated/0/notes.txt"),
    ]

    func testTheWholeListComesInBatchesAndChangesFollow() async throws {
        let phone = Phone()
        phone.rows = rows
        let (sync, seen, watching) = make(phone)
        defer { watching.cancel() }
        await sync.load()
        let ready = await waitUntil {
            let lists = await seen.lists.count, last = await seen.states.last
            return lists == 1 && last == .ready
        }
        XCTAssertTrue(ready)
        XCTAssertEqual(phone.log, ["sync", "full from 0", "full from 2", "full from 4"], "the configuration first, then batch after batch from where the last ended")
        let states = await seen.states
        XCTAssertEqual(states, [.loading(received: 0, expected: nil), .loading(received: 2, expected: 5), .loading(received: 4, expected: 5), .loading(received: 5, expected: 5), .ready])
        let list = await seen.lists[0]
        XCTAssertEqual(list.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(list[2], PhoneFile(id: 3, uri: "content://media/external/file/3", name: "IMG_10.jpg", path: "/storage/emulated/0/DCIM/Camera/IMG_10.jpg",
                                          kind: .image, size: 3_000_000, modified: Date(timeIntervalSince1970: 1_790_000_003), checksum: 21))
        XCTAssertTrue(list[0].isDirectory)
        // Asked again without need: nothing goes out.
        await sync.load()
        XCTAssertEqual(phone.log.count, 4)

        // The phone says something changed: what changed is asked for from where the list stood.
        var made = PhoneFiles_V1_IncrementalFileSync(), gone = PhoneFiles_V1_IncrementalFileSync(), renamed = PhoneFiles_V1_IncrementalFileSync()
        made.create.metadata = Phone.row(6, "/storage/emulated/0/Download/new.zip")
        gone.delete.metadata = Phone.row(5, "/storage/emulated/0/notes.txt")
        renamed.update.metadata = Phone.row(2, "/storage/emulated/0/Download/final.pdf")
        phone.changes = [made, gone, renamed]
        var word = PhoneFiles_V1_FilesResponsePayload()
        word.fileSyncUpdate.syncType = .incrementalSync
        word.fileSyncUpdate.seqNum = 43
        await sync.published(try word.serializedData())
        let changed = await waitUntil { await seen.lists.count == 2 }
        XCTAssertTrue(changed)
        XCTAssertEqual(phone.log.last, "changes since 40, quietly")
        XCTAssertEqual(PhoneFileTree(files: [PhoneFile(id: 1, name: "a", path: "/storage/emulated/0/x/y/a")]).children(of: "/storage/emulated/0").first?.id,
                       PhoneFileTree(files: [PhoneFile(id: 9, name: "b", path: "/storage/emulated/0/x/b"), PhoneFile(id: 1, name: "a", path: "/storage/emulated/0/x/y/a")]).children(of: "/storage/emulated/0").first?.id,
                       "a folder without a row keeps its number from one list to the next")
        let after = await seen.lists[1]
        XCTAssertEqual(after.map(\.id), [1, 2, 3, 4, 6])
        XCTAssertEqual(after[1].name, "final.pdf")
        // And the next change from the new place.
        await sync.published(try word.serializedData())
        let askedAgain = await waitUntil { phone.log.last == "changes since 43, quietly" }
        XCTAssertTrue(askedAgain)
        let lists = await seen.lists.count
        XCTAssertEqual(lists, 2, "no changes, no new list")

        // Word of changes while the last asking is still under way: one more round, not two at once.
        phone.changes = [made]
        phone.delay = .milliseconds(120)
        await sync.published(try word.serializedData())
        await sync.published(try word.serializedData())
        await sync.published(try word.serializedData())
        let settled = await waitUntil(timeout: 3) { phone.log.filter { $0.hasPrefix("changes since") }.count == 4 }
        XCTAssertTrue(settled)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(phone.log.filter { $0.hasPrefix("changes since") }, ["changes since 40, quietly", "changes since 43, quietly", "changes since 43, quietly", "changes since 44, quietly"],
                       "one at a time, each from where the last ended")
        phone.delay = .zero

        // Free space, as the phone publishes it before its answers.
        var storage = PhoneFiles_V1_FilesResponsePayload()
        storage.storageInfo.availableSizeBytes = 5_000
        storage.storageInfo.totalSizeBytes = 9_000
        await sync.published(try storage.serializedData())
        let told = await waitUntil { await seen.storage == [5_000] }
        XCTAssertTrue(told)

        // A refresh by hand asks the phone to look over its storage first.
        await sync.load(again: true)
        XCTAssertTrue(phone.log.contains("full from 0, rescan"))
    }

    /// The phone no longer knows the place the list stood at: the whole list is had again,
    /// once. No answer at all is not taken for that.
    func testChangesThePhoneCannotGiveLeadToTheWholeListAgain() async throws {
        let phone = Phone()
        phone.rows = rows
        let (sync, seen, watching) = make(phone)
        defer { watching.cancel() }
        await sync.load()
        _ = await waitUntil { await seen.states.last == .ready }
        phone.sequence = 900
        var word = PhoneFiles_V1_FilesResponsePayload()
        word.fileSyncUpdate.syncType = .incrementalSync
        await sync.published(try word.serializedData())
        let again = await waitUntil { await seen.lists.count == 2 }
        XCTAssertTrue(again)
        XCTAssertEqual(phone.log.suffix(5), ["changes since 40, quietly", "sync", "full from 0", "full from 2", "full from 4"], "the whole list again, without making the phone look over its storage")
        let state = await sync.state
        XCTAssertEqual(state, .ready)
        await sync.published(try word.serializedData())
        let follows = await waitUntil { phone.log.last == "changes since 900, quietly" }
        XCTAssertTrue(follows, "and it goes on following from the new place")
    }

    /// Seen with the real phone on 2026-10-10: the set-up is published at once, the answer to
    /// the question about it does not come for a minute or more. The list does not wait for it.
    func testTheListDoesNotWaitForTheLateAnswerAboutTheSetUp() async throws {
        let phone = Phone()
        phone.rows = rows
        phone.syncDelay = .seconds(3)
        let (sync, seen, watching) = make(phone)
        defer { watching.cancel() }
        let began = ContinuousClock.now
        await sync.load()
        let state = await sync.state
        XCTAssertEqual(state, .ready)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(2), "the list is here long before the answer")
        let delivered = await waitUntil { await seen.lists.last?.count == 5 }
        XCTAssertTrue(delivered)

        // A phone that publishes nothing and answers late: asked for the list after a short wait.
        let quiet = Phone()
        quiet.rows = rows
        quiet.syncDelay = .seconds(3)
        quiet.silentAboutSetUp = true
        let (second, _, alsoWatching) = make(quiet)
        defer { alsoWatching.cancel() }
        await second.setConfigurationWait(.milliseconds(300))
        await second.load()
        let later = await second.state
        XCTAssertEqual(later, .ready)
        // Without the permission the publication says so, and the list is not asked for.
        let closed = Phone()
        closed.permission = false
        closed.syncDelay = .seconds(3)
        let (third, _, thirdWatching) = make(closed)
        defer { thirdWatching.cancel() }
        await third.load()
        let refused = await third.state
        XCTAssertEqual(refused, .needsPermission)
        XCTAssertEqual(closed.log, ["sync"])
    }

    func testAPhoneThatLosesItsPlaceIsAskedFromTheBeginning() async throws {
        let phone = Phone()
        phone.rows = rows
        phone.restarts = 1
        let (sync, seen, watching) = make(phone)
        defer { watching.cancel() }
        await sync.load()
        _ = await waitUntil { await seen.states.last == .ready }
        XCTAssertEqual(phone.log, ["sync", "full from 0", "full from 2", "full from 0", "full from 2", "full from 4"])
        let list = await seen.lists.last
        XCTAssertEqual(list?.count, 5, "nothing twice")
        // Losing its place every time ends the asking.
        let stubborn = Phone()
        stubborn.rows = rows
        stubborn.restarts = 99
        let (second, others, alsoWatching) = make(stubborn)
        defer { alsoWatching.cancel() }
        await second.load()
        _ = await waitUntil { if case .failed = await others.states.last { return true } else { return false } }
        XCTAssertEqual(stubborn.log.filter { $0 == "full from 0" }.count, 3)
    }

    func testWithoutThePermissionNothingIsListedUntilItIsGiven() async throws {
        let phone = Phone()
        phone.rows = rows
        phone.permission = false
        let (sync, seen, watching) = make(phone)
        defer { watching.cancel() }
        await sync.load()
        let state = await sync.state
        XCTAssertEqual(state, .needsPermission)
        XCTAssertEqual(phone.log, ["sync"], "the configuration said so: the list is not even asked for")
        // Given on the phone: its new configuration starts the listing by itself.
        phone.permission = true
        var configuration = PhoneFiles_V1_FilesResponsePayload()
        configuration.fileConfiguration.permission = true
        await sync.published(try configuration.serializedData())
        let ready = await waitUntil { await seen.states.last == .ready }
        XCTAssertTrue(ready)

        // A phone that does not offer the feature, and one that does not know the resource.
        let without = Phone()
        without.disabled = true
        let (second, _, alsoWatching) = make(without)
        defer { alsoWatching.cancel() }
        await second.load()
        let refused = await second.state
        XCTAssertEqual(refused, .failed("This phone does not offer its files to a computer."))
        let unknown = PhoneFilesSync { _, _ in throw DeviceResources.ResourceError.unsupportedResource("/filesmetadata") }
        await unknown.load()
        let unsupported = await unknown.state
        XCTAssertEqual(unsupported, .failed("This phone does not offer its files to a computer."))
        // Asking again after a failure is allowed.
        without.disabled = false
        await second.load()
        let later = await second.state
        XCTAssertEqual(later, .ready)
    }

    func testAPreviewIsAskedForWithTheFilesOwnMark() async throws {
        let phone = Phone()
        phone.rows = rows
        let (sync, seen, watching) = make(phone)
        defer { watching.cancel() }
        await sync.load()
        _ = await waitUntil { await seen.states.last == .ready }
        let listed = await seen.lists.last ?? []
        let picture = try XCTUnwrap(listed.first { $0.id == 3 })
        XCTAssertTrue(picture.hasPreview)
        let bytes = try await sync.thumbnail(of: picture, side: 128)
        XCTAssertEqual(bytes, Data([0xFF, 0xD8, 0xFF, 3]))
        XCTAssertEqual(phone.log.last, "preview 128x128")
        // The file changed on the phone since it was listed: the phone says so.
        var stale = picture
        stale.checksum = 1
        do {
            _ = try await sync.thumbnail(of: stale)
            XCTFail("a preview for a mark the phone does not know")
        } catch {
            XCTAssertEqual(error as? PhoneFilesSync.FilesError, .refused(4))
        }
    }

    func testTheFlatListBecomesFolders() {
        let files = rows.map(PhoneFile.init) + [PhoneFile(PhoneFilesTests.Phone.row(9, "/storage/emulated/0/Android/data/app/cache/x.bin"))]
        let tree = PhoneFileTree(files: files)
        XCTAssertEqual(tree.root, "/storage/emulated/0")
        XCTAssertEqual(tree.fileCount, 5)
        XCTAssertEqual(tree.children(of: tree.root).map(\.name), ["Android", "DCIM", "Download", "notes.txt"], "folders first, then files, each by name")
        XCTAssertTrue(tree.children(of: tree.root)[1].isDirectory, "a folder the phone listed no row for is there all the same")
        XCTAssertLessThan(tree.children(of: tree.root)[1].id, 0)
        XCTAssertEqual(tree.children(of: tree.root)[2].id, 1, "a folder with a row keeps it")
        XCTAssertEqual(tree.children(of: "/storage/emulated/0/DCIM").map(\.name), ["Camera"])
        XCTAssertEqual(tree.children(of: "/storage/emulated/0/DCIM/Camera").map(\.name), ["IMG_9.jpg", "IMG_10.jpg"], "numbers in names count as numbers")
        XCTAssertEqual(tree.children(of: "/storage/emulated/0/Android/data/app/cache").map(\.name), ["x.bin"])
        XCTAssertEqual(tree.children(of: "/nowhere"), [])
        XCTAssertEqual(tree.trail(to: "/storage/emulated/0/DCIM/Camera"), ["/storage/emulated/0", "/storage/emulated/0/DCIM", "/storage/emulated/0/DCIM/Camera"])
        XCTAssertEqual(tree.trail(to: tree.root), [tree.root])
        XCTAssertEqual(tree.search("img").map(\.name), ["IMG_9.jpg", "IMG_10.jpg"])
        XCTAssertEqual(tree.search("  "), [])
        // A card beside the built-in storage: the root is what holds both.
        let both = PhoneFileTree(files: files + [PhoneFile(id: 20, name: "song.mp3", path: "/storage/1A2B-3C4D/Music/song.mp3")])
        XCTAssertEqual(both.root, "/storage")
        XCTAssertEqual(both.children(of: "/storage").map(\.name), ["1A2B-3C4D", "emulated"])
        XCTAssertEqual(PhoneFileTree().root, PhoneFileTree.usualRoot)
        XCTAssertEqual(PhoneFileTree.parent(of: "/a"), "/")
    }
}
