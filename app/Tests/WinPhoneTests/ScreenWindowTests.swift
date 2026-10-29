import AppKit
import XCTest
@testable import WinPhone
@testable import WinPhoneCore

/// The phone's screen in a window of its own.
final class ScreenWindowTests: XCTestCase {
    let upright = CGSize(width: 720, height: 1600), lying = CGSize(width: 1600, height: 720)

    /// The picture's shape, width over height, in a window's content.
    func ratio(_ content: CGSize) -> CGFloat {
        let picture = ScreenWindowLayout.picture(in: content)
        return picture.width / picture.height
    }

    func testTheWindowKeepsThePicturesShapeAboveItsBar() {
        let bar = ScreenWindowLayout.barHeight, margin = ScreenWindowLayout.margin
        let window = CGSize(width: 360 + 2 * margin, height: 800 + margin + bar)
        XCTAssertEqual(ScreenWindowLayout.content(forWidth: window.width, picture: upright), window)
        XCTAssertEqual(ScreenWindowLayout.picture(in: window), CGSize(width: 360, height: 800), "the picture, inside its margin and above the bar")
        XCTAssertEqual(ScreenWindowLayout.content(forHeight: window.height, picture: upright), window, "a drag at the bottom edge gives the same window")
        XCTAssertEqual(ScreenWindowLayout.content(forWidth: 10, picture: upright).width, ScreenWindowLayout.minimumWidth, "never too narrow for its buttons")
        // The first size: most of the screen's height, and always inside it.
        let laptop = CGSize(width: 1440, height: 860)
        let first = ScreenWindowLayout.initial(picture: upright, visible: laptop)
        XCTAssertEqual(first.height, 688, accuracy: 2)
        XCTAssertEqual(ratio(first), 720.0 / 1600, accuracy: 0.01)
        let wide = ScreenWindowLayout.initial(picture: lying, visible: laptop)
        XCTAssertLessThanOrEqual(wide.width, laptop.width * 0.95)
        XCTAssertEqual(ratio(wide), 1600.0 / 720, accuracy: 0.01)
        let small = ScreenWindowLayout.initial(picture: upright, visible: CGSize(width: 300, height: 2000))
        XCTAssertLessThanOrEqual(small.width, 300)
    }

    func testAPhoneTurnedOnItsSideKeepsItsLongSide() {
        let margin = ScreenWindowLayout.margin, laptop = CGSize(width: 1440, height: 860)
        let standing = ScreenWindowLayout.content(forWidth: 270 + 2 * margin, picture: upright)
        XCTAssertEqual(ScreenWindowLayout.picture(in: standing), CGSize(width: 270, height: 600))
        let turned = ScreenWindowLayout.reshaped(from: standing, picture: lying, visible: laptop)
        XCTAssertEqual(ScreenWindowLayout.picture(in: turned), CGSize(width: 600, height: 270))
        XCTAssertEqual(ScreenWindowLayout.reshaped(from: turned, picture: upright, visible: laptop), standing, "and back")
        // A window that would not fit once turned is made to.
        let tall = ScreenWindowLayout.content(forWidth: 360, picture: upright)
        let cramped = ScreenWindowLayout.reshaped(from: tall, picture: lying, visible: CGSize(width: 700, height: 500))
        XCTAssertLessThanOrEqual(cramped.width, 700 * 0.95)
        XCTAssertEqual(ratio(cramped), 1600.0 / 720, accuracy: 0.02)
    }

    /// The locked phone's PIN or password goes to it as keys of a US keyboard.
    func testAPasswordIsTypedAsTheKeysOfAUSKeyboard() {
        XCTAssertEqual(KeyCodes.typing("a")?.usage, 0x04)
        XCTAssertEqual(KeyCodes.typing("a")?.shift, false)
        XCTAssertEqual(KeyCodes.typing("Z")?.usage, 0x1D)
        XCTAssertEqual(KeyCodes.typing("Z")?.shift, true)
        XCTAssertEqual(KeyCodes.typing("1")?.usage, 0x1E)
        XCTAssertEqual(KeyCodes.typing("0")?.usage, 0x27)
        XCTAssertEqual(KeyCodes.typing("!")?.usage, 0x1E, "Shift and 1")
        XCTAssertEqual(KeyCodes.typing("!")?.shift, true)
        XCTAssertEqual(KeyCodes.typing("\\")?.usage, 0x31)
        XCTAssertEqual(KeyCodes.typing("\"")?.usage, 0x34)
        XCTAssertEqual(KeyCodes.typing("\"")?.shift, true)
        XCTAssertEqual(KeyCodes.typing(" ")?.usage, 0x2C)
        XCTAssertNil(KeyCodes.typing("ж"), "not on a US keyboard")
        XCTAssertNil(KeyCodes.typing("é"))
    }

    @MainActor
    func testTheWindowIsWantedOnlyWhileThereIsSomethingToShow() {
        XCTAssertTrue(ScreenWindowController.wanted(ownWindow: true, state: .live))
        XCTAssertTrue(ScreenWindowController.wanted(ownWindow: true, state: .connecting))
        XCTAssertTrue(ScreenWindowController.wanted(ownWindow: true, state: .waitingForPermission))
        XCTAssertFalse(ScreenWindowController.wanted(ownWindow: true, state: .idle))
        XCTAssertFalse(ScreenWindowController.wanted(ownWindow: true, state: .failed("no")))
        XCTAssertFalse(ScreenWindowController.wanted(ownWindow: false, state: .live))
    }

    /// Lets what was published reach the controller.
    @MainActor
    func settle() async {
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor
    func testTheWindowOpensFollowsThePictureAndClosingItEndsTheMirroring() async {
        let model = AppModel()
        let actions = DemoActions(model: model, startConnected: true)
        model.actions = actions
        let controller = ScreenWindowController(model: model)
        await settle()
        XCTAssertNil(controller.window, "nothing to show yet")
        model.screenVideoSize = upright
        model.screenInOwnWindow = true
        model.screenState = .live
        await settle()
        guard let window = controller.window else { return XCTFail("no window for a live screen") }
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.title, "Phone Screen")
        var content = window.contentRect(forFrameRect: window.frame).size
        XCTAssertGreaterThan(content.height, content.width, "the phone's shape")

        // Dragged wider: the height follows.
        let wider = controller.windowWillResize(window, to: NSSize(width: window.frame.width + 90, height: window.frame.height))
        let widerContent = window.contentRect(forFrameRect: NSRect(origin: .zero, size: wider)).size
        XCTAssertEqual(ratio(widerContent), 720.0 / 1600, accuracy: 0.02)
        // Dragged at the bottom edge: the width follows.
        let taller = controller.windowWillResize(window, to: NSSize(width: window.frame.width, height: window.frame.height + 100))
        XCTAssertGreaterThan(taller.width, window.frame.width)

        // The phone turned: the window lies down with it.
        model.screenVideoSize = lying
        await settle()
        content = window.contentRect(forFrameRect: window.frame).size
        XCTAssertGreaterThan(content.width, content.height)
        model.screenOnTop = true
        await settle()
        XCTAssertEqual(window.level, .floating)

        // Back into the main window: the window goes, the mirroring stays.
        model.screenInOwnWindow = false
        await settle()
        XCTAssertNil(controller.window)
        XCTAssertEqual(model.screenState, .live)

        XCTAssertEqual(model.selection, .screen, "and the main window shows it")

        // Out again, and closed by its user: that stops the mirroring.
        model.selection = .apps
        model.screenInOwnWindow = true
        await settle()
        guard let again = controller.window else { return XCTFail("no window the second time") }
        again.close()
        await settle()
        XCTAssertEqual(model.screenState, .idle)
        XCTAssertNil(controller.window)
        XCTAssertTrue(model.screenInOwnWindow, "the next time it opens in its own window again")
        XCTAssertEqual(model.selection, .apps, "a stop leaves the main window where it was")

        // Closed while the phone is still being reached, and the session goes on a moment
        // longer: the window does not come back by itself, only when asked for.
        model.screenState = .connecting
        await settle()
        guard let third = controller.window else { return XCTFail("no window while connecting") }
        model.actions = nil
        third.close()
        model.screenState = .waitingForPermission
        await settle()
        XCTAssertNil(controller.window)
        controller.bringForward()
        XCTAssertNotNil(controller.window)
        // A failure closes the window and shows the reason where it is told.
        model.selection = .apps
        model.screenState = .failed("no")
        await settle()
        XCTAssertNil(controller.window)
        XCTAssertEqual(model.selection, .screen)
    }

    func app(_ name: String, _ package: String) -> PhoneApp {
        PhoneApp(id: Int64(abs(package.hashValue % 100_000)), packageName: package, name: name)
    }

    func testAppsAreShelvedByFavoritesThenLatelyOpenedThenAll() {
        let apps = [app("Maps", "maps"), app("Camera", "camera"), app("Notes", "notes"), app("Clock", "clock"), app("", "nameless")]
        // Nothing marked, nothing opened: one group without a heading.
        XCTAssertEqual(AppsView.shelves(apps, favorites: [], recent: [], search: "").map(\.title), [nil])
        XCTAssertEqual(AppsView.shelves(apps, favorites: [], recent: [], search: "").first?.apps.map(\.name), ["Camera", "Clock", "Maps", "Notes"], "by name, the nameless left out")
        let shelves = AppsView.shelves(apps, favorites: ["notes", "gone"], recent: ["maps", "notes", "uninstalled", "clock"], search: "")
        XCTAssertEqual(shelves.map(\.title), ["Favorites", "Recently Opened", "All Apps"])
        XCTAssertEqual(shelves[0].apps.map(\.name), ["Notes"])
        XCTAssertEqual(shelves[1].apps.map(\.name), ["Maps", "Clock"], "newest first, without favorites and without what left the phone")
        XCTAssertEqual(shelves[2].apps.count, 4, "every app is still under All")
        // A search is one plain group, or nothing.
        XCTAssertEqual(AppsView.shelves(apps, favorites: ["notes"], recent: ["maps"], search: " c ").first?.apps.map(\.name), ["Camera", "Clock"])
        XCTAssertEqual(AppsView.shelves(apps, favorites: ["notes"], recent: ["maps"], search: "zzz"), [])
    }

    @MainActor
    func testOpeningAnAppRemembersItAndFavoritesAreKept() {
        let suite = "apps-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        let model = AppModel()
        model.preferenceStore = store
        // The model does not hold on to what acts for it.
        let actions = DemoActions(model: model, startConnected: true)
        model.actions = actions
        for package in ["a", "b", "a", "c"] { model.open(app: package) }
        XCTAssertEqual(model.recentApps, ["c", "a", "b"], "newest first, each once")
        XCTAssertEqual(model.selection, .screen)
        XCTAssertEqual(model.screenApp, "c")
        for index in 0..<20 { model.open(app: "p\(index)") }
        XCTAssertEqual(model.recentApps.count, AppModel.recentAppsKept)
        model.setFavorite("a", true)
        model.setFavorite("a", true)
        model.setFavorite("b", true)
        model.setFavorite("b", false)
        XCTAssertEqual(model.favoriteApps, ["a"])
        // The screen in its own window: the main window stays where it is.
        model.selection = .apps
        model.screenInOwnWindow = true
        model.open(app: "z")
        XCTAssertEqual(model.selection, .apps)
        let again = AppModel()
        again.preferenceStore = store
        XCTAssertEqual(again.favoriteApps, ["a"])
        XCTAssertEqual(again.recentApps.first, "z")
        XCTAssertTrue(again.screenInOwnWindow)
    }
}
