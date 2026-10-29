import Foundation
import SwiftUI
import WinPhoneCore

/// What the app is doing, as far as the user interface is concerned.
enum AppPhase: Equatable {
    /// The app has just started, or has just signed in, and does not know yet whether a
    /// phone is linked. Nothing is offered meanwhile: neither sign-in nor linking.
    case starting
    /// No account. Offer to sign in.
    case signedOut
    /// Waiting for the user to enter the code at the verification page.
    case signingIn(code: String, url: String, expires: Date)
    /// Signed in, no phone linked yet. Pairing is in progress or about to start.
    case linking(PairingStep?)
    case connecting(phoneName: String)
    case connected(phoneName: String)
    case failed(message: String, canRetry: Bool)
}

struct LinkedPhone: Equatable, Identifiable {
    var id: String
    var name: String
    var model: String
    var isOnline: Bool
    /// False for a phone of the account that has not been linked with this Mac.
    var isLinked = true
}

/// A link that came from the phone: copied there, or the page an app there had open.
struct PhoneLinkItem: Identifiable, Equatable {
    enum Source: Equatable { case copied, app(String) }
    let id = UUID()
    var url: URL
    var title: String
    var source: Source
    var date = Date()

    /// Where it came from, in words.
    var caption: String {
        switch source {
        case .copied: return "Copied on the phone"
        case .app(let name): return name.isEmpty ? "Open on the phone" : "Open in \(name) on the phone"
        }
    }
}

/// What of one phone app's notifications shows on this Mac. Nothing changes on the phone.
struct AppNotificationRule: Codable, Equatable {
    /// In the list at all. Off means nothing of the app shows here.
    var list = true
    /// Also as a Mac notification.
    var banner = true
    /// With the Mac notification's sound.
    var sound = true
    /// Counted on the Dock icon and beside "Notifications".
    var badge = true

    /// What is switched off, in words, for under the app's name. Nil when nothing is.
    var summary: String? {
        if !list { return "Off" }
        var parts: [String] = []
        if !banner { parts.append("No banners") } else if !sound { parts.append("No sound") }
        if !badge { parts.append("Not counted") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A file that arrived from the phone and where it was saved.
/// Where the pointer is over the mirrored screen, in the phone's own pixels, which of its
/// buttons are held, and how far the wheel was turned since the last report.
struct ScreenPointer: Equatable {
    var x = 0
    var y = 0
    var left = false
    var right = false
    var middle = false
    var wheelX = 0
    var wheelY = 0
}

/// A word about a screenshot just taken; with the file, where one was written.
struct ScreenshotNote: Equatable {
    var text: String
    var file: URL?
}

/// The phone's picture shown turned: an app lying on its side on a display that stands upright.
enum ScreenTurn {
    /// The size a picture takes once turned by quarter turns.
    static func shown(_ size: CGSize, turns: Int) -> CGSize {
        turns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// The angle for a layer whose coordinates run downward, as in the picture's view: there
    /// a positive angle turns with the clock, and the phone counts against it.
    static func angle(turns: Int) -> CGFloat {
        -CGFloat(((turns % 4) + 4) % 4) * .pi / 2
    }

    /// Where the picture layer goes in a view of this size: its own shape before turning,
    /// centred, so that once turned it fills the view.
    static func layerBounds(in view: CGSize, turns: Int) -> CGRect {
        CGRect(origin: .zero, size: shown(view, turns: turns))
    }
}

/// One crossing between the phone's clipboard and this Mac's.
struct ClipboardEvent: Equatable, Identifiable {
    enum Kind: Equatable { case text, image }
    var id = UUID()
    var kind: Kind
    /// True when it was copied on the phone and arrived here.
    var fromPhone: Bool
    var date: Date
}

/// A file that moved between the phone and this Mac.
struct ReceivedFileEntry: Equatable, Identifiable, Codable {
    var id = UUID()
    var name: String
    /// Where it is on this Mac: where it was saved, or where it was sent from.
    var url: URL
    var size: Int
    var date: Date
    /// True for a file that went from this Mac to the phone.
    var sent = false
}

/// The list of transferred files, kept between launches. It holds names and places only;
/// the files themselves stay where they are.
enum FileHistory {
    static let key = "files.history"
    static let limit = 200

    static func load(from store: UserDefaults) -> [ReceivedFileEntry] {
        guard let data = store.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ReceivedFileEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [ReceivedFileEntry], to store: UserDefaults) {
        store.set(try? JSONEncoder().encode(Array(entries.prefix(limit))), forKey: key)
    }
}

/// The actions the interface can ask for. The protocol stack implements this; the demo
/// implementation fills the interface with sample data.
@MainActor
protocol AppActions: AnyObject {
    func signIn()
    func cancelSignIn()
    func startPairing(manual: Bool)
    func refreshChallengePIN()
    func retry()
    func signOut()
    func removePhone(_ phone: LinkedPhone)
    func dismiss(_ notification: PhoneNotification)
    func clearAll()
    func openOnPhone(_ notification: PhoneNotification)
    func invoke(_ action: PhoneNotification.Action, on notification: PhoneNotification)
    func reply(_ text: String, to notification: PhoneNotification)
    func setClipboardSync(_ enabled: Bool)
    /// Makes the phone ask for permission to show notifications Android hides as sensitive.
    func setUpSensitiveNotifications()
    /// Stops waiting for the phone's permission dialog.
    func cancelPermissionRequest()
    /// Sends a text in a conversation.
    func sendMessage(_ text: String, attachments: [OutgoingAttachment], in conversation: Conversation)
    /// Starts a conversation with a phone number.
    func startConversation(with number: String, text: String)
    func discardFailedMessage(_ id: Int64)
    /// Tells the phone a conversation was read here, for phones that can take it.
    func markConversationRead(_ conversation: Conversation)
    /// Asks the phone to send its messages again.
    func refreshMessages()
    func refreshPhotos()
    /// Asks for thumbnails of photos that came into view.
    func needThumbnails(_ ids: [Int64])
    /// Fetches one image from the phone, or nil if that failed.
    func fetchPhoto(_ id: Int64) async -> FetchedPhoto?
    /// Switches the phone's hotspot on and joins it with this Mac's Wi-Fi.
    func connectHotspot()
    /// Takes this Mac off the phone's hotspot again, back to a network of its own.
    func leaveHotspot()
    /// Has the phone ask its user to allow that.
    func setUpHotspot()
    /// Asks the phone for the list of its files; `again` also when the list is here.
    func loadPhoneFiles(again: Bool)
    /// Fetches one of the phone's files to this Mac; it arrives like a file the phone shared.
    func downloadPhoneFile(_ file: PhoneFile)
    /// A small picture of one of the phone's files, or nil if there is none to be had.
    func phoneFilePreview(_ file: PhoneFile, side: Int) async -> Data?
    /// Deletes a photo from the phone. Returns nil when done, else what went wrong.
    func deletePhoto(_ photo: PhonePhoto) async -> String?
    /// Switches an app's notifications off or back on for this Mac.
    func setMuted(_ muted: Bool, package: String)
    /// Changes what of one app's notifications shows on this Mac.
    func setRule(_ rule: AppNotificationRule, package: String)
    /// Sends a web address to the phone, where it is offered to be opened.
    func sendLink(_ url: URL)
    /// The setting for Mac notifications changed.
    func bannersChanged()
    /// Asks the phone what a picture message's attachments are. Returns whether it answered.
    func loadAttachmentList(of message: PhoneMessage) async -> Bool
    /// Fetches the file of a picture-message attachment, or nil if that failed.
    func fetchAttachment(_ attachment: MessageAttachment) async -> Data?
    /// Switches the call history on or off. It is off until the user asks for it.
    func setCallsEnabled(_ enabled: Bool)
    func refreshCalls()
    /// Opens the phone's dialer with a number. Returns nil when the phone was asked, else
    /// what went wrong.
    func dialOnPhone(_ number: String) async -> String?
    /// Answering and placing calls from this Mac over Bluetooth.
    func setBluetoothCalls(_ enabled: Bool)
    func chooseCallDevice(_ address: String)
    func answerCall()
    /// Ends the call, or declines the one that rings.
    func endCall()
    /// Places a call over Bluetooth. False when there is no connection for it.
    func placeCall(_ number: String) -> Bool
    func callTone(_ key: Character)
    func toggleCallHold()
    func setCallMuted(_ muted: Bool)
    /// Switches receiving files from the phone on or off; takes effect at the next launch.
    func setFilesEnabled(_ enabled: Bool)
    /// Sends files to the phone. Folders and unreadable items are left out.
    func sendFiles(_ urls: [URL])
    /// Stops the file transfer that is running, whichever way it goes.
    func cancelFileTransfer()
    /// Makes another linked phone the one this Mac talks to.
    func selectPhone(_ phone: LinkedPhone)
    /// Starts showing the phone's screen, or one app of it by its package name; the phone
    /// asks its user first.
    func startScreen(app: String?)
    func stopScreen()
    /// The pointer over the mirrored screen.
    func screenPointer(_ pointer: ScreenPointer)
    /// A key for the mirrored screen: a USB keyboard usage number, or one of `NanoKey`.
    func screenKey(_ usage: UInt8, pressed: Bool)
    /// Goes to the phone's home screen, or shows its recent apps, with the swipe for it.
    func screenGesture(_ gesture: NanoMirrorSession.Gesture)
    /// Wakes the phone and brings its unlock prompt forward while its screen is shown here.
    func wakeScreen()
    /// Makes the phone ring loudly so it can be found.
    func ringPhone()
    func stopRinging()
    func setRinger(_ ringer: PhoneStatus.Ringer)
    func setDoNotDisturb(_ on: Bool)
    /// Lets the phone sync while it is on mobile data. A setting on the phone.
    func setSyncOverMobileData(_ on: Bool)
    /// Presses a media key for what is playing on the phone.
    func media(_ command: MediaCommand, on session: PhoneNotification)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var phase: AppPhase = .signedOut
    @Published var accountName: String?
    @Published var phones: [LinkedPhone] = []
    /// The app shown instead of the whole screen, by package name.
    @Published var screenApp: String?
    /// Whether the phone's sound should play on this Mac while its screen is shown.
    @Published var screenSound = false {
        didSet { if screenSound != oldValue { preferenceStore?.set(screenSound, forKey: AppModel.screenSoundKey) } }
    }
    static let screenSoundKey = "screen.sound"
    /// The phone's screen in a window of its own, in the phone's shape, instead of a page of
    /// the main window.
    @Published var screenInOwnWindow = false {
        didSet { if screenInOwnWindow != oldValue { preferenceStore?.set(screenInOwnWindow, forKey: AppModel.screenOwnWindowKey) } }
    }
    static let screenOwnWindowKey = "screen.ownWindow"
    /// That window above all others.
    @Published var screenOnTop = false {
        didSet { if screenOnTop != oldValue { preferenceStore?.set(screenOnTop, forKey: AppModel.screenOnTopKey) } }
    }
    static let screenOnTopKey = "screen.onTop"
    /// Apps the user keeps at the top of the Apps section, by package name.
    @Published var favoriteApps: [String] = [] {
        didSet { if favoriteApps != oldValue { preferenceStore?.set(favoriteApps, forKey: AppModel.favoriteAppsKey) } }
    }
    static let favoriteAppsKey = "apps.favorites"
    /// Apps opened on this Mac, newest first.
    @Published var recentApps: [String] = [] {
        didSet { if recentApps != oldValue { preferenceStore?.set(recentApps, forKey: AppModel.recentAppsKey) } }
    }
    static let recentAppsKey = "apps.recent"
    static let recentAppsKept = 12, recentAppsShown = 6

    func setFavorite(_ package: String, _ favorite: Bool) {
        if favorite {
            if !favoriteApps.contains(package) { favoriteApps.append(package) }
        } else {
            favoriteApps.removeAll { $0 == package }
        }
    }

    /// Opens one of the phone's apps here and remembers that it was opened.
    func open(app package: String) {
        recentApps = Array(([package] + recentApps.filter { $0 != package }).prefix(AppModel.recentAppsKept))
        actions?.startScreen(app: package)
        if !screenInOwnWindow { selection = .screen }
    }

    /// How far joining the phone's hotspot has come.
    enum HotspotState: Equatable {
        case idle
        /// The phone was asked to put its question to the user.
        case settingUp
        /// The phone is being asked, over Bluetooth, to switch its hotspot on.
        case asking
        /// The hotspot is on; this Mac is joining its network.
        case joining
        case joined(network: String)
        /// The Mac is being taken off the phone's hotspot.
        case leaving
        /// The Mac was on the phone's hotspot and is no longer.
        case left
        case failed(String)

        var isBusy: Bool { self == .asking || self == .joining || self == .leaving }
        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }

        /// A line for under the phone's controls; nil when there is nothing to say.
        var notice: String? {
            switch self {
            case .idle: return nil
            case .settingUp: return "Check your phone: it should show Link to Windows' Instant Hotspot setting, or a notification leading to it. Allow it there, then click the hotspot button again."
            case .asking: return "Asking the phone to switch on its hotspot…"
            case .joining: return "Joining the phone's network…"
            case .joined(let network): return "This Mac is on the phone's hotspot (\(network)). The phone now uses mobile data."
            case .leaving: return "Leaving the phone's hotspot…"
            case .left: return "This Mac has left the phone's hotspot. The phone switches the hotspot off by itself once nothing has been connected to it for a while; it cannot be switched off from here."
            case .failed(let why): return why
            }
        }
    }
    @Published var hotspotState = HotspotState.idle

    /// The phone's files as a list to browse: how far the list is, the list as folders,
    /// and the phone's free space.
    @Published var storageState = PhoneFilesSync.State.idle
    @Published var storageTree = PhoneFileTree()
    @Published var storageSpace: StorageSpace?
    /// The list has arrived at least once since the phone was connected.
    @Published var storageListed = false

    struct StorageSpace: Equatable {
        var available: Int64
        var total: Int64
    }

    /// What the last screenshot came to, shown for a moment.
    @Published var screenshotNote: ScreenshotNote?
    let screenAudio = ScreenAudio()

    /// How far showing the phone's screen has come.
    enum ScreenState: Equatable {
        case idle, connecting, waitingForPermission, live
        case failed(String)
    }
    @Published var screenState = ScreenState.idle
    /// The picture's size, for the shape of the view; the phone's own pixels, for the pointer.
    @Published var screenVideoSize = CGSize(width: 720, height: 1600)
    @Published var screenInputSize: CGSize?
    /// Quarter turns against the clock the phone wants the picture shown with.
    @Published var screenTurns = 0
    /// The shape the picture takes on screen, turned or not.
    var screenShownSize: CGSize { ScreenTurn.shown(screenVideoSize, turns: screenTurns) }
    @Published var screenLocked = false
    /// The app on the phone's screen protects it, so the picture is blank on purpose.
    @Published var screenProtected = false
    /// Where the frames go. Not published: they come many a second.
    let screenVideo = ScreenVideo()

    /// The phone this Mac is talking to, or trying to. One at a time, as in Phone Link.
    @Published var currentPhoneId: String?

    /// The phones the user can switch between.
    var switchablePhones: [LinkedPhone] { phones.filter(\.isLinked) }
    /// Every notification on the phone except what is playing. Views show `visibleNotifications`.
    @Published var notifications: [PhoneNotification] = []
    /// What of each app's notifications shows on this Mac, by package name. An app without
    /// an entry shows everything.
    @Published var appRules: [String: AppNotificationRule] = [:] {
        didSet {
            guard appRules != oldValue, let store = preferenceStore else { return }
            store.set(try? JSONEncoder().encode(appRules), forKey: AppModel.appRulesKey)
        }
    }
    static let appRulesKey = "notifications.appRules"

    func rule(for package: String) -> AppNotificationRule { appRules[package] ?? AppNotificationRule() }

    /// Stores an app's rule; the usual one needs no entry.
    func setRule(_ rule: AppNotificationRule, for package: String) {
        appRules[package] = rule == AppNotificationRule() ? nil : rule
    }

    /// Apps whose notifications the user does not want on this Mac at all, by package name.
    var mutedPackages: Set<String> {
        get { Set(appRules.filter { !$0.value.list }.keys) }
        set {
            var rules = appRules
            for package in newValue { rules[package, default: AppNotificationRule()].list = false }
            for (package, rule) in rules where !rule.list && !newValue.contains(package) {
                var shown = rule
                shown.list = true
                rules[package] = shown == AppNotificationRule() ? nil : shown
            }
            appRules = rules
        }
    }
    /// Whether phone notifications also appear as Mac notifications, or only in the list.
    @Published var showsBanners = true {
        didSet { if showsBanners != oldValue { preferenceStore?.set(showsBanners, forKey: AppModel.bannersKey) } }
    }
    /// What a click on a Mac notification does: ask the phone to open the app the
    /// notification belongs to (which also removes it there), or show it in this app.
    /// What clicking a Mac banner does. Showing it here by default: opening the app on the
    /// phone also removes the notification there, and with it here, before it could be read
    /// (2026-10-19, an SMS).
    @Published var clickOpensAppOnPhone = false {
        didSet { if clickOpensAppOnPhone != oldValue { preferenceStore?.set(clickOpensAppOnPhone, forKey: AppModel.clickOpensPhoneKey) } }
    }
    static let clickOpensPhoneKey = "notifications.clickOpensPhone"
    /// The section the main window shows.
    @Published var selection: SidebarItem? = .notifications
    /// Brings the main window forward, opening it again when it was closed. Set by the window.
    var showMainWindow: (() -> Void)?

    /// Files handed to the app from outside, as by a drop on its Dock icon. They arrive one
    /// by one, so they are gathered for a moment and then sent together.
    private var filesToSend: [URL] = []
    private var filesToSendTask: Task<Void, Never>?

    func gatherFileToSend(_ url: URL, wait: Duration = .milliseconds(400)) {
        if !filesToSend.contains(url) { filesToSend.append(url) }
        filesToSendTask?.cancel()
        filesToSendTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            let files = self.filesToSend
            self.filesToSend = []
            self.filesToSendTask = nil
            guard !files.isEmpty else { return }
            self.actions?.sendFiles(files)
            self.show(.files)
        }
    }

    /// Shows a section of the main window, bringing the window back if it was closed.
    func show(_ item: SidebarItem) {
        selection = item
        showMainWindow?()
    }
    /// Opens the settings window. Set by the main window.
    var showSettings: (() -> Void)?
    /// The pane the settings window shows.
    @Published var settingsTab = SettingsTab.general

    /// Shows a notification in this app: for a text, its conversation in Messages, else the list.
    func reveal(_ notification: PhoneNotification) {
        if notification.notificationClass == 1 && !conversations.isEmpty {
            conversationTarget = conversation(for: notification)?.id
            selection = .messages
        } else {
            selection = .notifications
        }
        showMainWindow?()
    }

    /// The conversation a text's notification is about. The notification carries no thread,
    /// only what the phone shows: the text itself, the sender's name or number, and the time.
    func conversation(for notification: PhoneNotification) -> Conversation? {
        let posted = Date(timeIntervalSince1970: Double(notification.postTime) / 1000)
        let shown = [notification.text, notification.bigText].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } + notification.messages.map(\.text) + notification.textLines
        let received = { (conversation: Conversation) in conversation.messages.filter(\.isIncoming) }
        // The text itself, received about when the notification was posted.
        if let match = conversations.first(where: { conversation in
            received(conversation).contains { message in
                abs(message.date.timeIntervalSince(posted)) < 600 && shown.contains { $0 == message.body || $0.hasSuffix(message.body) }
            }
        }) { return match }
        // The sender, by the name the contacts give or by number.
        if let title = notification.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            if let match = conversations.first(where: { $0.participants.count == 1 && self.title(for: $0) == title }) { return match }
            if let match = conversation(with: title) { return match }
        }
        // Whatever was received closest to it, within a couple of minutes.
        return conversations
            .compactMap { conversation in received(conversation).last.map { (conversation, abs($0.date.timeIntervalSince(posted))) } }
            .filter { $0.1 < 120 }
            .min { $0.1 < $1.1 }?.0
    }

    /// Whether the Dock icon shows how many phone notifications are waiting.
    @Published var showsDockBadge = true {
        didSet { if showsDockBadge != oldValue { preferenceStore?.set(showsDockBadge, forKey: AppModel.dockBadgeKey) } }
    }
    static let dockBadgeKey = "notifications.dockBadge"

    /// What the Dock icon should show: the number of waiting notifications, or nothing.
    var dockBadge: String? {
        let count = countedNotifications.count
        return showsDockBadge && isConnected && count > 0 ? String(count) : nil
    }

    /// Where preferences are kept between launches; nil keeps them in memory only.
    var preferenceStore: UserDefaults? {
        didSet {
            guard let store = preferenceStore else { return }
            if let saved = store.data(forKey: AppModel.appRulesKey), let rules = try? JSONDecoder().decode([String: AppNotificationRule].self, from: saved) {
                appRules = rules
            } else {
                // From before apps had more than an on and off.
                mutedPackages = Set(store.stringArray(forKey: AppModel.mutedPackagesKey) ?? [])
            }
            showsBanners = store.object(forKey: AppModel.bannersKey) as? Bool ?? true
            showsDockBadge = store.object(forKey: AppModel.dockBadgeKey) as? Bool ?? true
            clickOpensAppOnPhone = store.object(forKey: AppModel.clickOpensPhoneKey) as? Bool ?? false
            callsEnabled = store.bool(forKey: AppModel.callsEnabledKey)
            bluetoothCallsEnabled = store.bool(forKey: AppModel.bluetoothCallsKey)
            notificationsGrouped = store.object(forKey: AppModel.notificationsGroupedKey) as? Bool ?? true
            if !CommandLine.arguments.contains("--rail") { sidebarCollapsed = store.bool(forKey: AppModel.sidebarCollapsedKey) }
            batteryLowAlert = store.object(forKey: AppModel.batteryLowKey) as? Bool ?? true
            batteryFullAlert = store.bool(forKey: AppModel.batteryFullKey)
            linksAnnounced = store.object(forKey: AppModel.linksAnnouncedKey) as? Bool ?? true
            linksOpenAtOnce = store.bool(forKey: AppModel.linksOpenAtOnceKey)
            callDeviceAddress = store.string(forKey: AppModel.callDeviceKey)
            filesEnabled = store.object(forKey: AppModel.filesEnabledKey) as? Bool ?? true
            receivedFiles = FileHistory.load(from: store)
            screenSound = store.bool(forKey: AppModel.screenSoundKey)
            screenInOwnWindow = store.bool(forKey: AppModel.screenOwnWindowKey)
            favoriteApps = store.stringArray(forKey: AppModel.favoriteAppsKey) ?? []
            recentApps = store.stringArray(forKey: AppModel.recentAppsKey) ?? []
            screenOnTop = store.bool(forKey: AppModel.screenOnTopKey)
        }
    }
    static let mutedPackagesKey = "notifications.mutedPackages"
    static let bannersKey = "notifications.banners"

    /// The notifications to show: those of apps the user has not switched off.
    var visibleNotifications: [PhoneNotification] {
        mutedPackages.isEmpty ? notifications : notifications.filter { !mutedPackages.contains($0.packageName) }
    }

    func isMuted(_ notification: PhoneNotification) -> Bool { mutedPackages.contains(notification.packageName) }

    /// Whether the list shows one stack per app, as Notification Center does, or everything
    /// by time.
    @Published var notificationsGrouped = true {
        didSet { if notificationsGrouped != oldValue { preferenceStore?.set(notificationsGrouped, forKey: AppModel.notificationsGroupedKey) } }
    }
    static let notificationsGroupedKey = "notifications.grouped"

    /// Whether the sidebar is narrowed to a strip of the sections' symbols. `--rail` starts so
    /// (a development aid for pictures of it).
    @Published var sidebarCollapsed = CommandLine.arguments.contains("--rail") {
        didSet { if sidebarCollapsed != oldValue { preferenceStore?.set(sidebarCollapsed, forKey: AppModel.sidebarCollapsedKey) } }
    }
    static let sidebarCollapsedKey = "sidebar.collapsed"

    /// One app's notifications, newest first.
    struct NotificationGroup: Identifiable, Equatable {
        var package: String
        var name: String
        var notifications: [PhoneNotification]
        var id: String { package }
    }

    /// The notifications by app: each app's newest first, the apps by their newest.
    static func groups(of notifications: [PhoneNotification], name: (PhoneNotification) -> String) -> [NotificationGroup] {
        var order: [String] = []
        var byPackage: [String: [PhoneNotification]] = [:]
        for notification in notifications.sorted(by: { $0.postTime > $1.postTime }) {
            if byPackage[notification.packageName] == nil { order.append(notification.packageName) }
            byPackage[notification.packageName, default: []].append(notification)
        }
        return order.map { package in
            let list = byPackage[package] ?? []
            return NotificationGroup(package: package, name: list.first.map(name) ?? package, notifications: list)
        }
    }

    var notificationGroups: [NotificationGroup] {
        AppModel.groups(of: visibleNotifications) { notification in
            apps[notification.packageName]?.name ?? (notification.appName.isEmpty ? notification.packageName : notification.appName)
        }
    }

    /// The notifications that count: on the Dock icon and beside "Notifications".
    var countedNotifications: [PhoneNotification] {
        appRules.isEmpty ? notifications : notifications.filter { rule(for: $0.packageName).list && rule(for: $0.packageName).badge }
    }

    /// Whether a notification also shows as a Mac notification.
    func wantsBanner(_ notification: PhoneNotification) -> Bool {
        let rule = rule(for: notification.packageName)
        return showsBanners && rule.list && rule.banner
    }

    /// Apps to list in the settings: every app the phone reported, plus any other that has
    /// a notification now or was switched off earlier, by name.
    var notifyingApps: [(package: String, name: String, icon: Data?)] {
        var names: [String: String] = [:]
        for package in appRules.keys { names[package] = package }
        for notification in notifications where !notification.appName.isEmpty { names[notification.packageName] = notification.appName }
        for (package, app) in apps where !app.name.isEmpty { names[package] = app.name }
        return names.map { (package: $0.key, name: $0.value, icon: apps[$0.key]?.icon) }
            .sorted { ($0.name.localizedLowercase, $0.package) < ($1.name.localizedLowercase, $1.package) }
    }
    @Published var clipboardSyncEnabled = true
    @Published var lastClipboardEvent: String?
    /// What crossed between the two clipboards in this run, newest first: the kind and the
    /// time only, never what was copied.
    @Published var clipboardEvents: [ClipboardEvent] = []

    func noteClipboard(_ kind: ClipboardEvent.Kind, fromPhone: Bool) {
        clipboardEvents.insert(ClipboardEvent(kind: kind, fromPhone: fromPhone, date: Date()), at: 0)
        if clipboardEvents.count > 30 { clipboardEvents.removeLast(clipboardEvents.count - 30) }
    }
    @Published var notificationAccessMissing = false
    /// Android is hiding some notifications from the phone app until the user allows them.
    @Published var sensitiveNotificationsHidden = false
    /// Whether Link to Windows may use Bluetooth on the phone, as the phone last said; nil
    /// while it has not said.
    @Published var phoneBluetoothAllowed: Bool?
    /// The phone is showing a permission dialog we asked for.
    @Published var waitingForPhonePermission = false
    /// The phone's apps by package name, for the icon next to a notification.
    @Published var apps: [String: PhoneApp] = [:]
    /// The phone's contacts, to show names and photos instead of numbers.
    @Published var contacts = ContactBook()

    /// The title of a conversation: contact names where known, numbers otherwise.
    func title(for conversation: Conversation) -> String {
        let addresses = conversation.participants.isEmpty ? Array(Set(conversation.messages.map(\.address).filter { !$0.isEmpty })).sorted() : conversation.participants
        guard !addresses.isEmpty else { return conversation.title }
        return addresses.map { contacts.name(for: $0) ?? $0 }.joined(separator: ", ")
    }

    /// The contact behind a one-to-one conversation, for its photo.
    func contact(for conversation: Conversation) -> PhoneContact? {
        guard conversation.participants.count == 1 else { return nil }
        return contacts.contact(for: conversation.participants[0])
    }

    /// Text conversations, most recent first.
    @Published var conversations: [Conversation] = []
    /// A number the Messages section is to open: its conversation, or a new message to it.
    @Published var messageTarget: String?
    /// A conversation the Messages section is to open.
    @Published var conversationTarget: Int64?

    /// The one-to-one conversation with a number, however the number is written.
    func conversation(with number: String) -> Conversation? {
        let wanted = AppModel.digits(number)
        guard wanted.count >= 3 else { return nil }
        return conversations.first { conversation in
            conversation.participants.count == 1 && AppModel.sameNumber(AppModel.digits(conversation.participants[0]), wanted)
        }
    }

    static func digits(_ number: String) -> String { number.filter(\.isNumber) }

    /// Two numbers as digits: equal, or one the other without its country code.
    static func sameNumber(_ first: String, _ second: String) -> Bool {
        if first == second { return true }
        let (short, long) = first.count <= second.count ? (first, second) : (second, first)
        return short.count >= 7 && long.hasSuffix(short.hasPrefix("0") ? String(short.dropFirst()) : short)
    }
    @Published var messagingAccessMissing = false
    /// Per conversation, the time up to which it has been read on this Mac. Most phones
    /// cannot be told that a text was read elsewhere, so this is kept here, as Phone Link does.
    @Published private(set) var readThrough: [Int64: Date] = [:]
    /// Where read marks are kept between launches; nil keeps them in memory only.
    var readMarkStore: UserDefaults? {
        didSet {
            let saved = readMarkStore?.dictionary(forKey: AppModel.readMarksKey) as? [String: Double] ?? [:]
            readThrough = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in Int64(key).map { ($0, Date(timeIntervalSince1970: value)) } })
        }
    }
    static let readMarksKey = "messages.readThrough"

    /// Unread texts in a conversation: received, unread on the phone, and newer than what
    /// has been read on this Mac.
    func unreadCount(_ conversation: Conversation) -> Int {
        let mark = readThrough[conversation.id] ?? .distantPast
        return conversation.messages.filter { $0.isIncoming && !$0.isRead && $0.date > mark }.count
    }

    var unreadMessageCount: Int { conversations.reduce(0) { $0 + unreadCount($1) } }

    /// Marks a conversation as read on this Mac and passes that on to the phone.
    func markRead(_ conversation: Conversation) {
        guard unreadCount(conversation) > 0, let newest = conversation.messages.last?.date else { return }
        readThrough[conversation.id] = newest
        readMarkStore?.set(Dictionary(uniqueKeysWithValues: readThrough.map { (String($0.key), $0.value.timeIntervalSince1970) }), forKey: AppModel.readMarksKey)
        actions?.markConversationRead(conversation)
    }
    /// The phone's call history, newest first, when the user switched it on.
    @Published var calls: [PhoneCall] = []
    @Published var callsEnabled = false
    @Published var callLogAccessMissing = false
    nonisolated static let callsEnabledKey = "calls.enabled"

    /// Who a call was with: the contact's name, the number, or a word for a withheld one.
    func title(for call: PhoneCall) -> String {
        if call.number.isEmpty { return "Private number" }
        return contacts.name(for: call.number) ?? call.number
    }

    // The phone's battery.
    @Published var batteryLowAlert = true {
        didSet { if batteryLowAlert != oldValue { preferenceStore?.set(batteryLowAlert, forKey: AppModel.batteryLowKey) } }
    }
    @Published var batteryFullAlert = false {
        didSet { if batteryFullAlert != oldValue { preferenceStore?.set(batteryFullAlert, forKey: AppModel.batteryFullKey) } }
    }
    static let batteryLowKey = "battery.lowAlert", batteryFullKey = "battery.fullAlert"

    // Links across the two devices.
    /// Links that came from the phone in this run, newest first.
    @Published var phoneLinks: [PhoneLinkItem] = []
    /// Whether a link from the phone is announced, and whether it is opened without asking.
    @Published var linksAnnounced = true {
        didSet { if linksAnnounced != oldValue { preferenceStore?.set(linksAnnounced, forKey: AppModel.linksAnnouncedKey) } }
    }
    @Published var linksOpenAtOnce = false {
        didSet { if linksOpenAtOnce != oldValue { preferenceStore?.set(linksOpenAtOnce, forKey: AppModel.linksOpenAtOnceKey) } }
    }
    static let linksAnnouncedKey = "links.announced", linksOpenAtOnceKey = "links.openAtOnce"
    /// Sending a link to the phone as a small page by the file route: built, and switched off
    /// for now (the user did not like a file arriving for a link).
    static let linkSendingEnabled = false
    /// What the last link sent to the phone came to, for the Links section.
    @Published var linkNotice: String?

    /// Takes in a link from the phone. Returns false for one that was just taken in: the same
    /// page reported twice, or copied and then reported by its browser.
    func noteLink(_ item: PhoneLinkItem) -> Bool {
        if let same = phoneLinks.first(where: { $0.url == item.url }), item.date.timeIntervalSince(same.date) < 120 { return false }
        phoneLinks.removeAll { $0.url == item.url }
        phoneLinks.insert(item, at: 0)
        if phoneLinks.count > 30 { phoneLinks.removeLast(phoneLinks.count - 30) }
        return true
    }

    // Calls over Bluetooth: this Mac as the phone's hands-free unit.
    @Published var bluetoothCallsEnabled = false
    @Published var callLink = CallLinkState.off
    /// The paired phones to choose from, and the one chosen.
    @Published var callDevices: [CallDevice] = []
    @Published var callDeviceAddress: String?
    /// The call in progress on the phone, if any, and since when it is being spoken.
    @Published var liveCall: LiveCall?
    @Published var liveCallSince: Date?
    /// Whether this phone mutes its microphone when asked from here, and whether it is muted.
    @Published var callCanMute = false
    @Published var callMuted = false
    nonisolated static let bluetoothCallsKey = "calls.bluetooth"
    nonisolated static let callDeviceKey = "calls.device"

    /// Whether a call can be placed from here, not just prepared in the phone's dialer.
    var canPlaceCalls: Bool {
        if case .connected = callLink { return true }
        return false
    }
    /// Whether the Calls section has anything to show.
    var showsCalls: Bool { callsEnabled || bluetoothCallsEnabled }

    func title(for call: LiveCall) -> String {
        guard let number = call.number, !number.isEmpty else { return "Unknown Caller" }
        return contacts.name(for: number) ?? number
    }

    /// Files that moved between the phone and this Mac, either way, newest first. Kept
    /// between launches where there is a preference store.
    @Published var receivedFiles: [ReceivedFileEntry] = [] {
        didSet { if receivedFiles != oldValue, let store = preferenceStore { FileHistory.save(receivedFiles, to: store) } }
    }
    /// What a share in progress is doing, in words; nil when none is.
    @Published var fileTransferStatus: String?
    /// Whether the transfer in progress goes from this Mac to the phone.
    @Published var fileTransferIsSending = false
    /// How far the file now arriving has come, 0 to 1.
    @Published var fileTransferProgress: Double?
    /// Why the last share did not complete.
    @Published var fileTransferProblem: String?
    /// Whether this Mac offers itself to the phone as a place to share files to.
    @Published var filesEnabled = true
    nonisolated static let filesEnabledKey = "files.enabled"

    /// The phone's recent photos, newest first.
    @Published var photos: [PhonePhoto] = []
    @Published var photoAccessMissing = false
    /// Photos to show: those the phone can actually produce a picture for.
    var visiblePhotos: [PhonePhoto] { photos.filter { !$0.thumbnailUnavailable } }
    /// Battery, signal and ringer state of the connected phone.
    @Published var phoneStatus: PhoneStatus?
    /// The phone is ringing at our request until this time.
    @Published var ringingUntil: Date?
    /// The phone offers to be rung from here.
    @Published var canRingPhone = false
    /// Media notifications: what is playing on the phone. Kept apart from the notification
    /// list, as Phone Link does.
    @Published var mediaSessions: [PhoneNotification] = []
    /// A ringer, Do Not Disturb or media request is on its way; its control shows as busy
    /// until the phone reports the change.
    @Published var pendingControl: PendingControl?
    /// Why the last control request did not work, shown briefly.
    @Published var controlNotice: String?

    enum PendingControl: Equatable { case ringer, doNotDisturb, media, mobileData }

    /// The session to show in the player: the one that is playing, else the latest.
    var nowPlaying: PhoneNotification? {
        mediaSessions.first(where: \.isPlaying) ?? mediaSessions.max { $0.postTime < $1.postTime }
    }

    /// Files a notification where it belongs: with the media sessions or in the list.
    func upsert(_ notification: PhoneNotification) {
        notifications.removeAll { $0.key == notification.key }
        mediaSessions.removeAll { $0.key == notification.key }
        if notification.isMediaSession {
            mediaSessions.append(notification)
            if pendingControl == .media { pendingControl = nil }
        } else {
            notifications.insert(notification, at: 0)
            notifications.sort { $0.postTime > $1.postTime }
        }
    }

    func removeNotification(key: String) {
        notifications.removeAll { $0.key == key }
        mediaSessions.removeAll { $0.key == key }
    }
    /// Why the connection is not up yet, when there is something to say.
    @Published var connectionDetail: String?
    /// Since when the phone has not answered at all, while this Mac could reach the service.
    @Published var phoneSilentSince: Date?
    /// How long the phone may stay silent, after its first round of wake-ups went unanswered
    /// (about a minute), before the app offers to link it again. Phone Link offers it within
    /// about a minute (the user's observation): a frozen Link to Windows (2026-10-13 to 10-15,
    /// two days) came back only when a computer was linked again.
    static let relinkOfferAfter: TimeInterval = 0

    /// Whether to offer linking the phone again, at the given moment.
    func offersRelink(at now: Date) -> Bool {
        guard !isConnected, let since = phoneSilentSince else { return false }
        return now.timeIntervalSince(since) >= AppModel.relinkOfferAfter
    }
    /// Whether screens may load live web pages, such as Microsoft's sign-in. Off for the demo
    /// and for rendered previews, which must not touch the network.
    var embedsLivePages = true
    weak var actions: AppActions?

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    /// The phone was reachable earlier in this run. A dropped link is then shown as
    /// "Reconnecting" over the normal interface instead of sending the user back to the start.
    @Published var hasBeenConnected = false

    /// Whether to show the main interface rather than onboarding.
    var showsMainInterface: Bool {
        if isConnected { return true }
        if case .connecting = phase { return hasBeenConnected }
        return false
    }

    var statusText: String {
        switch phase {
        case .starting: return "Starting"
        case .signedOut: return "Not signed in"
        case .signingIn: return "Waiting for sign-in"
        case .linking: return "Linking a phone"
        case .connecting(let name): return hasBeenConnected ? "Reconnecting to \(name)" : "Connecting to \(name)"
        case .connected(let name): return "Connected to \(name)"
        case .failed(let message, _): return message
        }
    }

    var statusSymbol: String {
        switch phase {
        case .connected: return "iphone.gen3.radiowaves.left.and.right"
        // Names the system does not have leave the menu bar item empty and so unreachable;
        // "iphone.gen3.badge.ellipsis" is one (2026-10-19).
        case .connecting, .linking, .signingIn, .starting: return "iphone.gen3"
        case .signedOut: return "iphone.gen3.slash"
        case .failed: return "iphone.gen3.badge.exclamationmark"
        }
    }
}
