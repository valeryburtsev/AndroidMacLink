import Foundation
import SwiftProtobuf

/// A file the phone shared, as it arrived.
public struct ReceivedFile: Equatable, Sendable {
    /// The name the phone gave it. Chosen by whoever made the file; clean it before use.
    public var name: String
    /// In memory, or a file of its own that whoever takes it moves or deletes.
    public var content: NanoBlobContent

    public init(name: String, content: NanoBlobContent) {
        self.name = name
        self.content = content
    }

    public init(name: String, data: Data) {
        self.init(name: name, content: .data(data))
    }

    public var size: Int { content.count }
    /// The bytes; a file is read whole.
    public var data: Data { content.data }
}

/// A share the phone offered to the Phone Link client, as its JSON says: which transfer, and
/// which files.
public struct LegacyFileOffer: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var id: String
        public var name: String
        public var size: Int64
    }

    public var transferId: String
    public var sessionTryCount: Int
    public var items: [Item]

    public static let offerScenario = "FileTransferToPc"

    /// Parses the `fileTransferFileDetail` text of an offer. Returns nil for anything else.
    public init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              object["Scenario"] as? String == LegacyFileOffer.offerScenario, let transferId = object["TransferId"] as? String,
              let content = object["Content"] as? [[String: Any]] else { return nil }
        self.transferId = transferId
        sessionTryCount = (object["SessionTryCount"] as? NSNumber)?.intValue ?? 0
        items = content.compactMap { item in
            guard let id = item["FileId"] as? String, !id.isEmpty else { return nil }
            return Item(id: id, name: item["FileName"] as? String ?? id, size: (item["FileSize"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    public init(transferId: String, sessionTryCount: Int = 1, items: [Item]) {
        self.transferId = transferId
        self.sessionTryCount = sessionTryCount
        self.items = items
    }

    /// A message of the transfer as JSON: the scenario, and every file with its status
    /// (1 waiting, 2 wanted now, 3 received).
    func message(scenario: String, senderName: String, statuses: [String: Int], folder: String? = nil) -> Data {
        var object: [String: Any] = [
            "TransferId": transferId, "Scenario": scenario, "SenderName": senderName,
            "ReceivedFileCount": statuses.values.filter { $0 == 3 }.count, "SessionTryCount": sessionTryCount,
            "Content": items.map { ["FileId": $0.id, "FileName": $0.name, "FileSize": $0.size, "FileHash": "", "FileStatus": statuses[$0.id] ?? 1] as [String: Any] },
        ]
        if let folder { object["PcFolder"] = folder }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

/// Receives the files of one share from the phone over a Nano connection, playing the part
/// Windows plays. There are two forms of the exchange, by which of the two clients the phone
/// chose as its target.
///
/// Toward the Phone Link client (`run(offer:)`), from both programs' code, never recorded:
/// the phone creates a "launcher" channel; this side asks on it for the file-transfer
/// workflow; the phone creates a message and a blob channel; this side asks for one file at a
/// time with a JSON message and the phone sends it as a blob; a "completed" message ends it.
///
/// Toward the cross-device client (`run()`), as recorded from Windows:
///
/// 1. the phone creates its control channel; this side asks on it for a file-share channel;
/// 2. the phone creates a message channel and a blob channel and offers its files;
/// 3. this side answers with the list of files it wants (all of them);
/// 4. each file arrives as a blob named by its file ID;
/// 5. both sides say "completed".
///
/// The exchange is the one recorded from Windows (`protocol/specs/nano-wire-notes.md` 10.8).
public actor NanoFileReceiver {
    /// The scenario Link to Windows accepts for a share toward the PC.
    public static let scenarioId = "fileShare_2B0F3A34-0C30-4CC0-8165-87FC30DB1E35"
    public static let offerScenario = "FileTransferToPc"
    public static let completedScenario = "FileTransferToPcCompleted"

    public enum ReceiveError: Error, Equatable {
        /// The phone refused the file-share channel.
        case refused(String)
        case connectionLost(String)
        case timedOut
        /// The phone called the share off.
        case cancelled
        /// A file could not be stored: the disk is too full, or its file could not be written.
        case noRoom
    }

    public enum Progress: Equatable, Sendable {
        case offered(names: [String], totalBytes: Int64)
        case receiving(name: String, received: Int, total: Int)
        case received(ReceivedFile)
    }

    private let connection: NanoConnection
    private let senderName: String
    private let onProgress: @Sendable (Progress) async -> Void

    private var controlChannel: UInt16?
    private var messageChannel: UInt16?
    private var blobChannel: UInt16?
    private var requestedChannel = false
    private var offer: FileTransfer_V1_FileShareMessage?
    private var received: [String: ReceivedFile] = [:]

    /// - Parameters:
    ///   - senderName: this computer's name, told to the phone at the end.
    ///   - onProgress: called as the share proceeds, with each file when it is complete.
    public init(connection: NanoConnection, senderName: String, onProgress: @escaping @Sendable (Progress) async -> Void = { _ in }) {
        self.connection = connection
        self.senderName = senderName
        self.onProgress = onProgress
    }

    private var scenarioPath: String { "/" + NanoFileReceiver.scenarioId }
    private var sharePath: String { scenarioPath + "/NamedStreams/fileTransfer/platform" }

    /// Runs the share to its end on a connection whose start sequence has completed.
    /// - Returns: the files, in the order the phone offered them.
    public func run(timeout: Duration = .seconds(600)) async throws -> [ReceivedFile] {
        let limit = Task { [connection] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { await connection.close() }
        }
        defer { limit.cancel() }
        for await event in connection.events {
            switch event {
            case .channelCreated(let channel, let description):
                let scenario = description.properties["ScenarioId"]
                if description.channelClass == "Messaging", scenario == "DeviceConnection" {
                    controlChannel = channel
                } else if description.channelClass == "Messaging", scenario == NanoFileReceiver.scenarioId {
                    messageChannel = channel
                } else if description.channelClass == "Blob", scenario == NanoFileReceiver.scenarioId {
                    blobChannel = channel
                }
            case .messageHandshake(let channel):
                // The control channel is ready: ask for the file-share channel, once.
                if channel == controlChannel, !requestedChannel {
                    requestedChannel = true
                    try await connection.sendMessage(channel: channel, path: "/Channel/ProtoCreatePlatformChannelRequest", body: try channelRequest().serializedData())
                }
            case .message(let channel, let message):
                if let files = try await handle(message, on: channel) { return files }
            case .blobProgress(let channel, let name, let got, let total):
                await onProgress(.receiving(name: fileName(for: name), received: got, total: total))
                try? await connection.sendBlobPacket(channel: channel, .written(queued: 0, name: name))
            case .blobReceived(let channel, let name, let content):
                let file = ReceivedFile(name: fileName(for: name), content: content)
                received[name] = file
                await onProgress(.received(file))
                try await finishIfComplete(blobChannel: channel)
            case .blobRefused:
                throw ReceiveError.noRoom
            case .closed(let reason):
                throw offer == nil && !requestedChannel ? ReceiveError.connectionLost(reason) : ReceiveError.connectionLost(reason)
            default:
                break
            }
        }
        throw ReceiveError.timedOut
    }

    // MARK: A file from the phone's storage

    /// The scenario under which the phone hands out a file of its storage
    /// (`protocol/specs/file-transfer.md` 6.4 and 6.4a).
    public static let storageScenarioId = "fileTransfer_1EAA053C-0354-4DF8-AA05-888312CCC57E"
    static let storageErrorSuffix = "/com.microsoft.mmx.agents.files.transport.files_stream_error"

    /// A file asked for by the address the phone's own list gives it.
    public struct Wanted: Equatable, Sendable {
        /// `content://media/external/file/<id>`: also the name its bytes arrive under.
        public var uri: String
        public var name: String
        public var size: Int64

        public init(uri: String, name: String, size: Int64) {
            self.uri = uri
            self.name = name
            self.size = size
        }
    }

    /// Fetches one file of the phone's storage on a connection whose start sequence has
    /// completed. From the phone's code, never recorded; the exchange around it is the one
    /// of a share: this side asks for a channel of the scenario, then for the file by a
    /// list of one, and the phone sends it as a blob named by its address.
    /// - Parameter timeout: how long nothing may arrive before the fetch is given up; a
    ///   large file may take as long as it takes while it keeps coming.
    public func fetch(_ file: Wanted, timeout: Duration = .seconds(90)) async throws -> [ReceivedFile] {
        lastArrival = ContinuousClock.now
        let limit = Task { [weak self, connection] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(min(5000, max(100, Int(timeout.components.seconds) * 100))))
                guard !Task.isCancelled, let quiet = await self?.quietFor() else { return }
                if quiet > timeout {
                    await connection.close()
                    return
                }
            }
        }
        defer { limit.cancel() }
        let scenario = NanoFileReceiver.storageScenarioId
        var asked = false
        await onProgress(.offered(names: [file.name], totalBytes: file.size))
        for await event in connection.events {
            lastArrival = ContinuousClock.now
            switch event {
            case .channelCreated(let channel, let description):
                let named = description.properties["ScenarioId"]
                if description.channelClass == "Messaging", named == "DeviceConnection" {
                    controlChannel = channel
                } else if description.channelClass == "Messaging", named == scenario {
                    messageChannel = channel
                } else if description.channelClass == "Blob", named == scenario {
                    blobChannel = channel
                }
            case .messageHandshake(let channel):
                if channel == controlChannel, !requestedChannel {
                    requestedChannel = true
                    try await connection.sendMessage(channel: channel, path: "/Channel/ProtoCreatePlatformChannelRequest",
                                                     body: try channelRequest(scenario: scenario).serializedData())
                } else if channel == messageChannel, !asked {
                    // The phone has made the scenario's channels: the list of what is wanted, one file.
                    asked = true
                    var manifest = PlatformSdk_V1_ProtoManifest()
                    var entry = PlatformSdk_V1_ProtoManifestEntry()
                    entry.id = file.uri
                    entry.size = UInt64(max(0, file.size))
                    manifest.entries[file.uri] = entry
                    manifest.traceContext = NanoFileReceiver.traceContext()
                    try await connection.sendMessage(channel: channel, path: "/" + scenario + "/ManifestRequest", body: try manifest.serializedData())
                }
            case .message(_, let message):
                if message.path.hasSuffix("/ProtoPeerPlatformChannelCreationResult") {
                    let result = try PlatformSdk_V1_ProtoPeerPlatformChannelCreationResult(serializedBytes: message.body)
                    guard result.resultCode == .success else { throw ReceiveError.refused("\(result.resultCode), \(result.resultReason)") }
                } else if message.path.hasSuffix(NanoFileReceiver.storageErrorSuffix) {
                    // The phone could not open the file: it says so here and sends an empty stream.
                    let status = (try? PhoneFiles_V1_FilesStreamsMessage(serializedBytes: message.body))?.streamMessageStatus.rawValue ?? 0
                    throw ReceiveError.refused("the phone could not read the file (\(status))")
                }
            case .blobProgress(let channel, let name, let got, let total):
                await onProgress(.receiving(name: file.name, received: got, total: total))
                try? await connection.sendBlobPacket(channel: channel, .written(queued: 0, name: name))
            case .blobReceived(let channel, let name, let content):
                // A file it cannot open the phone answers with an empty stream and a message
                // saying why; whichever comes first, nothing is no file.
                if content.count == 0, file.size > 0 {
                    if case .file(let url, _) = content { try? FileManager.default.removeItem(at: url) }
                    throw ReceiveError.refused("the phone sent nothing for the file")
                }
                let received = ReceivedFile(name: file.name, content: content)
                await onProgress(.received(received))
                // The reports a share ends a blob with, in the order Windows sends them.
                try? await connection.sendBlobPacket(channel: channel, .written(queued: 1, name: name))
                try? await connection.sendBlobPacket(channel: channel, .completion(kind: 4, name: name))
                try? await connection.sendBlobPacket(channel: channel, .written(queued: 0, name: name))
                await connection.flush(timeout: .seconds(2))
                if let messageChannel { try? await connection.closeChannel(messageChannel) }
                if let blobChannel { try? await connection.closeChannel(blobChannel) }
                await connection.flush(timeout: .seconds(2))
                return [received]
            case .blobRefused:
                throw ReceiveError.noRoom
            case .closed(let reason):
                throw ReceiveError.connectionLost(reason)
            default:
                break
            }
        }
        throw ReceiveError.timedOut
    }

    private var lastArrival = ContinuousClock.now
    private func quietFor() -> Duration { ContinuousClock.now - lastArrival }

    func channelRequest(scenario: String = NanoFileReceiver.scenarioId) -> PlatformSdk_V1_ProtoCreatePlatformChannelRequest {
        var request = PlatformSdk_V1_ProtoCreatePlatformChannelRequest()
        request.type = .namedStreamsChannel
        request.scenarioID = scenario
        request.channelID = UUID().uuidString.lowercased()
        request.traceContext = NanoFileReceiver.traceContext()
        return request
    }

    static func traceContext() -> PlatformSdk_V1_ProtoTraceContext {
        var context = PlatformSdk_V1_ProtoTraceContext()
        context.traceID = TraceContext.randomHex(bytes: 16)
        context.parentID = TraceContext.randomHex(bytes: 8)
        context.correlationID = TraceContext.randomHex(bytes: 8)
        return context
    }

    private func fileName(for id: String) -> String {
        offer?.content.first { $0.fileID == id }?.fileName ?? id
    }

    /// Handles one message; returns the files when the share is over.
    private func handle(_ message: NanoMessageAssembler.Message, on channel: UInt16) async throws -> [ReceivedFile]? {
        if message.path.hasSuffix("/ProtoPeerPlatformChannelCreationResult") {
            let result = try PlatformSdk_V1_ProtoPeerPlatformChannelCreationResult(serializedBytes: message.body)
            guard result.resultCode == .success else { throw ReceiveError.refused("\(result.resultCode), \(result.resultReason)") }
            return nil
        }
        guard message.path == sharePath, let share = try? FileTransfer_V1_FileShareMessage(serializedBytes: message.body) else { return nil }
        switch share.scenario {
        case NanoFileReceiver.offerScenario:
            offer = share
            await onProgress(.offered(names: share.content.map(\.fileName), totalBytes: share.content.reduce(0) { $0 + $1.fileSize }))
            // Ask for every file offered, by ID and size.
            var manifest = PlatformSdk_V1_ProtoManifest()
            for item in share.content {
                var entry = PlatformSdk_V1_ProtoManifestEntry()
                entry.id = item.fileID
                entry.size = UInt64(max(0, item.fileSize))
                manifest.entries[item.fileID] = entry
            }
            manifest.traceContext = NanoFileReceiver.traceContext()
            try await connection.sendMessage(channel: channel, path: scenarioPath + "/ManifestRequest", body: try manifest.serializedData())
            // An offer without files is over at once.
            if share.content.isEmpty, let blobChannel { try await finishIfComplete(blobChannel: blobChannel) }
            return nil
        case NanoFileReceiver.completedScenario:
            // The phone's acknowledgement: close what it opened for the share and stop.
            await connection.flush(timeout: .seconds(2))
            if let messageChannel { try? await connection.closeChannel(messageChannel) }
            if let blobChannel { try? await connection.closeChannel(blobChannel) }
            await connection.flush(timeout: .seconds(2))
            return orderedFiles()
        default:
            return nil
        }
    }

    // MARK: Toward the Phone Link client

    static let launcherPath = "/workflow"
    static let legacyPath = "/fileTransfer"
    static let workflowName = "fileTransfer"

    private var launcherChannel: UInt16?
    private var workflowRequested = false
    private var legacyGreeted = false
    private var wanted: String?
    private var statuses: [String: Int] = [:]

    /// Receives the files of an offer made to the Phone Link client, on a connection whose
    /// start sequence has completed.
    /// - Parameter folderName: told to the phone at the end as where the files went.
    public func run(offer: LegacyFileOffer, folderName: String = "Downloads", timeout: Duration = .seconds(600)) async throws -> [ReceivedFile] {
        legacyFolder = folderName
        await onProgress(.offered(names: offer.items.map(\.name), totalBytes: offer.items.reduce(0) { $0 + $1.size }))
        let limit = Task { [connection] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { await connection.close() }
        }
        defer { limit.cancel() }
        func name(_ id: String) -> String { offer.items.first { $0.id == id }?.name ?? id }
        for await event in connection.events {
            switch event {
            case .channelCreated(let channel, let description):
                let workflow = description.properties["workflow"]
                if description.channelClass == "Messaging", workflow == "launcher" {
                    launcherChannel = channel
                } else if description.channelClass == "Messaging", workflow == NanoFileReceiver.workflowName {
                    messageChannel = channel
                } else if description.channelClass == "Blob", workflow == NanoFileReceiver.workflowName {
                    blobChannel = channel
                }
                try await askForNextFile(of: offer)
            case .messageHandshake(let channel):
                if channel == launcherChannel, !workflowRequested {
                    // Ask the phone to start its file-transfer workflow on this connection.
                    workflowRequested = true
                    diag("files", "launcher channel ready; asking for the file-transfer workflow")
                    let request: [String: Any] = ["workflow": NanoFileReceiver.workflowName, "workflowId": UUID().uuidString.lowercased()]
                    try await connection.sendMessage(channel: channel, path: NanoFileReceiver.launcherPath, body: try JSONSerialization.data(withJSONObject: request))
                } else if channel == messageChannel {
                    legacyGreeted = true
                    try await askForNextFile(of: offer)
                }
            case .message(_, let message):
                guard message.path == NanoFileReceiver.legacyPath,
                      let object = try? JSONSerialization.jsonObject(with: message.body) as? [String: Any], let scenario = object["Scenario"] as? String else {
                    diag("files", "message on \(message.path.prefix(40)), \(message.body.count) bytes, not understood")
                    continue
                }
                diag("files", "the phone says \(scenario)")
                if scenario == NanoFileReceiver.completedScenario {
                    await connection.flush(timeout: .seconds(2))
                    return offer.items.compactMap { received[$0.id] }
                }
                if scenario == "FileTransferToPcCancel" { throw ReceiveError.cancelled }
            case .blobProgress(let channel, let id, let got, let total):
                await onProgress(.receiving(name: name(id), received: got, total: total))
                // The receiving side reports that it keeps up, which the sender paces itself by.
                try? await connection.sendBlobPacket(channel: channel, .written(queued: 0, name: id))
            case .blobRefused:
                throw ReceiveError.noRoom
            case .blobReceived(let channel, let id, let content):
                let file = ReceivedFile(name: name(id), content: content)
                received[id] = file
                statuses[id] = 3
                wanted = nil
                await onProgress(.received(file))
                // What the receiving side of a blob channel reports, as recorded from Windows.
                try await connection.sendBlobPacket(channel: channel, .written(queued: 1, name: id))
                try await connection.sendBlobPacket(channel: channel, .completion(kind: 4, name: id))
                try await connection.sendBlobPacket(channel: channel, .written(queued: 0, name: id))
                try await askForNextFile(of: offer)
            case .closed(let reason):
                // Once every file is here, a phone that hangs up instead of confirming has
                // still delivered.
                if offer.items.allSatisfy({ received[$0.id] != nil }), !offer.items.isEmpty { return offer.items.compactMap { received[$0.id] } }
                throw ReceiveError.connectionLost(reason)
            default:
                break
            }
        }
        throw ReceiveError.timedOut
    }

    /// Asks for the next file not yet received, or says "completed" when none is left. One
    /// file at a time, as Windows does.
    private func askForNextFile(of offer: LegacyFileOffer) async throws {
        guard let messageChannel, blobChannel != nil, legacyGreeted, wanted == nil else { return }
        if let next = offer.items.first(where: { received[$0.id] == nil }) {
            diag("files", "asking for file \(received.count + 1) of \(offer.items.count)")
            wanted = next.id
            statuses[next.id] = 2
            try await connection.sendMessage(channel: messageChannel, path: NanoFileReceiver.legacyPath,
                                             body: offer.message(scenario: "FileTransferToPcFile", senderName: senderName, statuses: statuses))
        } else {
            wanted = "done"
            try await connection.sendMessage(channel: messageChannel, path: NanoFileReceiver.legacyPath,
                                             body: offer.message(scenario: NanoFileReceiver.completedScenario, senderName: senderName, statuses: statuses, folder: legacyFolder))
        }
    }

    private var legacyFolder = "Downloads"

    private func orderedFiles() -> [ReceivedFile] {
        (offer?.content ?? []).compactMap { received[$0.fileID] }
    }

    /// Once every offered file is here: the reports and the "completed" message, in the
    /// order Windows sends them.
    private func finishIfComplete(blobChannel channel: UInt16) async throws {
        guard let offer, let messageChannel, offer.content.allSatisfy({ received[$0.fileID] != nil }) else { return }
        for item in offer.content { try await connection.sendBlobPacket(channel: channel, .written(queued: 1, name: item.fileID)) }
        var done = FileTransfer_V1_FileShareMessage()
        done.transferID = offer.transferID
        done.scenario = NanoFileReceiver.completedScenario
        done.senderName = senderName
        done.receivedFileCount = Int32(clamping: offer.content.count)
        done.sessionTryCount = offer.sessionTryCount
        done.content = offer.content.map { item in
            var finished = item
            finished.fileStatus = .completed
            return finished
        }
        try await connection.sendMessage(channel: messageChannel, path: sharePath, body: try done.serializedData())
        for item in offer.content {
            try await connection.sendBlobPacket(channel: channel, .completion(kind: 4, name: item.fileID))
            try await connection.sendBlobPacket(channel: channel, .written(queued: 0, name: item.fileID))
        }
    }
}
