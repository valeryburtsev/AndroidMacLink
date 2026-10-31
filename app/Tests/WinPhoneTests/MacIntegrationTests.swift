import AppKit
import UserNotifications
import XCTest
@testable import WinPhone
@testable import WinPhoneCore

final class MacClipboardTests: XCTestCase {
    /// A private, uniquely named pasteboard, so tests never touch the user's clipboard.
    func makeClipboard() -> (MacClipboard, NSPasteboard) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("winphone.tests.\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        return (MacClipboard(pasteboard: pasteboard), pasteboard)
    }

    func testTextRoundTrip() async {
        let (clipboard, pasteboard) = makeClipboard()
        let empty = await clipboard.read()
        XCTAssertNil(empty)
        await clipboard.write(.text("Привет ✓ naïve 日本語"))
        XCTAssertEqual(pasteboard.string(forType: .string), "Привет ✓ naïve 日本語")
        let read = await clipboard.read()
        XCTAssertEqual(read, .text("Привет ✓ naïve 日本語"))
    }

    func testHTMLAlsoOffersPlainText() async {
        let (clipboard, pasteboard) = makeClipboard()
        await clipboard.write(.html("<p>Hello <b>world</b></p>"))
        XCTAssertEqual(pasteboard.string(forType: .html), "<p>Hello <b>world</b></p>")
        XCTAssertEqual(pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), "Hello world")
        let read = await clipboard.read()
        XCTAssertEqual(read, .html("<p>Hello <b>world</b></p>"))
    }

    /// As macOS puts text copied in Preview on the clipboard: a whole document with a style
    /// sheet in its head. Only the body goes to the phone.
    func testHTMLCopiedFromRichTextGoesToThePhoneWithoutItsHead() throws {
        let document = """
        <!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
        <html>
        <head>
        <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
        <meta http-equiv="Content-Style-Type" content="text/css">
        <title></title>
        <meta name="Generator" content="Cocoa HTML Writer">
        <style type="text/css">
        p.p1 {margin: 0.0px 0.0px 0.0px 0.0px; font: 12.0px Helvetica}
        span.s1 {font-kerning: none}
        </style>
        </head>
        <body>
        <p class="p1"><span class="s1">Invoice 42 is due on <b>1 November</b>.</span></p>
        <!-- a comment -->
        </body>
        </html>
        """
        let cleaned = try XCTUnwrap(MacClipboard.cleanedHTML(document))
        XCTAssertFalse(cleaned.contains("margin"), "no style sheet")
        XCTAssertFalse(cleaned.lowercased().contains("<head") || cleaned.lowercased().contains("<meta") || cleaned.contains("<!"))
        XCTAssertTrue(cleaned.hasPrefix("<p class=\"p1\">"))
        XCTAssertTrue(cleaned.contains("<b>1 November</b>"), "formatting kept")
        XCTAssertEqual(MacClipboard.plainText(fromHTML: cleaned).trimmingCharacters(in: .whitespacesAndNewlines), "Invoice 42 is due on 1 November.")
        XCTAssertTrue(MacClipboard.isMadeFromRichText(document), "this one goes as plain text")
        XCTAssertFalse(MacClipboard.isMadeFromRichText("<meta charset='utf-8'><b>from a web page</b>"))
        // A fragment, as browsers copy: unchanged.
        XCTAssertEqual(MacClipboard.cleanedHTML("<b>bold</b> text"), "<b>bold</b> text")
        // Nothing readable: nil, so that the plain text is sent instead.
        XCTAssertNil(MacClipboard.cleanedHTML("<html><head><style>p{}</style></head><body> </body></html>"))
    }

    func testPlainTextFromHTMLDropsMarkupAndRunsNothing() {
        XCTAssertEqual(MacClipboard.plainText(fromHTML: "<p>Hello <b>world</b></p><p>Second&nbsp;line</p>"), "Hello world\nSecond line")
        XCTAssertEqual(MacClipboard.plainText(fromHTML: "one<br>two<BR/>three"), "one\ntwo\nthree")
        XCTAssertEqual(MacClipboard.plainText(fromHTML: "<style>p{color:red}</style><script>alert(1)</script><!-- note -->text"), "text")
        XCTAssertEqual(MacClipboard.plainText(fromHTML: "a &lt;b&gt; &amp; &quot;c&quot; &#233; &#x263A; &amp;lt;"), "a <b> & \"c\" é ☺ &lt;")
        XCTAssertEqual(MacClipboard.plainText(fromHTML: "<img src=\"https://example.com/x.png\">"), "")
        XCTAssertEqual(MacClipboard.plainText(fromHTML: "<ul><li>one</li><li>two</li></ul>"), "one\ntwo")
        XCTAssertEqual(MacClipboard.plainText(fromHTML: "a < b and c > d"), "a d", "a tag is whatever lies between the brackets")
        XCTAssertEqual(MacClipboard.plainText(fromHTML: "1 < 2"), "1 < 2", "a bracket that opens nothing is text")
        XCTAssertEqual(MacClipboard.plainText(fromHTML: "kept <!-- never closed"), "kept")
        XCTAssertEqual(MacClipboard.plainText(fromHTML: "AT&T &unknown; &#xZZ;"), "AT&T &unknown; &#xZZ;")
    }

    func testMarkupBuiltToBeSlowIsReadInLinearTime() {
        // Each of these made the earlier, pattern-based version take seconds.
        for hostile in [String(repeating: "<", count: 120_000), String(repeating: "<!--", count: 30_000), String(repeating: "<script ", count: 15_000),
                        String(repeating: "&", count: 120_000)] {
            let start = ContinuousClock.now
            _ = MacClipboard.plainText(fromHTML: hostile)
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
        }
    }

    func testImageIsReadBackAsPNG() async throws {
        let (clipboard, _) = makeClipboard()
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        await clipboard.write(.image(png))
        guard case .image(let data)? = await clipboard.read() else { return XCTFail("expected an image") }
        XCTAssertEqual(data.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "PNG signature")
        XCTAssertNotNil(NSImage(data: data))
    }

    /// A noisy image, which PNG cannot compress, standing in for a large screenshot or photo.
    func noisyBitmap(side: Int) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        var generator = SystemRandomNumberGenerator()
        let pixels = bitmap.bitmapData!
        for index in 0..<(bitmap.bytesPerRow * side) { pixels[index] = index % 4 == 3 ? 255 : UInt8.random(in: 0...255, using: &generator) }
        return bitmap
    }

    func testLargeImagesAreShrunkToThePhonesLimit() async throws {
        let (clipboard, pasteboard) = makeClipboard()
        let big = noisyBitmap(side: 1400)
        let png = try XCTUnwrap(big.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, ClipboardContent.maxImageBytes, "the test image must exceed the limit as PNG")
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)

        guard case .image(let sent)? = await clipboard.read() else { return XCTFail("a large image must still be offered") }
        XCTAssertLessThanOrEqual(sent.count, MacClipboard.imageByteLimit)
        XCTAssertLessThanOrEqual(sent.count, ClipboardContent.maxImageBytes)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: sent), "what we send is a readable image")
        XCTAssertGreaterThan(decoded.pixelsWide, 100)

        // A small image goes out untouched, as PNG.
        let small = try XCTUnwrap(noisyBitmap(side: 64).representation(using: .png, properties: [:]))
        pasteboard.clearContents()
        pasteboard.setData(small, forType: .png)
        guard case .image(let untouched)? = await clipboard.read() else { return XCTFail() }
        XCTAssertEqual(untouched, small)
    }

    func testConcealedContentIsNeverRead() async {
        let (clipboard, pasteboard) = makeClipboard()
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let read = await clipboard.read()
        XCTAssertNil(read, "password managers mark secrets this way")
    }

    func testOwnWritesAreToldApartFromUserCopies() async {
        let (clipboard, pasteboard) = makeClipboard()
        await clipboard.write(.text("from phone"))
        XCTAssertTrue(clipboard.lastChangeWasOurs)
        pasteboard.clearContents()
        pasteboard.setString("typed by user", forType: .string)
        XCTAssertFalse(clipboard.lastChangeWasOurs)
    }

    func testWatcherReportsOnlyForeignChanges() async {
        let (clipboard, pasteboard) = makeClipboard()
        let counter = Counter()
        let task = clipboard.watch(every: .milliseconds(10)) { await counter.increment() }
        await clipboard.write(.text("from phone"))
        try? await Task.sleep(for: .milliseconds(80))
        let afterOwnWrite = await counter.value
        XCTAssertEqual(afterOwnWrite, 0)
        pasteboard.clearContents()
        pasteboard.setString("typed by user", forType: .string)
        let deadline = Date().addingTimeInterval(2)
        while await counter.value == 0, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        let afterUserCopy = await counter.value
        XCTAssertEqual(afterUserCopy, 1)
        task.cancel()
    }
}

actor Counter {
    var value = 0
    func increment() { value += 1 }
}

final class MacNotifierTests: XCTestCase {
    func notification(reply: Bool, buttons: [String]) -> PhoneNotification {
        DemoData.notification(key: "k", app: "Chat", package: "com.example.chat", title: "Ada", text: "hi", minutesAgo: 1, reply: reply, buttons: buttons)
    }

    func testCategoryReflectsTheActionSet() {
        let withReply = MacNotifier.category(for: notification(reply: true, buttons: ["Mark as read"]))
        XCTAssertEqual(withReply.actions.map(\.identifier), ["reply.0", "action.1"])
        XCTAssertTrue(withReply.actions[0] is UNTextInputNotificationAction)
        XCTAssertEqual(withReply.actions[1].title, "Mark as read")
        XCTAssertTrue(withReply.options.contains(.customDismissAction), "so dismissing the banner can dismiss on the phone")

        let plain = MacNotifier.category(for: notification(reply: false, buttons: []))
        XCTAssertTrue(plain.actions.isEmpty)
        XCTAssertNotEqual(plain.identifier, withReply.identifier)
        XCTAssertEqual(MacNotifier.categoryIdentifier(for: notification(reply: true, buttons: ["Mark as read"])), withReply.identifier,
                       "the same buttons share one category")
        let many = MacNotifier.category(for: notification(reply: false, buttons: ["A", "B", "C", "D", "E"]))
        XCTAssertEqual(many.actions.count, 3)
    }

    func testResponsesMapToPhoneCommands() {
        XCTAssertEqual(MacNotifier.response(actionIdentifier: "reply.0", key: "k", text: "on my way"), .reply(key: "k", text: "on my way"))
        XCTAssertNil(MacNotifier.response(actionIdentifier: "reply.0", key: "k", text: ""), "an empty reply is not sent")
        XCTAssertEqual(MacNotifier.response(actionIdentifier: "action.2", key: "k", text: nil), .action(key: "k", index: 2))
        XCTAssertEqual(MacNotifier.response(actionIdentifier: UNNotificationDefaultActionIdentifier, key: "k", text: nil), .open(key: "k"))
        XCTAssertEqual(MacNotifier.response(actionIdentifier: UNNotificationDismissActionIdentifier, key: "k", text: nil), .dismissed(key: "k"))
        XCTAssertNil(MacNotifier.response(actionIdentifier: "action.x", key: "k", text: nil))
        XCTAssertNil(MacNotifier.response(actionIdentifier: "something.else", key: "k", text: nil))
    }
}

final class ReceivedFileTests: XCTestCase {
    func testAFileFromThePhoneIsSavedUnderItsNameWithoutReplacingAnything() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winphone-received-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try XCTUnwrap(ReceivedFiles.save(ReceivedFile(name: "Report.pdf", data: Data([1, 2, 3])), to: folder))
        XCTAssertEqual(first.lastPathComponent, "Report.pdf")
        let second = try XCTUnwrap(ReceivedFiles.save(ReceivedFile(name: "Report.pdf", data: Data([9])), to: folder))
        XCTAssertEqual(second.lastPathComponent, "Report 2.pdf", "a file already there is never replaced")
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: second), Data([9]))
        XCTAssertNotNil(try first.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties, "marked as a download")
        // A name that tries to leave the folder, or hide, is reduced to a plain one.
        let escaping = try XCTUnwrap(ReceivedFiles.save(ReceivedFile(name: "../../.hidden/evil.sh", data: Data([0])), to: folder))
        XCTAssertEqual(escaping.deletingLastPathComponent().standardizedFileURL.path, folder.standardizedFileURL.path)
        XCTAssertFalse(escaping.lastPathComponent.hasPrefix("."))
        let unnamed = try XCTUnwrap(ReceivedFiles.save(ReceivedFile(name: "", data: Data([0])), to: folder))
        XCTAssertFalse(unnamed.lastPathComponent.isEmpty)
    }

    func testAFileThatArrivedOnDiskIsMovedIntoPlaceWithoutReplacingAnything() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winphone-received-\(UUID().uuidString)")
        let incoming = folder.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func arrived(_ bytes: [UInt8]) throws -> ReceivedFile {
            let url = incoming.appendingPathComponent(UUID().uuidString + ".part")
            try Data(bytes).write(to: url)
            return ReceivedFile(name: "Clip.mp4", content: .file(url, size: bytes.count))
        }
        let first = try XCTUnwrap(ReceivedFiles.save(try arrived([1, 2, 3]), to: folder))
        let second = try XCTUnwrap(ReceivedFiles.save(try arrived([4, 5]), to: folder))
        XCTAssertEqual(first.lastPathComponent, "Clip.mp4")
        XCTAssertEqual(second.lastPathComponent, "Clip 2.mp4", "a file already there is never replaced")
        XCTAssertEqual(try Data(contentsOf: first), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: second), Data([4, 5]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: incoming.path), [], "moved, not copied")
        XCTAssertNotNil(try first.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties, "marked as a download")
        // One whose file has gone is reported as not saved.
        XCTAssertNil(ReceivedFiles.save(ReceivedFile(name: "Gone.bin", content: .file(incoming.appendingPathComponent("missing.part"), size: 1)), to: folder))
    }
}

final class AttachmentFileTests: XCTestCase {
    func attachment(_ type: String, _ name: String) -> MessageAttachment { MessageAttachment(id: 5, contentType: type, name: name) }

    func testOnlyViewableKindsAreOpened() {
        XCTAssertTrue(AttachmentFiles.isSafeToOpen(attachment("image/jpeg", "a.jpg")))
        XCTAssertTrue(AttachmentFiles.isSafeToOpen(attachment("video/mp4", "")))
        XCTAssertTrue(AttachmentFiles.isSafeToOpen(attachment("audio/mpeg", "")))
        XCTAssertTrue(AttachmentFiles.isSafeToOpen(attachment("application/pdf", "")))
        XCTAssertTrue(AttachmentFiles.isSafeToOpen(attachment("text/x-vcard; charset=utf-8", "c.vcf")) || AttachmentFiles.isSafeToOpen(attachment("text/vcard", "c.vcf")))
        XCTAssertFalse(AttachmentFiles.isSafeToOpen(attachment("application/x-sh", "run.command")))
        XCTAssertFalse(AttachmentFiles.isSafeToOpen(attachment("application/octet-stream", "tool.app")))
        XCTAssertFalse(AttachmentFiles.isSafeToOpen(attachment("made/up", "x")))
        XCTAssertFalse(AttachmentFiles.isSafeToOpen(attachment("image/svg+xml", "drawing.svg")), "a picture that can carry scripts")
        XCTAssertFalse(AttachmentFiles.isSafeToOpen(attachment("text/html", "page.html")))
        // Playlists and stream descriptions make a player contact hosts the sender chose.
        for type in ["audio/x-mpegurl", "application/vnd.apple.mpegurl", "application/sdp", "video/x-ms-asx", "audio/x-pn-realaudio", "text/csv", "text/markdown"] {
            XCTAssertFalse(AttachmentFiles.isSafeToOpen(attachment(type, "file")), type)
        }
        XCTAssertTrue(AttachmentFiles.isSafeToOpen(attachment("text/plain", "note.txt")))
        XCTAssertTrue(AttachmentFiles.isSafeToOpen(attachment("image/png", "")))
        XCTAssertTrue(AttachmentFiles.isSafeToOpen(attachment("video/3gpp", "")))
    }

    func testTheNameFollowsTheDeclaredTypeNotTheSender() {
        XCTAssertEqual(AttachmentFiles.fileName(for: attachment("image/jpeg", "beach.jpg")), "beach.jpg")
        XCTAssertEqual(AttachmentFiles.fileName(for: attachment("image/jpeg", "holiday.command")), "holiday.jpeg")
        let escaping = AttachmentFiles.fileName(for: attachment("image/png", "../../etc/x"))
        XCTAssertFalse(escaping.contains("/"))
        XCTAssertFalse(escaping.hasPrefix("."))
        XCTAssertTrue(escaping.hasSuffix(".png"))
        XCTAssertEqual(AttachmentFiles.fileName(for: attachment("made/up", "tool.command")), "tool.command.download")
        XCTAssertEqual(AttachmentFiles.fileName(for: attachment("made/up", "notes.xyz")), "notes.xyz.download", "an unknown ending is not trusted")
        XCTAssertEqual(AttachmentFiles.fileName(for: attachment("application/octet-stream", "photo.jpg")), "photo.jpg", "a harmless ending is kept")
        for risky in ["x.terminal", "x.webloc", "x.inetloc", "x.fileloc", "x.workflow", "x.mobileconfig", "x.pkg", "x.dmg", "x.html", "x.svg", "x.url"] {
            XCTAssertTrue(AttachmentFiles.fileName(for: attachment("application/octet-stream", risky)).hasSuffix(".download"), risky)
        }
        XCTAssertFalse(AttachmentFiles.fileName(for: attachment("image/gif", "")).isEmpty)
        XCTAssertFalse(AttachmentFiles.safeName("a/b:c").contains("/"))
    }

    func testAPictureToSendIsShrunkToWhatCarriersAccept() throws {
        // A large, noisy picture that will not fit as it is.
        let side = 2400
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        var generator = SystemRandomNumberGenerator()
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for index in 0..<(bitmap.bytesPerRow * side) { pixels[index] = index % 4 == 3 ? 255 : UInt8.random(in: 0...255, using: &generator) }
        let source = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(source.count, OutgoingPicture.byteLimit)
        let picture = try XCTUnwrap(OutgoingPicture.make(from: source, name: "holiday/2026"))
        XCTAssertLessThanOrEqual(picture.data.count, OutgoingPicture.byteLimit)
        XCTAssertEqual(picture.contentType, "image/jpeg")
        XCTAssertEqual(picture.name, "holiday_2026.jpg")
        XCTAssertNotNil(NSImage(data: picture.data))
        XCTAssertNil(OutgoingPicture.make(from: Data("not a picture".utf8), name: "x"))
    }

    func testTemporaryCopiesAreWrittenPrivatelyAndRemoved() throws {
        let url = try XCTUnwrap(AttachmentFiles.write(Data([1, 2, 3]), named: "x.jpg"))
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertTrue(url.path.hasPrefix(AttachmentFiles.folder.path))
        let mark = try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        XCTAssertNotNil(mark, "marked as a download, so macOS checks it before first use")
        AttachmentFiles.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    /// Per app: in the list at all, as a Mac notification, with sound, counted.
    func testEachAppHasItsOwnRuleAndTheRulesAreRemembered() throws {
        let suite = "winphone.tests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        // From before apps had more than an on and off: the old list is taken over.
        store.set(["com.example.games"], forKey: AppModel.mutedPackagesKey)
        let model = AppModel()
        model.preferenceStore = store
        XCTAssertEqual(model.mutedPackages, ["com.example.games"])
        XCTAssertEqual(model.rule(for: "com.example.games"), AppNotificationRule(list: false))
        model.notifications = DemoData.notifications
        let packages = model.notifications.map(\.packageName)
        XCTAssertEqual(model.rule(for: packages[0]), AppNotificationRule(), "everything, unless said otherwise")
        XCTAssertTrue(model.wantsBanner(model.notifications[0]))
        XCTAssertEqual(model.dockBadge == nil, true, "not connected, no badge")
        XCTAssertEqual(model.countedNotifications.count, 3)

        // Seen but not counted.
        model.setRule(AppNotificationRule(badge: false), for: packages[0])
        XCTAssertEqual(model.visibleNotifications.count, 3)
        XCTAssertEqual(model.countedNotifications.count, 3 - packages.filter { $0 == packages[0] }.count)
        XCTAssertTrue(model.wantsBanner(model.notifications[0]))
        // In the list, but no Mac notification.
        model.setRule(AppNotificationRule(banner: false), for: packages[0])
        XCTAssertFalse(model.wantsBanner(model.notifications[0]))
        XCTAssertEqual(model.visibleNotifications.count, 3)
        XCTAssertEqual(model.countedNotifications.count, 3)
        // Quiet.
        model.setRule(AppNotificationRule(sound: false), for: packages[0])
        XCTAssertTrue(model.wantsBanner(model.notifications[0]))
        XCTAssertFalse(model.rule(for: packages[0]).sound)
        // Banners off for everything overrules an app's own yes.
        model.showsBanners = false
        XCTAssertFalse(model.wantsBanner(model.notifications[0]))
        model.showsBanners = true

        XCTAssertNil(AppNotificationRule().summary)
        XCTAssertEqual(AppNotificationRule(sound: false).summary, "No sound")
        XCTAssertEqual(AppNotificationRule(banner: false, sound: false, badge: false).summary, "No banners · Not counted", "no banner, so the sound is beside the point")
        XCTAssertEqual(AppNotificationRule(list: false).summary, "Off")

        let later = AppModel()
        later.preferenceStore = store
        XCTAssertEqual(later.rule(for: packages[0]), AppNotificationRule(sound: false))
        XCTAssertEqual(later.mutedPackages, ["com.example.games"])
        // Back to the usual leaves no entry; switching an app on again keeps its finer choices.
        later.setRule(AppNotificationRule(), for: packages[0])
        XCTAssertEqual(Set(later.appRules.keys), ["com.example.games"])
        later.setRule(AppNotificationRule(list: false, badge: false), for: "com.example.games")
        later.mutedPackages.remove("com.example.games")
        XCTAssertEqual(later.rule(for: "com.example.games"), AppNotificationRule(badge: false))
        XCTAssertTrue(later.notifyingApps.contains { $0.package == "com.example.games" }, "an app with a rule stays in the list")
    }

    func testAnAppSwitchedOffIsHiddenAndRemembered() throws {
        let suite = "winphone.tests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let model = AppModel()
        model.preferenceStore = store
        XCTAssertTrue(model.showsBanners, "on unless the user said otherwise")
        model.notifications = DemoData.notifications
        XCTAssertEqual(model.visibleNotifications.count, 3)
        model.mutedPackages.insert("com.example.mail")
        XCTAssertEqual(model.visibleNotifications.map(\.key), ["n1", "n2"])
        XCTAssertEqual(model.notifications.count, 3, "still known, so switching the app back on shows it again")
        model.showsBanners = false

        let later = AppModel()
        later.preferenceStore = store
        XCTAssertEqual(later.mutedPackages, ["com.example.mail"])
        XCTAssertFalse(later.showsBanners)
        // The settings list names every app that can notify, also one switched off earlier.
        later.notifications = DemoData.notifications
        XCTAssertEqual(later.notifyingApps.map(\.name), ["Calendar", "Mail", "Messages"])
    }

    func testTheClipboardSwitchIsRemembered() throws {
        let suite = "winphone.tests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let first = AppModel()
        first.preferenceStore = store
        XCTAssertTrue(first.clipboardSyncEnabled, "on until the user says otherwise")
        first.clipboardSyncEnabled = false
        let second = AppModel()
        second.preferenceStore = store
        XCTAssertFalse(second.clipboardSyncEnabled)
        XCTAssertEqual(store.object(forKey: AppModel.clipboardEnabledKey) as? Bool, false, "where each connection looks it up")
    }

    func testRevealingANotificationSelectsItsSectionAndBringsTheWindowForward() {
        let model = AppModel()
        var shown = 0
        model.showMainWindow = { shown += 1 }
        XCTAssertFalse(model.clickOpensAppOnPhone, "shown here unless the user chooses otherwise: opening it on the phone removes it")
        model.selection = .photos
        model.reveal(DemoData.notifications[1])
        XCTAssertEqual(model.selection, .notifications)
        XCTAssertEqual(shown, 1)
        // A text goes to Messages, once there are conversations to show.
        let text = PhoneNotification(json: #"{"key":"s","packageName":"com.example.sms","postTime":1,"notificationClass":1}"#)!
        model.reveal(text)
        XCTAssertEqual(model.selection, .notifications)
        model.conversations = DemoData.conversations
        model.reveal(text)
        XCTAssertEqual(model.selection, .messages)
        XCTAssertEqual(shown, 3)
    }

    func testATextsBannerOpensItsOwnConversation() {
        let model = AppModel()
        model.showMainWindow = {}
        let posted: TimeInterval = 1_800_000_000
        func thread(_ id: Int64, from number: String, saying body: String, at time: TimeInterval) -> Conversation {
            Conversation(id: id, participants: [number], messages: [
                PhoneMessage(kind: .sms, messageId: id, threadId: id, date: Date(timeIntervalSince1970: time), body: body,
                             isIncoming: true, isRead: false, address: number, subscriptionId: 1),
            ], pending: [])
        }
        func banner(title: String, text: String, at time: TimeInterval = posted) -> PhoneNotification {
            PhoneNotification(json: #"{"key":"k","packageName":"com.example.sms","postTime":\#(Int64(time * 1000)),"notificationClass":1,"title":"\#(title)","text":"\#(text)"}"#)!
        }
        model.conversations = [
            thread(1, from: "+15550101", saying: "newest, elsewhere", at: posted + 30),
            thread(2, from: "+15550102", saying: "your code is 1234", at: posted - 1),
            thread(3, from: "+15550103", saying: "older", at: posted - 3600),
        ]
        // By the text itself, though another conversation is more recent.
        model.reveal(banner(title: "Someone", text: "your code is 1234"))
        XCTAssertEqual(model.conversationTarget, 2)
        XCTAssertEqual(model.selection, .messages)
        // By the sender's number, when the text is not (yet) here.
        model.reveal(banner(title: "+1 555-0103", text: "not synced"))
        XCTAssertEqual(model.conversationTarget, 3)
        // Else by time; nothing close, nothing chosen and Messages opens on the newest.
        XCTAssertEqual(model.conversation(for: banner(title: "?", text: "?", at: posted + 40))?.id, 1)
        model.reveal(banner(title: "?", text: "?", at: posted + 86_400))
        XCTAssertNil(model.conversationTarget)
    }

    func testWhatIsPlayingIsKeptApartFromTheNotificationList() {
        let model = AppModel()
        model.upsert(DemoData.notifications[0])
        model.upsert(DemoData.mediaSession)
        XCTAssertEqual(model.notifications.map(\.key), ["n1"])
        XCTAssertEqual(model.nowPlaying?.key, "media1")
        model.removeNotification(key: "media1")
        XCTAssertNil(model.nowPlaying)
    }

    func testStatusTextAndSymbolFollowThePhase() {
        let model = AppModel()
        XCTAssertEqual(model.statusText, "Not signed in")
        XCTAssertFalse(model.isConnected)
        model.phase = .connected(phoneName: "Galaxy")
        XCTAssertEqual(model.statusText, "Connected to Galaxy")
        XCTAssertTrue(model.isConnected)
        model.phase = .failed(message: "Offline", canRetry: true)
        XCTAssertEqual(model.statusText, "Offline")
        XCTAssertEqual(model.statusSymbol, "iphone.gen3.badge.exclamationmark")
    }

    func testTheMenuBarSymbolExistsInEveryPhase() {
        let model = AppModel()
        let phases: [AppPhase] = [.starting, .signedOut, .signingIn(code: "c", url: "u", expires: .distantFuture), .linking(nil),
                                  .connecting(phoneName: "p"), .connected(phoneName: "p"), .failed(message: "m", canRetry: true)]
        for phase in phases {
            model.phase = phase
            XCTAssertNotNil(NSImage(systemSymbolName: model.statusSymbol, accessibilityDescription: nil),
                            "\(model.statusSymbol): without it the menu bar item is empty")
        }
    }

    func testEveryPairingFailureHasATitleAndExplanation() {
        let failures: [PairingFailure] = [.accountMismatch, .linkExpired, .pinExpired, .sessionExpired, .requiredPermissionDenied,
                                          .serviceFailure(type: "Timeout"), .serviceFailure(type: nil), .unknownState("NEW_STATE")]
        for failure in failures {
            XCTAssertFalse(PairingView.title(failure).isEmpty)
            XCTAssertGreaterThan(PairingView.explanation(failure).count, 20)
        }
        XCTAssertTrue(PairingView.explanation(.unknownState("NEW_STATE")).contains("NEW_STATE"))
    }

    func testDemoBackendDrivesTheModel() {
        let model = AppModel()
        let demo = DemoActions(model: model, startConnected: true)
        model.actions = demo
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.notifications.count, 3)
        demo.dismiss(model.notifications[0])
        XCTAssertEqual(model.notifications.count, 2)
        demo.clearAll()
        XCTAssertTrue(model.notifications.isEmpty)
        demo.signOut()
        XCTAssertEqual(model.phase, .signedOut)
        demo.startPairing(manual: false)
        guard case .linking(.showLink(let link, _, _, _)?) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertNotNil(QRCodeView.makeImage(link), "the pairing link fits in a QR code")
    }
}

final class KeyCodeTests: XCTestCase {
    func testMacKeysBecomeKeyboardUsageNumbers() {
        // By the Mac's key codes: A, C, Return, Space, the arrows.
        XCTAssertEqual(KeyCodes.usage[0x00], 0x04)
        XCTAssertEqual(KeyCodes.usage[0x08], 0x06, "the letter recorded from Windows as 0x06")
        XCTAssertEqual(KeyCodes.usage[0x24], 0x28)
        XCTAssertEqual(KeyCodes.usage[0x31], 0x2C, "the space recorded from Windows as 0x2C")
        XCTAssertEqual([0x7B, 0x7C, 0x7D, 0x7E].map { KeyCodes.usage[$0] }, [0x50, 0x4F, 0x51, 0x52])
        // Command acts as Control on the phone, so that the usual shortcuts work there.
        XCTAssertEqual(KeyCodes.usage[0x37], KeyCodes.usage[0x3B])
        XCTAssertEqual(KeyCodes.usage[0x38], 0xE1)
        XCTAssertNil(KeyCodes.usage[0x3F], "the Fn key has no number to send")
    }
}

@MainActor
final class PhoneSwitchTests: XCTestCase {
    func testChoosingAnotherLinkedPhoneMakesItTheOneInUse() {
        let model = AppModel()
        let demo = DemoActions(model: model, startConnected: true)
        model.actions = demo
        XCTAssertEqual(model.currentPhoneId, DemoData.phone.id)
        XCTAssertEqual(model.switchablePhones.map(\.id), [DemoData.phone.id, DemoData.otherPhone.id])
        XCTAssertFalse(model.notifications.isEmpty)
        demo.selectPhone(DemoData.otherPhone)
        XCTAssertEqual(model.currentPhoneId, DemoData.otherPhone.id)
        XCTAssertEqual(model.phase, .connected(phoneName: "Pixel 9"))
        XCTAssertEqual(model.phones.filter(\.isOnline).map(\.id), [DemoData.otherPhone.id], "one phone at a time")
        XCTAssertTrue(model.notifications.isEmpty, "nothing of the first phone stays on screen")
        // A phone of the account that is not linked with this Mac cannot be chosen.
        var stranger = DemoData.otherPhone
        stranger.id = "not-linked"
        stranger.isLinked = false
        model.phones.append(stranger)
        XCTAssertEqual(model.switchablePhones.count, 2)
        demo.selectPhone(stranger)
        XCTAssertEqual(model.currentPhoneId, DemoData.otherPhone.id)
    }
}

final class SidebarTests: XCTestCase {
    /// The sidebar list selects by row ID, so the ID must be the very value the selection holds.
    /// When these differed, no row could be selected.
    func testSidebarRowsAreIdentifiedByTheSelectionValue() {
        for item in SidebarItem.allCases {
            let selection: SidebarItem? = item
            XCTAssertEqual(item.id, selection)
        }
        XCTAssertEqual(Set(SidebarItem.allCases.map(\.id)).count, SidebarItem.allCases.count)
        XCTAssertTrue(SidebarItem.allCases.contains(.photos))
    }
}

@MainActor
final class ReadMarkTests: XCTestCase {
    func conversation(_ id: Int64, unreadAt seconds: [TimeInterval]) -> Conversation {
        Conversation(id: id, participants: ["+1"], messages: seconds.enumerated().map { index, time in
            PhoneMessage(kind: .sms, messageId: Int64(index), threadId: id, date: Date(timeIntervalSince1970: time), body: "m",
                         isIncoming: true, isRead: false, address: "+1", subscriptionId: 1)
        }, pending: [])
    }

    func testOpeningAConversationClearsItsUnreadCountUntilSomethingNewerArrives() throws {
        let suite = "winphone.tests.\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let model = AppModel()
        model.readMarkStore = store
        var thread = conversation(5, unreadAt: [100, 200])
        model.conversations = [thread, conversation(6, unreadAt: [50])]
        XCTAssertEqual(model.unreadCount(thread), 2, "the phone says both are unread")
        XCTAssertEqual(model.unreadMessageCount, 3)

        model.markRead(thread)
        XCTAssertEqual(model.unreadCount(thread), 0, "read here, whatever the phone's flag says")
        XCTAssertEqual(model.unreadMessageCount, 1, "the other conversation is untouched")

        // A newer text makes it unread again.
        thread = conversation(5, unreadAt: [100, 200, 300])
        XCTAssertEqual(model.unreadCount(thread), 1)

        // The marks survive a relaunch.
        let relaunched = AppModel()
        relaunched.readMarkStore = store
        XCTAssertEqual(relaunched.unreadCount(conversation(5, unreadAt: [100, 200])), 0)
        XCTAssertEqual(relaunched.unreadCount(thread), 1)
    }
}

@MainActor
final class ReconnectPresentationTests: XCTestCase {
    func testADroppedLinkKeepsTheMainInterface() {
        let model = AppModel()
        model.phase = .connecting(phoneName: "Phone")
        XCTAssertFalse(model.showsMainInterface, "a first connection shows the connecting screen")
        XCTAssertEqual(model.statusText, "Connecting to Phone")
        model.phase = .connected(phoneName: "Phone")
        model.hasBeenConnected = true
        XCTAssertTrue(model.showsMainInterface)
        model.phase = .connecting(phoneName: "Phone")
        XCTAssertTrue(model.showsMainInterface, "after a drop the interface stays, with a status")
        XCTAssertEqual(model.statusText, "Reconnecting to Phone")
        model.phase = .signedOut
        XCTAssertFalse(model.showsMainInterface)
    }

    func testOnlyTheNetworkComingBackCountsAsAChange() {
        let state = PathState()
        XCTAssertFalse(state.becameSatisfied(true), "the first report of a working network is not a change")
        XCTAssertFalse(state.becameSatisfied(false))
        XCTAssertFalse(state.becameSatisfied(false))
        XCTAssertTrue(state.becameSatisfied(true))
        XCTAssertFalse(state.becameSatisfied(true))
    }
}
