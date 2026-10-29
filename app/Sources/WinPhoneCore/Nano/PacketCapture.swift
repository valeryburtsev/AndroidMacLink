import Foundation

/// Reads UDP datagrams out of a packet capture file as `tcpdump -w` writes it (classic pcap,
/// Ethernet, loopback or raw IP link types). For checking the Nano decoder against a recording.
public enum PacketCapture {
    public struct Datagram: Equatable, Sendable {
        public var source: String
        public var destination: String
        public var payload: Data
        /// Seconds since 1970, as the capture recorded it.
        public var time: Double = 0
    }

    public enum CaptureError: Error, Equatable {
        /// The newer pcapng format; convert it with `tcpdump -r in.pcapng -w out.pcap`.
        case pcapng
        case notACapture
        case unsupportedLinkType(UInt32)
    }

    public static func udpDatagrams(in file: Data) throws -> [Datagram] {
        let bytes = [UInt8](file)
        guard bytes.count >= 24 else { throw CaptureError.notACapture }
        let magic = bytes[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        if magic == 0x0A0D0D0A { throw CaptureError.pcapng }
        let littleEndian: Bool
        switch magic {
        case 0xD4C3B2A1, 0x4D3CB2A1: littleEndian = true
        case 0xA1B2C3D4, 0xA1B23C4D: littleEndian = false
        default: throw CaptureError.notACapture
        }
        func word(_ offset: Int) -> UInt32 {
            let slice = bytes[offset..<(offset + 4)]
            return littleEndian ? slice.reversed().reduce(0) { $0 << 8 | UInt32($1) } : slice.reduce(0) { $0 << 8 | UInt32($1) }
        }
        let linkType = word(20)
        var result: [Datagram] = []
        var offset = 24
        while offset + 16 <= bytes.count {
            let captured = Int(word(offset + 8))
            let time = Double(word(offset)) + Double(word(offset + 4)) / (magic == 0x4D3CB2A1 || magic == 0xA1B23C4D ? 1_000_000_000 : 1_000_000)
            offset += 16
            guard captured >= 0, offset + captured <= bytes.count else { break }
            let frame = Array(bytes[offset..<(offset + captured)])
            offset += captured
            var ip = 0
            switch linkType {
            case 1:
                // Ethernet, with VLAN tags skipped.
                guard frame.count >= 14 else { continue }
                var type = UInt16(frame[12]) << 8 | UInt16(frame[13])
                ip = 14
                while type == 0x8100, frame.count >= ip + 4 {
                    type = UInt16(frame[ip + 2]) << 8 | UInt16(frame[ip + 3])
                    ip += 4
                }
                guard type == 0x0800 || type == 0x86DD else { continue }
            case 0, 108: ip = 4
            case 12, 101, 228, 229: ip = 0
            default: throw CaptureError.unsupportedLinkType(linkType)
            }
            if var datagram = udp(in: frame, at: ip) {
                datagram.time = time
                result.append(datagram)
            }
        }
        return result
    }

    private static func udp(in frame: [UInt8], at start: Int) -> Datagram? {
        guard frame.count > start else { return nil }
        var transport: Int
        let source: String, destination: String
        switch frame[start] >> 4 {
        case 4:
            let headerLength = Int(frame[start] & 0x0F) * 4
            guard headerLength >= 20, frame.count >= start + headerLength, frame[start + 9] == 17 else { return nil }
            // Only the first fragment of a datagram carries the UDP header; later ones are skipped.
            guard (UInt16(frame[start + 6]) << 8 | UInt16(frame[start + 7])) & 0x1FFF == 0 else { return nil }
            source = frame[(start + 12)..<(start + 16)].map(String.init).joined(separator: ".")
            destination = frame[(start + 16)..<(start + 20)].map(String.init).joined(separator: ".")
            transport = start + headerLength
        case 6:
            guard frame.count >= start + 40, frame[start + 6] == 17 else { return nil }
            func address(_ at: Int) -> String {
                stride(from: at, to: at + 16, by: 2).map { String(UInt16(frame[$0]) << 8 | UInt16(frame[$0 + 1]), radix: 16) }.joined(separator: ":")
            }
            source = address(start + 8)
            destination = address(start + 24)
            transport = start + 40
        default:
            return nil
        }
        guard frame.count >= transport + 8 else { return nil }
        let sourcePort = UInt16(frame[transport]) << 8 | UInt16(frame[transport + 1])
        let destinationPort = UInt16(frame[transport + 2]) << 8 | UInt16(frame[transport + 3])
        let length = Int(UInt16(frame[transport + 4]) << 8 | UInt16(frame[transport + 5]))
        transport += 8
        let end = min(frame.count, transport + max(0, length - 8))
        guard end >= transport else { return nil }
        return Datagram(source: "\(source):\(sourcePort)", destination: "\(destination):\(destinationPort)", payload: Data(frame[transport..<end]))
    }
}
