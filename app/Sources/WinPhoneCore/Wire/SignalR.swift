import Foundation

/// SignalR framing and hub messages for the MessagePack hub protocol.
///
/// A WebSocket message holds one or more frames, each a base-128 length prefix followed by a
/// MessagePack array. The very first message in each direction is a JSON handshake ending in 0x1E.
public enum SignalR {
    public static let recordSeparator: UInt8 = 0x1E

    /// The client's handshake, exactly as Phone Link sends it.
    public static let handshakeRequest = Data(#"{"protocol":"messagepack","version":1}"#.utf8) + [recordSeparator]

    public enum FramingError: Error, Equatable {
        case truncatedLengthPrefix
        case lengthPrefixTooLong
        case frameRunsPastEnd
        case missingRecordSeparator
        case handshakeRejected(String)
        case malformedHubMessage(String)
    }

    /// Splits the handshake response from whatever hub bytes share its WebSocket message.
    public static func splitHandshake(_ message: Data) throws -> (handshake: Data, rest: Data) {
        guard let end = message.firstIndex(of: recordSeparator) else { throw FramingError.missingRecordSeparator }
        return (Data(message[message.startIndex..<end]), Data(message[(end + 1)...]))
    }

    /// Validates a handshake response. An empty object means success.
    public static func checkHandshakeResponse(_ handshake: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: handshake) as? [String: Any] else {
            throw FramingError.handshakeRejected("not a JSON object")
        }
        if let error = object["error"] as? String { throw FramingError.handshakeRejected(error) }
    }

    public static func lengthPrefix(_ length: Int) -> Data {
        var out = Data()
        var n = UInt32(length)
        repeat {
            var byte = UInt8(n & 0x7F)
            n >>= 7
            if n != 0 { byte |= 0x80 }
            out.append(byte)
        } while n != 0
        return out
    }

    public static func frame(_ payload: Data) -> Data { lengthPrefix(payload.count) + payload }

    /// Splits one WebSocket message into its frames.
    public static func splitFrames(_ message: Data) throws -> [Data] {
        var frames: [Data] = []
        var index = message.startIndex
        while index < message.endIndex {
            var length = 0
            var shift = 0
            var consumed = 0
            while true {
                guard index < message.endIndex else { throw FramingError.truncatedLengthPrefix }
                guard consumed < 5 else { throw FramingError.lengthPrefixTooLong }
                let byte = message[index]
                index += 1
                consumed += 1
                length |= Int(byte & 0x7F) << shift
                shift += 7
                if byte & 0x80 == 0 { break }
            }
            guard length <= message.endIndex - index else { throw FramingError.frameRunsPastEnd }
            frames.append(Data(message[index..<index + length]))
            index += length
        }
        return frames
    }
}

/// One hub message. Unknown kinds are kept verbatim so nothing is lost on decode.
public enum HubMessage: Equatable, Sendable {
    /// `[1, headers, invocationId, target, arguments, streamIds]`
    case invocation(headers: MsgPack, invocationId: String?, target: String, arguments: [MsgPack])
    /// `[3, headers, invocationId, resultKind, value?]`. Kind 1 is an error string, 2 is void, 3 is a result.
    case completion(headers: MsgPack, invocationId: String, resultKind: Int, value: MsgPack?)
    /// `[6]`
    case ping
    /// `[7, error, allowReconnect?]`
    case close(error: String?, allowReconnect: Bool?)
    case other(MsgPack)

    public static let emptyHeaders = MsgPack.map([])

    public var encoded: MsgPack {
        switch self {
        case .invocation(let headers, let id, let target, let arguments):
            return .array([.int(1), headers, id.map(MsgPack.string) ?? .null, .string(target), .array(arguments), .array([])])
        case .completion(let headers, let id, let kind, let value):
            var items: [MsgPack] = [.int(3), headers, .string(id), .int(Int64(kind))]
            if let value { items.append(value) }
            return .array(items)
        case .ping:
            return .array([.int(6)])
        case .close(let error, let allowReconnect):
            var items: [MsgPack] = [.int(7), error.map(MsgPack.string) ?? .null]
            if let allowReconnect { items.append(.bool(allowReconnect)) }
            return .array(items)
        case .other(let value):
            return value
        }
    }

    /// The framed bytes ready to send as (part of) a WebSocket message.
    public var framed: Data { SignalR.frame(encoded.encoded()) }

    public init(frame: Data) throws {
        self = try HubMessage(value: MsgPack.decode(frame))
    }

    public init(value: MsgPack) throws {
        guard let items = value.arrayValue, let kind = items.first?.intValue else {
            throw SignalR.FramingError.malformedHubMessage("not an array with a type")
        }
        switch kind {
        case 1:
            guard items.count >= 5, let target = items[3].stringValue, let arguments = items[4].arrayValue else {
                throw SignalR.FramingError.malformedHubMessage("invocation")
            }
            // A streamIds entry that is present but not empty would be lost on re-encode.
            if items.count > 5, items[5] != .array([]) { self = .other(value); return }
            if items.count != 6 { self = .other(value); return }
            self = .invocation(headers: items[1], invocationId: items[2].stringValue, target: target, arguments: arguments)
        case 3:
            guard items.count >= 4, let id = items[2].stringValue, let resultKind = items[3].intValue else {
                throw SignalR.FramingError.malformedHubMessage("completion")
            }
            self = .completion(headers: items[1], invocationId: id, resultKind: Int(resultKind), value: items.count > 4 ? items[4] : nil)
        case 6:
            self = items.count == 1 ? .ping : .other(value)
        case 7:
            self = .close(error: items.count > 1 ? items[1].stringValue : nil, allowReconnect: items.count > 2 ? items[2].boolValue : nil)
        default:
            self = .other(value)
        }
    }
}
