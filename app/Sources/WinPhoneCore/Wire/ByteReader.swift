import Foundation

/// Bounds-checked sequential reader over `Data`.
public struct ByteReader {
    private let data: Data
    private var offset: Int

    public init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    public var remaining: Int { data.endIndex - offset }
    public var position: Int { offset - data.startIndex }

    public mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw MsgPackError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    public mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw MsgPackError.truncated }
        defer { offset += count }
        return Data(data[offset..<offset + count])
    }

    public mutating func u16() throws -> UInt16 { UInt16(try bigEndian(2)) }
    public mutating func u32() throws -> UInt32 { UInt32(try bigEndian(4)) }
    public mutating func u64() throws -> UInt64 { try bigEndian(8) }

    public mutating func u16LE() throws -> UInt16 { UInt16(try littleEndian(2)) }
    public mutating func u32LE() throws -> UInt32 { UInt32(try littleEndian(4)) }
    /// Everything not yet read.
    public mutating func rest() -> Data { (try? bytes(remaining)) ?? Data() }
    public mutating func u64LE() throws -> UInt64 { try littleEndian(8) }

    private mutating func bigEndian(_ count: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for byte in try bytes(count) { value = value << 8 | UInt64(byte) }
        return value
    }

    private mutating func littleEndian(_ count: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for (i, byte) in try bytes(count).enumerated() { value |= UInt64(byte) << (8 * UInt64(i)) }
        return value
    }
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
