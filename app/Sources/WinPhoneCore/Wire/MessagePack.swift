import Foundation

/// A MessagePack value. Maps keep their entries in wire order so a decoded value can be
/// re-encoded to the same bytes.
public indirect enum MsgPack: Equatable, Sendable {
    case null
    case bool(Bool)
    /// Any integer that fits in `Int64`. The encoder picks the smallest wire form by value.
    case int(Int64)
    /// Integers above `Int64.max`.
    case uint(UInt64)
    /// An integer written in a specific wire format (`0xCC`...`0xD3`) that is wider than its value
    /// needs. Phone Link writes packet properties as fixed 32-bit integers (`0xD2`), and matching
    /// its bytes exactly requires keeping that choice.
    case sizedInt(Int64, format: UInt8)
    case float(Float)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([MsgPack])
    case map([MsgPackEntry])
    case ext(type: Int8, data: Data)
}

public struct MsgPackEntry: Equatable, Sendable {
    public var key: MsgPack
    public var value: MsgPack
    public init(_ key: MsgPack, _ value: MsgPack) { self.key = key; self.value = value }
}

public enum MsgPackError: Error, Equatable {
    case truncated
    case trailingBytes(Int)
    case invalidByte(UInt8)
    case tooDeep
    case lengthExceedsInput
    case invalidUTF8
}

// MARK: - Convenience accessors

public extension MsgPack {
    static func map(_ pairs: KeyValuePairs<String, MsgPack>) -> MsgPack {
        .map(pairs.map { MsgPackEntry(.string($0.key), $0.value) })
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var dataValue: Data? { if case .binary(let d) = self { return d }; return nil }
    var arrayValue: [MsgPack]? { if case .array(let a) = self { return a }; return nil }
    var entries: [MsgPackEntry]? { if case .map(let m) = self { return m }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var isNull: Bool { self == .null }

    /// Integer value, also accepting floats that hold a whole number. Phone-side packets carry
    /// counters such as `SequenceNumber` as doubles.
    var intValue: Int64? {
        switch self {
        case .int(let v): return v
        case .sizedInt(let v, _): return v
        case .uint(let v): return v <= UInt64(Int64.max) ? Int64(v) : nil
        case .double(let v): return v.rounded() == v && abs(v) < 9.0e15 ? Int64(v) : nil
        case .float(let v): return v.rounded() == v && abs(v) < 1.6e7 ? Int64(v) : nil
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .float(let v): return Double(v)
        case .int(let v), .sizedInt(let v, _): return Double(v)
        case .uint(let v): return Double(v)
        default: return nil
        }
    }

    /// A 32-bit signed integer in the fixed-width form (`0xD2`) Phone Link uses for boxed numbers.
    static func int32(_ value: Int) -> MsgPack { .sizedInt(Int64(value), format: 0xD2) }

    /// Looks up a string key in a map.
    subscript(key: String) -> MsgPack? {
        guard case .map(let entries) = self else { return nil }
        return entries.first { $0.key == .string(key) }?.value
    }
}

// MARK: - Encoding

public extension MsgPack {
    /// Encodes using the smallest representation for every value, which is what
    /// MessagePack-CSharp and msgpack-java produce.
    func encoded() -> Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    func encode(into out: inout Data) {
        switch self {
        case .null: out.append(0xC0)
        case .bool(let b): out.append(b ? 0xC3 : 0xC2)
        case .int(let v): MsgPack.encodeInt(v, into: &out)
        case .sizedInt(let v, let format):
            out.append(format)
            switch format {
            case 0xCC, 0xD0: out.append(UInt8(truncatingIfNeeded: v))
            case 0xCD, 0xD1: out.appendBE(UInt16(truncatingIfNeeded: v))
            case 0xCE, 0xD2: out.appendBE(UInt32(truncatingIfNeeded: v))
            default: out.appendBE(UInt64(truncatingIfNeeded: v))
            }
        case .uint(let v):
            if v <= UInt64(Int64.max) { MsgPack.encodeInt(Int64(v), into: &out) } else { out.append(0xCF); out.appendBE(v) }
        case .float(let v): out.append(0xCA); out.appendBE(v.bitPattern)
        case .double(let v): out.append(0xCB); out.appendBE(v.bitPattern)
        case .string(let s):
            let utf8 = Data(s.utf8)
            switch utf8.count {
            case 0...31: out.append(0xA0 | UInt8(utf8.count))
            case 32...0xFF: out.append(0xD9); out.append(UInt8(utf8.count))
            case 0x100...0xFFFF: out.append(0xDA); out.appendBE(UInt16(utf8.count))
            default: out.append(0xDB); out.appendBE(UInt32(utf8.count))
            }
            out.append(utf8)
        case .binary(let d):
            switch d.count {
            case 0...0xFF: out.append(0xC4); out.append(UInt8(d.count))
            case 0x100...0xFFFF: out.append(0xC5); out.appendBE(UInt16(d.count))
            default: out.append(0xC6); out.appendBE(UInt32(d.count))
            }
            out.append(d)
        case .array(let items):
            switch items.count {
            case 0...15: out.append(0x90 | UInt8(items.count))
            case 16...0xFFFF: out.append(0xDC); out.appendBE(UInt16(items.count))
            default: out.append(0xDD); out.appendBE(UInt32(items.count))
            }
            for item in items { item.encode(into: &out) }
        case .map(let entries):
            switch entries.count {
            case 0...15: out.append(0x80 | UInt8(entries.count))
            case 16...0xFFFF: out.append(0xDE); out.appendBE(UInt16(entries.count))
            default: out.append(0xDF); out.appendBE(UInt32(entries.count))
            }
            for entry in entries { entry.key.encode(into: &out); entry.value.encode(into: &out) }
        case .ext(let type, let data):
            switch data.count {
            case 1: out.append(0xD4)
            case 2: out.append(0xD5)
            case 4: out.append(0xD6)
            case 8: out.append(0xD7)
            case 16: out.append(0xD8)
            case 0...0xFF: out.append(0xC7); out.append(UInt8(data.count))
            case 0x100...0xFFFF: out.append(0xC8); out.appendBE(UInt16(data.count))
            default: out.append(0xC9); out.appendBE(UInt32(data.count))
            }
            out.append(UInt8(bitPattern: type))
            out.append(data)
        }
    }

    /// The format byte the smallest encoding of `v` uses, or nil for a single-byte fixint.
    static func minimalIntFormat(_ v: Int64) -> UInt8? {
        if v >= 0 {
            switch v {
            case 0...0x7F: return nil
            case 0x80...0xFF: return 0xCC
            case 0x100...0xFFFF: return 0xCD
            case 0x1_0000...0xFFFF_FFFF: return 0xCE
            default: return 0xCF
            }
        }
        switch v {
        case -32 ... -1: return nil
        case -0x80 ... -33: return 0xD0
        case -0x8000 ... -0x81: return 0xD1
        case -0x8000_0000 ... -0x8001: return 0xD2
        default: return 0xD3
        }
    }

    private static func sized(_ v: Int64, _ format: UInt8) -> MsgPack {
        minimalIntFormat(v) == format ? .int(v) : .sizedInt(v, format: format)
    }

    private static func encodeInt(_ v: Int64, into out: inout Data) {
        if v >= 0 {
            switch v {
            case 0...0x7F: out.append(UInt8(v))
            case 0x80...0xFF: out.append(0xCC); out.append(UInt8(v))
            case 0x100...0xFFFF: out.append(0xCD); out.appendBE(UInt16(v))
            case 0x1_0000...0xFFFF_FFFF: out.append(0xCE); out.appendBE(UInt32(v))
            default: out.append(0xCF); out.appendBE(UInt64(v))
            }
        } else {
            switch v {
            case -32 ... -1: out.append(UInt8(bitPattern: Int8(v)))
            case -0x80 ... -33: out.append(0xD0); out.append(UInt8(bitPattern: Int8(v)))
            case -0x8000 ... -0x81: out.append(0xD1); out.appendBE(UInt16(bitPattern: Int16(v)))
            case -0x8000_0000 ... -0x8001: out.append(0xD2); out.appendBE(UInt32(bitPattern: Int32(v)))
            default: out.append(0xD3); out.appendBE(UInt64(bitPattern: v))
            }
        }
    }
}

// MARK: - Decoding

public extension MsgPack {
    /// Decodes exactly one value and rejects trailing bytes.
    static func decode(_ data: Data) throws -> MsgPack {
        var reader = ByteReader(data)
        let value = try decode(&reader, depth: 0)
        if reader.remaining != 0 { throw MsgPackError.trailingBytes(reader.remaining) }
        return value
    }

    /// Decodes one value from the reader, leaving it positioned after the value.
    static func decode(_ r: inout ByteReader, depth: Int) throws -> MsgPack {
        guard depth <= 64 else { throw MsgPackError.tooDeep }
        let b = try r.u8()
        switch b {
        case 0x00...0x7F: return .int(Int64(b))
        case 0xE0...0xFF: return .int(Int64(Int8(bitPattern: b)))
        case 0x80...0x8F: return try decodeMap(&r, count: Int(b & 0x0F), depth: depth)
        case 0x90...0x9F: return try decodeArray(&r, count: Int(b & 0x0F), depth: depth)
        case 0xA0...0xBF: return try decodeString(&r, count: Int(b & 0x1F))
        case 0xC0: return .null
        case 0xC2: return .bool(false)
        case 0xC3: return .bool(true)
        case 0xC4: return .binary(try r.bytes(Int(try r.u8())))
        case 0xC5: return .binary(try r.bytes(Int(try r.u16())))
        case 0xC6: return .binary(try r.bytes(Int(try r.u32())))
        case 0xC7: let n = Int(try r.u8()); return try decodeExt(&r, count: n)
        case 0xC8: let n = Int(try r.u16()); return try decodeExt(&r, count: n)
        case 0xC9: let n = Int(try r.u32()); return try decodeExt(&r, count: n)
        case 0xCA: return .float(Float(bitPattern: try r.u32()))
        case 0xCB: return .double(Double(bitPattern: try r.u64()))
        case 0xCC: return sized(Int64(try r.u8()), b)
        case 0xCD: return sized(Int64(try r.u16()), b)
        case 0xCE: return sized(Int64(try r.u32()), b)
        case 0xCF:
            let v = try r.u64()
            return v <= UInt64(Int64.max) ? sized(Int64(v), b) : .uint(v)
        case 0xD0: return sized(Int64(Int8(bitPattern: try r.u8())), b)
        case 0xD1: return sized(Int64(Int16(bitPattern: try r.u16())), b)
        case 0xD2: return sized(Int64(Int32(bitPattern: try r.u32())), b)
        case 0xD3: return sized(Int64(bitPattern: try r.u64()), b)
        case 0xD4: return try decodeExt(&r, count: 1)
        case 0xD5: return try decodeExt(&r, count: 2)
        case 0xD6: return try decodeExt(&r, count: 4)
        case 0xD7: return try decodeExt(&r, count: 8)
        case 0xD8: return try decodeExt(&r, count: 16)
        case 0xD9: return try decodeString(&r, count: Int(try r.u8()))
        case 0xDA: return try decodeString(&r, count: Int(try r.u16()))
        case 0xDB: return try decodeString(&r, count: Int(try r.u32()))
        case 0xDC: return try decodeArray(&r, count: Int(try r.u16()), depth: depth)
        case 0xDD: return try decodeArray(&r, count: Int(try r.u32()), depth: depth)
        case 0xDE: return try decodeMap(&r, count: Int(try r.u16()), depth: depth)
        case 0xDF: return try decodeMap(&r, count: Int(try r.u32()), depth: depth)
        default: throw MsgPackError.invalidByte(b)
        }
    }

    private static func decodeString(_ r: inout ByteReader, count: Int) throws -> MsgPack {
        guard let s = String(data: try r.bytes(count), encoding: .utf8) else { throw MsgPackError.invalidUTF8 }
        return .string(s)
    }

    private static func decodeExt(_ r: inout ByteReader, count: Int) throws -> MsgPack {
        let type = Int8(bitPattern: try r.u8())
        return .ext(type: type, data: try r.bytes(count))
    }

    private static func decodeArray(_ r: inout ByteReader, count: Int, depth: Int) throws -> MsgPack {
        guard count <= r.remaining else { throw MsgPackError.lengthExceedsInput }
        var items: [MsgPack] = []
        items.reserveCapacity(count)
        for _ in 0..<count { items.append(try decode(&r, depth: depth + 1)) }
        return .array(items)
    }

    private static func decodeMap(_ r: inout ByteReader, count: Int, depth: Int) throws -> MsgPack {
        guard count * 2 <= r.remaining else { throw MsgPackError.lengthExceedsInput }
        var entries: [MsgPackEntry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let key = try decode(&r, depth: depth + 1)
            entries.append(MsgPackEntry(key, try decode(&r, depth: depth + 1)))
        }
        return .map(entries)
    }
}
