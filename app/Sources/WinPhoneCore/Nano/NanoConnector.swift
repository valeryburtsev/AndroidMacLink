import Foundation

/// The networks this computer is on, to tell whether one of the phone's addresses is a
/// neighbour that can be reached as it is.
public enum LocalNetworks {
    /// Address and mask of every IPv4 interface that is up, loopback aside.
    public static func current() -> [(address: [UInt8], mask: [UInt8])] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(address: [UInt8], mask: [UInt8])] = []
        var entry: UnsafeMutablePointer<ifaddrs>? = first
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = current.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = current.pointee.ifa_netmask else { continue }
            func bytes(_ pointer: UnsafeMutablePointer<sockaddr>) -> [UInt8] {
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
            }
            found.append((bytes(address), bytes(mask)))
        }
        return found
    }

    /// Whether a numeric IPv4 address lies in one of the networks.
    public static func isNeighbour(_ host: String, among networks: [(address: [UInt8], mask: [UInt8])] = current()) -> Bool {
        guard let address = IceAddress(text: host + ":1"), address.isIPv4 else { return false }
        return networks.contains { network in
            network.mask != [255, 255, 255, 255] && network.mask != [0, 0, 0, 0]
                && zip(zip(address.bytes, network.address), network.mask).allSatisfy { $0.0 & $1 == $0.1 & $1 }
        }
    }
}

/// Opens a Nano connection to the phone whichever way works: straight to its address when the
/// two are on one network, else by the candidates-and-relay procedure of `IceAgent`. Each way
/// starts with its own request to the phone on the Phone Link session.
public struct NanoConnector: Sendable {
    /// Opens UDP to an address on the same network; replaced in tests.
    public var makeTransport: @Sendable (_ host: String, _ port: UInt16) async throws -> NanoDatagramTransport
    /// The helping servers and the relay account, asked for when the direct way is no use.
    /// Nil where only the same network is to be tried.
    public var relayServers: (@Sendable () async -> NanoRelayServers?)?
    public var iceSettings = IceAgent.Settings()
    public var makeIceSocket: @Sendable (IceAddress?) throws -> IceSocket = { try IceUDPSocket(toward: $0) }
    public var resolve: @Sendable (String) async -> IceAddress? = { await IceUDPSocket.resolve($0) }
    /// Which of the phone's addresses are neighbours; replaced in tests.
    public var isNeighbour: @Sendable (String) -> Bool = { LocalNetworks.isNeighbour($0) }

    public init(makeTransport: @escaping @Sendable (_ host: String, _ port: UInt16) async throws -> NanoDatagramTransport = { host, port in
        try NanoSocketTransport(host: host, port: port)
    }, relayServers: (@Sendable () async -> NanoRelayServers?)? = nil) {
        self.makeTransport = makeTransport
        self.relayServers = relayServers
    }

    /// How the connection was made, for the log and for what the user is told.
    public enum Way: Equatable, Sendable { case sameNetwork, internet }

    /// - Parameters:
    ///   - workflow: what the connection is first wanted for: `fileTransfer`, or `permission`
    ///     when the phone's screen is to be shown.
    ///   - tag: the log's name for whoever asks.
    public func open(messenger: PeerMessenger, sender: AppSender, workflow: String, transferId: String, settings: NanoConnection.Settings,
                     tag: String) async throws -> (connection: NanoConnection, way: Way) {
        let envelope = try await messenger.appRequest(route: PhoneFileReceiver.handshakeRoute,
                                                      payload: PhoneFileReceiver.handshakeRequest(sender: sender, transferId: transferId, workflow: workflow).serialized(),
                                                      timeout: .seconds(40))
        let reply = try ValueSet(serialized: envelope.payload)
        guard let description = reply.string("handshake"), let contract = NanoDirectContract(connectionDescription: description) else {
            diag(tag, "handshake refused: result \(reply.int("result").map(String.init) ?? "none"), reason \(reply.string("rejectReason") ?? "none"), keys \(reply.entries.keys.sorted().joined(separator: ","))")
            throw NanoSignalling.SignallingError.refused(reply.string("rejectReason") ?? "no connection description")
        }
        // With another way at hand, only addresses that can be neighbours are worth the ten
        // seconds a silent one costs.
        let direct = relayServers == nil ? contract.candidates : contract.candidates.filter(isNeighbour)
        diag(tag, "the phone listens on \(contract.addresses.map(\.interface).joined(separator: ",")); \(direct.count) of its addresses are on this network")
        for host in direct {
            do {
                let connection = try await PhoneFileReceiver.open(host: host, port: contract.port, keys: contract.keys, settings: settings, makeTransport: makeTransport)
                diag(tag, "direct connection open")
                return (connection, .sameNetwork)
            } catch NanoConnection.ConnectionError.noAnswer {
                // This address did not answer; the phone may have another.
                continue
            }
        }
        guard let relayServers else { throw NanoConnection.ConnectionError.noAnswer }
        guard let servers = await relayServers() else {
            diag(tag, "no helping servers to be had for a connection over the internet")
            throw NanoConnection.ConnectionError.noAnswer
        }
        diag(tag, "not on one network; trying over the internet")
        return (try await openOverInternet(messenger: messenger, sender: sender, workflow: workflow, transferId: transferId, settings: settings, servers: servers, tag: tag), .internet)
    }

    private func openOverInternet(messenger: PeerMessenger, sender: AppSender, workflow: String, transferId: String, settings: NanoConnection.Settings,
                                  servers: NanoRelayServers, tag: String) async throws -> NanoConnection {
        let stun = await resolve(servers.stun)
        let turn = await resolve(servers.turn)
        guard stun != nil || turn != nil else {
            diag(tag, "the helping servers could not be looked up")
            throw NanoConnection.ConnectionError.noAnswer
        }
        let agent = IceAgent(socket: try makeIceSocket(stun ?? turn),
                             servers: IceAgent.Servers(stun: stun, turn: turn, username: servers.username, password: servers.password), settings: iceSettings)
        do {
            await agent.gather()
            // On this way the computer makes the key and sends it with its candidates.
            let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            let salt = Data((0..<14).map { _ in UInt8.random(in: 0...255) })
            let keys = try NanoSessionKeys(keyHex: NanoConnector.hex(key), saltHex: NanoConnector.hex(salt))
            let local = await agent.local
            let description = NanoConnector.handshakeDescription(local: local, key: key, salt: salt, servers: servers)
            let envelope = try await messenger.appRequest(route: PhoneFileReceiver.handshakeRoute,
                                                          payload: PhoneFileReceiver.handshakeRequest(sender: sender, transferId: transferId, workflow: workflow, description: description).serialized(),
                                                          timeout: .seconds(40))
            let reply = try ValueSet(serialized: envelope.payload)
            guard let text = reply.string("handshake"), let remote = NanoConnector.remoteDescription(inHandshake: text) else {
                diag(tag, "handshake over the internet refused: result \(reply.int("result").map(String.init) ?? "none"), reason \(reply.string("rejectReason") ?? "none")")
                throw NanoSignalling.SignallingError.refused(reply.string("rejectReason") ?? "no connection description")
            }
            let transport = try await agent.connect(to: remote)
            var settings = settings
            // Room for what a relay adds to every datagram.
            settings.probeSize = min(settings.probeSize, 1100)
            let connection = NanoConnection(transport: transport, keys: keys, settings: settings)
            do {
                try await connection.start()
            } catch {
                await connection.close()
                throw error
            }
            diag(tag, "connection over the internet open")
            return connection
        } catch {
            await agent.close()
            if case IceAgent.IceError.noPath = error { throw NanoConnection.ConnectionError.noAnswer }
            throw error
        }
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// This side's part of a handshake over the internet, in the order the library writes it:
    /// the key, the candidates and servers, then what the phone's connection service reads.
    /// The type says how much help is offered: 1 none, 2 the address server, 3 the relay too.
    static func handshakeDescription(local: IceDescription, key: Data, salt: Data, servers: NanoRelayServers?, instanceId: String = UUID().uuidString.lowercased()) -> String {
        func quoted(_ text: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        let hasRelay = servers.map { !$0.username.isEmpty } ?? false
        let type = hasRelay ? 3 : servers == nil ? 1 : 2
        let turn = hasRelay ? servers : nil
        return "{\"security\":{\"key\":\"\(hex(key))\",\"salt\":\"\(hex(salt))\"},"
            + "\"ice\":{\"candidates\":\(quoted(local.text)),\"stun\":{\"url\":\(quoted(servers?.stun ?? ""))},"
            + "\"turn\":{\"url\":\(quoted(turn?.turn ?? "")),\"username\":\(quoted(turn?.username ?? "")),\"password\":\(quoted(turn?.password ?? ""))}},"
            + "\"contractVersion\":{\"versionMin\":6,\"versionMax\":6},\"settings\":{\"connectionType\":\(type)},\"instanceId\":\"\(instanceId)\",\"multipleConnections\":true}"
    }

    /// The phone's candidates from its answer.
    static func remoteDescription(inHandshake text: String) -> IceDescription? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        let info = object["connectioninformation"] as? [String: Any] ?? object
        return ((info["ice"] as? [String: Any])?["candidates"] as? String).flatMap(IceDescription.init(text:))
    }
}
