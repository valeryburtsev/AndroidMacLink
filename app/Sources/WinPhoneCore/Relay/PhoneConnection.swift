import Foundation

/// Presence and reachability of one phone on an open hub connection, plus the messaging stack
/// bound to it.
///
/// The sequence follows what Phone Link does on the wire: announce presence to the phone, wait
/// for the hub's on-connected payload, send a wake push if the phone is not there, and treat the
/// phone as present once it announces itself or sends anything. Every presence announcement
/// from the phone is answered with one of ours, which is what lets the phone start its session.
public actor PhoneConnection {
    public enum State: Equatable, Sendable {
        case idle
        /// Waiting for the phone to appear on the hub.
        case waitingForPhone
        case online
        /// The phone left or stopped sending heartbeats.
        case offline
        case closed
    }

    public enum ConnectionError: Error, Equatable {
        /// The phone did not appear after every wake attempt.
        case phoneUnreachable
        case closed
    }

    public struct Timing: Sendable {
        /// How long to wait for the hub's on-connected payload before waking without a region.
        public var hubInfoWait: Duration = .seconds(10)
        /// After the hub reports in, how long to give a phone that is already present to answer
        /// our announcement before waking it. In the capture Windows wakes about 0.3 s after.
        public var presenceGrace: Duration = .milliseconds(300)
        /// How long to wait for the phone after each wake. Phone Link uses the push lifetime, 20 s.
        public var wakeWait: Duration = .seconds(20)
        /// Wake attempts after the first. Retries are sent with high priority.
        public var wakeRetries = 2
        /// Seconds between the phone's heartbeats, as requested at negotiate.
        public var heartbeatSeconds = 30
        /// Heartbeats that may be missed before the phone counts as gone.
        public var missedHeartbeats = 3
        public init() {}
    }

    /// Sends the wake push. Receives the hub region, if known, and whether this is a retry.
    public typealias Wake = @Sendable (_ hubRegion: String?, _ highPriority: Bool) async throws -> Void

    public nonisolated let peer: String
    public nonisolated let relay: RelayClient
    public nonisolated let messenger: PeerMessenger
    public nonisolated let resources: DeviceResources
    public nonisolated let publisher: ContextPublisher
    /// State changes, in order.
    public nonisolated let states: AsyncStream<State>

    private let wake: Wake
    private let timing: Timing
    private let continuation: AsyncStream<State>.Continuation
    public private(set) var state: State = .idle
    public private(set) var hubRegion: String?
    private var hubInfoReceived = false
    private var lastSeen = ContinuousClock.now
    private var pump: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - hub: a hub connection that has completed its handshake.
    ///   - ownId: this device's DCG client ID.
    public init(hub: HubConnection, peer: String, ownId: String, timing: Timing = Timing(), wake: @escaping Wake) {
        self.peer = peer
        self.wake = wake
        self.timing = timing
        relay = RelayClient(hub: hub)
        messenger = PeerMessenger(relay: relay, peer: peer)
        resources = DeviceResources(messenger: messenger)
        publisher = ContextPublisher(messenger: messenger, ownId: ownId)
        (states, continuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .unbounded)
    }

    /// Brings the phone online: announces presence, wakes the phone if needed, and returns once
    /// it is present. Throws `phoneUnreachable` when it never appears.
    public func connect() async throws {
        if pump == nil {
            await relay.start()
            await resources.start()
            await publisher.start()
            let events = relay.events
            pump = Task { [weak self] in
                for await event in events { await self?.handle(event) }
            }
        }
        guard state != .closed else { throw ConnectionError.closed }
        if state == .online { return }
        set(.waitingForPhone)

        // Announce ourselves first. If the phone is already on the hub it answers at once.
        try await relay.sendConnected(to: peer)
        await wait(for: timing.hubInfoWait) { self.hubInfoReceived || self.state == .online }
        await wait(for: timing.presenceGrace) { self.state == .online }

        for attempt in 0...timing.wakeRetries where state == .waitingForPhone {
            try await wake(hubRegion, attempt > 0)
            await wait(for: timing.wakeWait) { self.state != .waitingForPhone }
        }
        switch state {
        case .online: return
        case .closed: throw ConnectionError.closed
        default:
            set(.offline)
            throw ConnectionError.phoneUnreachable
        }
    }

    public func close() async {
        await relay.close()
    }

    // MARK: Events

    private func handle(_ event: RelayClient.Event) async {
        switch event {
        case .connected(let region, let partners): diag("relay", "hub connected, region \(region ?? "?"), partners present \(partners.count)")
        case .partnerConnected(let id, _): diag("relay", "partner connected \(id.prefix(8))")
        case .partnerDisconnected(let id): diag("relay", "partner disconnected \(id.prefix(8))")
        case .message(let message): diag("relay", "message from \(message.source.prefix(8)), \(message.type), \(message.payload.count) bytes")
        case .closed: diag("relay", "connection closed")
        case .partnerHeartbeat: break
        }
        switch event {
        case .connected(let region, let partners):
            hubRegion = region
            hubInfoReceived = true
            // The hub lists who is present, but Phone Link does not count that as presence;
            // it waits for the phone to announce itself.
            _ = partners
            wakeWaiters()
        case .partnerConnected(let id, _) where id == peer:
            seen(markOnline: true)
            // Answer every announcement. Without it the phone will not start a session for us.
            try? await relay.sendConnected(to: peer)
        case .message(let message) where message.source == peer:
            seen(markOnline: true)
            await messenger.receive(message)
        case .partnerHeartbeat(let id) where id == peer:
            // A heartbeat keeps a present phone alive but does not make an absent one present.
            if state == .online { seen(markOnline: false) }
        case .partnerDisconnected(let id) where id == peer:
            if state == .online { set(.offline) }
        case .closed:
            watchdog?.cancel()
            await messenger.connectionLost()
            set(.closed)
        default:
            break
        }
    }

    private func seen(markOnline: Bool) {
        lastSeen = .now
        guard markOnline, state != .online, state != .closed else { return }
        set(.online)
        startWatchdog()
    }

    /// Declares the phone gone after too many missed heartbeats.
    private func startWatchdog() {
        watchdog?.cancel()
        guard timing.heartbeatSeconds > 0 else { return }
        let interval = Duration.seconds(timing.heartbeatSeconds + 2)
        let limit = interval * timing.missedHeartbeats
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                if await self.silentFor(longerThan: limit) { return }
            }
        }
    }

    private func silentFor(longerThan limit: Duration) -> Bool {
        guard state == .online else { return true }
        if ContinuousClock.now - lastSeen > limit {
            set(.offline)
            return true
        }
        return false
    }

    private func set(_ new: State) {
        guard state != new else { return }
        state = new
        continuation.yield(new)
        if new == .closed { continuation.finish() }
        wakeWaiters()
    }

    // MARK: Waiting

    private func wakeWaiters() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    /// Suspends until `condition` holds or the time is up, re-checking whenever state changes.
    private func wait(for duration: Duration, until condition: @escaping () -> Bool) async {
        let deadline = ContinuousClock.now + duration
        while !condition(), ContinuousClock.now < deadline, state != .closed {
            let remaining = deadline - ContinuousClock.now
            let timer = Task { [weak self] in
                try? await Task.sleep(for: remaining)
                await self?.wakeWaiters()
            }
            await withCheckedContinuation { waiters.append($0) }
            timer.cancel()
        }
    }
}
