import Foundation

/// A connected WebSocket. Text messages are delivered as their UTF-8 bytes.
public protocol WebSocketConnection: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

public protocol WebSocketConnector: Sendable {
    func connect(url: URL, headers: [(name: String, value: String)]) async throws -> WebSocketConnection
}

public struct URLSessionWebSocketConnector: WebSocketConnector {
    private let session: URLSession

    public init(session: URLSession = URLSessionTransport.makeSession()) {
        self.session = session
    }

    public func connect(url: URL, headers: [(name: String, value: String)]) async throws -> WebSocketConnection {
        var request = URLRequest(url: url)
        for header in headers { request.setValue(header.value, forHTTPHeaderField: header.name) }
        let task = session.webSocketTask(with: request)
        // Hub frames can carry large fragments; the default limit is 1 MiB.
        task.maximumMessageSize = 16 << 20
        task.resume()
        return Connection(task: task)
    }

    private struct Connection: WebSocketConnection {
        let task: URLSessionWebSocketTask

        func send(_ data: Data) async throws { try await task.send(.data(data)) }

        func receive() async throws -> Data {
            switch try await task.receive() {
            case .data(let data): return data
            case .string(let text): return Data(text.utf8)
            @unknown default: return Data()
            }
        }

        func close() { task.cancel(with: .normalClosure, reason: nil) }
    }
}
