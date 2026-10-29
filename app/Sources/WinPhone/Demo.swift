import AppKit
import SwiftUI
import WinPhoneCore

/// Sample data for exploring the interface without a phone.
enum DemoData {
    static func notification(key: String, app: String, package: String, title: String, text: String, minutesAgo: Int,
                             reply: Bool = false, buttons: [String] = [], messages: [(String, String)] = []) -> PhoneNotification {
        let postTime = Int64((Date().timeIntervalSince1970 - Double(minutesAgo) * 60) * 1000)
        var actions: [[String: Any]] = []
        if reply { actions.append(["actionName": "Reply", "isActionInlineReply": true, "actionIndex": 0]) }
        for (offset, name) in buttons.enumerated() { actions.append(["actionName": name, "isActionInlineReply": false, "actionIndex": offset + 1]) }
        var object: [String: Any] = ["key": key, "packageName": package, "appName": app, "postTime": postTime, "title": title, "text": text,
                                     "importance": 4, "notificationActions": actions]
        if !messages.isEmpty {
            object["messages"] = messages.map(\.1)
            object["senderNames"] = messages.map(\.0)
        }
        let json = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        return PhoneNotification(json: json)!
    }

    static var notifications: [PhoneNotification] {
        [
            notification(key: "n1", app: "Messages", package: "com.example.messages", title: "Ada", text: "Are we still on for 5?", minutesAgo: 2,
                         reply: true, buttons: ["Mark as read"], messages: [("Ada", "Running a bit late"), ("Ada", "Are we still on for 5?")]),
            notification(key: "n2", app: "Calendar", package: "com.example.calendar", title: "Design review", text: "Starts in 15 minutes · Room 4", minutesAgo: 9,
                         buttons: ["Snooze", "Dismiss"]),
            notification(key: "n3", app: "Mail", package: "com.example.mail", title: "Grace Hopper", text: "Re: Compiler notes — thanks, these look good to me.", minutesAgo: 34,
                         reply: true, buttons: ["Archive"]),
        ]
    }

    /// Something playing on the phone, with generated album art.
    static var mediaSession: PhoneNotification {
        var object: [String: Any] = ["key": "media1", "packageName": "com.example.music", "appName": "Music", "postTime": Int64(Date().timeIntervalSince1970 * 1000),
                                     "title": "Analytical Engine", "text": "The Difference", "notificationClass": 2, "playbackState": 3]
        if let art = image(seed: 3, side: 128) { object["largeIcon"] = art.base64EncodedString() }
        let json = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        return PhoneNotification(json: json)!
    }

    static let status = PhoneStatus(batteryPercent: 81, isCharging: true, networkOperator: "Carrier", signalBars: 3, signalBarsMax: 4,
                                    wifiEnabled: true, wifiLevel: 4, network: .wifi, ringerMode: 1, doNotDisturb: 1)
    /// A generated picture, so the demo needs no real photos.
    static func image(seed: Int, side: Int) -> Data? {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let hue = CGFloat((seed * 47) % 360) / 360
        let gradient = NSGradient(starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1),
                                  ending: NSColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.55, alpha: 1))
        gradient?.draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: CGFloat(30 + seed * 25))
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: NSRect(x: side / 5, y: side / 4, width: side / 2, height: side / 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    static func message(_ id: Int64, thread: Int64, minutesAgo: Double, _ body: String, incoming: Bool, read: Bool = true, from: String) -> PhoneMessage {
        PhoneMessage(kind: .sms, messageId: id, threadId: thread, date: Date().addingTimeInterval(-minutesAgo * 60), body: body,
                     isIncoming: incoming, isRead: read, address: from, subscriptionId: 1)
    }

    /// A picture message: one attachment already loaded, one still on the phone.
    static func picture(_ id: Int64, thread: Int64, minutesAgo: Double, _ body: String, from: String) -> PhoneMessage {
        var message = PhoneMessage(kind: .mms, messageId: id, threadId: thread, date: Date().addingTimeInterval(-minutesAgo * 60), body: body,
                                   isIncoming: true, isRead: true, address: from, subscriptionId: 1, attachmentCount: 2)
        message.parts = [MessageAttachment(id: 11, contentType: "image/jpeg", name: "board.jpg", size: 412_000, preview: image(seed: 11, side: 320)),
                         MessageAttachment(id: 12, contentType: "image/jpeg", name: "notes.jpg", size: 1_840_000)]
        return message
    }

    static var calls: [PhoneCall] {
        [PhoneCall(id: 1, number: "+15550100", date: Date().addingTimeInterval(-600), duration: 0, type: 3, isRead: false),
         PhoneCall(id: 2, number: "+15550142", date: Date().addingTimeInterval(-5400), duration: 312, type: 2),
         PhoneCall(id: 3, number: "+15550100", date: Date().addingTimeInterval(-86400), duration: 64, type: 1),
         PhoneCall(id: 4, number: "", date: Date().addingTimeInterval(-90000), duration: 0, type: 5),
         PhoneCall(id: 5, number: "+15550177", date: Date().addingTimeInterval(-200000), duration: 1290, type: 1)]
    }

    static let contacts = ContactBook(contacts: [PhoneContact(id: 1, displayName: "Ada Lovelace", photo: image(seed: 5, side: 96)),
                                                 PhoneContact(id: 2, displayName: "Grace Hopper")],
                                      numbers: [("+15550100", 1), ("+15550142", 2)], emails: [],
                                      displayNumbers: [("+1 555 0100", 1), ("+1 555 0142", 2)])

    static var conversations: [Conversation] {
        [
            Conversation(id: 1, participants: ["+1 555 0100"], messages: [
                message(1, thread: 1, minutesAgo: 95, "Are you coming to the review?", incoming: true, from: "+1 555 0100"),
                message(2, thread: 1, minutesAgo: 90, "Yes, ten minutes.", incoming: false, from: "+1 555 0100"),
                picture(7, thread: 1, minutesAgo: 30, "The whiteboard so far", from: "+1 555 0100"),
                message(3, thread: 1, minutesAgo: 4, "Room 4, we started.", incoming: true, read: false, from: "+1 555 0100"),
            ], pending: []),
            Conversation(id: 2, participants: ["Parcel"], messages: [
                message(4, thread: 2, minutesAgo: 60 * 26, "Your parcel will be delivered tomorrow between 9 and 12.", incoming: true, from: "Parcel"),
            ], pending: []),
            Conversation(id: 3, participants: ["+1 555 0142"], messages: [
                message(5, thread: 3, minutesAgo: 60 * 24 * 3, "Thanks, got it!", incoming: false, from: "+1 555 0142"),
            ], pending: [PendingMessage(id: 9, threadId: 3, recipients: [], body: "See you on Friday", date: Date(), state: .sending)]),
        ]
    }

    static let photos: [PhonePhoto] = (1...18).map { index in
        PhonePhoto(id: Int64(index), name: "20261009_10\(String(format: "%02d", index)).jpg", width: 4000, height: 3000, fileSize: 3_200_000,
                   taken: Date().addingTimeInterval(TimeInterval(-index * 3600)), checksum: Int64(index), thumbnail: image(seed: index, side: 256))
    }

    /// A phone's storage in small: folders with a few things in each.
    static let storage: [PhoneFile] = {
        let root = PhoneFileTree.usualRoot
        var files: [PhoneFile] = []
        var id: Int64 = 0
        func add(_ path: String, _ kind: PhoneFile.Kind = .other, size: Int64 = 0, folder: Bool = false, daysAgo: Double = 1) {
            id += 1
            files.append(PhoneFile(id: id, uri: "content://media/external/file/\(id)", name: (path as NSString).lastPathComponent, path: root + "/" + path, kind: kind,
                                   size: size, modified: Date().addingTimeInterval(-daysAgo * 86_400), checksum: id, isDirectory: folder))
        }
        for folder in ["DCIM", "DCIM/Camera", "Documents", "Download", "Music", "Pictures", "Pictures/Screenshots"] { add(folder, folder: true, daysAgo: 30) }
        for index in 1...6 { add("DCIM/Camera/20261009_10\(String(format: "%02d", index)).jpg", .image, size: 3_200_000 + Int64(index) * 41_000, daysAgo: Double(index)) }
        add("DCIM/Camera/20261008_183012.mp4", .video, size: 84_000_000, daysAgo: 2)
        add("Documents/Lease agreement.pdf", .document, size: 412_000, daysAgo: 12)
        add("Documents/Packing list.docx", .document, size: 23_500, daysAgo: 3)
        add("Download/boarding-pass.pdf", .document, size: 96_000, daysAgo: 0.2)
        add("Download/setup.apk", .other, size: 48_200_000, daysAgo: 9)
        add("Music/Analytical Engine - The Difference.mp3", .audio, size: 7_900_000, daysAgo: 60)
        add("Pictures/Screenshots/Screenshot_20261010_091500.png", .image, size: 640_000, daysAgo: 0.3)
        add("notes.txt", .document, size: 1_200, daysAgo: 5)
        return files
    }()

    static let phone = LinkedPhone(id: "demo-phone", name: "Galaxy S21+", model: "Samsung SM-G996B · Android 15", isOnline: true)
    /// A second linked phone, to show switching between phones.
    static let otherPhone = LinkedPhone(id: "demo-phone-2", name: "Pixel 9", model: "Google Pixel 9 · Android 16", isOnline: false)

    /// Transfers both ways, so the list shows how each kind looks.
    static var files: [ReceivedFileEntry] {
        // Empty files of the right kinds in a folder of their own, so that the list shows their icons.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Phone Mac Link Demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func entry(_ name: String, _ size: Int, minutesAgo: Double, sent: Bool) -> ReceivedFileEntry {
            let url = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: Data()) }
            return ReceivedFileEntry(name: name, url: url, size: size, date: Date().addingTimeInterval(-minutesAgo * 60), sent: sent)
        }
        return [entry("Quarterly report.pdf", 60_559, minutesAgo: 2, sent: false),
                entry("Screenshot 2026-10-09.png", 346_452, minutesAgo: 9, sent: true),
                entry("IMG_2041.jpg", 2_340_000, minutesAgo: 60, sent: false),
                entry("Trip plan.key", 19_781_438, minutesAgo: 60 * 26, sent: true)]
    }

    static var apps: [String: PhoneApp] {
        ["com.example.messages": PhoneApp(id: 1, packageName: "com.example.messages", name: "Messages", icon: DemoData.image(seed: 2, side: 64)),
         "com.example.calendar": PhoneApp(id: 2, packageName: "com.example.calendar", name: "Calendar", icon: DemoData.image(seed: 6, side: 64)),
         "com.example.mail": PhoneApp(id: 3, packageName: "com.example.mail", name: "Mail", icon: DemoData.image(seed: 9, side: 64)),
         "com.example.games": PhoneApp(id: 4, packageName: "com.example.games", name: "Word Game")]
    }
    static let pairingLink = "https://dcg.microsoft.com/dl?mvc=1000000&cpsi=00000000-0000-4000-8000-000000000000&vm=101&et=1791535221&r=5&ti=00000000000000000000000000000000"
}

/// Drives the interface with sample data. Nothing leaves the machine.
@MainActor
final class DemoActions: AppActions {
    private let model: AppModel

    init(model: AppModel, startConnected: Bool) {
        self.model = model
        model.embedsLivePages = false
        if startConnected { connect() }
    }

    private func connect() {
        model.accountName = "demo@example.com"
        model.phones = [DemoData.phone, DemoData.otherPhone]
        model.currentPhoneId = DemoData.phone.id
        model.notifications = DemoData.notifications
        model.phoneStatus = DemoData.status
        model.canRingPhone = true
        model.mediaSessions = [DemoData.mediaSession]
        model.callsEnabled = true
        model.calls = DemoData.calls
        model.photos = DemoData.photos
        model.conversations = DemoData.conversations
        model.contacts = DemoData.contacts
        model.receivedFiles = DemoData.files
        model.clipboardEvents = [ClipboardEvent(kind: .text, fromPhone: true, date: Date().addingTimeInterval(-120)),
                                 ClipboardEvent(kind: .image, fromPhone: false, date: Date().addingTimeInterval(-900)),
                                 ClipboardEvent(kind: .text, fromPhone: false, date: Date().addingTimeInterval(-2400))]
        model.apps = DemoData.apps
        if CommandLine.arguments.contains("--window-snapshot") {
            model.fileTransferStatus = "Sending Holiday video.mov"
            model.fileTransferProgress = 0.62
            model.fileTransferIsSending = true
        }
        model.phase = .connected(phoneName: DemoData.phone.name)
    }

    func signIn() { model.phase = .signingIn(code: "ABCD1234", url: "https://www.microsoft.com/link", expires: Date().addingTimeInterval(900)) }
    func cancelSignIn() { model.phase = .signedOut }
    func startPairing(manual: Bool) {
        model.phase = .linking(manual ? .enterPairingPIN(pin: "482913", expires: Date().addingTimeInterval(180))
                                      : .showLink(link: DemoData.pairingLink, expires: Date().addingTimeInterval(600), manualLink: nil, pairingPIN: nil))
    }
    func refreshChallengePIN() { model.phase = .linking(.confirmChallengePIN(pin: "QWERTY", expires: Date().addingTimeInterval(180))) }
    func retry() { model.phase = .signedOut }
    func signOut() { model.phones = []; model.notifications = []; model.accountName = nil; model.phase = .signedOut }
    func removePhone(_ phone: LinkedPhone) { model.phones.removeAll { $0.id == phone.id }; model.phase = .linking(nil) }
    func dismiss(_ notification: PhoneNotification) { model.notifications.removeAll { $0.key == notification.key } }
    func clearAll() { model.notifications = [] }
    func openOnPhone(_ notification: PhoneNotification) { dismiss(notification) }
    func invoke(_ action: PhoneNotification.Action, on notification: PhoneNotification) { dismiss(notification) }
    func reply(_ text: String, to notification: PhoneNotification) { dismiss(notification) }
    func setClipboardSync(_ enabled: Bool) { model.lastClipboardEvent = enabled ? "Sharing turned on" : "Sharing turned off" }
    func sendMessage(_ text: String, attachments: [OutgoingAttachment], in conversation: Conversation) {
        guard let index = model.conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        let next = (model.conversations[index].messages.map(\.messageId).max() ?? 0) + 1
        var message = PhoneMessage(kind: attachments.isEmpty ? .sms : .mms, messageId: next, threadId: conversation.id, date: Date(), body: text,
                                   isIncoming: false, isRead: true, address: conversation.title, subscriptionId: 1, attachmentCount: attachments.count)
        if !attachments.isEmpty {
            message.parts = attachments.enumerated().map { MessageAttachment(id: next * 100 + Int64($0.offset), contentType: $0.element.contentType, name: $0.element.name,
                                                                             size: Int64($0.element.data.count), preview: $0.element.data) }
        }
        model.conversations[index].messages.append(message)
    }
    func startConversation(with number: String, text: String) {
        let id = Int64(model.conversations.count + 100)
        model.conversations.insert(Conversation(id: id, participants: [number], messages: [
            PhoneMessage(kind: .sms, messageId: 1, threadId: id, date: Date(), body: text, isIncoming: false, isRead: true, address: number, subscriptionId: 1),
        ], pending: []), at: 0)
    }
    func discardFailedMessage(_ id: Int64) {}
    func markConversationRead(_ conversation: Conversation) {}
    func refreshMessages() { model.conversations = DemoData.conversations }
    func setUpSensitiveNotifications() { model.sensitiveNotificationsHidden = false }
    func cancelPermissionRequest() { model.waitingForPhonePermission = false }
    func refreshPhotos() { model.photos = DemoData.photos }
    func needThumbnails(_ ids: [Int64]) {}
    func loadAttachmentList(of message: PhoneMessage) async -> Bool { true }
    func fetchAttachment(_ attachment: MessageAttachment) async -> Data? { DemoData.image(seed: Int(attachment.id), side: 900) }
    func deletePhoto(_ photo: PhonePhoto) async -> String? { model.photos.removeAll { $0.id == photo.id }; return nil }
    func setMuted(_ muted: Bool, package: String) {
        if muted { model.mutedPackages.insert(package) } else { model.mutedPackages.remove(package) }
    }
    func setRule(_ rule: AppNotificationRule, package: String) { model.setRule(rule, for: package) }
    func sendLink(_ url: URL) { model.linkNotice = "Sent. On the phone, tap the notification to open it." }
    func bannersChanged() {}
    func setCallsEnabled(_ enabled: Bool) { model.callsEnabled = enabled; model.calls = enabled ? DemoData.calls : [] }
    func refreshCalls() { model.calls = DemoData.calls }
    func dialOnPhone(_ number: String) async -> String? { nil }
    func setBluetoothCalls(_ enabled: Bool) {
        model.bluetoothCallsEnabled = enabled
        model.callLink = enabled ? .connected : .off
    }
    func chooseCallDevice(_ address: String) { model.callDeviceAddress = address }
    func answerCall() {
        model.liveCall?.phase = .active
        model.liveCallSince = Date()
    }
    func endCall() { model.liveCall = nil; model.liveCallSince = nil }
    func placeCall(_ number: String) -> Bool {
        guard model.canPlaceCalls else { return false }
        model.liveCall = LiveCall(phase: .dialing, number: number)
        return true
    }
    func callTone(_ key: Character) {}
    func toggleCallHold() { model.liveCall?.phase = model.liveCall?.phase == .held ? .active : .held }
    func setCallMuted(_ muted: Bool) { model.callMuted = muted }
    func setFilesEnabled(_ enabled: Bool) { model.filesEnabled = enabled }
    func cancelFileTransfer() {
        model.fileTransferStatus = nil
        model.fileTransferProgress = nil
    }
    func startScreen(app: String?) {
        model.screenApp = app
        model.screenState = .waitingForPermission
    }
    func stopScreen() { model.screenState = .idle }
    func screenPointer(_ pointer: ScreenPointer) {}
    func screenKey(_ usage: UInt8, pressed: Bool) {}
    func screenGesture(_ gesture: NanoMirrorSession.Gesture) {}
    func wakeScreen() { model.screenLocked = false }
    func selectPhone(_ phone: LinkedPhone) {
        guard phone.isLinked, phone.id != model.currentPhoneId else { return }
        for index in model.phones.indices { model.phones[index].isOnline = model.phones[index].id == phone.id }
        model.currentPhoneId = phone.id
        // Another phone has other content: the sample notifications stay with the first.
        model.notifications = phone.id == DemoData.phone.id ? DemoData.notifications : []
        model.mediaSessions = phone.id == DemoData.phone.id ? [DemoData.mediaSession] : []
        model.phase = .connected(phoneName: phone.name)
    }
    func sendFiles(_ urls: [URL]) {
        for url in urls {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            model.receivedFiles.insert(ReceivedFileEntry(name: url.lastPathComponent, url: url, size: size, date: Date(), sent: true), at: 0)
        }
    }
    func ringPhone() { model.ringingUntil = Date().addingTimeInterval(20) }
    func stopRinging() { model.ringingUntil = nil }
    func setRinger(_ ringer: PhoneStatus.Ringer) { model.phoneStatus?.ringerMode = ringer == .silent ? 0 : ringer == .vibrate ? 1 : 2 }
    func setDoNotDisturb(_ on: Bool) { model.phoneStatus?.doNotDisturb = on ? 2 : 1 }
    func setSyncOverMobileData(_ on: Bool) { model.phoneStatus?.syncOverMobileData = on }
    func connectHotspot() {
        model.hotspotState = .asking
        Task {
            try? await Task.sleep(for: .seconds(1))
            model.hotspotState = .joining
            try? await Task.sleep(for: .seconds(1))
            model.hotspotState = .joined(network: "Galaxy S21+")
        }
    }
    func leaveHotspot() { model.hotspotState = .left }
    func setUpHotspot() { model.hotspotState = .settingUp }
    func media(_ command: MediaCommand, on session: PhoneNotification) {
        guard let index = model.mediaSessions.firstIndex(where: { $0.key == session.key }) else { return }
        switch command {
        case .play: model.mediaSessions[index].playbackState = 3
        case .pause: model.mediaSessions[index].playbackState = 2
        case .next, .previous: break
        }
    }
    func loadPhoneFiles(again: Bool) {
        model.storageTree = PhoneFileTree(files: DemoData.storage)
        model.storageSpace = AppModel.StorageSpace(available: 41_300_000_000, total: 128_000_000_000)
        model.storageListed = true
        model.storageState = .ready
    }
    func phoneFilePreview(_ file: PhoneFile, side: Int) async -> Data? { DemoData.image(seed: Int(file.id), side: side) }
    func downloadPhoneFile(_ file: PhoneFile) {
        model.receivedFiles.insert(ReceivedFileEntry(name: file.name, url: FileManager.default.temporaryDirectory.appendingPathComponent(file.name), size: Int(file.size), date: Date(), sent: false), at: 0)
    }
    func fetchPhoto(_ id: Int64) async -> FetchedPhoto? {
        guard let data = DemoData.image(seed: Int(id), side: 900) else { return nil }
        return FetchedPhoto(data: data, fileExtension: "jpg")
    }
}

/// Renders each screen to a PNG so layouts can be checked without launching the app.
@MainActor
enum Snapshots {
    static func render(to directory: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expires = Date().addingTimeInterval(540)
        let phases: [(String, AppPhase)] = [
            ("01-welcome", .signedOut),
            ("02-sign-in-code", .signingIn(code: "ABCD1234", url: "https://www.microsoft.com/link", expires: expires)),
            ("03-link-start", .linking(nil)),
            ("04-link-qr", .linking(.showLink(link: DemoData.pairingLink, expires: expires, manualLink: nil, pairingPIN: nil))),
            ("05-link-challenge-pin", .linking(.confirmChallengePIN(pin: "ETLXZB", expires: Date().addingTimeInterval(170)))),
            ("06-link-manual-pin", .linking(.enterPairingPIN(pin: "482913", expires: Date().addingTimeInterval(170)))),
            ("07-link-permissions", .linking(.approvePermissionsOnPhone)),
            ("08-link-mismatch", .linking(.failed(.accountMismatch))),
            ("09-link-expired", .linking(.failed(.linkExpired))),
            ("10-pin-expired", .linking(.challengePINProblem(expired: true))),
            ("11-failed", .failed(message: "The connection to Microsoft's service was lost.", canRetry: true)),
        ]
        for (name, phase) in phases {
            let model = AppModel()
            model.embedsLivePages = false
            model.phase = phase
            write(OnboardingView(model: model).frame(width: 860, height: 560), to: directory.appendingPathComponent(name + ".png"))
        }
        write(SignInView(code: "ABCD1234", url: "https://www.microsoft.com/link", expires: expires, embedsPage: false, placeholderPage: true) {}
            .padding(24).frame(width: 860, height: 560), to: directory.appendingPathComponent("02b-sign-in-page.png"))
        let connected = AppModel()
        connected.accountName = "demo@example.com"
        connected.phones = [DemoData.phone]
        connected.notifications = DemoData.notifications
        connected.phoneStatus = DemoData.status
        connected.canRingPhone = true
        connected.mediaSessions = [DemoData.mediaSession]
        connected.phase = .connected(phoneName: DemoData.phone.name)
        connected.lastClipboardEvent = "Text copied on Galaxy S21+ · 2 minutes ago"
        write(NavigationStack { NotificationsView(model: connected) }.frame(width: 660, height: 560), to: directory.appendingPathComponent("12-notifications.png"))
        connected.sensitiveNotificationsHidden = true
        write(NavigationStack { NotificationsView(model: connected) }.frame(width: 660, height: 560), to: directory.appendingPathComponent("12b-notifications-hidden.png"))
        connected.waitingForPhonePermission = true
        write(NavigationStack { NotificationsView(model: connected) }.frame(width: 660, height: 560), to: directory.appendingPathComponent("12c-notifications-check-phone.png"))
        connected.sensitiveNotificationsHidden = false
        connected.waitingForPhonePermission = false
        write(NavigationStack { ClipboardView(model: connected) }.frame(width: 660, height: 420), to: directory.appendingPathComponent("13-clipboard.png"))
        write(NavigationStack { DevicesView(model: connected) }.frame(width: 660, height: 420), to: directory.appendingPathComponent("14-devices.png"))
        connected.conversations = DemoData.conversations
        connected.contacts = DemoData.contacts
        write(NavigationStack { MessagesView(model: connected) }.frame(width: 760, height: 520), to: directory.appendingPathComponent("18-messages.png"))
        let many = ContactBook(contacts: [PhoneContact(id: 1, displayName: "Ada Lovelace", company: "Analytical Engines", photo: DemoData.image(seed: 5, side: 96)),
                                          PhoneContact(id: 2, displayName: "Grace Hopper"), PhoneContact(id: 3, displayName: "Alan Turing"),
                                          PhoneContact(id: 4, displayName: "Édouard Lucas"), PhoneContact(id: 5, displayName: "Hedy Lamarr"),
                                          PhoneContact(id: 6, displayName: "", company: "Pizza Place"), PhoneContact(id: 7, displayName: "3D Print Shop")],
                               numbers: [("+15550100", 1), ("+15550101", 1), ("+15550142", 2), ("+15550103", 3), ("+15550104", 4), ("+15550105", 5), ("+15550106", 6), ("+15550107", 7)],
                               emails: [], displayNumbers: [("+1 555 0100", 1), ("+1 555 0101", 1), ("+1 555 0142", 2), ("+1 555 0103", 3), ("+1 555 0104", 4), ("+1 555 0105", 5), ("+1 555 0106", 6), ("+1 555 0107", 7)])
        let people = AppModel()
        people.phase = .connected(phoneName: DemoData.phone.name)
        people.contacts = many
        write(NavigationStack { ContactsView(model: people) }.frame(width: 770, height: 520), to: directory.appendingPathComponent("26-contacts.png"))
        connected.callsEnabled = true
        connected.calls = DemoData.calls
        write(NavigationStack { CallsView(model: connected) }.frame(width: 770, height: 560), to: directory.appendingPathComponent("21-calls.png"))
        connected.photos = DemoData.photos
        write(NavigationStack { PhotosView(model: connected) }.frame(width: 660, height: 520), to: directory.appendingPathComponent("17-photos.png"))
        write(VStack(spacing: 0) { DeviceCard(model: connected).padding(12); Spacer(); SidebarFooter(model: connected) }.frame(width: 230, height: 300), to: directory.appendingPathComponent("16-sidebar-status.png"))
        connected.ringingUntil = Date().addingTimeInterval(14)
        connected.controlNotice = PhoneControlError.needsPermission.explanation
        write(VStack(spacing: 0) { DeviceCard(model: connected).padding(12); Spacer(); SidebarFooter(model: connected) }.frame(width: 230, height: 340), to: directory.appendingPathComponent("16b-sidebar-ringing.png"))
        connected.ringingUntil = nil
        connected.controlNotice = nil
        connected.apps = DemoData.apps
        connected.mutedPackages = ["com.example.games"]
        write(AppNotificationSettings(model: connected).frame(width: 480, height: 380), to: directory.appendingPathComponent("19-settings-notifications.png"))
        if let first = connected.notifyingApps.first?.package, let second = connected.notifyingApps.dropFirst().first?.package {
            connected.setRule(AppNotificationRule(sound: false), for: first)
            connected.setRule(AppNotificationRule(banner: false, badge: false), for: second)
        }
        write(AppNotificationSheet(model: connected), to: directory.appendingPathComponent("19b-notification-apps-sheet.png"))
        write(NavigationStack { NotificationsView(model: connected) }.frame(width: 660, height: 300), to: directory.appendingPathComponent("12d-notifications-gear.png"))
        connected.appRules = [:]
        connected.mutedPackages = ["com.example.games"]
        write(GeneralSettings(model: connected).frame(width: 480, height: 380), to: directory.appendingPathComponent("20-settings-general.png"))
        // A call over Bluetooth: ringing, as its own panel shows it, and spoken, in the Calls section.
        connected.bluetoothCallsEnabled = true
        connected.callLink = .connected
        connected.phoneStatus?.network = .cellular
        connected.phoneStatus?.syncOverMobileData = false
        write(GeneralSettings(model: connected).frame(width: 480, height: 620), to: directory.appendingPathComponent("20b-settings-general-calls.png"))
        write(VStack(spacing: 0) { DeviceCard(model: connected).padding(12); Spacer() }.frame(width: 230, height: 220), to: directory.appendingPathComponent("16c-sidebar-mobile-data.png"))
        connected.phoneStatus = DemoData.status
        connected.liveCall = LiveCall(phase: .incoming, number: "+15550100")
        for (name, phase) in [("24-call-panel-incoming", LiveCall.Phase.incoming), ("24b-call-panel-calling", .dialing), ("24c-call-panel-active", .active)] {
            connected.liveCall = LiveCall(phase: phase, number: phase == .dialing ? "+15550177" : "+15550100")
            connected.liveCallSince = phase == .active ? Date().addingTimeInterval(-42) : nil
            write(LiveCallCard(model: connected).background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .environment(\.colorScheme, .dark).padding(20).background(Color(white: 0.45)),
                  to: directory.appendingPathComponent(name + ".png"))
        }
        connected.liveCall = LiveCall(phase: .active, number: "+15550100")
        connected.liveCallSince = Date().addingTimeInterval(-42)
        write(NavigationStack { CallsView(model: connected) }.frame(width: 770, height: 560), to: directory.appendingPathComponent("21b-calls-in-call.png"))
        connected.liveCall = nil
        connected.callsEnabled = false
        write(NavigationStack { CallsView(model: connected) }.frame(width: 770, height: 560), to: directory.appendingPathComponent("21c-calls-no-history.png"))
        connected.callsEnabled = true
        _ = connected.noteLink(PhoneLinkItem(url: URL(string: "https://example.com/article")!, title: "An Article Worth Reading", source: .app("Samsung Internet"), date: Date().addingTimeInterval(-300)))
        _ = connected.noteLink(PhoneLinkItem(url: URL(string: "https://maps.example/xyz")!, title: "maps.example", source: .copied))
        connected.linkNotice = "Sent. On the phone, tap the notification to open it."
        write(NavigationStack { LinksView(model: connected) }.frame(width: 660, height: 460), to: directory.appendingPathComponent("25-links.png"))
        connected.receivedFiles = DemoData.files
        connected.fileTransferStatus = "Receiving Notes.docx"
        connected.fileTransferProgress = 0.4
        write(NavigationStack { FilesView(model: connected) }.frame(width: 660, height: 420), to: directory.appendingPathComponent("23-files.png"))
        connected.fileTransferStatus = nil
        connected.fileTransferProgress = nil
        write(MainView(model: connected).frame(width: 900, height: 600), to: directory.appendingPathComponent("22-main-window.png"))
        write(MenuBarPanel(model: connected).background(.regularMaterial), to: directory.appendingPathComponent("29a-menu-panel.png"))
        write(MenuBarPanel(model: connected).background(Color(nsColor: .windowBackgroundColor)), to: directory.appendingPathComponent("29b-menu-panel-dark.png"), dark: true)
        write(NavigationStack { StorageView(model: connected) }.frame(width: 700, height: 440), to: directory.appendingPathComponent("28a-storage-start.png"))
        connected.storageTree = PhoneFileTree(files: DemoData.storage)
        connected.storageSpace = AppModel.StorageSpace(available: 41_300_000_000, total: 128_000_000_000)
        connected.storageListed = true
        connected.storageState = .ready
        write(NavigationStack { StorageView(model: connected) }.frame(width: 700, height: 440), to: directory.appendingPathComponent("28b-storage-top.png"))
        connected.storageListed = false
        connected.storageState = .loading(received: 15_000, expected: 42_000)
        write(NavigationStack { StorageView(model: connected) }.frame(width: 700, height: 440), to: directory.appendingPathComponent("28c-storage-loading.png"))
        connected.storageState = .needsPermission
        write(NavigationStack { StorageView(model: connected) }.frame(width: 700, height: 440), to: directory.appendingPathComponent("28d-storage-permission.png"))
        connected.storageState = .idle
        write(StoragePreview(file: DemoData.storage[8], model: connected) {}, to: directory.appendingPathComponent("28e-storage-preview.png"))
        connected.favoriteApps = Array(connected.apps.keys.sorted().prefix(2))
        connected.recentApps = Array(connected.apps.keys.sorted().dropFirst(2).prefix(3))
        write(NavigationStack { AppsView(model: connected) }.frame(width: 660, height: 520), to: directory.appendingPathComponent("27-apps-shelves.png"))
        connected.screenState = .live
        connected.screenInOwnWindow = true
        write(NavigationStack { ScreenView(model: connected) }.frame(width: 660, height: 460), to: directory.appendingPathComponent("26-screen-elsewhere.png"))
        let ownWindow = ScreenWindowLayout.initial(picture: connected.screenShownSize, visible: CGSize(width: 1440, height: 860))
        write(ScreenWindowView(model: connected).frame(width: ownWindow.width, height: ownWindow.height), to: directory.appendingPathComponent("26b-screen-window.png"))
        connected.screenState = .waitingForPermission
        write(ScreenWindowView(model: connected).frame(width: ownWindow.width, height: ownWindow.height), to: directory.appendingPathComponent("26c-screen-window-waiting.png"))
        connected.screenState = .idle
        connected.screenInOwnWindow = false
        write(NavigationStack { ScreenView(model: connected) }.frame(width: 660, height: 460), to: directory.appendingPathComponent("26d-screen-start.png"))
        let empty = AppModel()
        empty.phase = .connected(phoneName: DemoData.phone.name)
        write(NavigationStack { NotificationsView(model: empty) }.frame(width: 660, height: 420), to: directory.appendingPathComponent("15-notifications-empty.png"))
        print("snapshots written to \(directory.path)")
    }

    /// Renders through a real, never-shown window. SwiftUI's offscreen `ImageRenderer` cannot
    /// draw AppKit-backed controls such as lists, forms and link buttons.
    private static func write(_ view: some View, to url: URL, dark: Bool = false) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("could not render \(url.lastPathComponent)")
            return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
