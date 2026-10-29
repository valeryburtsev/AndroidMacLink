import XCTest
@testable import WinPhoneCore

/// The outer layers of the peer-to-peer transport. No recorded packet exists yet, so these
/// check the parts that have a public reference and that the two directions agree.
final class NanoPacketTests: XCTestCase {
    /// The key derivation example of RFC 3711, appendix B.3.
    func testSessionKeysMatchThePublishedSRTPDerivation() throws {
        let masterKey = Data(hex: "E1F97A0D3E018BE0D64FA32C06DE4139"), masterSalt = Data(hex: "0EC675AD498AFEEBB6960B3AABE6")
        let keys = try NanoSessionKeys(masterKey: masterKey, masterSalt: masterSalt)
        XCTAssertEqual(keys.encryptionKey.hex.uppercased(), "C61E7A93744F39EE10734AFE3FF7A087")
        XCTAssertEqual(keys.salt.hex.uppercased(), "30CBBC08863D8C85D49DB34A9AE1")
        // The authentication key, unused with this cipher, shows the counter running on
        // past one block.
        let authentication = try NanoSessionKeys.derive(label: 1, length: 20, masterKey: masterKey, masterSalt: masterSalt)
        XCTAssertEqual(authentication.hex.uppercased(), "CEBE321F6FF7716B6FD4AB49AF256A156D38BAA4")
        // The same keys from the text form used in a connection description.
        XCTAssertEqual(try NanoSessionKeys(keyHex: "e1f97a0d3e018be0d64fa32c06de4139", saltHex: "0ec675ad498afeebb6960b3aabe6"), keys)
        XCTAssertThrowsError(try NanoSessionKeys(masterKey: Data(count: 15), masterSalt: masterSalt))
        XCTAssertThrowsError(try NanoSessionKeys(keyHex: "zz", saltHex: "00"))
    }

    func testTheHeaderIsPlainRTPWithTheChannelInTheLowHalfOfTheSSRC() throws {
        let header = try XCTUnwrap(NanoHeader(Data(hex: "80e5001200000040" + "00070023")))
        XCTAssertTrue(header.marker)
        XCTAssertEqual(header.payloadType, 101)
        XCTAssertEqual(header.kind, .keepAlive)
        XCTAssertEqual(header.sequence, 0x12)
        XCTAssertEqual(header.timestamp, 0x40)
        XCTAssertEqual(header.connectionId, 7)
        XCTAssertEqual(header.channelId, 0x23)
        XCTAssertEqual(header.encoded().hex, "80e500120000004000070023")
        XCTAssertEqual(NanoHeader.Kind(payloadType: 35), .channelData)
        XCTAssertEqual(NanoHeader.Kind(payloadType: 63), .channelData)
        XCTAssertEqual(NanoHeader.Kind(payloadType: 97), .muxControl)
        XCTAssertEqual(NanoHeader.Kind(payloadType: 100), .rateControl)
        XCTAssertEqual(NanoHeader.Kind(payloadType: 104), .rateControlNoData)
        XCTAssertNil(NanoHeader(Data(hex: "40e5001200000040" + "00070023")), "not version 2")
        XCTAssertNil(NanoHeader(Data(hex: "80c8001200000040" + "00070023")), "the range read as RTCP")
        XCTAssertNil(NanoHeader(Data(hex: "80e500")))
    }

    func testTheNonceMixesSSRCAndPacketIndexIntoTheLastTwelveSaltBytes() {
        let keys = NanoSessionKeys(encryptionKey: Data(count: 16), salt: Data(hex: "aaaa" + "000000000000000000000000"))
        XCTAssertEqual(keys.nonce(ssrc: 0x01020304, rollover: 0x0A0B0C0D, sequence: 0xFFEE).hex, "0000010203040a0b0c0dffee")
        let salted = NanoSessionKeys(encryptionKey: Data(count: 16), salt: Data(hex: "aaaa" + "ffffffffffffffffffffffff"))
        XCTAssertEqual(salted.nonce(ssrc: 0, rollover: 0, sequence: 1).hex, "fffffffffffffffffffffffe")
    }

    func testADatagramSealsAndOpensAndTamperingIsNoticed() throws {
        let keys = try NanoSessionKeys(keyHex: "e1f97a0d3e018be0d64fa32c06de4139", saltHex: "0ec675ad498afeebb6960b3aabe6")
        let original = NanoDatagram(header: NanoHeader(payloadType: 100, sequence: 3, timestamp: 9, ssrc: 0x00010000), payload: Data("syn".utf8), innerSequence: 0x1234)
        let wire = try original.sealed(with: keys)
        XCTAssertEqual(wire.count, 3 + NanoDatagram.overhead, "thirty bytes around every payload")
        XCTAssertEqual(wire.prefix(12), original.header.encoded(), "the header travels in the clear")
        XCTAssertEqual(try NanoDatagram(opening: wire, keys: keys), original)

        var damaged = wire
        damaged[14] ^= 1
        XCTAssertThrowsError(try NanoDatagram(opening: damaged, keys: keys)) { XCTAssertEqual($0 as? NanoDatagram.DatagramError, .notAuthentic) }
        var relabelled = wire
        relabelled[1] = 97
        XCTAssertThrowsError(try NanoDatagram(opening: relabelled, keys: keys), "the header is covered by the check")
        XCTAssertThrowsError(try NanoDatagram(opening: wire, keys: keys, rollover: 1), "a wrong roll-over count gives a wrong nonce")
        XCTAssertThrowsError(try NanoDatagram(opening: wire.prefix(20), keys: keys)) { XCTAssertEqual($0 as? NanoDatagram.DatagramError, .tooShort) }
        let other = try NanoSessionKeys(keyHex: "00000000000000000000000000000000", saltHex: "0ec675ad498afeebb6960b3aabe6")
        XCTAssertThrowsError(try NanoDatagram(opening: wire, keys: other))
    }

    /// A capture file as tcpdump writes it, built here: one Ethernet frame with an encrypted
    /// Nano datagram, one that is not UDP.
    func testDatagramsAreReadFromACaptureFileAndOpen() throws {
        let keys = try NanoSessionKeys(keyHex: "e1f97a0d3e018be0d64fa32c06de4139", saltHex: "0ec675ad498afeebb6960b3aabe6")
        let nano = try NanoDatagram(header: NanoHeader(payloadType: 101, sequence: 1, ssrc: 0x00010000), payload: Data([1, 2, 3, 4, 5, 6, 7, 8]), innerSequence: 7).sealed(with: keys)
        func little(_ value: UInt32) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)] }
        func frame(protocolNumber: UInt8, payload: Data) -> [UInt8] {
            let udpLength = UInt16(8 + payload.count)
            var bytes: [UInt8] = Array(repeating: 0, count: 12) + [0x08, 0x00]
            bytes += [0x45, 0, 0, 0, 0, 0, 0, 0, 64, protocolNumber, 0, 0, 192, 168, 140, 128, 192, 168, 1, 20]
            bytes += [0xC0, 0x01, 0x13, 0x88, UInt8(udpLength >> 8), UInt8(udpLength & 0xFF), 0, 0]
            return bytes + [UInt8](payload)
        }
        var file: [UInt8] = [0xD4, 0xC3, 0xB2, 0xA1, 2, 0, 4, 0] + Array(repeating: 0, count: 8) + little(65535) + little(1)
        for packet in [frame(protocolNumber: 17, payload: nano), frame(protocolNumber: 6, payload: Data([9, 9]))] {
            file += little(0) + little(0) + little(UInt32(packet.count)) + little(UInt32(packet.count)) + packet
        }
        let datagrams = try PacketCapture.udpDatagrams(in: Data(file))
        XCTAssertEqual(datagrams.count, 1, "the TCP frame is left out")
        XCTAssertEqual(datagrams[0].source, "192.168.140.128:49153")
        XCTAssertEqual(datagrams[0].destination, "192.168.1.20:5000")
        let opened = try NanoDatagram(opening: datagrams[0].payload, keys: keys)
        XCTAssertEqual(opened.header.kind, .keepAlive)
        XCTAssertEqual(opened.innerSequence, 7)
        XCTAssertThrowsError(try PacketCapture.udpDatagrams(in: Data([0x0A, 0x0D, 0x0D, 0x0A] + Array(repeating: UInt8(0), count: 24)))) {
            XCTAssertEqual($0 as? PacketCapture.CaptureError, .pcapng)
        }
        XCTAssertThrowsError(try PacketCapture.udpDatagrams(in: Data(count: 40)))
    }
}
