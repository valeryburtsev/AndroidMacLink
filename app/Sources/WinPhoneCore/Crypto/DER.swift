import Foundation

/// A minimal DER writer and reader: just enough ASN.1 to build a self-signed X.509 certificate
/// and to read the fields we need back out of one.
public enum DER {
    public static func encode(tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var bytes: [UInt8] = []
            var v = n
            while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        out.append(content)
        return out
    }

    public static func sequence(_ items: Data...) -> Data { encode(tag: 0x30, items.reduce(Data(), +)) }
    public static func set(_ items: Data...) -> Data { encode(tag: 0x31, items.reduce(Data(), +)) }
    public static func octetString(_ data: Data) -> Data { encode(tag: 0x04, data) }
    public static func bitString(_ data: Data, unusedBits: UInt8 = 0) -> Data { encode(tag: 0x03, Data([unusedBits]) + data) }
    public static func utf8String(_ s: String) -> Data { encode(tag: 0x0C, Data(s.utf8)) }
    public static func printableString(_ s: String) -> Data { encode(tag: 0x13, Data(s.utf8)) }

    /// The string type Windows picks for a certificate name: PrintableString when every character
    /// is in that alphabet, BMPString otherwise. A GUID is printable; `trust_<guid>` is not,
    /// because of the underscore.
    public static func directoryString(_ s: String) -> Data {
        let printable = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 '()+,-./:=?")
        return s.unicodeScalars.allSatisfy(printable.contains) ? printableString(s) : bmpString(s)
    }

    /// UTF-16 big-endian string, the form Windows uses for certificate names.
    public static func bmpString(_ s: String) -> Data { encode(tag: 0x1E, s.data(using: .utf16BigEndian) ?? Data()) }
    public static func boolean(_ value: Bool) -> Data { encode(tag: 0x01, Data([value ? 0xFF : 0x00])) }
    public static func explicit(_ number: UInt8, _ content: Data) -> Data { encode(tag: 0xA0 | number, content) }

    /// A non-negative INTEGER from big-endian magnitude bytes.
    public static func integer(_ magnitude: Data) -> Data {
        var bytes = Data(magnitude.drop { $0 == 0 })
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes[bytes.startIndex] & 0x80 != 0 { bytes.insert(0, at: bytes.startIndex) }
        return encode(tag: 0x02, bytes)
    }

    public static func integer(_ value: Int) -> Data {
        var bytes: [UInt8] = []
        var v = value
        repeat { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 } while v > 0
        return integer(Data(bytes))
    }

    public static func objectIdentifier(_ components: [UInt]) -> Data {
        precondition(components.count >= 2)
        var out = Data([UInt8(components[0] * 40 + components[1])])
        for component in components.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(component & 0x7F)]
            var v = component >> 7
            while v > 0 { chunk.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            out.append(contentsOf: chunk)
        }
        return encode(tag: 0x06, out)
    }

    /// UTCTime for years 1950-2049, GeneralizedTime otherwise, as X.509 requires.
    public static func time(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let tail = String(format: "%02d%02d%02d%02d%02dZ", c.month!, c.day!, c.hour!, c.minute!, c.second!)
        if (1950...2049).contains(c.year!) {
            return encode(tag: 0x17, Data((String(format: "%02d", c.year! % 100) + tail).utf8))
        }
        return encode(tag: 0x18, Data((String(format: "%04d", c.year!) + tail).utf8))
    }

    // MARK: Reading

    public struct Node {
        public let tag: UInt8
        public let content: Data
        /// The full encoding, header included.
        public let raw: Data

        public func children() throws -> [Node] { try DER.parseAll(content) }
    }

    public enum ParseError: Error { case truncated, unsupportedLength, trailingData }

    public static func parse(_ data: Data) throws -> Node {
        let nodes = try parseAll(data)
        guard nodes.count == 1 else { throw ParseError.trailingData }
        return nodes[0]
    }

    public static func parseAll(_ data: Data) throws -> [Node] {
        var nodes: [Node] = []
        var i = data.startIndex
        while i < data.endIndex {
            let start = i
            let tag = data[i]; i += 1
            guard i < data.endIndex else { throw ParseError.truncated }
            var length = Int(data[i]); i += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count >= 1, count <= 4, data.endIndex - i >= count else { throw ParseError.unsupportedLength }
                length = 0
                for _ in 0..<count { length = length << 8 | Int(data[i]); i += 1 }
            }
            guard data.endIndex - i >= length else { throw ParseError.truncated }
            nodes.append(Node(tag: tag, content: Data(data[i..<i + length]), raw: Data(data[start..<i + length])))
            i += length
        }
        return nodes
    }
}
