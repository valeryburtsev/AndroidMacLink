import Foundation
import os

/// A plain diagnostics log: what the client did and how the service answered.
///
/// It records steps, hosts and paths, status codes and error codes. It never records tokens,
/// keys, request or response bodies, notification text or clipboard content.
public final class Diagnostics: @unchecked Sendable {
    public static let shared = Diagnostics()

    private let lock = NSLock()
    private let system = Logger(subsystem: "com.winphone.app", category: "link")
    private var handle: FileHandle?
    private var file: URL?
    private var written = 0
    /// The file starts over, keeping one older copy, once it reaches this size.
    public var sizeLimit = 4 * 1024 * 1024
    private var recent: [String] = []
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Starts appending to a file, keeping the previous run as `<name>.1`.
    public func writeToFile(_ url: URL) {
        lock.withLock {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            file = url
            startFile()
        }
    }

    /// Moves the current file aside as `<name>.1` and opens a fresh one. Call with the lock held.
    private func startFile() {
        guard let url = file else { return }
        try? handle?.close()
        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try? FileHandle(forWritingTo: url)
        written = 0
    }

    public func log(_ area: String, _ message: String) {
        lock.withLock {
            let line = "\(formatter.string(from: Date())) [\(area)] \(message)"
            system.info("\(line, privacy: .public)")
            recent.append(line)
            if recent.count > 400 { recent.removeFirst(recent.count - 400) }
            let bytes = Data((line + "\n").utf8)
            try? handle?.write(contentsOf: bytes)
            written += bytes.count
            // A session that runs for weeks must not grow the file without end.
            if written >= sizeLimit { startFile() }
        }
    }

    /// The newest lines, oldest first.
    public var recentLines: [String] { lock.withLock { recent } }
}

/// Shorthand for `Diagnostics.shared.log`.
public func diag(_ area: String, _ message: String) {
    Diagnostics.shared.log(area, message)
}

/// Logs every request by method, host and path, with the status and, for failures, the error
/// code and message the service gave. Query strings, headers and bodies are left out.
public struct LoggingTransport: HTTPTransport {
    public var inner: HTTPTransport

    public init(_ inner: HTTPTransport) { self.inner = inner }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let target = "\(request.method) \(request.url.host ?? "?")\(request.url.path)"
        let start = ContinuousClock.now
        do {
            let response = try await inner.send(request)
            let elapsed = (ContinuousClock.now - start).components
            let ms = Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
            var line = "\(target) -> \(response.status) (\(ms) ms)"
            if !(200..<300).contains(response.status) { line += " " + LoggingTransport.errorSummary(response.body) }
            // Waiting for the user to finish signing in is not worth a line per poll.
            if !line.contains("authorization_pending") { diag("http", line) }
            return response
        } catch {
            diag("http", "\(target) failed: \(LoggingTransport.describe(error))")
            throw error
        }
    }

    /// The error code and message of a DCG or OAuth error body, and nothing else from it.
    static func errorSummary(_ body: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return body.isEmpty ? "(empty body)" : "(\(body.count) bytes, not JSON)"
        }
        if let error = object["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "?"
            let category = (error["categoryCode"] as? NSNumber).map { " category \($0)" } ?? ""
            return "\(code)\(category): \(String((error["message"] as? String ?? "").prefix(200)))"
        }
        if let code = object["error"] as? String {
            return "\(code): \(String((object["error_description"] as? String ?? "").prefix(200)))"
        }
        return "(JSON with keys \(object.keys.sorted().joined(separator: ",")))"
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code) \(ns.localizedDescription)"
    }
}
