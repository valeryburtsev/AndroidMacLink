import Foundation
import SwiftProtobuf

// The phone's shared storage as a list to browse (`protocol/specs/file-transfer.md`, section 6):
// what Windows shows as the phone in File Explorer. The phone keeps an index of every file and
// folder; this side asks for all of it once, in batches, and afterwards for what changed.
// Names, sizes, dates and small previews travel over the relay. A file's content does not.

/// One file or folder on the phone.
public struct PhoneFile: Equatable, Sendable, Identifiable {
    public enum Kind: Int, Sendable {
        case other = 0, image = 1, video = 2, audio = 3, document = 4, playlist = 5, subtitle = 6, none = 7
    }

    /// The phone's row number for it; negative for a folder that is only known from the
    /// paths of what lies in it.
    public var id: Int64
    /// How the phone names it in requests; empty for a folder without a row of its own.
    public var uri: String
    public var name: String
    /// The whole path on the phone, such as `/storage/emulated/0/Download/a.pdf`.
    public var path: String
    public var kind: Kind
    public var size: Int64
    public var modified: Date
    /// The phone's mark of this version of the file, sent back when asking for its preview.
    public var checksum: Int64
    public var isDirectory: Bool

    public init(id: Int64, uri: String = "", name: String, path: String, kind: Kind = .other, size: Int64 = 0, modified: Date = .distantPast,
                checksum: Int64 = 0, isDirectory: Bool = false) {
        self.id = id
        self.uri = uri
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        self.checksum = checksum
        self.isDirectory = isDirectory
    }

    init(_ metadata: PhoneFiles_V1_FileMetadata) {
        // A name is the last part of the path where the phone sent none.
        let name = metadata.name.isEmpty ? (metadata.path as NSString).lastPathComponent : metadata.name
        self.init(id: metadata.id, uri: metadata.uri, name: name, path: metadata.path, kind: Kind(rawValue: metadata.fileType.rawValue) ?? .other,
                  size: metadata.size, modified: metadata.hasModifiedTime ? Date(timeIntervalSince1970: TimeInterval(metadata.modifiedTime.seconds)) : .distantPast,
                  checksum: metadata.checksum, isDirectory: metadata.isDirectory)
    }

    /// The folder it lies in.
    public var parentPath: String { PhoneFileTree.parent(of: path) }
    /// Whether the phone can make a small picture of it.
    public var hasPreview: Bool { !isDirectory && !uri.isEmpty && (kind == .image || kind == .video || kind == .audio) }
}

/// The phone's flat list of files as folders with their contents.
public struct PhoneFileTree: Sendable {
    /// Where an Android phone keeps what its user can see.
    public static let usualRoot = "/storage/emulated/0"

    /// The folder everything lies under.
    public private(set) var root: String
    private var contents: [String: [PhoneFile]] = [:]
    public private(set) var fileCount = 0

    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    public init(files: [PhoneFile] = []) {
        let usable = files.filter { $0.path.hasPrefix("/") && $0.path.count > 1 }
        root = PhoneFileTree.commonFolder(of: usable)
        var known = Set(usable.filter(\.isDirectory).map(\.path))
        for file in usable where file.path != root {
            contents[file.parentPath, default: []].append(file)
            if !file.isDirectory { fileCount += 1 }
            // Folders the phone listed no row for (hidden ones it leaves out, or a list cut
            // short) still have to be there to be walked through.
            var folder = file.parentPath
            while folder != root, folder.count > root.count, known.insert(folder).inserted {
                contents[PhoneFileTree.parent(of: folder), default: []].append(
                    PhoneFile(id: PhoneFileTree.madeUpId(for: folder), name: (folder as NSString).lastPathComponent, path: folder, isDirectory: true))
                folder = PhoneFileTree.parent(of: folder)
            }
        }
        for key in contents.keys {
            contents[key]?.sort { first, second in
                if first.isDirectory != second.isDirectory { return first.isDirectory }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
        }
    }

    /// A number for a folder that has no row on the phone: negative, and the same for the
    /// same path every time the list is turned into folders, so a selection stays put.
    static func madeUpId(for path: String) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return -Int64(hash & 0x3fff_ffff_ffff_ffff) - 1
    }

    /// The usual root where everything lies under it, else the deepest folder that holds all.
    static func commonFolder(of files: [PhoneFile]) -> String {
        guard let first = files.first else { return usualRoot }
        if files.allSatisfy({ $0.path.hasPrefix(usualRoot + "/") || $0.path == usualRoot }) { return usualRoot }
        var parts = parent(of: first.path).split(separator: "/").map(String.init)
        for file in files.dropFirst() {
            let other = parent(of: file.path).split(separator: "/").map(String.init)
            var same = 0
            while same < parts.count, same < other.count, parts[same] == other[same] { same += 1 }
            parts = Array(parts.prefix(same))
            if parts.isEmpty { break }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// What lies in a folder: folders first, then files, each by name.
    public func children(of folder: String) -> [PhoneFile] { contents[folder] ?? [] }

    /// The folders from the root down to this one, for a path bar. The root comes first.
    public func trail(to folder: String) -> [String] {
        guard folder.hasPrefix(root), folder != root else { return [root] }
        var trail = [folder]
        var current = folder
        while current != root, current.count > root.count {
            current = PhoneFileTree.parent(of: current)
            trail.insert(current, at: 0)
        }
        return trail
    }

    /// Everything whose name contains the words, anywhere on the phone.
    public func search(_ words: String, limit: Int = 500) -> [PhoneFile] {
        let query = words.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        var found: [PhoneFile] = []
        for (_, files) in contents {
            for file in files where file.name.localizedCaseInsensitiveContains(query) {
                found.append(file)
                if found.count >= limit { break }
            }
            if found.count >= limit { break }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Keeps the list of the phone's files: asks for all of it when the user first wants to see
/// it, then follows the phone's word that something changed.
public actor PhoneFilesSync {
    public static let path = "/filesmetadata"

    public enum State: Equatable, Sendable {
        /// Nothing has been asked for yet.
        case idle
        case loading(received: Int, expected: Int?)
        case ready
        /// The phone's user has not let Link to Windows see all files.
        case needsPermission
        case failed(String)
    }

    public enum Update: Sendable {
        case state(State)
        /// The whole list as it now is.
        case files([PhoneFile])
        case storage(available: Int64, total: Int64)
    }

    public enum FilesError: Error, Equatable {
        /// The phone's own word for what went wrong, by number.
        case refused(Int)
        case malformedResponse
    }

    public typealias Request = @Sendable (_ type: DeviceResources.RequestType, _ payload: Data) async throws -> Data

    private let request: Request
    private let continuation: AsyncStream<Update>.Continuation
    public nonisolated let updates: AsyncStream<Update>
    private var files: [Int64: PhoneFile] = [:]
    private var sequence: Int64?
    public private(set) var state = State.idle
    /// What the phone last said about its all-files permission; nil before it said anything.
    private var permitted: Bool?
    private var following = false

    public init(request: @escaping Request) {
        self.request = request
        (updates, continuation) = AsyncStream.makeStream(of: Update.self, bufferingPolicy: .unbounded)
    }

    /// As it runs in the app: requests go to the phone's resource, and what the phone
    /// publishes about its files is followed.
    public init(resources: DeviceResources, publisher: ContextPublisher) async {
        self.init { type, payload in
            // Windows names the resource the old way too, beside the path.
            try await resources.request(PhoneFilesSync.path, type: type, payload: payload, timeout: .seconds(90), legacyType: .filesMetadata)
        }
        await publisher.subscribe(.phoneFiles) { [weak self] publication in await self?.published(publication.body) }
        // A new session knows nothing yet: whoever listens starts from there.
        continuation.yield(.state(.idle))
    }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        continuation.yield(.state(new))
    }

    /// Asks for the whole list, unless it is here or on its way.
    /// - Parameter again: ask anew although the list is here, and have the phone look over
    ///   its storage first.
    public func load(again: Bool = false) async {
        await load(again: again, rescan: again)
    }

    /// One listing at a time, whoever asks.
    private var listing = false

    private func load(again: Bool, rescan: Bool) async {
        guard !listing else { return }
        if state == .ready, !again { return }
        listing = true
        defer { listing = false }
        set(.loading(received: 0, expected: nil))
        do {
            // The phone is asked how it is set up, and says so by publishing it, the
            // permission among it. Its answer to the question itself comes only once that
            // publication has reached every computer linked to the phone, and for one that is
            // switched off it waits a long time (seen on 2026-10-10: the publication after
            // 0.4 s, no answer within a minute). So the publication is what is waited for;
            // the answer is taken when it comes.
            let began = ContinuousClock.now
            let heardBefore = configurationsHeard
            syncOutcome = nil
            var sync = PhoneFiles_V1_FilesSyncRequest()
            sync.configSyncRequest = PhoneFiles_V1_FilesConfigurationSyncRequest()
            let question = try sync.serializedData()
            diag("files", "asking the phone how its files are set up")
            Task { await self.askConfiguration(question) }
            while configurationsHeard == heardBefore, syncOutcome == nil, ContinuousClock.now - began < configurationWait {
                try? await Task.sleep(for: .milliseconds(50))
            }
            switch syncOutcome {
            case .failure(let error)?: throw error
            case .success(let status)? where status == .featureDisabled: throw FilesError.refused(status.rawValue)
            default: break
            }
            diag("files", "\(configurationsHeard == heardBefore ? "no word on the set-up" : "set-up published, permission \(permitted == true ? "given" : "not given")") after \(began.duration(to: .now).components.seconds) s; \(syncOutcome == nil ? "the answer still to come" : "answered")")
            if permitted == false { return set(.needsPermission) }
            try await loadAll(rescan: rescan)
        } catch FilesError.refused(let status) {
            diag("files", "the phone refused the file list: status \(status)")
            set(status == PhoneFiles_V1_FilesResponseStatus.noPermission.rawValue ? .needsPermission
                : .failed(status == PhoneFiles_V1_FilesResponseStatus.featureDisabled.rawValue ? "This phone does not offer its files to a computer."
                    : "The phone could not list its files (\(status))."))
        } catch DeviceResources.ResourceError.unsupportedResource {
            set(.failed("This phone does not offer its files to a computer."))
        } catch {
            diag("files", "the file list could not be had: \(type(of: error))")
            set(.failed("The phone did not answer. Check that it is connected and try again."))
        }
    }

    /// How long the phone's word on its set-up is waited for before the list is asked for anyway.
    var configurationWait = Duration.seconds(8)
    private var configurationsHeard = 0
    private var syncOutcome: Result<PhoneFiles_V1_FilesResponseStatus, Error>?

    /// Asks the question and keeps its answer for whenever it comes.
    private func askConfiguration(_ question: Data) async {
        let began = ContinuousClock.now
        do {
            let answer = try PhoneFiles_V1_FilesSyncResponse(serializedBytes: try await request(.sync, question))
            syncOutcome = .success(answer.status)
            diag("files", "the question about the set-up was answered with status \(answer.status.rawValue) after \(began.duration(to: .now).components.seconds) s")
            // A phone that says so late: what was started in the meantime ends here.
            if answer.status == .featureDisabled, !storageHere { set(.failed("This phone does not offer its files to a computer.")) }
        } catch let error as DeviceResources.ResourceError {
            syncOutcome = .failure(error)
        } catch {
            // No answer in the time allowed is no reason by itself: the list may come all the same.
            diag("files", "the question about the set-up got no answer: \(type(of: error))")
        }
    }

    /// Whether a list has been had on this session.
    private var storageHere: Bool { following }

    func setConfigurationWait(_ wait: Duration) { configurationWait = wait }

    /// The whole list in batches: each answer names where the next begins.
    private func loadAll(rescan: Bool) async throws {
        var restarts = 0
        restart: while true {
            var gathered: [Int64: PhoneFile] = [:]
            var token = ""
            var batches = 0
            while true {
                var ask = PhoneFiles_V1_GetFilesMetadataSyncRequest()
                ask.syncType = .fullSync
                ask.supportsBatchedResponse = true
                ask.batchContinuationToken = token
                if rescan, batches == 0 { ask.isUserInitiated = true }
                let response: PhoneFiles_V1_FilesGetResponse
                let asked = ContinuousClock.now
                do {
                    response = try await get(.filesMetadataSyncRequest(ask))
                    if batches == 0 { diag("files", "first part of the list after \(asked.duration(to: .now).components.seconds) s") }
                } catch FilesError.refused(let status) where status == PhoneFiles_V1_FilesResponseStatus.batchRestartRequired.rawValue && restarts < 2 {
                    // The phone lost its place: from the beginning, a few times at most.
                    restarts += 1
                    continue restart
                }
                guard case .fullSync(let full)? = response.filesMetadataSyncResponse.payload else { throw FilesError.malformedResponse }
                for metadata in full.metadata { gathered[metadata.id] = PhoneFile(metadata) }
                batches += 1
                set(.loading(received: gathered.count, expected: full.estimatedTotalItems > 0 ? Int(full.estimatedTotalItems) : nil))
                // Two hundred batches is the phone's own limit; a token that repeats would never end.
                guard full.hasMoreBatches_p, !full.batchContinuationToken.isEmpty, full.batchContinuationToken != token, batches < 250 else {
                    files = gathered
                    sequence = full.endingSequenceNumber
                    following = true
                    diag("files", "file list here: \(gathered.count) entries in \(batches) batches\(full.fullSyncMaxCapacityReached ? ", cut short by the phone" : "")")
                    continuation.yield(.files(Array(gathered.values)))
                    set(.ready)
                    return
                }
                token = full.batchContinuationToken
            }
        }
    }

    private func get(_ what: PhoneFiles_V1_FilesGetRequest.OneOf_Request) async throws -> PhoneFiles_V1_FilesGetResponse {
        var message = PhoneFiles_V1_FilesGetRequest()
        message.request = what
        message.requestID = UUID().uuidString.lowercased()
        guard let response = try? PhoneFiles_V1_FilesGetResponse(serializedBytes: try await request(.get, try message.serializedData())) else {
            throw FilesError.malformedResponse
        }
        guard response.status == .success else { throw FilesError.refused(response.status.rawValue) }
        return response
    }

    private var catchingUp = false, changedMeanwhile = false

    /// What changed since the list was had: asked for when the phone says there is something.
    /// One asking at a time; word of more changes meanwhile leads to one more round.
    private func catchUp() async {
        guard state == .ready, sequence != nil else { return }
        guard !catchingUp else {
            changedMeanwhile = true
            return
        }
        catchingUp = true
        defer { catchingUp = false }
        repeat {
            changedMeanwhile = false
            guard state == .ready, let from = sequence else { return }
            var ask = PhoneFiles_V1_GetFilesMetadataSyncRequest()
            ask.syncType = .incrementalSync
            ask.seqNum = from
            // Following along is no sign of the user looking.
            ask.isNoEngagementSync = true
            do {
                let response = try await get(.filesMetadataSyncRequest(ask))
                guard case .incrementalSync(let changes)? = response.filesMetadataSyncResponse.payload else { throw FilesError.malformedResponse }
                // A whole new list was asked for meanwhile: these changes belong to the old one.
                guard state == .ready, sequence == from else { return }
                for change in changes.syncOperation {
                    switch change.operation {
                    case .create(let made)?: files[made.metadata.id] = PhoneFile(made.metadata)
                    case .update(let changed)?: files[changed.metadata.id] = PhoneFile(changed.metadata)
                    case .delete(let gone)?: files[gone.metadata.id] = nil
                    case nil: break
                    }
                }
                if changes.endingSequenceNumber > from { sequence = changes.endingSequenceNumber }
                if !changes.syncOperation.isEmpty { continuation.yield(.files(Array(files.values))) }
            } catch let error as FilesError {
                // The phone no longer knows where this list stood: the whole of it again,
                // unless that is being done already.
                diag("files", "changes could not be had (\(error)); asking for the whole list")
                if state == .ready { await load(again: true, rescan: false) }
                return
            } catch {
                // No answer this time: the next word of a change asks again.
                diag("files", "changes could not be asked for: \(type(of: error))")
                return
            }
        } while changedMeanwhile
    }

    /// What the phone publishes about its files: how it is set up, its free space, and that
    /// something changed. Called while the phone waits for its publication to be taken, so
    /// nothing here waits for the phone in turn: what has to be asked is asked afterwards.
    func published(_ body: Data) {
        guard let message = try? PhoneFiles_V1_FilesResponsePayload(serializedBytes: body) else { return }
        switch message.payload {
        case .fileConfiguration(let configuration)?:
            let before = permitted
            permitted = configuration.permission
            configurationsHeard += 1
            // Granted on the phone while this side was waiting for it: go on by itself.
            if state == .needsPermission, configuration.permission, before == false { Task { await self.load() } }
        case .storageInfo(let storage)?:
            continuation.yield(.storage(available: storage.availableSizeBytes, total: storage.totalSizeBytes))
        case .fileSyncUpdate?:
            if following { Task { await self.catchUp() } }
        case nil:
            break
        }
    }

    /// A small picture of a file, as the phone makes it: JPEG bytes.
    public func thumbnail(of file: PhoneFile, side: Int = 256) async throws -> Data {
        var ask = PhoneFiles_V1_GetThumbnailRequest()
        ask.targetUri = file.uri
        ask.targetChecksum = file.checksum
        ask.width = Int32(side)
        ask.height = Int32(side)
        ask.requestID = UUID().uuidString.lowercased()
        let response = try await get(.thumbnailRequest(ask))
        let answer = response.thumbnailResponse
        guard answer.status == .success || answer.status == .unspecified, !answer.thumbnail.isEmpty else { throw FilesError.refused(answer.status.rawValue) }
        return answer.thumbnail
    }

    /// Forgets the list, as when the phone is another one.
    public func reset() {
        files = [:]
        sequence = nil
        following = false
        permitted = nil
        set(.idle)
    }
}
