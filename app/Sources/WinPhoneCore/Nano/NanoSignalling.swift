import Foundation
import SwiftProtobuf

/// What the phone says about how to reach it directly: its addresses by network interface,
/// a UDP port, and the key that protects the connection.
public struct NanoDirectContract: Equatable, Sendable {
    public struct Address: Equatable, Sendable {
        public var interface: String
        public var address: String
    }

    public var addresses: [Address]
    public var port: UInt16
    public var keys: NanoSessionKeys

    /// The addresses to try, most likely first: Wi-Fi before anything else, and never the
    /// mobile data interfaces, which a computer on the local network cannot reach.
    public var candidates: [String] {
        let usable = addresses.filter { !$0.interface.hasPrefix("rmnet") && !$0.interface.hasPrefix("ccmni") && !$0.address.isEmpty }
        return (usable.filter { $0.interface.hasPrefix("wlan") } + usable.filter { !$0.interface.hasPrefix("wlan") }).map(\.address)
    }

    /// Parses a connection description of the direct kind. Returns nil for any other kind
    /// and for one that lacks an address, a port or a key.
    public init?(connectionDescription text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        // Two wrappings of the same thing: on the cross-device session the phone's part sits
        // under "connectioninformation" beside a connection type; in the answer to a Phone
        // Link handshake it is the object itself.
        let info: [String: Any]
        if let nested = object["connectioninformation"] as? [String: Any] {
            guard (object["connectiontype"] as? NSNumber)?.intValue == NanoSignalling.directConnectionType else { return nil }
            info = nested
        } else {
            info = object
        }
        guard let ip = info["ip"] as? [String: Any], let security = info["security"] as? [String: Any],
              let key = security["key"] as? String, let salt = security["salt"] as? String,
              let keys = try? NanoSessionKeys(keyHex: key, saltHex: salt) else { return nil }
        // The phone writes numbers as text; accept both.
        func number(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) }
        guard let port = number(info["port"]), (1...65535).contains(port) else { return nil }
        var addresses: [Address] = []
        for index in 0..<min(16, number(ip["count"]) ?? 16) {
            guard let entry = ip["\(index)"] as? [String: Any], let address = entry["addr"] as? String else { continue }
            addresses.append(Address(interface: entry["iname"] as? String ?? "", address: address))
        }
        guard !addresses.isEmpty else { return nil }
        self.addresses = addresses
        self.port = UInt16(port)
        self.keys = keys
    }
}

/// The signalling that precedes a Nano connection, carried by the relay session of the
/// cross-device role: the phone announces a share with a resource request, the PC asks the
/// phone to set up a direct connection and the phone answers with where and with which key.
///
/// The messages are those Windows was recorded sending on 2026-10-09
/// (`protocol/specs/nano-scoping.md` section 9), reduced to the direct kind: Windows also
/// offers relayed connections in the same exchange, which this client does not.
public actor NanoSignalling {
    public static let messageRoute = "/Context/Message"
    public static let shareResource = "/fileshare_android2cdeh_phase1"
    /// `connectiontype` of a direct connection in a connection description.
    public static let directConnectionType = 0
    static let acknowledgement = Data(#"{"processStatus":"Success"}"#.utf8)

    public enum SignallingError: Error, Equatable {
        /// The phone did not acknowledge or did not say how to reach it.
        case noAnswer
        case refused(String)
    }

    private let messenger: PeerMessenger
    private let resources: DeviceResources
    private let ownId: String
    private let peerId: String
    private var acknowledged: [CheckedContinuation<Void, Error>] = []
    private var contractWaiters: [CheckedContinuation<NanoDirectContract, Error>] = []
    private var pendingAcknowledgement = false
    private var pendingContract: NanoDirectContract?
    private var onShare: (@Sendable (_ transferId: String) async -> Void)?

    public init(messenger: PeerMessenger, resources: DeviceResources, ownId: String, peerId: String) {
        self.messenger = messenger
        self.resources = resources
        self.ownId = ownId
        self.peerId = peerId
    }

    /// Starts answering the phone. `onShare` is called each time the phone announces a share
    /// toward this computer, after the announcement has been accepted.
    public func start(onShare: @escaping @Sendable (_ transferId: String) async -> Void) async {
        self.onShare = onShare
        await resources.serve(NanoSignalling.shareResource) { [weak self] request in
            await self?.shareAnnounced(request)
        }
        await messenger.handle(NanoSignalling.messageRoute, prefix: true) { [weak self] request, messenger in
            try? await messenger.respond(to: request, payload: NanoSignalling.acknowledgement, contentType: PeerMessenger.jsonContentType)
            await self?.received(request.payload)
        }
    }

    /// The phone's announcement of a share: answered with "OK", after which the phone waits
    /// for this side to open the connection.
    private func shareAnnounced(_ request: DeviceResources.IncomingRequest) -> Data? {
        guard let announcement = try? FileTransfer_V1_NanoDelegateInitRequest(serializedBytes: request.payload) else {
            var response = FileTransfer_V1_NanoDelegateInitResponse()
            response.status = request.payload.isEmpty ? .emptyPayload : .unrecognizedPayload
            return try? response.serializedData()
        }
        var response = FileTransfer_V1_NanoDelegateInitResponse()
        response.fileTransferSessionID = announcement.fileTransferSessionID
        response.status = .ok
        let transferId = announcement.fileTransferSessionID
        if let onShare { Task { await onShare(transferId) } }
        return try? response.serializedData()
    }

    private func received(_ payload: Data) {
        guard let message = try? PlatformSdk_V1_ContextSourceMessage(serializedBytes: payload), let type = message.type else { return }
        switch type {
        case .csInitializeAckMessage(let ack):
            if ack.status == .success {
                if acknowledged.isEmpty { pendingAcknowledgement = true }
                for waiter in acknowledged { waiter.resume() }
            } else {
                for waiter in acknowledged { waiter.resume(throwing: SignallingError.refused("\(ack.status)")) }
            }
            acknowledged.removeAll()
        case .csConnectionInfo(let info):
            guard let contract = NanoDirectContract(connectionDescription: info.connectionInfo) else { return }
            if contractWaiters.isEmpty { pendingContract = contract }
            for waiter in contractWaiters { waiter.resume(returning: contract) }
            contractWaiters.removeAll()
        case .csErrorInfo:
            for waiter in acknowledged { waiter.resume(throwing: SignallingError.refused("the phone reported an error")) }
            for waiter in contractWaiters { waiter.resume(throwing: SignallingError.refused("the phone reported an error")) }
            acknowledged.removeAll()
            contractWaiters.removeAll()
        default:
            break
        }
    }

    static func traceContext() -> PlatformSdk_V1_ProtoTraceContext { NanoFileReceiver.traceContext() }

    func initializeMessage() -> PlatformSdk_V1_ContextSourceMessage {
        var initialize = PlatformSdk_V1_CSInitializeMessage()
        // Names the device the connection is to: the phone.
        initialize.contextSourceID = peerId
        initialize.transportPreference = 0
        initialize.traceContext = NanoSignalling.traceContext()
        var message = PlatformSdk_V1_ContextSourceMessage()
        message.csInitializeMessage = initialize
        return message
    }

    /// The description of this side's end of a direct connection: nothing but an identifier,
    /// since the phone is the one that listens.
    static func directDescription(connectionId: String = UUID().uuidString.lowercased()) -> String {
        "{\"connectioninformation\":{},\"connectionid\":\"\(connectionId)\",\"connectiontype\":\(directConnectionType),\"multipleconnections\":true}"
    }

    func connectionInfoMessage() -> PlatformSdk_V1_ContextSourceMessage {
        var info = PlatformSdk_V1_CSConnectionInfo()
        info.connectionInfo = NanoSignalling.directDescription()
        info.traceContext = NanoSignalling.traceContext()
        var message = PlatformSdk_V1_ContextSourceMessage()
        message.csConnectionInfo = info
        return message
    }

    /// Asks the phone to set up a direct connection and returns where it listens.
    public func requestDirectConnection(timeout: Duration = .seconds(15)) async throws -> NanoDirectContract {
        pendingAcknowledgement = false
        pendingContract = nil
        // 1. "Initialize", on the bare route; the phone acknowledges with a message of its own.
        _ = try await messenger.request(route: NanoSignalling.messageRoute, payload: try initializeMessage().serializedData(), timeout: timeout)
        try await waitForAcknowledgement(timeout: timeout)
        // 2. This side's description, on the route that ends in this side's own identifier.
        _ = try await messenger.request(route: NanoSignalling.messageRoute + "/" + ownId, payload: try connectionInfoMessage().serializedData(), timeout: timeout)
        // 3. The phone's description, with its addresses, port and key.
        return try await waitForContract(timeout: timeout)
    }

    private func waitForAcknowledgement(timeout: Duration) async throws {
        if pendingAcknowledgement {
            pendingAcknowledgement = false
            return
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { await self?.expire() }
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in acknowledged.append(waiter) }
    }

    private func waitForContract(timeout: Duration) async throws -> NanoDirectContract {
        if let contract = pendingContract {
            pendingContract = nil
            return contract
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { await self?.expire() }
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<NanoDirectContract, Error>) in contractWaiters.append(waiter) }
    }

    private func expire() {
        for waiter in acknowledged { waiter.resume(throwing: SignallingError.noAnswer) }
        for waiter in contractWaiters { waiter.resume(throwing: SignallingError.noAnswer) }
        acknowledged.removeAll()
        contractWaiters.removeAll()
    }
}

/// Receives shares from the phone: ties the signalling, the connection and the receiver
/// together for one phone, one share at a time.
public actor PhoneFileReceiver {
    public enum Update: Equatable, Sendable {
        /// The phone announced a share; the connection is being set up.
        case started
        case offered(names: [String], totalBytes: Int64)
        case receiving(name: String, received: Int, total: Int)
        case received(ReceivedFile)
        case finished(count: Int)
        case failed(String)
        /// Files from this computer are on their way to the phone.
        case sendStarted(names: [String], totalBytes: Int64)
        case sending(name: String, sent: Int64, total: Int64)
        /// One file has gone out whole.
        case sent(name: String)
        /// The phone has confirmed this many files.
        case sendFinished(count: Int)
        /// The transfer was stopped from this side.
        case cancelled
    }

    /// The connection of the transfer that is running, and whether it was told to stop.
    private var active: NanoConnection?
    private var cancelRequested = false

    /// Stops the transfer that is running, in either direction. The phone sees the connection
    /// end, which is also all it sees when Phone Link cancels.
    public func cancel() async {
        guard busy else { return }
        cancelRequested = true
        await active?.close()
    }

    /// Reports how a transfer ended badly: as stopped here, or with what went wrong.
    private func report(_ error: Error, _ what: String) {
        if cancelRequested {
            diag("files", "\(what) stopped here")
            continuation.yield(.cancelled)
        } else {
            // Without the name an unreadable file's error carries.
            if case NanoFileSender.SendError.unreadable = error { diag("files", "\(what) failed: a file could not be read") } else { diag("files", "\(what) failed: \(error)") }
            continuation.yield(.failed(PhoneFileReceiver.describe(error)))
        }
    }

    /// Whether a transfer is running, in either direction.
    public var isBusy: Bool { busy }

    private let signalling: NanoSignalling?
    private let senderName: String
    private let makeTransport: @Sendable (_ host: String, _ port: UInt16) async throws -> NanoDatagramTransport
    private let connector: NanoConnector
    private let connectionSettings: NanoConnection.Settings
    private let continuation: AsyncStream<Update>.Continuation
    public nonisolated let updates: AsyncStream<Update>
    private var busy = false

    /// - Parameters:
    ///   - relayServers: where the helping servers for a connection over the internet come
    ///     from; without it only the same network is tried.
    ///   - makeTransport: opens UDP to the phone; replaced in tests.
    public init(signalling: NanoSignalling?, senderName: String, connectionSettings: NanoConnection.Settings = .init(),
                relayServers: (@Sendable () async -> NanoRelayServers?)? = nil,
                makeTransport: @escaping @Sendable (_ host: String, _ port: UInt16) async throws -> NanoDatagramTransport = { host, port in
                    let transport = try NanoSocketTransport(host: host, port: port)
                    diag("files", "socket open, receive buffer \(transport.receiveBufferSize / 1024) kB")
                    return transport
                }) {
        self.signalling = signalling
        self.senderName = senderName
        self.connectionSettings = connectionSettings
        self.makeTransport = makeTransport
        connector = NanoConnector(makeTransport: makeTransport, relayServers: relayServers)
        (updates, continuation) = AsyncStream.makeStream(of: Update.self, bufferingPolicy: .unbounded)
    }

    public func start() async {
        await signalling?.start { [weak self] _ in await self?.receiveShare() }
    }

    // MARK: A share offered to the Phone Link client

    public static let handshakeRoute = "/nanohandshake"

    /// This side's part of the handshake: nothing about the connection itself, since the
    /// phone is the one that listens, only what the phone's connection service reads.
    static func handshakeDescription(instanceId: String = UUID().uuidString.lowercased()) -> String {
        "{\"contractVersion\":{\"versionMin\":6,\"versionMax\":6},\"settings\":{\"connectionType\":0},\"instanceId\":\"\(instanceId)\",\"multipleConnections\":true}"
    }

    /// - Parameter workflow: what the connection is first wanted for: `fileTransfer`, or
    ///   `permission` when the phone's screen is to be shown.
    static func handshakeRequest(sender: AppSender, transferId: String, workflow: String = NanoFileReceiver.workflowName, description: String = handshakeDescription(),
                                 now: Date = Date()) -> ValueSet {
        var request = sender.request(contentType: "nanoHandshake", userInitiated: true)
        request["workflow"] = .string(workflow)
        request["handshake"] = .string(description)
        // A Windows file time: 100-nanosecond steps since 1601. Must be an Int64, and larger
        // than the one before.
        request["sequenceNumber"] = .int64(Int64((now.timeIntervalSince1970 + 11_644_473_600) * 10_000_000))
        request["correlationVector"] = .string(transferId)
        return request
    }

    /// Receives a share the phone offered on the Phone Link session: asks the phone, on that
    /// session, to listen for a direct connection, then fetches the files over it.
    public func receive(offer: LegacyFileOffer, messenger: PeerMessenger, sender: AppSender) async {
        guard !busy else { return }
        busy = true
        cancelRequested = false
        defer { busy = false }
        continuation.yield(.started)
        diag("files", "offer on the Phone Link session: \(offer.items.count) files; asking the phone to listen")
        do {
            // Better said now than after minutes of receiving.
            let total = UInt64(clamping: offer.items.reduce(Int64(0)) { $0 + max(0, $1.size) })
            if let directory = connectionSettings.blobDirectory, !NanoBlobAssembler.hasRoom(for: total, in: directory) {
                throw NanoFileReceiver.ReceiveError.noRoom
            }
            let opened = try await connector.open(messenger: messenger, sender: sender, workflow: NanoFileReceiver.workflowName, transferId: offer.transferId,
                                                  settings: connectionSettings, tag: "files")
            try await receive(over: opened.connection) { receiver in try await receiver.run(offer: offer) }
        } catch {
            report(error, "share")
        }
    }

    // MARK: Sending to the phone

    /// Sends files to the phone: asks it, on the Phone Link session, to listen for a direct
    /// connection, then offers the files over it and sends each one the phone asks for.
    /// The outcome arrives on `updates`.
    public func send(_ files: [OutgoingFile], messenger: PeerMessenger, sender: AppSender) async {
        guard !files.isEmpty else { return }
        guard !busy else {
            continuation.yield(.failed("Another transfer is still running."))
            return
        }
        busy = true
        cancelRequested = false
        defer { busy = false }
        continuation.yield(.sendStarted(names: files.map(\.name), totalBytes: files.reduce(0) { $0 + $1.size }))
        diag("files", "sending \(files.count) files, \(files.reduce(0) { $0 + $1.size }) bytes; asking the phone to listen")
        do {
            // Windows names a transfer with a new GUID.
            let transferId = UUID().uuidString.lowercased()
            let opened: (connection: NanoConnection, way: NanoConnector.Way)
            do {
                opened = try await connector.open(messenger: messenger, sender: sender, workflow: NanoFileReceiver.workflowName, transferId: transferId,
                                                  settings: connectionSettings, tag: "files")
            } catch NanoSignalling.SignallingError.refused("workflowInProgress") {
                throw NanoFileSender.SendError.busy
            }
            let count = try await with(opened.connection) { [senderName, continuation] connection in
                let sender = NanoFileSender(connection: connection, senderName: senderName) { progress in
                    switch progress {
                    case .sending(let name, let sent, let total): continuation.yield(.sending(name: name, sent: sent, total: total))
                    case .sent(let name): continuation.yield(.sent(name: name))
                    }
                }
                return try await sender.run(files: files, transferId: transferId)
            }
            continuation.yield(.sendFinished(count: count))
            diag("files", "sent: the phone confirmed \(count) of \(files.count) files")
        } catch {
            report(error, "sending")
        }
    }

    /// Fetches one file of the phone's storage, the way a share arrives: a direct connection
    /// is asked for on this session, and the file comes over it. Its progress and its end
    /// are reported like a share's.
    public func fetch(_ file: NanoFileReceiver.Wanted) async {
        guard let signalling else {
            continuation.yield(.failed("Receiving files is switched off in Settings."))
            return
        }
        guard !busy else {
            continuation.yield(.failed("Another transfer is still running."))
            return
        }
        busy = true
        cancelRequested = false
        defer { busy = false }
        continuation.yield(.started)
        do {
            let contract = try await signalling.requestDirectConnection()
            try await receive(over: contract) { receiver in try await receiver.fetch(file) }
        } catch {
            report(error, "download")
        }
    }

    private func receiveShare() async {
        // One share at a time: the phone also refuses a second one while the first runs.
        guard !busy, let signalling else { return }
        busy = true
        cancelRequested = false
        defer { busy = false }
        continuation.yield(.started)
        do {
            let contract = try await signalling.requestDirectConnection()
            try await receive(over: contract) { receiver in try await receiver.run() }
        } catch {
            report(error, "share")
        }
    }

    /// Opens the direct connection the phone described, trying each of its reachable
    /// addresses, and runs the share over it.
    private func receive(over contract: NanoDirectContract, _ run: @Sendable (NanoFileReceiver) async throws -> [ReceivedFile]) async throws {
        try await receive(over: try await openDirect(contract), run)
    }

    /// Runs a share over an open connection and closes it.
    private func receive(over connection: NanoConnection, _ run: @Sendable (NanoFileReceiver) async throws -> [ReceivedFile]) async throws {
        let files = try await with(connection) { [senderName, continuation] connection in
            let receiver = NanoFileReceiver(connection: connection, senderName: senderName) { progress in
                switch progress {
                case .offered(let names, let total): continuation.yield(.offered(names: names, totalBytes: total))
                case .receiving(let name, let received, let total): continuation.yield(.receiving(name: name, received: received, total: total))
                case .received(let file): continuation.yield(.received(file))
                }
            }
            return try await run(receiver)
        }
        continuation.yield(.finished(count: files.count))
        diag("files", "share complete: \(files.count) files, \(files.reduce(0) { $0 + $1.size }) bytes")
    }

    /// Opens the direct connection the phone described, trying each of its reachable addresses.
    private func openDirect(_ contract: NanoDirectContract) async throws -> NanoConnection {
        diag("files", "the phone listens on \(contract.addresses.map(\.interface).joined(separator: ",")), \(contract.candidates.count) reachable candidates")
        for host in contract.candidates {
            do {
                let connection = try await PhoneFileReceiver.open(host: host, port: contract.port, keys: contract.keys, settings: connectionSettings, makeTransport: makeTransport)
                diag("files", "direct connection open; waiting for the phone's channels")
                return connection
            } catch NanoConnection.ConnectionError.noAnswer {
                // This address did not answer; the phone may have another.
                continue
            }
        }
        throw NanoConnection.ConnectionError.noAnswer
    }

    /// Runs the work over an open connection and closes it, whatever the outcome.
    private func with<Result: Sendable>(_ connection: NanoConnection, _ work: @Sendable (NanoConnection) async throws -> Result) async throws -> Result {
        active = connection
        defer { active = nil }
        let result: Result
        do {
            // Stopped while the connection was still being set up.
            if cancelRequested { throw CancellationError() }
            result = try await work(connection)
        } catch {
            await connection.close()
            throw error
        }
        await connection.close()
        return result
    }

    static let blockedExplanation = "macOS did not let Phone Mac Link use the local network. Allow Phone Mac Link under System Settings › Privacy & Security › Local Network, then try again."

    /// Opens a socket to the phone and runs the start sequence over it. When macOS shuts the
    /// socket at once, which it does while it checks the app's access to the local network,
    /// a fresh one is tried a few times before giving up.
    static func open(host: String, port: UInt16, keys: NanoSessionKeys, settings: NanoConnection.Settings,
                     makeTransport: @Sendable (_ host: String, _ port: UInt16) async throws -> NanoDatagramTransport) async throws -> NanoConnection {
        var attempt = 0
        while true {
            attempt += 1
            let transport = try await makeTransport(host, port)
            let connection = NanoConnection(transport: transport, keys: keys, settings: settings)
            do {
                try await connection.start()
                return connection
            } catch NanoSocketTransport.SocketError.blocked where attempt < 4 {
                await connection.close()
                diag("nano", "the system shut the socket before the first packet (try \(attempt)); it may be checking local network access")
                try await Task.sleep(for: .milliseconds(1500))
            } catch {
                await connection.close()
                throw error
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case NanoSocketTransport.SocketError.blocked: return blockedExplanation
        case NanoSignalling.SignallingError.noAnswer: return "The phone did not say how to reach it."
        case NanoSignalling.SignallingError.refused: return "The phone refused the connection."
        case NanoConnection.ConnectionError.noAnswer: return "The phone could not be reached, neither on this network nor over the internet."
        case NanoFileReceiver.ReceiveError.refused: return "The phone refused the file transfer."
        case NanoFileReceiver.ReceiveError.connectionLost: return "The connection to the phone was lost during the transfer."
        case NanoFileReceiver.ReceiveError.timedOut: return "The transfer took too long."
        case NanoFileReceiver.ReceiveError.cancelled: return "The share was cancelled on the phone."
        case NanoFileReceiver.ReceiveError.noRoom: return "There is not enough free space on this Mac for what the phone is sharing."
        case NanoFileSender.SendError.busy: return "The phone is busy with another transfer."
        case NanoFileSender.SendError.cancelled: return "The transfer was cancelled on the phone."
        case NanoFileSender.SendError.connectionLost: return "The connection to the phone was lost during the transfer."
        case NanoFileSender.SendError.timedOut: return "The transfer took too long."
        case NanoFileSender.SendError.unreadable(let name): return "\(name) could not be read to the end."
        case NanoFileSender.SendError.unknownFile: return "The phone asked for a file that was not offered."
        case PeerMessenger.MessagingError.timedOut: return "The phone did not answer the request for a connection."
        default: return "The file could not be received."
        }
    }
}
