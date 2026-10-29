import CryptoKit
import Foundation

// When the phone and this computer are not on one network, the Nano connection is made the way
// voice calls are: both sides list the addresses they might be reached at, try each other's
// with small signed messages, and fall back to a relay server that passes packets on
// (`protocol/specs/nano-ice.md`). The messages are STUN, the relay is TURN, the procedure is
// ICE; all three as the public standards have them, with the few additions the recording shows.

/// An address and port, IPv4 or IPv6, as numbers. Its text form is never written to the log.
public struct IceAddress: Hashable, Sendable {
    /// 4 or 16 bytes.
    public var bytes: [UInt8]
    public var port: UInt16

    public init(bytes: [UInt8], port: UInt16) {
        self.bytes = bytes
        self.port = port
    }

    /// "1.2.3.4:5" or "[2001:db8::1]:5".
    public init?(text: String) {
        guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]) else { return nil }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var four = in_addr()
        var six = in6_addr()
        if inet_pton(AF_INET, host, &four) == 1 {
            bytes = withUnsafeBytes(of: &four) { Array($0) }
        } else if inet_pton(AF_INET6, host, &six) == 1 {
            bytes = withUnsafeBytes(of: &six) { Array($0) }
        } else {
            return nil
        }
        self.port = port
    }

    public var isIPv4: Bool { bytes.count == 4 }

    public var host: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        bytes.withUnsafeBytes { _ = inet_ntop(isIPv4 ? AF_INET : AF_INET6, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
        return String(cString: buffer)
    }

    public var text: String { isIPv4 ? "\(host):\(port)" : "[\(host)]:\(port)" }

    /// A home or office network's own range.
    public var isPrivate: Bool {
        guard isIPv4 else { return bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) }
        return bytes[0] == 10 || (bytes[0] == 172 && bytes[1] & 0xF0 == 16) || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 169 && bytes[1] == 254)
    }
    /// The range mobile carriers hand out behind their own address translation.
    public var isCarrierGrade: Bool { isIPv4 && bytes[0] == 100 && bytes[1] & 0xC0 == 64 }
    public var isLoopback: Bool { isIPv4 ? bytes[0] == 127 : bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1 }
    /// Reachable from anywhere on the internet, as far as the number tells.
    public var isGlobal: Bool { !isPrivate && !isCarrierGrade && !isLoopback && !(isIPv4 && bytes[0] == 0) }

    /// What kind of address this is, for the log.
    public var kind: String { (isIPv4 ? "v4" : "v6") + (isPrivate ? "-private" : isCarrierGrade ? "-carrier" : isGlobal ? "-public" : "-other") }
}

/// One STUN message: a method, whether it asks, tells, answers or refuses, and attributes.
public struct StunMessage: Equatable, Sendable {
    public enum Method: UInt16, Sendable {
        case binding = 1, allocate = 3, refresh = 4, send = 6, data = 7, createPermission = 8, channelBind = 9
    }
    public enum Kind: UInt16, Sendable { case request = 0, indication = 1, success = 2, error = 3 }

    public enum Attribute {
        public static let mappedAddress: UInt16 = 0x0001
        public static let username: UInt16 = 0x0006
        public static let messageIntegrity: UInt16 = 0x0008
        public static let errorCode: UInt16 = 0x0009
        public static let channelNumber: UInt16 = 0x000C
        public static let lifetime: UInt16 = 0x000D
        public static let xorPeerAddress: UInt16 = 0x0012
        public static let data: UInt16 = 0x0013
        public static let realm: UInt16 = 0x0014
        public static let nonce: UInt16 = 0x0015
        public static let xorRelayedAddress: UInt16 = 0x0016
        public static let requestedAddressFamily: UInt16 = 0x0017
        public static let requestedTransport: UInt16 = 0x0019
        public static let dontFragment: UInt16 = 0x001A
        public static let xorMappedAddress: UInt16 = 0x0020
        public static let priority: UInt16 = 0x0024
        public static let useCandidate: UInt16 = 0x0025
        public static let software: UInt16 = 0x8022
        public static let alternateServer: UInt16 = 0x8023
        /// How many times this request has been sent, and the answer to it (RFC 7982): two
        /// zero bytes, the request's count, the answer's count.
        public static let transmitCounter: UInt16 = 0x8025
        public static let iceControlled: UInt16 = 0x8029
        public static let iceControlling: UInt16 = 0x802A
        /// Sent with every allocation by the Nano library: a session identifier, all zeros.
        public static let sessionId: UInt16 = 0x8094
    }

    public static let cookie: [UInt8] = [0x21, 0x12, 0xA4, 0x42]

    public var method: Method
    public var kind: Kind
    /// 12 bytes that tie an answer to its request.
    public var transaction: Data
    public var attributes: [(type: UInt16, value: Data)]
    /// Where the integrity attribute starts in the bytes this was read from, for checking it.
    private var integrityOffset: Int?
    private var raw: Data?

    public init(method: Method, kind: Kind, transaction: Data = StunMessage.newTransaction(), attributes: [(type: UInt16, value: Data)] = []) {
        self.method = method
        self.kind = kind
        self.transaction = transaction
        self.attributes = attributes
    }

    public static func == (left: StunMessage, right: StunMessage) -> Bool {
        left.method == right.method && left.kind == right.kind && left.transaction == right.transaction
            && left.attributes.count == right.attributes.count
            && zip(left.attributes, right.attributes).allSatisfy { $0.type == $1.type && $0.value == $1.value }
    }

    public static func newTransaction() -> Data { Data((0..<12).map { _ in UInt8.random(in: 0...255) }) }

    /// Whether a datagram is a STUN message at all: two zero bits, then the fixed cookie.
    public static func looksLikeStun(_ datagram: Data) -> Bool {
        datagram.count >= 20 && datagram[datagram.startIndex] < 4 && Array(datagram[(datagram.startIndex + 4)..<(datagram.startIndex + 8)]) == cookie
    }

    // MARK: Reading

    public init?(_ datagram: Data) {
        let bytes = Data(datagram)
        guard StunMessage.looksLikeStun(bytes) else { return nil }
        let type = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let length = Int(bytes[2]) << 8 | Int(bytes[3])
        guard bytes.count >= 20 + length, length % 4 == 0 else { return nil }
        // The method's bits are spread around the two bits of the kind.
        let number = (type & 0x000F) | ((type >> 1) & 0x0070) | ((type >> 2) & 0x0F80)
        guard let method = Method(rawValue: number), let kind = Kind(rawValue: ((type >> 4) & 1) | ((type >> 7) & 2)) else { return nil }
        self.method = method
        self.kind = kind
        transaction = bytes.subdata(in: 8..<20)
        attributes = []
        var offset = 20
        while offset + 4 <= 20 + length {
            let attribute = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            let size = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard offset + 4 + size <= bytes.count else { return nil }
            if attribute == Attribute.messageIntegrity, integrityOffset == nil { integrityOffset = offset }
            attributes.append((attribute, bytes.subdata(in: (offset + 4)..<(offset + 4 + size))))
            offset += 4 + (size + 3) / 4 * 4
        }
        raw = bytes
    }

    public func value(_ type: UInt16) -> Data? { attributes.first { $0.type == type }?.value }
    public func text(_ type: UInt16) -> String? { value(type).map { String(decoding: $0, as: UTF8.self) } }

    public func number(_ type: UInt16) -> UInt32? {
        guard let value = value(type), value.count == 4 else { return nil }
        return value.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// The code of a refusal: 300 "try another server", 401 "say who you are", 403, 438 ...
    public var errorCode: Int? {
        guard let value = value(Attribute.errorCode), value.count >= 4 else { return nil }
        let bytes = Array(value)
        return Int(bytes[2] & 7) * 100 + Int(bytes[3])
    }

    /// An address attribute, either kind: the plain ones as written, the others undone from
    /// their mixing with the cookie and the transaction.
    public func address(_ type: UInt16) -> IceAddress? {
        guard let value = value(type), value.count >= 8 else { return nil }
        let bytes = Array(value)
        let plain = type == Attribute.mappedAddress || type == Attribute.alternateServer
        let mask = StunMessage.cookie + Array(transaction)
        let port = (UInt16(bytes[2]) << 8 | UInt16(bytes[3])) ^ (plain ? 0 : 0x2112)
        let size = bytes[1] == 2 ? 16 : 4
        guard bytes.count >= 4 + size else { return nil }
        return IceAddress(bytes: (0..<size).map { bytes[4 + $0] ^ (plain ? 0 : mask[$0]) }, port: port)
    }

    /// Whether the message was signed with this key. False for a message built here or one
    /// that carries no signature.
    public func isSigned(with key: Data) -> Bool {
        guard let raw, let offset = integrityOffset, let claimed = value(Attribute.messageIntegrity) else { return false }
        // Signed as if the message ended with the signature, whatever follows it.
        var covered = raw.subdata(in: 0..<offset)
        let length = offset + 24 - 20
        covered[2] = UInt8(length >> 8)
        covered[3] = UInt8(length & 0xFF)
        return Data(HMAC<Insecure.SHA1>.authenticationCode(for: covered, using: SymmetricKey(data: key))) == claimed
    }

    // MARK: Writing

    public static func addressValue(_ address: IceAddress, transaction: Data, plain: Bool = false) -> Data {
        let mask = StunMessage.cookie + Array(transaction)
        let port = address.port ^ (plain ? 0 : 0x2112)
        var value = Data([0, address.isIPv4 ? 1 : 2, UInt8(port >> 8), UInt8(port & 0xFF)])
        value.append(contentsOf: address.bytes.enumerated().map { $1 ^ (plain ? 0 : mask[$0]) })
        return value
    }

    public mutating func add(_ type: UInt16, _ value: Data = Data()) { attributes.append((type, value)) }
    public mutating func add(_ type: UInt16, text: String) { add(type, Data(text.utf8)) }
    public mutating func add(_ type: UInt16, number: UInt32) { add(type, Data([UInt8(number >> 24), UInt8(number >> 16 & 0xFF), UInt8(number >> 8 & 0xFF), UInt8(number & 0xFF)])) }
    public mutating func add(_ type: UInt16, address: IceAddress, plain: Bool = false) {
        add(type, StunMessage.addressValue(address, transaction: transaction, plain: plain))
    }

    /// The message as bytes, signed at the end when a key is given.
    public func encoded(signedWith key: Data? = nil) -> Data {
        var body = Data()
        for attribute in attributes where attribute.type != Attribute.messageIntegrity {
            body.append(contentsOf: [UInt8(attribute.type >> 8), UInt8(attribute.type & 0xFF), UInt8(attribute.value.count >> 8), UInt8(attribute.value.count & 0xFF)])
            body.append(attribute.value)
            body.append(Data(count: (4 - attribute.value.count % 4) % 4))
        }
        let number = method.rawValue
        let type = (number & 0x000F) | ((number & 0x0070) << 1) | ((number & 0x0F80) << 2) | ((kind.rawValue & 1) << 4) | ((kind.rawValue & 2) << 7)
        let length = body.count + (key == nil ? 0 : 24)
        var message = Data([UInt8(type >> 8), UInt8(type & 0xFF), UInt8(length >> 8), UInt8(length & 0xFF)])
        message.append(contentsOf: StunMessage.cookie)
        message.append(transaction)
        message.append(body)
        if let key {
            let code = HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key))
            message.append(contentsOf: [0, 8, 0, 20])
            message.append(contentsOf: code)
        }
        return message
    }

    /// The key a relay server's messages are signed with, from an account's name, the realm
    /// the server names and the password.
    public static func longTermKey(username: String, realm: String, password: String) -> Data {
        Data(Insecure.MD5.hash(data: Data("\(username):\(realm):\(password)".utf8)))
    }
}

/// A relay server's framing for data on a bound channel: the channel's number, the length,
/// the data.
public enum TurnChannelData {
    public static func isChannelData(_ datagram: Data) -> Bool {
        datagram.count >= 4 && datagram[datagram.startIndex] & 0xC0 == 0x40
    }

    public static func encode(channel: UInt16, _ payload: Data) -> Data {
        var data = Data([UInt8(channel >> 8), UInt8(channel & 0xFF), UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        data.append(payload)
        return data
    }

    public static func decode(_ datagram: Data) -> (channel: UInt16, payload: Data)? {
        let bytes = Data(datagram)
        guard isChannelData(bytes) else { return nil }
        let length = Int(bytes[2]) << 8 | Int(bytes[3])
        guard bytes.count >= 4 + length else { return nil }
        return (UInt16(bytes[0]) << 8 | UInt16(bytes[1]), bytes.subdata(in: 4..<(4 + length)))
    }
}
