import SwiftUI
import WinPhoneCore

enum SidebarItem: String, CaseIterable, Identifiable {
    case notifications = "Notifications"
    case messages = "Messages"
    case calls = "Calls"
    case contacts = "Contacts"
    case photos = "Photos"
    case files = "Files"
    case screen = "Phone Screen"
    case apps = "Apps"
    case links = "Links"
    case clipboard = "Clipboard"
    case devices = "Devices"
    /// Declared last, so that the numbers of the sections before it stay as they were.
    case storage = "Phone Storage"

    /// Rows are identified by the item itself, which is also what the selection holds. With a
    /// different ID type the list cannot match a click to a row.
    var id: SidebarItem { self }

    /// What the phone holds, and what belongs to this Mac's side of the link.
    static let phoneItems: [SidebarItem] = [.notifications, .messages, .calls, .contacts, .photos, .files, .storage, .screen, .apps]
    static let macItems: [SidebarItem] = [.links, .clipboard, .devices]

    /// The number that goes with Command to show this section; the same whichever sections
    /// are switched on.
    var shortcutNumber: Int? {
        guard let index = SidebarItem.allCases.firstIndex(of: self), index < 9 else { return nil }
        return index + 1
    }

    var symbol: String {
        switch self {
        case .notifications: return "bell"
        case .messages: return "message"
        case .calls: return "phone"
        case .contacts: return "person.crop.circle"
        case .photos: return "photo.on.rectangle"
        case .files: return "folder"
        case .screen: return "rectangle.portrait.on.rectangle.portrait.angled"
        case .apps: return "square.grid.2x2"
        case .links: return "link"
        case .clipboard: return "doc.on.clipboard"
        case .devices: return "laptopcomputer.and.iphone"
        case .storage: return "internaldrive"
        }
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    /// The page's title and subtitle, as the page gives them.
    @State private var header = SectionTitle()

    var body: some View {
        if model.showsMainInterface {
            // The sidebar's panel and the page beside it. Not a split view: a split view will not
            // narrow its sidebar below a width of its own, nor move between widths smoothly.
            HStack(spacing: 0) {
                SidebarPanel(model: model)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Every page lies on the backdrop; its cards are lifted off it.
                    .background(Theme.canvas.ignoresSafeArea())
                    .overlay(alignment: .topLeading) {
                        SectionHeader(title: header.title ?? (model.selection ?? .notifications).rawValue, subtitle: header.subtitle)
                            // Narrowed, the sidebar's button stands where the title would begin.
                            .padding(.leading, model.sidebarCollapsed ? SidebarPanel.toggleRoom : 0)
                            .ignoresSafeArea(edges: .top)
                    }
            }
            .onPreferenceChange(SectionTitleKey.self) { header = $0 }
            .background(NoInitialFocus())
            .modifier(OwnPageTitles(model: model))
            .animation(SidebarPanel.motion, value: model.sidebarCollapsed)
        } else {
            OnboardingView(model: model)
        }
    }

    private var detail: some View {
                // Calls is only there while the call history is switched on.
                Group {
                    switch (model.selection == .calls && !model.showsCalls) ? .notifications : (model.selection ?? .notifications) {
                    case .notifications: NotificationsView(model: model)
                    case .messages: MessagesView(model: model)
                    case .calls: CallsView(model: model)
                    case .contacts: ContactsView(model: model)
                    case .photos: PhotosView(model: model)
                    case .files: FilesView(model: model)
                    case .storage: StorageView(model: model)
                    case .screen: ScreenView(model: model)
                    case .apps: AppsView(model: model)
                    case .links: LinksView(model: model)
                    case .clipboard: ClipboardView(model: model)
                    case .devices: DevicesView(model: model)
                    }
                }
                // The toolbar sits on the content, as in the system's own apps, not on a band of its own.
                .toolbarBackground(.hidden, for: .windowToolbar)
    }
}

/// The sidebar: the phone, then every section, on a panel floating in the window. Narrowed,
/// it keeps only the symbols: they stay where they are while the panel's edge moves in over
/// the names, and what does not fit a strip fades away.
struct SidebarPanel: View {
    /// The panel's widths. Narrowed, its inset (`Theme.panelInset`) and width put the window's
    /// close, minimise and zoom buttons in its middle (they span 18.5 to 79.5 points from the
    /// window's left edge).
    static let railWidth: CGFloat = 82
    static let fullWidth: CGFloat = 244
    /// The split view's column around the panel: the panel and the backdrop beside it.
    static var railColumn: CGFloat { railWidth + Theme.panelInset * 1.5 }
    static var fullColumn: CGFloat { fullWidth + Theme.panelInset * 1.5 }
    /// Where every symbol's middle is, from the panel's left edge, in both widths.
    static let symbolCentre: CGFloat = railWidth / 2
    /// The room the sidebar's toolbar button takes past the narrow panel's edge.
    static let toggleRoom: CGFloat = 32
    /// How the panel narrows and widens.
    static let motion = Animation.spring(response: 0.42, dampingFraction: 0.88)

    @ObservedObject var model: AppModel
    private var rail: Bool { model.sidebarCollapsed }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    phone.padding(.bottom, 8)
                    ForEach(SidebarItem.phoneItems.filter { $0 != .calls || model.showsCalls }) { item in
                        SidebarRow(item: item, selected: model.selection == item, badge: badge(for: item), rail: rail) { model.selection = item }
                    }
                    ZStack(alignment: .leading) {
                        Text("This Mac").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .fixedSize().padding(.leading, 12).opacity(rail ? 0 : 1)
                        Divider().frame(width: 36).padding(.leading, SidebarPanel.symbolCentre - 18 - 6).opacity(rail ? 1 : 0)
                    }
                    .frame(height: 30, alignment: .leading)
                    ForEach(SidebarItem.macItems) { item in
                        SidebarRow(item: item, selected: model.selection == item, badge: 0, rail: rail) { model.selection = item }
                    }
                }
                .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 14)
            }
            // What scrolls on below fades out rather than being cut off flat.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
                }
            }
            if !rail {
                SidebarFooter(model: model).transition(.opacity)
            }
        }
        .frame(width: rail ? SidebarPanel.railWidth : SidebarPanel.fullWidth, alignment: .leading)
        .clipped()
        .floatingPanel()
    }

    /// The phone: its card with the switches, or narrowed, its tile alone.
    @ViewBuilder private var phone: some View {
        if rail {
            Menu {
                PhoneSwitcherItems(model: model)
            } label: {
                IconTile(symbol: "smartphone", tint: .accentColor, size: 36)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(model.isConnected ? Color.green : Color.orange).frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 2).padding(-1))
                            .offset(x: 3, y: 3)
                    }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .frame(width: 36, height: 44)
            .padding(.leading, SidebarPanel.symbolCentre - 18 - 6)
            .help(model.statusText)
            .accessibilityLabel(model.statusText)
            .transition(.opacity)
        } else {
            DeviceCard(model: model)
                .frame(width: SidebarPanel.fullWidth - 12)
                .transition(.opacity)
        }
    }

    private func badge(for item: SidebarItem) -> Int {
        switch item {
        case .notifications: return model.countedNotifications.count
        case .messages: return model.unreadMessageCount
        default: return 0
        }
    }
}

/// One section in the sidebar: its tile, its name, what is new in it; narrowed, the count
/// moves onto the tile's corner. The tile stays put in both.
private struct SidebarRow: View {
    let item: SidebarItem
    let selected: Bool
    let badge: Int
    let rail: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: item.tileSymbol, tint: item.tint, size: 28)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.system(size: 9, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                                .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                                .background(Color.red, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.card, lineWidth: 1.5).padding(-1))
                                .offset(x: 6, y: -5)
                                .opacity(rail ? 1 : 0)
                        }
                    }
                Text(item.rawValue).lineLimit(1).fixedSize()
                    .opacity(rail ? 0 : 1)
                Spacer(minLength: 8)
                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
                        .fixedSize().opacity(rail ? 0 : 1)
                }
            }
            .padding(.leading, SidebarPanel.symbolCentre - 14 - 6)
            .padding(.trailing, 12)
            .frame(width: SidebarPanel.fullWidth - 12, height: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The highlight is as wide as the panel lets it be: the whole row, or the strip.
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.primary.opacity(0.09)) : hovered ? AnyShapeStyle(Color.primary.opacity(0.045)) : AnyShapeStyle(.clear))
                .frame(width: (rail ? SidebarPanel.railWidth : SidebarPanel.fullWidth) - 12)
        }
        .onHover { hovered = $0 }
        .help(rail ? item.rawValue : "")
        .accessibilityLabel(badge > 0 ? "\(item.rawValue), \(badge) new" : item.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A page's title and subtitle, shown at the top of the page in line with the window's
/// buttons, where a split view would have put them.
struct SectionTitle: Equatable {
    var title: String?
    var subtitle: String?
}

struct SectionTitleKey: PreferenceKey {
    static let defaultValue = SectionTitle()
    static func reduce(value: inout SectionTitle, nextValue: () -> SectionTitle) {
        let next = nextValue()
        value.title = next.title ?? value.title
        value.subtitle = next.subtitle ?? value.subtitle
    }
}

extension View {
    /// The page's title, when it is not the section's name.
    func sectionTitle(_ title: String) -> some View {
        navigationTitle(title).preference(key: SectionTitleKey.self, value: SectionTitle(title: title))
    }

    /// A line under the page's title.
    func sectionSubtitle(_ subtitle: String) -> some View {
        preference(key: SectionTitleKey.self, value: SectionTitle(subtitle: subtitle.isEmpty ? nil : subtitle))
    }
}

/// The page's title in the toolbar's band, beside the sidebar's panel.
struct SectionHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(height: 52)
        .padding(.leading, 18)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The sidebar's button, right after the window's close, minimise and zoom buttons: on the
/// panel while it is wide, just past its edge while it is narrow; it does not move between
/// the two. The flexible space after it keeps the page's own buttons on the right.
private struct SidebarToggle: ToolbarContent {
    @ObservedObject var model: AppModel

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            // A plain symbol, as on the panel itself, without the toolbar's glass round it.
            ToolbarItem(placement: .navigation) { button }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { button }
        }
        ToolbarItem(placement: .navigation) { Spacer() }
    }

    private var button: some View {
        Button { withAnimation(SidebarPanel.motion) { model.sidebarCollapsed.toggle() } } label: {
            Label(model.sidebarCollapsed ? "Show Section Names" : "Show Symbols Only", systemImage: "sidebar.left")
        }
        .help(model.sidebarCollapsed ? "Show the section names" : "Show symbols only")
    }
}

/// Leaves nothing focused when the window opens. The sidebar is not a list any more, so the
/// window would otherwise start in the first text field of the page, such as a Reply box.
private struct NoInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        private var done = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !done, let window else { return }
            done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak window] in
                if window?.firstResponder is NSTextView { window?.makeFirstResponder(nil) }
            }
        }
    }
}

/// The window keeps a toolbar on every page (so pages start at the same height) but does not
/// show its title there: the page shows it, beside the sidebar.
private struct OwnPageTitles: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbar(removing: .title)
                .toolbar { SidebarToggle(model: model) }
                .toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            content
                .background(WindowReader { $0?.titleVisibility = .hidden })
                .toolbar { SidebarToggle(model: model) }
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

extension View {
    /// Gives the model the means to bring the main window back, also after it was closed.
    /// The menu bar item does this too: the app may start with the window closed, and then
    /// the window's own view never appears to do it.
    func registeringWindows(of model: AppModel) -> some View {
        modifier(WindowRegistration(model: model))
    }
}

struct WindowRegistration: ViewModifier {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onAppear {
            let open = openWindow, settings = openSettings
            model.showMainWindow = {
                DockPresence.show()
                open(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            model.showSettings = { settings() }
        }
    }
}

/// The phone at the top of the sidebar: its name, how it is doing, and the switches that act
/// on it, as Phone Link shows them above everything else.
struct DeviceCard: View {
    @ObservedObject var model: AppModel

    private var name: String {
        switch model.phase {
        case .connected(let name), .connecting(let name): return name
        default: return "Phone"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The phone's name is also where phones are switched, as at the top of Phone Link.
            Menu {
                PhoneSwitcherItems(model: model)
            } label: {
                header
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .help(model.switchablePhones.count > 1 ? "Switch to another phone" : "Phones")
            .accessibilityLabel(model.statusText)
            .accessibilityHint("Shows the linked phones")
            if model.isConnected, let status = model.phoneStatus {
                PhoneControls(model: model, status: status)
            }
            if model.isConnected, model.phoneStatus?.isSyncPausedOnMobileData == true {
                // As Phone Link does in its connection card: say why nothing new arrives, and
                // offer the phone's own switch for it.
                VStack(alignment: .leading, spacing: 4) {
                    Text("The phone is on mobile data and is not syncing.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Sync over Mobile Data") { model.actions?.setSyncOverMobileData(true) }
                        .controlSize(.small).disabled(model.pendingControl == .mobileData)
                }
            }
            if let notice = model.controlNotice {
                // All of it, as below: a row of the sidebar would cut it off after one line.
                Text(notice).font(.caption).foregroundStyle(.orange)
                    .lineLimit(8).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isConnected || model.hotspotState != .idle, let notice = model.hotspotState.notice {
                HStack(alignment: .top, spacing: 4) {
                    // All of it: a row of the sidebar would cut it off after one line.
                    Text(notice).font(.caption).foregroundStyle(model.hotspotState.isFailure ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(8).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.hotspotState.isBusy {
                        Button { model.hotspotState = .idle } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .buttonStyle(.borderless).accessibilityLabel("Dismiss")
                    }
                }
            }
            if !model.isConnected, let detail = model.connectionDetail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            // Looked at again every few seconds, so the offer appears without anything else changing.
            TimelineView(.periodic(from: .now, by: 5)) { context in
                if model.offersRelink(at: context.date), let since = model.phoneSilentSince {
                    RelinkOffer(model: model, since: since)
                }
            }
        }
        .padding(10)
        .background {
            // The phone's own surface: a wash of the accent colour, paler towards the bottom.
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.05)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 0.5)
                }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "smartphone", tint: .accentColor, size: 36)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(model.isConnected ? Color.green : Color.orange).frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(.background, lineWidth: 2).padding(-1))
                            .offset(x: 3, y: 3)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(name).font(.headline).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if model.isConnected, let status = model.phoneStatus {
                        PhoneStatusStrip(status: status, showsModes: false)
                    } else {
                        Text(model.isConnected ? "Connected" : "Connecting…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// The linked phones to choose from, then the ways to add one or manage them: the contents
/// of the phone menu in the sidebar and in the menu bar.
struct PhoneSwitcherItems: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let phones = model.switchablePhones
        if !phones.isEmpty {
            Picker("Phone", selection: Binding(get: { model.currentPhoneId ?? "" }, set: { id in
                if let phone = phones.first(where: { $0.id == id }) { model.actions?.selectPhone(phone) }
            })) {
                ForEach(phones) { phone in
                    Label(phone.name, systemImage: "smartphone").tag(phone.id)
                }
            }
            .pickerStyle(.inline).labelsHidden()
            Divider()
        }
        Button("Link Another Phone…") { model.actions?.startPairing(manual: false) }
        Button("Manage Devices…") {
            model.selection = .devices
            model.showMainWindow?()
        }
    }
}

/// The bottom of the sidebar: what is playing on the phone.
struct SidebarFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.isConnected, let session = model.nowPlaying {
            NowPlayingCard(model: model, session: session)
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                .padding(.horizontal, 10).padding(.bottom, 10)
        }
    }
}

/// How a switch in the device card looks: a small tile, filled while its setting is on.
struct TileButtonStyle: ButtonStyle {
    var isOn = false
    var tint = Color.accentColor
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 28)
            .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(isOn ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// What is playing on the phone, with the keys to control it.
struct NowPlayingCard: View {
    @ObservedObject var model: AppModel
    let session: PhoneNotification

    private var artwork: NSImage? {
        if let art = session.largeIcon, let image = NSImage(data: art) { return image }
        if let icon = model.apps[session.packageName]?.icon ?? session.smallIcon, let image = NSImage(data: icon) { return image }
        return nil
    }

    private var player: String {
        session.appName.isEmpty ? (model.apps[session.packageName]?.name ?? "Phone") : session.appName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if let artwork {
                        Image(nsImage: artwork).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                    }
                }
                .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title?.isEmpty == false ? session.title! : player).font(.callout.weight(.medium)).lineLimit(1)
                    Text(session.text?.isEmpty == false ? session.text! : player).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Playing on phone: \([session.title, session.text].compactMap { $0 }.joined(separator: ", "))")
            HStack(spacing: 18) {
                Spacer(minLength: 0)
                key("backward.fill", "Previous", .previous)
                key(session.isPlaying ? "pause.fill" : "play.fill", session.isPlaying ? "Pause" : "Play", session.isPlaying ? .pause : .play)
                    .font(.title3)
                key("forward.fill", "Next", .next)
                Spacer(minLength: 0)
            }
            .disabled(model.pendingControl == .media)
        }
    }

    private func key(_ symbol: String, _ label: String, _ command: MediaCommand) -> some View {
        Button { model.actions?.media(command, on: session) } label: {
            Image(systemName: symbol).frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The phone's ringer mode and Do Not Disturb as controls, and the button that rings it.
struct PhoneControls: View {
    @ObservedObject var model: AppModel
    let status: PhoneStatus

    static func symbol(_ ringer: PhoneStatus.Ringer) -> String {
        switch ringer {
        case .normal: return "bell"
        case .vibrate: return "iphone.radiowaves.left.and.right"
        case .silent: return "bell.slash"
        }
    }

    static func name(_ ringer: PhoneStatus.Ringer) -> String {
        switch ringer {
        case .normal: return "Sound"
        case .vibrate: return "Vibrate"
        case .silent: return "Silent"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Button { model.actions?.setDoNotDisturb(!status.isDoNotDisturbOn) } label: {
                Image(systemName: status.isDoNotDisturbOn ? "moon.fill" : "moon")
            }
            .buttonStyle(TileButtonStyle(isOn: status.isDoNotDisturbOn, tint: .indigo))
            .disabled(!status.canSetDoNotDisturb || model.pendingControl == .doNotDisturb)
            .help(status.canSetDoNotDisturb ? (status.isDoNotDisturbOn ? "Turn off Do Not Disturb on the phone" : "Turn on Do Not Disturb on the phone")
                  : "Do Not Disturb cannot be changed from here. Check Link to Windows in the phone's Do Not Disturb settings.")
            .accessibilityLabel("Do Not Disturb on phone")
            .accessibilityValue(status.isDoNotDisturbOn ? "On" : "Off")
            if status.canSetRinger {
                Menu {
                    Picker("Phone ringer", selection: Binding(get: { status.ringer }, set: { model.actions?.setRinger($0) })) {
                        ForEach([PhoneStatus.Ringer.normal, .vibrate, .silent], id: \.self) { ringer in
                            Label(PhoneControls.name(ringer), systemImage: PhoneControls.symbol(ringer)).tag(ringer)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: PhoneControls.symbol(status.ringer))
                }
                .menuStyle(.button).menuIndicator(.hidden)
                .buttonStyle(TileButtonStyle(isOn: status.ringer != .normal, tint: .orange))
                .disabled(model.pendingControl == .ringer)
                .help("Phone ringer: \(PhoneControls.name(status.ringer))")
                .accessibilityLabel("Phone ringer")
                .accessibilityValue(PhoneControls.name(status.ringer))
            }
            if model.canRingPhone { RingButton(model: model) }
            HotspotButton(model: model, status: status)
        }
    }
}

/// Rings the phone to find it; while it rings, counts down and offers to stop.
/// Switches the phone's hotspot on and joins it: one click, as Phone Link's entry in the
/// Wi-Fi list does it. A phone whose user has not agreed yet is asked first.
struct HotspotButton: View {
    @ObservedObject var model: AppModel
    let status: PhoneStatus

    private var joined: Bool {
        if case .joined = model.hotspotState { return true }
        return false
    }

    var body: some View {
        Button { if joined { model.actions?.leaveHotspot() } else { model.actions?.connectHotspot() } } label: {
            if model.hotspotState.isBusy { ProgressView().controlSize(.small) } else { Image(systemName: "personalhotspot") }
        }
        .buttonStyle(TileButtonStyle(isOn: joined, tint: .green))
        .disabled(model.hotspotState.isBusy)
        .help(joined ? "This Mac is on the phone's hotspot. Click to leave it and go back to the Mac's own network."
              : status.hotspot?.consent == false ? "Use the phone's hotspot. The phone will first ask you to allow it."
              : "Switch on the phone's hotspot and join it with this Mac")
        .accessibilityLabel("Phone hotspot")
        .accessibilityValue(joined ? "Joined" : "Off")
    }
}

struct RingButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let until = model.ringingUntil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                Button { model.actions?.stopRinging() } label: {
                    // One line, however narrow the tile: the seconds only, the stop symbol before them.
                    HStack(spacing: 3) {
                        Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold))
                        Text("\(left)").monospacedDigit()
                    }
                    .lineLimit(1).fixedSize()
                }
                .accessibilityLabel("Stop ringing the phone, \(left) seconds left")
            }
            .buttonStyle(TileButtonStyle(isOn: true, tint: .red))
            .help("The phone is ringing. Click to stop.")
        } else {
            Button { model.actions?.ringPhone() } label: {
                Image(systemName: "bell.and.waves.left.and.right")
            }
            .buttonStyle(TileButtonStyle())
            .help("Ring the phone at full volume for 20 seconds, even if it is on silent")
            .accessibilityLabel("Ring the phone to find it")
        }
    }
}

/// The phone's battery, signal and ringer state as a row of small symbols.
struct PhoneStatusStrip: View {
    let status: PhoneStatus
    /// Whether to show the ringer mode and Do Not Disturb; off where they have their own controls.
    var showsModes = true

    static func batterySymbol(_ percent: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    /// What VoiceOver and the tooltip say.
    static func summary(_ status: PhoneStatus) -> String {
        var parts: [String] = []
        if let percent = status.batteryPercent { parts.append("Battery \(percent)%" + (status.isCharging ? ", charging" : "") + (status.isPowerSaving ? ", power saving" : "")) }
        if status.airplaneMode {
            parts.append("Airplane mode")
        } else {
            if status.signalBarsMax > 0 { parts.append("\(status.networkOperator ?? "Mobile network") \(status.signalBars) of \(status.signalBarsMax) bars") }
            if status.wifiEnabled { parts.append("Wi-Fi on") }
        }
        switch status.ringer {
        case .silent: parts.append("Silent")
        case .vibrate: parts.append("Vibrate")
        case .normal: break
        }
        if status.isDoNotDisturbOn { parts.append("Do Not Disturb") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            if let percent = status.batteryPercent {
                HStack(spacing: 3) {
                    Image(systemName: PhoneStatusStrip.batterySymbol(percent, charging: status.isCharging))
                        .foregroundStyle(percent < 15 && !status.isCharging ? Color.red : Color.secondary)
                    Text("\(percent)%").monospacedDigit()
                }
            }
            if status.airplaneMode {
                Image(systemName: "airplane")
            } else {
                if status.signalBarsMax > 0 {
                    Image(systemName: "cellularbars", variableValue: Double(status.signalBars) / Double(status.signalBarsMax))
                }
                if status.wifiEnabled { Image(systemName: "wifi", variableValue: Double(min(status.wifiLevel, 4)) / 4) }
            }
            if showsModes {
                switch status.ringer {
                case .silent: Image(systemName: "bell.slash")
                case .vibrate: Image(systemName: "iphone.radiowaves.left.and.right")
                case .normal: EmptyView()
                }
                if status.isDoNotDisturbOn { Image(systemName: "moon.fill") }
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .help(PhoneStatusStrip.summary(status))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PhoneStatusStrip.summary(status))
    }
}

struct NotificationsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.sensitiveNotificationsHidden, !model.notificationAccessMissing { SensitiveNotificationsBanner(model: model) }
            list
        }
        .navigationTitle("Notifications")
        .toolbar {
            Button("Clear All") { model.actions?.clearAll() }.disabled(model.visibleNotifications.isEmpty)
            Toggle(isOn: $model.notificationsGrouped) { Label("Group by App", systemImage: "square.stack.3d.up") }
                .toggleStyle(.button)
                .help(model.notificationsGrouped ? "Show notifications by time" : "Show notifications in one stack per app")
            Button { choosingApps = true } label: { Label("Notification Settings", systemImage: "gearshape") }
                .help("Choose which apps show notifications on this Mac, and how")
        }
        .sheet(isPresented: $choosingApps) { AppNotificationSheet(model: model) }
    }

    @State private var choosingApps = false
    /// Two fingers to the left over a notification dismiss it.
    @StateObject private var swipe = NotificationSwipe()

    private var list: some View {
        Group {
            if model.notificationAccessMissing {
                EmptyState(title: "Notification access is off", symbol: "bell.slash.fill", tint: .orange,
                           message: "On the phone, open Link to Windows and allow it to read notifications.")
            } else if model.visibleNotifications.isEmpty {
                EmptyState(title: "No notifications", symbol: SidebarItem.notifications.tileSymbol, tint: SidebarItem.notifications.tint,
                           message: "Notifications from your phone appear here.")
            } else {
                // Not a List: on macOS 27 a row that arrives by itself into a List keeps the
                // list's default height and is cut off (seen at every start, when the phone
                // sends what it holds one by one). Here every row has the height it needs.
                ScrollView {
                    // Each app's notifications on a card of their own, or each notification on
                    // its own card when they are shown by time.
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.notificationsGrouped {
                            ForEach(model.notificationGroups) { group in
                                VStack(spacing: 0) {
                                    NotificationGroupHeader(model: model, group: group)
                                        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
                                    ForEach(group.notifications) { notification in
                                        row(notification, grouped: true, last: notification.id == group.notifications.last?.id)
                                    }
                                }
                                .card()
                            }
                        } else {
                            ForEach(model.visibleNotifications) { notification in
                                row(notification, grouped: false, last: true)
                                    .card()
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                }
                .background(Theme.canvas)
                .onPreferenceChange(SwipeFrames.self) { frames in Task { @MainActor in swipe.frames = frames } }
                .background(WindowReader { swipe.window = $0 })
                .onAppear {
                    swipe.onDismiss = { id in
                        if let notification = model.visibleNotifications.first(where: { $0.id == id }) { model.actions?.dismiss(notification) }
                    }
                    swipe.start()
                }
                .onDisappear { swipe.stop() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One notification with the line under it; the last of its card has room instead.
    private func row(_ notification: PhoneNotification, grouped: Bool, last: Bool) -> some View {
        VStack(spacing: 0) {
            SwipeToDismissRow(id: notification.id, swipe: swipe) {
                menu(NotificationRow(notification: notification, model: model, grouped: grouped)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Theme.card), for: notification)
            }
            if !last { Divider().padding(.leading, 60).padding(.trailing, 14) } else { Color.clear.frame(height: 6) }
        }
    }

    private func menu(_ row: some View, for notification: PhoneNotification) -> some View {
        row
            .contextMenu {
                Button("Dismiss") { model.actions?.dismiss(notification) }
                Button("Open on Phone") { model.actions?.openOnPhone(notification) }
                // The app itself, shown here as the Apps section shows it.
                if let app = model.apps[notification.packageName], !app.name.isEmpty {
                    Button("Open \(app.name) Here") { model.open(app: app.packageName) }
                        .disabled(!model.isConnected || !(model.screenState == .idle || model.screenState.isFailed))
                }
                Divider()
                Menu("Notifications from \(model.apps[notification.packageName]?.name ?? (notification.appName.isEmpty ? "This App" : notification.appName))") {
                    AppNotificationOptions(model: model, package: notification.packageName)
                    Divider()
                    Button("Stop Showing on This Mac") { model.actions?.setMuted(true, package: notification.packageName) }
                }
            }
    }
}

/// The phone has not answered for a long while. As Phone Link does then, linking it again
/// is offered: scanning the code resets a Link to Windows that has stopped answering.
struct RelinkOffer: View {
    @ObservedObject var model: AppModel
    let since: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The phone has not answered since \(since.formatted(date: Calendar.current.isDateInToday(since) ? .omitted : .abbreviated, time: .shortened)).")
                .font(.caption.weight(.semibold))
            Text("If Link to Windows on the phone says it is connected, it may be stuck. Scanning the code with the phone links it again and usually brings it back.")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(6).fixedSize(horizontal: false, vertical: true)
            Button("Show QR Code") { model.actions?.startPairing(manual: false) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The head of one app's stack: which app, how many, and a way to clear them all.
private struct NotificationGroupHeader: View {
    @ObservedObject var model: AppModel
    let group: AppModel.NotificationGroup
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon = model.apps[group.package]?.icon, let image = NSImage(data: icon) {
                Image(nsImage: image).resizable().interpolation(.high).frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous)).accessibilityHidden(true)
            }
            Text(group.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
            if group.notifications.count > 1 {
                Text("\(group.notifications.count)").font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 8)
            Button("Clear") { for notification in group.notifications { model.actions?.dismiss(notification) } }
                .buttonStyle(.borderless).font(.caption)
                .opacity(hovering ? 1 : 0)
                .help("Dismiss all of \(group.name)'s notifications, here and on the phone")
                .accessibilityLabel("Clear \(group.name)")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Explains that Android is holding some notifications back, and offers to ask for them.
struct SensitiveNotificationsBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.waitingForPhonePermission ? "iphone.gen3.radiowaves.left.and.right" : "eye.slash")
                .font(.title3).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                if model.waitingForPhonePermission {
                    Text("Check your phone").font(.headline)
                    Text("Link to Windows is asking for permission there. Choose Allow to show these notifications on your Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Certain notifications are hidden").font(.headline)
                    Text("Recent Android versions hide some notifications, such as ones with sign-in codes or private messages, until you allow Link to Windows to read them.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if model.waitingForPhonePermission {
                ProgressView().controlSize(.small)
                Button("Cancel") { model.actions?.cancelPermissionRequest() }
            } else {
                Button("Set Up") { model.actions?.setUpSensitiveNotifications() }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .top], 12)
    }
}

struct NotificationRow: View {
    let notification: PhoneNotification
    @ObservedObject var model: AppModel
    /// Under its app's heading, where the app need not be named again.
    var grouped = false
    @State private var reply = ""
    @State private var hovering = false

    private var appName: String {
        notification.appName.isEmpty ? (model.apps[notification.packageName]?.name ?? notification.packageName) : notification.appName
    }

    /// The two things every notification can do, out of the way until wanted; the time else.
    @ViewBuilder private var trailing: some View {
        Group {
            if hovering {
                Button { model.actions?.openOnPhone(notification) } label: { Image(systemName: "arrow.up.forward.app") }
                    .help("Open on phone").accessibilityLabel("Open on phone")
                Button { model.actions?.dismiss(notification) } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Dismiss").accessibilityLabel("Dismiss")
            } else {
                Text(Date(timeIntervalSince1970: TimeInterval(notification.postTime) / 1000), style: .time)
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.borderless).foregroundStyle(.secondary)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon = model.apps[notification.packageName]?.icon, let image = NSImage(data: icon) {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.badge").font(.system(size: 16)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary)
                }
            }
            .frame(width: 34, height: 34).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if grouped {
                    // Under the app's heading the first line is the notification's own.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let title = notification.title, !title.isEmpty {
                            Text(title).font(.body.weight(.semibold)).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        trailing
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(appName).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        trailing
                    }
                    .frame(height: 16)
                    if let title = notification.title, !title.isEmpty { Text(title).font(.body.weight(.semibold)).lineLimit(2) }
                }
                if !notification.displayBody.isEmpty { Text(notification.displayBody).foregroundStyle(.secondary).lineLimit(4) }
                if notification.replyAction != nil || !notification.buttonActions.isEmpty {
                    HStack(spacing: 8) {
                        if notification.replyAction != nil {
                            TextField("Reply", text: $reply)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                                .onSubmit(send)
                            Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                                .buttonStyle(.borderless).foregroundStyle(.tint)
                                .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                                .help("Send the reply").accessibilityLabel("Send the reply")
                        }
                        ForEach(notification.buttonActions, id: \.index) { action in
                            Button(action.name) { model.actions?.invoke(action, on: notification) }
                        }
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .padding(.top, 4)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        model.actions?.reply(text, to: notification)
        reply = ""
    }
}

/// Clipboard sharing: its switch, what it does, and what crossed lately. The list names the
/// kind and the time of each crossing, never what was copied.
struct ClipboardView: View {
    @ObservedObject var model: AppModel

    private var phoneName: String {
        switch model.phase {
        case .connected(let name), .connecting(let name): return name
        default: return "the phone"
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.clipboardSyncEnabled },
                                     set: { model.clipboardSyncEnabled = $0; model.actions?.setClipboardSync($0) })) {
                    HStack(spacing: 14) {
                        Image(systemName: "doc.on.clipboard.fill")
                            .font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background((model.clipboardSyncEnabled ? Color.teal : Color.gray).gradient, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clipboard Sharing").font(.title3.weight(.semibold))
                            Text("Copy on one device, paste on the other.").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("Works for text and for images of up to 1 MB; larger images are scaled down on the way to the phone. Copied content passes through Microsoft's servers, so avoid copying passwords while this is on.")
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Recent Activity") {
                if model.clipboardEvents.isEmpty {
                    Text(model.clipboardSyncEnabled ? "Nothing has been copied across since Phone Mac Link started." : "Clipboard sharing is off.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.clipboardEvents) { event in
                    HStack(spacing: 12) {
                        Image(systemName: event.kind == .image ? "photo" : "text.alignleft")
                            .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 28, height: 28)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: event.fromPhone ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                                    .symbolRenderingMode(.palette).foregroundStyle(.white, event.fromPhone ? Color.green : Color.blue)
                                    .font(.system(size: 13)).offset(x: 5, y: 4)
                            }
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(event.kind == .image ? "Image" : "Text") copied on \(event.fromPhone ? phoneName : "this Mac")")
                            Text(event.fromPhone ? "Ready to paste here" : "Ready to paste on \(phoneName)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(event.date.formatted(date: .omitted, time: .shortened)).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .formStyle(.grouped)
        // The whole page on one card, its groups inside as before.
        .scrollContentBackground(.hidden)
        .card()
        .pageInset()
        .navigationTitle("Clipboard")
    }
}

/// The phones linked to this Mac and the account they are linked through.
struct DevicesView: View {
    @ObservedObject var model: AppModel
    @State private var confirmSignOut = false
    @State private var removing: LinkedPhone?

    var body: some View {
        Form {
            if model.phones.isEmpty {
                Section { Text("No phone is linked.").foregroundStyle(.secondary) }
            }
            ForEach(model.phones) { phone in
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "smartphone")
                            .font(.system(size: 26, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background((phone.id == model.currentPhoneId ? Color.accentColor : Color.gray).gradient, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(phone.name).font(.title3.weight(.semibold))
                            Text(phone.model).font(.callout).foregroundStyle(.secondary)
                            HStack(spacing: 5) {
                                let current = phone.id == model.currentPhoneId
                                Circle().fill(phone.isOnline ? Color.green : current ? Color.orange : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                                Text(phone.isOnline ? "Connected" : current ? "Connecting…" : phone.isLinked ? "Linked, not in use" : "Not linked with this Mac")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        // One phone at a time, as in Phone Link: the others wait to be chosen.
                        if phone.isLinked, phone.id != model.currentPhoneId {
                            Button("Use This Phone") { model.actions?.selectPhone(phone) }
                        }
                        Button("Remove…", role: .destructive) { removing = phone }
                    }
                    .padding(.vertical, 4)
                    if phone.isOnline, let status = model.phoneStatus {
                        if let percent = status.batteryPercent {
                            LabeledContent("Battery") {
                                Label("\(percent)%" + (status.isCharging ? ", charging" : "") + (status.isPowerSaving ? ", power saving" : ""),
                                      systemImage: PhoneStatusStrip.batterySymbol(percent, charging: status.isCharging))
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        LabeledContent("Mobile network") {
                            if status.airplaneMode {
                                Label("Airplane mode", systemImage: "airplane").labelStyle(.titleAndIcon)
                            } else if status.signalBarsMax > 0 {
                                Label {
                                    Text(status.networkOperator ?? "\(status.signalBars) of \(status.signalBarsMax) bars")
                                } icon: {
                                    Image(systemName: "cellularbars", variableValue: Double(status.signalBars) / Double(status.signalBarsMax))
                                }
                                .labelStyle(.titleAndIcon)
                            } else {
                                Text("No service")
                            }
                        }
                        LabeledContent("Wi-Fi", value: status.airplaneMode ? "Off" : status.wifiEnabled ? "On" : "Off")
                        LabeledContent("Sound") {
                            Label(PhoneControls.name(status.ringer) + (status.isDoNotDisturbOn ? ", Do Not Disturb" : ""),
                                  systemImage: status.isDoNotDisturbOn ? "moon.fill" : PhoneControls.symbol(status.ringer))
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
            Section {
                Button("Link Another Phone…") { model.actions?.startPairing(manual: false) }
            } footer: {
                Text("The phone needs the Link to Windows app, signed in to the same Microsoft account. With several phones linked, this Mac talks to one at a time; choose it here or from the phone's name at the top of the sidebar.")
                    .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Microsoft Account") {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 34)).foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.accountName ?? "Signed in")
                        Text("Phones are linked through this account.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign Out…", role: .destructive) { confirmSignOut = true }
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        // The whole page on one card, its groups inside as before.
        .scrollContentBackground(.hidden)
        .card()
        .pageInset()
        .navigationTitle("Devices")
        .confirmationDialog("Remove \(removing?.name ?? "this phone")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { phone in
            Button("Remove", role: .destructive) { model.actions?.removePhone(phone) }
        } message: { _ in
            Text("This Mac stops receiving the phone's notifications, messages and files. You can link it again at any time.")
        }
        .confirmationDialog("Sign out of your Microsoft account?", isPresented: $confirmSignOut) {
            Button("Sign Out", role: .destructive) { model.actions?.signOut() }
        } message: {
            Text("This Mac will stop receiving notifications and clipboard content from your phone. The phone stays linked to your account.")
        }
    }
}

/// The app's own entries in the menu bar: the sections by number in View, and a Phone menu
/// for what is otherwise a click away in the window.
struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    private var mirroring: Bool {
        switch model.screenState {
        case .idle, .failed: return false
        default: return true
        }
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(model.sidebarCollapsed ? "Show Section Names" : "Show Symbols Only") {
                withAnimation(SidebarPanel.motion) { model.sidebarCollapsed.toggle() }
            }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(!model.showsMainInterface)
            Divider()
            ForEach(SidebarItem.allCases.filter { $0 != .calls || model.showsCalls }) { item in
                if let number = item.shortcutNumber {
                    Button(item.rawValue) { model.show(item) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                } else {
                    Button(item.rawValue) { model.show(item) }
                }
            }
            .disabled(!model.showsMainInterface)
            Divider()
        }
        CommandMenu("Phone") {
            if mirroring {
                Button("Stop Showing Phone Screen") { model.actions?.stopScreen() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            } else {
                Button("Show Phone Screen") {
                    model.actions?.startScreen(app: nil)
                    if !model.screenInOwnWindow { model.show(.screen) }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.isConnected)
            }
            Toggle("Phone Screen in Its Own Window", isOn: $model.screenInOwnWindow)
            Button("Save Screenshot of Phone Screen") { model.saveScreenshot() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model.screenState != .live)
            Button("Copy Screenshot of Phone Screen") { model.copyScreenshot() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(model.screenState != .live)
            Divider()
            if model.ringingUntil != nil {
                Button("Stop Ringing Phone") { model.actions?.stopRinging() }
            } else {
                Button("Ring Phone") { model.actions?.ringPhone() }.disabled(!model.canRingPhone)
            }
            if let status = model.phoneStatus, status.canSetDoNotDisturb {
                Toggle("Do Not Disturb on Phone", isOn: Binding(get: { status.isDoNotDisturbOn }, set: { model.actions?.setDoNotDisturb($0) }))
            }
            if case .joined = model.hotspotState {
                Button("Leave Phone's Hotspot") { model.actions?.leaveHotspot() }
            } else {
                Button("Connect to Phone's Hotspot") { model.actions?.connectHotspot() }
                    .disabled(!model.isConnected || model.hotspotState.isBusy)
            }
            Divider()
            Button("Send Files to Phone…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.canChooseDirectories = false
                panel.prompt = "Send"
                guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
                model.actions?.sendFiles(panel.urls)
                model.show(.files)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!model.isConnected || model.fileTransferStatus != nil)
        }
    }
}
