import AppKit
import Combine
import SwiftUI
import WinPhoneCore

/// The call in progress on the phone: who it is with, how it stands, and what can be done.
/// Shown at the top of the Calls section and in a panel of its own while the call lasts.
struct LiveCallBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let call = model.liveCall {
            HStack(spacing: 12) {
                ContactAvatar(name: model.title(for: call), photo: call.number.flatMap { model.contacts.contact(for: $0)?.photo }, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title(for: call)).font(.headline).lineLimit(1)
                    status(call).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 12)
                if call.phase == .incoming {
                    CallButton(symbol: "phone.down.fill", tint: .red, label: "Decline") { model.actions?.endCall() }
                    CallButton(symbol: "phone.fill", tint: .green, label: "Answer") { model.actions?.answerCall() }
                } else {
                    if model.callCanMute, call.phase == .active {
                        CallButton(symbol: model.callMuted ? "mic.slash.fill" : "mic.fill", tint: model.callMuted ? .orange : nil,
                                   label: model.callMuted ? "Unmute" : "Mute") { model.actions?.setCallMuted(!model.callMuted) }
                    }
                    if call.phase == .active || call.phase == .held {
                        CallButton(symbol: call.phase == .held ? "play.fill" : "pause.fill", tint: call.phase == .held ? .orange : nil,
                                   label: call.phase == .held ? "Resume" : "Hold") { model.actions?.toggleCallHold() }
                    }
                    CallButton(symbol: "phone.down.fill", tint: .red, label: "End Call") { model.actions?.endCall() }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private func status(_ call: LiveCall) -> some View {
        switch call.phase {
        case .incoming: Text("Incoming call")
        case .dialing: Text("Calling…")
        case .alerting: Text("Ringing…")
        case .held: Text("On hold")
        case .active:
            HStack(spacing: 4) {
                if let since = model.liveCallSince {
                    TimelineView(.periodic(from: since, by: 1)) { moment in
                        Text(LiveCallBar.clock(moment.date.timeIntervalSince(since))).monospacedDigit()
                    }
                    Text("·")
                }
                Text("Audio on phone")
            }
        }
    }

    /// A call's length as a phone shows it: minutes and seconds, hours when there are any.
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The call as a card of its own, the way a phone shows it: whose phone, who is on the line,
/// how the call stands, where its sound is, and the buttons with their names under them. For
/// the panel that floats over everything while a call lasts.
struct LiveCallCard: View {
    @ObservedObject var model: AppModel

    private var phoneName: String {
        model.phones.first { $0.id == model.currentPhoneId }?.name ?? "Phone"
    }

    var body: some View {
        if let call = model.liveCall {
            let title = model.title(for: call)
            VStack(spacing: 0) {
                Label(phoneName, systemImage: "phone.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                ContactAvatar(name: title, photo: call.number.flatMap { model.contacts.contact(for: $0)?.photo }, size: 84)
                    .padding(.top, 18)
                Text(title).font(.title2.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                    .padding(.top, 14)
                // Under a contact's name, the number the call is with.
                Text(call.number.flatMap { $0 == title ? nil : $0 } ?? " ")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    .padding(.top, 2)
                status(call).font(.body.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.top, 14)
                // The sound cannot come to the Mac: say where it is, as a phone says "speaker".
                Label("Audio on Phone", systemImage: "phone.and.waveform.fill")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.top, 22)
                HStack(alignment: .top, spacing: call.phase == .incoming ? 44 : 22) {
                    if call.phase == .incoming {
                        CallButton(symbol: "phone.down.fill", tint: .red, label: "Decline", size: 58, captioned: true) { model.actions?.endCall() }
                        CallButton(symbol: "phone.fill", tint: .green, label: "Answer", size: 58, captioned: true) { model.actions?.answerCall() }
                    } else {
                        // Only on a phone that said it mutes on request; most do not.
                        if model.callCanMute, call.phase == .active {
                            CallButton(symbol: model.callMuted ? "mic.slash.fill" : "mic.fill", tint: model.callMuted ? .orange : nil,
                                       label: model.callMuted ? "Unmute" : "Mute", size: 46, captioned: true) { model.actions?.setCallMuted(!model.callMuted) }
                        }
                        if call.phase == .active || call.phase == .held {
                            CallButton(symbol: call.phase == .held ? "play.fill" : "pause.fill", tint: call.phase == .held ? .orange : nil,
                                       label: call.phase == .held ? "Resume" : "Hold", size: 46, captioned: true) { model.actions?.toggleCallHold() }
                        }
                        CallButton(symbol: "phone.down.fill", tint: .red, label: "End", size: 58, captioned: true) { model.actions?.endCall() }
                    }
                }
                .padding(.top, 14)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 18)
            .frame(width: 264)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private func status(_ call: LiveCall) -> some View {
        switch call.phase {
        case .incoming: Text("Incoming call")
        case .dialing: Text("Calling…")
        case .alerting: Text("Ringing…")
        case .held: Text("On hold")
        case .active:
            if let since = model.liveCallSince {
                TimelineView(.periodic(from: since, by: 1)) { moment in
                    Text(LiveCallBar.clock(moment.date.timeIntervalSince(since))).monospacedDigit()
                }
            } else {
                Text("Connected")
            }
        }
    }
}

/// A round button of the kind a phone's call screen has, with its name under it where there
/// is room for one.
private struct CallButton: View {
    let symbol: String
    let tint: Color?
    let label: String
    var size: CGFloat = 36
    var captioned = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
                    .frame(width: size, height: size)
                    .background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.quaternary), in: Circle())
                if captioned { Text(label).font(.caption.weight(.semibold)).foregroundStyle(.primary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Shows the call in a small panel for as long as it lasts, so that a ringing phone can be
/// answered whatever window is in front. The panel never takes the keyboard from the app in
/// use. It starts at the top right of the screen, can be dragged anywhere by its background,
/// and comes back where it was left.
@MainActor
final class CallPanelController {
    private let model: AppModel
    private var panel: NSPanel?
    private var watching: AnyCancellable?
    private var moved: NSObjectProtocol?
    static let positionKey = "calls.panelOrigin"

    init(model: AppModel) {
        self.model = model
        watching = model.$liveCall.map { $0 != nil }.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] showing in
            MainActor.assumeIsolated { self?.show(showing) }
        }
    }

    private func show(_ showing: Bool) {
        guard showing else {
            panel?.orderOut(nil)
            return
        }
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setFrameOrigin(CallPanelController.origin(for: panel.frame.size, saved: UserDefaults.standard.string(forKey: CallPanelController.positionKey),
                                                        screens: NSScreen.screens.map(\.visibleFrame), main: NSScreen.main?.visibleFrame))
        panel.orderFrontRegardless()
    }

    /// Where the panel goes: where the user left it, if that is still on a screen; else the
    /// top right corner of the main one.
    static func origin(for size: NSSize, saved: String?, screens: [NSRect], main: NSRect?) -> NSPoint {
        if let saved {
            let point = NSPointFromString(saved)
            let frame = NSRect(origin: point, size: size)
            // Enough of it must be in view to be grabbed again.
            if screens.contains(where: { $0.intersection(frame).width >= 80 && $0.intersection(frame).height >= 80 }) { return point }
        }
        let area = main ?? screens.first ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16)
    }

    private func makePanel() -> NSPanel {
        // Dark glass whatever the system's look, as call screens are.
        let card = LiveCallCard(model: model)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .environment(\.colorScheme, .dark)
        let content = card
        let host = NSHostingView(rootView: content)
        let panel = CallPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // Wherever it is moved to, by whichever of the two ways, is where it comes back.
        moved = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak panel] _ in
            MainActor.assumeIsolated {
                guard let panel, panel.isVisible else { return }
                UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: CallPanelController.positionKey)
            }
        }
        return panel
    }
}

/// The call's panel can be picked up anywhere and moved. Its content is one view that takes
/// every click for itself, so the window's own "drag me by my background" finds no background;
/// the panel watches the mouse instead: a press that turns into a movement is a drag of the
/// window, and whatever was pressed is let go of first, so that no button fires at the end.
final class CallPanel: NSPanel {
    private var pressedAt: NSPoint?

    /// How far the pointer must travel with the button down before it is a drag and not a
    /// click with an unsteady hand.
    static func isDrag(from start: NSPoint, to point: NSPoint) -> Bool {
        abs(point.x - start.x) > 4 || abs(point.y - start.y) > 4
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressedAt = event.locationInWindow
        case .leftMouseDragged:
            if let start = pressedAt, CallPanel.isDrag(from: start, to: event.locationInWindow) {
                pressedAt = nil
                // Let go of the button under the pointer, somewhere it does not count.
                if let release = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: -1000, y: -1000), modifierFlags: [], timestamp: event.timestamp,
                                                    windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
                    super.sendEvent(release)
                }
                performDrag(with: event)
                return
            }
        case .leftMouseUp:
            pressedAt = nil
        default:
            break
        }
        super.sendEvent(event)
    }
}
