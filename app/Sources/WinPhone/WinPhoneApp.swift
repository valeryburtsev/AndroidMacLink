import AppKit
import SwiftUI
import WinPhoneCore

@main
enum Main {
    static func main() {
        // A write to a connection the system has shut must be an error, not the end of the app.
        NanoSocketTransport.ignoreBrokenPipes()
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            // Development aid: render every screen to PNG files and exit, without showing a window.
            MainActor.assumeIsolated { Snapshots.render(to: URL(fileURLWithPath: arguments[index + 1])) }
            return
        }
        WinPhoneApp.main()
    }
}

struct WinPhoneApp: App {
    @MainActor static var demoPanel: CallPanelController?
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    private let actions: AppActions

    init() {
        let model = AppModel()
        // `--demo` fills the interface with sample data and never touches the network.
        let actions: AppActions = CommandLine.arguments.contains("--demo") ? DemoActions(model: model, startConnected: true) : LiveActions(model: model)
        model.actions = actions
        self.actions = actions
        _model = StateObject(wrappedValue: model)
        ScreenWindowController.shared = ScreenWindowController(model: model)
        AppDelegate.model = model
        // "Send Link to Phone" in every app's Services menu, while sending is switched on.
        LinkService.shared.model = model
        if AppModel.linkSendingEnabled { NSApplication.shared.servicesProvider = LinkService.shared }
        if CommandLine.arguments.contains("--demo"), CommandLine.arguments.contains("--call-panel") {
            // Development aid: the call panel alone, with a call that rings.
            WinPhoneApp.demoPanel = CallPanelController(model: model)
            model.bluetoothCallsEnabled = true
            model.callLink = .connected
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.liveCall = LiveCall(phase: .incoming, number: "+15550100") }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--demo-feed"), index + 1 < CommandLine.arguments.count {
            WindowSnapshots.runFeed(model: model, to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--sidebar-frames"), index + 1 < CommandLine.arguments.count {
            WindowSnapshots.runSidebarFrames(model: model, to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
        if let index = CommandLine.arguments.firstIndex(of: "--window-snapshot"), index + 1 < CommandLine.arguments.count {
            WindowSnapshots.run(model: model, to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
    }

    var body: some Scene {
        Window("Phone Mac Link", id: "main") {
            MainView(model: model)
                .registeringWindows(of: model)
                .frame(minWidth: 860, minHeight: 500)
                // Files dropped on the Dock icon go to the phone; winphone://send?url=… comes
                // from a shortcut or another app.
                .onOpenURL { url in
                    if url.isFileURL { model.gatherFileToSend(url) } else { LinkService.shared.handle(url) }
                }
        }
        .defaultSize(width: 1000, height: 660)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView(model: model)
        }

        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            Label("Phone Mac Link", systemImage: model.statusSymbol)
                .labelStyle(.iconOnly)
                .registeringWindows(of: model)
        }
        // A panel of its own making, not a list of menu items.
        .menuBarExtraStyle(.window)
    }
}

/// What the app does at launch and when it is opened again while running.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { DockPresence.follow() }
    }

    /// Opened again, from Finder, Launchpad or Spotlight, with the window closed and so no
    /// icon in the Dock: the window comes back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { MainActor.assumeIsolated { AppDelegate.model?.showMainWindow?() } }
        return true
    }
}
