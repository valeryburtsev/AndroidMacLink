import Foundation

/// The state of the content features for one phone. It outlives a single connection, so after
/// a reconnect the phone is asked only for what changed.
public struct PhoneFeatures: Sendable {
    public let messages: MessageSync
    public let photos: PhotoSync
    public let notifications: NotificationSync
    public let contacts: ContactSync
    public let apps: AppCatalogSync
    public let calls: CallLogSync?

    public init(messages: MessageSync, photos: PhotoSync, notifications: NotificationSync, contacts: ContactSync, apps: AppCatalogSync,
                calls: CallLogSync? = nil) {
        self.calls = calls
        self.messages = messages
        self.photos = photos
        self.notifications = notifications
        self.contacts = contacts
        self.apps = apps
    }
}

/// One client role's live session with one phone: the relay connection, presence, and the
/// features that role owns. Windows runs two of these side by side, one per client type, and
/// so do we: the phone offers notifications to a `PL` client and the clipboard to a `WEA` one.
public actor RoleSession {
    public struct Dependencies: Sendable {
        public var http: HTTPTransport
        public var webSockets: WebSocketConnector
        public var instance: ClientInstance
        public var displayName: String
        public var installationId: String
        public var localClipboard: LocalClipboard?
        public var ownStatus: @Sendable () async -> DeviceStatusSync.OwnStatus
        public var timing = PhoneConnection.Timing()
        public var baseURL = DCGClient.productionBaseURL
        /// Where to keep a phone's messages between launches, by the phone's ID; nil keeps
        /// them in memory only.
        public var messageCache: (@Sendable (_ phoneId: String) -> BlobCache?)?
        /// The same for a phone's photo list and thumbnails.
        public var photoCache: (@Sendable (_ phoneId: String) -> BlobCache?)?
        /// The same for a phone's contacts.
        public var contactCache: (@Sendable (_ phoneId: String) -> BlobCache?)?
        /// The same for a phone's app list and icons.
        public var appCache: (@Sendable (_ phoneId: String) -> BlobCache?)?
        /// The same for a phone's call history.
        public var callCache: (@Sendable (_ phoneId: String) -> BlobCache?)?
        /// Whether to sync the call history, asked at each connect. Off unless the user
        /// turned it on: it flips a phone-wide switch, and no capture confirms the exchange.
        public var callLogsEnabled: @Sendable () -> Bool = { false }
        /// Whether the clipboard is shared, asked at each connect.
        public var clipboardEnabled: @Sendable () -> Bool = { true }
        /// Whether files the phone shares are taken, asked at each connect.
        public var filesEnabled: @Sendable () -> Bool = { false }
        /// Where files from the phone are written while they arrive. Without it they are
        /// held in memory, which limits their size.
        public var incomingFilesDirectory: URL?
        /// Run before a phone's content state is opened for a connection.
        public var prepareForConnect: (@Sendable () async -> Void)?

        public init(http: HTTPTransport, webSockets: WebSocketConnector, instance: ClientInstance, displayName: String, installationId: String,
                    localClipboard: LocalClipboard? = nil, ownStatus: @escaping @Sendable () async -> DeviceStatusSync.OwnStatus = { .init() }) {
            self.http = http
            self.webSockets = webSockets
            self.instance = instance
            self.displayName = displayName
            self.installationId = installationId
            self.localClipboard = localClipboard
            self.ownStatus = ownStatus
        }
    }

    public nonisolated let identity: IdentityService
    public nonisolated let peer: PeerDevice
    private let dependencies: Dependencies
    private let features: PhoneFeatures?
    public private(set) var connection: PhoneConnection?
    public private(set) var clipboard: ClipboardSync?
    public private(set) var notifications: NotificationSync?
    public private(set) var status: DeviceStatusSync?
    /// The phone's files as a list to browse; on the cross-device session.
    public private(set) var storage: PhoneFilesSync?
    public private(set) var photos: PhotoSync?
    public private(set) var messages: MessageSync?
    public private(set) var contacts: ContactSync?
    public private(set) var apps: AppCatalogSync?
    public private(set) var calls: CallLogSync?
    public private(set) var files: PhoneFileReceiver?

    /// What a transfer started from this side signs its requests with.
    private var fileSender: AppSender?

    /// The permission the phone needs before it takes files from a PC.
    static let sharedContentPermission: Int32 = 0x400

    public enum FileSendError: Error, Equatable {
        case notConnected
        /// Link to Windows may not store files on the phone; the phone was asked to allow it.
        case needsPermission
    }

    /// Sends files to the phone over a direct connection. Returns once the transfer has
    /// ended either way; progress and outcome arrive on the file updates.
    public func sendFiles(_ outgoing: [OutgoingFile]) async throws {
        guard let files, let fileSender, let messenger = connection?.messenger else { throw FileSendError.notConnected }
        if phoneInfo?.permissions["shared_content"] == false {
            // As Phone Link does: ask once, quietly, whether it has been granted meanwhile.
            let granted = (try? await notifications?.requestPermission(RoleSession.sharedContentPermission, silent: true)) ?? false
            if !granted { throw FileSendError.needsPermission }
        }
        await files.send(outgoing, messenger: messenger, sender: fileSender)
    }

    /// Shows the phone's screen; created with the Phone Link session.
    public private(set) var mirror: PhoneScreenMirror?

    /// Starts mirroring the phone's screen. Returns when it has ended; progress, frames and
    /// the outcome arrive on the mirror's updates.
    public func mirrorScreen(options: NanoMirrorSession.Options = .init(), frameSink: (@Sendable (NanoVideoFrame) -> Void)? = nil) async throws {
        guard let mirror, let fileSender, let messenger = connection?.messenger else { throw FileSendError.notConnected }
        await mirror.start(messenger: messenger, sender: fileSender, options: options, frameSink: frameSink)
    }

    /// Presses a notification's button over a short connection of the phone-screen kind, as
    /// Phone Link does. Not while the phone's screen is being shown: the phone runs one such
    /// connection at a time.
    public func pressNotificationButton(key: String, actionIndex: Int) async throws -> NotificationLaunch.Outcome {
        guard let fileSender, let messenger = connection?.messenger else { throw FileSendError.notConnected }
        if await mirror?.isRunning == true { throw NotificationLaunch.LaunchError.screenInUse }
        let connector = NanoConnector(makeTransport: { host, port in try NanoSocketTransport(host: host, port: port) },
                                      relayServers: { [weak self] in await self?.relayServers() })
        let opened = try await connector.open(messenger: messenger, sender: fileSender, workflow: NotificationLaunch.workflow, transferId: UUID().uuidString.lowercased(),
                                              settings: NanoConnection.Settings(), tag: "notify")
        do {
            let outcome = try await NotificationLaunch.press(over: opened.connection, key: key, actionIndex: actionIndex)
            await opened.connection.close()
            return outcome
        } catch {
            await opened.connection.close()
            throw error
        }
    }

    /// Stops a file transfer that is running on this session, in either direction.
    public func cancelFileTransfer() async {
        await files?.cancel()
    }

    /// How a connection for files stores them: on disk when the app named a folder, and then
    /// with the disk as the only limit on size.
    static func fileSettings(_ dependencies: Dependencies) -> NanoConnection.Settings {
        var settings = NanoConnection.Settings()
        if let directory = dependencies.incomingFilesDirectory {
            settings.blobDirectory = directory
            settings.blobLimit = 1 << 40
        }
        return settings
    }

    public private(set) var phoneInfo: ConnectExchange.PhoneInfo?
    public private(set) var peerCapabilities: SessionValidation.PeerCapabilities?

    /// - Parameter features: the phone's content state to carry on with; without it this
    ///   session starts from nothing.
    public init(identity: IdentityService, peer: PeerDevice, dependencies: Dependencies, features: PhoneFeatures? = nil) {
        self.identity = identity
        self.peer = peer
        self.dependencies = dependencies
        self.features = features
    }

    public nonisolated var clientType: String { identity.clientType }

    /// Opens the relay, brings the phone online and starts this role's features.
    /// - Parameter stillWanted: asked before each step that touches shared state; a session
    ///   that was replaced while it connected stops there.
    public func connect(stillWanted: @Sendable () async -> Bool = { true }) async throws -> PhoneConnection {
        guard let ownId = await identity.deviceId else { throw IdentityService.IdentityError.notEnrolled }
        diag("session", "\(clientType) \(ownId.prefix(8)) opening relay for phone \(peer.id.prefix(8))")
        let hub = try await openHub()
        guard !Task.isCancelled, await stillWanted() else {
            await hub.close()
            throw CancellationError()
        }
        do {
            try await hub.start()
        } catch {
            await hub.close()
            throw error
        }
        guard !Task.isCancelled, await stillWanted() else {
            await hub.close()
            throw CancellationError()
        }
        diag("session", "\(clientType) hub handshake done")
        let identity = identity
        let peerId = peer.id
        let connection = PhoneConnection(hub: hub, peer: peerId, ownId: ownId, timing: dependencies.timing) { region, highPriority in
            diag("session", "\(identity.clientType) waking phone, region \(region ?? "unknown"), high priority \(highPriority)")
            try await identity.wake(peer: peerId, hubRegion: region, highPriority: highPriority)
        }
        self.connection = connection
        do {
            try await connection.connect()
        } catch {
            await connection.close()
            self.connection = nil
            throw error
        }
        // The features are shared with whatever session replaces this one: do not attach
        // them to a connection that is no longer wanted.
        guard !Task.isCancelled, await stillWanted() else {
            await connection.close()
            self.connection = nil
            throw CancellationError()
        }
        diag("session", "\(clientType) phone is online, starting features")
        try await startFeatures(connection, ownId: ownId)
        diag("session", "\(clientType) features started")
        return connection
    }

    /// The servers that help a connection find its way when the phone is on another network,
    /// and the account for the relay among them. Asked of the service each time: the account
    /// lasts about a week.
    func relayServers() async -> NanoRelayServers? {
        let client = DCGClient(baseURL: dependencies.baseURL, profile: identity.profile, instance: dependencies.instance, transport: dependencies.http)
        do {
            let answer: CloudRelayResponse
            do {
                answer = try await client.cloudRelay(dcgToken: try await identity.dcgToken())
            } catch let error as DCGError where error == .http(status: 401) || { if case .service(401, _, _, _) = error { return true } else { return false } }() {
                answer = try await client.cloudRelay(dcgToken: try await identity.signIn())
            }
            guard let servers = NanoRelayServers(answer) else {
                diag("session", "the service named no relay")
                return nil
            }
            return servers
        } catch {
            diag("session", "the helping servers could not be asked for: \(type(of: error))")
            return nil
        }
    }

    /// Negotiates the relay with the role's token; a refused token is renewed once.
    private func openHub() async throws -> HubConnection {
        let connector = RelayConnector(baseURL: dependencies.baseURL, profile: identity.profile, instance: dependencies.instance,
                                       http: dependencies.http, webSockets: dependencies.webSockets)
        do {
            return try await connector.connect(dcgToken: try await identity.dcgToken(), partnerId: peer.id)
        } catch RelayConnector.ConnectError.http(_, 401) {
            return try await connector.connect(dcgToken: try await identity.signIn(), partnerId: peer.id)
        }
    }

    private func startFeatures(_ connection: PhoneConnection, ownId: String) async throws {
        let profile = identity.profile
        if profile.receivesFiles, profile.clientType == ClientProfile.crossDevice.clientType {
            // Shares from the phone: announced on this session, received over a direct connection.
            let signalling = NanoSignalling(messenger: connection.messenger, resources: connection.resources, ownId: ownId, peerId: peer.id)
            let files = PhoneFileReceiver(signalling: signalling, senderName: dependencies.displayName, connectionSettings: RoleSession.fileSettings(dependencies),
                                          relayServers: { [weak self] in await self?.relayServers() })
            await files.start()
            self.files = files
        }
        if profile.offersClipboard {
            let status = DeviceStatusSync(resources: connection.resources, publisher: connection.publisher, ownStatus: dependencies.ownStatus)
            await status.start()
            self.status = status
            // Nothing is asked of the phone until the user wants to see its files.
            storage = await PhoneFilesSync(resources: connection.resources, publisher: connection.publisher)
            if let local = dependencies.localClipboard {
                // Once the link has settled, so that the phone counts it as active.
                let clipboard = ClipboardSync(resources: connection.resources, publisher: connection.publisher, local: local, rewatchAfter: .seconds(3))
                try await clipboard.start(enabled: dependencies.clipboardEnabled())
                self.clipboard = clipboard
            }
            // Informational exchanges: do not hold up the session if the phone is slow to answer.
            Task { [weak self] in
                let capabilities = try? await SessionValidation.exchange(with: connection.messenger)
                await self?.record(capabilities)
                _ = try? await status.refresh()
            }
        }
        if profile.receivesNotifications {
            let notifications = features?.notifications ?? NotificationSync(displayName: dependencies.displayName, appVersion: profile.appVersion,
                                                                            installationId: dependencies.installationId)
            let sender = AppSender(displayName: dependencies.displayName, appVersion: profile.appVersion, installationId: dependencies.installationId)
            let photos = features?.photos ?? PhotoSync(sender: sender)
            let messages = features?.messages ?? MessageSync(sender: sender)
            let contacts = features?.contacts ?? ContactSync()
            let apps = features?.apps ?? AppCatalogSync()
            // Only with the feature on; otherwise the phone's unasked call log pushes are
            // answered "nothing wanted" like any other unused content.
            let calls = dependencies.callLogsEnabled() ? features?.calls : nil
            await calls?.attach(connection.messenger)
            await photos.attach(connection.messenger)
            await messages.attach(connection.messenger)
            // A share toward the Phone Link client is offered on this session, as content.
            // Sending to the phone always goes through this session; receiving only while wanted.
            let transfers = self.files ?? PhoneFileReceiver(signalling: nil, senderName: dependencies.displayName, connectionSettings: RoleSession.fileSettings(dependencies),
                                                            relayServers: { [weak self] in await self?.relayServers() })
            self.files = transfers
            fileSender = sender
            if mirror == nil { mirror = PhoneScreenMirror(relayServers: { [weak self] in await self?.relayServers() }) }
            let legacyFiles: PhoneFileReceiver? = dependencies.filesEnabled() ? transfers : nil
            let offerMessenger = connection.messenger
            // The phone uses one route for every kind of content; hand each kind to its owner.
            await notifications.attach(connection.messenger) { _, values in
                switch values.string("contentType") {
                case PhotoSync.contentType: return await photos.apply(values)
                case MessageSync.contentType: return await messages.apply(values)
                case ContactSync.contentType: return await contacts.apply(values)
                case AppCatalogSync.contentType: return await apps.apply(values)
                case CallLogSync.contentType: return await calls?.apply(values)
                case "fileTransfer":
                    guard let legacyFiles, let offer = values.string("fileTransferFileDetail").flatMap(LegacyFileOffer.init(json:)) else { return nil }
                    // Accepted; the files are fetched over a direct connection, apart from this answer.
                    Task { await legacyFiles.receive(offer: offer, messenger: offerMessenger, sender: sender) }
                    return ValueSet(["result": .int32(0)])
                default: return nil
                }
            }
            self.notifications = notifications
            self.photos = photos
            self.messages = messages
            self.contacts = contacts
            self.apps = apps
            self.calls = calls
        }
    }

    /// Sends the start-of-session exchange: tells the phone what this client supports and
    /// holds, after which the phone pushes the message history it is missing.
    @discardableResult
    public func performConnect() async throws -> ConnectExchange.PhoneInfo {
        guard let connection, let messages, let photos else { throw PhoneConnection.ConnectionError.closed }
        let sender = AppSender(displayName: dependencies.displayName, appVersion: identity.profile.appVersion, installationId: dependencies.installationId)
        // What we hold of each content type; the phone then sends only what is newer.
        var numbers = await messages.sequenceNumbers
        numbers["media_info"] = await photos.sequenceNumber
        if let contacts { numbers.merge(await contacts.sequenceNumbers) { $1 } }
        if let apps { numbers.merge(await apps.sequenceNumbers) { $1 } }
        if let calls { numbers[CallLogSync.sequenceKey] = await calls.sequenceNumber }
        let info = try await ConnectExchange.perform(with: connection.messenger, sender: sender, sequenceNumbers: numbers, callLogs: calls != nil)
        phoneInfo = info
        // A phone whose numbering went backwards was reset; start over next time.
        if await messages.reconcile(phoneNumbers: info.sequenceNumbers, sent: numbers) {
            diag("session", "the phone's message numbering started over; cached messages dropped")
        }
        if await photos.reconcile(phoneNumber: info.sequenceNumbers["media_info"], sent: numbers["media_info"]) {
            diag("session", "the phone's photo numbering started over; cached photos dropped")
        }
        if let contacts, await contacts.reconcile(phoneNumbers: info.sequenceNumbers, sent: numbers) {
            diag("session", "the phone's contact numbering started over; cached contacts dropped")
        }
        if let apps, await apps.reconcile(phoneNumbers: info.sequenceNumbers, sent: numbers) {
            diag("session", "the phone's app numbering started over; cached apps dropped")
        }
        if let calls, await calls.reconcile(phoneNumber: info.sequenceNumbers[CallLogSync.sequenceKey], sent: numbers[CallLogSync.sequenceKey]) {
            diag("session", "the phone's call log numbering started over; cached calls dropped")
        }
        return info
    }

    private func record(_ capabilities: SessionValidation.PeerCapabilities?) {
        peerCapabilities = capabilities
    }

    public func close() async {
        await connection?.close()
        connection = nil
        clipboard = nil
        notifications = nil
        status = nil
        storage = nil
        photos = nil
        messages = nil
        contacts = nil
        apps = nil
        calls = nil
        files = nil
    }

    public var state: PhoneConnection.State {
        get async { await connection?.state ?? .idle }
    }
}
