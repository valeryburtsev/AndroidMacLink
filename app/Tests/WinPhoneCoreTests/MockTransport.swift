import Foundation
@testable import WinPhoneCore

/// Scripted HTTP transport: records every request and answers from a queue or a handler.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private var queue: [HTTPResponse] = []
    var handler: (@Sendable (HTTPRequest) throws -> HTTPResponse)?

    var requests: [HTTPRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func enqueue(status: Int = 200, json: String) {
        lock.lock(); defer { lock.unlock() }
        queue.append(HTTPResponse(status: status, body: Data(json.utf8)))
    }

    func enqueue(status: Int = 200, body: Data) {
        lock.lock(); defer { lock.unlock() }
        queue.append(HTTPResponse(status: status, body: body))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        _requests.append(request)
        let next = queue.isEmpty ? nil : queue.removeFirst()
        let handler = self.handler
        lock.unlock()
        if let next { return next }
        if let handler { return try handler(request) }
        throw URLError(.resourceUnavailable)
    }
}

func jsonTypes(_ value: Any) -> Any {
    if let dict = value as? [String: Any] { return dict.mapValues(jsonTypes) }
    if let array = value as? [Any] { return array.first.map { [jsonTypes($0)] } ?? [] }
    if value is NSNull { return "null" }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return "bool" }
        return CFNumberIsFloatType(number) ? "double" : "int"
    }
    return "string"
}
