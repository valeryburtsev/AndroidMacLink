import AppKit

/// The Dock icon is there while a window of this app is: closing the last one leaves only
/// the menu bar icon, as for an app that keeps running in the background; opening one again
/// brings the Dock icon back.
@MainActor
enum DockPresence {
    private static var observers: [NSObjectProtocol] = []

    /// Starts following the windows. Called once, at launch.
    static func follow() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { if counts(window) { show() } }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard counts(window) else { return }
                    // Looked at once the window has gone, so it no longer counts itself.
                    DispatchQueue.main.async { MainActor.assumeIsolated { hideIfNoWindows() } }
                }
            },
        ]
        // The app may come back with no window open, when it was quit with none.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { hideIfNoWindows() } }
    }

    /// Puts the icon in the Dock. Called before a window is opened, so it comes up in front.
    static func show() {
        if NSApplication.shared.activationPolicy() != .regular { NSApplication.shared.setActivationPolicy(.regular) }
    }

    static func hideIfNoWindows() {
        guard !NSApplication.shared.windows.contains(where: { counts($0) && ($0.isVisible || $0.isMiniaturized) }) else { return }
        if NSApplication.shared.activationPolicy() == .regular { NSApplication.shared.setActivationPolicy(.accessory) }
    }

    /// Windows of the app's own: the main window, Settings, the phone's screen. Not the menu
    /// bar's panel, the call panel, or open and save panels.
    static func counts(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && window.level == .normal
    }
}
