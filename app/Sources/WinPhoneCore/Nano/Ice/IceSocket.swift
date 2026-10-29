import Foundation

/// A datagram and where it came from.
public struct IceDatagram: Sendable {
    public var data: Data
    public var source: IceAddress

    public init(data: Data, source: IceAddress) {
        self.data = data
        self.source = source
    }
}

/// A UDP socket that talks to many addresses: the phone's candidates and the servers.
public protocol IceSocket: Sendable {
    /// The device's own address and the port the socket has: the "host" candidate.
    var localAddress: IceAddress { get }
    func send(_ datagram: Data, to address: IceAddress) async throws
    var incoming: AsyncStream<IceDatagram> { get }
    func close()
}

/// The real thing: an IPv4 socket with a large receive buffer and a reader thread of its own,
/// as `NanoSocketTransport` has and for the same reason.
public final class IceUDPSocket: IceSocket, @unchecked Sendable {
    private let descriptor: Int32
    private let continuation: AsyncStream<IceDatagram>.Continuation
    public let incoming: AsyncStream<IceDatagram>
    public let localAddress: IceAddress
    private let lock = NSLock()
    private var closed = false

    /// - Parameter toward: an address on the internet; the device's address on the way there
    ///   is the one worth announcing.
    public init(toward: IceAddress?, receiveBuffer: Int32 = 8 * 1024 * 1024) throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw NanoSocketTransport.SocketError.cannotOpen(errno) }
        var wanted = receiveBuffer
        while wanted >= 256 * 1024, setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &wanted, socklen_t(MemoryLayout<Int32>.size)) != 0 { wanted /= 2 }
        var quiet: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &quiet, socklen_t(MemoryLayout<Int32>.size))
        var any = sockaddr_in()
        any.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        any.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &any) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw NanoSocketTransport.SocketError.cannotOpen(code)
        }
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &name) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        let port = UInt16(bigEndian: name.sin_port)
        localAddress = IceAddress(bytes: IceUDPSocket.localIPv4(toward: toward) ?? [0, 0, 0, 0], port: port)
        self.descriptor = descriptor
        (incoming, continuation) = AsyncStream.makeStream(of: IceDatagram.self, bufferingPolicy: .unbounded)
        let thread = Thread { [descriptor, continuation] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                var from = sockaddr_in()
                var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(descriptor, &buffer, buffer.count, 0, $0, &size) }
                }
                if count > 0 {
                    let source = IceAddress(bytes: withUnsafeBytes(of: &from.sin_addr) { Array($0) }, port: UInt16(bigEndian: from.sin_port))
                    continuation.yield(IceDatagram(data: Data(buffer[0..<count]), source: source))
                } else if count < 0, errno == EINTR || errno == ECONNREFUSED {
                    continue
                } else {
                    break
                }
            }
            continuation.finish()
        }
        thread.name = "winphone.ice.reader"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    public func send(_ datagram: Data, to address: IceAddress) async throws {
        guard address.isIPv4 else { return }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = address.port.bigEndian
        withUnsafeMutableBytes(of: &target.sin_addr) { $0.copyBytes(from: address.bytes) }
        let (sent, code): (Int, Int32) = lock.withLock {
            guard !closed else { return (0, 0) }
            let sent = datagram.withUnsafeBytes { bytes in
                withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(descriptor, bytes.baseAddress, datagram.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            }
            return (sent, sent < 0 ? errno : 0)
        }
        guard sent < 0 else { return }
        if code == EPIPE { throw NanoSocketTransport.SocketError.blocked }
        // An address that cannot be reached from here is one candidate less, not a failure.
        let harmless: Set<Int32> = [ENOBUFS, ECONNREFUSED, EAGAIN, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, EADDRNOTAVAIL, ENETDOWN, EACCES, EPERM]
        if !harmless.contains(code) { throw NanoSocketTransport.SocketError.cannotOpen(code) }
    }

    public func close() {
        let already = lock.withLock { () -> Bool in
            defer { closed = true }
            return closed
        }
        guard !already else { return }
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        continuation.finish()
    }

    /// The device's own IPv4 address on the way to an address: asked of the system by aiming
    /// a socket there, which sends nothing.
    static func localIPv4(toward: IceAddress?) -> [UInt8]? {
        let target = toward.flatMap { $0.isIPv4 ? $0 : nil } ?? IceAddress(bytes: [1, 1, 1, 1], port: 53)
        let probe = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard probe >= 0 else { return nil }
        defer { Darwin.close(probe) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = target.port.bigEndian
        withUnsafeMutableBytes(of: &address.sin_addr) { $0.copyBytes(from: target.bytes) }
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { return nil }
        var name = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &name, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &length) } }) == 0 else { return nil }
        return withUnsafeBytes(of: &name.sin_addr) { Array($0) }
    }

    /// Looks a "host:port" up, IPv4 only. Off the caller's thread: the system's lookup waits.
    public static func resolve(_ hostAndPort: String) async -> IceAddress? {
        if let literal = IceAddress(text: hostAndPort), literal.isIPv4 { return literal }
        guard let colon = hostAndPort.lastIndex(of: ":") else { return nil }
        let host = String(hostAndPort[..<colon])
        let port = String(hostAndPort[hostAndPort.index(after: colon)...])
        return await Task.detached { () -> IceAddress? in
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_DGRAM
            var resolved: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, port, &hints, &resolved) == 0, let info = resolved else { return nil }
            defer { freeaddrinfo(resolved) }
            return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                IceAddress(bytes: withUnsafeBytes(of: pointer.pointee.sin_addr) { Array($0) }, port: UInt16(bigEndian: pointer.pointee.sin_port))
            }
        }.value
    }
}
