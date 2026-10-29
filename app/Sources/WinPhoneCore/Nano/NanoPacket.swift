import CommonCrypto
import CryptoKit
import Foundation

// First stones of the peer-to-peer transport Microsoft calls Nano, which file transfer and
// screen mirroring use: the outer packet header and the encryption around every datagram.
// The layouts come from static reading of the phone's native library
// (`protocol/specs/nano-wire-notes.md`). Nothing here has met a recorded packet yet; the key
// derivation is checked against the published SRTP test vector.

/// The 12-byte RTP header every Nano datagram starts with.
public struct NanoHeader: Equatable, Sendable {
    public static let length = 12

    /// What the payload is for. Values 35 to 63 carry channel data.
    public enum Kind: Equatable, Sendable {
        case channelData, linkControl, muxControl, fecControl, securityControl, rateControl, keepAlive, probing, rateControlNoData, other

        init(payloadType: UInt8) {
            switch payloadType {
            case 35...63: self = .channelData
            case 96: self = .linkControl
            case 97: self = .muxControl
            case 98: self = .fecControl
            case 99: self = .securityControl
            case 100: self = .rateControl
            case 101: self = .keepAlive
            case 102: self = .probing
            case 104: self = .rateControlNoData
            default: self = .other
            }
        }
    }

    public var marker: Bool
    public var payloadType: UInt8
    /// On the wire this is the encryption layer's own packet counter, not a channel's.
    public var sequence: UInt16
    public var timestamp: UInt32
    public var ssrc: UInt32

    public init(marker: Bool = false, payloadType: UInt8, sequence: UInt16, timestamp: UInt32 = 0, ssrc: UInt32) {
        self.marker = marker
        self.payloadType = payloadType
        self.sequence = sequence
        self.timestamp = timestamp
        self.ssrc = ssrc
    }

    public var kind: Kind { Kind(payloadType: payloadType) }
    /// The high half of the SSRC, read as the connection's number.
    public var connectionId: UInt16 { UInt16(truncatingIfNeeded: ssrc >> 16) }
    /// The low half of the SSRC: the channel the multiplexer routes by.
    public var channelId: UInt16 { UInt16(truncatingIfNeeded: ssrc) }

    /// Parses the header. Returns nil for anything but RTP version 2 without CSRC entries,
    /// and for the byte range the library treats as RTCP.
    public init?(_ datagram: Data) {
        guard datagram.count >= NanoHeader.length else { return nil }
        let bytes = [UInt8](datagram.prefix(NanoHeader.length))
        guard bytes[0] >> 6 == 2, bytes[0] & 0x0F == 0, !(0xC1...0xDF).contains(bytes[1]) else { return nil }
        marker = bytes[1] & 0x80 != 0
        payloadType = bytes[1] & 0x7F
        sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = bytes[4..<8].reduce(0) { $0 << 8 | UInt32($1) }
        ssrc = bytes[8..<12].reduce(0) { $0 << 8 | UInt32($1) }
    }

    public func encoded() -> Data {
        var bytes: [UInt8] = [0x80, (marker ? 0x80 : 0) | (payloadType & 0x7F), UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: timestamp >> UInt32(shift))) }
        for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: ssrc >> UInt32(shift))) }
        return Data(bytes)
    }
}

/// The session keys of one Nano connection, derived from the master key and salt that the
/// two devices exchange in their connection descriptions.
public struct NanoSessionKeys: Equatable, Sendable {
    public enum KeyError: Error, Equatable {
        case wrongLength
        case cipherFailed
    }

    /// 16 bytes, for AES-128-GCM.
    public var encryptionKey: Data
    /// 14 bytes; the last 12 seed each packet's nonce.
    public var salt: Data

    public init(encryptionKey: Data, salt: Data) {
        self.encryptionKey = encryptionKey
        self.salt = salt
    }

    /// Derives the session keys as SRTP does (RFC 3711, section 4.3.1, derivation rate 0):
    /// each is the start of an AES counter-mode keystream under the master key, whose first
    /// counter block is the master salt with the key's label mixed into byte 7.
    public init(masterKey: Data, masterSalt: Data) throws {
        guard masterKey.count == 16, masterSalt.count == 14 else { throw KeyError.wrongLength }
        encryptionKey = try NanoSessionKeys.derive(label: 0, length: 16, masterKey: masterKey, masterSalt: masterSalt)
        salt = try NanoSessionKeys.derive(label: 2, length: 14, masterKey: masterKey, masterSalt: masterSalt)
    }

    /// The master key and salt as they appear in a connection description: hexadecimal text.
    public init(keyHex: String, saltHex: String) throws {
        guard let key = Data(hexString: keyHex), let salt = Data(hexString: saltHex) else { throw KeyError.wrongLength }
        try self.init(masterKey: key, masterSalt: salt)
    }

    static func derive(label: UInt8, length: Int, masterKey: Data, masterSalt: Data) throws -> Data {
        var block = [UInt8](masterSalt) + [0, 0]
        block[7] ^= label
        var output = Data()
        while output.count < length {
            output.append(try aesBlock(block, key: masterKey))
            // The counter is the block's last 16 bits.
            let counter = (UInt16(block[14]) << 8 | UInt16(block[15])) &+ 1
            block[14] = UInt8(counter >> 8)
            block[15] = UInt8(counter & 0xFF)
        }
        return output.prefix(length)
    }

    /// One AES block, encrypted as it stands.
    private static func aesBlock(_ block: [UInt8], key: Data) throws -> Data {
        var output = [UInt8](repeating: 0, count: kCCBlockSizeAES128 * 2)
        var written = 0
        let status = key.withUnsafeBytes { keyBytes in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), keyBytes.baseAddress, key.count, nil,
                    block, block.count, &output, output.count, &written)
        }
        guard status == kCCSuccess, written >= kCCBlockSizeAES128 else { throw KeyError.cipherFailed }
        return Data(output.prefix(kCCBlockSizeAES128))
    }

    /// The nonce of one packet: the last 12 salt bytes, with the SSRC and the 48-bit packet
    /// index (roll-over count and sequence number) mixed in.
    func nonce(ssrc: UInt32, rollover: UInt32, sequence: UInt16) -> Data {
        var bytes = [UInt8](salt.suffix(12))
        let mix: [UInt8] = [0, 0, UInt8(truncatingIfNeeded: ssrc >> 24), UInt8(truncatingIfNeeded: ssrc >> 16), UInt8(truncatingIfNeeded: ssrc >> 8),
                            UInt8(truncatingIfNeeded: ssrc), UInt8(truncatingIfNeeded: rollover >> 24), UInt8(truncatingIfNeeded: rollover >> 16),
                            UInt8(truncatingIfNeeded: rollover >> 8), UInt8(truncatingIfNeeded: rollover), UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
        for index in 0..<12 { bytes[index] ^= mix[index] }
        return Data(bytes)
    }
}

/// One datagram, opened: its header, what the next layer gets, and the sequence number that
/// layer had given it, which travels encrypted at the end.
public struct NanoDatagram: Equatable, Sendable {
    public enum DatagramError: Error, Equatable {
        case tooShort
        case notRTP
        /// The authentication check failed: wrong key, wrong roll-over count, or damage.
        case notAuthentic
    }

    /// Bytes each datagram spends on the header, the inner sequence number and the tag.
    public static let overhead = NanoHeader.length + 2 + 16

    public var header: NanoHeader
    public var payload: Data
    /// The upper layer's own 16-bit sequence number.
    public var innerSequence: UInt16

    public init(header: NanoHeader, payload: Data, innerSequence: UInt16) {
        self.header = header
        self.payload = payload
        self.innerSequence = innerSequence
    }

    /// Opens a recorded or received datagram.
    /// - Parameter rollover: how often the header's sequence number has wrapped in this
    ///   direction; zero for the first 65,536 packets.
    public init(opening datagram: Data, keys: NanoSessionKeys, rollover: UInt32 = 0) throws {
        guard datagram.count >= NanoDatagram.overhead else { throw DatagramError.tooShort }
        guard let header = NanoHeader(datagram) else { throw DatagramError.notRTP }
        let associated = datagram.prefix(NanoHeader.length)
        let body = datagram.dropFirst(NanoHeader.length)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: keys.nonce(ssrc: header.ssrc, rollover: rollover, sequence: header.sequence)),
                                            ciphertext: body.dropLast(16), tag: body.suffix(16))
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: keys.encryptionKey), authenticating: associated)
            guard plain.count >= 2 else { throw DatagramError.tooShort }
            self.header = header
            payload = Data(plain.dropLast(2))
            // Stored as the machine had it, low byte first.
            innerSequence = UInt16(plain[plain.endIndex - 2]) | UInt16(plain[plain.endIndex - 1]) << 8
        } catch let error as DatagramError {
            throw error
        } catch {
            throw DatagramError.notAuthentic
        }
    }

    /// Builds the datagram as it goes on the wire.
    public func sealed(with keys: NanoSessionKeys, rollover: UInt32 = 0) throws -> Data {
        let head = header.encoded()
        let plain = payload + Data([UInt8(innerSequence & 0xFF), UInt8(innerSequence >> 8)])
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: keys.encryptionKey),
                                   nonce: AES.GCM.Nonce(data: keys.nonce(ssrc: header.ssrc, rollover: rollover, sequence: header.sequence)),
                                   authenticating: head)
        return head + box.ciphertext + box.tag
    }
}

extension Data {
    /// Bytes from hexadecimal text, or nil when it is not that.
    init?(hexString: String) {
        let characters = Array(hexString.utf8)
        guard characters.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let high = UInt8(String(UnicodeScalar(characters[index])), radix: 16),
                  let low = UInt8(String(UnicodeScalar(characters[index + 1])), radix: 16) else { return nil }
            bytes.append(high << 4 | low)
        }
        self.init(bytes)
    }
}
