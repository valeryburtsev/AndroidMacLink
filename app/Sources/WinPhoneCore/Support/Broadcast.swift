import Foundation

/// Updates for whoever listens now, each listener with a stream of its own. A single
/// `AsyncStream` ends for good when the task reading it is cancelled; the phone's screen
/// outlives the connections that listen to it, and after the first reconnection its events
/// went nowhere: the window showed "Connecting…" while the phone was shown (2026-10-16).
public final class Broadcast<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [UUID: AsyncStream<Element>.Continuation] = [:]

    public init() {}

    /// A new stream that gets what is sent from now on, until its reader stops.
    public func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .unbounded)
        let id = UUID()
        lock.withLock { listeners[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.listeners.removeValue(forKey: id) }
        }
        return stream
    }

    public func send(_ element: Element) {
        let current = lock.withLock { Array(listeners.values) }
        for listener in current { listener.yield(element) }
    }

    /// How many listen now.
    public var listenerCount: Int { lock.withLock { listeners.count } }
}
