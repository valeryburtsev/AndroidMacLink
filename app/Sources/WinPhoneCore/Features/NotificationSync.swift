import Foundation

/// A notification on the phone, as described by the JSON document the phone sends.
public struct PhoneNotification: Equatable, Sendable, Identifiable {
    public struct Action: Equatable, Sendable {
        public var name: String
        /// The action accepts free-form text, so it can serve as a reply box.
        public var isInlineReply: Bool
        /// Index into the phone's own action list. Not necessarily contiguous.
        public var index: Int
    }

    /// The phone's notification key; identifies the notification in every command.
    public var key: String
    public var packageName: String
    public var appName: String
    /// When the phone posted it, in milliseconds. Echoed back during reconciliation.
    public var postTime: Int64
    public var timestamp: Int64?
    public var title: String?
    public var text: String?
    public var bigText: String?
    public var textLines: [String]
    /// Conversation messages with their senders, oldest first.
    public var messages: [(sender: String?, text: String)]
    public var actions: [Action]
    /// Channel importance, 0 to 5. Phone Link shows no banner at 2 or below.
    public var importance: Int?
    public var isOngoing: Bool
    public var isClearable: Bool
    /// 3 phone call, 1 SMS, 2 media, 0 other.
    public var notificationClass: Int
    /// Raw Android notification flags.
    public var flags: Int
    /// For a media notification, Android's playback state: 2 paused, 3 playing.
    public var playbackState: Int?
    /// For a media notification, the album art as a JPEG.
    public var largeIcon: Data?
    /// For a media notification, the player's icon as a JPEG.
    public var smallIcon: Data?

    /// The notification stands for something playing on the phone, which the media keys can
    /// control by its key.
    public var isMediaSession: Bool { notificationClass == 2 }
    public var isPlaying: Bool { playbackState == 3 }
    /// Android asks that an update of this notification does not alert again.
    public var onlyAlertOnce: Bool { flags & 0x8 != 0 }

    public var id: String { key }

    /// The first action that accepts text, which Phone Link uses as the reply box.
    public var replyAction: Action? { actions.first(where: \.isInlineReply) }
    /// Up to three other actions, shown as buttons.
    public var buttonActions: [Action] { Array(actions.filter { !$0.isInlineReply }.prefix(3)) }

    /// The body to display: the most specific text the notification carries.
    public var displayBody: String {
        if let last = messages.last { return last.sender.map { "\($0): \(last.text)" } ?? last.text }
        if !textLines.isEmpty { return textLines.joined(separator: "\n") }
        return bigText ?? text ?? ""
    }

    public static func == (lhs: PhoneNotification, rhs: PhoneNotification) -> Bool {
        lhs.key == rhs.key && lhs.packageName == rhs.packageName && lhs.appName == rhs.appName && lhs.postTime == rhs.postTime
            && lhs.title == rhs.title && lhs.text == rhs.text && lhs.bigText == rhs.bigText && lhs.textLines == rhs.textLines
            && lhs.actions == rhs.actions && lhs.messages.map(\.text) == rhs.messages.map(\.text)
            && lhs.messages.map(\.sender) == rhs.messages.map(\.sender)
            && lhs.playbackState == rhs.playbackState && lhs.largeIcon == rhs.largeIcon
    }

    /// Parses the phone's JSON. `key`, `packageName` and `postTime` are required.
    public init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let key = object["key"] as? String, let packageName = object["packageName"] as? String,
              let postTime = (object["postTime"] as? NSNumber)?.int64Value else { return nil }
        self.key = key
        self.packageName = packageName
        self.postTime = postTime
        appName = object["appName"] as? String ?? ""
        timestamp = (object["timestamp"] as? NSNumber)?.int64Value
        title = object["title"] as? String
        text = object["text"] as? String
        bigText = object["bigText"] as? String
        textLines = object["textLines"] as? [String] ?? []
        let texts = object["messages"] as? [String] ?? []
        let senders = object["senderNames"] as? [String] ?? []
        messages = texts.enumerated().map { (sender: $0.offset < senders.count ? senders[$0.offset] : nil, text: $0.element) }
        actions = (object["notificationActions"] as? [[String: Any]] ?? []).compactMap { action in
            // The index goes back to the phone as an Int32; one that does not fit is not usable.
            guard let name = action["actionName"] as? String, let number = action["actionIndex"] as? NSNumber,
                  let index = Int32(exactly: number.int64Value) else { return nil }
            return Action(name: name, isInlineReply: action["isActionInlineReply"] as? Bool ?? false, index: Int(index))
        }
        importance = (object["importance"] as? NSNumber)?.intValue
        isOngoing = object["isOngoing"] as? Bool ?? false
        isClearable = object["isClearable"] as? Bool ?? true
        notificationClass = (object["notificationClass"] as? NSNumber)?.intValue ?? 0
        flags = (object["flags"] as? NSNumber)?.intValue ?? 0
        playbackState = (object["playbackState"] as? NSNumber)?.intValue
        largeIcon = (object["largeIcon"] as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
        smallIcon = (object["smallIcon"] as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
    }
}

/// Notification sync with a phone.
///
/// The phone pushes changes on the APP route `/legacy/phonecontent` as three parallel arrays:
/// keys, operation codes and JSON documents. The PC sends commands on `/notifications`.
public actor NotificationSync {
    public static let pushRoute = "/legacy/phonecontent"
    public static let commandRoute = "/notifications"
    public static let contentType = "notifications"
    public static let permissionRoute = "/permission"
    /// Content the phone offers after the handshake that this client has no use for yet.
    static let declinedSyncTypes: Set<String> = ["wallpaper", "recentApps", "browserHistory", "callLogs"]
    public static let appContextType = "continuityAppContext"
    /// The phone's permission type for reading notifications.
    public static let notificationPermission: Int32 = 64
    /// Permission to read notifications Android 15 marks as sensitive and hides from apps such
    /// as Link to Windows until the user allows it. Phone Link asks with this value, the top
    /// bit of the 32-bit mask (capture of 2026-10-09).
    public static let sensitiveNotificationPermission = Int32.min

    /// Link to Windows' own use of Bluetooth: Android's three "Nearby devices" permissions
    /// together (the phone's type 26; a type's bit is its number less one). The phone takes
    /// no hotspot request without all three.
    public static let bluetoothPermission: Int32 = 1 << 25

    /// The right to appear on top of other apps (the phone's type 20), which Link to Windows
    /// falls back on to start things from the background.
    public static let appearOnTopPermission: Int32 = 1 << 19

    public enum Change: Equatable, Sendable {
        /// A new or updated notification. `alert` is false for ones that already existed
        /// on the phone and arrive during reconciliation.
        case upsert(PhoneNotification, alert: Bool)
        case removed(key: String)
        /// The user granted or revoked notification access on the phone.
        case accessChanged(granted: Bool)
        /// The user allowed or disallowed showing notifications Android hides as sensitive.
        case sensitiveAccessChanged(granted: Bool)
        /// Link to Windows was allowed or disallowed to use Bluetooth itself.
        case bluetoothAccessChanged(granted: Bool)
        /// The phone's battery, signal, ringer and Do Not Disturb, which ride on every push.
        /// The values are the push's own; see `PhoneStatus.init(push:base:)`.
        case statusReported(ValueSet)
        /// What the user was doing on the phone, as apps that support "continue on PC" tell
        /// it: pages open in a browser, a note being written.
        case appContexts([PhoneAppContext])
    }

    public enum CommandError: Error, Equatable {
        /// The phone answered with a result other than success.
        case failed(ScenarioResult?)
        /// The phone needs notification access to be granted by the user.
        case needsPermission
        /// The phone could not press a notification's button from the background and is asking
        /// its user for the right to appear on top, which it presses such buttons with.
        case needsAppearOnTop
        /// The phone could not press the button although it holds that right: starting things
        /// from the background failed inside Link to Windows.
        case cannotStartInBackground
    }

    private var messenger: PeerMessenger?
    /// Identity fields every APP request carries.
    private let displayName: String
    private let appVersion: String
    private let installationId: String
    private var store: [String: PhoneNotification] = [:]
    /// Sent with every permission request of this session, in Windows' braced upper-case form.
    private let permissionSessionId = "{" + UUID().uuidString.uppercased() + "}"
    private let continuation: AsyncStream<Change>.Continuation

    /// Changes to the phone's notifications, in order.
    public nonisolated let changes: AsyncStream<Change>

    /// - Parameter messenger: the connection to the phone, or nil until one is attached.
    public init(messenger: PeerMessenger? = nil, displayName: String, appVersion: String = ClientProfile.phoneLink.appVersion,
                installationId: String) {
        self.messenger = messenger
        self.displayName = displayName
        self.appVersion = appVersion
        self.installationId = installationId
        (changes, continuation) = AsyncStream.makeStream(of: Change.self, bufferingPolicy: .unbounded)
    }

    /// Notifications currently known, newest first.
    public var notifications: [PhoneNotification] {
        store.values.sorted { $0.postTime > $1.postTime }
    }

    /// Starts receiving pushes. Call once. Other content types on the same route are left to
    /// `fallback`, since the phone uses this route for every legacy feature.
    /// Uses a new connection to the phone and starts receiving pushes on it. The notifications
    /// held are kept, so the next `reconcile` lets the phone say which ones are gone.
    public func attach(_ messenger: PeerMessenger, fallback: (@Sendable (PeerMessenger.IncomingRequest, ValueSet) async -> ValueSet?)? = nil) async {
        self.messenger = messenger
        await start(fallback: fallback)
    }

    public func start(fallback: (@Sendable (PeerMessenger.IncomingRequest, ValueSet) async -> ValueSet?)? = nil) async {
        guard let messenger else { return }
        // A request refused because the phone is on mobile data and may not sync over it:
        // the one sign of that state, since the phone then sends nothing by itself.
        await messenger.onMeteredRefusal { [continuation] in
            continuation.yield(.statusReported(ValueSet(["syncOverMeteredConnection": .bool(false), NotificationSync.meteredNowKey: .bool(true)])))
        }
        await messenger.handle(NotificationSync.pushRoute) { [weak self] request, messenger in
            guard let self else { return }
            guard let values = try? ValueSet(serialized: request.payload) else {
                // Never drop a push silently: the phone waits for an answer to each one.
                diag("content", "a push could not be read (\(request.payload.count) bytes, headers \(request.envelope.headers.map(\.key).joined(separator: ",")))")
                try? await messenger.respond(to: request, payload: ValueSet(["result": .int32(Int32(ScenarioResult.failure.rawValue))]).serialized(),
                                             contentType: nil, result: ScenarioResult.failure.rawValue)
                return
            }
            await self.noteStatus(in: values)
            let reply: ValueSet
            if values.string("contentType") == "deviceStatus" {
                // Sent when the ringer or Do Not Disturb changes; the status itself was just
                // read from it. Phone Link's whole reply is "result 0".
                reply = ValueSet(["result": .int32(0)])
            } else if values.string("contentType") == NotificationSync.contentType {
                reply = await self.apply(values)
            } else if values.string("contentType") == "permissions" {
                reply = await self.applyPermissions(values)
            } else if values.string("contentType") == "phoneCommand" {
                reply = await self.applyPhoneCommand(values)
            } else if values.string("contentType") == NotificationSync.appContextType {
                reply = await self.applyAppContexts(values)
            } else if values.string("contentType") == "heartbeat" {
                // Every ten minutes the phone checks that this client still answers. Phone
                // Link's whole reply is "result 0".
                reply = ValueSet(["result": .int32(0)])
            } else if let other = await fallback?(request, values) {
                reply = other
            } else if NotificationSync.declinedSyncTypes.contains(values.string("contentType") ?? "") {
                // A sync this client does not use. Answering "success, nothing wanted" lets the
                // phone finish it; an error would make it start the same sync again and again.
                reply = values.entries["metadata"] != nil ? ValueSet(["result": .int32(0), "itemCount": .int32(0)]) : ValueSet(["result": .int32(0)])
            } else {
                reply = ValueSet(["result": .int32(Int32(ScenarioResult.unknownType.rawValue))])
            }
            diag("content", "push \(values.string("contentType") ?? "untyped")\(values.entries["metadata"] != nil ? " (list)" : ""), \(request.payload.count) bytes, answered \(reply.int("result").map(String.init) ?? "nothing")")
            try? await messenger.respond(to: request, payload: reply.serialized(), contentType: nil, result: reply.int("result"))
        }
    }

    private static let statusKeys = ["batteryPercent", "batteryCharging", "batteryPowerSave", "networkOperator", "networkSignalStrength",
                                     "networkSignalStrengthMax", "wifiState", "wifiSignalLevel", "airplaneMode", "ringerMode",
                                     "doNotDisturbStatus", "doNotDisturbRuleEnabled", "syncOverMeteredConnection",
                                     "hotspotUserConsent", "oemBluetoothRfcommServerOpen"]
    /// Not from the phone: added here to a report that says the phone is on a metered network
    /// now and refuses to sync over it.
    public static let meteredNowKey = "meteredNow"
    private var lastStatusKeys: ValueSet?

    /// Passes on the status carried by a push, when it differs from the last one seen.
    func noteStatus(in values: ValueSet) {
        guard values.entries["batteryPercent"] != nil, values.entries["ringerMode"] != nil else { return }
        let status = ValueSet(values.entries.filter { NotificationSync.statusKeys.contains($0.key) })
        guard status != lastStatusKeys else { return }
        lastStatusKeys = status
        continuation.yield(.statusReported(status))
    }

    /// Applies one push and returns the reply value set.
    func apply(_ values: ValueSet) -> ValueSet {
        // The three arrays must be present with these exact types and equal lengths;
        // otherwise nothing is processed and the reply is empty, as on Windows.
        guard let keys = values.strings("notificationKeys"), let operations = values.int32s("operations"),
              let documents = values.strings("notifications"), keys.count == operations.count, keys.count == documents.count else {
            return ValueSet()
        }
        for index in keys.indices {
            switch operations[index] {
            case 1, 3:
                guard let notification = PhoneNotification(json: documents[index]) else { continue }
                // An update of a notification we already hold alerts again unless Android's
                // "only alert once" flag is set, as on the phone itself.
                var alert = operations[index] == 1
                if store[notification.key] != nil, notification.onlyAlertOnce { alert = false }
                // What is playing changes with every track; it is shown, never announced.
                if notification.isMediaSession { alert = false }
                store[notification.key] = notification
                continuation.yield(.upsert(notification, alert: alert))
            case 2:
                if store.removeValue(forKey: keys[index]) != nil { continuation.yield(.removed(key: keys[index])) }
            default:
                continue
            }
        }
        return ValueSet(["result": .int32(0)])
    }

    /// Applies a permission push: parallel arrays of permission types and states, where state
    /// 0 means granted. Windows answers result 0, or 14 when the arrays are malformed.
    func applyPermissions(_ values: ValueSet) -> ValueSet {
        guard let types = values.int32s("permissionTypes"), let states = values.int32s("permissionStates"), types.count == states.count else {
            return ValueSet(["result": .int32(Int32(ScenarioResult.invalidRequest.rawValue))])
        }
        for (type, state) in zip(types, states) {
            if type == NotificationSync.notificationPermission { continuation.yield(.accessChanged(granted: state == 0)) }
            if type == NotificationSync.sensitiveNotificationPermission { continuation.yield(.sensitiveAccessChanged(granted: state == 0)) }
            if type == NotificationSync.bluetoothPermission { continuation.yield(.bluetoothAccessChanged(granted: state == 0)) }
        }
        return ValueSet(["result": .int32(0)])
    }

    /// Passes on the app contexts of a push. The answer is the plain "taken", with a count
    /// where the phone sent a list to choose from.
    func applyAppContexts(_ values: ValueSet) -> ValueSet {
        let contexts = PhoneAppContext.contexts(in: values)
        if !contexts.isEmpty { continuation.yield(.appContexts(contexts)) }
        return values.entries["metadata"] != nil ? ValueSet(["result": .int32(0), "itemCount": .int32(0)]) : ValueSet(["result": .int32(0)])
    }

    /// Applies a `phoneCommand` push. Type 7 reports what happened to the phone's dialog for
    /// sensitive notifications: shown, granted, or denied (also when the user just closes it).
    /// Windows acknowledges every command with result 0.
    func applyPhoneCommand(_ values: ValueSet) -> ValueSet {
        // Type 0: "sync over mobile data" was switched on the phone itself.
        if values.int("phoneCommandType") == 0, let allowed = values.bool("syncOverMeteredConnection") {
            continuation.yield(.statusReported(ValueSet(["syncOverMeteredConnection": .bool(allowed)])))
        }
        // Type 3: the user answered the phone's question about the hotspot, or changed the
        // setting. The command names the open channel differently from the status.
        if values.int("phoneCommandType") == 3, let consent = values.bool("hotspotUserConsent") {
            func said(_ key: String) -> String { values.bool(key).map(String.init) ?? "not said" }
            diag("hotspot", "the phone says: consent \(consent), Bluetooth permission \(said("oemBluetoothPermission")), Bluetooth channel enabled \(said("oemBluetoothRfcommEnabled"))")
            var said: [String: ValueSet.Value] = ["hotspotUserConsent": .bool(consent)]
            if let open = values.bool("oemBluetoothRfcommEnabled") { said["oemBluetoothRfcommServerOpen"] = .bool(open) }
            continuation.yield(.statusReported(ValueSet(said)))
        }
        if values.int("phoneCommandType") == 7 {
            switch values.string("notificationsSensitivePermissionScenario") {
            case "notifications_sensitive_permission_granted": continuation.yield(.sensitiveAccessChanged(granted: true))
            case "notifications_sensitive_permission_denied": continuation.yield(.sensitiveAccessChanged(granted: false))
            default: break
            }
        }
        return ValueSet(["result": .int32(0)])
    }

    // MARK: Commands

    /// Asks the phone whether notification access is granted, as Phone Link does before it
    /// reconciles. With `silent` false the phone may prompt its user.
    /// - Returns: true when the phone reports the permission as granted.
    public func checkAccess(silent: Bool = true) async throws -> Bool {
        try await requestPermission(NotificationSync.notificationPermission, silent: silent)
    }

    /// Asks the phone about one permission. With `silent` false the phone shows its own
    /// dialog and answers once the user has decided, which can take a while.
    /// - Returns: true when the permission is granted.
    public func requestPermission(_ type: Int32, silent: Bool) async throws -> Bool {
        // A dialog on the phone is answered when its user gets to it.
        guard let messenger else { throw CommandError.failed(nil) }
        let response = try await messenger.appRequest(route: NotificationSync.permissionRoute,
                                                      payload: permissionPayload(silent: silent, type: type).serialized(),
                                                      timeout: silent ? nil : .seconds(600))
        let result = (try? ValueSet(serialized: response.payload))?.int("result").flatMap(ScenarioResult.init)
        return result == .userAccepted || result == .success
    }

    func permissionPayload(silent: Bool, type: Int32 = NotificationSync.notificationPermission) -> ValueSet {
        ValueSet([
            "contentType": .string("permission"),
            "contractVersion": .double(ValueSet.contractVersion),
            "correlationVector": .string(TraceContext.randomHex(bytes: 8)),
            "permissionType": .int32(type),
            "permissionSessionId": .string(permissionSessionId),
            "silent": .bool(silent),
            "displayName": .string(displayName),
            "appVersion": .string(appVersion),
            "installationId": .string(installationId),
        ])
    }

    /// Dismisses a notification on the phone. The phone confirms with a removal push.
    public func dismiss(key: String) async throws {
        try await command(2, ["key": .string(key)])
    }

    /// Clears the given notifications, or every one this client knows when `keys` is nil.
    /// Phone Link's "Clear all" lists the keys it holds rather than sending an empty list.
    public func clear(keys: [String]? = nil) async throws {
        // What is playing is not a notification to clear.
        let keys = keys ?? notifications.filter { !$0.isMediaSession }.map(\.key)
        guard !keys.isEmpty else { return }
        try await command(4, clearFields(keys))
    }

    func clearFields(_ keys: [String]) -> [String: ValueSet.Value] {
        ["notificationKeysCount": .int32(Int32(keys.count)), "notificationKeys": .stringArray(keys)]
    }

    /// Asks the phone to bring this client up to date. The phone answers with one push listing
    /// what is new or changed (operation 3) and what is gone (operation 2), then with the result.
    /// Call after connecting; with nothing known it requests a full list.
    public func reconcile() async throws {
        try await command(3, reconcileFields())
    }

    func reconcileFields() -> [String: ValueSet.Value] {
        let known = notifications
        return [
            "notificationKeysCount": .int32(Int32(known.count)),
            "notificationKeys": .stringArray(known.map(\.key)),
            "postTimes": .int64Array(known.map(\.postTime)),
        ]
    }

    /// Opens the notification's app on the phone.
    public func openOnPhone(key: String) async throws {
        try await command(5, ["key": .string(key)])
    }

    /// Presses one of the notification's action buttons.
    public func invoke(action: PhoneNotification.Action, key: String) async throws {
        let extra: [String: ValueSet.Value] = ["key": .string(key), "actionIndex": .int32(Int32(action.index))]
        do {
            try await command(5, extra, alsoSuccess: [.appLaunched])
        } catch CommandError.needsPermission {
            // For a button, "needs permission" is the phone's word that its way of starting
            // things from the background failed (`BackgroundNotificationLauncher`): it says
            // so before it looks whether it holds "appear on top", its other way. Holding
            // it, it gives up (seen on 2026-10-13: the answer was this, the right was held).
            // Once more after a moment, in case the failure was a passing one.
            try? await Task.sleep(for: retryPause)
            do {
                try await command(5, extra, alsoSuccess: [.appLaunched])
            } catch CommandError.needsPermission {
                let held = (try? await requestPermission(NotificationSync.appearOnTopPermission, silent: true)) ?? false
                diag("content", "a notification's button could not be pressed; the phone holds \"appear on top\": \(held)")
                throw held ? CommandError.cannotStartInBackground : CommandError.needsAppearOnTop
            }
        }
    }

    /// How long to wait before a button that the phone could not press is tried once more.
    var retryPause: Duration = .milliseconds(1200)
    func setRetryPause(_ pause: Duration) { retryPause = pause }

    /// Sends a text reply through the notification's inline-reply action. Success means the
    /// phone dispatched the reply to the app, not that the message was delivered.
    public func reply(_ text: String, to key: String, action: PhoneNotification.Action) async throws {
        try await command(5, ["key": .string(key), "actionIndex": .int32(Int32(action.index)), "inlineReplyMessage": .string(text)])
    }

    func commandPayload(_ operation: Int32, _ extra: [String: ValueSet.Value]) -> ValueSet {
        var values = ValueSet([
            "contentType": .string(NotificationSync.contentType),
            "contractVersion": .double(ValueSet.contractVersion),
            "correlationVector": .string(TraceContext.randomHex(bytes: 8)),
            "operation": .int32(operation),
            // Phone Link sends false even for a click on Dismiss or Clear all.
            "isuserinitiated": .bool(false),
            "ignoreResponse": .bool(false),
            "transportType": .int32(0),
            "displayName": .string(displayName),
            "appVersion": .string(appVersion),
            "installationId": .string(installationId),
        ])
        for (key, value) in extra { values[key] = value }
        return values
    }

    private func command(_ operation: Int32, _ extra: [String: ValueSet.Value], alsoSuccess: Set<ScenarioResult> = []) async throws {
        guard let messenger else { throw CommandError.failed(nil) }
        let response = try await messenger.appRequest(route: NotificationSync.commandRoute, payload: commandPayload(operation, extra).serialized())
        let result = (try? ValueSet(serialized: response.payload))?.int("result").flatMap(ScenarioResult.init)
        if result == .needsPermission { throw CommandError.needsPermission }
        guard let result, result.countsAsSuccess || alsoSuccess.contains(result) else { throw CommandError.failed(result) }
    }
}
