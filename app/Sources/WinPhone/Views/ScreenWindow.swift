import AppKit
import Combine
import SwiftUI
import WinPhoneCore

/// Sizes for the screen's own window: the picture in its shape with a margin round it, a bar
/// of buttons under it.
enum ScreenWindowLayout {
    static let barHeight: CGFloat = 44
    /// Between the picture and the window's edges, so the picture can show its rounded corners.
    static let margin: CGFloat = 10
    static let minimumWidth: CGFloat = 240

    /// The picture's part of a window's content.
    static func picture(in content: CGSize) -> CGSize {
        CGSize(width: content.width - 2 * margin, height: content.height - margin - barHeight)
    }

    /// The content for a width.
    static func content(forWidth width: CGFloat, picture: CGSize) -> CGSize {
        let width = max(width, minimumWidth)
        let shown = width - 2 * margin
        return CGSize(width: width, height: (shown * picture.height / max(1, picture.width)).rounded() + margin + barHeight)
    }

    /// The content for a height: for a drag at the bottom edge.
    static func content(forHeight height: CGFloat, picture: CGSize) -> CGSize {
        let shown = height - margin - barHeight
        return content(forWidth: (shown * picture.width / max(1, picture.height)).rounded() + 2 * margin, picture: picture)
    }

    /// The content as large as wanted and no larger than fits the screen.
    static func fitted(_ wanted: CGSize, picture: CGSize, visible: CGSize) -> CGSize {
        var size = content(forWidth: min(wanted.width, visible.width * 0.95).rounded(), picture: picture)
        if size.height > visible.height * 0.95 { size = content(forHeight: (visible.height * 0.95).rounded(), picture: picture) }
        return size
    }

    /// The first size on a screen: most of its height, like a phone held up beside the work.
    static func initial(picture: CGSize, visible: CGSize) -> CGSize {
        fitted(content(forHeight: min(visible.height * 0.8, 860), picture: picture), picture: picture, visible: visible)
    }

    /// After the picture changed its shape: its long side stays as long as it was.
    static func reshaped(from old: CGSize, picture: CGSize, visible: CGSize) -> CGSize {
        let shown = self.picture(in: old)
        let long = max(shown.width, shown.height)
        let width = picture.width >= picture.height ? long : long * picture.width / max(1, picture.height)
        return fitted(content(forWidth: width.rounded() + 2 * margin, picture: picture), picture: picture, visible: visible)
    }
}

/// What the screen's own window holds.
struct ScreenWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.screenState == .live {
                    LivePicture(model: model, cornerRadius: 16)
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                } else {
                    let waiting = model.screenState == .waitingForPermission
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(waiting ? "Check Your Phone" : "Connecting…").font(.headline)
                        Text(waiting ? "Link to Windows is asking whether it may show the screen. Allow it on the phone." : "Reaching the phone.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Cancel") { model.actions?.stopScreen() }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .card()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding([.horizontal, .top], ScreenWindowLayout.margin)
            bar
        }
        .background(Theme.canvas.ignoresSafeArea())
    }

    /// The phone's own keys in a floating capsule in the middle, as on the phone; the window's
    /// own buttons either side of it.
    private var bar: some View {
        ZStack {
            HStack(spacing: 2) {
                if model.screenState == .live {
                    Menu {
                        Button("Save to Downloads") { model.saveScreenshot() }
                        Button("Copy") { model.copyScreenshot() }
                    } label: {
                        Label("Screenshot", systemImage: "camera")
                    } primaryAction: {
                        model.saveScreenshot()
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Take a picture of the phone's screen")
                }
                Toggle(isOn: $model.screenOnTop) { Label("Keep on Top", systemImage: model.screenOnTop ? "pin.fill" : "pin") }
                    .toggleStyle(.button)
                    .help("Keep this window above the others")
                Spacer(minLength: 4)
                Button { model.screenInOwnWindow = false } label: { Label("Show in Main Window", systemImage: "rectangle.inset.filled.and.cursorarrow") }
                    .help("Show the screen in the main window again")
            }
            if model.screenState == .live {
                HStack(spacing: 14) { ScreenNavigation(model: model) }
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(Theme.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.08), radius: 5, y: 1)
            }
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.large)
        .padding(.horizontal, ScreenWindowLayout.margin + 2)
        .frame(height: ScreenWindowLayout.barHeight)
    }
}

/// Shows the phone's screen in a window of its own while the user wants it so and there is
/// something to show. Closing the window ends the mirroring, as closing a phone's window does
/// in Phone Link; the button in its bar brings the picture back into the main window instead.
@MainActor
final class ScreenWindowController: NSObject, NSWindowDelegate {
    static var shared: ScreenWindowController?
    static let frameKey = "screen.windowOrigin"

    private let model: AppModel
    private(set) var window: NSWindow?
    private var watching: Set<AnyCancellable> = []
    /// The window is being closed from here, not by its user.
    private var closing = false
    private var shape = CGSize.zero

    init(model: AppModel) {
        self.model = model
        super.init()
        // Published values arrive before they are set: each is looked at a turn later.
        model.$screenInOwnWindow.combineLatest(model.$screenState).receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }.store(in: &watching)
        model.$screenVideoSize.combineLatest(model.$screenTurns).receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.reshape() }
        }.store(in: &watching)
        model.$screenOnTop.combineLatest(model.$screenApp).receive(on: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.dress() }
        }.store(in: &watching)
    }

    /// Whether there is something for the window to show.
    static func wanted(ownWindow: Bool, state: AppModel.ScreenState) -> Bool {
        guard ownWindow else { return false }
        switch state {
        case .connecting, .waitingForPermission, .live: return true
        case .idle, .failed: return false
        }
    }

    /// The user closed the window while the mirroring was still winding down: it is not
    /// opened again for the same session behind their back.
    private var closedByUser = false

    func bringForward() {
        if window == nil {
            closedByUser = false
            update()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func update() {
        let wanted = ScreenWindowController.wanted(ownWindow: model.screenInOwnWindow, state: model.screenState)
        if !wanted { closedByUser = false }
        if wanted, window == nil, !closedByUser {
            open()
        } else if !wanted, let window {
            closing = true
            window.close()
            closing = false
            self.window = nil
            // The picture goes on in the main window, or the mirroring failed and the reason
            // is told there: either way that is where to look now.
            if model.screenState != .idle { model.show(.screen) }
        }
    }

    private var visibleSize: CGSize { (window?.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 860) }

    private func open() {
        shape = model.screenShownSize
        let content = ScreenWindowLayout.initial(picture: shape, visible: visibleSize)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: content), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        // The title bar in the backdrop's colour, without a line under it: one surface round
        // the picture, as the main window's.
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.canvasColor
        window.delegate = self
        window.contentView = NSHostingView(rootView: ScreenWindowView(model: model))
        window.contentMinSize = ScreenWindowLayout.content(forWidth: ScreenWindowLayout.minimumWidth, picture: shape)
        window.collectionBehavior = [.fullScreenAuxiliary]
        if let saved = UserDefaults.standard.string(forKey: ScreenWindowController.frameKey) {
            let origin = NSPointFromString(saved), frame = NSRect(origin: origin, size: window.frame.size)
            // Where it was left, if enough of that is still on a screen.
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersection(frame).width >= 120 && $0.visibleFrame.intersection(frame).height >= 120 }) {
                window.setFrameOrigin(origin)
            } else {
                window.center()
            }
        } else {
            window.center()
        }
        self.window = window
        dress()
        window.makeKeyAndOrderFront(nil)
    }

    private func dress() {
        guard let window else { return }
        window.title = model.screenTitle
        window.level = model.screenOnTop ? .floating : .normal
    }

    /// The picture changed its shape: the phone was turned, or the stream began in another
    /// size than expected. The window follows, its top-left corner where it was.
    private func reshape() {
        guard let window, model.screenShownSize != shape else { return }
        shape = model.screenShownSize
        let old = window.contentRect(forFrameRect: window.frame).size
        let content = ScreenWindowLayout.reshaped(from: old, picture: shape, visible: visibleSize)
        window.contentMinSize = ScreenWindowLayout.content(forWidth: ScreenWindowLayout.minimumWidth, picture: shape)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible = window.screen?.visibleFrame {
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
            frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        }
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: NSWindowDelegate

    /// The window keeps the picture's shape whichever edge is dragged.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let current = sender.contentRect(forFrameRect: sender.frame).size
        let picture = model.screenShownSize
        let content = abs(proposed.width - current.width) < 0.5 ? ScreenWindowLayout.content(forHeight: proposed.height, picture: picture)
            : ScreenWindowLayout.content(forWidth: proposed.width, picture: picture)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    func windowDidMove(_ notification: Notification) {
        guard let window, window.isVisible else { return }
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: ScreenWindowController.frameKey)
    }

    func windowWillClose(_ notification: Notification) {
        guard !closing else { return }
        // Closed by its user: that ends the mirroring.
        window = nil
        closedByUser = true
        model.actions?.stopScreen()
    }
}
