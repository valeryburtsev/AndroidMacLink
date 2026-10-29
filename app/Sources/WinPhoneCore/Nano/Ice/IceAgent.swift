import Foundation

/// Finds a way for datagrams between this device and the phone when they are not on one
/// network: gathers this side's candidates, checks them against the phone's, picks the best
/// pair that works, and then carries the connection's datagrams over it, through a relay
/// server if nothing shorter works. `protocol/specs/nano-ice.md`.
///
/// The computer is the "controlling" side, as Phone Link is: it decides which pair is used.
/// The other role exists so that two of these can be tried against each other.
///
/// Never logs an address: only what kind it is.
public actor IceAgent {
    public enum Role: Sendable { case controlling, controlled }

    public enum IceError: Error, Equatable {
        /// No pair of addresses worked in time.
        case noPath
        case closed
    }

    public struct Settings: Sendable {
        /// Between the starts of two checks.
        public var pacing: Duration = .milliseconds(50)
        /// How long the first send of a request waits for its answer; doubled for each resend.
        public var firstTimeout: Duration = .milliseconds(200)
        public var attempts = 5
        /// After the first pair works, how long better ones get before the choice is made.
        public var nominationDelay: Duration = .seconds(1)
        public var timeout: Duration = .seconds(12)
        public var software = "libnano"
        /// How often a relay in use is told to keep going. The server grants ten minutes.
        public var refreshEvery: Duration = .seconds(240)
        /// Use nothing but the relay, for trying the relay itself.
        public var onlyRelayed = false
        public init() {}
    }

    /// The helping servers, as addresses.
    public struct Servers: Sendable {
        public var stun: IceAddress?
        public var turn: IceAddress?
        public var username: String
        public var password: String

        public init(stun: IceAddress?, turn: IceAddress?, username: String = "", password: String = "") {
            self.stun = stun
            self.turn = turn
            self.username = username
            self.password = password
        }
    }

    /// How a datagram gets to the phone: straight from the socket, or through the relay.
    public enum Route: Hashable, Sendable {
        case direct(IceAddress)
        case relayed(IceAddress)

        var peer: IceAddress {
            switch self {
            case .direct(let address), .relayed(let address): return address
            }
        }
        var name: String {
            switch self {
            case .direct(let address): return "direct to \(address.kind)"
            case .relayed(let address): return "relayed to \(address.kind)"
            }
        }
    }

    private enum PairState { case checking, valid, failed }

    private struct Relay {
        var server: IceAddress
        var relayed: IceAddress
        var realm: String
        var nonce: Data
        var key: Data
    }

    private let socket: IceSocket
    private let role: Role
    private let settings: Settings
    private let servers: Servers?
    private let tieBreaker = Data((0..<8).map { _ in UInt8.random(in: 0...255) })

    public private(set) var local = IceDescription()
    private var remote: IceDescription?
    private var reflexive: IceAddress?
    private var relay: Relay?

    private var pairs: [Route: PairState] = [:]
    /// Routes checks arrived on before the phone's description was known.
    private var early: [Route] = []
    private var pending: [Data: (token: Int, waiter: CheckedContinuation<StunMessage?, Never>)] = [:]
    private var nextToken = 0
    private var permitted: Set<[UInt8]> = []
    private var permissionTasks: [[UInt8]: Task<Bool, Never>] = [:]
    private var channels: [IceAddress: UInt16] = [:]
    private var nextChannel: UInt16 = 0x4000

    public private(set) var selected: Route?
    private var selectionWaiters: [CheckedContinuation<Route?, Never>] = []
    private var nomination: Task<Void, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var closed = false

    private let dataContinuation: AsyncStream<Data>.Continuation
    private let dataStream: AsyncStream<Data>

    public init(socket: IceSocket, role: Role = .controlling, servers: Servers?, settings: Settings = Settings()) {
        self.socket = socket
        self.role = role
        self.servers = servers
        self.settings = settings
        (dataStream, dataContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    // MARK: Gathering

    /// Finds this side's candidates: the socket's own address, that address as the internet
    /// sees it, and one on the relay server. Fills `local`.
    public func gather() async {
        startReceiving()
        let host = socket.localAddress
        var candidates = [IceCandidate(address: host, kind: .host, priority: IceCandidate.priority(kind: .host, order: 0))]
        if let stun = servers?.stun {
            let answer = await transact(to: .direct(stun), key: nil, attempts: 3) { transaction, attempt in
                var message = StunMessage(method: .binding, kind: .request, transaction: transaction)
                message.add(StunMessage.Attribute.software, text: self.settings.software)
                message.add(StunMessage.Attribute.transmitCounter, IceAgent.counter(attempt))
                return message
            }
            if let answer, answer.kind == .success, let mapped = answer.address(StunMessage.Attribute.xorMappedAddress) {
                reflexive = mapped
                if mapped != host {
                    candidates.append(IceCandidate(address: mapped, base: host, kind: .reflexive, priority: IceCandidate.priority(kind: .reflexive, order: 1), serverAddress: stun))
                }
            }
        }
        if let servers, let turn = servers.turn, !servers.username.isEmpty, let allocated = await allocate(at: turn, servers) {
            candidates.append(IceCandidate(address: allocated.relayed, base: host, kind: .relay, priority: IceCandidate.priority(kind: .relay, order: 2),
                                           natAddress: allocated.mapped ?? reflexive, serverAddress: turn))
        }
        local.candidates = candidates
        diag("ice", "gathered \(candidates.count) candidates: own \(host.kind), seen from outside \(reflexive.map(\.kind) ?? "no"), relay \(relay == nil ? "no" : "yes")")
    }

    /// Asks the relay server for an address. The server first says who it is and, usually,
    /// names another server to ask; the second request is signed.
    private func allocate(at first: IceAddress, _ servers: Servers) async -> (relayed: IceAddress, mapped: IceAddress?)? {
        var server = first
        var realm: String?
        var nonce: Data?
        for _ in 0..<5 {
            let key = realm.map { StunMessage.longTermKey(username: servers.username, realm: $0, password: servers.password) }
            let answer = await transact(to: .direct(server), key: key, attempts: 3) { transaction, attempt in
                var message = StunMessage(method: .allocate, kind: .request, transaction: transaction)
                message.add(StunMessage.Attribute.software, text: self.settings.software)
                if let realm, let nonce {
                    message.add(StunMessage.Attribute.username, text: servers.username)
                    message.add(StunMessage.Attribute.realm, text: realm)
                    message.add(StunMessage.Attribute.nonce, nonce)
                }
                // Datagrams, an hour, unfragmented, IPv4: byte for byte as the library asks.
                message.add(StunMessage.Attribute.requestedTransport, Data([0x11, 0, 0, 0]))
                message.add(StunMessage.Attribute.lifetime, number: 3600)
                message.add(StunMessage.Attribute.dontFragment)
                message.add(StunMessage.Attribute.requestedAddressFamily, Data([0, 0, 0, 1]))
                message.add(StunMessage.Attribute.sessionId, text: "00000000-0000-0000-0000-000000000000")
                message.add(StunMessage.Attribute.transmitCounter, IceAgent.counter(attempt))
                return message
            }
            guard let answer else {
                diag("ice", "the relay server did not answer")
                return nil
            }
            if answer.kind == .success, let relayed = answer.address(StunMessage.Attribute.xorRelayedAddress), let realm, let nonce, let key {
                relay = Relay(server: server, relayed: relayed, realm: realm, nonce: nonce, key: key)
                return (relayed, answer.address(StunMessage.Attribute.xorMappedAddress))
            }
            guard answer.kind == .error, let code = answer.errorCode else { return nil }
            realm = answer.text(StunMessage.Attribute.realm) ?? realm
            nonce = answer.value(StunMessage.Attribute.nonce) ?? nonce
            switch code {
            case 300:
                guard let other = answer.address(StunMessage.Attribute.alternateServer), other.isIPv4 else { return nil }
                server = other
            case 401, 438:
                guard realm != nil, nonce != nil else { return nil }
            default:
                diag("ice", "the relay server refused an address: \(code)")
                return nil
            }
        }
        return nil
    }

    // MARK: Connecting

    /// Checks this side's candidates against the phone's and settles on a pair.
    /// - Returns: The path, as something a Nano connection can run on.
    public func connect(to remote: IceDescription) async throws -> IceTransport {
        guard !closed else { throw IceError.closed }
        startReceiving()
        self.remote = remote
        var routes: [Route] = []
        for candidate in remote.candidates where candidate.address.isIPv4 && !candidate.address.isLoopback && candidate.address.port != 0 {
            if !settings.onlyRelayed, !routes.contains(.direct(candidate.address)) { routes.append(.direct(candidate.address)) }
            // The relay server passes nothing on to addresses that are not public.
            if relay != nil, candidate.address.isGlobal, !routes.contains(.relayed(candidate.address)) { routes.append(.relayed(candidate.address)) }
        }
        for route in early where !routes.contains(route) && wanted(route) { routes.append(route) }
        early = []
        routes.sort { rank($0) > rank($1) }
        diag("ice", "checking \(routes.count) pairs against \(remote.candidates.count) candidates of the phone (\(remote.candidates.map { "\($0.kind) \($0.address.kind)" }.joined(separator: ", ")))")
        tasks.append(Task { [settings] in
            for route in routes {
                self.startCheck(route)
                try? await Task.sleep(for: settings.pacing)
            }
        })
        let limit = Task { [settings] in
            try? await Task.sleep(for: settings.timeout)
            if !Task.isCancelled { self.giveUp() }
        }
        defer { limit.cancel() }
        let chosen: Route? = await withCheckedContinuation { waiter in
            if let selected { waiter.resume(returning: selected) } else if closed { waiter.resume(returning: nil) } else { selectionWaiters.append(waiter) }
        }
        guard chosen != nil else {
            diag("ice", "no pair worked: \(pairs.map { "\($0.key.name) \($0.value)" }.sorted().joined(separator: "; "))")
            throw closed ? IceError.closed : IceError.noPath
        }
        return IceTransport(agent: self, incoming: dataStream)
    }

    private func wanted(_ route: Route) -> Bool {
        if case .direct = route { return !settings.onlyRelayed }
        return true
    }

    private func giveUp() {
        guard selected == nil else { return }
        for waiter in selectionWaiters { waiter.resume(returning: nil) }
        selectionWaiters = []
    }

    private func startCheck(_ route: Route) {
        guard pairs[route] == nil, !closed, selected == nil else { return }
        pairs[route] = .checking
        tasks.append(Task {
            let works = await self.check(route)
            self.finished(route, works)
        })
    }

    private func finished(_ route: Route, _ works: Bool) {
        guard pairs[route] == .checking else { return }
        pairs[route] = works ? .valid : .failed
        guard works else { return }
        diag("ice", "a pair works: \(route.name)")
        // A relayed pair gets a channel: less to send with every datagram.
        if case .relayed(let peer) = route { tasks.append(Task { await self.bindChannel(peer) }) }
        if role == .controlling, nomination == nil, selected == nil {
            nomination = Task { [settings] in
                try? await Task.sleep(for: settings.nominationDelay)
                await self.nominate()
            }
        }
    }

    /// The controlling side's choice: the best pair that works, confirmed by one more check
    /// that says "this one".
    private func nominate() async {
        while selected == nil, !closed {
            guard let best = pairs.filter({ $0.value == .valid }).keys.max(by: { rank($0) < rank($1) }) else {
                nomination = nil
                return
            }
            if await check(best, nominating: true) {
                select(best)
                return
            }
            pairs[best] = .failed
        }
    }

    private func select(_ route: Route) {
        guard selected == nil, !closed else { return }
        selected = route
        diag("ice", "path chosen: \(route.name)")
        for waiter in selectionWaiters { waiter.resume(returning: route) }
        selectionWaiters = []
        if case .relayed(let peer) = route {
            tasks.append(Task { [settings] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: settings.refreshEvery)
                    if Task.isCancelled { return }
                    await self.keepRelay(for: peer)
                }
            })
        }
    }

    /// How good a pair is: the standard's formula over the two candidates' priorities, so
    /// that both sides order alike.
    private func rank(_ route: Route) -> UInt64 {
        let own: UInt32
        switch route {
        case .direct: own = IceCandidate.priority(kind: .host, order: 0)
        case .relayed: own = IceCandidate.priority(kind: .relay, order: 2)
        }
        let theirs = remote?.candidates.first { $0.address == route.peer }?.priority ?? IceCandidate.priority(kind: .peerReflexive, order: 0)
        let controlling = role == .controlling ? own : theirs
        let controlled = role == .controlling ? theirs : own
        return UInt64(min(controlling, controlled)) << 32 | UInt64(max(controlling, controlled)) << 1 | (controlling > controlled ? 1 : 0)
    }

    /// One connectivity check: a signed question to the phone over a route, answered or not.
    private func check(_ route: Route, nominating: Bool = false) async -> Bool {
        guard let remote else { return false }
        if case .relayed(let peer) = route {
            guard await permit(peer) else { return false }
        }
        let key = Data(remote.password.utf8)
        // What this side's address would rank as if the phone learns it from this check.
        let priority: UInt32
        switch route {
        case .direct: priority = IceCandidate.priority(kind: reflexive == nil ? .host : .reflexive, order: 1)
        case .relayed: priority = IceCandidate.priority(kind: .relay, order: 2)
        }
        let answer = await transact(to: route, key: key, attempts: settings.attempts) { transaction, attempt in
            var message = StunMessage(method: .binding, kind: .request, transaction: transaction)
            message.add(StunMessage.Attribute.software, text: self.settings.software)
            message.add(StunMessage.Attribute.username, text: "\(remote.username):\(self.local.username)")
            message.add(self.role == .controlling ? StunMessage.Attribute.iceControlling : StunMessage.Attribute.iceControlled, self.tieBreaker)
            message.add(StunMessage.Attribute.priority, number: priority)
            if nominating { message.add(StunMessage.Attribute.useCandidate) }
            message.add(StunMessage.Attribute.transmitCounter, IceAgent.counter(attempt))
            return message
        }
        guard let answer, answer.kind == .success else { return false }
        return answer.isSigned(with: key)
    }

    /// Answers the phone's check, and learns from it: a route nobody announced, or, on the
    /// controlled side, the other side's choice.
    private func answerCheck(_ message: StunMessage, _ route: Route) async {
        let key = Data(local.password.utf8)
        guard let username = message.text(StunMessage.Attribute.username), username.hasPrefix(local.username + ":"), message.isSigned(with: key) else { return }
        var answer = StunMessage(method: .binding, kind: .success, transaction: message.transaction)
        answer.add(StunMessage.Attribute.mappedAddress, address: route.peer, plain: true)
        answer.add(StunMessage.Attribute.xorMappedAddress, address: route.peer)
        if let counter = message.value(StunMessage.Attribute.transmitCounter) { answer.add(StunMessage.Attribute.transmitCounter, counter) }
        await send(answer.encoded(signedWith: key), over: route)
        if remote == nil {
            if !early.contains(route) { early.append(route) }
        } else if pairs[route] == nil, wanted(route) {
            startCheck(route)
        }
        if role == .controlled, message.value(StunMessage.Attribute.useCandidate) != nil {
            pairs[route] = .valid
            select(route)
        }
    }

    // MARK: The relay

    /// A request to the relay server, signed with the account, repeated once when the server
    /// says its nonce has grown old.
    private func relayRequest(_ method: StunMessage.Method, _ fill: (inout StunMessage) -> Void) async -> StunMessage? {
        for _ in 0..<2 {
            guard let relay, let servers else { return nil }
            let answer = await transact(to: .direct(relay.server), key: relay.key, attempts: 3) { transaction, attempt in
                var message = StunMessage(method: method, kind: .request, transaction: transaction)
                message.add(StunMessage.Attribute.software, text: self.settings.software)
                message.add(StunMessage.Attribute.username, text: servers.username)
                message.add(StunMessage.Attribute.realm, text: relay.realm)
                message.add(StunMessage.Attribute.nonce, relay.nonce)
                fill(&message)
                message.add(StunMessage.Attribute.transmitCounter, IceAgent.counter(attempt))
                return message
            }
            guard let answer else { return nil }
            if answer.kind == .error, let code = answer.errorCode, code == 438 || code == 401, let nonce = answer.value(StunMessage.Attribute.nonce) {
                self.relay?.nonce = nonce
                continue
            }
            return answer
        }
        return nil
    }

    /// Lets the phone's address send to this side's relay address. One request per address,
    /// however many checks wait for it.
    private func permit(_ peer: IceAddress) async -> Bool {
        if permitted.contains(peer.bytes) { return true }
        if let running = permissionTasks[peer.bytes] { return await running.value }
        let task = Task { await self.requestPermission(peer) }
        permissionTasks[peer.bytes] = task
        let allowed = await task.value
        permissionTasks[peer.bytes] = nil
        if allowed { permitted.insert(peer.bytes) }
        return allowed
    }

    private func requestPermission(_ peer: IceAddress) async -> Bool {
        let answer = await relayRequest(.createPermission) { message in
            message.add(StunMessage.Attribute.xorPeerAddress, address: IceAddress(bytes: peer.bytes, port: 0))
        }
        return answer?.kind == .success
    }

    private func bindChannel(_ peer: IceAddress) async {
        guard channels[peer] == nil, relay != nil else { return }
        let number = nextChannel
        nextChannel += 1
        let answer = await relayRequest(.channelBind) { message in
            message.add(StunMessage.Attribute.channelNumber, Data([UInt8(number >> 8), UInt8(number & 0xFF), 0, 0]))
            message.add(StunMessage.Attribute.xorPeerAddress, address: peer)
        }
        if answer?.kind == .success { channels[peer] = number }
    }

    /// Keeps a relay in use alive: the address, the phone's leave to use it, the channel.
    private func keepRelay(for peer: IceAddress) async {
        let refreshed = await relayRequest(.refresh) { $0.add(StunMessage.Attribute.lifetime, number: 600) }
        _ = await requestPermission(peer)
        if let number = channels[peer] {
            _ = await relayRequest(.channelBind) { message in
                message.add(StunMessage.Attribute.channelNumber, Data([UInt8(number >> 8), UInt8(number & 0xFF), 0, 0]))
                message.add(StunMessage.Attribute.xorPeerAddress, address: peer)
            }
        }
        if refreshed?.kind != .success { diag("ice", "the relay did not confirm being kept") }
    }

    // MARK: Sending and receiving

    static func counter(_ attempt: Int) -> Data { Data([0, 0, UInt8(clamping: attempt), 0]) }

    /// Sends a request until it is answered or the tries run out. The same transaction each
    /// time; only the count of sends in it changes.
    private func transact(to route: Route, key: Data?, attempts: Int, _ build: (_ transaction: Data, _ attempt: Int) -> StunMessage) async -> StunMessage? {
        let transaction = StunMessage.newTransaction()
        var wait = settings.firstTimeout
        for attempt in 1...max(1, attempts) {
            guard !closed else { return nil }
            await send(build(transaction, attempt).encoded(signedWith: key), over: route)
            nextToken += 1
            let token = nextToken
            let answer: StunMessage? = await withCheckedContinuation { waiter in
                pending[transaction] = (token, waiter)
                Task { [wait] in
                    try? await Task.sleep(for: wait)
                    self.expire(transaction, token)
                }
            }
            if let answer { return answer }
            wait *= 2
        }
        return nil
    }

    private func expire(_ transaction: Data, _ token: Int) {
        guard let entry = pending[transaction], entry.token == token else { return }
        pending[transaction] = nil
        entry.waiter.resume(returning: nil)
    }

    private func settle(_ message: StunMessage) {
        guard let entry = pending.removeValue(forKey: message.transaction) else { return }
        entry.waiter.resume(returning: message)
    }

    private func send(_ datagram: Data, over route: Route) async {
        switch route {
        case .direct(let address):
            try? await socket.send(datagram, to: address)
        case .relayed(let peer):
            guard let relay else { return }
            if let channel = channels[peer] {
                try? await socket.send(TurnChannelData.encode(channel: channel, datagram), to: relay.server)
            } else {
                var message = StunMessage(method: .send, kind: .indication)
                message.add(StunMessage.Attribute.data, datagram)
                message.add(StunMessage.Attribute.xorPeerAddress, address: peer)
                message.add(StunMessage.Attribute.dontFragment)
                try? await socket.send(message.encoded(), to: relay.server)
            }
        }
    }

    /// A datagram of the connection that runs over the chosen path.
    public func sendData(_ datagram: Data) async throws {
        guard let selected, !closed else { throw IceError.closed }
        await send(datagram, over: selected)
    }

    private var receiving = false

    private func startReceiving() {
        guard !receiving else { return }
        receiving = true
        tasks.append(Task { [socket] in
            for await datagram in socket.incoming { await self.received(datagram) }
            self.close()
        })
    }

    private func received(_ datagram: IceDatagram) async {
        if let relay, datagram.source == relay.server {
            if let framed = TurnChannelData.decode(datagram.data) {
                guard let peer = channels.first(where: { $0.value == framed.channel })?.key else { return }
                await arrived(framed.payload, over: .relayed(peer))
            } else if let message = StunMessage(datagram.data) {
                if message.method == .data, message.kind == .indication {
                    guard let peer = message.address(StunMessage.Attribute.xorPeerAddress), let payload = message.value(StunMessage.Attribute.data) else { return }
                    await arrived(payload, over: .relayed(peer))
                } else {
                    settle(message)
                }
            }
            return
        }
        await arrived(datagram.data, over: .direct(datagram.source))
    }

    private func arrived(_ payload: Data, over route: Route) async {
        if let message = StunMessage(payload) {
            switch message.kind {
            case .request: if message.method == .binding { await answerCheck(message, route) }
            case .success, .error: settle(message)
            case .indication: break
            }
            return
        }
        // Anything else is the connection's own, once there is a path for it.
        guard selected != nil else { return }
        dataContinuation.yield(payload)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        // The relay address is given back rather than left to run out.
        if let relay, let servers {
            var message = StunMessage(method: .refresh, kind: .request)
            message.add(StunMessage.Attribute.software, text: settings.software)
            message.add(StunMessage.Attribute.username, text: servers.username)
            message.add(StunMessage.Attribute.realm, text: relay.realm)
            message.add(StunMessage.Attribute.nonce, relay.nonce)
            message.add(StunMessage.Attribute.lifetime, number: 0)
            message.add(StunMessage.Attribute.transmitCounter, IceAgent.counter(1))
            let bytes = message.encoded(signedWith: relay.key)
            let socket = socket
            Task {
                try? await socket.send(bytes, to: relay.server)
                socket.close()
            }
        } else {
            socket.close()
        }
        nomination?.cancel()
        for task in tasks { task.cancel() }
        tasks = []
        for entry in pending.values { entry.waiter.resume(returning: nil) }
        pending = [:]
        for waiter in selectionWaiters { waiter.resume(returning: nil) }
        selectionWaiters = []
        dataContinuation.finish()
    }
}

/// The chosen path as a Nano connection sees it: datagrams out, datagrams in.
public final class IceTransport: NanoDatagramTransport, @unchecked Sendable {
    private let agent: IceAgent
    public let incoming: AsyncStream<Data>

    init(agent: IceAgent, incoming: AsyncStream<Data>) {
        self.agent = agent
        self.incoming = incoming
    }

    public func send(_ datagram: Data) async throws {
        try await agent.sendData(datagram)
    }

    public func close() {
        Task { await agent.close() }
    }
}
