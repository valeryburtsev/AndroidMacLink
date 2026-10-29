import Foundation

/// A file on this computer that is to go to the phone.
public struct OutgoingFile: Equatable, Sendable {
    /// Names the file within one transfer. Windows uses a new GUID per file.
    public var id: String
    /// The name the phone saves it under.
    public var name: String
    public var url: URL
    public var size: Int64

    public init(id: String = UUID().uuidString.lowercased(), name: String, url: URL, size: Int64) {
        self.id = id
        self.name = name
        self.url = url
        self.size = size
    }

    /// Describes a file on disk. Returns nil for a folder or anything that cannot be read.
    public init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true, let size = values.fileSize,
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        self.init(name: url.lastPathComponent, url: url, size: Int64(size))
    }
}

/// Sends files to the phone over a Nano connection, playing the part Phone Link plays.
///
/// From both programs' code (`protocol/specs/file-transfer.md`, section 4.1); never recorded:
///
/// 1. the phone creates a "launcher" channel; this side asks on it for the file-transfer
///    workflow; the phone creates a message and a blob channel;
/// 2. this side offers its files with a JSON message, scenario `FileTransferToPhone`;
/// 3. the phone asks for one file at a time (`FileTransferToPhoneFile`, the wanted file at
///    status 2), and this side sends it as a blob named by the file's ID, "#" and a count of
///    how often that file has been sent;
/// 4. the phone ends with `FileTransferToPhoneCompleted`.
///
/// The phone saves the files in its Downloads folder under "Received from PC".
public actor NanoFileSender {
    public static let offerScenario = "FileTransferToPhone"
    public static let requestScenario = "FileTransferToPhoneFile"
    public static let completedScenario = "FileTransferToPhoneCompleted"
    public static let rejectedScenario = "FileTransferToPhoneRejected"
    /// What the phone says for a cancel in either direction.
    public static let cancelScenario = "FileTransferToPcCancel"

    public enum SendError: Error, Equatable {
        /// The phone is in another transfer.
        case busy
        /// The share was called off on the phone.
        case cancelled
        case connectionLost(String)
        case timedOut
        /// A file could not be read to the end.
        case unreadable(String)
        /// The phone asked for something that was not offered.
        case unknownFile
    }

    public enum Progress: Equatable, Sendable {
        case sending(name: String, sent: Int64, total: Int64)
        case sent(name: String)
    }

    private let connection: NanoConnection
    private let senderName: String
    private let onProgress: @Sendable (Progress) async -> Void

    private var launcherChannel: UInt16?
    private var messageChannel: UInt16?
    private var blobChannel: UInt16?
    private var workflowRequested = false, greeted = false, offered = false
    /// How often each file has been sent, for the blob's name.
    private var sendCounts: [String: Int] = [:]
    private var sending: Task<Void, Never>?
    private var failure: SendError?

    public init(connection: NanoConnection, senderName: String, onProgress: @escaping @Sendable (Progress) async -> Void = { _ in }) {
        self.connection = connection
        self.senderName = senderName
        self.onProgress = onProgress
    }

    /// Runs the transfer to its end on a connection whose start sequence has completed.
    /// - Returns: how many files the phone says it received.
    public func run(files: [OutgoingFile], transferId: String = UUID().uuidString.lowercased(), timeout: Duration = .seconds(4 * 3600)) async throws -> Int {
        let offer = LegacyFileOffer(transferId: transferId, items: files.map { .init(id: $0.id, name: $0.name, size: $0.size) })
        let limit = Task { [connection] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { await connection.close() }
        }
        defer {
            limit.cancel()
            sending?.cancel()
        }
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
                try await offerIfReady(offer)
            case .messageHandshake(let channel):
                if channel == launcherChannel, !workflowRequested {
                    workflowRequested = true
                    diag("files", "launcher channel ready; asking for the file-transfer workflow")
                    let request: [String: Any] = ["workflow": NanoFileReceiver.workflowName, "workflowId": UUID().uuidString.lowercased()]
                    try await connection.sendMessage(channel: channel, path: NanoFileReceiver.launcherPath, body: try JSONSerialization.data(withJSONObject: request))
                } else if channel == messageChannel {
                    greeted = true
                    try await offerIfReady(offer)
                }
            case .message(_, let message):
                guard message.path == NanoFileReceiver.legacyPath,
                      let object = try? JSONSerialization.jsonObject(with: message.body) as? [String: Any], let scenario = object["Scenario"] as? String else {
                    diag("files", "message on \(message.path.prefix(40)), \(message.body.count) bytes, not understood")
                    continue
                }
                diag("files", "the phone says \(scenario)")
                switch scenario {
                case NanoFileSender.requestScenario:
                    guard let wanted = NanoFileSender.wantedFile(in: object, of: files) else { throw SendError.unknownFile }
                    start(wanted)
                case NanoFileSender.completedScenario:
                    await connection.flush(timeout: .seconds(2))
                    return (object["ReceivedFileCount"] as? NSNumber)?.intValue ?? files.count
                case NanoFileSender.rejectedScenario:
                    throw SendError.busy
                case NanoFileSender.cancelScenario:
                    throw SendError.cancelled
                default:
                    break
                }
            case .closed(let reason):
                throw failure ?? SendError.connectionLost(reason)
            default:
                break
            }
        }
        throw failure ?? SendError.timedOut
    }

    /// The file the phone asks for: the one at status 2, or the only one named.
    static func wantedFile(in object: [String: Any], of files: [OutgoingFile]) -> OutgoingFile? {
        let content = object["Content"] as? [[String: Any]] ?? []
        let wanted = content.first { ($0["FileStatus"] as? NSNumber)?.intValue == 2 } ?? (content.count == 1 ? content.first : nil)
        guard let id = wanted?["FileId"] as? String else { return nil }
        return files.first { $0.id == id }
    }

    private func offerIfReady(_ offer: LegacyFileOffer) async throws {
        guard let messageChannel, blobChannel != nil, greeted, !offered else { return }
        offered = true
        diag("files", "offering \(offer.items.count) files to the phone")
        try await connection.sendMessage(channel: messageChannel, path: NanoFileReceiver.legacyPath,
                                         body: offer.message(scenario: NanoFileSender.offerScenario, senderName: senderName, statuses: [:]))
    }

    /// Sends one file as a blob, apart from the loop that listens to the phone, so that a
    /// cancel is heard while the bytes go out.
    private func start(_ file: OutgoingFile) {
        guard let blobChannel else { return }
        let count = sendCounts[file.id, default: 0] + 1
        sendCounts[file.id] = count
        diag("files", "sending a file of \(file.size) bytes, try \(count)")
        sending?.cancel()
        sending = Task { [connection, onProgress] in
            do {
                try await connection.sendBlob(channel: blobChannel, name: "\(file.id)#\(count)", file: file.url, size: Int(file.size)) { sent in
                    await onProgress(.sending(name: file.name, sent: Int64(sent), total: file.size))
                }
                await onProgress(.sent(name: file.name))
            } catch is CancellationError {
            } catch NanoConnection.ConnectionError.closed {
            } catch {
                // The file changed or cannot be read: nothing more can be sent on this connection.
                await self.fail(.unreadable(file.name))
            }
        }
    }

    private func fail(_ error: SendError) async {
        failure = error
        await connection.close()
    }
}
