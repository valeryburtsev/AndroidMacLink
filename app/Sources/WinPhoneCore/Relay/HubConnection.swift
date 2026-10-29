import Foundation

/// A SignalR hub connection speaking the MessagePack protocol over one WebSocket.
///
/// Outbound invocations get string IDs "1", "2", ... and complete when the hub answers with a
/// Completion. Inbound invocations from the hub are delivered through `events` in order.
public actor HubConnection {
    public struct Invocation: Equatable, Sendable {
        public var target: String
        public var arguments: [MsgPack]
    }

    public enum HubError: Error, Equatable {
        case closed(String?)
        case invocationFailed(String)
        case notStarted
    }

    private let socket: WebSocketConnection
    private var nextInvocation = 1
    private var pending: [String: CheckedContinuation<MsgPack?, Error>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var closedReason: String??
    private var lastReceived = ContinuousClock.now
    private let continuation: AsyncStream<Invocation>.Continuation

    /// Hub-to-client invocations in arrival order. Finishes when the connection closes.
    public nonisolated let events: AsyncStream<Invocation>

    public init(socket: WebSocketConnection) {
        self.socket = socket
        (events, continuation) = AsyncStream.makeStream(of: Invocation.self, bufferingPolicy: .unbounded)
    }

    /// Performs the handshake and starts the receive and keepalive loops.
    /// - Parameters:
    ///   - keepAlive: interval between client pings. SignalR's default is 15 seconds.
    ///   - serverTimeout: the connection is closed when the hub sends nothing, not even a ping,
    ///     for this long. SignalR's default is 30 seconds.
    public func start(keepAlive: Duration = .seconds(15), serverTimeout: Duration = .seconds(30)) async throws {
        try await socket.send(SignalR.handshakeRequest)
        let first = try await socket.receive()
        let (handshake, rest) = try SignalR.splitHandshake(first)
        try SignalR.checkHandshakeResponse(handshake)
        handle(message: rest)
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
        lastReceived = .now
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: keepAlive)
                if Task.isCancelled { return }
                guard let self else { return }
                if await self.silentFor(longerThan: serverTimeout) {
                    await self.shutDown(reason: "server timeout")
                    return
                }
                try? await self.sendRaw(HubMessage.ping.framed)
            }
        }
    }

    /// Calls a hub method and waits for its Completion.
    /// - Returns: the result value, or nil for a void completion.
    @discardableResult
    public func invoke(_ target: String, arguments: [MsgPack], headers: MsgPack = HubMessage.emptyHeaders) async throws -> MsgPack? {
        if let closedReason { throw HubError.closed(closedReason) }
        let id = String(nextInvocation)
        nextInvocation += 1
        let frame = HubMessage.invocation(headers: headers, invocationId: id, target: target, arguments: arguments).framed
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await self.socket.send(frame)
                } catch {
                    self.fail(id: id, error: error)
                }
            }
        }
    }

    public func close() {
        shutDown(reason: nil)
        socket.close()
    }

    public var isClosed: Bool { closedReason != nil }

    // MARK: Internals

    private func silentFor(longerThan limit: Duration) -> Bool {
        ContinuousClock.now - lastReceived > limit
    }

    private func sendRaw(_ data: Data) async throws {
        try await socket.send(data)
    }

    private func fail(id: String, error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                handle(message: message)
                if closedReason != nil { return }
            } catch {
                shutDown(reason: String(describing: error))
                return
            }
        }
    }

    private func handle(message: Data) {
        lastReceived = .now
        guard !message.isEmpty else { return }
        let frames: [Data]
        do {
            frames = try SignalR.splitFrames(message)
        } catch {
            shutDown(reason: "malformed frame: \(error)")
            return
        }
        for frame in frames {
            guard let hubMessage = try? HubMessage(frame: frame) else { continue }
            switch hubMessage {
            case .invocation(_, _, let target, let arguments):
                continuation.yield(Invocation(target: target, arguments: arguments))
            case .completion(_, let id, let kind, let value):
                guard let waiter = pending.removeValue(forKey: id) else { continue }
                if kind == 1 {
                    waiter.resume(throwing: HubError.invocationFailed(value?.stringValue ?? "unknown error"))
                } else {
                    waiter.resume(returning: kind == 3 ? value : nil)
                }
            case .close(let error, _):
                shutDown(reason: error)
            case .ping, .other:
                break
            }
        }
    }

    private func shutDown(reason: String?) {
        guard closedReason == nil else { return }
        diag("hub", "closed: \(reason ?? "by us")")
        closedReason = .some(reason)
        pingTask?.cancel()
        receiveTask?.cancel()
        for (_, waiter) in pending { waiter.resume(throwing: HubError.closed(reason)) }
        pending.removeAll()
        continuation.finish()
    }
}
