import AppKit
import SwiftUI

/// One sideways swipe over a row, reckoned apart from the events that drive it.
struct SwipeTrack: Equatable {
    var row: String
    /// How far the row has been pushed to the left: zero or less.
    var offset: CGFloat = 0

    /// Whether a movement that begins like this goes sideways and not along the list.
    static func isSideways(dx: CGFloat, dy: CGFloat) -> Bool { abs(dx) > 0.5 && abs(dx) > abs(dy) * 1.5 }

    /// The fingers moved on; the row follows them, to the left only and no further than its width.
    mutating func move(by dx: CGFloat, width: CGFloat) { offset = min(0, max(-width, offset + dx)) }

    /// Whether letting go here sends the row away.
    func dismisses(width: CGFloat) -> Bool { -offset >= min(150, width * 0.3) }
}

/// Swiping a row of the notifications to the left with two fingers dismisses it, as the
/// system's own lists have it. Those lists could not be kept (rows cut off, macOS 27), so
/// the swipe is read here from the scrolling events themselves.
@MainActor
final class NotificationSwipe: ObservableObject {
    enum Phase: Equatable {
        case began, changed, ended, cancelled
        /// The glide after the fingers have left.
        case momentum(ended: Bool)
        case other
    }

    @Published private(set) var track: SwipeTrack?
    /// Where the rows are, in the window's content, counted from its top left.
    var frames: [String: CGRect] = [:]
    var onDismiss: (String) -> Void = { _ in }
    weak var window: NSWindow?
    private var monitor: Any?
    /// The rest of a movement that was taken as a swipe belongs to it too, glide included.
    private var taking = false

    func offset(for row: String) -> CGFloat { track?.row == row ? track?.offset ?? 0 : 0 }

    func start() {
        guard monitor == nil else { return }
        NotificationSwipe.current = self
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard event.hasPreciseScrollingDeltas else { return event }
            let number = event.windowNumber, location = event.locationInWindow
            // As the fingers go, whichever way the user has scrolling set.
            let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX, dy = event.scrollingDeltaY
            let phase: Phase
            if event.phase.contains(.began) { phase = .began }
            else if event.phase.contains(.changed) { phase = .changed }
            else if event.phase.contains(.ended) { phase = .ended }
            else if event.phase.contains(.cancelled) { phase = .cancelled }
            else if !event.momentumPhase.isEmpty { phase = .momentum(ended: event.momentumPhase.contains(.ended)) }
            else { phase = .other }
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, window.windowNumber == number, let content = window.contentView else { return false }
                return self.handle(point: NotificationSwipe.contentPoint(location, in: content), dx: dx, dy: dy, phase: phase)
            }
            return taken ? nil : event
        }
    }

    /// The one on screen, for the development aid that tries a swipe.
    static weak var current: NotificationSwipe?

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        track = nil
        taking = false
    }

    /// A point of the window, as the rows' frames count: from the content's top left.
    static func contentPoint(_ inWindow: CGPoint, in content: NSView) -> CGPoint {
        var point = content.convert(inWindow, from: nil)
        if !content.isFlipped { point.y = content.bounds.height - point.y }
        return point
    }

    /// One scrolling event. Returns whether it was the swipe's, and so not the list's.
    /// The choice falls at the start of a movement: sideways over a row, it is a swipe to
    /// its end; else it is scrolling and none of it is touched.
    func handle(point: CGPoint, dx: CGFloat, dy: CGFloat, phase: Phase) -> Bool {
        switch phase {
        case .began:
            taking = false
            track = nil
            guard SwipeTrack.isSideways(dx: dx, dy: dy), let row = frames.first(where: { $0.value.contains(point) }) else { return false }
            taking = true
            var begun = SwipeTrack(row: row.key)
            begun.move(by: dx, width: row.value.width)
            track = begun
            return true
        case .changed:
            guard taking, var moved = track, let frame = frames[moved.row] else { return taking }
            moved.move(by: dx, width: frame.width)
            track = moved
            return true
        case .ended, .cancelled:
            guard taking else { return false }
            guard let ended = track, let frame = frames[ended.row] else { return true }
            if phase == .ended, ended.dismisses(width: frame.width) {
                withAnimation(.easeOut(duration: 0.16)) { track?.offset = -frame.width }
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(170))
                    self?.onDismiss(ended.row)
                    if self?.track?.row == ended.row { self?.track = nil }
                }
            } else {
                withAnimation(.spring(duration: 0.25)) { track = nil }
            }
            return true
        case .momentum(let ended):
            guard taking else { return false }
            if ended { taking = false }
            return true
        case .other:
            return false
        }
    }
}

/// The frames of the rows that can be swiped, by their identifiers.
struct SwipeFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

/// A row that follows a swipe to the left, with what the swipe will do shown behind it.
struct SwipeToDismissRow<Content: View>: View {
    let id: String
    @ObservedObject var swipe: NotificationSwipe
    @ViewBuilder var content: Content

    var body: some View {
        let offset = swipe.offset(for: id)
        content
            .offset(x: offset)
            .background(alignment: .trailing) {
                if offset < 0 {
                    ZStack(alignment: .trailing) {
                        Color.red
                        Label("Dismiss", systemImage: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                            .labelStyle(.titleAndIcon).lineLimit(1).fixedSize().padding(.trailing, 18)
                            .opacity(-offset > 90 ? 1 : 0)
                    }
                    .frame(width: -offset)
                    .clipped()
                    .accessibilityHidden(true)
                }
            }
            .background(GeometryReader { proxy in Color.clear.preference(key: SwipeFrames.self, value: [id: proxy.frame(in: .global)]) })
            .clipped()
    }
}

/// Tells which window a view is in.
struct WindowReader: NSViewRepresentable {
    let found: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { found(view.window) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { found(view.window) }
    }
}
