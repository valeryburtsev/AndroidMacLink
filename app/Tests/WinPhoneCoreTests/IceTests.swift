import XCTest
@testable import WinPhoneCore

/// Finding a path between two devices on different networks, tried on a made-up internet
/// (`IceTestNetwork`). The computer decides, a stand-in phone follows.
final class IceTests: XCTestCase {
    static var quick: IceAgent.Settings {
        var settings = IceAgent.Settings()
        settings.pacing = .milliseconds(3)
        settings.firstTimeout = .milliseconds(25)
        settings.attempts = 5
        settings.nominationDelay = .milliseconds(120)
        settings.timeout = .seconds(4)
        return settings
    }

    static var servers: IceAgent.Servers {
        IceAgent.Servers(stun: IceTestNetwork.stunServer, turn: IceTestNetwork.stunServer, username: IceTestNetwork.account.username, password: IceTestNetwork.account.password)
    }

    /// Runs both sides to the end: gathering, the exchange of descriptions, the checks.
    func connect(_ mac: IceAgent, _ phone: IceAgent) async throws -> (mac: IceTransport, phone: IceTransport) {
        await mac.gather()
        await phone.gather()
        // The descriptions travel as text, as they do in the handshake.
        let offerText = await mac.local.text
        let answerText = await phone.local.text
        let offer = try XCTUnwrap(IceDescription(text: offerText))
        let answer = try XCTUnwrap(IceDescription(text: answerText))
        async let phoneSide = phone.connect(to: offer)
        async let macSide = mac.connect(to: answer)
        return (try await macSide, try await phoneSide)
    }

    /// A datagram each way over the chosen path.
    func exchange(_ pair: (mac: IceTransport, phone: IceTransport)) async throws {
        let toPhone = Data([0x80, 0x66, 1, 2, 3])
        let toMac = Data([0x80, 0x65, 9, 8, 7, 6])
        try await pair.mac.send(toPhone)
        var atPhone = pair.phone.incoming.makeAsyncIterator()
        let first = await atPhone.next()
        XCTAssertEqual(first, toPhone)
        try await pair.phone.send(toMac)
        var atMac = pair.mac.incoming.makeAsyncIterator()
        let second = await atMac.next()
        XCTAssertEqual(second, toMac)
    }

    func testSameNetworkUsesTheLocalAddresses() async throws {
        let network = IceTestNetwork()
        let home = network.addRouter(.init(publicIP: [30, 0, 0, 1]))
        let mac = IceAgent(socket: network.socket(at: IceAddress(bytes: [192, 168, 1, 10], port: 5000), behind: home), servers: Self.servers, settings: Self.quick)
        let phone = IceAgent(socket: network.socket(at: IceAddress(bytes: [192, 168, 1, 20], port: 6000), behind: home), role: .controlled, servers: Self.servers, settings: Self.quick)
        let pair = try await connect(mac, phone)
        let kinds = await mac.local.candidates.map(\.kind)
        XCTAssertEqual(kinds, [.host, .reflexive, .relay], "own address, the address seen from outside, a relay address")
        let chosen = await mac.selected
        XCTAssertEqual(chosen, .direct(IceAddress(bytes: [192, 168, 1, 20], port: 6000)))
        // The checks try the relay as well; the data does not go that way.
        let before = network.relayedCount
        try await exchange(pair)
        XCTAssertEqual(network.relayedCount, before, "nothing goes the long way round")
        await mac.close()
        await phone.close()
    }

    func testTwoHomeRoutersMeetDirectly() async throws {
        let network = IceTestNetwork()
        let home = network.addRouter(.init(publicIP: [30, 0, 0, 1]))
        let mobile = network.addRouter(.init(publicIP: [40, 0, 0, 1]))
        let mac = IceAgent(socket: network.socket(at: IceAddress(bytes: [192, 168, 1, 10], port: 5000), behind: home), servers: Self.servers, settings: Self.quick)
        let phone = IceAgent(socket: network.socket(at: IceAddress(bytes: [100, 64, 3, 7], port: 6000), behind: mobile), role: .controlled, servers: Self.servers, settings: Self.quick)
        let pair = try await connect(mac, phone)
        guard case .direct(let address)? = await mac.selected else { return XCTFail("expected a direct path") }
        XCTAssertEqual(address.bytes, [40, 0, 0, 1], "the phone as the internet sees it")
        let before = network.relayedCount
        try await exchange(pair)
        XCTAssertEqual(network.relayedCount, before, "the data itself does not touch the relay")
        await mac.close()
        await phone.close()
    }

    /// A carrier that gives every destination its own port cannot be met half-way: only the
    /// relay is left, and the phone's address on it is one nobody announced.
    func testAStrictCarrierIsReachedThroughTheRelay() async throws {
        let network = IceTestNetwork()
        let home = network.addRouter(.init(publicIP: [30, 0, 0, 1], symmetric: true))
        let mobile = network.addRouter(.init(publicIP: [40, 0, 0, 1], symmetric: true))
        let mac = IceAgent(socket: network.socket(at: IceAddress(bytes: [192, 168, 1, 10], port: 5000), behind: home), servers: Self.servers, settings: Self.quick)
        let phone = IceAgent(socket: network.socket(at: IceAddress(bytes: [100, 64, 3, 7], port: 6000), behind: mobile), role: .controlled, servers: Self.servers, settings: Self.quick)
        let pair = try await connect(mac, phone)
        let chosen = try await XCTUnwrapAsync(await mac.selected)
        let viaRelay: Bool
        switch chosen {
        case .relayed: viaRelay = true
        case .direct(let address): viaRelay = address.bytes == IceTestNetwork.relayServer.bytes
        }
        XCTAssertTrue(viaRelay, "one relay or the other is in the path")
        let before = network.relayedCount
        try await exchange(pair)
        XCTAssertGreaterThanOrEqual(network.relayedCount, before + 2, "both datagrams went through it")
        XCTAssertEqual(network.allocationCount, 2)
        await mac.close()
        await phone.close()
        let released = await waitUntil { network.allocationCount == 0 }
        XCTAssertTrue(released, "the relay addresses are given back")
    }

    func testNoWayAtAllEndsWithAnError() async throws {
        let network = IceTestNetwork()
        network.relayWorks = false
        let home = network.addRouter(.init(publicIP: [30, 0, 0, 1], symmetric: true))
        let mobile = network.addRouter(.init(publicIP: [40, 0, 0, 1], symmetric: true))
        var settings = Self.quick
        settings.timeout = .milliseconds(900)
        let mac = IceAgent(socket: network.socket(at: IceAddress(bytes: [192, 168, 1, 10], port: 5000), behind: home), servers: Self.servers, settings: settings)
        let phone = IceAgent(socket: network.socket(at: IceAddress(bytes: [100, 64, 3, 7], port: 6000), behind: mobile), role: .controlled, servers: Self.servers, settings: settings)
        do {
            _ = try await connect(mac, phone)
            XCTFail("expected no path")
        } catch let error as IceAgent.IceError {
            XCTAssertEqual(error, .noPath)
        }
        let kinds = await mac.local.candidates.map(\.kind)
        XCTAssertEqual(kinds, [.host, .reflexive], "no relay address without a relay")
        await mac.close()
        await phone.close()
    }

    // MARK: From the request to a file

    final class Mailbox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?
        func put(_ value: Value) { lock.withLock { if self.value == nil { self.value = value } } }
        func take() async -> Value? {
            for _ in 0..<400 {
                if let value = lock.withLock({ self.value }) { return value }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }
    }

    /// The whole way for a phone on mobile data: the first request shows that it has no
    /// address on this network, the second carries the computer's candidates, key and servers,
    /// a path is found through the made-up internet, and a share arrives over it.
    func testAPhoneOnMobileDataIsReachedOverTheInternetAndItsFilesArrive() async throws {
        let network = IceTestNetwork()
        let home = network.addRouter(.init(publicIP: [30, 0, 0, 1]))
        let mobile = network.addRouter(.init(publicIP: [40, 0, 0, 1], symmetric: true))
        let phoneAgent = IceAgent(socket: network.socket(at: IceAddress(bytes: [100, 64, 3, 7], port: 6000), behind: mobile), role: .controlled, servers: Self.servers, settings: Self.quick)
        await phoneAgent.gather()
        let phoneCandidates = await phoneAgent.local.text
        let quoted = String(String(decoding: try JSONSerialization.data(withJSONObject: [phoneCandidates]), as: UTF8.self).dropFirst().dropLast())

        let relayPhone = FakePhone()
        let offered = Mailbox<String>()
        relayPhone.responder = { envelope in
            guard envelope.route == PhoneFileReceiver.handshakeRoute, let values = try? ValueSet(serialized: envelope.payload), let text = values.string("handshake"),
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let type = ((object["settings"] as? [String: Any])?["connectionType"] as? NSNumber)?.intValue else { return nil }
            if type == 0 {
                // Asked for a direct connection: the phone has only its mobile data address.
                return ValueSet(["result": .int32(0), "handshake": .string(#"{"security":{"key":"000102030405060708090a0b0c0d0e0f","salt":"101112131415161718191a1b1c1d"},"ip":{"0":{"addr":"100.64.3.7","iname":"rmnet6"},"count":"1"},"port":"35249","keepalive":{"warningtimeout":"5000"},"contractVersion":{"versionMin":6,"versionMax":6}}"#)]).serialized()
            }
            offered.put(text)
            return ValueSet(["result": .int32(0), "handshake": .string("{\"ice\":{\"candidates\":\(quoted)},\"keepalive\":{\"warningtimeout\":\"5000\"},\"contractVersion\":{\"versionMin\":6,\"versionMax\":6}}")]).serialized()
        }
        let (messenger, relay) = try await relayPhone.connect()

        let files = [ScriptedNanoPhone.File(id: "aaaa-1", name: "First.pdf", data: Data((0..<7000).map { UInt8(truncatingIfNeeded: $0 &* 7) })),
                     ScriptedNanoPhone.File(id: "bbbb-2", name: "Second.jpg", data: Data((0..<2500).map { UInt8(truncatingIfNeeded: $0 &* 13) }))]
        // The phone's side: once the computer's candidates are in, find the path and play the
        // phone's part of the transfer over it.
        let phoneSide = Task { () -> [String: Any]? in
            guard let text = await offered.take(), let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let security = object["security"] as? [String: Any], let key = security["key"] as? String, let salt = security["salt"] as? String,
                  let keys = try? NanoSessionKeys(keyHex: key, saltHex: salt), let remote = NanoConnector.remoteDescription(inHandshake: text),
                  let path = try? await phoneAgent.connect(to: remote) else { return nil }
            let (inner, outer) = MemoryNanoTransport.pair()
            let phone = ScriptedNanoPhone(transport: inner, keys: keys, files: files)
            await phone.setLegacy(true)
            await phone.run()
            Task { for await datagram in outer.incoming { try? await path.send(datagram) } }
            Task { for await datagram in path.incoming { try? await outer.send(datagram) } }
            return object
        }

        var connector = NanoConnector(relayServers: {
            NanoRelayServers(stun: "20.0.0.1:3478", turn: "20.0.0.1:3478", username: IceTestNetwork.account.username, password: IceTestNetwork.account.password)
        })
        connector.makeIceSocket = { _ in network.socket(at: IceAddress(bytes: [192, 168, 1, 10], port: 5000), behind: home) }
        connector.iceSettings = Self.quick
        var settings = NanoConnection.Settings()
        settings.fillerCount = 10
        settings.handshakeRetry = .milliseconds(200)
        settings.retransmitAfter = .milliseconds(80)
        let opened = try await connector.open(messenger: messenger, sender: AppSender(displayName: "Mac", installationId: "INSTALL"), workflow: "fileTransfer",
                                              transferId: "0123456789abcdef0123456789abcdef", settings: settings, tag: "test")
        XCTAssertEqual(opened.way, .internet)

        let detail = #"{"TransferId":"0123456789abcdef0123456789abcdef","Scenario":"FileTransferToPc","SenderName":"","ReceivedFileCount":0,"SessionTryCount":1,"Content":[{"FileId":"aaaa-1","FileName":"First.pdf","FileSize":7000,"FileHash":"","FileStatus":1},{"FileId":"bbbb-2","FileName":"Second.jpg","FileSize":2500,"FileHash":"","FileStatus":1}]}"#
        let received = try await NanoFileReceiver(connection: opened.connection, senderName: "Test Mac").run(offer: try XCTUnwrap(LegacyFileOffer(json: detail)), timeout: .seconds(10))
        XCTAssertEqual(received.map(\.name), ["First.pdf", "Second.jpg"])
        XCTAssertEqual(received.map(\.data), files.map(\.data))
        XCTAssertGreaterThan(network.relayedCount, 20, "the file went through a relay")

        // What the phone was sent the second time, as Phone Link sends it.
        let sent = try await XCTUnwrapAsync(await phoneSide.value)
        XCTAssertEqual(Array(sent.keys).sorted(), ["contractVersion", "ice", "instanceId", "multipleConnections", "security", "settings"])
        XCTAssertEqual((sent["settings"] as? [String: Any])?["connectionType"] as? Int, 3, "with the address server and the relay")
        let ice = try XCTUnwrap(sent["ice"] as? [String: Any])
        XCTAssertEqual((ice["stun"] as? [String: Any])?["url"] as? String, "20.0.0.1:3478")
        XCTAssertEqual((ice["turn"] as? [String: Any])?["username"] as? String, IceTestNetwork.account.username, "the phone gets the relay account too")
        XCTAssertEqual(((sent["security"] as? [String: Any])?["key"] as? String)?.count, 32)
        XCTAssertEqual(((sent["security"] as? [String: Any])?["salt"] as? String)?.count, 28)
        let requests = try relayPhone.received(route: PhoneFileReceiver.handshakeRoute).map { try ValueSet(serialized: $0.payload) }
        XCTAssertEqual(requests.count, 2, "one request per way")
        XCTAssertEqual(requests.map { $0.string("workflow") }, ["fileTransfer", "fileTransfer"])
        let numbers = requests.compactMap { $0.entries["sequenceNumber"] }
        if case .int64(let first) = numbers[0], case .int64(let second) = numbers[1] { XCTAssertGreaterThan(second, first, "a later request must carry a larger number") } else { XCTFail("sequence numbers") }

        await opened.connection.close()
        await phoneAgent.close()
        await relay.close()
    }

    /// On one network nothing changes: the phone's address there is tried, and no server is
    /// asked for anything.
    func testNeighboursAreToldApartFromStrangers() {
        let networks: [(address: [UInt8], mask: [UInt8])] = [([192, 168, 1, 10], [255, 255, 255, 0]), ([10, 8, 0, 2], [255, 255, 255, 255])]
        XCTAssertTrue(LocalNetworks.isNeighbour("192.168.1.20", among: networks))
        XCTAssertFalse(LocalNetworks.isNeighbour("192.168.2.20", among: networks))
        XCTAssertFalse(LocalNetworks.isNeighbour("100.64.3.7", among: networks))
        XCTAssertFalse(LocalNetworks.isNeighbour("10.8.0.9", among: networks), "a point-to-point link has no neighbours")
        XCTAssertFalse(LocalNetworks.isNeighbour("fe80::1", among: networks))
        XCTAssertFalse(LocalNetworks.isNeighbour("", among: networks))
        // This computer's own networks, where it has any: its own address is a neighbour.
        if let own = LocalNetworks.current().first(where: { $0.mask != [255, 255, 255, 255] }) {
            XCTAssertEqual(own.address.count, 4)
            XCTAssertTrue(LocalNetworks.isNeighbour(own.address.map(String.init).joined(separator: ".")))
        }
        // The description for a phone without servers at hand, and with the address server only.
        let local = IceDescription(username: "abcdefghijkl", password: "pw", candidates: [])
        let plain = NanoConnector.handshakeDescription(local: local, key: Data(repeating: 1, count: 16), salt: Data(repeating: 2, count: 14), servers: nil, instanceId: "i")
        XCTAssertTrue(plain.hasPrefix(#"{"security":{"key":"01010101010101010101010101010101","salt":"0202020202020202020202020202"},"ice":{"candidates":"{\"Full\":\"1\","#))
        XCTAssertTrue(plain.hasSuffix(#""stun":{"url":""},"turn":{"url":"","username":"","password":""}},"contractVersion":{"versionMin":6,"versionMax":6},"settings":{"connectionType":1},"instanceId":"i","multipleConnections":true}"#))
        let addressOnly = NanoConnector.handshakeDescription(local: local, key: Data(count: 16), salt: Data(count: 14), servers: NanoRelayServers(stun: "s:3478", turn: "s:3478", username: "", password: ""), instanceId: "i")
        XCTAssertTrue(addressOnly.contains(#""stun":{"url":"s:3478"},"turn":{"url":"","username":"","password":""}}"#))
        XCTAssertTrue(addressOnly.contains(#""connectionType":2"#))
        XCTAssertEqual(NanoConnector.remoteDescription(inHandshake: plain)?.username, "abcdefghijkl", "reads back what it wrote")
    }

    // MARK: The messages

    func testMessagesReadBackAsWritten() throws {
        let peer = IceAddress(bytes: [203, 0, 113, 7], port: 54321)
        var message = StunMessage(method: .binding, kind: .request)
        message.add(StunMessage.Attribute.software, text: "libnano")
        message.add(StunMessage.Attribute.username, text: "abcdefghijkl:mnopqrstuvwx")
        message.add(StunMessage.Attribute.iceControlling, Data(repeating: 7, count: 8))
        message.add(StunMessage.Attribute.priority, number: 0x64FF_FEFF)
        message.add(StunMessage.Attribute.useCandidate)
        message.add(StunMessage.Attribute.transmitCounter, IceAgent.counter(2))
        message.add(StunMessage.Attribute.xorPeerAddress, address: peer)
        let key = Data("the other side's password".utf8)
        let bytes = message.encoded(signedWith: key)
        XCTAssertEqual(bytes.count % 4, 0)
        XCTAssertEqual(Array(bytes.prefix(2)), [0x00, 0x01], "a binding request")
        XCTAssertTrue(StunMessage.looksLikeStun(bytes))
        let read = try XCTUnwrap(StunMessage(bytes))
        XCTAssertEqual(read.method, .binding)
        XCTAssertEqual(read.kind, .request)
        XCTAssertEqual(read.text(StunMessage.Attribute.software), "libnano", "padding is not part of the value")
        XCTAssertEqual(read.number(StunMessage.Attribute.priority), 0x64FF_FEFF)
        XCTAssertEqual(read.address(StunMessage.Attribute.xorPeerAddress), peer)
        XCTAssertEqual(read.value(StunMessage.Attribute.transmitCounter), Data([0, 0, 2, 0]))
        XCTAssertTrue(read.isSigned(with: key))
        XCTAssertFalse(read.isSigned(with: Data("another password".utf8)))
        var tampered = bytes
        tampered[30] ^= 1
        XCTAssertEqual(StunMessage(tampered)?.isSigned(with: key), false)
        XCTAssertFalse(message.isSigned(with: key), "a message built here has no signature to check")
        // Kinds and methods share the first two bytes in a pattern of their own.
        XCTAssertEqual(Array(StunMessage(method: .allocate, kind: .error).encoded().prefix(2)), [0x01, 0x13])
        XCTAssertEqual(Array(StunMessage(method: .send, kind: .indication).encoded().prefix(2)), [0x00, 0x16])
        XCTAssertEqual(Array(StunMessage(method: .channelBind, kind: .success).encoded().prefix(2)), [0x01, 0x09])
        XCTAssertNil(StunMessage(Data([0x80, 0x66, 0, 0] + [UInt8](repeating: 0, count: 30))), "a packet of the connection is not one of these")
        // A refusal's code.
        var refusal = StunMessage(method: .allocate, kind: .error)
        refusal.add(StunMessage.Attribute.errorCode, Data([0, 0, 4, 38]) + Data("Stale Nonce".utf8))
        XCTAssertEqual(StunMessage(refusal.encoded())?.errorCode, 438)
        // The relay's key: the standard's own example of the calculation.
        XCTAssertEqual(StunMessage.longTermKey(username: "user", realm: "realm", password: "pass").hex, "8493fbc53ba582fb4c044c456bdc40eb")
        // Channel framing.
        let framed = TurnChannelData.encode(channel: 0x4001, Data([1, 2, 3]))
        XCTAssertEqual(Array(framed), [0x40, 0x01, 0, 3, 1, 2, 3])
        XCTAssertEqual(TurnChannelData.decode(framed)?.channel, 0x4001)
        XCTAssertEqual(TurnChannelData.decode(framed)?.payload, Data([1, 2, 3]))
        XCTAssertNil(TurnChannelData.decode(bytes))
    }

    func testAddressesAndTheirKinds() throws {
        let home = try XCTUnwrap(IceAddress(text: "192.168.1.20:57428"))
        XCTAssertEqual(home.bytes, [192, 168, 1, 20])
        XCTAssertEqual(home.port, 57428)
        XCTAssertEqual(home.text, "192.168.1.20:57428")
        XCTAssertTrue(home.isPrivate)
        XCTAssertEqual(home.kind, "v4-private")
        XCTAssertEqual(IceAddress(text: "100.80.1.2:1")?.kind, "v4-carrier")
        XCTAssertEqual(IceAddress(text: "203.0.113.9:3478")?.kind, "v4-public")
        let six = try XCTUnwrap(IceAddress(text: "[fe80::1]:54158"))
        XCTAssertFalse(six.isIPv4)
        XCTAssertEqual(six.text, "[fe80::1]:54158")
        XCTAssertEqual(six.kind, "v6-private")
        XCTAssertNil(IceAddress(text: "not an address"))
        XCTAssertNil(IceAddress(text: ""))
    }

    /// The description in the library's own shape: every value a string, slashes escaped.
    func testDescriptionTextAsTheLibraryWritesIt() throws {
        let host = try XCTUnwrap(IceAddress(text: "192.168.1.10:54161"))
        let outside = try XCTUnwrap(IceAddress(text: "203.0.113.5:60265"))
        let server = try XCTUnwrap(IceAddress(text: "198.51.100.1:3478"))
        let relayed = try XCTUnwrap(IceAddress(text: "198.51.100.2:55327"))
        let description = IceDescription(username: "Pvo8C4uYKScm", password: "ab/cd+ef==", candidates: [
            IceCandidate(address: host, kind: .host, priority: IceCandidate.priority(kind: .host, order: 0), foundation: "281128422"),
            IceCandidate(address: outside, base: host, kind: .reflexive, priority: IceCandidate.priority(kind: .reflexive, order: 1), foundation: "3523678690", serverAddress: server),
            IceCandidate(address: relayed, base: host, kind: .relay, priority: IceCandidate.priority(kind: .relay, order: 2), foundation: "1066047394", natAddress: outside, serverAddress: server),
        ])
        XCTAssertEqual(description.text, #"{"Full":"1","PacingMs":"50","Version":"1","Candidates":{"count":"3","#
            + #""0":{"transportAddress":"192.168.1.10:54161","baseAddress":"192.168.1.10:54161","natAddress":"","serverAddress":"","ipv6":"0","type":"0","addressType":"3","priority":"2130706431","foundation":"281128422","transport":"udp"},"#
            + #""1":{"transportAddress":"203.0.113.5:60265","baseAddress":"192.168.1.10:54161","natAddress":"","serverAddress":"198.51.100.1:3478","ipv6":"0","type":"1","addressType":"3","priority":"1694498559","foundation":"3523678690","transport":"udp"},"#
            + #""2":{"transportAddress":"198.51.100.2:55327","baseAddress":"192.168.1.10:54161","natAddress":"203.0.113.5:60265","serverAddress":"198.51.100.1:3478","ipv6":"0","type":"3","addressType":"3","priority":"16776703","foundation":"1066047394","transport":"udp","relayStandard":"0"}},"#
            + #""Username":"Pvo8C4uYKScm","Password":"ab\/cd+ef==","StunTimeoutMs":"200","StunRetryCount":"4"}"#)
        XCTAssertEqual(IceDescription(text: description.text), description)
        // The phone's: addresses of both families, kinds as numbers in text.
        let phone = try XCTUnwrap(IceDescription(text: #"{"Full":"1","PacingMs":"50","Version":"1","Candidates":{"count":"3","0":{"transportAddress":"[2001:db8::7]:32883","baseAddress":"[2001:db8::7]:32883","natAddress":"","serverAddress":"","ipv6":"1","type":"0","addressType":"0","priority":"2130705151","foundation":"4202671789","transport":"udp"},"1":{"transportAddress":"100.80.1.2:41327","baseAddress":"100.80.1.2:41327","natAddress":"","serverAddress":"","ipv6":"0","type":"0","addressType":"0","priority":"2130705919","foundation":"2113405128","transport":"udp"},"2":{"transportAddress":"203.0.113.77:51906","baseAddress":"192.168.7.3:59982","natAddress":"","serverAddress":"198.51.100.1:3478","ipv6":"0","type":"1","addressType":"3","priority":"1694497791","foundation":"1","transport":"udp"}},"Username":"RIlC+vS0+gln","Password":"9\/wlMFmP7HuqB","StunTimeoutMs":"200","StunRetryCount":"4"}"#))
        XCTAssertEqual(phone.username, "RIlC+vS0+gln")
        XCTAssertEqual(phone.password, "9/wlMFmP7HuqB")
        XCTAssertEqual(phone.candidates.map(\.kind), [.host, .host, .reflexive])
        XCTAssertEqual(phone.candidates.map(\.address.isIPv4), [false, true, true])
        XCTAssertEqual(phone.candidates[2].priority, 1_694_497_791)
        XCTAssertEqual(phone.candidates[2].base.text, "192.168.7.3:59982")
        XCTAssertNil(IceDescription(text: "{}"))
        XCTAssertEqual(IceDescription().username.count, 12)
        XCTAssertEqual(IceDescription().password.count, 44)
    }

    func testRelayServersFromTheServicesAnswer() throws {
        let answer = try JSONDecoder().decode(CloudRelayResponse.self, from: Data(#"{"stunInfo":{"urls":["relay.example.com:3478"]},"turnCredential":{"urls":["relay.example.com:3478"],"username":"name","credential":"word","turnExpireTime":1792186033}}"#.utf8))
        XCTAssertEqual(NanoRelayServers(answer), NanoRelayServers(stun: "relay.example.com:3478", turn: "relay.example.com:3478", username: "name", password: "word"))
        let schemes = try JSONDecoder().decode(CloudRelayResponse.self, from: Data(#"{"turnCredential":{"urls":["turns:relay.example.com:443?transport=tcp","turn:relay.example.com?transport=udp"],"username":"n","credential":"w"}}"#.utf8))
        XCTAssertEqual(NanoRelayServers(schemes)?.turn, "relay.example.com:3478")
        XCTAssertEqual(NanoRelayServers(schemes)?.stun, "relay.example.com:3478", "the relay also answers address questions")
        let none = try JSONDecoder().decode(CloudRelayResponse.self, from: Data(#"{"stunInfo":{"urls":["relay.example.com:3478"]}}"#.utf8))
        XCTAssertNil(NanoRelayServers(none))
    }
}

/// The same code against what Windows and the phone really sent each other: every message of
/// the recording must read, its signature must hold under the key the recording's own
/// descriptions give, and written again it must come out byte for byte. Skipped where the
/// recording is not at hand; nothing of it is kept here.
final class IceRecordingTests: XCTestCase {
    func testTheRecordedMessagesReadVerifyAndWriteBackTheSame() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let capture = FileManager.default.contents(atPath: root.appendingPathComponent("captures/nano-udp-4.pcap").path),
              let relay = try? String(contentsOf: root.appendingPathComponent("captures/vm-raw-2026-10-09/flows.jsonl"), encoding: .utf8) else {
            throw XCTSkip("the recording is not on this machine")
        }
        // Names and passwords of both sides, and the relay account, from the handshakes.
        var passwords: [String: String] = [:]
        var accounts: [(username: String, password: String)] = []
        for entry in NanoRecording.descriptions(inRelayCapture: relay) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(entry.text.utf8)) as? [String: Any] else { continue }
            let info = object["connectioninformation"] as? [String: Any] ?? object
            guard let ice = info["ice"] as? [String: Any], let description = (ice["candidates"] as? String).flatMap(IceDescription.init(text:)) else { continue }
            passwords[description.username] = description.password
            if let turn = ice["turn"] as? [String: Any], let username = turn["username"] as? String, let password = turn["password"] as? String, !username.isEmpty {
                accounts.append((username, password))
            }
        }
        XCTAssertGreaterThan(passwords.count, 10)
        var read = 0, checks = 0, checksVerified = 0, relayRequests = 0, relayVerified = 0, rewritten = 0, answersVerified = 0
        var kinds: Set<String> = []
        for datagram in try PacketCapture.udpDatagrams(in: capture) where StunMessage.looksLikeStun(datagram.payload) {
            guard let message = StunMessage(datagram.payload) else {
                XCTFail("a recorded message did not read")
                continue
            }
            read += 1
            kinds.insert("\(message.method) \(message.kind)")
            var key: Data?
            if let username = message.text(StunMessage.Attribute.username) {
                if let realm = message.text(StunMessage.Attribute.realm) {
                    relayRequests += 1
                    key = accounts.first { $0.username == username }.map { StunMessage.longTermKey(username: username, realm: realm, password: $0.password) }
                    if let key, message.isSigned(with: key) { relayVerified += 1 }
                } else if let receiver = username.split(separator: ":").first.map(String.init), let password = passwords[receiver] {
                    // A check is signed with the password of the side it goes to.
                    checks += 1
                    key = Data(password.utf8)
                    if message.isSigned(with: Data(password.utf8)) { checksVerified += 1 }
                }
            } else if message.method == .binding, message.kind == .success, message.value(StunMessage.Attribute.messageIntegrity) != nil {
                key = passwords.values.map { Data($0.utf8) }.first { message.isSigned(with: $0) }
                if key != nil { answersVerified += 1 }
            }
            // Written again from what was read: the same bytes.
            if message.value(StunMessage.Attribute.messageIntegrity) == nil || key != nil {
                if message.encoded(signedWith: key) == datagram.payload { rewritten += 1 } else { XCTFail("a recorded \(message.method) \(message.kind) does not write back the same") }
            }
            // A check carried through the relay reads like any other.
            if let inner = message.value(StunMessage.Attribute.data), StunMessage.looksLikeStun(inner) { XCTAssertNotNil(StunMessage(inner)) }
        }
        XCTAssertGreaterThan(read, 100)
        XCTAssertGreaterThan(checks, 20)
        XCTAssertEqual(checksVerified, checks, "every recorded check is signed as this code signs")
        XCTAssertGreaterThan(answersVerified, 5)
        XCTAssertGreaterThan(relayRequests, 3)
        XCTAssertEqual(relayVerified, relayRequests, "every recorded request to the relay is signed as this code signs")
        XCTAssertGreaterThan(rewritten, 100)
        for kind in ["binding request", "binding success", "allocate request", "allocate error", "allocate success", "createPermission success", "channelBind success", "send indication", "data indication"] {
            XCTAssertTrue(kinds.contains(kind), "the recording has a \(kind)")
        }
    }
}

func XCTUnwrapAsync<T>(_ value: @autoclosure () async -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let result = await value()
    return try XCTUnwrap(result, file: file, line: line)
}
