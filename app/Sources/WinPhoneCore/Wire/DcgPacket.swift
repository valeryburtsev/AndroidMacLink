import Foundation

/// W3C-style trace context carried as the first argument of every outbound hub invocation.
/// The service rejects an empty object, so all four fields are always present.
public struct TraceContext: Equatable, Sendable {
    public var traceId: String
    public var parentId: String?
    public var flags: Int
    public var scenarioId: String?
    public var triggerId: String?

    public init(traceId: String = TraceContext.randomHex(bytes: 16), parentId: String? = TraceContext.randomHex(bytes: 8),
                flags: Int = 0, scenarioId: String? = nil, triggerId: String? = nil) {
        self.traceId = traceId
        self.parentId = parentId
        self.flags = flags
        self.scenarioId = scenarioId
        self.triggerId = triggerId
    }

    public static func randomHex(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
    }

    /// `00-<traceId>-<spanId>-<flags>`, sent as the `traceparent` invocation header.
    public func traceparent(spanId: String = TraceContext.randomHex(bytes: 8)) -> String {
        "00-\(traceId)-\(spanId)-\(String(format: "%02x", flags))"
    }

    public var encoded: MsgPack {
        var state: [MsgPackEntry] = []
        if let scenarioId { state.append(MsgPackEntry(.string("ypScenarioId"), .string(scenarioId))) }
        if let triggerId { state.append(MsgPackEntry(.string("ypTriggerId"), .string(triggerId))) }
        return .map([
            MsgPackEntry(.string("TraceId"), .string(traceId)),
            MsgPackEntry(.string("ParentId"), parentId.map(MsgPack.string) ?? .null),
            MsgPackEntry(.string("TraceFlags"), .int(Int64(flags))),
            MsgPackEntry(.string("TraceState"), .map(state)),
        ])
    }

    public init?(_ value: MsgPack) {
        guard let traceId = value["TraceId"]?.stringValue else { return nil }
        self.traceId = traceId
        self.parentId = value["ParentId"]?.stringValue
        self.flags = Int(value["TraceFlags"]?.intValue ?? 0)
        self.scenarioId = value["TraceState"]?["ypScenarioId"]?.stringValue
        self.triggerId = value["TraceState"]?["ypTriggerId"]?.stringValue
    }
}

/// Which kind of message a fragment carries, as numbered on the hub relay.
/// The protobuf enum of the same name uses different numbers (App=1, Platform=2).
public enum RelayMessageType: Int, Sendable {
    case app = 0
    case platform = 1
    case unknown = 2
}

/// The packet object carried by `SendMessageAsync` and `OnReceiveMessage`: a property map, the
/// handler type and the raw payload. Fragments carry payload bytes; acknowledgements carry none.
public enum DcgPacket: Equatable, Sendable {
    public static let handlerType = "ms-dcg"
    public static let version = 1.0

    case fragment(Fragment)
    case ack(Ack)

    public struct Fragment: Equatable, Sendable {
        public var sessionId: String
        public var sequenceNumber: Int
        public var messageId: Int
        public var messageType: RelayMessageType
        public var fragmentId: Int
        public var fragmentCount: Int
        public var raw: Data

        public init(sessionId: String, sequenceNumber: Int, messageId: Int, messageType: RelayMessageType,
                    fragmentId: Int, fragmentCount: Int, raw: Data) {
            self.sessionId = sessionId
            self.sequenceNumber = sequenceNumber
            self.messageId = messageId
            self.messageType = messageType
            self.fragmentId = fragmentId
            self.fragmentCount = fragmentCount
            self.raw = raw
        }
    }

    public struct Ack: Equatable, Sendable {
        public var sessionId: String
        public var sequenceNumber: Int
        public var success: Bool
        public var errorNumber: Int

        public init(sessionId: String, sequenceNumber: Int, success: Bool = true, errorNumber: Int = 0) {
            self.sessionId = sessionId
            self.sequenceNumber = sequenceNumber
            self.success = success
            self.errorNumber = errorNumber
        }
    }

    public enum DecodeError: Error, Equatable {
        case notAPacket
        case unsupportedType(Int64?)
        case missingProperty(String)
    }

    /// Encodes with the key order and value types Phone Link uses on the wire: `Version` is a
    /// double and every other number a fixed 32-bit integer, because Windows serializes the
    /// property map as boxed objects.
    public var encoded: MsgPack {
        let properties: MsgPack
        let raw: MsgPack
        switch self {
        case .fragment(let f):
            properties = .map([
                MsgPackEntry(.string("Version"), .double(DcgPacket.version)),
                MsgPackEntry(.string("Type"), .int32(2)),
                MsgPackEntry(.string("SessionId"), .string(f.sessionId)),
                MsgPackEntry(.string("SequenceNumber"), .int32(f.sequenceNumber)),
                MsgPackEntry(.string("MessageId"), .int32(f.messageId)),
                MsgPackEntry(.string("MessageType"), .int32(f.messageType.rawValue)),
                MsgPackEntry(.string("FragmentId"), .int32(f.fragmentId)),
                MsgPackEntry(.string("FragmentCount"), .int32(f.fragmentCount)),
            ])
            raw = .binary(f.raw)
        case .ack(let a):
            properties = .map([
                MsgPackEntry(.string("Version"), .double(DcgPacket.version)),
                MsgPackEntry(.string("Type"), .int32(1)),
                MsgPackEntry(.string("SessionId"), .string(a.sessionId)),
                MsgPackEntry(.string("SequenceNumber"), .int32(a.sequenceNumber)),
                MsgPackEntry(.string("Success"), .bool(a.success)),
                MsgPackEntry(.string("ErrorNo"), .int32(a.errorNumber)),
            ])
            raw = .null
        }
        return .map([
            MsgPackEntry(.string("Properties"), properties),
            MsgPackEntry(.string("Type"), .string(DcgPacket.handlerType)),
            MsgPackEntry(.string("Raw"), raw),
        ])
    }

    /// Decodes a packet from either client. The phone sends counters as doubles and uses a
    /// different key order, so lookups are by name and numeric type is not assumed.
    public init(_ value: MsgPack) throws {
        guard let properties = value["Properties"], properties.entries != nil else { throw DecodeError.notAPacket }
        func int(_ name: String) throws -> Int {
            guard let v = properties[name]?.intValue else { throw DecodeError.missingProperty(name) }
            return Int(v)
        }
        guard let sessionId = properties["SessionId"]?.stringValue else { throw DecodeError.missingProperty("SessionId") }
        switch properties["Type"]?.intValue {
        case 2:
            guard let raw = value["Raw"]?.dataValue else { throw DecodeError.missingProperty("Raw") }
            self = .fragment(Fragment(
                sessionId: sessionId, sequenceNumber: try int("SequenceNumber"), messageId: try int("MessageId"),
                messageType: RelayMessageType(rawValue: try int("MessageType")) ?? .unknown,
                fragmentId: try int("FragmentId"), fragmentCount: try int("FragmentCount"), raw: raw))
        case 1:
            guard let success = properties["Success"]?.boolValue else { throw DecodeError.missingProperty("Success") }
            self = .ack(Ack(sessionId: sessionId, sequenceNumber: try int("SequenceNumber"), success: success,
                            errorNumber: Int(properties["ErrorNo"]?.intValue ?? 0)))
        case let other:
            throw DecodeError.unsupportedType(other)
        }
    }
}
