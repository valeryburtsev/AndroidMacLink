import Foundation

/// The binary envelope around every PLATFORM and APP message carried in a DCG fragment.
///
/// Layout: `u8 version (1)`, `u32le headerBytes`, `u32le headerCount`, then for each header a
/// `u32le` length plus UTF-8 key and a `u32le` length plus UTF-8 value, then `u64le payloadLength`
/// and the payload. Windows counts the four `headerCount` bytes inside `headerBytes`; Android does
/// not. Both are accepted, and the convention is remembered so a message re-encodes unchanged.
public struct PlatformEnvelope: Equatable, Sendable {
    public enum Convention: Equatable, Sendable {
        /// `headerBytes` includes the header count field. Used by Phone Link.
        case windows
        /// `headerBytes` covers only the header entries. Used by Link to Windows.
        case android
    }

    public enum Header {
        public static let route = "_route"
        public static let requestId = "_requestId"
        public static let originalRequestId = "_originalRequestId"
        public static let rejectionVersion = "_rejectionVersion"
        public static let rejectedReason = "_rejectedReason"
        /// `"true"` when the payload is a gzip stream around the real payload.
        public static let gzipped = "_isGzippedCompressed"
        /// On APP replies: the scenario result code, repeated from the value set.
        public static let result = "result"
        public static let contentType = "ms-content-type"
    }

    public enum DecodeError: Error, Equatable {
        case unsupportedVersion(UInt8)
        case truncated
        case tooManyHeaders(UInt32)
        case invalidUTF8
        case headerLengthMismatch(declared: UInt32, actual: Int)
        case payloadLengthMismatch(declared: UInt64, remaining: Int)
    }

    /// Headers in wire order. Order matters for byte-exact re-encoding.
    public var headers: [(key: String, value: String)]
    public var payload: Data
    public var convention: Convention

    public init(headers: [(key: String, value: String)], payload: Data, convention: Convention = .windows) {
        self.headers = headers
        self.payload = payload
        self.convention = convention
    }

    public static func == (lhs: PlatformEnvelope, rhs: PlatformEnvelope) -> Bool {
        lhs.payload == rhs.payload && lhs.convention == rhs.convention
            && lhs.headers.count == rhs.headers.count
            && zip(lhs.headers, rhs.headers).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    public subscript(header: String) -> String? {
        headers.first { $0.key == header }?.value
    }

    public var route: String? { self[Header.route] }
    public var requestId: String? { self[Header.requestId] }
    public var originalRequestId: String? { self[Header.originalRequestId] }

    public func encoded() -> Data {
        var entries = Data()
        for header in headers {
            let key = Data(header.key.utf8), value = Data(header.value.utf8)
            entries.appendLE(UInt32(key.count)); entries.append(key)
            entries.appendLE(UInt32(value.count)); entries.append(value)
        }
        var out = Data([1])
        out.appendLE(UInt32(entries.count + (convention == .windows ? 4 : 0)))
        out.appendLE(UInt32(headers.count))
        out.append(entries)
        out.appendLE(UInt64(payload.count))
        out.append(payload)
        return out
    }

    public init(decoding data: Data) throws {
        var r = ByteReader(data)
        do {
            let version = try r.u8()
            guard version == 1 else { throw DecodeError.unsupportedVersion(version) }
            let declared = try r.u32LE()
            let count = try r.u32LE()
            guard count <= 64 else { throw DecodeError.tooManyHeaders(count) }
            let start = r.position
            var headers: [(key: String, value: String)] = []
            for _ in 0..<count {
                let key = try r.bytes(Int(try r.u32LE()))
                let value = try r.bytes(Int(try r.u32LE()))
                guard let k = String(data: key, encoding: .utf8), let v = String(data: value, encoding: .utf8) else {
                    throw DecodeError.invalidUTF8
                }
                headers.append((k, v))
            }
            let entryBytes = r.position - start
            if Int(declared) == entryBytes + 4 {
                convention = .windows
            } else if Int(declared) == entryBytes {
                convention = .android
            } else {
                throw DecodeError.headerLengthMismatch(declared: declared, actual: entryBytes)
            }
            let payloadLength = try r.u64LE()
            guard payloadLength == UInt64(r.remaining) else {
                throw DecodeError.payloadLengthMismatch(declared: payloadLength, remaining: r.remaining)
            }
            self.headers = headers
            self.payload = try r.bytes(r.remaining)
        } catch let error as MsgPackError where error == .truncated {
            throw DecodeError.truncated
        }
    }
}
