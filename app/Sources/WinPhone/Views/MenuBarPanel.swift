import AppKit
import SwiftUI
import WinPhoneCore

/// What opens under the menu bar item: the phone at a glance, as Phone Link's own flyout
/// shows it. The phone and how it is doing, its switches, a call or what is playing, the
/// sections of the main window with what is new in them, and the latest notifications.
struct MenuBarPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    /// The panel's own window, to put away should dismissing not do it.
    @State private var window: NSWindow?

    private var name: String {
        switch model.phase {
        case .connected(let name), .connecting(let name): return name
        default: return "Phone Mac Link"
        }
    }

    /// The sections offered here, with what is new in each.
    static func sections(showsCalls: Bool) -> [SidebarItem] {
        [.notifications, .messages] + (showsCalls ? [.calls] : []) + [.photos, .storage, .screen]
    }

    static func badge(for item: SidebarItem, notifications: Int, unreadTexts: Int) -> Int {
        switch item {
        case .notifications: return notifications
        case .messages: return unreadTexts
        default: return 0
        }
    }

    /// The newest few notifications, for the "Recent" part.
    static func recent(_ notifications: [PhoneNotification], limit: Int = 3) -> [PhoneNotification] {
        Array(notifications.sorted { $0.postTime > $1.postTime }.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.showsMainInterface {
                if model.isConnected, let status = model.phoneStatus {
                    PhoneControls(model: model, status: status)
                }
                if let notice = model.hotspotState.notice ?? model.controlNotice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let call = model.liveCall { callCard(call) }
                if model.isConnected, let session = model.nowPlaying {
                    NowPlayingCard(model: model, session: session)
                        .padding(10)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                VStack(spacing: 1) {
                    ForEach(MenuBarPanel.sections(showsCalls: model.showsCalls)) { item in
                        PanelRow(title: item.rawValue, symbol: item.tileSymbol, tint: item.tint,
                                 badge: MenuBarPanel.badge(for: item, notifications: model.countedNotifications.count, unreadTexts: model.unreadMessageCount)) {
                            leave { model.show(item) }
                        }
                    }
                    PanelRow(title: "Send Files…", symbol: "arrow.up.doc.fill", tint: SidebarItem.files.tint, badge: 0) { leave { model.show(.files) } }
                }
                let recent = MenuBarPanel.recent(model.visibleNotifications)
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recent").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 8)
                        VStack(spacing: 1) {
                            ForEach(recent) { notification in
                                RecentNotificationRow(model: model, notification: notification) { leave { model.reveal(notification) } }
                            }
                        }
                    }
                }
            } else {
                Text("Set up Phone Mac Link in its window to see your phone here.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        .background(WindowReader { window = $0 })
    }

    /// Goes to a window of the app: the panel closes, as a menu does once a line is chosen.
    private func leave(_ open: () -> Void) {
        dismiss()
        if let window, window.isVisible { window.orderOut(nil) }
        open()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "smartphone")
                .font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(model.isConnected ? Color.green : Color.orange).frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 2).padding(-1))
                        .offset(x: 3, y: 3)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if model.switchablePhones.count > 1 {
                    Menu {
                        ForEach(model.switchablePhones) { phone in
                            Button(phone.name) { model.actions?.selectPhone(phone) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(name).font(.headline).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                } else {
                    Text(name).font(.headline).lineLimit(1)
                }
                if model.isConnected, let status = model.phoneStatus {
                    PhoneStatusStrip(status: status, showsModes: false)
                } else {
                    Text(model.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button { leave { openSettings(); NSApplication.shared.activate(ignoringOtherApps: true) } } label: {
                Image(systemName: "gearshape").font(.system(size: 14))
                    .frame(width: 28, height: 28).background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain).help("Settings")
            .accessibilityLabel("Settings")
        }
        .accessibilityElement(children: .contain)
    }

    private func callCard(_ call: LiveCall) -> some View {
        HStack(spacing: 10) {
            Image(systemName: call.phase == .incoming ? "phone.arrow.down.left.fill" : "phone.fill")
                .foregroundStyle(.white).frame(width: 30, height: 30).background(Color.green, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title(for: call)).font(.callout.weight(.medium)).lineLimit(1)
                Text(call.phase == .incoming ? "Incoming call" : "On a call · audio on phone").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if call.phase == .incoming {
                Button("Answer") { model.actions?.answerCall() }.buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
                Button("Decline") { model.actions?.endCall() }.buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
            } else {
                Button("End") { model.actions?.endCall() }.buttonStyle(.borderedProminent).tint(.red).controlSize(.small)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.showsMainInterface {
                Toggle(isOn: Binding(get: { model.clipboardSyncEnabled }, set: { model.clipboardSyncEnabled = $0; model.actions?.setClipboardSync($0) })) {
                    Label("Clipboard", systemImage: "doc.on.clipboard").font(.callout)
                }
                .toggleStyle(.switch).controlSize(.mini)
                .help("Copy on one device, paste on the other")
            }
            Spacer(minLength: 0)
            Button("Open Phone Mac Link") { leave { model.showMainWindow?() } }
                .controlSize(.small)
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .controlSize(.small).help("Quit Phone Mac Link")
                .accessibilityLabel("Quit")
                .keyboardShortcut("q")
        }
    }
}

/// One line of the panel that leads somewhere: a sign, a name, and a count of what is new.
/// Lights up under the pointer as a menu's line does.
struct PanelRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let badge: Int
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, tint: tint, size: 22)
                Text(title)
                Spacer(minLength: 0)
                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)").font(.caption.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .foregroundStyle(.white).background(Color.accentColor, in: Capsule())
                        .accessibilityLabel("\(badge) new")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// One of the latest notifications: the app's icon, who or what, and the beginning of it.
struct RecentNotificationRow: View {
    @ObservedObject var model: AppModel
    let notification: PhoneNotification
    let action: () -> Void
    @State private var hovered = false

    private var icon: NSImage? {
        (model.apps[notification.packageName]?.icon ?? notification.smallIcon).flatMap { NSImage(data: $0) }
    }

    private var heading: String {
        if let title = notification.title, !title.isEmpty { return title }
        return notification.appName.isEmpty ? (model.apps[notification.packageName]?.name ?? "Notification") : notification.appName
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "app.badge").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 26, height: 26).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(heading).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Date(timeIntervalSince1970: TimeInterval(notification.postTime) / 1000), style: .time)
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    let body = notification.displayBody
                    if !body.isEmpty { Text(body).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(hovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
