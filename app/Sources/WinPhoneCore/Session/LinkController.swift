import Foundation

/// The whole client: account, one identity per role, pairing, and the sessions with the phone.
/// The interface drives it through its methods and watches `events`.
public actor LinkController {
    public enum Event: Sendable {
        case signedOut
        case signingIn(code: String, url: String, expires: Date)
        case signedIn(accountName: String?)
        case pairing(PairingStep, sessionId: String)
        case phones([PeerDevice])
        case connecting(PeerDevice)
        case connected(PeerDevice, role: String)
        case disconnected(PeerDevice, role: String, error: String?)
        case notification(NotificationSync.Change)
        case notificationAccess(granted: Bool)
        /// Whether Android is hiding sensitive notifications from Link to Windows.
        case sensitiveNotifications(hidden: Bool)
        /// Whether Link to Windows itself may use Bluetooth on the phone (Android's "Nearby
        /// devices"). Without it the phone takes no hotspot request, and says nothing.
        case phoneBluetoothAccess(granted: Bool)
        case clipboardReceived(ClipboardContent)
        case phoneStatus(PhoneStatus)
        /// The phone is ringing at our request until the given time; nil when it stopped.
        /// The phone does not report the end, so this is our own countdown.
        case ringing(until: Date?)
        /// Whether the phone offers to be rung from here.
        case canRingPhone(Bool)
        /// The phone's apps by package name, for their icons.
        case apps([String: PhoneApp])
        /// The phone's contacts, for putting names to addresses.
        case contacts(ContactBook)
        /// Text conversations, most recent first.
        case conversations([Conversation])
        /// Whether the phone lets Link to Windows read and send texts.
        case messagingAccess(granted: Bool)
        /// A share from the phone: its start, its progress, each file, its end.
        case fileTransfer(PhoneFileReceiver.Update)
        /// The phone's screen: progress, frames of video, the end.
        case screen(PhoneScreenMirror.Update)
        /// The phone's files as a list to browse: how far it is, the list, the free space.
        case storage(PhoneFilesSync.Update)
        /// A phone was unlinked; nothing of it should stay on screen.
        case phoneRemoved(id: String)
        /// The phone's call history, newest first.
        case calls([PhoneCall])
        /// Whether the phone lets Link to Windows read the call log.
        case callLogAccess(granted: Bool)
        /// The phone's recent photos, newest first.
        case photos([PhonePhoto])
        /// The phone has not been given access to photos.
        case photoAccess(granted: Bool)
        case failed(String)
    }

    public enum ControllerError: Error, Equatable {
        case noPhoneLinked
        case busy
    }

    public struct Reconnect: Sendable {
        public var initialDelay: Duration = .seconds(5)
        public var maxDelay: Duration = .seconds(60)
        public init() {}
    }

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let vault: StateVault
    private let account: AccountSession
    private let identities: [IdentityService]
    private let dcg: DCGClient
    private let dependencies: RoleSession.Dependencies
    private let reconnect: Reconnect
    private var sessions: [String: RoleSession] = [:]
    private var runners: [String: Task<Void, Never>] = [:]
    /// Tasks relaying one session's events, ended with that session. Keyed by the session
    /// itself, not its role: an old session winding down must not touch its replacement's.
    private var forwarders: [ObjectIdentifier: [Task<Void, Never>]] = [:]
    /// The phone the sessions are with.
    private var currentPhoneId: String?
    private var signInTask: Task<Void, Error>?
    private var pairingTask: Task<Void, Error>?
    private var pairingSessionId: String?
    private var pairingCoordinator: PairingCoordinator?
    private var reconnecting = false
    private var features: [String: PhoneFeatures] = [:]
    /// Tasks relaying a phone's content updates, by phone; they live as long as its state.
    private var featureForwarders: [String: [Task<Void, Never>]] = [:]
    private var ringTimer: Task<Void, Never>?
    private var ringGeneration = 0
    private var signInStarting = false
    private var lastStatus: PhoneStatus?
    private var pairingStarting = false

    /// - Parameters:
    ///   - roles: the client roles to run. Both by default, as Windows does.
    public init(vault: StateVault, msa: MicrosoftAccount, dependencies: RoleSession.Dependencies,
                roles: [ClientProfile] = [.crossDevice, .phoneLink], reconnect: Reconnect = Reconnect()) async {
        self.vault = vault
        self.dependencies = dependencies
        self.reconnect = reconnect
        let account = AccountSession(account: msa, vault: vault)
        self.account = account
        let instance = await vault.clientInstance
        dcg = DCGClient(baseURL: dependencies.baseURL, profile: .phoneLink, instance: instance, transport: dependencies.http)
        identities = roles.map { profile in
            IdentityService(profile: profile, client: DCGClient(baseURL: dependencies.baseURL, profile: profile, instance: instance, transport: dependencies.http),
                            account: account, vault: vault, displayName: dependencies.displayName)
        }
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
    }

    // MARK: Lifecycle

    /// Reports the current state and, when signed in with a phone, connects.
    public func start() async {
        guard await vault.state.isSignedIn else { return emit(.signedOut) }
        emit(.signedIn(accountName: await vault.state.accountName))
        await showSavedContent()
        await connectIfPossible()
    }

    /// Publishes what the last run kept for the phone this client uses: messages, photos,
    /// contacts, apps and calls, read from this computer alone. The service takes seconds to
    /// list the phones at a start; what is already here need not wait for it.
    private func showSavedContent() async {
        guard let phone = await preferredPhone(), features[phone.id] == nil else { return }
        // The caches cannot be opened without their key.
        await dependencies.prepareForConnect?()
        _ = featureState(for: phone)
    }

    private func emitQuietly(_ event: Event) {
        continuation.yield(event)
    }

    private func emit(_ event: Event) {
        diag("event", LinkController.summary(of: event))
        continuation.yield(event)
    }

    /// One line per event for the diagnostics log, without any user content.
    static func summary(of event: Event) -> String {
        switch event {
        case .signedOut: return "signed out"
        case .signingIn: return "waiting for sign-in"
        case .signedIn: return "signed in"
        case .pairing(let step, _): return "pairing: \(name(of: step))"
        case .phones(let phones): return "phones: \(phones.count) [" + phones.map { "\($0.id.prefix(8)) \($0.clientType) linked=\($0.isLinked)" }.joined(separator: ", ") + "]"
        case .connecting(let phone): return "connecting to \(phone.id.prefix(8))"
        case .connected(_, let role): return "connected (\(role))"
        case .disconnected(_, let role, let error): return "disconnected (\(role)): \(error ?? "phone left or relay closed")"
        case .notification(.upsert(_, let alert)): return "notification upsert alert=\(alert)"
        case .notification(.removed): return "notification removed"
        case .notification(.accessChanged(let granted)): return "notification access \(granted)"
        case .notificationAccess(let granted): return "notification access \(granted)"
        case .sensitiveNotifications(let hidden): return "sensitive notifications hidden \(hidden)"
        case .phoneBluetoothAccess(let granted): return "the phone app's own Bluetooth access \(granted)"
        case .notification(.sensitiveAccessChanged(let granted)): return "sensitive notification access \(granted)"
        case .notification(.bluetoothAccessChanged(let granted)): return "the phone app's own Bluetooth access \(granted)"
        case .notification(.statusReported): return "status on a push"
        case .notification(.appContexts(let contexts)): return "app contexts from the phone, \(contexts.count)"
        case .clipboardReceived: return "clipboard received"
        case .storage(.state(let state)):
            switch state {
            case .idle: return "phone files: nothing asked"
            case .loading(let received, _): return "phone files: \(received) so far"
            case .ready: return "phone files: list here"
            case .needsPermission: return "phone files: the phone has not allowed it"
            case .failed: return "phone files: failed"
            }
        case .storage(.files(let files)): return "phone files: \(files.count) entries"
        case .storage(.storage): return "phone files: free space"
        case .phoneStatus: return "phone status"
        case .ringing(let until): return until == nil ? "ring ended" : "ringing the phone"
        case .canRingPhone(let supported): return "ring my phone supported \(supported)"
        case .conversations(let list): return "conversations: \(list.count), \(list.reduce(0) { $0 + $1.messages.count }) messages, \(list.reduce(0) { $0 + $1.pending.count }) sending"
        case .messagingAccess(let granted): return "messaging access \(granted)"
        case .contacts(let book): return "contacts: \(book.contacts.count)"
        case .apps(let apps): return "apps: \(apps.count), \(apps.values.filter { $0.icon != nil }.count) with icons"
        case .fileTransfer(let update):
            // Never a file name.
            switch update {
            case .started: return "file share announced"
            case .offered(let names, let total): return "file share offer: \(names.count) files, \(total) bytes"
            case .receiving: return "file share: receiving"
            case .received(let file): return "file received, \(file.size) bytes"
            case .finished(let count): return "file share finished, \(count) files"
            // The reason may name a file; the "files" lines of the log say what went wrong.
            case .failed: return "file transfer failed"
            case .sendStarted(let names, let total): return "sending files: \(names.count) files, \(total) bytes"
            case .sending: return "sending files: in progress"
            case .sent: return "file sent"
            case .sendFinished(let count): return "sending finished, \(count) files confirmed"
            case .cancelled: return "file transfer stopped here"
            }
        case .screen(let update):
            switch update {
            case .connecting: return "phone screen: connecting"
            case .waitingForPermission: return "phone screen: the phone is asking for permission"
            case .started(let format): return "phone screen: video \(format.width) x \(format.height)"
            case .inputSize(let width, let height): return "phone screen: input \(width) x \(height)"
            case .rotation(let turns): return "phone screen: turned by \(turns) quarter turns"
            case .frame: return "phone screen: frame"
            case .soundStarted(let format): return "phone screen: sound, \(format.channels) channels at \(format.sampleRate) Hz"
            case .sound: return "phone screen: sound frame"
            case .locked(let locked): return "phone screen: phone locked \(locked)"
            case .protectedContent(let protected): return "phone screen: protected app \(protected)"
            case .ended: return "phone screen: ended"
            // The reason is one of this program's own sentences.
            case .failed(let reason): return "phone screen failed: \(reason)"
            }
        case .phoneRemoved(let id): return "phone removed \(id.prefix(8))"
        case .calls(let calls): return "calls: \(calls.count)"
        case .callLogAccess(let granted): return "call log access \(granted)"
        case .photos(let photos): return "photos: \(photos.count), \(photos.filter { $0.thumbnail != nil }.count) with thumbnails"
        case .photoAccess(let granted): return "photo access \(granted)"
        case .failed(let message): return "failed: \(message)"
        }
    }

    /// The step's name alone: its values include the PINs.
    static func name(of step: PairingStep) -> String {
        switch step {
        case .showLink: return "show link"
        case .confirmChallengePIN: return "confirm challenge PIN"
        case .challengePINProblem(let expired): return expired ? "challenge PIN expired" : "challenge PIN rejected"
        case .enterPairingPIN: return "enter pairing PIN"
        case .approvePermissionsOnPhone: return "approve permissions on phone"
        case .completing: return "completing"
        case .paired: return "paired"
        case .failed(let failure): return "failed (\(failure))"
        }
    }

    // MARK: Account

    /// Runs the device-code sign-in and then connects. Returns once the user has signed in.
    public func signIn() async throws {
        // Claimed before the first suspension, so a second click cannot start a second poll.
        guard signInTask == nil, !signInStarting else { throw ControllerError.busy }
        signInStarting = true
        defer { signInStarting = false }
        let code = try await account.beginSignIn()
        emit(.signingIn(code: code.userCode, url: code.verificationURI, expires: Date().addingTimeInterval(TimeInterval(code.expiresIn))))
        let task = Task { [account] in try await account.finishSignIn(code) }
        signInTask = task
        defer { signInTask = nil }
        do {
            try await task.value
        } catch is CancellationError {
            emit(.signedOut)
            return
        } catch {
            emit(.failed(LinkController.describe(error)))
            throw error
        }
        emit(.signedIn(accountName: await vault.state.accountName))
        await connectIfPossible()
    }

    public func cancelSignIn() {
        signInTask?.cancel()
    }

    public func signOut() async {
        await disconnect()
        cancelPairing()
        for state in features.values {
            await state.messages.reset()
            await state.photos.reset()
            await state.contacts.reset()
            await state.apps.reset()
            await state.calls?.reset()
        }
        for tasks in featureForwarders.values { for task in tasks { task.cancel() } }
        featureForwarders.removeAll()
        currentPhoneId = nil
        features.removeAll()
        lastStatus = nil
        try? await account.signOut()
        emit(.signedOut)
    }

    // MARK: Pairing

    /// Links a new phone. Reports each step through `events` and connects when paired.
    public func pair(flow: PairingFlow = .qrCode) async throws {
        guard pairingTask == nil, !pairingStarting else { throw ControllerError.busy }
        pairingStarting = true
        defer { pairingStarting = false }
        // The phone looks the PC up in the device list after pairing, so enroll first.
        for identity in identities { try await identity.ensureReady() }
        let coordinator = PairingCoordinator(client: dcg) { [account] in try await account.token() }
        pairingCoordinator = coordinator
        // The task is awaited below, so holding self strongly cannot outlive this call.
        let task = Task { [self] in
            let final = try await coordinator.run(flow: flow) { step, session in
                await self.pairingStep(step, session)
            }
            if case .paired = final { await self.paired() }
        }
        pairingTask = task
        defer { pairingTask = nil; pairingSessionId = nil; pairingCoordinator = nil }
        do {
            try await task.value
        } catch is CancellationError {
            return
        } catch {
            emit(.failed(LinkController.describe(error)))
            throw error
        }
    }

    private func pairingStep(_ step: PairingStep, _ session: PairingSessionResponse) {
        pairingSessionId = session.pairingSessionId
        emit(.pairing(step, sessionId: session.pairingSessionId))
    }

    private func paired() async {
        // The new phone appears in the device list; a wake from an unknown sender would make
        // the phone refresh its own list, but we refresh ours first so trust is in place.
        await connectIfPossible()
    }

    public func refreshChallengePIN() async throws {
        guard let coordinator = pairingCoordinator, let id = pairingSessionId else { return }
        let session = try await coordinator.refreshChallengePIN(sessionId: id)
        pairingStep(session.step, session)
    }

    public func cancelPairing() {
        pairingTask?.cancel()
    }

    // MARK: Phones

    /// Enrolls every role, refreshes the phones and connects to the chosen one.
    public func connectIfPossible() async {
        await connectIfPossible(networkTries: 0)
    }

    /// Whether an error is the network's doing (no connection, a connection that dropped, a
    /// name that did not resolve) and so worth another try by itself.
    static func isNetworkTrouble(_ error: Error) -> Bool {
        (error as NSError).domain == NSURLErrorDomain
    }

    /// How long to wait before trying again after the network failed this many times in a row.
    static func networkRetryWait(after tries: Int) -> Duration {
        let seconds = [1, 2, 5, 10, 30]
        return .seconds(tries < seconds.count ? seconds[tries] : 60)
    }

    private func connectIfPossible(networkTries: Int) async {
        do {
            var phones: [PeerDevice] = []
            for identity in identities { phones = try await identity.ensureReady() }
            emit(.phones(phones))
            guard let phone = await selectedPhone(phones) else { return }
            await connect(to: phone)
        } catch MicrosoftAccount.SignInError.reauthorizationRequired {
            emit(.signedOut)
        } catch {
            // With sessions up or retrying, a refresh that failed (say, the network is not
            // back yet after sleep) is no reason to leave the interface; they carry on.
            if !runners.isEmpty {
                diag("session", "refresh failed, sessions carry on: \(type(of: error))")
                return
            }
            // A connection that dropped on the way to the service, or no network yet after
            // waking: tried again by itself, ever more slowly, instead of stopping at an
            // error (seen on 2026-10-12: one request lost at launch ended on the error page).
            if LinkController.isNetworkTrouble(error) {
                let wait = LinkController.networkRetryWait(after: networkTries)
                diag("session", "the service could not be reached (network error \((error as NSError).code)); trying again in \(wait.components.seconds) s")
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                return await connectIfPossible(networkTries: networkTries + 1)
            }
            emit(.failed(LinkController.describe(error)))
        }
    }

    /// Drops the current sessions and connects afresh, for when the old sockets are known to
    /// be dead: after sleep, or when the network returned. Does nothing while signed out, while
    /// pairing, or when another reconnect is already under way.
    public func reconnect(reason: String) async {
        guard await vault.state.isSignedIn, pairingTask == nil, !reconnecting else { return }
        reconnecting = true
        defer { reconnecting = false }
        diag("session", "reconnecting (\(reason))")
        await connectIfPossible()
    }

    private func selectedPhone(_ phones: [PeerDevice]) async -> PeerDevice? {
        let linked = phones.filter(\.isLinked)
        let selected = await vault.state.selectedPeerId
        return linked.first { $0.id == selected } ?? linked.first
    }

    /// The phones of the account, as last synced.
    public func linkedPhones() async -> [PeerDevice] {
        await vault.state.peers.filter(\.isPhone)
    }

    /// The phone this client connects to: the one the user chose, else the first linked one.
    public func preferredPhone() async -> PeerDevice? {
        await selectedPhone(await linkedPhones())
    }

    /// Makes a linked phone the one this client talks to, now and at later starts, and
    /// connects to it in place of the current one.
    public func select(phone id: String) async {
        try? await vault.update { $0.selectedPeerId = id }
        await connectIfPossible()
    }

    /// Opens one session per role and keeps each alive until `disconnect`.
    public func connect(to phone: PeerDevice) async {
        await disconnect()
        emit(.connecting(phone))
        currentPhoneId = phone.id
        // For the app to have what the caches need, such as their key after a new sign-in.
        await dependencies.prepareForConnect?()
        let features = featureState(for: phone)
        for identity in identities {
            let session = RoleSession(identity: identity, peer: phone, dependencies: dependencies,
                                      features: identity.profile.receivesNotifications ? features : nil)
            sessions[identity.clientType] = session
            runners[identity.clientType] = Task { [weak self] in await self?.keepAlive(session) }
        }
    }

    /// The content state for a phone, created on first use and kept for the whole run. Its
    /// updates are forwarded from here, once, however often the connection is rebuilt.
    private func featureState(for phone: PeerDevice) -> PhoneFeatures {
        if let existing = features[phone.id] { return existing }
        let sender = AppSender(displayName: dependencies.displayName, installationId: dependencies.installationId)
        let state = PhoneFeatures(messages: MessageSync(sender: sender, cache: dependencies.messageCache?(phone.id)),
                                  photos: PhotoSync(sender: sender, cache: dependencies.photoCache?(phone.id)),
                                  notifications: NotificationSync(displayName: dependencies.displayName, installationId: dependencies.installationId),
                                  contacts: ContactSync(cache: dependencies.contactCache?(phone.id)),
                                  apps: AppCatalogSync(cache: dependencies.appCache?(phone.id)),
                                  calls: CallLogSync(sender: sender, cache: dependencies.callCache?(phone.id)))
        featureForwarders[phone.id, default: []].append(Task { [weak self] in
            for await apps in state.apps.updates { await self?.emit(.apps(apps)) }
        })
        featureForwarders[phone.id, default: []].append(Task { [weak self] in
            for await book in state.contacts.updates { await self?.emit(.contacts(book)) }
        })
        if let calls = state.calls {
            featureForwarders[phone.id, default: []].append(Task { [weak self] in
                for await list in calls.updates { await self?.emit(.calls(list)) }
            })
        }
        features[phone.id] = state
        featureForwarders[phone.id, default: []].append(Task { [weak self] in
            for await change in state.notifications.changes {
                if case .accessChanged(let granted) = change {
                    await self?.emit(.notificationAccess(granted: granted))
                    // Newly granted: fetch what is already on the phone.
                    if granted { try? await state.notifications.reconcile() }
                } else if case .sensitiveAccessChanged(let granted) = change {
                    await self?.emit(.sensitiveNotifications(hidden: !granted))
                } else if case .bluetoothAccessChanged(let granted) = change {
                    await self?.emit(.phoneBluetoothAccess(granted: granted))
                } else if case .statusReported(let values) = change {
                    await self?.statusReported(values)
                } else {
                    await self?.emit(.notification(change))
                }
            }
        })
        featureForwarders[phone.id, default: []].append(Task { [weak self] in
            for await list in state.messages.updates { await self?.emit(.conversations(list)) }
        })
        featureForwarders[phone.id, default: []].append(Task { [weak self] in
            for await list in state.photos.updates {
                await self?.emit(.photos(list))
                // Fill in the first screens of thumbnails ahead of scrolling.
                let missing = list.prefix(96).filter { $0.thumbnail == nil && !$0.thumbnailUnavailable }.map(\.id)
                if !missing.isEmpty { Task { try? await state.photos.loadThumbnails(for: missing) } }
            }
        })
        // What was kept from the last run shows at once, before the phone is reached.
        Task {
            await state.contacts.republish()
            await state.apps.republish()
            if dependencies.callLogsEnabled() { await state.calls?.republish() }
            await state.messages.republish()
            await state.photos.republish()
        }
        return state
    }

    private func keepAlive(_ session: RoleSession) async {
        var delay = reconnect.initialDelay
        var failures = 0
        while !Task.isCancelled {
            do {
                let connection = try await session.connect { [weak self] in await self?.isCurrent(session) ?? false }
                // Replaced while connecting: do not announce a session nobody wants.
                if Task.isCancelled || !isCurrent(session) {
                    await session.close()
                    return
                }
                delay = reconnect.initialDelay
                failures = 0
                emit(.connected(session.peer, role: session.clientType))
                await forward(session)
                // Stay until the phone leaves or the relay closes, then reconnect with a wake.
                for await state in connection.states where state == .offline || state == .closed { break }
                endForwarding(for: session)
                await session.close()
                if Task.isCancelled || !isCurrent(session) { return }
                emit(.disconnected(session.peer, role: session.clientType, error: nil))
            } catch {
                endForwarding(for: session)
                await session.close()
                if Task.isCancelled || !isCurrent(session) { return }
                failures += 1
                diag("session", "\(session.clientType) attempt \(failures) failed: \(error); retry in \(delay)")
                if let dcgError = error as? DCGError, dcgError.isDeviceUnlinked {
                    runnerGaveUp(session)
                    emit(.failed("The phone was unlinked from the account."))
                    return
                }
                if case MicrosoftAccount.SignInError.reauthorizationRequired = error {
                    runnerGaveUp(session)
                    emit(.signedOut)
                    return
                }
                // A phone that is simply off is retried quietly; persistent trouble is reported.
                if failures == 1 || failures % 5 == 0 {
                    emit(.disconnected(session.peer, role: session.clientType, error: LinkController.describe(error)))
                }
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, reconnect.maxDelay)
        }
    }

    /// Relays feature events of a freshly connected session to `events`.
    /// The phone's status as last heard on either session: the cross-device one reports it
    /// in full, and every content push to the Phone Link one carries most of it.
    private func report(_ status: PhoneStatus) {
        // The full status of the cross-device session says nothing of the hotspot set-up;
        // what the Phone Link session has heard about it is kept.
        var status = status
        if status.hotspot == nil { status.hotspot = lastStatus?.hotspot }
        guard status != lastStatus else { return }
        lastStatus = status
        emit(.phoneStatus(status))
    }

    private func statusReported(_ values: ValueSet) {
        if let status = PhoneStatus(push: values, base: lastStatus) {
            // A push while the phone was taken to be holding back: it may be on Wi-Fi again,
            // which only its full status says.
            let wasPaused = lastStatus?.isSyncPausedOnMobileData == true
            report(status)
            if wasPaused {
                Task { for session in self.sessions.values { if let sync = await session.status { _ = try? await sync.refresh() } } }
            }
        } else if var status = lastStatus, let allowed = values.bool("syncOverMeteredConnection") {
            // The setting was changed on the phone, or a request was refused for it. A refusal
            // also says where the phone is: on a network it counts as metered.
            status.syncOverMobileData = allowed
            if values.bool(NotificationSync.meteredNowKey) == true { status.network = .cellular }
            report(status)
        } else if var status = lastStatus, status.applyHotspot(values) {
            // The user answered the phone's question about its hotspot.
            report(status)
        }
    }

    private func endForwarding(for session: RoleSession) {
        for task in forwarders.removeValue(forKey: ObjectIdentifier(session)) ?? [] { task.cancel() }
    }

    /// Whether this session is still the one in use for its role. A session that was replaced
    /// while it was connecting must not announce itself, attach the shared features to its
    /// own connection, or end anything that belongs to its successor.
    private func isCurrent(_ session: RoleSession) -> Bool {
        sessions[session.clientType] === session
    }

    /// A runner that gives up for good takes itself off the list of live ones.
    private func runnerGaveUp(_ session: RoleSession) {
        guard isCurrent(session) else { return }
        runners.removeValue(forKey: session.clientType)
    }

    private func forward(_ session: RoleSession) async {
        let key = ObjectIdentifier(session)
        if await session.messages != nil {
            // The handshake Phone Link sends first: what this client supports and holds. The
            // phone then pushes whatever is newer. It runs beside the other features so a slow
            // answer holds nothing up.
            forwarders[key, default: []].append(Task { [weak self] in
                do {
                    let info = try await session.performConnect()
                    diag("session", "connect reply: result \(info.result.map { "\($0)" } ?? "none"), permissions \(info.permissions.filter(\.value).keys.sorted().joined(separator: ","))")
                    await self?.emit(.messagingAccess(granted: info.messagingAllowed))
                    await self?.emit(.photoAccess(granted: info.photosAllowed))
                    if await session.calls != nil { await self?.emit(.callLogAccess(granted: info.callLogAllowed)) }
                    if let allowed = info.permissions["notification_sensitive"] { await self?.emit(.sensitiveNotifications(hidden: !allowed)) }
                    if let allowed = info.permissions["bluetooth"] { await self?.emit(.phoneBluetoothAccess(granted: allowed)) }
                    await self?.emit(.canRingPhone((info.capabilities["ringMyPhoneCapabilities"] ?? 0) & 1 != 0))
                    diag("session", "phone sequence numbers: " + (MessageSync.sequenceKeys + ["media_info"]).map { "\($0)=\(info.sequenceNumbers[$0].map(String.init) ?? "absent")" }.joined(separator: " "))
                    // The phone starts the photo list by itself after the handshake. If it has
                    // not after a while, ask for it outright.
                    try? await Task.sleep(for: .seconds(30))
                    if info.photosAllowed, let photos = await session.photos, await photos.sequenceNumber < 0 {
                        diag("photos", "no list after the handshake; asking for it")
                        try await photos.refresh()
                    }
                } catch {
                    diag("session", "connect exchange failed: \(error)")
                }
            })
        }
        if let notifications = await session.notifications {
            // Beside the other features: a phone that is busy may take long to answer, and a
            // late answer is no reason to hold up or fail the connection.
            forwarders[key, default: []].append(Task { [weak self] in
                do {
                    // As Phone Link does: ask about the permission, then bring the list up to
                    // date. The phone answers with what is new and what is gone.
                    let granted = (try? await notifications.checkAccess()) ?? true
                    await self?.emit(.notificationAccess(granted: granted))
                    if granted { try await notifications.reconcile() }
                } catch NotificationSync.CommandError.needsPermission {
                    await self?.emit(.notificationAccess(granted: false))
                } catch {
                    diag("session", "notification sync could not start: \(error)")
                }
            })
        }
        if let status = await session.status {
            forwarders[key, default: []].append(Task { [weak self] in
                for await update in status.updates { await self?.report(update) }
            })
        }
        if let mirror = await session.mirror {
            forwarders[key, default: []].append(Task { [weak self] in
                for await update in mirror.updates {
                    // Frames come many a second; the log gets the milestones only.
                    switch update {
                    case .frame, .sound: await self?.emitQuietly(.screen(update))
                    default: await self?.emit(.screen(update))
                    }
                }
            })
        }
        if let files = await session.files {
            forwarders[key, default: []].append(Task { [weak self] in
                for await update in files.updates {
                    // Progress is frequent; the log gets the milestones only.
                    switch update {
                    case .receiving, .sending: await self?.emitQuietly(.fileTransfer(update))
                    default: await self?.emit(.fileTransfer(update))
                    }
                }
            })
        }
        if let clipboard = await session.clipboard {
            forwarders[key, default: []].append(Task { [weak self] in
                for await content in clipboard.received { await self?.emit(.clipboardReceived(content)) }
            })
        }
        if let storage = await session.storage {
            forwarders[key, default: []].append(Task { [weak self] in
                for await update in storage.updates {
                    // The count goes up batch by batch; the log gets the milestones only.
                    if case .state(.loading(let received, _)) = update, received > 0 {
                        await self?.emitQuietly(.storage(update))
                    } else {
                        await self?.emit(.storage(update))
                    }
                }
            })
        }
    }

    // MARK: The phone's hotspot

    public static let hotspotSetupRoute = "/hotspotsetupnotificationrequest"
    public static let hotspotDataRoute = "/hotspotdevicedatasyncrequest"

    /// Has the phone ask its user whether computers may switch its hotspot on: it opens the
    /// Link to Windows settings there, or shows a notification that leads to them. The
    /// answer arrives later with the phone's status.
    public func requestHotspotSetup() async throws {
        guard let connection = await sessions[ClientProfile.phoneLink.clientType]?.connection else { throw PhoneControlError.notConnected }
        // The phone is told first that this computer's own part of the set-up is done:
        // without that it lets its user agree and then says "Complete setup on your PC"
        // (seen on 2026-10-11). Phone Link sends the same after its set-up pages.
        var done = LinkController.hotspotSetupRequest(from: controls.sender)
        done["isuserinitiated"] = .bool(false)
        done["HotspotCompletedFTU"] = .bool(true)
        let told = try? await connection.messenger.appRequest(route: LinkController.hotspotDataRoute, payload: done.serialized(),
                                                               trace: TraceContext(scenarioId: "InstantHotspot", triggerId: "HotspotCompletedFTU"), timeout: .seconds(10))
        diag("hotspot", "told the phone that the set-up on this side is done: \(told == nil ? "no answer" : "result \((try? ValueSet(serialized: told!.payload))?.int("result").map(String.init) ?? "none")")")
        do {
            let envelope = try await connection.messenger.appRequest(route: LinkController.hotspotSetupRoute, payload: LinkController.hotspotSetupRequest(from: controls.sender).serialized(),
                                                                     trace: TraceContext(scenarioId: "InstantHotspot", triggerId: "SendNotificationRequest"), timeout: .seconds(20))
            // 0 where the phone showed its settings or a notification; anything else where it could not.
            let result = (try? ValueSet(serialized: envelope.payload))?.int("result")
            diag("hotspot", "the phone answered the set-up request with result \(result.map(String.init) ?? "none")")
            if let result, result != 0 { throw PhoneControlError.unsupported }
        } catch PeerMessenger.MessagingError.rejected {
            throw PhoneControlError.unsupported
        } catch PeerMessenger.MessagingError.timedOut {
            throw PhoneControlError.noAnswer
        }
    }

    /// The set-up request as Phone Link's client library sends any request of this kind: the
    /// one value of its own among the fields every such request carries. The phone reads the
    /// contract version of every request before anything else and does not answer one
    /// without it (seen on 2026-10-11: a bare request got no answer in 20 s, three times).
    static func hotspotSetupRequest(from sender: AppSender) -> ValueSet {
        var values = sender.request(contentType: "", userInitiated: true)
        values.entries.removeValue(forKey: "contentType")
        return values
    }

    /// A signed request for the phone's hotspot service, to be carried to the phone over
    /// Bluetooth by whoever asks, and the means to read the answer. Made with the Phone Link
    /// identity, which is the one the phone's hotspot service knows.
    /// - Parameter crossDevice: sign as the cross-device identity instead: the phone trusts
    ///   both, and which of them its hotspot service answers is not known from its code alone.
    public func hotspotExchange(_ kind: HotspotExchange.Kind, crossDevice: Bool = false) async throws -> HotspotExchange {
        let role = crossDevice ? ClientProfile.crossDevice.clientType : ClientProfile.phoneLink.clientType
        guard let session = sessions[role] else { throw PhoneControlError.notConnected }
        return try await session.identity.hotspotExchange(peer: session.peer.id, kind: kind)
    }

    // MARK: The phone's files

    private var storage: PhoneFilesSync? {
        get async {
            for session in sessions.values { if let sync = await session.storage { return sync } }
            return nil
        }
    }

    /// Asks the phone for the list of its files, when the user wants to see them.
    /// - Returns: false when no session that could ask is connected.
    @discardableResult
    public func loadPhoneFiles(again: Bool = false) async -> Bool {
        guard let storage = await storage else { return false }
        await storage.load(again: again)
        return true
    }

    /// Fetches one of the phone's files to this computer. How it goes is reported as file
    /// transfer events, like a share from the phone.
    /// - Returns: false when no session that could fetch it is connected.
    @discardableResult
    public func downloadPhoneFile(_ file: PhoneFile) async -> Bool {
        guard !file.isDirectory, !file.uri.isEmpty else { return false }
        for session in sessions.values {
            guard await session.storage != nil, let receiver = await session.files else { continue }
            await receiver.fetch(NanoFileReceiver.Wanted(uri: file.uri, name: file.name, size: file.size))
            return true
        }
        return false
    }

    /// A small picture of one of the phone's files, as JPEG bytes.
    public func phoneFilePreview(_ file: PhoneFile, side: Int = 256) async throws -> Data {
        guard let storage = await storage else { throw PhoneControlError.notConnected }
        return try await storage.thumbnail(of: file, side: side)
    }

    public func disconnect() async {
        for runner in runners.values { runner.cancel() }
        runners.removeAll()
        for tasks in forwarders.values { for task in tasks { task.cancel() } }
        forwarders.removeAll()
        // Taken out of the list first, so a session still connecting sees it was replaced.
        let ending = Array(sessions.values)
        sessions.removeAll()
        for session in ending { await session.close() }
        if ringTimer != nil {
            ringTimer?.cancel()
            ringTimer = nil
            emit(.ringing(until: nil))
        }
    }

    /// Unlinks the phone from the account and forgets our identities, as the service does.
    public func unlink(phone: PeerDevice) async throws {
        await disconnect()
        try await identities.first?.unlink(peer: phone.id)
        // Nothing of that phone's content stays, in memory or on disk, whether or not it was
        // connected in this run: opening its state is what finds its cache files.
        let state = featureState(for: phone)
        await state.messages.reset()
        await state.photos.reset()
        await state.contacts.reset()
        await state.apps.reset()
        await state.calls?.reset()
        features.removeValue(forKey: phone.id)
        for task in featureForwarders.removeValue(forKey: phone.id) ?? [] { task.cancel() }
        lastStatus = nil
        if currentPhoneId == phone.id { currentPhoneId = nil }
        try? await vault.update { $0.peers.removeAll { $0.id == phone.id } }
        emit(.phoneRemoved(id: phone.id))
        // Carry on with another linked phone, or report that none is left.
        await connectIfPossible()
    }

    // MARK: Features

    private var notifications: NotificationSync? {
        get async {
            for session in sessions.values { if let sync = await session.notifications { return sync } }
            return nil
        }
    }

    private var clipboard: ClipboardSync? {
        get async {
            for session in sessions.values { if let sync = await session.clipboard { return sync } }
            return nil
        }
    }

    private var photos: PhotoSync? {
        get async {
            for session in sessions.values { if let sync = await session.photos { return sync } }
            return nil
        }
    }

    private var messages: MessageSync? {
        get async {
            for session in sessions.values { if let sync = await session.messages { return sync } }
            return nil
        }
    }

    /// Sends a text in an existing conversation, or to new recipients when `threadId` is nil.
    public func sendMessage(_ body: String, threadId: Int64?, recipients: [String] = [], attachments: [OutgoingAttachment] = []) async throws {
        // Between connections the phone's lasting state takes the message, so that it shows,
        // as failed, instead of vanishing.
        var target = await messages
        if target == nil, let id = currentPhoneId { target = features[id]?.messages }
        guard let target else { throw PhoneConnection.ConnectionError.closed }
        try await target.send(body, threadId: threadId, recipients: recipients, attachments: attachments)
    }

    public func markConversationRead(threadId: Int64, through date: Date) async throws {
        try await messages?.markRead(threadId: threadId, through: date)
    }

    /// Has the phone describe the attachments of a picture message it only counted before.
    public func describeAttachments(ofMessage id: Int64) async throws {
        guard let messages = await messages else { throw PhoneConnection.ConnectionError.closed }
        try await messages.describeAttachments(of: id)
    }

    /// The bytes of a picture-message attachment, fetched from the phone when not at hand.
    public func attachmentData(partId: Int64) async throws -> Data {
        guard let messages = await messages else { throw PhoneConnection.ConnectionError.closed }
        return try await messages.attachmentData(partId: partId)
    }

    public func discardFailedMessage(id: Int64) async { await messages?.discardFailed(id: id) }
    public func resyncMessages() async throws { _ = try await messages?.resync() }

    public func refreshPhotos() async throws { try await photos?.refresh() }
    /// Deletes a photo from the phone. Irreversible; the interface asks first.
    public func deletePhoto(id: Int64) async throws {
        guard let photos = await photos else { throw PhoneConnection.ConnectionError.closed }
        try await photos.delete(ids: [id])
    }
    public func loadThumbnails(for ids: [Int64]) async throws { try await photos?.loadThumbnails(for: ids) }
    public func fetchPhoto(id: Int64) async throws -> FetchedPhoto {
        guard let photos = await photos else { throw PhotoSync.PhotoError.notFound }
        return try await photos.fetchImage(id: id)
    }

    /// Whether Link to Windows holds a permission, asked without anything showing on the
    /// phone: it answers from what it has.
    public func phoneHolds(permission type: Int32) async throws -> Bool {
        guard let notifications = await notifications else { throw PhoneConnection.ConnectionError.closed }
        return try await notifications.requestPermission(type, silent: true)
    }

    /// Makes the phone ask its user to let Link to Windows use Bluetooth itself, as Phone
    /// Link does when calls are set up. Where part of that is allowed already, Android
    /// grants the rest without a question. Returns once the phone has answered.
    @discardableResult
    public func requestPhoneBluetoothAccess() async throws -> Bool {
        guard let notifications = await notifications else { throw PhoneConnection.ConnectionError.closed }
        let granted = try await notifications.requestPermission(NotificationSync.bluetoothPermission, silent: false)
        emit(.phoneBluetoothAccess(granted: granted))
        return granted
    }

    /// Makes the phone ask its user to let Link to Windows show notifications that Android
    /// hides as sensitive. Returns once the user has answered on the phone.
    @discardableResult
    public func requestSensitiveNotificationAccess() async throws -> Bool {
        guard let notifications = await notifications else { throw PhoneConnection.ConnectionError.closed }
        let granted = try await notifications.requestPermission(NotificationSync.sensitiveNotificationPermission, silent: false)
        emit(.sensitiveNotifications(hidden: !granted))
        return granted
    }

    public func dismiss(notificationKey key: String) async throws { try await notifications?.dismiss(key: key) }
    /// Clears the given notifications on the phone, or all of them when `keys` is nil.
    public func clearNotifications(keys: [String]? = nil) async throws { try await notifications?.clear(keys: keys) }
    public func openOnPhone(notificationKey key: String) async throws { try await notifications?.openOnPhone(key: key) }
    public func invoke(_ action: PhoneNotification.Action, notificationKey key: String) async throws {
        // As Phone Link presses a button on a phone that shows its apps: over a short
        // connection of the phone-screen kind. This phone refuses the plain command for it.
        if let session = mirrorSession {
            do {
                let outcome = try await session.pressNotificationButton(key: key, actionIndex: action.index)
                diag("notify", "button pressed over the phone-screen connection: \(outcome)")
                if case .failed = outcome { throw NotificationSync.CommandError.failed(nil) }
                return
            } catch NotificationSync.CommandError.failed {
                // The phone tried and could not: the plain command is the other way.
            } catch NotificationLaunch.LaunchError.screenInUse {
                // The plain command may do; where it does not, the reason to tell is this one.
                do { try await notifications?.invoke(action: action, key: key) } catch { throw NotificationLaunch.LaunchError.screenInUse }
                return
            } catch {
                diag("notify", "the phone-screen way did not work (\(type(of: error)): \(error is NotificationLaunch.LaunchError || error is RoleSession.FileSendError ? "\(error)" : "")); trying the plain command")
            }
        }
        try await notifications?.invoke(action: action, key: key)
    }
    public func reply(_ text: String, notificationKey key: String, action: PhoneNotification.Action) async throws {
        try await notifications?.reply(text, to: key, action: action)
    }
    public func setClipboardSync(_ enabled: Bool) async throws { try await clipboard?.setEnabled(enabled) }

    // MARK: Calls

    private var calls: CallLogSync? {
        get async {
            for session in sessions.values { if let sync = await session.calls { return sync } }
            return nil
        }
    }

    /// Asks the phone for its call history again.
    public func refreshCalls() async throws {
        guard let calls = await calls else { throw CallLogSync.CallError.notConnected }
        try await calls.refresh()
    }

    /// Sends files to the phone, where they land in Downloads under "Received from PC".
    /// Returns when the transfer has ended; progress and outcome come as file-transfer events.
    public func sendFiles(_ files: [OutgoingFile]) async throws {
        guard let session = sessions[ClientProfile.phoneLink.clientType] ?? sessions.values.first else { throw RoleSession.FileSendError.notConnected }
        try await session.sendFiles(files)
    }

    // MARK: Phone screen

    /// Tries the way over the internet against the real servers, without the phone
    /// (`IceSelfTest`). Returns a line for the log.
    public func relaySelfTest() async -> String {
        guard let session = sessions[ClientProfile.phoneLink.clientType] ?? sessions.values.first else { return "not connected" }
        guard let servers = await session.relayServers() else { return "the service gave no servers" }
        return await IceSelfTest.run(servers: servers)
    }

    private var mirrorSession: RoleSession? { sessions[ClientProfile.phoneLink.clientType] ?? sessions.values.first }

    /// Shows the phone's screen. Returns when mirroring has ended; what happens arrives as
    /// screen events.
    public func mirrorScreen(options: NanoMirrorSession.Options = .init(), frameSink: (@Sendable (NanoVideoFrame) -> Void)? = nil) async throws {
        guard let session = mirrorSession else { throw RoleSession.FileSendError.notConnected }
        try await session.mirrorScreen(options: options, frameSink: frameSink)
    }

    public func screenGesture(_ gesture: NanoMirrorSession.Gesture) async {
        await mirrorSession?.mirror?.gesture(gesture)
    }

    public func screenWake() async {
        await mirrorSession?.mirror?.wake()
    }

    public func screenKey(_ usage: UInt8, pressed: Bool) async {
        await mirrorSession?.mirror?.key(usage, pressed: pressed)
    }

    public func stopMirroring() async {
        for session in sessions.values { await session.mirror?.stop() }
    }

    /// The size of the phone's screen for pointer positions, while it is mirrored.
    public func screenInputSize() async -> (width: Int, height: Int)? {
        await mirrorSession?.mirror?.inputSize()
    }

    public func screenPointer(x: Int, y: Int, pressed: Bool, rightPressed: Bool = false, middlePressed: Bool = false, wheelX: Int = 0, wheelY: Int = 0) async {
        await mirrorSession?.mirror?.pointer(x: x, y: y, pressed: pressed, rightPressed: rightPressed, middlePressed: middlePressed, wheelX: wheelX, wheelY: wheelY)
    }

    /// Stops the file transfer that is running, whichever way it goes.
    public func cancelFileTransfer() async {
        for session in sessions.values { await session.cancelFileTransfer() }
    }

    /// Opens the phone's dialer with the number filled in; the user presses call there.
    public func dialOnPhone(_ number: String) async throws {
        guard let connection = await sessions[ClientProfile.phoneLink.clientType]?.connection else { throw CallLogSync.CallError.notConnected }
        // The phone serves this whether or not the call history is synced.
        let dialer = CallLogSync(sender: AppSender(displayName: dependencies.displayName, installationId: dependencies.installationId))
        await dialer.attach(connection.messenger)
        try await dialer.dial(number)
    }

    /// Applies a change of the call history switch: ends the sessions, drops the history
    /// when it was switched off, and connects again so the phone learns the new setting.
    /// In that order, so that no push of the old session lands in a history just emptied.
    public func callHistorySettingChanged() async {
        await disconnect()
        if !dependencies.callLogsEnabled() {
            for state in features.values { await state.calls?.reset() }
        }
        guard await vault.state.isSignedIn, pairingTask == nil else { return }
        await connectIfPossible()
    }

    // MARK: Device controls

    /// The connection of the Phone Link role, which Windows uses for every control; any other
    /// when that role is not up, since the phone does not look at who asks.
    private var controlConnection: PhoneConnection? {
        get async {
            if let connection = await sessions[ClientProfile.phoneLink.clientType]?.connection { return connection }
            for session in sessions.values { if let connection = await session.connection { return connection } }
            return nil
        }
    }

    private var controls: DeviceControls {
        DeviceControls(sender: AppSender(displayName: dependencies.displayName, installationId: dependencies.installationId))
    }

    /// Makes the phone ring so it can be found: vibration, then the alarm sound at full
    /// volume, for twenty seconds. Calling it again while ringing extends the ring.
    public func ringPhone() async throws {
        guard let connection = await controlConnection else { throw PhoneControlError.notConnected }
        try await DeviceControls.ring(true, through: connection.resources)
        ringTimer?.cancel()
        ringGeneration += 1
        let generation = ringGeneration
        emit(.ringing(until: Date().addingTimeInterval(TimeInterval(DeviceControls.ringDuration.components.seconds))))
        ringTimer = Task { [weak self] in
            try? await Task.sleep(for: DeviceControls.ringDuration)
            if !Task.isCancelled { await self?.ringEnded(generation) }
        }
    }

    /// Ends the countdown, unless the ring was started again in the meantime.
    private func ringEnded(_ generation: Int) {
        guard generation == ringGeneration else { return }
        ringTimer = nil
        emit(.ringing(until: nil))
    }

    /// Stops a ring started with `ringPhone`. Harmless when nothing is ringing.
    public func stopRinging() async throws {
        guard let connection = await controlConnection else { throw PhoneControlError.notConnected }
        // If this fails the phone is still ringing, so the countdown is left running.
        try await DeviceControls.ring(false, through: connection.resources)
        ringTimer?.cancel()
        ringEnded(ringGeneration)
    }

    public func setRinger(_ ringer: PhoneStatus.Ringer) async throws { try await change(.ringer(ringer)) }
    public func setDoNotDisturb(_ on: Bool) async throws { try await change(.doNotDisturb(on)) }

    /// Lets the phone sync while it is on mobile data, or stops that. The setting lives on the
    /// phone and is the same for every computer it is linked to.
    public func setSyncOverMobileData(_ on: Bool) async throws {
        guard let connection = await controlConnection else { throw PhoneControlError.notConnected }
        try await controls.setSyncOverMobileData(on, through: connection.messenger)
        // The phone reports the change only when it is made on the phone itself.
        if var status = lastStatus {
            status.syncOverMobileData = on
            report(status)
        }
        for session in sessions.values { if let sync = await session.status { Task { _ = try? await sync.refresh() } } }
    }

    /// Changes the ringer or Do Not Disturb. The request that answers with the new state is
    /// tried first; a phone without it gets the command Phone Link sends, whose effect arrives
    /// as a status update.
    private func change(_ setting: DeviceStatusSync.Setting) async throws {
        var status: DeviceStatusSync?
        for session in sessions.values { if let sync = await session.status { status = sync } }
        if let status {
            do {
                try await status.apply(setting)
                return
            } catch PhoneControlError.unsupported {
                diag("controls", "the phone has no status update handler; using the command route")
            } catch PhoneControlError.noAnswer {
                // No capture shows Windows sending this request; the command below is the
                // one Phone Link is known to build.
                diag("controls", "no answer to the status update; using the command route")
            }
        }
        guard let connection = await controlConnection else { throw PhoneControlError.notConnected }
        switch setting {
        case .ringer(let ringer): try await controls.setRinger(ringer, through: connection.messenger)
        case .doNotDisturb(let on): try await controls.setDoNotDisturb(on, through: connection.messenger)
        }
        // The command does not say what happened; ask instead of waiting for the next report.
        if let status { Task { _ = try? await status.refresh() } }
    }

    /// Presses a media key for whatever plays behind a media notification.
    public func media(_ command: MediaCommand, notificationKey key: String) async throws {
        guard let connection = await sessions[ClientProfile.phoneLink.clientType]?.connection else { throw PhoneControlError.notConnected }
        try await controls.media(command, notificationKey: key, through: connection.messenger)
    }
    /// - Returns: What was offered to the phone, or nil when nothing was.
    @discardableResult
    public func localClipboardChanged() async throws -> ClipboardContent? { try await clipboard?.localClipboardChanged() }

    // MARK: Helpers

    /// A sentence for the interface.
    public static func describe(_ error: Error) -> String {
        switch error {
        case let error as DCGError:
            switch error {
            case .service(let status, let code, let message, _): return "Service error \(status) \(code ?? ""): \(message ?? "")"
            case .http(let status): return "Service answered HTTP \(status)"
            case .malformedResponse(let detail): return "Unexpected answer from the service: \(detail)"
            }
        case MicrosoftAccount.SignInError.reauthorizationRequired: return "Please sign in again."
        case MicrosoftAccount.SignInError.expired: return "The sign-in code expired."
        case MicrosoftAccount.SignInError.declined: return "The sign-in was declined."
        case PhoneConnection.ConnectionError.phoneUnreachable: return "The phone did not answer."
        case let error as PhoneControlError: return error.explanation
        case CallLogSync.CallError.needsPermission: return "Link to Windows is not allowed to read the call log. Check its permissions on the phone."
        case CallLogSync.CallError.notConnected: return "The phone is not connected."
        case CallLogSync.CallError.noAnswer: return "The phone did not answer."
        case CallLogSync.CallError.failed: return "The phone could not do that."
        case NotificationSync.CommandError.needsAppearOnTop:
            return "Check your phone: Link to Windows asks to be allowed to appear on top, which it needs to press a notification's button for you. Allow it there (Settings › Apps › Link to Windows › Appear on top), then try the button again."
        case NotificationLaunch.LaunchError.screenInUse:
            return "The phone cannot press a notification's button while its screen is shown here. Close the phone's screen and try again, or press the button in the picture."
        case NotificationSync.CommandError.cannotStartInBackground:
            return "The phone could not press that button: Link to Windows failed to start it in the background, though it has every permission for it. Restarting the phone, or Link to Windows on it, usually clears this. The button still works on the phone itself."
        case NotificationSync.CommandError.needsPermission: return "Link to Windows needs notification access on the phone for this. Check the phone."
        case NotificationSync.CommandError.failed: return "The phone could not do that. The notification may be gone there already."
        case PhotoSync.PhotoError.needsPermission: return "Link to Windows is not allowed to do that with photos. Check its permissions on the phone."
        case PhotoSync.PhotoError.notFound: return "The phone could not find the photo."
        case PhotoSync.PhotoError.failed: return "The phone could not do that."

        case let error where isNetworkTrouble(error):
            // In plain words, with the system's number for whoever wants to look it up.
            return "Microsoft's service could not be reached. Check this Mac's internet connection. (Network error \((error as NSError).code))"
        case let error as LocalizedError: return error.errorDescription ?? String(describing: error)
        default: return String(describing: error)
        }
    }
}
