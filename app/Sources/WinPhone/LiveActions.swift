import AppKit
import CryptoKit
import Foundation
import Network
import IOBluetooth
import WinPhoneCore

/// The real backend: drives `LinkController` and mirrors its events into the interface, the
/// pasteboard and Notification Center.
@MainActor
final class LiveActions: AppActions {
    private let model: AppModel
    private let bluetoothCalls = BluetoothCalls()
    private let hotspotWatch = HotspotWatch()
    private let bluetoothAccess = BluetoothAccess()
    private var relaySelfTestRun = false
    private var batteryAlerts = BatteryAlerts()
    private var callPanel: CallPanelController?
    private let notifier = MacNotifier()
    private let clipboard = MacClipboard()
    private var controller: LinkController?
    private var eventTask: Task<Void, Never>?
    private var clipboardWatch: Task<Void, Never>?
    private var connectedRoles: Set<String> = []
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var wantedThumbnails: Set<Int64> = []
    private var thumbnailFlush: Task<Void, Never>?
    private var phoneName = ""
    private var cacheKeys: CacheKeys?
    private var bannerWork: Task<Void, Never>?
    private let networkKind = NetworkKind()
    private var controlToken = 0

    init(model: AppModel) {
        self.model = model
        // Until the saved state has been read, the window offers nothing: a user with a
        // linked phone must never be asked to sign in or to link one.
        model.phase = .starting
        model.readMarkStore = .standard
        model.preferenceStore = .standard
        notifier.onResponse = { [weak self] response in
            Task { @MainActor in self?.handle(response) }
        }
        setUpBluetoothCalls()
        Task { await self.boot() }
    }

    /// Where the document lives: the login keychain, with a private file as the fallback for
    /// builds the keychain refuses (for example when run unsigned from the command line).
    static func makeStore() -> StateStore {
        AppFolders.adoptFormerFolders()
        let keychain = KeychainStateStore()
        if let existing = try? keychain.load() {
            _ = existing
            return keychain
        }
        if (try? keychain.save(PersistedState())) != nil { return keychain }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FileStateStore(url: support.appendingPathComponent("\(AppFolders.name)/state.json"))
    }

    private func boot() async {
        let vault: StateVault
        do {
            vault = try StateVault(store: LiveActions.makeStore())
        } catch {
            model.phase = .failed(message: "The saved account state could not be read: \(error)", canRetry: false)
            return
        }
        Diagnostics.shared.writeToFile(AppFolders.log)
        // A network joined through this app and still remembered from a run that ended on it.
        forgetNetworksAddedHere()
        diag("app", "started, state in \(type(of: LiveActions.makeStore()))")
        let http = LoggingTransport(URLSessionTransport())
        var dependencies = RoleSession.Dependencies(
            http: http, webSockets: URLSessionWebSocketConnector(), instance: await vault.clientInstance,
            displayName: Host.current().localizedName ?? "Mac", installationId: await vault.state.installationId,
            localClipboard: clipboard)
        let network = networkKind
        dependencies.ownStatus = { MacStatus.status(network: network.current) }
        // Messages are kept between launches, sealed with a key that lives in the Keychain.
        // The key is looked up each time a phone's caches are opened: signing out drops it,
        // and the next account gets a new one.
        let keys = CacheKeys(vault: vault)
        if await keys.refresh() != nil {
            let folder = AppFolders.support
            let cache: @Sendable (String, String) -> BlobCache? = { kind, phoneId in
                keys.current.map { EncryptedFile(url: folder.appendingPathComponent("\(kind)-\(phoneId).cache"), key: $0) }
            }
            dependencies.messageCache = { cache("messages", $0) }
            dependencies.photoCache = { cache("photos", $0) }
            dependencies.contactCache = { cache("contacts", $0) }
            dependencies.appCache = { cache("apps", $0) }
            dependencies.callCache = { cache("calls", $0) }
        }
        cacheKeys = keys
        // Before each connection, so that a sign-in after a sign-out has its new key in place
        // before any cache is opened.
        dependencies.prepareForConnect = { await keys.refresh() }
        dependencies.callLogsEnabled = { UserDefaults.standard.bool(forKey: AppModel.callsEnabledKey) }
        dependencies.filesEnabled = { UserDefaults.standard.object(forKey: AppModel.filesEnabledKey) as? Bool ?? true }
        dependencies.clipboardEnabled = { UserDefaults.standard.object(forKey: AppModel.clipboardEnabledKey) as? Bool ?? true }
        // Files are written here while they arrive and moved to Downloads when whole.
        ReceivedFiles.clearIncoming()
        dependencies.incomingFilesDirectory = ReceivedFiles.incomingFolder
        // Two roles as on Windows by default; `--single-client` tries one enrollment for both.
        // The cross-device client announces file transfer only while the user wants files here:
        // with it the phone lists this Mac as a share target.
        let acceptsFiles = UserDefaults.standard.object(forKey: AppModel.filesEnabledKey) as? Bool ?? true
        let roles: [ClientProfile] = CommandLine.arguments.contains("--single-client") ? [.unified]
            : [acceptsFiles ? ClientProfile.crossDevice.acceptingFiles : .crossDevice, .phoneLink]
        let controller = await LinkController(vault: vault, msa: MicrosoftAccount(transport: http), dependencies: dependencies, roles: roles)
        self.controller = controller
        // A phone linked in an earlier run: straight to the main window, as "reconnecting",
        // with what the caches hold, instead of waiting for the service to list the phone again.
        if let phone = await controller.preferredPhone() {
            phoneName = phone.name
            model.phones = await controller.linkedPhones().map(LiveActions.entry)
            model.currentPhoneId = phone.id
            model.hasBeenConnected = true
            model.phase = .connecting(phoneName: phone.name)
        }
        eventTask = Task { [weak self] in
            for await event in controller.events { self?.apply(event) }
        }
        clipboardWatch = clipboard.watch { [weak controller, weak model] in
            guard let offered = try? await controller?.localClipboardChanged() else { return }
            let isImage: Bool
            if case .image = offered { isImage = true } else { isImage = false }
            await MainActor.run { [model] in model?.noteClipboard(isImage ? .image : .text, fromPhone: false) }
        }
        _ = await notifier.requestAuthorization()
        // Banners left by an earlier run belong to notifications this run knows nothing of;
        // the phone lists the current ones again after connecting.
        notifier.removeAll()
        AttachmentFiles.removeAll()
        await controller.start()
        watchSystem(controller)
    }

    /// Reconnects at once after the Mac wakes or the network comes back, instead of waiting
    /// for the relay's silence timeout and the retry delay.
    private func watchSystem(_ controller: LinkController) {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            diag("app", "woke from sleep; reconnecting")
            Task { await controller.reconnect(reason: "wake") }
        }
        let monitor = NWPathMonitor()
        let previous = PathState()
        let network = networkKind
        monitor.pathUpdateHandler = { path in
            network.update(path)
            Task { @MainActor [weak self] in self?.hotspotWatch.networkChanged() }
            // Only a change from "no network" to "network" matters.
            guard previous.becameSatisfied(path.status == .satisfied) else { return }
            diag("app", "network is back; reconnecting")
            Task { await controller.reconnect(reason: "network") }
        }
        monitor.start(queue: DispatchQueue(label: "winphone.network"))
        pathMonitor = monitor
    }


    // MARK: Events

    private func apply(_ event: LinkController.Event) {
        defer { refreshDockBadge() }
        switch event {
        case .signedOut:
            model.accountName = nil
            model.phones = []
            model.notifications = []
            model.mediaSessions = []
            model.calls = []
            model.ringingUntil = nil
            model.photos = []
            model.conversations = []
            model.contacts = ContactBook()
            model.apps = [:]
            model.hasBeenConnected = false
            connectedRoles = []
            // Banners carry the phone's notification text; none stay after signing out.
            notifier.removeAll()
            AttachmentFiles.removeAll()
            // The key went with the account; the next one is fetched before the next connect.
            cacheKeys?.clear()
            model.phase = .signedOut
        case .signingIn(let code, let url, let expires):
            model.phase = .signingIn(code: code, url: url, expires: expires)
        case .signedIn(let name):
            model.accountName = name
            // Whether a phone is linked is known once the service has listed the phones.
            if case .signingIn = model.phase { model.phase = .starting }
            if case .signedOut = model.phase { model.phase = .starting }
        case .pairing(let step, _):
            model.phase = .linking(step)
        case .phones(let phones):
            // The list comes again at every reconnect; the phone in use stays marked as such.
            let online = model.isConnected ? model.currentPhoneId : nil
            model.phones = phones.map { phone in
                var entry = LiveActions.entry(phone)
                entry.isOnline = phone.id == online
                return entry
            }
            // None to connect to: now, and only now, linking is offered.
            if !phones.contains(where: \.isLinked) {
                // What was shown from the last run belonged to a phone that is linked no more.
                if model.currentPhoneId != nil { clearPhoneContent() }
                model.currentPhoneId = nil
                model.hasBeenConnected = false
                if case .linking = model.phase {} else { model.phase = .linking(nil) }
            }
        case .connecting(let phone):
            // Another phone than before: nothing of the old one stays on screen.
            if let previous = model.currentPhoneId, previous != phone.id {
                clearPhoneContent()
                setOnline(previous, false)
            }
            model.currentPhoneId = phone.id
            phoneName = phone.name
            connectedRoles = []
            model.connectionDetail = nil
            model.phase = .connecting(phoneName: phone.name)
        case .connected(let phone, let role):
            model.hasBeenConnected = true
            model.connectionDetail = nil
            model.phoneSilentSince = nil
            connectedRoles.insert(role)
            setOnline(phone.id, true)
            model.phase = .connected(phoneName: phone.name)
            retryBluetoothCallsIfNeeded()
            // Development aid: `defaults write com.winphone.app ice.selftest -bool true` tries
            // the way over the internet against the real servers once after connecting.
            if UserDefaults.standard.bool(forKey: "hotspot.selfcheck"), !hotspotSelfCheckRun {
                hotspotSelfCheckRun = true
                // After the phone's status has had time to arrive.
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    self?.hotspotSelfCheck()
                }
            }
            // Development aid: what the phone says it holds, asked silently, into the log.
            if UserDefaults.standard.bool(forKey: "permissions.selfcheck"), role == "PL", let controller {
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    for (name, type) in [("appear on top", NotificationSync.appearOnTopPermission), ("notification access", NotificationSync.notificationPermission), ("Bluetooth", NotificationSync.bluetoothPermission)] {
                        let held = try? await controller.phoneHolds(permission: type)
                        diag("app", "the phone says of \(name): \(held.map { $0 ? "held" : "not held" } ?? "no answer")")
                    }
                }
            }
            if UserDefaults.standard.bool(forKey: "ice.selftest"), !relaySelfTestRun, let controller {
                relaySelfTestRun = true
                Task { diag("ice", "self-test: \(await controller.relaySelfTest())") }
            }
        case .disconnected(let phone, let role, let error):
            if let error {
                let sentence = error.hasSuffix(".") ? error : error + "."
                model.connectionDetail = "\(role == "PL" ? "Notifications" : "Clipboard") link: \(sentence) Trying again."
                // The phone itself is silent (not the network): counted from the first time.
                if error == LinkController.describe(PhoneConnection.ConnectionError.phoneUnreachable), model.phoneSilentSince == nil {
                    model.phoneSilentSince = Date()
                }
            }
            connectedRoles.remove(role)
            // A list that was on its way over that link will not arrive: the next session starts anew.
            if model.storageState.isLoading { model.storageState = .idle }
            if connectedRoles.isEmpty {
                setOnline(phone.id, false)
                model.phase = .connecting(phoneName: phone.name)
            }
        case .notification(let change):
            switch change {
            case .upsert(let notification, let alert):
                model.upsert(notification)
                // What is playing is shown in the player, not as a Mac notification.
                if !notification.isMediaSession, model.wantsBanner(notification) {
                    let sound = model.rule(for: notification.packageName).sound
                    banner { await $0.show(notification, alert: alert, sound: sound) }
                }
            case .removed(let key):
                model.removeNotification(key: key)
                banner { $0.remove(key: key) }
            case .accessChanged(let granted):
                model.notificationAccessMissing = !granted
            case .sensitiveAccessChanged(let granted):
                model.sensitiveNotificationsHidden = !granted
                model.waitingForPhonePermission = false
            case .bluetoothAccessChanged(let granted):
                model.phoneBluetoothAllowed = granted
            case .appContexts(let contexts):
                for context in contexts where context.action == .update {
                    guard let url = context.url else { continue }
                    let app = model.apps[context.appId]?.name ?? ""
                    linkArrived(PhoneLinkItem(url: url, title: context.title.isEmpty ? (url.host ?? "Link") : context.title, source: .app(app)))
                }
            case .statusReported:
                // The controller turns these into events of their own.
                break
            }
        case .notificationAccess(let granted):
            model.notificationAccessMissing = !granted
        case .sensitiveNotifications(let hidden):
            // Also the phone's verdict on a dialog we asked for: granted, denied or closed.
            model.sensitiveNotificationsHidden = hidden
            model.waitingForPhonePermission = false
        case .phoneBluetoothAccess(let granted):
            model.phoneBluetoothAllowed = granted
        case .clipboardReceived(let content):
            let what: String
            switch content {
            case .text, .html: what = "Text"
            case .image: what = "An image"
            }
            model.lastClipboardEvent = "\(what) copied on \(phoneName) · \(Date().formatted(date: .omitted, time: .shortened))"
            if case .image = content { model.noteClipboard(.image, fromPhone: true) } else { model.noteClipboard(.text, fromPhone: true) }
            // A link copied on the phone is most likely meant to be opened here.
            if case .text(let text) = content, let url = PhoneLinks.link(inCopied: text) {
                linkArrived(PhoneLinkItem(url: url, title: url.host ?? "Link", source: .copied))
            }
        case .phoneStatus(let status):
            // A report is also the answer to a ringer or Do Not Disturb request.
            if model.pendingControl == .ringer || model.pendingControl == .doNotDisturb { model.pendingControl = nil }
            model.phoneStatus = status
            // The user has just agreed on the phone: go on to what was asked for.
            // Not while the phone's question about Bluetooth is still open: that one continues by itself.
            if model.hotspotState == .settingUp, status.hotspot?.consent == true, !hotspotBluetoothPending {
                diag("hotspot", "the phone reports its user's consent; going on")
                connectHotspot(afterSetUp: true)
            }
            if let alert = batteryAlerts.check(status, lowWanted: model.batteryLowAlert, fullWanted: model.batteryFullAlert) {
                diag("status", "battery alert")
                banner { await $0.showNotice(kind: "battery", title: alert.title, body: alert.body) }
            }
        case .ringing(let until):
            model.ringingUntil = until
        case .canRingPhone(let supported):
            model.canRingPhone = supported
        case .apps(let apps):
            model.apps = apps
            notifier.icons = apps.compactMapValues(\.icon)
        case .contacts(let book):
            model.contacts = book
        case .conversations(let list):
            model.conversations = list
        case .messagingAccess(let granted):
            model.messagingAccessMissing = !granted
        case .fileTransfer(let update):
            apply(update)
        case .screen(let update):
            switch update {
            case .connecting:
                model.screenState = .connecting
                model.screenLocked = false
                model.screenProtected = false
                model.screenInputSize = nil
                model.screenTurns = 0
                model.screenVideo.reset()
            case .waitingForPermission:
                model.screenState = .waitingForPermission
            case .started(let format):
                model.screenVideoSize = CGSize(width: CGFloat(format.width), height: CGFloat(format.height))
                model.screenState = .live
            case .inputSize(let width, let height):
                model.screenInputSize = CGSize(width: width, height: height)
            case .rotation(let turns):
                model.screenTurns = turns
            case .frame(let frame):
                model.screenVideo.show(frame)
            case .soundStarted(let format):
                if !model.screenAudio.start(format) { diag("screen", "the sound format cannot be played here") }
            case .sound(let data):
                let played = model.screenAudio.play(data)
                // The first frames, and now and then a count, say whether the sound is being read right.
                let total = model.screenAudio.framesPlayed + model.screenAudio.failures
                if total <= 3 { diag("screen", "sound frame of \(data.count) bytes \(played ? "decoded" : "not decoded"), first byte \(data.first.map { String($0, radix: 16) } ?? "none")") }
                if total % 500 == 0 { diag("screen", "sound: \(model.screenAudio.framesPlayed) frames played, \(model.screenAudio.failures) not decoded") }
            case .locked(let locked):
                model.screenLocked = locked
            case .protectedContent(let protected):
                model.screenProtected = protected
            case .ended:
                let counts = model.screenVideo.counts()
                let pacing = model.screenVideo.pacingCounts().map { ", paced: \($0.late) late, \($0.averageRoom) ms of room on average" } ?? ", shown on arrival"
                diag("screen", "frames shown \(counts.shown), held back while waiting for a whole one \(counts.held), drawn past a missing one \(counts.pastGaps)\(pacing)")
                model.screenAudio.stop()
                model.screenState = .idle
            case .failed(let reason):
                model.screenAudio.stop()
                model.screenState = .failed(reason)
            }
        case .phoneRemoved(let id):
            // Nothing of the removed phone stays on screen or in Notification Center.
            if id == model.currentPhoneId || model.currentPhoneId == nil {
                clearPhoneContent()
                model.currentPhoneId = nil
            }
        case .storage(let update):
            switch update {
            case .state(let state):
                model.storageState = state
            case .files(let files):
                // Tens of thousands of entries are sorted into folders off the main thread.
                storageBuild?.cancel()
                storageBuild = Task { [weak model] in
                    let tree = await Task.detached(priority: .userInitiated) { PhoneFileTree(files: files) }.value
                    guard !Task.isCancelled else { return }
                    model?.storageTree = tree
                    model?.storageListed = true
                }
            case .storage(let available, let total):
                model.storageSpace = AppModel.StorageSpace(available: available, total: total)
            }
        case .calls(let calls):
            // A list still on its way when the user switched the history off is not shown.
            model.calls = model.callsEnabled ? calls : []
        case .callLogAccess(let granted):
            model.callLogAccessMissing = !granted
        case .photos(let photos):
            model.photos = photos
        case .photoAccess(let granted):
            model.photoAccessMissing = !granted
        case .failed(let message):
            model.phase = .failed(message: message, canRetry: true)
        }
    }

    /// Keeps the number on the Dock icon in step with the notification list.
    func refreshDockBadge() {
        let wanted = model.dockBadge
        if NSApp?.dockTile.badgeLabel != wanted { NSApp?.dockTile.badgeLabel = wanted }
    }

    /// Banner changes run one after another in the order they were asked for, so a removal
    /// cannot overtake the banner it removes.
    private func banner(_ work: @escaping @Sendable (MacNotifier) async -> Void) {
        let previous = bannerWork
        let notifier = notifier
        bannerWork = Task {
            await previous?.value
            await work(notifier)
        }
    }

    /// Empties everything that belongs to one phone: what it showed and what it could do.
    private func clearPhoneContent() {
        model.notifications = []
        model.mediaSessions = []
        model.conversations = []
        model.photos = []
        model.calls = []
        model.contacts = ContactBook()
        model.apps = [:]
        storageBuild?.cancel()
        storageBuild = nil
        PhoneFilePreviews.shared.forget()
        model.storageTree = PhoneFileTree()
        model.storageListed = false
        model.storageSpace = nil
        model.storageState = .idle
        model.phoneStatus = nil
        model.ringingUntil = nil
        model.canRingPhone = false
        model.controlNotice = nil
        model.pendingControl = nil
        banner { $0.removeAll() }
        AttachmentFiles.removeAll()
    }

    static func entry(_ phone: PeerDevice) -> LinkedPhone {
        LinkedPhone(id: phone.id, name: phone.name, model: "\(phone.manufacture) \(phone.modelName) · Android \(phone.osVersion)",
                    isOnline: false, isLinked: phone.isLinked)
    }

    // MARK: Phone screen

    func startScreen(app: String?) {
        guard let controller else {
            model.screenState = .failed(PhoneControlError.notConnected.explanation)
            return
        }
        switch model.screenState {
        case .idle, .failed: break
        default: return
        }
        model.screenState = .connecting
        model.screenApp = app
        var options = NanoMirrorSession.Options()
        if let app { options.packageName = app }
        options.sound = model.screenSound
        Task {
            do {
                // Frames go straight to the picture, not through the app's events.
                let video = model.screenVideo
                video.whenPictureSizeChanges { [weak model] width, height in
                    diag("screen", "the picture is now \(width) x \(height)")
                    model?.screenVideoSize = CGSize(width: width, height: height)
                }
                try await controller.mirrorScreen(options: options) { video.show($0) }
            } catch {
                model.screenState = .failed(PhoneControlError.notConnected.explanation)
            }
        }
    }

    func stopScreen() {
        guard let controller else { return }
        Task { await controller.stopMirroring() }
    }

    /// Input goes to the phone in the order it happened here: one after the other.
    private var screenInput: Task<Void, Never>?

    private func sendToScreen(_ work: @escaping @Sendable (LinkController) async -> Void) {
        guard let controller, model.screenState == .live else { return }
        let before = screenInput
        screenInput = Task {
            await before?.value
            await work(controller)
        }
    }

    func screenPointer(_ pointer: ScreenPointer) {
        sendToScreen { await $0.screenPointer(x: pointer.x, y: pointer.y, pressed: pointer.left, rightPressed: pointer.right, middlePressed: pointer.middle,
                                              wheelX: pointer.wheelX, wheelY: pointer.wheelY) }
    }

    func screenKey(_ usage: UInt8, pressed: Bool) {
        sendToScreen { await $0.screenKey(usage, pressed: pressed) }
    }

    func screenGesture(_ gesture: NanoMirrorSession.Gesture) {
        sendToScreen { await $0.screenGesture(gesture) }
    }

    func wakeScreen() {
        sendToScreen { await $0.screenWake() }
    }

    func selectPhone(_ phone: LinkedPhone) {
        guard phone.isLinked, phone.id != model.currentPhoneId else { return }
        // A transfer with the old phone ends with its connection.
        run { await $0.select(phone: phone.id) }
    }

    private func setOnline(_ id: String, _ online: Bool) {
        if let index = model.phones.firstIndex(where: { $0.id == id }) { model.phones[index].isOnline = online }
    }

    private func handle(_ response: MacNotifier.Response) {
        guard let notification = model.notifications.first(where: { $0.key == response.key }) else { return }
        switch response {
        case .reply(_, let text): reply(text, to: notification)
        case .action(_, let index):
            if let action = notification.actions.first(where: { $0.index == index }) { invoke(action, on: notification) }
        case .open:
            if model.clickOpensAppOnPhone { openOnPhone(notification) } else { model.reveal(notification) }
        case .dismissed: dismiss(notification)
        }
    }

    private func run(_ work: @escaping @Sendable (LinkController) async throws -> Void) {
        guard let controller else { return }
        Task { @MainActor in
            do {
                try await work(controller)
            } catch LinkController.ControllerError.busy {
                // A second click while the first is under way: nothing to report.
            } catch {
                self.model.phase = .failed(message: LinkController.describe(error), canRetry: true)
            }
        }
    }

    /// Something asked of the phone about one thing: a notification, the clipboard. When it
    /// fails, a line says so; the rest of the app goes on as it was. (`run` is for what the
    /// whole link stands on, and shows its failures in place of everything.)
    private func act(_ work: @escaping @Sendable (LinkController) async throws -> Void) {
        guard let controller else { return }
        Task { @MainActor in
            do {
                try await work(controller)
            } catch LinkController.ControllerError.busy {
            } catch {
                diag("app", "an action failed: \(type(of: error)).\(error is NotificationSync.CommandError ? "\(error)" : "")")
                let words = LinkController.describe(error)
                self.show(notice: words, seconds: words.count > 90 ? 25 : 8)
            }
        }
    }

    // MARK: AppActions

    func signIn() { run { try await $0.signIn() } }
    func cancelSignIn() { run { await $0.cancelSignIn() } }
    func startPairing(manual: Bool) { run { try await $0.pair(flow: manual ? .manual : .qrCode) } }
    func refreshChallengePIN() { run { try await $0.refreshChallengePIN() } }
    func retry() {
        model.phase = model.accountName == nil ? .signedOut : .linking(nil)
        run { await $0.connectIfPossible() }
    }
    func signOut() { run { await $0.signOut() } }
    func removePhone(_ phone: LinkedPhone) {
        run { controller in
            let peers = await controller.linkedPhones()
            if let peer = peers.first(where: { $0.id == phone.id }) { try await controller.unlink(phone: peer) }
        }
    }
    func dismiss(_ notification: PhoneNotification) { act { try await $0.dismiss(notificationKey: notification.key) } }
    func clearAll() {
        // Only what is shown: notifications of apps switched off here stay on the phone.
        let keys = model.visibleNotifications.map(\.key)
        act { try await $0.clearNotifications(keys: keys) }
    }

    // MARK: Links

    /// A link came from the phone: listed, and announced or opened as the user chose.
    private func linkArrived(_ item: PhoneLinkItem) {
        guard model.noteLink(item) else { return }
        diag("links", "a link from the phone (\(item.source == .copied ? "copied" : "from an app"))")
        if model.linksOpenAtOnce {
            NSWorkspace.shared.open(item.url)
        } else if model.linksAnnounced {
            banner { await $0.showLink(title: item.title, caption: item.caption + ". Click to open.", url: item.url) }
        }
    }

    /// Sends a link as a small page the phone offers to open, by the way files go.
    func sendLink(_ url: URL) {
        guard AppModel.linkSendingEnabled else { return }
        guard let web = PhoneLinks.webURL(url.absoluteString) else {
            model.linkNotice = "Only web addresses can be sent."
            return
        }
        let folder = AppFolders.caches.appendingPathComponent("Links", isDirectory: true)
        let file = folder.appendingPathComponent(PhoneLinks.fileName(for: web))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try PhoneLinks.page(for: web).write(to: file, options: .atomic)
        } catch {
            model.linkNotice = "The link could not be prepared."
            return
        }
        guard controller != nil, model.isConnected else {
            model.linkNotice = PhoneControlError.notConnected.explanation
            return
        }
        guard model.fileTransferStatus == nil else {
            model.linkNotice = "A file transfer is running. Try again when it is done."
            return
        }
        diag("links", "sending a link to the phone")
        model.linkNotice = "Sent. On the phone, tap the notification to open it."
        sendFiles([file])
    }

    func setMuted(_ muted: Bool, package: String) {
        var rule = model.rule(for: package)
        rule.list = !muted
        setRule(rule, package: package)
    }

    func setRule(_ rule: AppNotificationRule, package: String) {
        let before = model.rule(for: package)
        model.setRule(rule, for: package)
        refreshDockBadge()
        let had = before.list && before.banner, wants = rule.list && rule.banner
        guard model.showsBanners, had != wants else { return }
        let affected = model.notifications.filter { $0.packageName == package }
        if wants {
            banner { notifier in for notification in affected { await notifier.show(notification, alert: false) } }
        } else {
            // Their banners go at once; the notifications stay on the phone.
            let keys = affected.map(\.key)
            banner { notifier in for key in keys { notifier.remove(key: key) } }
        }
    }

    /// Follows the banner setting: off removes the banners, on brings the current ones back.
    func bannersChanged() {
        refreshDockBadge()
        if model.showsBanners {
            let current = model.visibleNotifications.filter { model.wantsBanner($0) }
            banner { notifier in for notification in current { await notifier.show(notification, alert: false) } }
        } else {
            banner { $0.removeAll() }
        }
    }
    func openOnPhone(_ notification: PhoneNotification) { act { try await $0.openOnPhone(notificationKey: notification.key) } }
    func invoke(_ action: PhoneNotification.Action, on notification: PhoneNotification) {
        act { try await $0.invoke(action, notificationKey: notification.key) }
    }
    func reply(_ text: String, to notification: PhoneNotification) {
        guard let action = notification.replyAction else { return }
        act { try await $0.reply(text, notificationKey: notification.key, action: action) }
    }
    func setClipboardSync(_ enabled: Bool) {
        model.clipboardSyncEnabled = enabled
        act { try await $0.setClipboardSync(enabled) }
    }

    func sendMessage(_ text: String, attachments: [OutgoingAttachment], in conversation: Conversation) {
        guard let controller else { return }
        // A conversation that exists only as a failed first message has no thread yet.
        let thread: Int64? = conversation.id > 0 ? conversation.id : nil
        let recipients = thread == nil ? conversation.participants : []
        // Failures show on the message itself, so they are not raised as an app error.
        Task { try? await controller.sendMessage(text, threadId: thread, recipients: recipients, attachments: attachments) }
    }

    func startConversation(with number: String, text: String) {
        guard let controller else { return }
        Task { try? await controller.sendMessage(text, threadId: nil, recipients: [number]) }
    }

    func refreshMessages() {
        guard let controller else { return }
        Task { try? await controller.resyncMessages() }
    }

    func markConversationRead(_ conversation: Conversation) {
        guard let controller, conversation.id > 0, let newest = conversation.messages.last?.date else { return }
        Task { try? await controller.markConversationRead(threadId: conversation.id, through: newest) }
    }

    func discardFailedMessage(_ id: Int64) {
        guard let controller else { return }
        Task { await controller.discardFailedMessage(id: id) }
    }

    func cancelPermissionRequest() { model.waitingForPhonePermission = false }

    func setUpSensitiveNotifications() {
        guard let controller, !model.waitingForPhonePermission else { return }
        model.waitingForPhonePermission = true
        Task { @MainActor in
            // The phone answers when its user has decided, or not at all if the dialog is ignored.
            _ = try? await controller.requestSensitiveNotificationAccess()
            self.model.waitingForPhonePermission = false
        }
    }

    func refreshPhotos() {
        guard let controller else { return }
        Task { try? await controller.refreshPhotos() }
    }

    func deletePhoto(_ photo: PhonePhoto) async -> String? {
        guard let controller else { return PhoneControlError.notConnected.explanation }
        do {
            try await controller.deletePhoto(id: photo.id)
            return nil
        } catch {
            diag("photos", "delete failed: \(error)")
            return LinkController.describe(error)
        }
    }

    func loadAttachmentList(of message: PhoneMessage) async -> Bool {
        guard let controller else { return false }
        do {
            try await controller.describeAttachments(ofMessage: message.messageId)
            return true
        } catch {
            diag("messages", "attachment list request failed: \(error)")
            return false
        }
    }

    func fetchAttachment(_ attachment: MessageAttachment) async -> Data? {
        guard let controller else { return nil }
        do {
            return try await controller.attachmentData(partId: attachment.id)
        } catch {
            diag("messages", "attachment fetch failed: \(error)")
            return nil
        }
    }

    // MARK: Files

    /// Files on their way to the phone, by name, until each is confirmed sent.
    private var outgoing: [String: OutgoingFile] = [:]

    private func apply(_ update: PhoneFileReceiver.Update) {
        switch update {
        case .started:
            model.fileTransferIsSending = false
            model.fileTransferProblem = nil
            model.fileTransferProgress = nil
            model.fileTransferStatus = "\(phoneName) is sharing a file…"
        case .offered(let names, let total):
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            model.fileTransferStatus = names.count == 1 ? "Receiving \(names[0]) (\(size))" : "Receiving \(names.count) files (\(size))"
        case .receiving(let name, let received, let total):
            model.fileTransferStatus = "Receiving \(name)"
            model.fileTransferProgress = total > 0 ? Double(received) / Double(total) : nil
        case .received(let file):
            model.fileTransferProgress = nil
            guard let url = ReceivedFiles.save(file) else {
                model.fileTransferProblem = "\(file.name) arrived but could not be saved to Downloads."
                return
            }
            model.receivedFiles.insert(ReceivedFileEntry(name: url.lastPathComponent, url: url, size: file.size, date: Date()), at: 0)
            let source = phoneName
            banner { await $0.showFileReceived(name: url.lastPathComponent, from: source, path: url.path) }
        case .finished:
            model.fileTransferStatus = nil
            model.fileTransferProgress = nil
        case .failed(let reason):
            model.fileTransferStatus = nil
            model.fileTransferProgress = nil
            model.fileTransferProblem = reason
            outgoing = [:]
        case .cancelled:
            model.fileTransferStatus = nil
            model.fileTransferProgress = nil
            outgoing = [:]
        case .sendStarted(let names, let total):
            model.fileTransferIsSending = true
            model.fileTransferProblem = nil
            model.fileTransferProgress = nil
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            model.fileTransferStatus = names.count == 1 ? "Sending \(names[0]) (\(size)) to \(phoneName)…" : "Sending \(names.count) files (\(size)) to \(phoneName)…"
        case .sending(let name, let sent, let total):
            model.fileTransferStatus = "Sending \(name)"
            model.fileTransferProgress = total > 0 ? Double(sent) / Double(total) : nil
        case .sent(let name):
            model.fileTransferProgress = nil
            if let file = outgoing.removeValue(forKey: name) {
                model.receivedFiles.insert(ReceivedFileEntry(name: name, url: file.url, size: Int(file.size), date: Date(), sent: true), at: 0)
            }
        case .sendFinished:
            model.fileTransferStatus = nil
            model.fileTransferProgress = nil
            outgoing = [:]
        }
    }

    func cancelFileTransfer() {
        guard let controller else { return }
        model.fileTransferStatus = "Stopping…"
        Task { await controller.cancelFileTransfer() }
    }

    func sendFiles(_ urls: [URL]) {
        var files: [OutgoingFile] = []
        // Two files of one name would be told apart on the phone, not here: one entry each.
        for url in urls {
            guard let file = OutgoingFile(url: url), !files.contains(where: { $0.name == file.name }) else { continue }
            files.append(file)
        }
        guard !files.isEmpty else {
            model.fileTransferProblem = "Nothing to send: choose files, not folders."
            return
        }
        guard let controller else {
            model.fileTransferProblem = PhoneControlError.notConnected.explanation
            return
        }
        guard model.fileTransferStatus == nil else {
            model.fileTransferProblem = "Another transfer is still running."
            return
        }
        outgoing = Dictionary(files.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        model.fileTransferIsSending = true
        model.fileTransferProblem = nil
        model.fileTransferStatus = "Connecting to \(phoneName)…"
        Task {
            do {
                try await controller.sendFiles(files)
            } catch RoleSession.FileSendError.needsPermission {
                model.fileTransferStatus = nil
                model.fileTransferProblem = "Link to Windows is not allowed to store files on the phone. Allow it there, then send again."
            } catch {
                model.fileTransferStatus = nil
                model.fileTransferProblem = PhoneControlError.notConnected.explanation
            }
        }
    }

    func setFilesEnabled(_ enabled: Bool) {
        model.filesEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppModel.filesEnabledKey)
    }

    // MARK: Calls

    func setCallsEnabled(_ enabled: Bool) {
        guard enabled != model.callsEnabled else { return }
        model.callsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppModel.callsEnabledKey)
        if !enabled { model.calls = [] }
        guard let controller else { return }
        // The switch travels in the start-of-session exchange, so the session starts again.
        Task { await controller.callHistorySettingChanged() }
    }

    // MARK: Calls over Bluetooth

    private func setUpBluetoothCalls() {
        bluetoothCalls.onState = { [weak self] state in self?.model.callLink = state }
        bluetoothCalls.onCall = { [weak self] call in self?.liveCallChanged(call) }
        bluetoothCalls.onNotice = { [weak self] notice in self?.show(notice: notice) }
        bluetoothCalls.onCanMute = { [weak self] can in self?.model.callCanMute = can }
        callPanel = CallPanelController(model: model)
        // Bluetooth is only touched once the user asked for calls: the system asks for
        // permission the first time.
        if model.bluetoothCallsEnabled { startBluetoothCalls() }
    }

    /// Finds the linked phone among the paired ones and starts holding a connection to it,
    /// once the user has let the app use Bluetooth.
    private func startBluetoothCalls() {
        bluetoothAccess.request { [weak self] allowed in
            guard let self, self.model.bluetoothCallsEnabled else { return }
            if allowed {
                self.connectBluetoothCalls()
            } else {
                self.bluetoothCalls.stop()
                self.model.callLink = .notAllowed
            }
        }
    }

    private func connectBluetoothCalls() {
        let phones = BluetoothCalls.pairedPhones()
        model.callDevices = phones
        let linked = model.phones.first { $0.id == model.currentPhoneId }?.name ?? phoneName
        guard let device = BluetoothCalls.choose(from: phones, chosen: model.callDeviceAddress, linkedName: linked) else {
            diag("calls", "bluetooth: \(phones.count) paired phones, none could be told to be the linked one")
            bluetoothCalls.stop()
            model.callLink = .noPhone
            return
        }
        // Remembered, so that the next launch does not wait for the phone's name.
        if model.callDeviceAddress != device.address {
            model.callDeviceAddress = device.address
            UserDefaults.standard.set(device.address, forKey: AppModel.callDeviceKey)
        }
        bluetoothCalls.start(address: device.address)
    }

    /// The linked phone's name is known now: look for it again if it was not found before.
    private func retryBluetoothCallsIfNeeded() {
        if model.bluetoothCallsEnabled, model.callLink == .noPhone { startBluetoothCalls() }
    }

    func setBluetoothCalls(_ enabled: Bool) {
        guard enabled != model.bluetoothCallsEnabled else { return }
        model.bluetoothCallsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppModel.bluetoothCallsKey)
        diag("calls", "bluetooth calls switched \(enabled ? "on" : "off")")
        if enabled {
            startBluetoothCalls()
        } else {
            bluetoothCalls.stop()
            model.callLink = .off
        }
    }

    func chooseCallDevice(_ address: String) {
        model.callDeviceAddress = address
        UserDefaults.standard.set(address, forKey: AppModel.callDeviceKey)
        if model.bluetoothCallsEnabled { startBluetoothCalls() }
    }

    private func liveCallChanged(_ call: LiveCall?) {
        let before = model.liveCall
        model.liveCall = call
        let spoken = call?.phase == .active || call?.phase == .held
        if spoken, model.liveCallSince == nil { model.liveCallSince = Date() }
        if !spoken { model.liveCallSince = nil }
        if call == nil {
            model.callMuted = false
            // The call that just ended belongs in the history.
            if before != nil, model.callsEnabled {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    self.refreshCalls()
                }
            }
        }
    }

    func answerCall() { bluetoothCalls.answer() }
    func endCall() { bluetoothCalls.hangUp() }
    func placeCall(_ number: String) -> Bool { bluetoothCalls.dial(number) }
    func callTone(_ key: Character) { bluetoothCalls.tone(key) }
    func toggleCallHold() { bluetoothCalls.toggleHold() }
    func setCallMuted(_ muted: Bool) {
        guard model.callCanMute else { return }
        model.callMuted = muted
        bluetoothCalls.setMuted(muted)
    }

    func refreshCalls() {
        guard let controller else { return }
        Task { @MainActor in
            do { try await controller.refreshCalls() } catch { self.show(notice: LinkController.describe(error)) }
        }
    }

    func dialOnPhone(_ number: String) async -> String? {
        guard let controller else { return PhoneControlError.notConnected.explanation }
        do {
            try await controller.dialOnPhone(number)
            return nil
        } catch {
            diag("calls", "dial request failed: \(error)")
            return LinkController.describe(error)
        }
    }

    // MARK: Device controls

    /// Runs a control request. A failure is said briefly next to the controls, not raised as
    /// an app error: the connection is fine, the phone just declined.
    private func control(_ pending: AppModel.PendingControl? = nil, _ work: @escaping @Sendable (LinkController) async throws -> Void) {
        guard let controller else { return }
        model.controlNotice = nil
        // Each request with an indicator gets a number, so the timer of an earlier one cannot
        // clear a later one's.
        var token = 0
        if let pending {
            controlToken += 1
            token = controlToken
            model.pendingControl = pending
        }
        Task { @MainActor in
            do {
                try await work(controller)
                // The phone accepted; the change itself arrives as a report. Do not wait forever.
                if pending != nil {
                    try? await Task.sleep(for: .seconds(4))
                    if self.controlToken == token { self.model.pendingControl = nil }
                }
            } catch {
                diag("controls", "request failed: \(error)")
                if pending != nil, self.controlToken == token { self.model.pendingControl = nil }
                self.show(notice: LinkController.describe(error))
            }
        }
    }

    private func show(notice: String, seconds: Int = 8) {
        model.controlNotice = notice
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if self.model.controlNotice == notice { self.model.controlNotice = nil }
        }
    }

    func ringPhone() { control { try await $0.ringPhone() } }
    func stopRinging() { control { try await $0.stopRinging() } }
    func setRinger(_ ringer: PhoneStatus.Ringer) { control(.ringer) { try await $0.setRinger(ringer) } }
    func setDoNotDisturb(_ on: Bool) { control(.doNotDisturb) { try await $0.setDoNotDisturb(on) } }
    func setSyncOverMobileData(_ on: Bool) { control(.mobileData) { try await $0.setSyncOverMobileData(on) } }
    func media(_ command: MediaCommand, on session: PhoneNotification) {
        control(.media) { try await $0.media(command, notificationKey: session.key) }
    }

    /// Cells ask one at a time as they scroll into view; collect them for a moment and send
    /// one request for the lot.
    func needThumbnails(_ ids: [Int64]) {
        wantedThumbnails.formUnion(ids)
        guard thumbnailFlush == nil, let controller else { return }
        thumbnailFlush = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            let batch = Array(self.wantedThumbnails)
            self.wantedThumbnails.removeAll()
            self.thumbnailFlush = nil
            try? await controller.loadThumbnails(for: batch)
        }
    }

    // MARK: The phone's hotspot

    private let hotspotChannel = HotspotChannel()
    private var hotspotSelfCheckRun = false

    /// Development aid, run once after launch when the default `hotspot.selfcheck` is set:
    /// what the paired phone offers over Bluetooth, into the log.
    func hotspotSelfCheck() {
        bluetoothAccess.request { [weak self] allowed in
            guard let self, allowed else { return diag("hotspot", "self-check: Bluetooth not allowed") }
            let phones = BluetoothCalls.pairedPhones()
            let linked = self.model.phones.first { $0.id == self.model.currentPhoneId }?.name ?? self.phoneName
            guard let device = BluetoothCalls.choose(from: phones, chosen: self.model.callDeviceAddress, linkedName: linked) else {
                return diag("hotspot", "self-check: \(phones.count) paired phones, none chosen")
            }
            diag("hotspot", "self-check: status says consent \(self.model.phoneStatus?.hotspot.map { String($0.consent) } ?? "unknown"), channel open \(self.model.phoneStatus?.hotspot.map { String($0.channelOpen) } ?? "unknown")")
            Task {
                await self.hotspotChannel.diagnose(address: device.address)
                // The whole way once with the question that switches nothing on: whether the
                // phone is asked directly, and what it answers.
                guard let controller = self.controller else { return }
                // First the question that needs no signature: does the phone read at all?
                do {
                    let answer = try await self.askOverSideChannel(SideChannelCapabilities.request, with: device.address, timeout: .seconds(12))
                    let services = (try? SideChannelCapabilities.services(in: answer)).map { "\($0)" } ?? "not readable"
                    diag("hotspot", "self-check: the phone answered the plain question, \(answer.count) bytes; services \(services)")
                } catch {
                    diag("hotspot", "self-check: the plain question ended with \(error is HotspotChannel.ChannelError ? "\(error)" : "\(type(of: error))")")
                }
                // Signed as each of the two identities the phone trusts, one after the other.
                for crossDevice in [false, true] {
                    // The phone needs a moment to let go of the connection before.
                    try? await Task.sleep(for: .seconds(3))
                    let signer = crossDevice ? "cross-device" : "Phone Link"
                    guard let exchange = try? await controller.hotspotExchange(.status, crossDevice: crossDevice) else {
                        diag("hotspot", "self-check: no request could be signed as \(signer)")
                        continue
                    }
                    do {
                        let answer = try await self.askOverSideChannel(exchange.request, with: device.address, timeout: .seconds(20))
                        diag("hotspot", "self-check (\(signer)): the phone answered the status question, \(answer.count) bytes")
                        switch try exchange.answer(answer) {
                        case .capable: diag("hotspot", "self-check (\(signer)): the phone could share its connection")
                        case .credentials: diag("hotspot", "self-check (\(signer)): credentials came back to a question that asked for none")
                        }
                    } catch {
                        diag("hotspot", "self-check (\(signer)): the status question ended with \(error is HotspotError || error is HotspotChannel.ChannelError ? "\(error)" : "\(type(of: error))")")
                    }
                }
            }
        }
    }

    func setUpHotspot() {
        guard let controller else { return }
        Task {
            do {
                try await controller.requestHotspotSetup()
                model.hotspotState = .settingUp
            } catch {
                diag("hotspot", "the set-up could not be asked for: \(type(of: error))")
                model.hotspotState = .failed((error as? PhoneControlError) == .unsupported
                    ? "The phone would not open its Instant Hotspot setting. Look for Instant Hotspot in Link to Windows' settings on the phone; if it is not there, this phone does not offer it."
                    : (error as? PhoneControlError)?.explanation ?? "The phone could not be asked. Is it connected?")
            }
        }
    }

    /// What went wrong, for the user. Nothing of the network's name or password.
    /// - Parameter phoneBluetoothAllowed: what the phone said of Link to Windows' own Bluetooth
    ///   permission. Without it the phone lets a request lie unread, which looks like silence.
    static func explain(_ error: Error, phoneBluetoothAllowed: Bool? = nil) -> String {
        if phoneBluetoothAllowed == false, case HotspotChannel.ChannelError.timedOut = error { return phoneBluetoothMissing }
        switch error {
        case HotspotError.notCapable(let obstacle): return obstacle?.explanation ?? "The phone cannot share its connection right now."
        case HotspotError.untrusted: return "The phone does not accept this Mac for its hotspot. On the phone, open Link to Windows and allow Instant Hotspot."
        case HotspotError.refused(2, _): return "The phone tried to switch its hotspot on and could not. Switch Mobile Hotspot on once by hand on the phone: if it asks or complains about something there, that is what stands in the way."
        case HotspotError.refused(let status, let kind): return "The phone refused to switch its hotspot on (\(status)/\(kind))."
        case HotspotError.forged, HotspotError.malformed, HotspotError.implausible: return "The phone's answer could not be trusted or read. Nothing was joined."
        case HotspotChannel.ChannelError.noDevice: return "The phone is not paired with this Mac. Pair it in System Settings › Bluetooth."
        case HotspotChannel.ChannelError.noService:
            return "The phone is not offering its hotspot to this Mac. On the phone, switch on Instant Hotspot in Link to Windows; the phone and this Mac must be paired over Bluetooth."
        case is HotspotChannel.ChannelError: return "The phone could not be reached over Bluetooth. Is it near, with Bluetooth on?"
        case let error as PhoneControlError: return error.explanation
        default: return "The phone's hotspot could not be asked for."
        }
    }

    /// One request over the phone's side channel, with the calls link out of the way.
    /// macOS 27 closes the wrong one of two serial channels an app holds to the same device:
    /// asked to close the side channel it cut the calls link and left the side channel open,
    /// and the next request never got through (its own log, 2026-10-12 20:45). So only one
    /// of the two is open at a time.
    private func askOverSideChannel(_ request: Data, with address: String, timeout: Duration = .seconds(25)) async throws -> Data {
        let callsWereOn = bluetoothCalls.state != .off
        if callsWereOn {
            diag("hotspot", "the calls link steps aside for the request")
            bluetoothCalls.stop()
            // The connection under the calls link takes about a second to end, and an opening
            // begun while it ends is lost.
            try? await Task.sleep(for: .milliseconds(1500))
        }
        let result: Result<Data, Error>
        do { result = .success(try await hotspotChannel.exchange(request, with: address, timeout: timeout)) } catch { result = .failure(error) }
        if callsWereOn {
            // The side channel is let go first, then the calls link comes back.
            try? await Task.sleep(for: .milliseconds(800))
            if model.bluetoothCallsEnabled { startBluetoothCalls() }
        }
        return try result.get()
    }

    /// Networks that joining through this app put among the Mac's remembered ones, kept over
    /// launches so that they can be taken off again; as fingerprints, not by their names.
    static let ourNetworksKey = "hotspot.networksAddedHere"
    static func fingerprint(_ ssid: String) -> String {
        SHA256.hash(data: Data(("winphone.hotspot." + ssid).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    static func isNotedAsOurs(_ ssid: String, in defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: ourNetworksKey) ?? []).contains(fingerprint(ssid))
    }
    static func noteAsOurs(_ ssid: String, _ ours: Bool, in defaults: UserDefaults = .standard) {
        var noted = (defaults.stringArray(forKey: ourNetworksKey) ?? []).filter { $0 != fingerprint(ssid) }
        if ours { noted.append(fingerprint(ssid)) }
        defaults.set(noted, forKey: ourNetworksKey)
    }

    /// Takes off the Mac's remembered networks those that joining through this app put there,
    /// so that the Mac does not go onto the phone's hotspot by itself. Told apart by their
    /// fingerprints; a network the Mac knew before is not touched.
    func forgetNetworksAddedHere() {
        guard !(UserDefaults.standard.stringArray(forKey: LiveActions.ourNetworksKey) ?? []).isEmpty else { return }
        if case .joined = model.hotspotState { return }
        Task {
            guard let remembered = await WiFiJoin.rememberedNetworks() else { return }
            var forgotten = 0
            for name in LiveActions.networksToForget(among: remembered) {
                await WiFiJoin.forget(ssid: name)
                forgotten += 1
            }
            // What is noted and no longer remembered needs no note either.
            UserDefaults.standard.removeObject(forKey: LiveActions.ourNetworksKey)
            if forgotten > 0 { diag("hotspot", "took \(forgotten) network(s) that this app had joined off the Mac's remembered ones") }
        }
    }

    static func networksToForget(among remembered: [String], in defaults: UserDefaults = .standard) -> [String] {
        let noted = Set(defaults.stringArray(forKey: ourNetworksKey) ?? [])
        return remembered.filter { noted.contains(fingerprint($0)) }
    }

    /// Whether the Mac remembered the phone's network before this app joined it.
    private var hotspotWasRemembered = true
    /// Where the Mac is while on the phone's network, for telling whether it has left.
    private var hotspotRoute: NetworkRoute?

    func leaveHotspot() {
        guard case .joined(let network) = model.hotspotState, let wifi = WiFiJoin.interfaceName() else { return }
        hotspotWatch.stop()
        model.hotspotState = .leaving
        let joined = hotspotRoute
        let forget = hotspotWasRemembered && !LiveActions.isNotedAsOurs(network) ? nil : network
        LiveActions.noteAsOurs(network, false)
        Task {
            diag("hotspot", "leaving the phone's network\(forget == nil ? "" : "; it is taken off the Mac's remembered ones, where joining put it")")
            await WiFiJoin.leave(forgetting: forget)
            // The Mac now looks for a network of its own. Given a while; then helped along.
            var now: NetworkRoute?
            for step in 0..<24 {
                try? await Task.sleep(for: .milliseconds(500))
                now = NetworkRoute.of(interface: wifi)
                if now != nil { break }
                if step == 15 {
                    diag("hotspot", "no network of its own yet; Wi-Fi off and on")
                    await WiFiJoin.restartWiFi()
                }
            }
            if let now, let joined, now == joined {
                diag("hotspot", "the Mac went straight back to the phone's network")
                self.model.hotspotState = .failed("This Mac went straight back to the phone's network, which it remembers as one of its own. Choose another network in the Wi-Fi menu.")
                return
            }
            diag("hotspot", "left the phone's network; \(now == nil ? "no other network joined yet" : "on another network")")
            self.model.hotspotState = .left
        }
    }

    /// Keeps the "on the phone's hotspot" sign true: it goes out when the Mac moves to another
    /// network, Wi-Fi is switched off, or the hotspot goes away.
    private func watchHotspot(interface: String, before: NetworkRoute?) {
        Task {
            guard let route = await HotspotWatch.settledRoute(of: interface, before: before) else {
                return diag("hotspot", "joined, but no address came from the phone's network; it is not watched")
            }
            guard case .joined = model.hotspotState else { return }
            hotspotRoute = route
            diag("hotspot", "watching the phone's network for the Mac leaving it")
            hotspotWatch.start(interface: interface, joined: route) { [weak self] in
                guard let self, case .joined = self.model.hotspotState else { return }
                diag("hotspot", "this Mac has left the phone's network")
                self.model.hotspotState = .left
                self.forgetNetworksAddedHere()
            }
        }
    }

    static let phoneBluetoothMissing = "Link to Windows on the phone does not hold all of its Bluetooth permission, so it leaves the request unread. On the phone open Settings › Apps › Link to Windows › Permissions › Nearby devices, choose Don't allow and then Allow again, and try once more."

    /// Whether the phone has been asked to put its question in this round: it is asked once,
    /// not again and again when the service stays away after the user agreed.
    private var hotspotSetUpAsked = false
    /// The same for the phone's question about Bluetooth for Link to Windows.
    private var hotspotBluetoothAsked = false
    private var hotspotBluetoothPending = false

    func connectHotspot() { connectHotspot(afterSetUp: false) }

    private func connectHotspot(afterSetUp: Bool) {
        guard let controller, !model.hotspotState.isBusy else { return }
        hotspotWatch.stop()
        // The calls link steps aside for the request, which it must not do during a call.
        guard model.liveCall == nil else {
            model.hotspotState = .failed("Finish the call first: the hotspot is asked for over the same Bluetooth connection.")
            return
        }
        if !afterSetUp {
            hotspotSetUpAsked = false
            hotspotBluetoothAsked = false
        }
        // The phone's user has not agreed yet: that comes first.
        if model.phoneStatus?.hotspot?.consent == false, !hotspotSetUpAsked {
            hotspotSetUpAsked = true
            return setUpHotspot()
        }
        // Link to Windows itself may not use Bluetooth: it would leave the request unread.
        // The phone is asked to allow it first, as Phone Link has it ask.
        if model.phoneBluetoothAllowed == false, !hotspotBluetoothAsked {
            hotspotBluetoothAsked = true
            hotspotBluetoothPending = true
            model.hotspotState = .settingUp
            Task {
                defer { self.hotspotBluetoothPending = false }
                do {
                    let granted = try await controller.requestPhoneBluetoothAccess()
                    diag("hotspot", "the phone was asked to let Link to Windows use Bluetooth: \(granted ? "allowed" : "not allowed")")
                    self.model.hotspotState = .idle
                    if granted { self.connectHotspot(afterSetUp: true) } else { self.model.hotspotState = .failed(LiveActions.phoneBluetoothMissing) }
                } catch {
                    diag("hotspot", "the phone could not be asked for its Bluetooth permission: \(type(of: error))")
                    self.model.hotspotState = .failed(LiveActions.phoneBluetoothMissing)
                }
            }
            return
        }
        model.hotspotState = .asking
        bluetoothAccess.request { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                self.model.hotspotState = .failed("Phone Mac Link may not use Bluetooth. Allow it in System Settings › Privacy & Security › Bluetooth.")
                return
            }
            let phones = BluetoothCalls.pairedPhones()
            let linked = self.model.phones.first { $0.id == self.model.currentPhoneId }?.name ?? self.phoneName
            guard let device = BluetoothCalls.choose(from: phones, chosen: self.model.callDeviceAddress, linkedName: linked) else {
                diag("hotspot", "\(phones.count) paired phones, none could be told to be the linked one")
                self.model.hotspotState = .failed(phones.isEmpty ? "The phone is not paired with this Mac. Pair it in System Settings › Bluetooth."
                    : "Several phones are paired with this Mac. Choose yours under Settings › General › Calls, then try again.")
                return
            }
            Task {
                do {
                    // As Phone Link: once more at once if the Bluetooth connection fails.
                    var credentials: HotspotCredentials?
                    var attempt = 0
                    while credentials == nil {
                        attempt += 1
                        do {
                            let exchange = try await controller.hotspotExchange(.credentials)
                            let answer = try await self.askOverSideChannel(exchange.request, with: device.address)
                            guard case .credentials(let found) = try exchange.answer(answer) else { throw HotspotError.malformed }
                            credentials = found
                        } catch let error as HotspotChannel.ChannelError where attempt < 2 && error != .noService && error != .noDevice && self.model.phoneBluetoothAllowed != false {
                            diag("hotspot", "the Bluetooth connection failed (\(error)); once more")
                        }
                    }
                    guard let credentials else { return }
                    diag("hotspot", "the phone switched its hotspot on and said how to join")
                    self.model.hotspotState = .joining
                    let wifi = WiFiJoin.interfaceName()
                    let before = wifi.flatMap { NetworkRoute.of(interface: $0) }
                    // Whether the Mac knew this network already: only one that joining puts
                    // among its remembered ones is taken off them again on leaving.
                    self.hotspotWasRemembered = await WiFiJoin.remembers(ssid: credentials.ssid) ?? true
                    if !self.hotspotWasRemembered { LiveActions.noteAsOurs(credentials.ssid, true) }
                    switch await WiFiJoin.join(ssid: credentials.ssid, password: credentials.password) {
                    case .joined:
                        self.model.hotspotState = .joined(network: credentials.ssid)
                        if let wifi { self.watchHotspot(interface: wifi, before: before) }
                    case .notFound: self.model.hotspotState = .failed("The phone switched its hotspot on, but this Mac did not find the network. Try again in a moment, or pick it in the Wi-Fi menu.")
                    case .refused(let why): self.model.hotspotState = .failed("This Mac could not join the phone's network (\(why)).")
                    case .noWiFi: self.model.hotspotState = .failed("Wi-Fi is switched off on this Mac.")
                    }
                } catch HotspotChannel.ChannelError.noService {
                    // The phone opens that service only once its user has allowed the hotspot
                    // to be switched on from a computer (seen on 2026-10-11: nineteen services
                    // listed, this one not among them, the status silent about consent). So
                    // the phone is asked to put the question.
                    if self.hotspotSetUpAsked || self.model.phoneStatus?.hotspot?.consent == true {
                        // Agreed to, and still not there: asking again would only repeat the question.
                        diag("hotspot", "the phone does not list the side channel although its user agreed")
                        self.model.hotspotState = .failed("The phone has Instant Hotspot allowed, but this Mac's remembered list of the phone's Bluetooth services is an old one without it. Remove the phone under System Settings › Bluetooth, pair it again, then try once more.")
                    } else {
                        diag("hotspot", "the phone does not list the side channel; asking it to put the question to its user")
                        self.hotspotSetUpAsked = true
                        self.setUpHotspot()
                    }
                } catch {
                    diag("hotspot", "failed: \(error is HotspotError || error is HotspotChannel.ChannelError ? "\(error)" : "\(type(of: error))"); the phone app's own Bluetooth access: \(self.model.phoneBluetoothAllowed.map { String($0) } ?? "unknown")")
                    self.model.hotspotState = .failed(LiveActions.explain(error, phoneBluetoothAllowed: self.model.phoneBluetoothAllowed))
                }
            }
        }
    }

    private var storageBuild: Task<Void, Never>?

    func loadPhoneFiles(again: Bool) {
        guard let controller else { return }
        Task {
            if await !controller.loadPhoneFiles(again: again) {
                model.storageState = .failed(PhoneControlError.notConnected.explanation)
            }
        }
    }

    func downloadPhoneFile(_ file: PhoneFile) {
        guard let controller else {
            model.fileTransferProblem = PhoneControlError.notConnected.explanation
            return
        }
        guard model.fileTransferStatus == nil else {
            model.fileTransferProblem = "Another transfer is still running."
            return
        }
        model.fileTransferProblem = nil
        Task {
            if await !controller.downloadPhoneFile(file) {
                model.fileTransferProblem = model.filesEnabled ? PhoneControlError.notConnected.explanation : "Receiving files is switched off in Settings."
            }
        }
    }

    func phoneFilePreview(_ file: PhoneFile, side: Int) async -> Data? {
        guard let controller else { return nil }
        return try? await controller.phoneFilePreview(file, side: side)
    }

    func fetchPhoto(_ id: Int64) async -> FetchedPhoto? {
        guard let controller else { return nil }
        do {
            return try await controller.fetchPhoto(id: id)
        } catch {
            diag("photos", "fetch failed: \(error)")
            return nil
        }
    }
}

extension MacNotifier.Response {
    var key: String {
        switch self {
        case .reply(let key, _), .action(let key, _), .open(let key), .dismissed(let key): return key
        }
    }
}

/// The key that seals the caches, readable from the synchronous closures that open them.
final class CacheKeys: @unchecked Sendable {
    private let vault: StateVault
    private let lock = NSLock()
    private var key: Data?

    init(vault: StateVault) { self.vault = vault }

    var current: Data? { lock.withLock { key } }

    func clear() { lock.withLock { key = nil } }

    /// Reads the key from the saved state, creating one when there is none.
    @discardableResult
    func refresh() async -> Data? {
        let fresh = try? await vault.cacheKey()
        lock.withLock { key = fresh }
        return fresh
    }
}

/// Remembers whether the network was usable at the last update.
final class PathState: @unchecked Sendable {
    private let lock = NSLock()
    private var satisfied = true

    /// Records the new state and reports whether the network just came back.
    func becameSatisfied(_ now: Bool) -> Bool {
        lock.withLock {
            defer { satisfied = now }
            return now && !satisfied
        }
    }
}

/// Where files from the phone go: the Downloads folder, under their own names.
enum ReceivedFiles {
    /// Saves a received file. The name is the sender's, so it is reduced to a plain name, and
    /// a file already there is never replaced. The file is marked as a download, so that
    /// macOS checks it before it is first opened.
    static func save(_ file: ReceivedFile, to folder: URL? = nil) -> URL? {
        guard let folder = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return nil }
        let name = AttachmentFiles.safeName(file.name)
        let base = (name as NSString).deletingPathExtension, ending = (name as NSString).pathExtension
        for attempt in 1...500 {
            let candidate = attempt == 1 ? name : "\(base) \(attempt)" + (ending.isEmpty ? "" : "." + ending)
            let url = folder.appendingPathComponent(candidate)
            switch file.content {
            case .data(let data):
                // Writing fails when the name is taken, which is what keeps an existing file safe.
                do {
                    try data.write(to: url, options: [.withoutOverwriting])
                    AttachmentFiles.quarantine(url)
                    return url
                } catch CocoaError.fileWriteFileExists {
                    continue
                } catch {
                    return nil
                }
            case .file(let arrived, _):
                switch place(arrived, at: url) {
                case .done:
                    AttachmentFiles.quarantine(url)
                    return url
                case .nameTaken:
                    continue
                case .failed:
                    try? FileManager.default.removeItem(at: arrived)
                    return nil
                }
            }
        }
        if case .file(let arrived, _) = file.content { try? FileManager.default.removeItem(at: arrived) }
        return nil
    }

    private enum Placement { case done, nameTaken, failed }

    /// Moves a file that arrived on disk to its place, never onto a file already there.
    private static func place(_ arrived: URL, at url: URL) -> Placement {
        // One step on the same disk, and it refuses a name that is taken.
        if renamex_np(arrived.path, url.path, UInt32(RENAME_EXCL)) == 0 { return .done }
        switch errno {
        case EEXIST:
            return .nameTaken
        case EXDEV, ENOTSUP:
            // Another disk, or one that cannot do it in one step: copied, then removed.
            do {
                try FileManager.default.copyItem(at: arrived, to: url)
                try? FileManager.default.removeItem(at: arrived)
                return .done
            } catch CocoaError.fileWriteFileExists {
                return .nameTaken
            } catch {
                return .failed
            }
        default:
            return .failed
        }
    }

    /// Where files are written while they arrive: out of sight, under random names.
    static var incomingFolder: URL {
        AppFolders.caches.appendingPathComponent("Incoming", isDirectory: true)
    }

    /// Removes what an earlier run left unfinished.
    static func clearIncoming() {
        try? FileManager.default.removeItem(at: incomingFolder)
    }
}
