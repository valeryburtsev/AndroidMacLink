import AppKit
import SwiftUI
import WinPhoneCore

/// Development aid: with `--demo --window-snapshot <folder>` the app shows its real window
/// with sample data, saves a picture of it for every section, and quits. Unlike `--snapshot`
/// this includes the window's own frame: toolbar, sidebar and their materials.
@MainActor
enum WindowSnapshots {
    static func run(model: AppModel, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            NSApplication.shared.activate(ignoringOtherApps: true)
            let dark = CommandLine.arguments.contains("--dark")
            NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            @MainActor func mainWindow() -> NSWindow? {
                let own = ScreenWindowController.shared?.window
                return NSApplication.shared.windows.first { $0.isVisible && $0.frame.height > 300 && $0.styleMask.contains(.titled) && $0 !== own }
            }
            // The window may not have come back from the last run: ask for it.
            for _ in 0..<10 where mainWindow() == nil {
                model.showMainWindow?()
                try? await Task.sleep(for: .milliseconds(500))
            }
            mainWindow()?.setContentSize(NSSize(width: 1000, height: 660))
            // A call as its panel shows it while the phone rings, then as the Calls section
            // shows it while it is spoken.
            let callPanel = CallPanelController(model: model)
            model.bluetoothCallsEnabled = true
            model.callLink = .connected
            model.liveCall = LiveCall(phase: .incoming, number: "+15550100")
            try? await Task.sleep(for: .milliseconds(900))
            if let panel = NSApplication.shared.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.styleMask.contains(.nonactivatingPanel) }),
               let image = capture(panel) {
                try? image.write(to: folder.appendingPathComponent("call-panel.png"))
            }
            for (index, item) in SidebarItem.allCases.enumerated() {
                model.selection = item
                if item == .calls {
                    model.liveCall = LiveCall(phase: .active, number: "+15550100")
                    model.liveCallSince = Date().addingTimeInterval(-42)
                } else {
                    model.liveCall = nil
                }
                try? await Task.sleep(for: .milliseconds(900))
                guard let window = mainWindow() else { continue }
                if let image = capture(window) {
                    let name = String(format: "%02d-%@.png", index + 1, item.rawValue.lowercased())
                    try? image.write(to: folder.appendingPathComponent(name))
                }
            }
            // The menus as the menu bar has them, with their shortcuts.
            var menus = ""
            for top in NSApplication.shared.mainMenu?.items ?? [] {
                menus += top.title + "\n"
                for item in top.submenu?.items ?? [] where !item.isSeparatorItem {
                    let keys = item.keyEquivalent.isEmpty ? "" : "  [" + (item.keyEquivalentModifierMask.contains(.shift) ? "shift+" : "")
                        + (item.keyEquivalentModifierMask.contains(.option) ? "option+" : "") + "cmd+" + item.keyEquivalent + "]"
                    menus += "    " + item.title + keys + (item.isEnabled ? "" : "  (off)") + "\n"
                }
            }
            try? menus.write(to: folder.appendingPathComponent("menus.txt"), atomically: true, encoding: .utf8)
            // The phone's screen in its own window, standing and turned on its side.
            model.selection = .screen
            model.screenVideoSize = CGSize(width: 720, height: 1600)
            model.screenInOwnWindow = true
            model.screenState = .live
            try? await Task.sleep(for: .milliseconds(900))
            if let window = ScreenWindowController.shared?.window, let image = capture(window) { try? image.write(to: folder.appendingPathComponent("screen-window.png")) }
            model.screenLocked = true
            try? await Task.sleep(for: .milliseconds(700))
            if let window = ScreenWindowController.shared?.window, let image = capture(window) { try? image.write(to: folder.appendingPathComponent("screen-window-locked.png")) }
            model.screenLocked = false
            model.screenProtected = true
            try? await Task.sleep(for: .milliseconds(700))
            if let window = ScreenWindowController.shared?.window, let image = capture(window) { try? image.write(to: folder.appendingPathComponent("screen-window-protected.png")) }
            model.screenProtected = false
            if let window = mainWindow(), let image = capture(window) { try? image.write(to: folder.appendingPathComponent("screen-window-main.png")) }
            model.screenTurns = 1
            try? await Task.sleep(for: .milliseconds(1200))
            if let window = ScreenWindowController.shared?.window, let image = capture(window) { try? image.write(to: folder.appendingPathComponent("screen-window-turned.png")) }
            model.screenTurns = 0
            model.screenInOwnWindow = false
            try? await Task.sleep(for: .milliseconds(700))
            if let window = mainWindow(), let image = capture(window) { try? image.write(to: folder.appendingPathComponent("screen-in-main.png")) }
            model.screenState = .idle
            // The way in, screen by screen, in the same window.
            let expires = Date().addingTimeInterval(540)
            let phases: [(String, AppPhase)] = [
                ("onboarding-1-starting", .starting),
                ("onboarding-2-welcome", .signedOut),
                ("onboarding-3-sign-in-code", .signingIn(code: "ABCD1234", url: "https://www.microsoft.com/link", expires: expires)),
                ("onboarding-4-link", .linking(nil)),
                ("onboarding-5-qr", .linking(.showLink(link: DemoData.pairingLink, expires: expires, manualLink: nil, pairingPIN: nil))),
                ("onboarding-6-pin", .linking(.confirmChallengePIN(pin: "ETLXZB", expires: expires))),
                ("onboarding-7-failed", .linking(.failed(.accountMismatch))),
            ]
            let before = model.phase
            for (name, phase) in phases {
                model.phase = phase
                model.hasBeenConnected = false
                try? await Task.sleep(for: .milliseconds(700))
                if let window = mainWindow(), let image = capture(window) { try? image.write(to: folder.appendingPathComponent(name + ".png")) }
            }
            model.phase = before
            // The settings window, pane by pane.
            for tab in SettingsTab.allCases {
                model.settingsTab = tab
                model.showSettings?()
                try? await Task.sleep(for: .milliseconds(1200))
                let settings = NSApplication.shared.windows.first { $0.isVisible && $0 !== mainWindow() && $0.styleMask.contains(.titled) && $0.frame.height > 120 }
                if let settings, let image = capture(settings) {
                    try? image.write(to: folder.appendingPathComponent("settings-\(tab.rawValue.lowercased()).png"))
                }
            }
            _ = callPanel
            exit(0)
        }
    }

    /// Development aid: with `--demo --demo-feed <folder>` the sample notifications arrive
    /// the way a real start brings them, one after the other into a list that began empty,
    /// their apps' names and icons after them, and a picture of the window is saved.
    static func runFeed(model: AppModel, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let all = model.notifications
        let apps = model.apps
        model.notifications = []
        let appsFirst = CommandLine.arguments.contains("--apps-first")
        if !appsFirst { model.apps = [:] }
        model.selection = .notifications
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            NSApplication.shared.activate(ignoringOtherApps: true)
            @MainActor func mainWindow() -> NSWindow? {
                NSApplication.shared.windows.first { $0.isVisible && $0.frame.height > 300 && $0.styleMask.contains(.titled) }
            }
            for _ in 0..<10 where mainWindow() == nil {
                model.showMainWindow?()
                try? await Task.sleep(for: .milliseconds(500))
            }
            mainWindow()?.setContentSize(NSSize(width: 1000, height: 660))
            try? await Task.sleep(for: .milliseconds(600))
            // Oldest first, as the phone sends what it holds; each in a turn of its own.
            for notification in all.sorted(by: { $0.postTime < $1.postTime }) {
                model.upsert(notification)
                try? await Task.sleep(for: .milliseconds(15))
            }
            try? await Task.sleep(for: .milliseconds(250))
            model.apps = apps
            try? await Task.sleep(for: .milliseconds(120))
            if let first = all.first { model.upsert(first) }
            if appsFirst, let newest = all.max(by: { $0.postTime < $1.postTime }) {
                // The newest once more with other words, gone, and back: as a phone does
                // that rewrites a notification while it is being listed.
                var other = newest
                other.text = nil
                model.upsert(other)
                try? await Task.sleep(for: .milliseconds(30))
                model.removeNotification(key: newest.key)
                try? await Task.sleep(for: .milliseconds(30))
                model.upsert(other)
            }
            for (index, wait) in [300, 1500, 3000].enumerated() {
                try? await Task.sleep(for: .milliseconds(wait))
                if let window = mainWindow(), let image = capture(window) { try? image.write(to: folder.appendingPathComponent("feed-\(index + 1).png")) }
            }
            // With `--swipe`: two fingers to the left over the first notification, as the
            // events would bring it; a picture midway and one after letting go.
            if CommandLine.arguments.contains("--swipe"), let swipe = NotificationSwipe.current, let window = mainWindow(), let content = window.contentView,
               let first = model.visibleNotifications.first, let frame = swipe.frames[first.id] {
                var report = "rows known: \(swipe.frames.count); window found: \(swipe.window === window)\n"
                // Where the row is by its own account must be where the window has its scrolling view.
                func scrollers(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? [] + view.subviews.flatMap(scrollers) }
                let inside = scrollers(content).contains { scroller in
                    var rect = content.convert(scroller.convert(scroller.bounds, to: nil), from: nil)
                    if !content.isFlipped { rect.origin.y = content.bounds.height - rect.maxY }
                    return rect.insetBy(dx: -1, dy: -1).contains(frame) || rect.intersects(frame) && rect.width >= frame.width
                }
                report += "the row lies within a scrolling view of the window: \(inside)\n"
                let point = CGPoint(x: frame.midX, y: frame.midY)
                report += "taken at the start: \(swipe.handle(point: point, dx: -8, dy: 0.5, phase: .began))\n"
                for _ in 0..<9 { _ = swipe.handle(point: point, dx: -12, dy: 0, phase: .changed) }
                try? await Task.sleep(for: .milliseconds(300))
                if let image = capture(window) { try? image.write(to: folder.appendingPathComponent("swipe-1-midway.png")) }
                report += "midway: pushed \(Int(swipe.track?.offset ?? 0)) points\n"
                for _ in 0..<12 { _ = swipe.handle(point: point, dx: -12, dy: 0, phase: .changed) }
                try? await Task.sleep(for: .milliseconds(300))
                if let image = capture(window) { try? image.write(to: folder.appendingPathComponent("swipe-2-far.png")) }
                _ = swipe.handle(point: point, dx: 0, dy: 0, phase: .ended)
                report += "the glide after it is taken too: \(swipe.handle(point: point, dx: -3, dy: 0, phase: .momentum(ended: true)))\n"
                try? await Task.sleep(for: .milliseconds(900))
                if let image = capture(window) { try? image.write(to: folder.appendingPathComponent("swipe-3-gone.png")) }
                report += "notifications after the swipe: \(model.visibleNotifications.count) of \(all.count); the swiped one gone: \(!model.visibleNotifications.contains { $0.id == first.id })\n"
                // And scrolling along the list is left alone.
                report += "a movement along the list is not taken: \(!swipe.handle(point: point, dx: 0.4, dy: -9, phase: .began))\n"
                try? report.write(to: folder.appendingPathComponent("swipe.txt"), atomically: true, encoding: .utf8)
            }
            exit(0)
        }
    }

    /// A picture of one of this app's own windows as the window server composes it.
    /// Development aid: pictures of the main window every 40 ms while the sidebar narrows to
    /// its symbols and widens again, to see the movement frame by frame.
    static func runSidebarFrames(model: AppModel, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            NSApplication.shared.activate(ignoringOtherApps: true)
            model.showMainWindow?()
            try? await Task.sleep(for: .seconds(1))
            guard let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.frame.height > 300 && $0.styleMask.contains(.titled) }) else { exit(1) }
            for (pass, collapse) in [true, false].enumerated() {
                model.sidebarCollapsed = collapse
                for frame in 0..<16 {
                    if let image = capture(window) {
                        try? image.write(to: folder.appendingPathComponent(String(format: "%d-%02d.png", pass, frame)))
                    }
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
            exit(0)
        }
    }

    private static func capture(_ window: NSWindow) -> Data? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // This window only, without its shadow, at the screen's resolution.
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 3)?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
