import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import WinPhone
@testable import WinPhoneCore

/// Photos taken out of the grid: saved, or dragged elsewhere.
final class PhotoExportTests: XCTestCase {
    func testASavedPhotoNeverTakesAnotherFilesPlace() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = PhotoExport.freeURL(for: "IMG_1.jpg", in: folder)
        XCTAssertEqual(first.lastPathComponent, "IMG_1.jpg")
        try Data([1]).write(to: first)
        let second = PhotoExport.freeURL(for: "IMG_1.jpg", in: folder)
        XCTAssertEqual(second.lastPathComponent, "IMG_1 2.jpg")
        try Data([2]).write(to: second)
        XCTAssertEqual(PhotoExport.freeURL(for: "IMG_1.jpg", in: folder).lastPathComponent, "IMG_1 3.jpg")
        try Data([3]).write(to: folder.appendingPathComponent("notes"))
        XCTAssertEqual(PhotoExport.freeURL(for: "notes", in: folder).lastPathComponent, "notes 2", "a name without an extension gets none")
    }

    func testThePromisedKindFollowsWhatThePhoneWillSend() {
        XCTAssertEqual(PhotoExport.promisedType(for: PhonePhoto(id: 1, name: "a.png", fileSize: 1000)), .png)
        XCTAssertEqual(PhotoExport.promisedType(for: PhonePhoto(id: 1, name: "a.jpg", fileSize: 1000)), .jpeg)
        XCTAssertEqual(PhotoExport.promisedType(for: PhonePhoto(id: 1, name: "a.heic", fileSize: PhonePhoto.originalByteLimit + 1)), .jpeg, "a large photo arrives reduced, as a JPEG")
        XCTAssertEqual(PhotoExport.promisedType(for: PhonePhoto(id: 1, name: "a.mp4", fileSize: 1000)), .jpeg, "nothing that is not a picture is promised")
        XCTAssertEqual(PhotoExport.promisedType(for: PhonePhoto(id: 1, name: "", fileSize: 1000)), .jpeg)
    }

    /// The drag's promise, kept as a drop target would have it kept: the photo is fetched and
    /// arrives as a file under the phone's name.
    @MainActor
    func testADraggedPhotoArrivesAsAFileWhenItIsDropped() async throws {
        let model = AppModel()
        let actions = DemoActions(model: model, startConnected: true)
        model.actions = actions
        let photo = DemoData.photos[0]
        let provider = PhotoExport.provider(for: photo, model: model)
        XCTAssertEqual(provider.suggestedName, photo.name)
        XCTAssertEqual(PhotoExport.suggestedName(for: PhonePhoto(id: 7, name: "a.heic", fileSize: PhonePhoto.originalByteLimit + 1)), "a", "what arrives is a JPEG: the old extension is left off")
        XCTAssertEqual(PhotoExport.suggestedName(for: PhonePhoto(id: 7, name: "")), "Photo 7")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.image.identifier))
        let arrived = expectation(description: "the photo as a file")
        nonisolated(unsafe) var name = "", bytes = 0
        _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier) { url, error in
            if let url {
                name = url.lastPathComponent
                bytes = (try? Data(contentsOf: url).count) ?? 0
            }
            arrived.fulfill()
        }
        await fulfillment(of: [arrived], timeout: 10)
        XCTAssertEqual(name, photo.name)
        XCTAssertGreaterThan(bytes, 1000)
    }

    /// Files dropped on the Dock icon arrive one at a time; they leave as one transfer.
    @MainActor
    func testFilesHandedOverOneByOneAreSentTogether() async throws {
        let model = AppModel()
        let actions = DemoActions(model: model, startConnected: true)
        model.actions = actions
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = ["a.txt", "b.txt", "c.txt"].map { folder.appendingPathComponent($0) }
        for file in files { try Data("x".utf8).write(to: file) }
        func sent() -> [String] { model.receivedFiles.filter { $0.sent && $0.url.path.hasPrefix(folder.path) }.map(\.name).sorted() }
        model.selection = .notifications
        model.gatherFileToSend(files[0], wait: .milliseconds(150))
        model.gatherFileToSend(files[1], wait: .milliseconds(150))
        model.gatherFileToSend(files[0], wait: .milliseconds(150))
        XCTAssertEqual(sent(), [], "nothing leaves while files are still arriving")
        try await Task.sleep(for: .milliseconds(60))
        model.gatherFileToSend(files[2], wait: .milliseconds(150))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sent(), [], "each arrival starts the short wait again")
        for _ in 0..<40 where sent().isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(sent(), ["a.txt", "b.txt", "c.txt"], "then they go together, each once")
        XCTAssertEqual(model.selection, .files, "and the Files section shows how it goes")
    }

    /// The phone's storage as the section shows it.
    @MainActor
    func testThePhonesFoldersAreShownOrderedAndFoundThingsSayWhereTheyLie() async {
        let root = PhoneFileTree.usualRoot
        let tree = PhoneFileTree(files: DemoData.storage)
        let camera = tree.children(of: root + "/DCIM/Camera")
        XCTAssertEqual(camera.count, 7)
        XCTAssertEqual(StorageView.ordered(camera, by: .largest).first?.name, "20261008_183012.mp4")
        XCTAssertEqual(StorageView.ordered(camera, by: .newest).first?.name, "20261009_1001.jpg")
        let top = StorageView.ordered(tree.children(of: root), by: .largest)
        XCTAssertEqual(top.map(\.name), ["DCIM", "Documents", "Download", "Music", "Pictures", "notes.txt"], "folders stay on top in any order")
        XCTAssertEqual(StorageView.title(of: root, root: root), "Phone")
        XCTAssertEqual(StorageView.title(of: root + "/DCIM/Camera", root: root), "Camera")
        XCTAssertEqual(StorageView.place(of: camera[0], root: root), "DCIM › Camera")
        XCTAssertEqual(StorageView.place(of: top[5], root: root), "Phone")
        XCTAssertEqual(StorageView.symbol(for: top[0]), "folder.fill")
        XCTAssertEqual(SidebarItem.screen.shortcutNumber, 7, "the new section took nobody's number")
        XCTAssertNil(SidebarItem.storage.shortcutNumber)

        // Opening the section asks; previews are fetched once and remembered, also that there is none.
        let model = AppModel()
        let actions = DemoActions(model: model, startConnected: true)
        model.actions = actions
        XCTAssertEqual(model.storageState, .idle)
        actions.loadPhoneFiles(again: false)
        XCTAssertEqual(model.storageState, .ready)
        XCTAssertTrue(model.storageListed)
        let previews = PhoneFilePreviews()
        let picture = camera[0], document = top[5]
        XCTAssertNil(previews.image(for: picture, side: 96))
        let loaded = await previews.load(picture, side: 96, model: model)
        XCTAssertNotNil(loaded)
        XCTAssertNotNil(previews.image(for: picture, side: 96), "kept for the next time")
        let none = await previews.load(document, side: 96, model: model)
        XCTAssertNil(none, "a document has no picture, and the phone is not asked for one")
    }
}

/// Joining the phone's hotspot: what the Mac's network tool is told, and what its words mean.
final class RelinkOfferTests: XCTestCase {
    @MainActor
    func testLinkingAgainIsOfferedOnlyAfterThePhoneHasBeenSilentForAWhile() {
        let model = AppModel()
        let now = Date()
        XCTAssertFalse(model.offersRelink(at: now), "nothing known of a silence")
        // Set when the first round of wake-ups (about a minute) went unanswered: offered from then on.
        model.phoneSilentSince = now.addingTimeInterval(-AppModel.relinkOfferAfter - 1)
        XCTAssertTrue(model.offersRelink(at: now))
        model.phase = .connected(phoneName: "Phone")
        XCTAssertFalse(model.offersRelink(at: now), "not while connected")
    }
}

final class BannerPictureTests: XCTestCase {
    func testAPictureIsNamedForItsKind() {
        XCTAssertEqual(MacNotifier.fileEnding(of: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])), "jpg")
        XCTAssertEqual(MacNotifier.fileEnding(of: Data([0x89, 0x50, 0x4E, 0x47])), "png")
        XCTAssertEqual(MacNotifier.fileEnding(of: Data()), "png")
    }
}

final class NotificationSwipeTests: XCTestCase {
    func testASwipeFollowsTheFingersToTheLeftOnlyAndDismissesPastAThird() {
        XCTAssertTrue(SwipeTrack.isSideways(dx: -8, dy: 1))
        XCTAssertFalse(SwipeTrack.isSideways(dx: -3, dy: -9), "along the list: scrolling")
        XCTAssertFalse(SwipeTrack.isSideways(dx: 0.2, dy: 0), "too little to tell")
        var track = SwipeTrack(row: "a")
        track.move(by: 30, width: 400)
        XCTAssertEqual(track.offset, 0, "not to the right")
        track.move(by: -100, width: 400)
        XCTAssertFalse(track.dismisses(width: 400))
        track.move(by: -30, width: 400)
        XCTAssertTrue(track.dismisses(width: 400))
        track.move(by: -900, width: 400)
        XCTAssertEqual(track.offset, -400, "no further than the row is wide")
        // A narrow row needs less than the fixed distance.
        var narrow = SwipeTrack(row: "b")
        narrow.move(by: -70, width: 200)
        XCTAssertTrue(narrow.dismisses(width: 200))
    }

    @MainActor
    func testOnlyAMovementThatStartsSidewaysOverARowIsTakenAndThenToItsEnd() async {
        let swipe = NotificationSwipe()
        swipe.frames = ["a": CGRect(x: 250, y: 100, width: 600, height: 80), "b": CGRect(x: 250, y: 180, width: 600, height: 80)]
        var dismissed: [String] = []
        swipe.onDismiss = { dismissed.append($0) }
        let onA = CGPoint(x: 400, y: 130), beside = CGPoint(x: 100, y: 130)

        // Along the list: none of it is taken, the glide neither.
        XCTAssertFalse(swipe.handle(point: onA, dx: 0.5, dy: -12, phase: .began))
        XCTAssertFalse(swipe.handle(point: onA, dx: -20, dy: -12, phase: .changed))
        XCTAssertFalse(swipe.handle(point: onA, dx: 0, dy: 0, phase: .ended))
        XCTAssertFalse(swipe.handle(point: onA, dx: 0, dy: -4, phase: .momentum(ended: true)))
        // Sideways, but over no row.
        XCTAssertFalse(swipe.handle(point: beside, dx: -10, dy: 0, phase: .began))

        // Sideways over a row, let go early: it comes back, nothing is dismissed.
        XCTAssertTrue(swipe.handle(point: onA, dx: -10, dy: 1, phase: .began))
        XCTAssertTrue(swipe.handle(point: onA, dx: -40, dy: 6, phase: .changed), "once taken, a drift along the list does not give it back")
        XCTAssertEqual(swipe.offset(for: "a"), -50)
        XCTAssertEqual(swipe.offset(for: "b"), 0)
        XCTAssertTrue(swipe.handle(point: onA, dx: 0, dy: 0, phase: .ended))
        XCTAssertNil(swipe.track)
        XCTAssertTrue(swipe.handle(point: onA, dx: -2, dy: 0, phase: .momentum(ended: false)))
        XCTAssertTrue(swipe.handle(point: onA, dx: -1, dy: 0, phase: .momentum(ended: true)))
        XCTAssertFalse(swipe.handle(point: onA, dx: -1, dy: 0, phase: .momentum(ended: true)), "the glide is over")
        XCTAssertEqual(dismissed, [])

        // Far enough: the row goes.
        XCTAssertTrue(swipe.handle(point: onA, dx: -10, dy: 0, phase: .began))
        XCTAssertTrue(swipe.handle(point: onA, dx: -200, dy: 0, phase: .changed))
        XCTAssertTrue(swipe.handle(point: onA, dx: 0, dy: 0, phase: .ended))
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(dismissed, ["a"])
        XCTAssertNil(swipe.track)

        // Broken off by the system: never a dismissal.
        XCTAssertTrue(swipe.handle(point: onA, dx: -10, dy: 0, phase: .began))
        XCTAssertTrue(swipe.handle(point: onA, dx: -300, dy: 0, phase: .changed))
        XCTAssertTrue(swipe.handle(point: onA, dx: 0, dy: 0, phase: .cancelled))
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(dismissed, ["a"])
    }
}

final class WiFiJoinTests: XCTestCase {
    @MainActor
    func testAnotherRouterAddressOrNetworkMarkMeansTheMacHasLeft() {
        let entry: [String: Any] = ["InterfaceName": "en0", "Router": "192.168.43.1", "Addresses": ["192.168.43.20"], "NetworkSignature": "IPv4.Router=192.168.43.1;IPv4.RouterHardwareAddress=02:00:00:00:00:01"]
        let joined = NetworkRoute(service: entry)
        XCTAssertEqual(joined, NetworkRoute(router: "192.168.43.1", address: "192.168.43.20", signature: "IPv4.Router=192.168.43.1;IPv4.RouterHardwareAddress=02:00:00:00:00:01"))
        XCTAssertNil(NetworkRoute(service: ["InterfaceName": "en0"]), "no address yet: no route")
        guard let joined else { return }
        XCTAssertTrue(HotspotWatch.isStillOn(joined, now: joined))
        XCTAssertFalse(HotspotWatch.isStillOn(joined, now: nil), "Wi-Fi off, or the hotspot gone")
        XCTAssertFalse(HotspotWatch.isStillOn(joined, now: NetworkRoute(router: "192.168.1.1", address: "192.168.1.128")))
        // The same numbers behind another router are another network.
        var twin = joined
        twin.signature = "IPv4.Router=192.168.43.1;IPv4.RouterHardwareAddress=02:00:00:00:00:02"
        XCTAssertFalse(HotspotWatch.isStillOn(joined, now: twin))
    }

    @MainActor
    func testANetworkThisAppMadeTheMacRememberIsKnownAsSuchWithoutItsNameBeingKept() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "hotspot-tests-\(UUID().uuidString)"))
        XCTAssertFalse(LiveActions.isNotedAsOurs("Phone Net", in: defaults))
        LiveActions.noteAsOurs("Phone Net", true, in: defaults)
        LiveActions.noteAsOurs("Phone Net", true, in: defaults)
        XCTAssertTrue(LiveActions.isNotedAsOurs("Phone Net", in: defaults))
        XCTAssertFalse(LiveActions.isNotedAsOurs("Home Net", in: defaults))
        let kept = try XCTUnwrap(defaults.stringArray(forKey: LiveActions.ourNetworksKey))
        XCTAssertEqual(kept.count, 1)
        XCTAssertFalse(kept.joined().contains("Phone"), "a fingerprint, not the name")
        LiveActions.noteAsOurs("Phone Net", false, in: defaults)
        XCTAssertFalse(LiveActions.isNotedAsOurs("Phone Net", in: defaults))
    }

    @MainActor
    func testOnlyNetworksThisAppMadeTheMacRememberAreForgotten() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "hotspot-tests-\(UUID().uuidString)"))
        XCTAssertEqual(LiveActions.networksToForget(among: ["Home Net", "Phone Net"], in: defaults), [])
        LiveActions.noteAsOurs("Phone Net", true, in: defaults)
        XCTAssertEqual(LiveActions.networksToForget(among: ["Home Net", "Phone Net", "Office"], in: defaults), ["Phone Net"])
        XCTAssertEqual(LiveActions.networksToForget(among: ["Home Net"], in: defaults), [], "noted, and already gone")
    }

    func testFoldersUnderTheFormerNameAreTakenOver() throws {
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.appendingPathComponent("folders-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: parent) }
        let old = parent.appendingPathComponent(AppFolders.formerName), new = parent.appendingPathComponent(AppFolders.name)
        try manager.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: old.appendingPathComponent("messages.cache"))
        // Nothing under the new name yet: the folder as a whole.
        AppFolders.adopt(in: parent, manager: manager)
        XCTAssertFalse(manager.fileExists(atPath: old.path))
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("messages.cache")), Data("a".utf8))
        // Both there: what the new one lacks is moved in, what it has is kept.
        try manager.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("messages.cache"))
        try Data("b".utf8).write(to: old.appendingPathComponent("photos.cache"))
        AppFolders.adopt(in: parent, manager: manager)
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("messages.cache")), Data("a".utf8))
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("photos.cache")), Data("b".utf8))
        XCTAssertTrue(manager.fileExists(atPath: old.path), "a file that was not moved stays where it is")
        // Nothing under the former name: nothing happens.
        try manager.removeItem(at: old)
        AppFolders.adopt(in: parent, manager: manager)
        XCTAssertTrue(manager.fileExists(atPath: new.path))
    }

    func testTheToolsListOfRememberedNetworksIsRead() {
        XCTAssertEqual(WiFiJoin.remembered(inList: "Preferred networks on en0:\n\tHome Net\n\tPhone Net\n"), ["Home Net", "Phone Net"])
        XCTAssertEqual(WiFiJoin.remembered(inList: ""), [])
    }

    @MainActor
    func testLeavingIsAStepOfItsOwnBetweenJoinedAndLeft() {
        XCTAssertTrue(AppModel.HotspotState.leaving.isBusy)
        XCTAssertNotNil(AppModel.HotspotState.leaving.notice)
    }

    @MainActor
    func testTheSignGoesOutWhenTheMacLeavesAndSaysThatThePhoneSwitchesOffItself() {
        XCTAssertEqual(AppModel.HotspotState.left.isBusy, false)
        XCTAssertEqual(AppModel.HotspotState.left.isFailure, false)
        XCTAssertTrue(AppModel.HotspotState.left.notice?.contains("by itself") == true)
    }

    func testTheNetworkToolIsToldAndUnderstood() {
        XCTAssertEqual(WiFiJoin.arguments(interface: "en0", ssid: "My Phone", password: "secret12"), ["-setairportnetwork", "en0", "My Phone", "secret12"])
        XCTAssertEqual(WiFiJoin.arguments(interface: "en1", ssid: "Open", password: ""), ["-setairportnetwork", "en1", "Open"])
        XCTAssertEqual(WiFiJoin.outcome(ofOutput: "", status: 0), .joined)
        XCTAssertEqual(WiFiJoin.outcome(ofOutput: "\n", status: 0), .joined)
        XCTAssertEqual(WiFiJoin.outcome(ofOutput: "Could not find network My Phone.\n", status: 0), .notFound)
        XCTAssertEqual(WiFiJoin.outcome(ofOutput: "Failed to join network My Phone.\nError: -3924  The operation couldn’t be completed.\n", status: 0), .refused("error -3924"))
        XCTAssertEqual(WiFiJoin.outcome(ofOutput: "Something else", status: 0), .refused("the Mac could not join"))
        XCTAssertEqual(WiFiJoin.outcome(ofOutput: "", status: 3), .refused("status 3"))
        XCTAssertFalse(WiFiJoin.describe(.refused("error -3924")).contains("My Phone"))
    }
}

/// The phone's hotspot as the app talks about it.
final class HotspotAppTests: XCTestCase {
    @MainActor
    func testTheServiceIsNamedAsThePhoneNamesItAndTroublesAreExplainedWithoutSecrets() {
        XCTAssertEqual(HotspotChannel.uuidBytes(HotspotChannel.serviceUUID).map { String(format: "%02X", $0) }.joined(), "111FAB8F00A24935B6B4ACA388CDD473")
        XCTAssertTrue(LiveActions.explain(HotspotError.notCapable(.dataSaver)).contains("Data saver"))
        XCTAssertTrue(LiveActions.explain(HotspotChannel.ChannelError.noService).contains("Instant Hotspot"))
        XCTAssertTrue(LiveActions.explain(HotspotChannel.ChannelError.timedOut).contains("Bluetooth"))
        // Silence from a phone whose Link to Windows may not use Bluetooth is explained by that.
        XCTAssertTrue(LiveActions.explain(HotspotChannel.ChannelError.timedOut, phoneBluetoothAllowed: false).contains("Nearby devices"))
        XCTAssertFalse(LiveActions.explain(HotspotChannel.ChannelError.timedOut, phoneBluetoothAllowed: true).contains("Nearby devices"))
        XCTAssertFalse(LiveActions.explain(HotspotError.untrusted, phoneBluetoothAllowed: false).contains("Nearby devices"), "an answer is no silence")
        XCTAssertTrue(LiveActions.explain(HotspotError.forged).contains("Nothing was joined"))
        XCTAssertNil(AppModel.HotspotState.idle.notice)
        XCTAssertTrue(AppModel.HotspotState.asking.isBusy)
        XCTAssertFalse(AppModel.HotspotState.joined(network: "N").isBusy)
        XCTAssertTrue(AppModel.HotspotState.failed("x").isFailure)
        XCTAssertEqual(AppModel.HotspotState.joined(network: "My Phone").notice?.contains("My Phone"), true)
    }
}

/// What the panel under the menu bar item shows.
final class MenuBarPanelTests: XCTestCase {
    @MainActor
    func testThePanelListsTheSectionsWithWhatIsNewAndTheLatestNotifications() {
        XCTAssertEqual(MenuBarPanel.sections(showsCalls: false), [.notifications, .messages, .photos, .storage, .screen])
        XCTAssertEqual(MenuBarPanel.sections(showsCalls: true)[2], .calls)
        XCTAssertEqual(MenuBarPanel.badge(for: .notifications, notifications: 3, unreadTexts: 37), 3)
        XCTAssertEqual(MenuBarPanel.badge(for: .messages, notifications: 3, unreadTexts: 37), 37)
        XCTAssertEqual(MenuBarPanel.badge(for: .photos, notifications: 3, unreadTexts: 37), 0)
        let all = DemoData.notifications
        let recent = MenuBarPanel.recent(all, limit: 2)
        XCTAssertEqual(recent.count, min(2, all.count))
        XCTAssertEqual(recent.first?.postTime, all.map(\.postTime).max(), "the newest first")
        XCTAssertEqual(MenuBarPanel.recent([]), [])
    }
}
