import XCTest
@testable import WinPhoneCore

final class MessagePackTests: XCTestCase {
    func testKnownVectors() throws {
        let vectors: [(MsgPack, String)] = [
            (.null, "c0"), (.bool(true), "c3"), (.bool(false), "c2"),
            (.int(0), "00"), (.int(127), "7f"), (.int(128), "cc80"), (.int(255), "ccff"), (.int(256), "cd0100"),
            (.int(65535), "cdffff"), (.int(65536), "ce00010000"), (.int(4_294_967_296), "cf0000000100000000"),
            (.int(-1), "ff"), (.int(-32), "e0"), (.int(-33), "d0df"), (.int(-129), "d1ff7f"), (.int(-32769), "d2ffff7fff"),
            (.uint(UInt64.max), "cfffffffffffffffff"),
            (.double(1.0), "cb3ff0000000000000"), (.float(1.5), "ca3fc00000"),
            (.string(""), "a0"), (.string("ms-dcg"), "a66d732d646367"),
            (.binary(Data([1, 2, 3])), "c403010203"),
            (.array([.int(6)]), "9106"),
            (.map([MsgPackEntry(.string("a"), .int(1))]), "81a16101"),
            (.ext(type: 5, data: Data([0xAA, 0xBB, 0xCC, 0xDD])), "d605aabbccdd"),
        ]
        for (value, hex) in vectors {
            XCTAssertEqual(value.encoded().hex, hex, "encode \(value)")
            XCTAssertEqual(try MsgPack.decode(Data(hex: hex)), value, "decode \(hex)")
        }
    }

    func testNonMinimalIntegersKeepTheirWidth() throws {
        // Phone Link writes boxed numbers as int32 even when small.
        XCTAssertEqual(MsgPack.int32(2).encoded().hex, "d200000002")
        XCTAssertEqual(try MsgPack.decode(Data(hex: "d200000002")), .sizedInt(2, format: 0xD2))
        XCTAssertEqual(try MsgPack.decode(Data(hex: "d200000002")).intValue, 2)
        // Link to Windows writes small values as uint8.
        XCTAssertEqual(try MsgPack.decode(Data(hex: "cc01")), .sizedInt(1, format: 0xCC))
        XCTAssertEqual(try MsgPack.decode(Data(hex: "cc01")).encoded().hex, "cc01")
        // A minimal encoding still decodes to the plain case.
        XCTAssertEqual(try MsgPack.decode(Data(hex: "cc80")), .int(128))
        XCTAssertEqual(try MsgPack.decode(Data(hex: "d2ffff7fff")), .int(-32769))
        XCTAssertEqual(MsgPack.sizedInt(-1, format: 0xD2).encoded().hex, "d2ffffffff")
    }

    func testLengthBoundaries() throws {
        for count in [31, 32, 255, 256, 65535, 65536] {
            let string = MsgPack.string(String(repeating: "x", count: count))
            XCTAssertEqual(try MsgPack.decode(string.encoded()), string)
            let binary = MsgPack.binary(Data(repeating: 7, count: count))
            XCTAssertEqual(try MsgPack.decode(binary.encoded()), binary)
        }
        for count in [15, 16, 65535, 65536] {
            let array = MsgPack.array(Array(repeating: .int(1), count: count))
            XCTAssertEqual(try MsgPack.decode(array.encoded()), array)
        }
        let map = MsgPack.map((0..<20).map { MsgPackEntry(.string("k\($0)"), .int(Int64($0))) })
        XCTAssertEqual(try MsgPack.decode(map.encoded()), map)
    }

    func testMalformedInputIsRejected() {
        let good = MsgPack.map(["a": .array([.int(1), .binary(Data([1, 2, 3]))])]).encoded()
        XCTAssertThrowsError(try MsgPack.decode(good.dropLast()))
        XCTAssertThrowsError(try MsgPack.decode(good + [0]))
        XCTAssertThrowsError(try MsgPack.decode(Data([0xC1])))
        XCTAssertThrowsError(try MsgPack.decode(Data([0xDD, 0xFF, 0xFF, 0xFF, 0xFF])))
        XCTAssertThrowsError(try MsgPack.decode(Data(repeating: 0x91, count: 200)))
        XCTAssertThrowsError(try MsgPack.decode(Data([0xA2, 0xFF, 0xFE])))
    }

    func testDecodingASliceWithNonZeroStartIndex() throws {
        let bytes = Data([0xFF, 0xFF]) + MsgPack.string("hello").encoded()
        XCTAssertEqual(try MsgPack.decode(bytes.dropFirst(2)), .string("hello"))
    }

    /// Our encoder must reproduce every real frame byte for byte, for both clients' encoders.
    func testRealFramesRoundTripExactly() throws {
        let frames = try Fixtures.relayFrames()
        XCTAssertGreaterThan(frames.count, 100)
        for frame in frames {
            let value = try MsgPack.decode(frame.bytes)
            XCTAssertEqual(value.encoded(), frame.bytes, "frame from \(frame.fromClient ? "PC" : "phone")")
        }
    }
}
