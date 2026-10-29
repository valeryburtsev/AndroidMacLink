import Foundation

/// Routed request and response messaging with one peer, on top of the relay.
///
/// Both message kinds use the same binary envelope. A request carries `_route` and `_requestId`;
/// its response comes back on route `/internal/response` with `_originalRequestId` set, on either
/// message kind. The DCG acknowledgement of a fragment is not a response.
public actor PeerMessenger {
    public static let responseRoute = "/internal/response"
    public static let binaryContentType = "application/x-binary"
    public static let jsonContentType = "text/json"

    public enum MessagingError: Error, Equatable {
        /// The peer answered with `_rejectedReason`, for example `NotSubscribedToRoute`.
        case rejected(reason: String)
        case timedOut(route: String)
        case closed
    }

    /// A request from the peer, with what is needed to answer it.
    public struct IncomingRequest: Sendable {
        public var envelope: PlatformEnvelope
        public var type: RelayMessageType
        public var source: String
        public var route: String { envelope.route ?? "" }
        public var payload: Data { envelope.payload }
    }

    public typealias Handler = @Sendable (IncomingRequest, PeerMessenger) async -> Void

    public func onMeteredRefusal(_ observer: (@Sendable () -> Void)?) {
        meteredRefusalObserver = observer
    }

    /// Whether an answer is the short value set the phone sends for "not over this network":
    /// result 8 or 12, with the Wi-Fi state and the setting beside it.
    static func isMeteredRefusal(_ payload: Data) -> Bool {
        guard payload.count < 600, let values = try? ValueSet(serialized: payload), let result = values.int("result") else { return false }
        return result == ScenarioResult.meteredConnection.rawValue || result == ScenarioResult.meteredConnectionSyncDisabled.rawValue
    }

    private let relay: RelayClient
    public nonisolated let peer: String
    private var nextRequestId = 1
    private var pending: [String: CheckedContinuation<PlatformEnvelope, Error>] = [:]
    /// The timer of each pending request, stopped when the request is settled: some wait ten
    /// minutes, and a sleeping task per answered request adds up.
    private var timers: [String: Task<Void, Never>] = [:]
    private var handlers: [(prefix: String, exact: Bool, handler: Handler)] = []
    /// Told when the peer refuses a request because it is on a metered network and may not
    /// sync over it: whatever was asked, that is news about the phone.
    private var meteredRefusalObserver: (@Sendable () -> Void)?
    private let requestTimeout: Duration
    private let jobs: AsyncStream<@Sendable () async -> Void>.Continuation
    private let jobStream: AsyncStream<@Sendable () async -> Void>
    private var worker: Task<Void, Never>?

    /// - Parameter requestTimeout: how long to wait for a response. Phone Link waits 120 seconds.
    public init(relay: RelayClient, peer: String, requestTimeout: Duration = .seconds(120)) {
        self.relay = relay
        self.peer = peer
        self.requestTimeout = requestTimeout
        (jobStream, jobs) = AsyncStream.makeStream(of: (@Sendable () async -> Void).self, bufferingPolicy: .unbounded)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        let stream = jobStream
        worker = Task { for await job in stream { await job() } }
    }

    /// Registers a handler for a route. With `prefix`, it also receives longer routes such as
    /// `/Context/Message/<id>`.
    public func handle(_ route: String, prefix: Bool = false, _ handler: @escaping Handler) {
        handlers.append((route, !prefix, handler))
    }

    // MARK: Sending

    /// Sends a PLATFORM request and waits for its response.
    public func request(route: String, payload: Data, contentType: String = PeerMessenger.binaryContentType,
                        trace: TraceContext = TraceContext(), timeout: Duration? = nil) async throws -> PlatformEnvelope {
        // Phone Link numbers PLATFORM requests with a process-wide decimal counter.
        let id = String(nextRequestId)
        nextRequestId += 1
        let envelope = PlatformEnvelope(headers: [
            (PlatformEnvelope.Header.route, route),
            (PlatformEnvelope.Header.contentType, contentType),
            (PlatformEnvelope.Header.requestId, id),
            (PlatformEnvelope.Header.rejectionVersion, "1"),
        ], payload: payload)
        return try await send(envelope, id: id, type: .platform, route: route, trace: trace, timeout: timeout)
    }

    /// Sends an APP request and waits for its response. APP requests use a GUID as request ID
    /// and carry no content type. Phone Link puts the request ID before the route here, unlike
    /// on PLATFORM requests (capture of 2026-10-09).
    /// - Parameter timeout: how long to wait for the answer, when the default is not right:
    ///   some requests are answered only after the phone's user acts or a long sync finishes.
    public func appRequest(route: String, payload: Data, extraHeaders: [(key: String, value: String)] = [],
                           trace: TraceContext = TraceContext(), timeout: Duration? = nil) async throws -> PlatformEnvelope {
        let id = UUID().uuidString.lowercased()
        let envelope = PeerMessenger.appRequestEnvelope(route: route, id: id, payload: payload, extraHeaders: extraHeaders)
        return try await send(envelope, id: id, type: .app, route: route, trace: trace, timeout: timeout)
    }

    static func appRequestEnvelope(route: String, id: String, payload: Data, extraHeaders: [(key: String, value: String)] = []) -> PlatformEnvelope {
        PlatformEnvelope(headers: [(PlatformEnvelope.Header.requestId, id), (PlatformEnvelope.Header.route, route)] + extraHeaders + [
            (PlatformEnvelope.Header.rejectionVersion, "1"),
        ], payload: payload)
    }

    /// Sends a message that expects no response.
    public func post(route: String, payload: Data, contentType: String? = PeerMessenger.binaryContentType,
                     type: RelayMessageType = .platform, trace: TraceContext = TraceContext()) async throws {
        var headers: [(key: String, value: String)] = [(PlatformEnvelope.Header.route, route)]
        if let contentType { headers.append((PlatformEnvelope.Header.contentType, contentType)) }
        headers.append((PlatformEnvelope.Header.requestId, String(nextRequestId)))
        headers.append((PlatformEnvelope.Header.rejectionVersion, "1"))
        nextRequestId += 1
        try await relay.send(PlatformEnvelope(headers: headers, payload: payload).encoded(), type: type, to: peer, trace: trace)
    }

    /// Answers a request. The response keeps the request's message kind.
    /// - Parameter result: for APP replies, the scenario result. Phone Link repeats it as a
    ///   `result` header next to the value set (capture of 2026-10-09).
    public func respond(to request: IncomingRequest, payload: Data, contentType: String? = PeerMessenger.binaryContentType,
                        result: Int? = nil, rejectedReason: String? = nil) async throws {
        guard let envelope = PeerMessenger.responseEnvelope(to: request.envelope, payload: payload, contentType: contentType,
                                                            result: result, rejectedReason: rejectedReason) else { return }
        try await relay.send(envelope.encoded(), type: request.type, to: peer)
    }

    /// Builds the response to a request, with the header order Phone Link uses. Returns nil
    /// when the request carries no ID and so cannot be answered.
    static func responseEnvelope(to request: PlatformEnvelope, payload: Data, contentType: String?, result: Int? = nil,
                                 rejectedReason: String? = nil) -> PlatformEnvelope? {
        guard let id = request.requestId else { return nil }
        var headers: [(key: String, value: String)] = [
            (PlatformEnvelope.Header.originalRequestId, id),
            (PlatformEnvelope.Header.route, PeerMessenger.responseRoute),
        ]
        if let contentType { headers.append((PlatformEnvelope.Header.contentType, contentType)) }
        if let result { headers.append((PlatformEnvelope.Header.result, String(result))) }
        headers.append((PlatformEnvelope.Header.rejectionVersion, "1"))
        if let rejectedReason { headers.append((PlatformEnvelope.Header.rejectedReason, rejectedReason)) }
        return PlatformEnvelope(headers: headers, payload: payload)
    }

    private func send(_ envelope: PlatformEnvelope, id: String, type: RelayMessageType, route: String,
                      trace: TraceContext, timeout: Duration? = nil) async throws -> PlatformEnvelope {
        let timeout = timeout ?? requestTimeout
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await self.relay.send(envelope.encoded(), type: type, to: self.peer, trace: trace)
                } catch {
                    self.fail(id, error)
                }
            }
            timers[id] = Task {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { self.fail(id, MessagingError.timedOut(route: route)) }
            }
        }
    }

    private func fail(_ id: String, _ error: Error) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: Receiving

    /// Feeds one reassembled relay message from this peer into the messenger.
    public func receive(_ message: RelayClient.InboundMessage) async {
        guard message.source == peer, var envelope = try? PlatformEnvelope(decoding: message.payload) else {
            diag("messaging", "dropped a message that is not an envelope (\(message.payload.count) bytes)")
            return
        }
        // The phone may gzip a payload and say so in a header.
        if envelope[PlatformEnvelope.Header.gzipped]?.lowercased() == "true" {
            guard let inflated = Gzip.decompress(envelope.payload) else {
                diag("messaging", "dropped a message whose compressed payload could not be read (\(envelope.payload.count) bytes, route \(envelope.route ?? "?"))")
                return
            }
            envelope.payload = inflated
        }
        if envelope.route == PeerMessenger.responseRoute {
            guard let id = envelope.originalRequestId, let waiter = pending.removeValue(forKey: id) else { return }
            timers.removeValue(forKey: id)?.cancel()
            if let reason = envelope[PlatformEnvelope.Header.rejectedReason], reason != "None" {
                if reason == "MeteredSyncDisabled" { meteredRefusalObserver?() }
                waiter.resume(throwing: MessagingError.rejected(reason: reason))
            } else {
                if meteredRefusalObserver != nil, PeerMessenger.isMeteredRefusal(envelope.payload) { meteredRefusalObserver?() }
                waiter.resume(returning: envelope)
            }
            return
        }
        let request = IncomingRequest(envelope: envelope, type: message.type, source: message.source)
        let route = request.route
        if let match = handlers.first(where: { $0.exact ? $0.prefix == route : route.hasPrefix($0.prefix) }) {
            // Handlers run off the receive path, one at a time and in arrival order. A handler
            // may send a request of its own and wait for the answer, which can only arrive if
            // this method has returned; responses never pass through this queue.
            let handler = match.handler
            startWorkerIfNeeded()
            jobs.yield { await handler(request, self) }
            return
        }
        // No handler. A sender that understands rejections gets told, as Phone Link does:
        // an empty JSON object with `_rejectedReason: NotSubscribedToRoute`.
        if let version = envelope[PlatformEnvelope.Header.rejectionVersion].flatMap(Int.init), version >= 1, envelope.requestId != nil {
            try? await respond(to: request, payload: Data("{}".utf8), contentType: PeerMessenger.jsonContentType,
                               rejectedReason: "NotSubscribedToRoute")
        }
    }

    /// Fails every pending request, for when the relay connection is lost.
    public func connectionLost() {
        for (_, waiter) in pending { waiter.resume(throwing: MessagingError.closed) }
        pending.removeAll()
        for (_, timer) in timers { timer.cancel() }
        timers.removeAll()
        jobs.finish()
    }
}
