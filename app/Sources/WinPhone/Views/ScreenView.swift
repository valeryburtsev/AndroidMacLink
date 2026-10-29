import AppKit
import Carbon.HIToolbox
import SwiftUI
import WinPhoneCore

/// The phone's screen, or one of its apps, live, with the pointer and the keyboard acting on it.
struct ScreenView: View {
    @ObservedObject var model: AppModel

    /// What is shown: the app's name, or "Phone Screen".
    private var title: String { model.screenTitle }

    var body: some View {
        Group {
            switch model.screenState {
            case .idle:
                OnboardingPage(symbol: "smartphone", title: "Phone Screen",
                               message: "See and use your phone's screen here, with the mouse and the keyboard.") {
                    VStack(spacing: 16) {
                        Button("Show Phone Screen") { model.actions?.startScreen(app: nil) }
                            .buttonStyle(.borderedProminent).controlSize(.extraLarge)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.isConnected)
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Play the phone's sound on this Mac", isOn: $model.screenSound)
                            Toggle("Show in a window of its own", isOn: $model.screenInOwnWindow)
                        }
                        .toggleStyle(.checkbox)
                        Text("The phone asks you to allow it the first time. Works best with both devices on the same Wi-Fi; away from it the picture comes over the internet and uses the phone's mobile data.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(minWidth: 300, maxWidth: 380).fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .connecting where !model.screenInOwnWindow:
                ScreenProgress(model: model)
            case .waitingForPermission where !model.screenInOwnWindow:
                ScreenProgress(model: model)
            case .live where !model.screenInOwnWindow:
                LivePicture(model: model, cornerRadius: 18)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator))
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                    .padding(16)
            case .connecting, .waitingForPermission, .live:
                // The picture has a window of its own.
                OnboardingPage(symbol: "macwindow.on.rectangle", title: "In Its Own Window",
                               message: "\(title) is shown in a window of its own.") {
                    VStack(spacing: 12) {
                        Button("Show It Here") { model.screenInOwnWindow = false }
                            .buttonStyle(.borderedProminent).controlSize(.extraLarge)
                        Button("Bring Window to Front") { ScreenWindowController.shared?.bringForward() }
                        Button("Stop") { model.actions?.stopScreen() }
                    }
                }
            case .failed(let reason):
                OnboardingPage(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "The Screen Could Not Be Shown", message: reason) {
                    Button("Try Again") { model.actions?.startScreen(app: model.screenApp) }
                        .buttonStyle(.borderedProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sectionTitle(title)
        .toolbar {
            // The phone's own three buttons, in its order. Home and Recents belong to the
            // whole screen; a single app has only Back, which on its first page closes it.
            if model.screenState == .live, !model.screenInOwnWindow {
                ToolbarItemGroup(placement: .principal) {
                    ScreenNavigation(model: model)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.screenInOwnWindow = true } label: { Label("Own Window", systemImage: "macwindow.on.rectangle") }
                        .help("Show the phone's screen in a window of its own")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Save to Downloads") { model.saveScreenshot() }
                        Button("Copy") { model.copyScreenshot() }
                    } label: {
                        Label("Screenshot", systemImage: "camera")
                    } primaryAction: {
                        model.saveScreenshot()
                    }
                    .help("Take a picture of the phone's screen")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { model.actions?.stopScreen() } label: { Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                        .help("Stop showing the phone's screen")
                }
            }
        }
    }
}

/// The phone's own navigation: Recents and Home for the whole screen, Back for everything.
struct ScreenNavigation: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.screenApp == nil {
            Button { model.actions?.screenGesture(.recents) } label: { Label("Recents", systemImage: "square.on.square") }
                .help("Show the phone's recent apps (a swipe up from the bottom, held)")
            Button { model.actions?.screenGesture(.home) } label: { Label("Home", systemImage: "circle") }
                .help("Go to the phone's home screen (a swipe up from the bottom)")
        }
        Button {
            model.actions?.screenKey(NanoKey.back, pressed: true)
            model.actions?.screenKey(NanoKey.back, pressed: false)
        } label: { Label("Back", systemImage: "chevron.backward") }
            .help("Back")
    }
}

/// While the phone is being reached, or is asking its user.
struct ScreenProgress: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let waiting = model.screenState == .waitingForPermission
        OnboardingPage(symbol: waiting ? "hand.tap.fill" : "smartphone", title: waiting ? "Check Your Phone" : "Connecting…",
                       message: waiting ? "Link to Windows is asking whether it may show the screen. Look for its notification on the phone and allow it."
                           : "Reaching the phone on your network.") {
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Button("Cancel") { model.actions?.stopScreen() }
            }
        }
    }
}

/// The live picture with what lies over it: the note about a locked phone, the place to drop
/// files, the word about a screenshot. In the main window and in the screen's own.
struct LivePicture: View {
    @ObservedObject var model: AppModel
    var cornerRadius: CGFloat
    @State private var dropTargeted = false

    private var canSendFiles: Bool { model.isConnected && model.fileTransferStatus == nil }

    var body: some View {
        MirrorSurface(model: model)
            .aspectRatio(model.screenShownSize.width / max(1, model.screenShownSize.height), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if model.screenLocked {
                    // A locked phone may send no picture; keys do reach it. A click beside the
                    // card goes to the picture, which wakes the phone.
                    UnlockCard(model: model).padding(.horizontal, 16)
                } else if model.screenProtected {
                    ProtectedScreenNote().padding(.horizontal, 16)
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Color.accentColor.opacity(0.25))
                        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                        .overlay(Label("Send to Phone", systemImage: "arrow.up.circle.fill").font(.title2.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8).background(.regularMaterial, in: Capsule()))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if let note = model.screenshotNote {
                    Button {
                        if let file = note.file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    } label: {
                        Label(note.text, systemImage: note.file == nil ? "camera" : "checkmark.circle.fill")
                            .font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain).padding(.bottom, 12)
                    .help(note.file == nil ? "" : "Show in Finder")
                    .transition(.opacity)
                }
            }
            // Files dropped on the picture go to the phone, as from the Files page.
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                guard canSendFiles, !files.isEmpty else { return false }
                model.actions?.sendFiles(files)
                return true
            } isTargeted: { dropTargeted = $0 && canSendFiles }
    }
}

extension AppModel {
    /// What is shown: the app's name, or "Phone Screen".
    var screenTitle: String {
        guard screenState != .idle, let package = screenApp else { return "Phone Screen" }
        return apps[package]?.name ?? "Phone Screen"
    }

    /// What the picture shows right now, turned as it is shown.
    private func screenshot() -> Data? {
        guard let image = screenVideo.currentImage(), let turned = ScreenShots.turned(image, turns: screenTurns) else { return nil }
        return ScreenShots.png(turned)
    }

    private func say(_ note: ScreenshotNote) {
        screenshotNote = note
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.screenshotNote == note { self?.screenshotNote = nil }
        }
    }

    func saveScreenshot() {
        guard let data = screenshot() else { return say(ScreenshotNote(text: "No picture to take yet")) }
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        do {
            say(ScreenshotNote(text: "Saved to Downloads", file: try ScreenShots.save(data, in: folder)))
        } catch {
            say(ScreenshotNote(text: "The screenshot could not be saved"))
        }
    }

    func copyScreenshot() {
        guard let data = screenshot() else { return say(ScreenshotNote(text: "No picture to take yet")) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        say(ScreenshotNote(text: "Copied"))
    }
}

/// The phone's apps: one opens on this Mac as the phone shows it, apart from the phone's own screen.
struct AppsView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""

    /// One group of apps under a heading; no heading while searching.
    struct Shelf: Identifiable, Equatable {
        var title: String?
        var apps: [PhoneApp]
        var id: String { title ?? "" }
    }

    /// The apps as shown: favorites first, then the ones opened last, then all by name.
    /// A search shows only what matches, in one group.
    static func shelves(_ apps: [PhoneApp], favorites: [String], recent: [String], search: String) -> [Shelf] {
        let named = apps.filter { !$0.name.isEmpty }
        let all = named.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard query.isEmpty else {
            let found = all.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return found.isEmpty ? [] : [Shelf(title: nil, apps: found)]
        }
        let byPackage = Dictionary(named.map { ($0.packageName, $0) }, uniquingKeysWith: { first, _ in first })
        var shelves: [Shelf] = []
        let liked = all.filter { favorites.contains($0.packageName) }
        if !liked.isEmpty { shelves.append(Shelf(title: "Favorites", apps: liked)) }
        // Newest first, without what is already among the favorites or gone from the phone.
        let lately = recent.filter { !favorites.contains($0) }.compactMap { byPackage[$0] }
        if !lately.isEmpty { shelves.append(Shelf(title: "Recently Opened", apps: Array(lately.prefix(AppModel.recentAppsShown)))) }
        if !all.isEmpty { shelves.append(Shelf(title: shelves.isEmpty ? nil : "All Apps", apps: all)) }
        return shelves
    }

    private var shelves: [Shelf] {
        AppsView.shelves(Array(model.apps.values), favorites: model.favoriteApps, recent: model.recentApps, search: search)
    }

    private var canOpen: Bool { model.isConnected && (model.screenState == .idle || model.screenState.isFailed) }

    var body: some View {
        Group {
            if model.apps.isEmpty {
                EmptyState(title: "No Apps Yet", symbol: "square.grid.2x2", tint: SidebarItem.apps.tint, message: "The phone's apps appear here once it has connected.")
            } else {
                ScrollView {
                    // Each shelf on a card of its own.
                    VStack(spacing: 12) {
                        ForEach(shelves) { shelf in
                            VStack(alignment: .leading, spacing: 10) {
                                if let title = shelf.title {
                                    Text(title).font(.headline).padding(.leading, 4)
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 8)], alignment: .leading, spacing: 14) {
                                    // An app may stand on two shelves: each place needs a name of its own.
                                    ForEach(shelf.apps.map { (key: shelf.id + "/" + $0.packageName, app: $0) }, id: \.key) { entry in cell(entry.app) }
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .card()
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 16)
                }
                .overlay { if shelves.isEmpty { ContentUnavailableView.search(text: search) } }
            }
        }
        .navigationTitle("Apps")
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
    }

    private func cell(_ app: PhoneApp) -> some View {
        let liked = model.favoriteApps.contains(app.packageName)
        return Button { model.open(app: app.packageName) } label: {
            VStack(spacing: 6) {
                Group {
                    if let icon = app.icon, let image = NSImage(data: icon) {
                        Image(nsImage: image).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "app.dashed").font(.system(size: 30)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(app.name).font(.caption).lineLimit(2, reservesSpace: true).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .help("Open \(app.name) here")
        .contextMenu {
            Button("Open") { model.open(app: app.packageName) }.disabled(!canOpen)
            Button(liked ? "Remove from Favorites" : "Add to Favorites") { model.setFavorite(app.packageName, !liked) }
        }
    }
}

extension AppModel.ScreenState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// The picture, with the pointer and the keyboard over it.
struct MirrorSurface: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> MirrorNSView {
        let view = MirrorNSView()
        view.attach(model.screenVideo.layer)
        return view
    }

    func updateNSView(_ view: MirrorNSView, context: Context) {
        view.inputSize = model.screenInputSize
        view.turns = model.screenTurns
        view.onPointer = { [weak model] in model?.actions?.screenPointer($0) }
        view.onKey = { [weak model] in model?.actions?.screenKey($0, pressed: $1) }
    }
}

/// Draws the video layer and turns mouse and keyboard events into input for the phone.
final class MirrorNSView: NSView {
    var inputSize: CGSize?
    /// Quarter turns against the clock the picture is shown with.
    var turns = 0 { didSet { if turns != oldValue { needsLayout = true } } }
    var onPointer: ((ScreenPointer) -> Void)?
    var onKey: ((_ usage: UInt8, _ pressed: Bool) -> Void)?
    private var video: CALayer?
    private var state = ScreenPointer()
    private var heldModifiers: Set<Int> = []
    private var lastHover = Date.distantPast
    private var tracking: NSTrackingArea?
    private var watching: NSObjectProtocol?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The picture takes the keyboard as soon as it is on screen: what is typed then is meant
    /// for the phone, a PIN for its lock not least.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.firstResponder !== self else { return }
            window.makeFirstResponder(self)
        }
    }

    func attach(_ layer: CALayer) {
        wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        layer.removeFromSuperlayer()
        self.layer?.addSublayer(layer)
        video = layer
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // The picture may have moved on to another view, the screen's own window or the main one.
        guard video?.superlayer === layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The layer keeps the picture's own shape and is turned as a whole; turned by a
        // quarter, it fills the view again.
        video?.setAffineTransform(.identity)
        video?.bounds = ScreenTurn.layerBounds(in: bounds.size, turns: turns)
        video?.position = CGPoint(x: bounds.midX, y: bounds.midY)
        video?.setAffineTransform(CGAffineTransform(rotationAngle: ScreenTurn.angle(turns: turns)))
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: Pointer

    /// Reports where the pointer is, with its buttons and what the wheel did.
    private func report(_ event: NSEvent, wheelX: Int = 0, wheelY: Int = 0) {
        guard let inputSize, bounds.width > 0, bounds.height > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let x = min(max(point.x / bounds.width, 0), 1), y = min(max(point.y / bounds.height, 0), 1)
        state.x = Int(x * (inputSize.width - 1))
        state.y = Int(y * (inputSize.height - 1))
        state.wheelX = wheelX
        state.wheelY = wheelY
        onPointer?(state)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        state.left = true
        report(event)
    }

    override func mouseDragged(with event: NSEvent) { report(event) }

    override func mouseUp(with event: NSEvent) {
        state.left = false
        report(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        state.right = true
        report(event)
    }

    override func rightMouseDragged(with event: NSEvent) { report(event) }

    override func rightMouseUp(with event: NSEvent) {
        state.right = false
        report(event)
    }

    override func otherMouseDown(with event: NSEvent) {
        state.middle = true
        report(event)
    }

    override func otherMouseDragged(with event: NSEvent) { report(event) }

    override func otherMouseUp(with event: NSEvent) {
        state.middle = false
        report(event)
    }

    override func mouseMoved(with event: NSEvent) {
        // The phone shows where the pointer is; thirty reports a second are plenty for that.
        let now = Date()
        guard now.timeIntervalSince(lastHover) >= 1.0 / 30 else { return }
        lastHover = now
        report(event)
    }

    override func scrollWheel(with event: NSEvent) {
        // In the units Windows counts a wheel in: 120 to a notch. A trackpad gives points.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 4 : 120
        let x = Int(event.scrollingDeltaX * scale), y = Int(event.scrollingDeltaY * scale)
        guard x != 0 || y != 0 else { return }
        report(event, wheelX: x, wheelY: y)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        // Held keys repeat on the phone by themselves; only the press itself is sent.
        guard !event.isARepeat, let usage = KeyCodes.usage[Int(event.keyCode)] else { return }
        onKey?(usage, true)
    }

    override func keyUp(with event: NSEvent) {
        guard let usage = KeyCodes.usage[Int(event.keyCode)] else { return }
        onKey?(usage, false)
    }

    /// Each modifier key's own bit in an event's flags: left and right apart.
    static let modifierBits: [Int: UInt] = [
        kVK_Control: 0x1, kVK_Shift: 0x2, kVK_RightShift: 0x4, kVK_Command: 0x8, kVK_RightCommand: 0x10,
        kVK_Option: 0x20, kVK_RightOption: 0x40, kVK_RightControl: 0x2000,
    ]

    /// What a "modifiers changed" event means for the key it names: went down, went up, or
    /// nothing new. The event's own flags say whether the key is down, so a release that
    /// happened while another window had the keyboard cannot turn the count around.
    static func modifierChange(keyCode: Int, flags: UInt, held: Set<Int>) -> Bool? {
        guard let bit = modifierBits[keyCode] else {
            // A key without a bit of its own, Caps Lock: each event is a press.
            return held.contains(keyCode) ? false : true
        }
        let down = flags & bit != 0
        return down == held.contains(keyCode) ? nil : down
    }

    override func flagsChanged(with event: NSEvent) {
        let code = Int(event.keyCode)
        guard let usage = KeyCodes.usage[code], let down = MirrorNSView.modifierChange(keyCode: code, flags: event.modifierFlags.rawValue, held: heldModifiers) else { return }
        if MirrorNSView.modifierBits[code] == nil {
            // Caps Lock: pressed and let go in one.
            onKey?(usage, true)
            onKey?(usage, false)
            return
        }
        if down { heldModifiers.insert(code) } else { heldModifiers.remove(code) }
        onKey?(usage, down)
    }

    /// Nothing stays held on the phone when the keyboard goes elsewhere.
    private func releaseModifiers() {
        for code in heldModifiers { if let usage = KeyCodes.usage[code] { onKey?(usage, false) } }
        heldModifiers.removeAll()
    }

    /// Shortcuts that stay with the Mac although the phone's picture has the keyboard: the
    /// system's own, the sections by number, and this app's menu commands.
    static func staysWithMac(_ characters: String, flags: NSEvent.ModifierFlags) -> Bool {
        let key = characters.lowercased()
        if flags.contains(.option) { return true }
        if flags.contains(.shift) { return ["p", "o"].contains(key) }
        return ["q", "w", "h", ",", "m", "`", "1", "2", "3", "4", "5", "6", "7", "8", "9"].contains(key)
    }

    /// Command shortcuts go to the phone while its screen has the keyboard, not to the menus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown, event.modifierFlags.contains(.command),
              let usage = KeyCodes.usage[Int(event.keyCode)] else { return super.performKeyEquivalent(with: event) }
        // Quit, close, hide, settings, the sections and this app's own commands stay with the Mac.
        if MirrorNSView.staysWithMac(event.charactersIgnoringModifiers ?? "", flags: event.modifierFlags) { return super.performKeyEquivalent(with: event) }
        onKey?(usage, true)
        onKey?(usage, false)
        return true
    }

    override func resignFirstResponder() -> Bool {
        releaseModifiers()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Leaving its window, or the window losing the keyboard to another: the same.
        releaseModifiers()
        if let watching { NotificationCenter.default.removeObserver(watching) }
        watching = nil
        guard let newWindow else { return }
        watching = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: newWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseModifiers() }
        }
    }
}

/// Over a locked phone's picture: a field for its PIN or password, typed to the phone as keys
/// with Return after them. What is typed is sent once and kept nowhere.
struct UnlockCard: View {
    @ObservedObject var model: AppModel
    @State private var secret = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    /// Characters a US keyboard cannot type, which the phone would not receive.
    private var untypable: Bool { secret.contains { KeyCodes.typing($0) == nil } }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.accentColor.gradient, in: Circle())
                .accessibilityHidden(true)
            VStack(spacing: 3) {
                Text("The phone is locked").font(.headline)
                Text("Type its PIN or password to unlock it.").font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 6) {
                SecureField("PIN or password", text: $secret)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(unlock)
                    .disabled(sending)
                Button(action: unlock) {
                    Image(systemName: sending ? "ellipsis.circle.fill" : "arrow.right.circle.fill").font(.system(size: 22))
                        .foregroundStyle(secret.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                }
                .buttonStyle(.plain)
                .disabled(secret.isEmpty || sending)
                .help("Unlock")
                .accessibilityLabel("Unlock")
            }
            .padding(.leading, 12).padding(.trailing, 5).padding(.vertical, 5)
            .background(.white.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.35 : 0.15), lineWidth: 1))
            if untypable {
                Text("Some of these characters cannot be typed on the phone from here.").font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Button("Wake the Phone") { model.actions?.wakeScreen() }
                .buttonStyle(.link).font(.callout)
        }
        .padding(20)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        // Light on dark, whatever the Mac's appearance: it lies over a black picture.
        .environment(\.colorScheme, .dark)
        .onAppear { focused = true }
    }

    /// Wakes the phone so that its unlock prompt is up, then types what was entered and Return.
    private func unlock() {
        let typed = secret
        guard !typed.isEmpty, !sending else { return }
        secret = ""
        sending = true
        Task { @MainActor in
            model.actions?.wakeScreen()
            try? await Task.sleep(for: .milliseconds(600))
            for character in typed {
                guard let key = KeyCodes.typing(character) else { continue }
                if key.shift { model.actions?.screenKey(0xE1, pressed: true) }
                model.actions?.screenKey(key.usage, pressed: true)
                model.actions?.screenKey(key.usage, pressed: false)
                if key.shift { model.actions?.screenKey(0xE1, pressed: false) }
                try? await Task.sleep(for: .milliseconds(40))
            }
            model.actions?.screenKey(0x28, pressed: true)
            model.actions?.screenKey(0x28, pressed: false)
            try? await Task.sleep(for: .seconds(2))
            sending = false
        }
    }
}

/// Over the picture of an app that protects its screen, such as a bank's: why it is black.
/// Clicks go through to the picture, and the phone's keys below still work.
struct ProtectedScreenNote: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.orange.gradient, in: Circle())
                .accessibilityHidden(true)
            Text("This app protects its screen").font(.headline).multilineTextAlignment(.center)
            Text("It shows only on the phone, as with screenshots and screen recording there. Go back or home to use other apps here.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
