import AppKit
import Foundation
import UserNotifications
import WinPhoneCore

/// Mirrors phone notifications into Notification Center, with a reply field and up to three
/// action buttons, and reports what the user does with them.
final class MacNotifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    enum Response: Equatable {
        case reply(key: String, text: String)
        case action(key: String, index: Int)
        case open(key: String)
        case dismissed(key: String)
    }

    private let center: UNUserNotificationCenter?
    private let lock = NSLock()
    private var categories: [String: UNNotificationCategory] = [:]
    var onResponse: (@Sendable (Response) -> Void)?
    /// App icons as PNG by Android package name, shown with each banner.
    var icons: [String: Data] {
        get { lock.withLock { _icons } }
        set { lock.withLock { _icons = newValue } }
    }
    private var _icons: [String: Data] = [:]

    /// "jpg" for a JPEG, "png" for everything else the phone sends (its icons are PNG).
    static func fileEnding(of picture: Data) -> String { picture.starts(with: [0xFF, 0xD8, 0xFF]) ? "jpg" : "png" }

    /// The icon as a file the system can attach. Notification Center takes attachments by URL
    /// and moves the file away, so each use gets its own copy.
    static func attachment(for package: String, icon: Data) -> UNNotificationAttachment? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-mac-link-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = package.replacingOccurrences(of: "/", with: "_")
        // Named for what it is: the system tells the kind of picture by the file's ending.
        let url = folder.appendingPathComponent("\(safe)-\(UUID().uuidString).\(MacNotifier.fileEnding(of: icon))")
        guard (try? icon.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: package, url: url, options: nil)
    }

    /// Without a bundle identifier (the bare executable, or a bundle caught half-built) the
    /// system's notification center aborts the app when asked for (2026-10-15): then there is
    /// none, and nothing is shown.
    init(center: UNUserNotificationCenter? = Bundle.main.bundleIdentifier == nil ? nil : .current()) {
        self.center = center
        super.init()
        center?.delegate = self
    }

    func requestAuthorization() async -> Bool {
        (try? await center?.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// The category identifier encodes the action set, so notifications with the same buttons share one.
    static func categoryIdentifier(for notification: PhoneNotification) -> String {
        let reply = notification.replyAction.map { "r\($0.index)" } ?? "-"
        let buttons = notification.buttonActions.map { "\($0.index):\($0.name)" }.joined(separator: "|")
        return "phone.\(reply).\(buttons)"
    }

    static func category(for notification: PhoneNotification) -> UNNotificationCategory {
        var actions: [UNNotificationAction] = []
        if let reply = notification.replyAction {
            actions.append(UNTextInputNotificationAction(identifier: "reply.\(reply.index)", title: reply.name, options: [],
                                                         textInputButtonTitle: "Send", textInputPlaceholder: "Message"))
        }
        for action in notification.buttonActions {
            actions.append(UNNotificationAction(identifier: "action.\(action.index)", title: action.name, options: []))
        }
        return UNNotificationCategory(identifier: categoryIdentifier(for: notification), actions: actions, intentIdentifiers: [],
                                      options: [.customDismissAction])
    }

    /// Shows or updates the banner for a phone notification.
    /// - Parameter alert: false delivers it quietly, for notifications that already existed.
    /// - Parameter sound: false for an app the user wants to see but not hear.
    func show(_ notification: PhoneNotification, alert: Bool, sound: Bool = true) async {
        let category = MacNotifier.category(for: notification)
        let (isNew, all) = lock.withLock {
            (categories.updateValue(category, forKey: category.identifier) == nil, Set(categories.values))
        }
        if isNew { center?.setNotificationCategories(all) }

        let content = UNMutableNotificationContent()
        content.title = notification.title ?? notification.appName
        content.subtitle = notification.title == nil ? "" : notification.appName
        content.body = notification.displayBody
        content.categoryIdentifier = category.identifier
        content.threadIdentifier = notification.packageName
        content.userInfo = ["key": notification.key]
        // The app's icon from the phone's list of apps; for an app not in that list (Link to
        // Windows itself is not), the notification's own picture where it has one.
        if let icon = icons[notification.packageName] ?? notification.largeIcon, let attachment = MacNotifier.attachment(for: notification.packageName, icon: icon) {
            content.attachments = [attachment]
        }
        // Phone Link shows no banner for low-importance notifications.
        let quiet = !alert || (notification.importance ?? 3) <= 2
        content.sound = quiet || !sound ? nil : .default
        content.interruptionLevel = quiet ? .passive : .active
        try? await center?.add(UNNotificationRequest(identifier: notification.key, content: content, trigger: nil))
        // The system moves the icon file away when it takes the request. If it did not take
        // it, say because notifications are switched off, the copy must not pile up.
        for attachment in content.attachments { try? FileManager.default.removeItem(at: attachment.url) }
    }

    func remove(key: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [key])
        center?.removePendingNotificationRequests(withIdentifiers: [key])
    }

    func removeAll() {
        center?.removeAllDeliveredNotifications()
    }

    /// Announces a file that arrived from the phone. Clicking it shows the file in Finder.
    func showFileReceived(name: String, from source: String, path: String) async {
        let content = UNMutableNotificationContent()
        content.title = "File received"
        content.body = source.isEmpty ? name : "\(name) from \(source)"
        content.sound = .default
        content.userInfo = ["file": path]
        try? await center?.add(UNNotificationRequest(identifier: "file-\(UUID().uuidString)", content: content, trigger: nil))
    }

    /// A word about the phone itself, such as its battery. One per kind at a time: a newer
    /// one replaces the older.
    func showNotice(kind: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["notice": kind]
        try? await center?.add(UNNotificationRequest(identifier: "notice-\(kind)", content: content, trigger: nil))
    }

    /// Announces a link that came from the phone. Clicking it opens the link.
    func showLink(title: String, caption: String, url: URL) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = caption
        content.sound = .default
        content.userInfo = ["link": url.absoluteString]
        try? await center?.add(UNNotificationRequest(identifier: "link-\(UUID().uuidString)", content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    static func response(actionIdentifier: String, key: String, text: String?) -> Response? {
        if actionIdentifier == UNNotificationDefaultActionIdentifier { return .open(key: key) }
        if actionIdentifier == UNNotificationDismissActionIdentifier { return .dismissed(key: key) }
        if actionIdentifier.hasPrefix("reply."), let text, !text.isEmpty { return .reply(key: key, text: text) }
        if actionIdentifier.hasPrefix("action."), let index = Int(actionIdentifier.dropFirst("action.".count)) {
            return .action(key: key, index: index)
        }
        return nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let path = response.notification.request.content.userInfo["file"] as? String {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            return
        }
        if response.notification.request.content.userInfo["notice"] != nil { return }
        if let link = response.notification.request.content.userInfo["link"] as? String {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let url = PhoneLinks.webURL(link) {
                await MainActor.run { _ = NSWorkspace.shared.open(url) }
            }
            return
        }
        guard let key = response.notification.request.content.userInfo["key"] as? String else { return }
        let text = (response as? UNTextInputNotificationResponse)?.userText
        if let mapped = MacNotifier.response(actionIdentifier: response.actionIdentifier, key: key, text: text) {
            onResponse?(mapped)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
