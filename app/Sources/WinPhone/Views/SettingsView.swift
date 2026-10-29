import ServiceManagement
import SwiftUI
import WinPhoneCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", notifications = "Notifications", advanced = "Advanced"
    var id: SettingsTab { self }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .notifications: return "bell.badge"
        case .advanced: return "gearshape.2"
        }
    }
}

/// The app's settings window, a pane per subject as in the system's own apps: what the app
/// does and shares, how phone notifications show on this Mac, and the rest.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            GeneralSettings(model: model)
                .tabItem { Label(SettingsTab.general.rawValue, systemImage: SettingsTab.general.symbol) }
                .tag(SettingsTab.general)
            AppNotificationSettings(model: model)
                .tabItem { Label(SettingsTab.notifications.rawValue, systemImage: SettingsTab.notifications.symbol) }
                .tag(SettingsTab.notifications)
            AdvancedSettings(model: model)
                .tabItem { Label(SettingsTab.advanced.rawValue, systemImage: SettingsTab.advanced.symbol) }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 540)
    }

    /// A pane's height: what it would like, or what fits between the menu bar and the Dock
    /// with the window's title and tabs above it.
    static func paneHeight(wanted: CGFloat, screen: CGFloat? = NSScreen.main?.visibleFrame.height) -> CGFloat {
        max(320, min(wanted, (screen ?? 800) - 140))
    }
}

/// Text under a group of settings, set like the system's.
private struct Footnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GeneralSettings: View {
    @ObservedObject var model: AppModel
    @State private var opensAtLogin = LoginItem.isEnabled
    @State private var loginItemProblem: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { opensAtLogin }, set: { wanted in
                    loginItemProblem = LoginItem.set(wanted)
                    opensAtLogin = LoginItem.isEnabled
                }))
                if let loginItemProblem {
                    Text(loginItemProblem).font(.caption).foregroundStyle(.orange)
                }
            } footer: {
                Footnote("The phone stays connected while Phone Mac Link is running, also with its window closed. It lives in the menu bar.")
            }
            Section {
                Toggle(isOn: Binding(get: { model.clipboardSyncEnabled }, set: { model.clipboardSyncEnabled = $0; model.actions?.setClipboardSync($0) })) {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                    Text("Copy on one device, paste on the other. Copied content passes through Microsoft's servers.")
                }
                Toggle(isOn: Binding(get: { model.filesEnabled }, set: { model.actions?.setFilesEnabled($0) })) {
                    Label("Receive files", systemImage: "arrow.down.doc")
                    Text("The phone lists this Mac when you share to Link to Windows. Files are saved to Downloads. Takes effect the next time Phone Mac Link starts.")
                }
                Toggle(isOn: $model.linksAnnounced) {
                    Label("Links from the phone", systemImage: "link")
                    Text("A link copied on the phone, or a page open in its browser, is offered here to open.")
                }
                Toggle(isOn: $model.linksOpenAtOnce) {
                    Label("Open them without asking", systemImage: "arrow.up.forward.app")
                    Text("Opens the link in this Mac's browser as soon as it arrives.")
                }
                .disabled(!model.linksAnnounced && !model.linksOpenAtOnce)
            } header: {
                Text("Sharing")
            } footer: {
                Footnote("On the same Wi-Fi, files travel directly between the two devices. Otherwise they go over the internet, which uses the phone's mobile data. Sending files to the phone is always available in the Files section.")
            }
            Section {
                Toggle(isOn: Binding(get: { model.phoneStatus?.syncOverMobileData ?? false }, set: { model.actions?.setSyncOverMobileData($0) })) {
                    Label("Sync over mobile data", systemImage: "antenna.radiowaves.left.and.right")
                    Text(model.phoneStatus?.isSyncPausedOnMobileData == true
                         ? "The phone is on mobile data now and is holding back its notifications, messages and photos."
                         : "When the phone is not on Wi-Fi, it keeps sending its notifications, messages and photos. Uses the phone's data plan.")
                }
                .disabled(!model.isConnected || model.phoneStatus?.syncOverMobileData == nil || model.pendingControl == .mobileData)
                Toggle(isOn: $model.batteryLowAlert) {
                    Label("Low battery alert", systemImage: "battery.25percent")
                    Text("A Mac notification when the phone falls to 20% and to 10%.")
                }
                Toggle(isOn: $model.batteryFullAlert) {
                    Label("Charged alert", systemImage: "battery.100percent.bolt")
                    Text("A Mac notification when the phone is fully charged.")
                }
            } header: {
                Text("Phone")
            } footer: {
                Footnote("A setting on the phone, the same for any Windows PC it is linked to. Away from Wi-Fi the phone's screen and files use mobile data as well, and need this switch on.")
            }
            Section {
                Toggle(isOn: Binding(get: { model.bluetoothCallsEnabled }, set: { model.actions?.setBluetoothCalls($0) })) {
                    Label("Calls on this Mac", systemImage: "phone.connection")
                    Text(GeneralSettings.callsStatus(model.callLink, candidates: model.callDevices.count))
                }
                if model.bluetoothCallsEnabled, model.callDevices.count > 1 {
                    Picker("Phone for calls", selection: Binding(get: { model.callDeviceAddress ?? "" }, set: { model.actions?.chooseCallDevice($0) })) {
                        if model.callDeviceAddress == nil { Text("Choose…").tag("") }
                        ForEach(model.callDevices) { Text($0.name).tag($0.address) }
                    }
                }
                Toggle(isOn: Binding(get: { model.callsEnabled }, set: { model.actions?.setCallsEnabled($0) })) {
                    Label("Recent calls", systemImage: "phone")
                    Text("Experimental. Syncs the call history of the last 30 days.")
                }
            } header: {
                Text("Calls")
            } footer: {
                Footnote("Calls are controlled over Bluetooth: pair the phone with this Mac in System Settings, Bluetooth, and keep it in reach. macOS does not let an app carry a call's sound, so that stays on the phone. Recent calls is a setting on the phone, shared with any Windows PC it is linked to; the phone reconnects when it changes.")
            }
        }
        .formStyle(.grouped)
        // As tall as the screen allows and no taller: the rest scrolls. The pane had grown
        // past the bottom of a laptop's screen, where a settings window cannot be resized.
        .frame(height: SettingsView.paneHeight(wanted: 680))
    }

    static func callsStatus(_ state: CallLinkState, candidates: Int = 0) -> String {
        switch state {
        case .off: return "See who is calling, answer, hang up and place calls from here; you talk on the phone. Uses Bluetooth: the phone must be paired with this Mac in Bluetooth settings."
        case .notAllowed: return "Phone Mac Link may not use Bluetooth. Allow it in System Settings, Privacy & Security, Bluetooth, then switch this off and on."
        case .noPhone where candidates > 1: return "Several phones are paired with this Mac. Choose yours below."
        case .noPhone: return "No paired phone found. Pair the phone with this Mac in System Settings, Bluetooth."
        case .connecting: return "Connecting to the phone over Bluetooth…"
        case .connected: return "Connected over Bluetooth. Calls are answered and placed from here; you talk on the phone."
        case .unreachable: return "The phone is not in Bluetooth reach, or its Bluetooth is off. Trying again."
        }
    }
}

/// How phone notifications show on this Mac, and the list of phone apps with what each may do
/// here. Nothing changes on the phone.
struct AppNotificationSettings: View {
    @ObservedObject var model: AppModel
    @State private var search = ""

    var body: some View {
        Form {
            Section {
                Toggle("Show as Mac notifications", isOn: Binding(get: { model.showsBanners }, set: { wanted in
                    model.showsBanners = wanted
                    model.actions?.bannersChanged()
                }))
                Toggle("Badge the Dock icon", isOn: Binding(get: { model.showsDockBadge }, set: { wanted in
                    model.showsDockBadge = wanted
                    model.actions?.bannersChanged()
                }))
                Picker("Clicking a notification", selection: $model.clickOpensAppOnPhone) {
                    Text("Opens the app on the phone").tag(true)
                    Text("Shows it in Phone Mac Link").tag(false)
                }
            } footer: {
                Footnote("With Mac notifications off, phone notifications still appear in the Phone Mac Link window. Opening the app on the phone also removes the notification there. Sound and banner style are set for WinPhone in System Settings › Notifications.")
            }
            AppNotificationList(model: model, search: $search)
        }
        .formStyle(.grouped)
        .frame(height: SettingsView.paneHeight(wanted: 600))
    }
}

struct AdvancedSettings: View {
    @ObservedObject var model: AppModel
    @State private var confirmingClear = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Diagnostics log") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppFolders.log])
                    }
                }
            } footer: {
                Footnote("The log records connection steps and error codes. It never holds message or notification text, clipboard content, file names or sign-in secrets.")
            }
            Section {
                LabeledContent("Transfer history") {
                    Button("Clear…") { confirmingClear = true }.disabled(model.receivedFiles.isEmpty)
                }
            } footer: {
                Footnote("The list in the Files section. Clearing it leaves the files themselves where they are.")
            }
            Section {
                LabeledContent("Version", value: version)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Clear the list of transferred files?", isPresented: $confirmingClear) {
            Button("Clear List", role: .destructive) { model.receivedFiles.removeAll() }
        } message: {
            Text("The files stay on this Mac and on the phone.")
        }
    }
}

/// Starting with the Mac, through the system's login items.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Switches the login item. Returns what to tell the user when that did not work.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            if enabled, SMAppService.mainApp.status == .requiresApproval {
                return "Allow Phone Mac Link under System Settings › General › Login Items."
            }
            return nil
        } catch {
            return "macOS did not accept the change: \(error.localizedDescription)"
        }
    }
}

/// The three finer choices for one app, as switches for a menu.
struct AppNotificationOptions: View {
    @ObservedObject var model: AppModel
    let package: String

    private func binding(_ path: WritableKeyPath<AppNotificationRule, Bool>) -> Binding<Bool> {
        Binding(get: { model.rule(for: package)[keyPath: path] }, set: { wanted in
            var rule = model.rule(for: package)
            rule[keyPath: path] = wanted
            model.actions?.setRule(rule, package: package)
        })
    }

    var body: some View {
        Toggle("Show as Mac Notification", isOn: binding(\.banner))
        Toggle("Play Sound", isOn: binding(\.sound)).disabled(!model.rule(for: package).banner)
        Toggle("Count in Badge", isOn: binding(\.badge))
    }
}

/// The phone's apps, each with a switch for "anything at all" and a menu for the finer
/// choices: banner, sound, count. Sections of a form, for Settings and for the sheet that the
/// Notifications section opens.
struct AppNotificationList: View {
    @ObservedObject var model: AppModel
    @Binding var search: String

    private var apps: [(package: String, name: String, icon: Data?)] {
        let all = model.notifyingApps
        let query = search.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.package.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Section {
            if model.notifyingApps.isEmpty {
                Text("The list fills in once the phone has connected.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search apps", text: $search, prompt: Text("Search")).textFieldStyle(.plain).labelsHidden()
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.borderless).accessibilityLabel("Clear search")
                    }
                }
                ForEach(apps, id: \.package) { app in
                    let rule = model.rule(for: app.package)
                    HStack(spacing: 10) {
                        if let icon = app.icon, let image = NSImage(data: icon) {
                            Image(nsImage: image).resizable().interpolation(.high).frame(width: 24, height: 24)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).accessibilityHidden(true)
                        } else {
                            Image(systemName: "app.dashed").font(.system(size: 18)).frame(width: 24, height: 24).foregroundStyle(.secondary).accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).lineLimit(1)
                            if let summary = rule.summary, rule.list { Text(summary).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 8)
                        Menu {
                            AppNotificationOptions(model: model, package: app.package)
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .disabled(!rule.list)
                        .help("Banner, sound and count for \(app.name)")
                        .accessibilityLabel("Options for \(app.name)")
                        Toggle(app.name, isOn: Binding(get: { rule.list }, set: { model.actions?.setMuted(!$0, package: app.package) }))
                            .labelsHidden().toggleStyle(.switch)
                    }
                }
                if apps.isEmpty { Text("No app matches.").foregroundStyle(.secondary) }
            }
        } header: {
            HStack {
                Text("Phone Apps")
                Spacer()
                if !model.appRules.isEmpty {
                    Button("Reset All") { for package in model.appRules.keys { model.actions?.setRule(AppNotificationRule(), package: package) } }
                        .buttonStyle(.link).font(.callout)
                }
            }
        } footer: {
            Footnote("The switch decides whether an app shows on this Mac at all; the sliders next to it, whether it also shows as a Mac notification, with sound, and whether it counts on the Dock icon. Nothing changes on the phone.")
        }
    }
}

/// The app list on its own, from the gear in the Notifications section.
struct AppNotificationSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            Form { AppNotificationList(model: model, search: $search) }
                .formStyle(.grouped)
            Divider()
            HStack {
                Button("All Notification Settings…") {
                    dismiss()
                    model.settingsTab = .notifications
                    model.showSettings?()
                }
                .buttonStyle(.link)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 560)
    }
}
