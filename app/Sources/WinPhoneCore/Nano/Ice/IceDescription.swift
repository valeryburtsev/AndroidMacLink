import Foundation

/// One address a side might be reached at.
public struct IceCandidate: Equatable, Sendable {
    /// The kinds, by the numbers the Nano library writes.
    public enum Kind: Int, Sendable {
        /// An address of the device itself.
        case host = 0
        /// The device's address as a server on the internet saw it.
        case reflexive = 1
        /// Learned from a check that arrived, not announced.
        case peerReflexive = 2
        /// An address on a relay server that passes packets on.
        case relay = 3
    }

    public var address: IceAddress
    /// The device's own address this one is reached through.
    public var base: IceAddress
    public var kind: Kind
    public var priority: UInt32
    public var foundation: String
    /// For a relay address: this side as the server saw it.
    public var natAddress: IceAddress?
    public var serverAddress: IceAddress?

    public init(address: IceAddress, base: IceAddress? = nil, kind: Kind, priority: UInt32, foundation: String = String(UInt32.random(in: 1...UInt32.max)),
                natAddress: IceAddress? = nil, serverAddress: IceAddress? = nil) {
        self.address = address
        self.base = base ?? address
        self.kind = kind
        self.priority = priority
        self.foundation = foundation
        self.natAddress = natAddress
        self.serverAddress = serverAddress
    }

    /// The standard's ranking: the kind first, then an order among one's own, then 255 for
    /// "the only component".
    public static func priority(kind: Kind, order: Int) -> UInt32 {
        let preference: UInt32
        switch kind {
        case .host: preference = 126
        case .peerReflexive: preference = 110
        case .reflexive: preference = 100
        case .relay: preference = 0
        }
        return preference << 24 | UInt32(max(0, 65535 - order)) << 8 | 255
    }

    /// The library's mark for the kind of the base address: 3 for a private IPv4 one, 4 for
    /// an IPv6 one of the local link, 0 for anything else.
    var addressType: Int {
        if base.isIPv4 { return base.isPrivate ? 3 : 0 }
        return base.bytes[0] == 0xFE && base.bytes[1] & 0xC0 == 0x80 ? 4 : 0
    }
}

/// What one side tells the other before the checks: a name and password for signing them,
/// and its candidates. The Nano library writes it as JSON with every value a string, and puts
/// that text into the handshake as `ice.candidates`.
public struct IceDescription: Equatable, Sendable {
    public var username: String
    public var password: String
    public var candidates: [IceCandidate]

    public init(username: String = IceDescription.randomText(bytes: 9), password: String = IceDescription.randomText(bytes: 32), candidates: [IceCandidate] = []) {
        self.username = username
        self.password = password
        self.candidates = candidates
    }

    public static func randomText(bytes: Int) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }

    public init?(text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let username = object["Username"] as? String, let password = object["Password"] as? String,
              let list = object["Candidates"] as? [String: Any] else { return nil }
        self.username = username
        self.password = password
        candidates = []
        let count = (list["count"] as? String).flatMap(Int.init) ?? (list["count"] as? NSNumber)?.intValue ?? 0
        for index in 0..<min(count, 64) {
            guard let entry = list[String(index)] as? [String: Any], let address = (entry["transportAddress"] as? String).flatMap(IceAddress.init(text:)) else { continue }
            func number(_ key: String) -> Int? { (entry[key] as? String).flatMap(Int.init) ?? (entry[key] as? NSNumber)?.intValue }
            // Anything but datagrams is of no use here.
            if let transport = entry["transport"] as? String, transport.lowercased() != "udp" { continue }
            candidates.append(IceCandidate(address: address, base: (entry["baseAddress"] as? String).flatMap(IceAddress.init(text:)),
                                           kind: number("type").flatMap(IceCandidate.Kind.init) ?? .host,
                                           priority: UInt32(clamping: number("priority") ?? 0), foundation: entry["foundation"] as? String ?? "0",
                                           natAddress: (entry["natAddress"] as? String).flatMap(IceAddress.init(text:)),
                                           serverAddress: (entry["serverAddress"] as? String).flatMap(IceAddress.init(text:))))
        }
    }

    /// The text as the library writes it: same keys, same order, every value a string.
    public var text: String {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "/", with: "\\/") + "\""
        }
        var entries = ["\"count\":\"\(candidates.count)\""]
        for (index, candidate) in candidates.enumerated() {
            var fields = ["\"transportAddress\":\(quoted(candidate.address.text))", "\"baseAddress\":\(quoted(candidate.base.text))",
                          "\"natAddress\":\(quoted(candidate.natAddress?.text ?? ""))", "\"serverAddress\":\(quoted(candidate.serverAddress?.text ?? ""))",
                          "\"ipv6\":\"\(candidate.address.isIPv4 ? 0 : 1)\"", "\"type\":\"\(candidate.kind.rawValue)\"", "\"addressType\":\"\(candidate.addressType)\"",
                          "\"priority\":\"\(candidate.priority)\"", "\"foundation\":\(quoted(candidate.foundation))", "\"transport\":\"udp\""]
            if candidate.kind == .relay { fields.append("\"relayStandard\":\"0\"") }
            entries.append("\"\(index)\":{\(fields.joined(separator: ","))}")
        }
        return "{\"Full\":\"1\",\"PacingMs\":\"50\",\"Version\":\"1\",\"Candidates\":{\(entries.joined(separator: ","))},"
            + "\"Username\":\(quoted(username)),\"Password\":\(quoted(password)),\"StunTimeoutMs\":\"200\",\"StunRetryCount\":\"4\"}"
    }
}

/// The servers that help two devices on different networks find each other, and the account
/// for the relay among them. From the service's `/CloudRelay/Relay`.
public struct NanoRelayServers: Equatable, Sendable {
    /// "host:port" of the server that tells a device its address as the internet sees it.
    public var stun: String
    /// "host:port" of the relay server.
    public var turn: String
    public var username: String
    public var password: String

    public init(stun: String, turn: String, username: String, password: String) {
        self.stun = stun
        self.turn = turn
        self.username = username
        self.password = password
    }

    /// From the service's answer. Nil when it names no relay.
    public init?(_ response: CloudRelayResponse) {
        func plain(_ url: String) -> String? {
            // Bare "host:port" as recorded; a scheme and a query are tolerated, a secure or
            // stream transport is not what this client speaks.
            var text = url
            if text.lowercased().hasPrefix("turns:") || text.lowercased().contains("transport=tcp") { return nil }
            for scheme in ["stun:", "turn:"] where text.lowercased().hasPrefix(scheme) { text = String(text.dropFirst(scheme.count)) }
            if let query = text.firstIndex(of: "?") { text = String(text[..<query]) }
            if !text.contains(":") { text += ":3478" }
            return text.isEmpty ? nil : text
        }
        guard let account = response.turnCredential, let turn = account.urls.compactMap(plain).first else { return nil }
        self.init(stun: response.stunInfo?.urls.compactMap(plain).first ?? turn, turn: turn, username: account.username, password: account.credential)
    }
}
