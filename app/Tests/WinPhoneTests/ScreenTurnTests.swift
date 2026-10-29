import AppKit
import XCTest
@testable import WinPhone

/// The phone's picture shown turned, as the phone asks for an app that lies on its side.
final class ScreenTurnTests: XCTestCase {
    /// Where a corner of the picture lands in a view whose coordinates run downward.
    func landing(ofPictureCorner corner: CGPoint, view: CGSize, turns: Int) -> CGPoint {
        let bounds = ScreenTurn.layerBounds(in: view, turns: turns)
        // From the layer's middle, turned, then to the view's middle.
        let fromMiddle = CGPoint(x: corner.x * bounds.width - bounds.width / 2, y: corner.y * bounds.height - bounds.height / 2)
        let turned = fromMiddle.applying(CGAffineTransform(rotationAngle: ScreenTurn.angle(turns: turns)))
        return CGPoint(x: (turned.x + view.width / 2).rounded(), y: (turned.y + view.height / 2).rounded())
    }

    func testAPictureTurnedByAQuarterFillsAViewOfTheOtherShape() {
        let upright = CGSize(width: 720, height: 1600)
        XCTAssertEqual(ScreenTurn.shown(upright, turns: 0), upright)
        XCTAssertEqual(ScreenTurn.shown(upright, turns: 2), upright)
        XCTAssertEqual(ScreenTurn.shown(upright, turns: 1), CGSize(width: 1600, height: 720))
        XCTAssertEqual(ScreenTurn.shown(upright, turns: 3), CGSize(width: 1600, height: 720))

        let view = CGSize(width: 800, height: 360)
        XCTAssertEqual(ScreenTurn.layerBounds(in: view, turns: 1).size, CGSize(width: 360, height: 800), "the layer keeps the picture's own shape")
        let topLeft = CGPoint(x: 0, y: 0), bottomRight = CGPoint(x: 1, y: 1)
        // One quarter against the clock, as Phone Link turns it: the picture's top-left
        // corner comes to rest at the bottom-left of the view.
        XCTAssertEqual(landing(ofPictureCorner: topLeft, view: view, turns: 1), CGPoint(x: 0, y: 360))
        XCTAssertEqual(landing(ofPictureCorner: bottomRight, view: view, turns: 1), CGPoint(x: 800, y: 0))
        // Three quarters: the top-left corner at the top-right.
        XCTAssertEqual(landing(ofPictureCorner: topLeft, view: view, turns: 3), CGPoint(x: 800, y: 0))
        // Upside down, and not at all.
        let standing = CGSize(width: 360, height: 800)
        XCTAssertEqual(landing(ofPictureCorner: topLeft, view: standing, turns: 2), CGPoint(x: 360, y: 800))
        XCTAssertEqual(landing(ofPictureCorner: topLeft, view: standing, turns: 0), .zero)
        XCTAssertEqual(ScreenTurn.angle(turns: 4), 0)
        XCTAssertEqual(ScreenTurn.angle(turns: -1), ScreenTurn.angle(turns: 3))
    }

    @MainActor
    func testTheModelShowsTheTurnedShape() {
        let model = AppModel()
        model.screenVideoSize = CGSize(width: 720, height: 1600)
        XCTAssertEqual(model.screenShownSize, CGSize(width: 720, height: 1600))
        model.screenTurns = 1
        XCTAssertEqual(model.screenShownSize, CGSize(width: 1600, height: 720))
    }

    /// A picture with one red point in its top-left corner, the rest white.
    func marked(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height - 1, width: 1, height: 1))
        return context.makeImage()!
    }

    /// Where the red point is, counted from the top-left.
    func mark(in image: CGImage) -> [Int] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[(y * image.width + x) * 4] > 200 && bytes[(y * image.width + x) * 4 + 1] < 60 { return [x, y] }
        }
        return []
    }

    func testAScreenshotIsTurnedAsThePictureIsShown() throws {
        let picture = marked(width: 4, height: 8)
        XCTAssertEqual(mark(in: picture), [0, 0])
        let quarter = try XCTUnwrap(ScreenShots.turned(picture, turns: 1))
        XCTAssertEqual([quarter.width, quarter.height], [8, 4])
        XCTAssertEqual(mark(in: quarter), [0, 3], "against the clock: the top-left corner at the bottom-left")
        let half = try XCTUnwrap(ScreenShots.turned(picture, turns: 2))
        XCTAssertEqual([half.width, half.height], [4, 8])
        XCTAssertEqual(mark(in: half), [3, 7])
        let three = try XCTUnwrap(ScreenShots.turned(picture, turns: 3))
        XCTAssertEqual(mark(in: three), [7, 0])
        XCTAssertEqual(mark(in: try XCTUnwrap(ScreenShots.turned(picture, turns: 0))), [0, 0])
        XCTAssertNotNil(ScreenShots.png(quarter))
    }

    func testScreenshotsAreNamedByTheirTimeAndNeverOverwriteOneAnother() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_791_642_605) // 2026-10-10 14:30:05 UTC
        XCTAssertEqual(ScreenShots.fileName(at: date, calendar: calendar), "Phone Screen 2026-10-10 at 14.30.05.png")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try ScreenShots.save(Data([1]), in: folder, at: date)
        let second = try ScreenShots.save(Data([2]), in: folder, at: date)
        let third = try ScreenShots.save(Data([3]), in: folder, at: date)
        XCTAssertEqual(try Data(contentsOf: first), Data([1]))
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" 2.png"))
        XCTAssertTrue(third.lastPathComponent.hasSuffix(" 3.png"))
    }

    /// A modifier's own bit in the event says whether it is down; what happened while another
    /// window had the keyboard cannot turn press and release around.
    @MainActor
    func testModifiersFollowTheEventsOwnWordNotACount() {
        let command = 0x37, shift = 0x38, rightShift = 0x3C, capsLock = 0x39
        XCTAssertEqual(MirrorNSView.modifierChange(keyCode: command, flags: 0x8, held: []), true)
        XCTAssertEqual(MirrorNSView.modifierChange(keyCode: command, flags: 0, held: [command]), false)
        // Pressed here, let go elsewhere, pressed again here: still a press, not a release.
        XCTAssertNil(MirrorNSView.modifierChange(keyCode: command, flags: 0x8, held: [command]), "already known to be down")
        // Let go here without having been pressed here: nothing to tell the phone.
        XCTAssertNil(MirrorNSView.modifierChange(keyCode: shift, flags: 0, held: []))
        // Left and right are two keys: one let go leaves the other down.
        XCTAssertEqual(MirrorNSView.modifierChange(keyCode: shift, flags: 0x4, held: [shift, rightShift]), false)
        XCTAssertNil(MirrorNSView.modifierChange(keyCode: rightShift, flags: 0x4, held: [rightShift]))
        XCTAssertEqual(MirrorNSView.modifierChange(keyCode: capsLock, flags: 0, held: []), true, "a key without a bit of its own is a press each time")
    }

    @MainActor
    func testTheMacKeepsItsOwnShortcutsWhileThePictureHasTheKeyboard() {
        let command: NSEvent.ModifierFlags = [.command]
        for key in ["q", "w", "h", ",", "m", "1", "7", "9"] { XCTAssertTrue(MirrorNSView.staysWithMac(key, flags: command), key) }
        // Copy, paste, select all, undo, find and the like go to the phone.
        for key in ["c", "v", "x", "a", "z", "f", "t", "0"] { XCTAssertFalse(MirrorNSView.staysWithMac(key, flags: command), key) }
        // This app's menu: screenshot, stop showing, send files.
        XCTAssertTrue(MirrorNSView.staysWithMac("s", flags: [.command, .option]))
        XCTAssertTrue(MirrorNSView.staysWithMac("c", flags: [.command, .option]))
        XCTAssertTrue(MirrorNSView.staysWithMac("P", flags: [.command, .shift]))
        XCTAssertTrue(MirrorNSView.staysWithMac("O", flags: [.command, .shift]))
        XCTAssertFalse(MirrorNSView.staysWithMac("Z", flags: [.command, .shift]), "redo is the phone's")
    }
}
