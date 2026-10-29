import AppKit
import XCTest
@testable import WinPhone
@testable import WinPhoneCore

/// What of calls over Bluetooth can be tried without a radio. Names and addresses are made up.
final class BluetoothCallsTests: XCTestCase {
    let phones = [CallDevice(name: "Ada’s Galaxy", address: "00-00-00-00-00-01"), CallDevice(name: "Tablet", address: "00-00-00-00-00-02")]

    @MainActor
    func testADeviceTheSystemListsTwiceIsOfferedOnce() {
        let listed = [phones[0], phones[1], CallDevice(name: "Tablet", address: "00-00-00-00-00-02"), CallDevice(name: "Ada’s Galaxy", address: "00-00-00-00-00-01")]
        let once = BluetoothCalls.unique(listed)
        XCTAssertEqual(once, phones, "in the order first seen")
        XCTAssertEqual(BluetoothCalls.choose(from: once, chosen: nil, linkedName: "Ada's Galaxy")?.address, "00-00-00-00-00-01", "and found by its name again")
        XCTAssertEqual(BluetoothCalls.unique([CallDevice(name: "A", address: "AA-BB"), CallDevice(name: "A", address: "aa-bb")]).count, 1)
    }

    @MainActor
    func testThePairedPhoneIsFoundByChoiceThenByNameThenByBeingTheOnlyOne() {
        XCTAssertEqual(BluetoothCalls.choose(from: phones, chosen: "00-00-00-00-00-02", linkedName: "Ada's Galaxy")?.name, "Tablet", "a choice wins")
        // The relay and Bluetooth write the apostrophe differently.
        XCTAssertEqual(BluetoothCalls.choose(from: phones, chosen: nil, linkedName: "Ada's Galaxy")?.address, "00-00-00-00-00-01")
        XCTAssertEqual(BluetoothCalls.choose(from: phones, chosen: "00-00-00-00-00-09", linkedName: "ada's  galaxy")?.address, "00-00-00-00-00-01", "a choice that is gone is passed over")
        XCTAssertNil(BluetoothCalls.choose(from: phones, chosen: nil, linkedName: "Another Phone"), "two candidates and no way to tell")
        XCTAssertNil(BluetoothCalls.choose(from: phones, chosen: nil, linkedName: ""))
        XCTAssertEqual(BluetoothCalls.choose(from: phones, chosen: nil, linkedName: "Galaxy")?.address, "00-00-00-00-00-01", "one name within the other")
        XCTAssertEqual(BluetoothCalls.choose(from: phones, chosen: nil, linkedName: "Ada's Galaxy S21+ 5G")?.address, "00-00-00-00-00-01")
        XCTAssertEqual(BluetoothCalls.choose(from: [phones[1]], chosen: nil, linkedName: nil)?.name, "Tablet")
        XCTAssertNil(BluetoothCalls.choose(from: [], chosen: nil, linkedName: "Ada's Galaxy"))
    }

    /// The Contacts section: who is listed, under which letter, and how a contact's number
    /// finds its conversation.
    @MainActor
    func testContactsAreListedByNameAndNumbersFindTheirConversation() {
        let book = ContactBook(contacts: [PhoneContact(id: 1, displayName: "Zoë Example"), PhoneContact(id: 2, displayName: "adam sample", company: "Works Ltd"),
                                          PhoneContact(id: 3, displayName: "", company: "Corner Shop"), PhoneContact(id: 4, displayName: "Édith Model"),
                                          PhoneContact(id: 5, displayName: "42 Taxi"), PhoneContact(id: 6, displayName: "")],
                               numbers: [("+15550101", 1), ("+15550102", 2), ("5550105", 5)], emails: [],
                               displayNumbers: [("+1 555 0101", 1), ("+1 555 0102", 2), ("555 0105", 5)])
        let all = ContactsView.listed(book, search: "")
        XCTAssertEqual(all.map(\.name), ["42 Taxi", "adam sample", "Corner Shop", "Édith Model", "Zoë Example"], "by name whatever the case; a company stands in for a missing name; nameless ones are left out")
        XCTAssertEqual(ContactsView.sections(all).map(\.letter), ["A", "C", "E", "Z", "#"], "accents filed under their letter, digits last")
        XCTAssertEqual(ContactsView.listed(book, search: "works").map(\.id), [2], "by company")
        XCTAssertEqual(ContactsView.listed(book, search: "0105").map(\.id), [5], "by digits of a number")
        XCTAssertEqual(ContactsView.listed(book, search: "nobody"), [])
        XCTAssertEqual(ContactsView.initial("  émile"), "E")
        XCTAssertEqual(ContactsView.initial(""), "#")

        XCTAssertTrue(AppModel.sameNumber("15550101", "15550101"))
        XCTAssertTrue(AppModel.sameNumber("5550101", "15550101"), "without the country code")
        XCTAssertTrue(AppModel.sameNumber("4915550101", "015550101"), "a national number with its leading zero")
        XCTAssertFalse(AppModel.sameNumber("5550102", "15550101"))
        XCTAssertFalse(AppModel.sameNumber("101", "15550101"), "too short to be the same number")
        let model = AppModel()
        model.conversations = DemoData.conversations
        let known = model.conversations.first { $0.participants.count == 1 }
        if let known { XCTAssertEqual(model.conversation(with: known.participants[0])?.id, known.id) }
        XCTAssertNil(model.conversation(with: "+19990000000"))
        XCTAssertNil(model.conversation(with: ""))
    }

    /// Notifications in one stack per app: each app's newest first, the apps by their newest.
    @MainActor
    func testNotificationsGroupByApp() throws {
        func note(_ key: String, _ package: String, _ time: Int64) throws -> PhoneNotification {
            try XCTUnwrap(PhoneNotification(json: #"{"key":"\#(key)","packageName":"\#(package)","appName":"\#(package.uppercased())","postTime":\#(time)}"#))
        }
        let all = [try note("a1", "mail", 100), try note("b1", "chat", 300), try note("a2", "mail", 400), try note("c1", "news", 200), try note("b2", "chat", 50)]
        let groups = AppModel.groups(of: all) { $0.appName }
        XCTAssertEqual(groups.map(\.package), ["mail", "chat", "news"], "the app with the newest notification first")
        XCTAssertEqual(groups.map { $0.notifications.map(\.key) }, [["a2", "a1"], ["b1", "b2"], ["c1"]])
        XCTAssertEqual(groups.map(\.name), ["MAIL", "CHAT", "NEWS"])
        XCTAssertEqual(AppModel.groups(of: []) { $0.appName }, [])
    }

    /// The phone's battery is announced once per step down, and once when full if wanted.
    func testBatteryAlertsSayEachThingOnce() {
        var alerts = BatteryAlerts()
        func at(_ percent: Int?, charging: Bool = false, low: Bool = true, full: Bool = true) -> BatteryAlerts.Alert? {
            alerts.check(PhoneStatus(batteryPercent: percent, isCharging: charging), lowWanted: low, fullWanted: full)
        }
        XCTAssertNil(at(60))
        XCTAssertNil(at(21))
        XCTAssertEqual(at(20), .low(20))
        XCTAssertNil(at(19), "said already")
        XCTAssertNil(at(22), "a percent back up is not news either way")
        XCTAssertNil(at(18))
        XCTAssertEqual(at(10), .low(10), "the second step down")
        XCTAssertNil(at(4))
        XCTAssertEqual(BatteryAlerts.Alert.low(9).body, "It will switch off soon unless it is charged.")
        // On the charger nothing is low; off it again, low is news again.
        XCTAssertNil(at(9, charging: true))
        XCTAssertEqual(at(9), .low(9))
        // Well above again, then down again.
        XCTAssertNil(at(40))
        XCTAssertEqual(at(15), .low(15))
        // Full, once, while it stays on the charger.
        XCTAssertNil(at(99, charging: true))
        XCTAssertEqual(at(100, charging: true), .full)
        XCTAssertNil(at(100, charging: true))
        XCTAssertNil(at(100), "full and off the charger is not an event")
        XCTAssertEqual(at(100, charging: true), .full, "after being off it")
        // Switched off, the steps are still counted, so switching on later does not replay them.
        var quiet = BatteryAlerts()
        XCTAssertNil(quiet.check(PhoneStatus(batteryPercent: 12), lowWanted: false, fullWanted: false))
        XCTAssertNil(quiet.check(PhoneStatus(batteryPercent: 11), lowWanted: true, fullWanted: false))
        XCTAssertNil(quiet.check(PhoneStatus(batteryPercent: nil), lowWanted: true, fullWanted: true), "a device that reports no battery")
    }

    @MainActor
    func testCallTitlesAndClock() {
        let model = AppModel()
        XCTAssertEqual(model.title(for: LiveCall(phase: .incoming)), "Unknown Caller")
        XCTAssertEqual(model.title(for: LiveCall(phase: .incoming, number: "5550100")), "5550100")
        XCTAssertEqual(LiveCallBar.clock(42), "0:42")
        XCTAssertEqual(LiveCallBar.clock(3723), "1:02:03")
        // What the dial pad's field takes for a number: a name is for the contact search.
        XCTAssertEqual(DialPad.number(in: " +1 (555) 01-00 "), "+1 (555) 01-00")
        XCTAssertEqual(DialPad.number(in: "*100#"), "*100#")
        XCTAssertNil(DialPad.number(in: "Ada"))
        XCTAssertNil(DialPad.number(in: "+"))
        XCTAssertEqual(DialPad.keys.flatMap { $0.map(\.key) }.count, 12)
        // The panel: a small tremble is a click, a movement is a drag; and it comes back where
        // it was left unless that place is no longer on any screen.
        XCTAssertFalse(CallPanel.isDrag(from: NSPoint(x: 10, y: 10), to: NSPoint(x: 13, y: 8)))
        XCTAssertTrue(CallPanel.isDrag(from: NSPoint(x: 10, y: 10), to: NSPoint(x: 10, y: 16)))
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900), size = NSSize(width: 264, height: 357)
        XCTAssertEqual(CallPanelController.origin(for: size, saved: nil, screens: [screen], main: screen), NSPoint(x: 1160, y: 527), "the top right corner to begin with")
        XCTAssertEqual(CallPanelController.origin(for: size, saved: "{200, 300}", screens: [screen], main: screen), NSPoint(x: 200, y: 300))
        XCTAssertEqual(CallPanelController.origin(for: size, saved: "{5000, 300}", screens: [screen], main: screen), NSPoint(x: 1160, y: 527), "a screen that is gone")
        XCTAssertFalse(model.canPlaceCalls)
        model.callLink = .connected
        XCTAssertTrue(model.canPlaceCalls)
        XCTAssertFalse(model.showsCalls)
        model.bluetoothCallsEnabled = true
        XCTAssertTrue(model.showsCalls)
    }
}
