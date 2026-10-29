import Foundation
@testable import WinPhoneCore

/// An in-memory WebSocket with a scripted peer. The test plays the hub: it sees every message the
/// client sends through `onClientMessage` and pushes messages with `deliver`.
final class MockWebSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Result<Data, Error>] = []
    private var waiter: CheckedContinuation<Data, Error>?
    private var _sent: [Data] = []
    private var closed = false
    var onClientMessage: (@Sendable (Data, MockWebSocket) -> Void)?

    var sent: [Data] { lock.lock(); defer { lock.unlock() }; return _sent }

    /// Hub frames the client sent, handshake excluded.
    var sentHubMessages: [HubMessage] {
        sent.dropFirst().flatMap { (try? SignalR.splitFrames($0)) ?? [] }.compactMap { try? HubMessage(frame: $0) }
    }

    func send(_ data: Data) async throws {
        lock.lock()
        if closed { lock.unlock(); throw URLError(.networkConnectionLost) }
        _sent.append(data)
        let handler = onClientMessage
        lock.unlock()
        handler?(data, self)
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let next = inbox.removeFirst()
                lock.unlock()
                continuation.resume(with: next)
            } else if closed {
                lock.unlock()
                continuation.resume(throwing: URLError(.networkConnectionLost))
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() { fail(URLError(.cancelled)) }

    /// Pushes a raw WebSocket message to the client.
    func deliver(_ data: Data) { push(.success(data)) }

    /// Pushes hub messages as one WebSocket message.
    func deliver(_ messages: HubMessage...) { deliver(messages.reduce(Data()) { $0 + $1.framed }) }

    /// Breaks the connection.
    func fail(_ error: Error) {
        lock.lock()
        closed = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(throwing: error)
    }

    private func push(_ result: Result<Data, Error>) {
        lock.lock()
        if let pending = waiter {
            waiter = nil
            lock.unlock()
            pending.resume(with: result)
        } else {
            inbox.append(result)
            lock.unlock()
        }
    }

    /// A socket whose peer answers the handshake and completes every invocation with a void result.
    static func autoCompleting() -> MockWebSocket {
        let socket = MockWebSocket()
        socket.onClientMessage = { data, socket in
            if data == SignalR.handshakeRequest { socket.deliver(Data("{}".utf8) + [SignalR.recordSeparator]); return }
            for frame in (try? SignalR.splitFrames(data)) ?? [] {
                if case .invocation(_, let id?, _, _)? = try? HubMessage(frame: frame) {
                    socket.deliver(.completion(headers: .map([]), invocationId: id, resultKind: 3, value: .null))
                }
            }
        }
        return socket
    }
}

struct MockConnector: WebSocketConnector {
    let socket: MockWebSocket
    let record: @Sendable (URL, [(name: String, value: String)]) -> Void
    func connect(url: URL, headers: [(name: String, value: String)]) async throws -> WebSocketConnection {
        record(url, headers)
        return socket
    }
}

func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
