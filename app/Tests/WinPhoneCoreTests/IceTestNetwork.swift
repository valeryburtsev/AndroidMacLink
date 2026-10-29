import Foundation
@testable import WinPhoneCore

/// A small internet for trying the connection-finding code without one: devices behind
/// address translators of the usual kinds, and a server that answers address questions and
/// relays, with the two-step sign-in the real one has. Every address here is made up.
final class IceTestNetwork: @unchecked Sendable {
    /// How a device's router behaves.
    struct Router {
        var publicIP: [UInt8]
        /// A different outside port for every destination: the kind that defeats direct paths.
        var symmetric = false
        /// Lets nothing in at all that was not asked for from that very address and port.
        var strict = true
    }

    final class Socket: IceSocket, @unchecked Sendable {
        let localAddress: IceAddress
        let incoming: AsyncStream<IceDatagram>
        fileprivate let continuation: AsyncStream<IceDatagram>.Continuation
        fileprivate weak var network: IceTestNetwork?
        fileprivate let router: Int?

        fileprivate init(address: IceAddress, router: Int?, network: IceTestNetwork) {
            localAddress = address
            self.router = router
            self.network = network
            (incoming, continuation) = AsyncStream.makeStream(of: IceDatagram.self, bufferingPolicy: .unbounded)
        }

        func send(_ datagram: Data, to address: IceAddress) async throws {
            network?.send(datagram, from: self, to: address)
        }

        func close() { continuation.finish() }
    }

    private struct Mapping: Hashable {
        var router: Int
        var port: UInt16
    }

    static let stunServer = IceAddress(bytes: [20, 0, 0, 1], port: 3478)
    static let relayServer = IceAddress(bytes: [20, 0, 0, 2], port: 3478)
    static let account = (username: "account", password: "secret", realm: "rtcmedia")

    private let lock = NSLock()
    private var routers: [Router] = []
    private var sockets: [Socket] = []
    /// Outside ports of the routers: who is behind each, and whom it has sent to.
    private var mappings: [Mapping: (socket: Socket, destination: IceAddress?, sentTo: Set<IceAddress>)] = [:]
    private var nextPort: UInt16 = 40000
    /// Whether the relay is there at all.
    var relayWorks = true
    /// Datagrams that went through the relay, either way.
    private(set) var relayed = 0

    // The relay's books.
    private struct Allocation {
        var client: IceAddress
        var relayed: IceAddress
        var permitted: Set<[UInt8]> = []
        var channels: [UInt16: IceAddress] = [:]
    }
    private var allocations: [Allocation] = []
    private let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

    func addRouter(_ router: Router) -> Int {
        lock.withLock {
            routers.append(router)
            return routers.count - 1
        }
    }

    /// A device's socket: behind a router, or straight on the internet.
    func socket(at address: IceAddress, behind router: Int? = nil) -> Socket {
        lock.withLock {
            let socket = Socket(address: address, router: router, network: self)
            sockets.append(socket)
            return socket
        }
    }

    // MARK: Delivery

    fileprivate func send(_ datagram: Data, from socket: Socket, to destination: IceAddress) {
        var deliveries: [(Socket, IceDatagram)] = []
        lock.withLock {
            guard let source = outsideAddress(of: socket, toward: destination) else { return }
            route(datagram, from: source, to: destination, into: &deliveries)
        }
        for (socket, datagram) in deliveries { socket.continuation.yield(datagram) }
    }

    /// The address a datagram appears to come from. Nil when it cannot leave.
    private func outsideAddress(of socket: Socket, toward destination: IceAddress) -> IceAddress? {
        guard let index = socket.router else { return socket.localAddress }
        // A neighbour on the same local network is reached as is.
        if sockets.contains(where: { $0.router == index && $0.localAddress == destination }) { return socket.localAddress }
        guard destination.isGlobal else { return nil }
        let router = routers[index]
        let existing = mappings.first { $0.key.router == index && $0.value.socket === socket && (!router.symmetric || $0.value.destination == destination) }
        let key: Mapping
        if let existing {
            key = existing.key
        } else {
            nextPort += 1
            key = Mapping(router: index, port: nextPort)
            mappings[key] = (socket, router.symmetric ? destination : nil, [])
        }
        mappings[key]?.sentTo.insert(destination)
        return IceAddress(bytes: router.publicIP, port: key.port)
    }

    private func route(_ datagram: Data, from source: IceAddress, to destination: IceAddress, into deliveries: inout [(Socket, IceDatagram)]) {
        if destination == IceTestNetwork.stunServer || destination == IceTestNetwork.relayServer {
            serve(datagram, from: source, at: destination, into: &deliveries)
            return
        }
        // To one of the relay's addresses: passed on to its owner, if the sender may.
        if let index = allocations.firstIndex(where: { $0.relayed == destination }) {
            let allocation = allocations[index]
            guard allocation.permitted.contains(source.bytes) else { return }
            relayed += 1
            let wrapped: Data
            if let channel = allocation.channels.first(where: { $0.value == source })?.key {
                wrapped = TurnChannelData.encode(channel: channel, datagram)
            } else {
                var message = StunMessage(method: .data, kind: .indication)
                message.add(StunMessage.Attribute.xorPeerAddress, address: source)
                message.add(StunMessage.Attribute.data, datagram)
                wrapped = message.encoded()
            }
            route(wrapped, from: IceTestNetwork.relayServer, to: allocation.client, into: &deliveries)
            return
        }
        // To a router's outside port.
        if let entry = mappings.first(where: { routers[$0.key.router].publicIP == destination.bytes && $0.key.port == destination.port }) {
            let router = routers[entry.key.router]
            let asked = router.strict ? entry.value.sentTo.contains(source) : entry.value.sentTo.contains { $0.bytes == source.bytes }
            if asked { deliveries.append((entry.value.socket, IceDatagram(data: datagram, source: source))) }
            return
        }
        // To a device as it is: on the same local network, or straight on the internet.
        if let socket = sockets.first(where: { $0.localAddress == destination }) {
            deliveries.append((socket, IceDatagram(data: datagram, source: source)))
        }
    }

    // MARK: The server

    private func serve(_ datagram: Data, from source: IceAddress, at server: IceAddress, into deliveries: inout [(Socket, IceDatagram)]) {
        func reply(_ message: StunMessage, signed: Bool = false) {
            let key = StunMessage.longTermKey(username: IceTestNetwork.account.username, realm: IceTestNetwork.account.realm, password: IceTestNetwork.account.password)
            route(message.encoded(signedWith: signed ? key : nil), from: server, to: source, into: &deliveries)
        }
        // Data on a bound channel.
        if let framed = TurnChannelData.decode(datagram) {
            guard server == IceTestNetwork.relayServer, let allocation = allocations.first(where: { $0.client == source }), let peer = allocation.channels[framed.channel] else { return }
            relayed += 1
            route(framed.payload, from: allocation.relayed, to: peer, into: &deliveries)
            return
        }
        guard let message = StunMessage(datagram) else { return }
        func refuse(_ code: Int, _ extra: (inout StunMessage) -> Void = { _ in }) {
            var answer = StunMessage(method: message.method, kind: .error, transaction: message.transaction)
            if let counter = message.value(StunMessage.Attribute.transmitCounter) { answer.add(StunMessage.Attribute.transmitCounter, counter) }
            answer.add(StunMessage.Attribute.errorCode, Data([0, 0, UInt8(code / 100), UInt8(code % 100)]))
            extra(&answer)
            reply(answer)
        }
        func accept(signed: Bool = true, _ extra: (inout StunMessage) -> Void = { _ in }) {
            var answer = StunMessage(method: message.method, kind: .success, transaction: message.transaction)
            if let counter = message.value(StunMessage.Attribute.transmitCounter) { answer.add(StunMessage.Attribute.transmitCounter, counter) }
            extra(&answer)
            reply(answer, signed: signed)
        }
        let key = StunMessage.longTermKey(username: IceTestNetwork.account.username, realm: IceTestNetwork.account.realm, password: IceTestNetwork.account.password)
        var knownAccount: Bool {
            message.text(StunMessage.Attribute.username) == IceTestNetwork.account.username && message.value(StunMessage.Attribute.nonce) == nonce && message.isSigned(with: key)
        }
        switch (message.method, message.kind) {
        case (.binding, .request):
            accept(signed: false) { $0.add(StunMessage.Attribute.xorMappedAddress, address: source) }
        case (.allocate, .request):
            guard relayWorks else { return }
            // The first server sends everyone on to the second, as the real one does.
            if server == IceTestNetwork.stunServer {
                refuse(300) {
                    $0.add(StunMessage.Attribute.nonce, self.nonce)
                    $0.add(StunMessage.Attribute.realm, text: IceTestNetwork.account.realm)
                    $0.add(StunMessage.Attribute.alternateServer, address: IceTestNetwork.relayServer, plain: true)
                }
                return
            }
            guard knownAccount else {
                refuse(401) {
                    $0.add(StunMessage.Attribute.nonce, self.nonce)
                    $0.add(StunMessage.Attribute.realm, text: IceTestNetwork.account.realm)
                }
                return
            }
            nextPort += 1
            let allocation = Allocation(client: source, relayed: IceAddress(bytes: IceTestNetwork.relayServer.bytes, port: nextPort))
            allocations.removeAll { $0.client == source }
            allocations.append(allocation)
            accept {
                $0.add(StunMessage.Attribute.lifetime, number: 600)
                $0.add(StunMessage.Attribute.xorMappedAddress, address: source)
                $0.add(StunMessage.Attribute.xorRelayedAddress, address: allocation.relayed)
            }
        case (.createPermission, .request):
            guard knownAccount, let index = allocations.firstIndex(where: { $0.client == source }), let peer = message.address(StunMessage.Attribute.xorPeerAddress) else { return refuse(401) }
            // Nothing is passed on into private ranges.
            guard peer.isGlobal else { return refuse(403) }
            allocations[index].permitted.insert(peer.bytes)
            accept()
        case (.channelBind, .request):
            guard knownAccount, let index = allocations.firstIndex(where: { $0.client == source }), let peer = message.address(StunMessage.Attribute.xorPeerAddress),
                  let number = message.value(StunMessage.Attribute.channelNumber).map({ UInt16($0[$0.startIndex]) << 8 | UInt16($0[$0.startIndex + 1]) }) else { return refuse(401) }
            allocations[index].permitted.insert(peer.bytes)
            allocations[index].channels[number] = peer
            accept()
        case (.refresh, .request):
            guard knownAccount else { return refuse(401) }
            if message.number(StunMessage.Attribute.lifetime) == 0 { allocations.removeAll { $0.client == source } }
            accept { $0.add(StunMessage.Attribute.lifetime, number: 600) }
        case (.send, .indication):
            guard let allocation = allocations.first(where: { $0.client == source }), let peer = message.address(StunMessage.Attribute.xorPeerAddress),
                  let payload = message.value(StunMessage.Attribute.data), allocation.permitted.contains(peer.bytes) else { return }
            relayed += 1
            route(payload, from: allocation.relayed, to: peer, into: &deliveries)
        default:
            break
        }
    }

    var allocationCount: Int { lock.withLock { allocations.count } }
    var relayedCount: Int { lock.withLock { relayed } }
}
