import Foundation

/// UDP to one address over a plain socket with a large receive buffer and a reader thread of
/// its own. A sender on the local network delivers a file in bursts of thousands of datagrams
/// a second; whatever does not fit the socket's buffer while the reader is busy is lost, and
/// every loss costs a round of recovery. So the buffer is made as large as the system allows
/// and reading never waits on anything else.
public final class NanoSocketTransport: NanoDatagramTransport, @unchecked Sendable {
    public enum SocketError: Error, Equatable {
        case cannotResolve
        case cannotOpen(Int32)
        /// The system shut the socket before anything could be sent: what macOS does while
        /// it checks, or after it has refused, the app's access to the local network.
        case blocked
    }

    /// A write to a socket the system has shut must fail with an error, not end the whole
    /// program, which is what the signal for it does unless it is switched off.
    public static func ignoreBrokenPipes() {
        signal(SIGPIPE, SIG_IGN)
    }

    private let descriptor: Int32
    private let continuation: AsyncStream<Data>.Continuation
    public let incoming: AsyncStream<Data>
    private let lock = NSLock()
    private var closed = false
    /// The receive buffer the system granted, in bytes.
    public private(set) var receiveBufferSize = 0
    private let counter = ReceivedCounter()
    public var receivedCount: Int { counter.value }

    /// Opens the socket and starts reading.
    /// - Parameter receiveBuffer: the receive buffer to ask for; the system may grant less.
    public init(host: String, port: UInt16, receiveBuffer: Int32 = 8 * 1024 * 1024) throws {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0, let info = resolved else { throw SocketError.cannotResolve }
        defer { freeaddrinfo(resolved) }
        let descriptor = socket(info.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw SocketError.cannotOpen(errno) }
        // As large as allowed: ask for less and less until the system agrees.
        var wanted = receiveBuffer
        while wanted >= 256 * 1024, setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &wanted, socklen_t(MemoryLayout<Int32>.size)) != 0 { wanted /= 2 }
        var quiet: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &quiet, socklen_t(MemoryLayout<Int32>.size))
        var granted: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &granted, &length)
        guard connect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw SocketError.cannotOpen(code)
        }
        self.descriptor = descriptor
        receiveBufferSize = Int(granted)
        (incoming, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        let thread = Thread { [descriptor, continuation, counter] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = recv(descriptor, &buffer, buffer.count, 0)
                if count > 0 {
                    counter.add()
                    continuation.yield(Data(buffer[0..<count]))
                } else if count < 0, errno == EINTR || errno == ECONNREFUSED {
                    // A refusal is the answer to an earlier datagram, not the end of the socket.
                    continue
                } else {
                    break
                }
            }
            continuation.finish()
        }
        thread.name = "winphone.nano.reader"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func send(_ datagram: Data) async throws {
        // Never after closing: the number may by then belong to another socket or file.
        let (sent, code): (Int, Int32) = lock.withLock {
            guard !closed else { return (0, 0) }
            let sent = datagram.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, datagram.count, 0) }
            return (sent, sent < 0 ? errno : 0)
        }
        guard sent < 0 else { return }
        if code == EPIPE { throw SocketError.blocked }
        // A full send buffer drops the datagram, as any network may; the layers above resend.
        if code != ENOBUFS, code != ECONNREFUSED, code != EAGAIN { throw SocketError.cannotOpen(code) }
    }

    public func close() {
        let already = lock.withLock { () -> Bool in
            defer { closed = true }
            return closed
        }
        guard !already else { return }
        // Wakes the reader, which then ends the stream.
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        continuation.finish()
    }
}

/// Counted on the reading thread, read from anywhere.
final class ReceivedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
