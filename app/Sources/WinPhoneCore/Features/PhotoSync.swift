import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The fields every APP request to the phone carries about its sender.
public struct AppSender: Sendable {
    public var displayName: String
    public var appVersion: String
    public var installationId: String

    public init(displayName: String, appVersion: String = ClientProfile.phoneLink.appVersion, installationId: String) {
        self.displayName = displayName
        self.appVersion = appVersion
        self.installationId = installationId
    }

    /// The common part of a request value set, as Phone Link's client library fills it in.
    public func request(contentType: String, userInitiated: Bool = false) -> ValueSet {
        ValueSet([
            "contentType": .string(contentType),
            "contractVersion": .double(ValueSet.contractVersion),
            "correlationVector": .string(TraceContext.randomHex(bytes: 8)),
            "isuserinitiated": .bool(userInitiated),
            "ignoreResponse": .bool(false),
            "transportType": .int32(0),
            "displayName": .string(displayName),
            "appVersion": .string(appVersion),
            "installationId": .string(installationId),
        ])
    }
}

/// A photo on the phone, as listed by the media sync.
public struct PhonePhoto: Equatable, Sendable, Identifiable, Codable {
    /// The phone's media ID; the key for every request.
    public var id: Int64
    public var name: String
    public var mimeType: String
    /// Pixel size as stored, before applying `orientation`.
    public var width: Int
    public var height: Int
    /// Size of the original file on the phone.
    public var fileSize: Int64
    public var taken: Date
    public var modified: Date
    /// Clockwise rotation in degrees. Thumbnails already have it applied.
    public var orientation: Int
    /// Changes when the file is renamed, resized or touched.
    public var checksum: Int64
    /// A JPEG, already upright. Nil until loaded.
    public var thumbnail: Data?
    /// The phone was asked for a thumbnail and had none: the file is damaged, empty or gone.
    /// Such entries are kept out of the grid.
    public var thumbnailUnavailable = false

    public init(id: Int64, name: String, mimeType: String = "image/jpeg", width: Int = 0, height: Int = 0, fileSize: Int64 = 0,
                taken: Date = Date(), modified: Date = Date(), orientation: Int = 0, checksum: Int64 = 0, thumbnail: Data? = nil) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.taken = taken
        self.modified = modified
        self.orientation = orientation
        self.checksum = checksum
        self.thumbnail = thumbnail
    }

    /// The size as it should be laid out, with a quarter turn swapping the sides.
    public var displaySize: (width: Int, height: Int) {
        orientation == 90 || orientation == 270 ? (height, width) : (width, height)
    }

    /// The phone sends a reduced JPEG instead of the original above this file size.
    public static let originalByteLimit: Int64 = 716_800
    public var arrivesReduced: Bool { fileSize > PhonePhoto.originalByteLimit }
}

/// An image fetched from the phone.
public struct FetchedPhoto: Equatable, Sendable {
    public var data: Data
    /// File extension chosen from the leading bytes, because a large HEIC arrives as JPEG
    /// under its original name.
    public var fileExtension: String

    public init(data: Data, fileExtension: String? = nil) {
        self.data = data
        self.fileExtension = fileExtension ?? FetchedPhoto.fileExtension(for: data)
    }

    public static func fileExtension(for data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if head.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if head.count >= 12, Array(head[4..<8]) == Array("ftyp".utf8) { return "heic" }
        if head.count >= 12, head.starts(with: Array("RIFF".utf8)), Array(head[8..<12]) == Array("WEBP".utf8) { return "webp" }
        return "jpg"
    }
}

/// The phone's recent photos.
///
/// The phone keeps a snapshot of its newest images and pushes it on `/legacy/phonecontent` with
/// content type `mediaInfo`: first a list of every ID with its checksum, which this client
/// answers by naming the items it wants, then the items as parallel arrays with thumbnails laid
/// end to end. Thumbnails and images that were not sent are pulled on `/media/v1`.
public actor PhotoSync {
    public static let route = "/media/v1"
    public static let contentType = "mediaInfo"

    public enum PhotoError: Error, Equatable {
        /// The phone has not been given access to photos.
        case needsPermission
        case failed(ScenarioResult?)
        /// The phone could not read the image.
        case notFound
    }

    public struct Limits: Sendable {
        /// How many of the newest photos to keep. The phone's snapshot holds up to 2000.
        public var window = 300
        /// Thumbnails asked for along with the list.
        public var initialThumbnails = 24
        /// IDs per thumbnail request; Phone Link sends 16.
        public var thumbnailBatch = 16
        public init() {}
    }

    private var messenger: PeerMessenger?
    private let sender: AppSender
    private let limits: Limits
    private let cache: BlobCache?
    private var saving: Task<Void, Never>?
    private var items: [Int64: PhonePhoto] = [:]
    private var loadingThumbnails: Set<Int64> = []
    public private(set) var sequenceNumber: Int64 = -1
    public private(set) var hasFullAccess: Bool?
    private let continuation: AsyncStream<[PhonePhoto]>.Continuation

    /// The list, newest first, each time it changes.
    public nonisolated let updates: AsyncStream<[PhonePhoto]>

    struct Snapshot: Codable {
        var sequenceNumber: Int64
        var photos: [PhonePhoto]
    }

    /// - Parameters:
    ///   - messenger: the connection to the phone, or nil until one is attached.
    ///   - cache: where to keep the list and thumbnails between launches.
    public init(messenger: PeerMessenger? = nil, sender: AppSender, limits: Limits = Limits(), cache: BlobCache? = nil) {
        self.messenger = messenger
        self.sender = sender
        self.limits = limits
        self.cache = cache
        (updates, continuation) = AsyncStream.makeStream(of: [PhonePhoto].self, bufferingPolicy: .bufferingNewest(4))
        if let data = cache?.load(), let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: data) {
            sequenceNumber = snapshot.sequenceNumber
            items = Dictionary(snapshot.photos.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        }
    }

    /// Writes the cache a little after the last change, so a burst of thumbnails is one write.
    private func scheduleSave() {
        guard let cache, saving == nil else { return }
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.saveNow(to: cache)
        }
    }

    private func saveNow(to cache: BlobCache) {
        saving = nil
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        if let data = try? encoder.encode(Snapshot(sequenceNumber: sequenceNumber, photos: Array(items.values))) { cache.save(data) }
    }

    /// Forgets everything, for a sign-out or when the phone's numbering started over.
    public func reset() {
        items = [:]
        sequenceNumber = -1
        cache?.clear()
        publish()
    }

    /// A phone number below ours means its list was reset: discard ours.
    @discardableResult
    public func reconcile(phoneNumber: Int64?, sent: Int64? = nil) -> Bool {
        // Compared with what the phone was told, not with what a push may have added since.
        let ours = sent ?? sequenceNumber
        guard let phoneNumber, ours >= 0, phoneNumber < ours else { return false }
        reset()
        return true
    }

    /// Photos known so far, newest first.
    public var photos: [PhonePhoto] {
        items.values.sorted { ($0.taken, $0.id) > ($1.taken, $1.id) }
    }

    private func publish() {
        continuation.yield(photos)
        scheduleSave()
    }

    /// Uses a new connection to the phone. The list held is kept, so after a reconnect the
    /// phone only sends what changed.
    public func attach(_ messenger: PeerMessenger) {
        self.messenger = messenger
        loadingThumbnails = []
    }

    /// Sends the current list again, for a new listener.
    public func republish() { publish() }

    // MARK: Pushes from the phone

    /// Applies a `mediaInfo` push and returns the reply value set.
    public func apply(_ values: ValueSet) -> ValueSet {
        if values.entries["metadata"] != nil { return answerMetadata(values) }
        guard merge(values) else { return ValueSet(["result": .int32(Int32(ScenarioResult.failure.rawValue))]) }
        // Stored only after the items are in, so a failure in between cannot lose them.
        if let number = values.int("sequenceNumber") { sequenceNumber = Int64(number) }
        publish()
        return ValueSet(["result": .int32(0)])
    }

    /// The first round of a full sync: the phone lists every ID with its checksum, and the
    /// answer names the items wanted. An answer without a positive `itemCount` tells the phone
    /// this client is up to date.
    private func answerMetadata(_ values: ValueSet) -> ValueSet {
        let ids = values.int64s("mediaIds") ?? []
        let checksums = values.int64s("checksums") ?? []
        // The list is newest first; keep the window and forget everything else.
        let kept = Array(ids.prefix(limits.window))
        let keptSet = Set(kept)
        let before = items.count
        items = items.filter { keptSet.contains($0.key) }
        var wanted: [Int64] = []
        for (index, id) in kept.enumerated() {
            let checksum = index < checksums.count ? checksums[index] : 0
            if items[id]?.checksum != checksum || items[id] == nil { wanted.append(id) }
        }
        if wanted.isEmpty {
            if let number = values.int("sequenceNumber") { sequenceNumber = Int64(number) }
            if items.count != before { publish() }
        }
        var reply = ValueSet([
            "result": .int32(0),
            "itemCount": .int32(Int32(wanted.count)),
            "mediaIds": .int64Array(wanted),
            "mediaRequestedIds": .int64Array(Array(wanted.prefix(limits.initialThumbnails))),
            "contentType": .string(PhotoSync.contentType),
            "contractVersion": .double(ValueSet.contractVersion),
        ])
        if let correlation = values.string("correlationVector") { reply["correlationVector"] = .string(correlation) }
        return reply
    }

    /// Merges a content message or a thumbnails reply: parallel arrays, one entry per item.
    /// Returns false when the arrays do not fit together.
    private func merge(_ values: ValueSet) -> Bool {
        guard let ids = values.int64s("mediaIds") else { return false }
        let count = ids.count
        func strings(_ key: String) -> [String] { values.strings(key) ?? [] }
        func longs(_ key: String) -> [Int64] { values.int64s(key) ?? [] }
        let names = strings("mediaNames"), mimeTypes = strings("mediaMimeTypes"), orientations = strings("mediaOrientations")
        let times = longs("mediaTimes"), taken = longs("mediaTakenTimes"), sizes = longs("mediaSizes")
        let widths = longs("mediaWidths"), heights = longs("mediaHeights"), checksums = longs("checksums")
        let actions = values.int32s("mediaActions") ?? []
        let thumbnailSizes = longs("mediaThumbnailSizes")
        var thumbnails: [Data] = []
        if let blob = values.bytes("mediaThumbnails"), !thumbnailSizes.isEmpty {
            guard thumbnailSizes.count == count, let pieces = ValueSet.split(blob, sizes: thumbnailSizes) else { return false }
            thumbnails = pieces
        }
        for index in 0..<count {
            let id = ids[index]
            if index < actions.count, actions[index] == 2 {
                items.removeValue(forKey: id)
                continue
            }
            var photo = items[id] ?? PhonePhoto(id: id, name: "")
            // A thumbnails reply repeats the metadata; a deleted-item stub has none.
            if index < names.count { photo.name = names[index] }
            if index < mimeTypes.count { photo.mimeType = mimeTypes[index] }
            if index < widths.count { photo.width = Int(widths[index]) }
            if index < heights.count { photo.height = Int(heights[index]) }
            if index < sizes.count { photo.fileSize = sizes[index] }
            if index < times.count { photo.modified = Date(timeIntervalSince1970: TimeInterval(times[index]) / 1000) }
            if index < taken.count { photo.taken = Date(timeIntervalSince1970: TimeInterval(taken[index]) / 1000) }
            if index < orientations.count { photo.orientation = Int(orientations[index]) ?? 0 }
            if index < checksums.count {
                // A changed file invalidates the thumbnail we hold.
                if photo.checksum != checksums[index], index >= thumbnails.count || thumbnails[index].isEmpty { photo.thumbnail = nil }
                photo.checksum = checksums[index]
            }
            if index < thumbnails.count, !thumbnails[index].isEmpty {
                photo.thumbnail = thumbnails[index]
                photo.thumbnailUnavailable = false
            }
            items[id] = photo
        }
        // Keep the newest window only.
        if items.count > limits.window {
            for extra in photos.dropFirst(limits.window) { items.removeValue(forKey: extra.id) }
        }
        return true
    }

    // MARK: Requests

    /// Asks the phone for a full sync of its photo list. The list arrives as pushes, which
    /// `apply` handles; this returns once the phone reports the sync finished.
    public func refresh() async throws {
        // A manual refresh gives entries without a thumbnail another chance.
        for id in items.keys where items[id]?.thumbnailUnavailable == true { items[id]?.thumbnailUnavailable = false }
        let response = try await send(sender.request(contentType: PhotoSync.contentType, userInitiated: true))
        if let full = response.bool("photos_full") { hasFullAccess = full }
    }

    func deleteRequest(ids: [Int64]) -> ValueSet {
        // No content type: Windows sends none, and `requestType` alone selects deletion.
        var request = sender.request(contentType: "", userInitiated: true)
        request.entries.removeValue(forKey: "contentType")
        request["requestType"] = .int32(0)
        request["mediaIds"] = .int64Array(ids)
        // The phone deletes an item only if it still is the file this client knows.
        request["checksums"] = .int64Array(ids.map { items[$0]?.checksum ?? 0 })
        return request
    }

    /// Deletes photos from the phone itself. This cannot be undone from here.
    /// - Returns: the IDs the phone reports as deleted. On a partial failure the phone names
    ///   both lists; those it did delete are removed here as well.
    @discardableResult
    public func delete(ids: [Int64]) async throws -> [Int64] {
        let ids = Array(Set(ids)).filter { items[$0] != nil }.sorted()
        guard !ids.isEmpty else { return [] }
        guard let messenger else { throw PhotoError.failed(nil) }
        let envelope = try await messenger.appRequest(route: PhotoSync.route, payload: deleteRequest(ids: ids).serialized(), timeout: .seconds(60))
        guard let response = try? ValueSet(serialized: envelope.payload) else { throw PhotoError.failed(nil) }
        let result = response.int("result").flatMap(ScenarioResult.init)
        if result == .needsPermission { throw PhotoError.needsPermission }
        // Only IDs that were asked for count, whatever the reply lists.
        let deleted = (response.int64s("mediaSuccessfullyDeletedIds") ?? []).filter(ids.contains)
        for id in deleted { items.removeValue(forKey: id) }
        if !deleted.isEmpty { publish() }
        guard result == .success else { throw PhotoError.failed(result) }
        return deleted
    }

    /// Loads thumbnails for photos that have none, in batches. IDs already being loaded or
    /// already loaded are skipped.
    public func loadThumbnails(for ids: [Int64]) async throws {
        let needed = ids.filter { items[$0] != nil && items[$0]?.thumbnail == nil && !loadingThumbnails.contains($0) }
        guard !needed.isEmpty else { return }
        loadingThumbnails.formUnion(needed)
        defer { loadingThumbnails.subtract(needed) }
        for start in stride(from: 0, to: needed.count, by: limits.thumbnailBatch) {
            let batch = Array(needed[start..<min(start + limits.thumbnailBatch, needed.count)])
            var request = sender.request(contentType: "thumbnails")
            request["mediaIds"] = .int64Array(batch)
            let response = try await send(request)
            guard merge(response) else { continue }
            // The phone answers every ID it finds; one that still has no thumbnail never will.
            for id in batch where items[id] != nil && items[id]?.thumbnail == nil {
                guard let photo = items[id] else { continue }
                let kind = "type \(photo.mimeType.isEmpty ? "unknown" : photo.mimeType), \(photo.fileSize) bytes, \(photo.width)x\(photo.height)"
                // The phone's thumbnailer fails on some files it can still send. Fetch the image
                // and make the thumbnail here.
                let image: FetchedPhoto
                do {
                    image = try await fetchImage(id: id)
                } catch let error as PhotoError where error == .notFound || error == .failed(.failure) || error == .failed(.databaseOperationFailed) {
                    // The phone itself says it cannot produce this one.
                    items[id]?.thumbnailUnavailable = true
                    diag("photos", "no thumbnail and no image for one item (\(kind)); hidden")
                    continue
                } catch {
                    // A lost connection or a timeout says nothing about the photo: leave it
                    // to be asked for again.
                    publish()
                    throw error
                }
                if let made = PhotoSync.makeThumbnail(from: image.data) {
                    items[id]?.thumbnail = made
                    diag("photos", "the phone had no thumbnail for one item (\(kind)); made one from the image")
                } else {
                    items[id]?.thumbnailUnavailable = true
                    diag("photos", "no thumbnail and an unreadable image for one item (\(kind)); hidden")
                }
            }
            publish()
        }
    }

    /// Fetches one image. Above 700 KiB the phone sends a reduced JPEG, not the original.
    public func fetchImage(id: Int64) async throws -> FetchedPhoto {
        var request = sender.request(contentType: "photos", userInitiated: true)
        request["mediaIds"] = .int64Array([id])
        let response = try await send(request)
        // In this reply `mediaSizes` gives the length of each image inside `content`.
        guard let ids = response.int64s("mediaIds"), let sizes = response.int64s("mediaSizes"), ids.count == sizes.count,
              let content = response.bytes("content"), let pieces = ValueSet.split(content, sizes: sizes),
              let index = ids.firstIndex(of: id), !pieces[index].isEmpty else { throw PhotoError.notFound }
        return FetchedPhoto(data: pieces[index], fileExtension: FetchedPhoto.fileExtension(for: pieces[index]))
    }

    /// Makes an upright JPEG thumbnail from image bytes, about the size the phone's own are.
    /// - Parameter commonFormatsOnly: for bytes chosen by someone else, such as a picture
    ///   message: decode only the everyday formats, not everything the system can read.
    public static func makeThumbnail(from data: Data, maxPixelSize: Int = 512, quality: Double = 0.85, commonFormatsOnly: Bool = false) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if commonFormatsOnly {
            let common: Set<String> = ["public.jpeg", "public.png", "com.compuserve.gif", "public.heic", "public.heif", "org.webmproject.webp",
                                       "public.tiff", "com.microsoft.bmp"]
            guard let type = CGImageSourceGetType(source) as String?, common.contains(type) else { return nil }
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    private func send(_ request: ValueSet) async throws -> ValueSet {
        guard let messenger else { throw PhotoError.failed(nil) }
        // A list request is answered only after the whole list has been pushed.
        let envelope = try await messenger.appRequest(route: PhotoSync.route, payload: request.serialized(), timeout: .seconds(300))
        guard let response = try? ValueSet(serialized: envelope.payload) else { throw PhotoError.failed(nil) }
        let result = response.int("result").flatMap(ScenarioResult.init)
        if result == .needsPermission { throw PhotoError.needsPermission }
        guard let result, result.countsAsSuccess else { throw PhotoError.failed(result) }
        if let full = response.bool("photos_full") { hasFullAccess = full }
        return response
    }
}
