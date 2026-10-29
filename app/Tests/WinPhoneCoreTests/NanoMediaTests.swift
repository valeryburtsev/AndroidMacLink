import XCTest
@testable import WinPhoneCore

/// The video and input packets of screen mirroring, against bytes recorded from Windows
/// mirroring the phone on 2026-10-09. The bytes here are headers only: no picture.
final class NanoMediaTests: XCTestCase {
    func testTheVideoHandshakesAsRecorded() throws {
        let offer = try XCTUnwrap(Data(hexString: "01000000" + "01000000" + "2c000000" + "06000000" + "d0020000" + "40060000" + "3c000000" + "4e8fa51fa1010000"
                                                  + "01000000" + "3c000000" + "d0020000" + "40060000" + "00000000"))
        let format = NanoVideoFormat(framesPerSecond: 60, width: 720, height: 1600)
        XCTAssertEqual(try NanoVideoPacket(offer), .serverHandshake(version: 6, width: 720, height: 1600, framesPerSecond: 60, referenceTime: 0x1A1_1FA5_8F4E, formats: [format]))
        XCTAssertEqual(try NanoVideoPacket(offer).encoded(), offer)
        let answer = try XCTUnwrap(Data(hexString: "02000000" + "01000000" + "14000000" + "afc5cd3a" + "3c000000" + "d0020000" + "40060000" + "00000000"))
        XCTAssertEqual(try NanoVideoPacket(answer), .clientHandshake(initialFrameId: 0x3ACD_C5AF, format: format))
        XCTAssertEqual(NanoVideoPacket.clientHandshake(initialFrameId: 0x3ACD_C5AF, format: format).encoded(), answer)
        // "Start, with a whole frame first", and "this frame was shown".
        XCTAssertEqual(NanoVideoPacket.start().encoded().hex, "03000000" + "01000000" + "04000000" + "30000000")
        let shown = try XCTUnwrap(Data(hexString: "03000000" + "01000000" + "10000000" + "81000000" + "afc5cd3a" + "f7b743e70c000000"))
        XCTAssertEqual(NanoVideoPacket.displayed(frameId: 0x3ACD_C5AF, at: 0x0C_E743_B7F7).encoded(), shown)
    }

    func testAFrameIsPutTogetherFromItsPiecesInAnyOrder() throws {
        // The head of a recorded piece: flags 6, the frame's number and time, 68,840 bytes in 54 pieces, this one at 1,275.
        let head = "04000000" + "01000000" + "23000000" + "06000000" + "b0c5cd3a" + "3d3405190c000000" + "00000000" + "e80c0100" + "36000000" + "fb040000" + "00000000" + "03000000" + "aabbcc"
        guard case .data(let flags, let id, let time, _, let total, let count, let offset, let metadata, let data) = try NanoVideoPacket(try XCTUnwrap(Data(hexString: head))) else {
            return XCTFail("not a data packet")
        }
        XCTAssertEqual([flags, id, total, count, offset], [6, 0x3ACD_C5B0, 68_840, 54, 1275])
        XCTAssertEqual(time, 0x0C_1905_343D)
        XCTAssertEqual(metadata, Data())
        XCTAssertEqual(data, Data([0xAA, 0xBB, 0xCC]))

        func piece(_ frame: UInt32, _ flags: UInt32, _ whole: Data, _ range: Range<Int>) -> NanoVideoPacket {
            .data(flags: flags, frameId: frame, timestamp: 7, reserved: 0, totalSize: UInt32(whole.count), packetCount: 3, offset: UInt32(range.lowerBound), metadata: Data(),
                  data: whole.subdata(in: range))
        }
        let picture = Data((0..<2500).map { UInt8(truncatingIfNeeded: $0) })
        var assembler = NanoVideoAssembler()
        XCTAssertNil(assembler.add(piece(10, 6, picture, 2000..<2500)))
        XCTAssertNil(assembler.add(piece(10, 6, picture, 0..<1000)))
        XCTAssertNil(assembler.add(piece(10, 6, picture, 0..<1000)), "a piece that comes twice counts once")
        let frame = try XCTUnwrap(assembler.add(piece(10, 6, picture, 1000..<2000)))
        XCTAssertEqual(frame, NanoVideoFrame(id: 10, timestamp: 7, isKeyframe: true, data: picture))
        // A piece of a frame from before the last one shown is of no use any more.
        XCTAssertNil(assembler.add(piece(9, 4, picture, 0..<2500)))
        XCTAssertEqual(try XCTUnwrap(assembler.add(piece(12, 4, picture, 0..<2500))).isKeyframe, false)
        // A piece that would reach past its frame's end is dropped.
        XCTAssertNil(assembler.add(.data(flags: 4, frameId: 13, timestamp: 0, reserved: 0, totalSize: 10, packetCount: 1, offset: 8, metadata: Data(), data: Data(count: 5))))
    }

    func testTheInputPacketsAsRecorded() throws {
        let offer = try XCTUnwrap(Data(hexString: "05000000" + "18000000" + "04000000" + "08000000" + "38040000" + "60090000" + "0a000000" + "82e5a3c2"))
        XCTAssertEqual(try NanoInputPacket(offer), .serverHandshake(version: 4, capabilities: 8, width: 1080, height: 2400, maxTouches: 10, firstFrameId: 0xC2A3_E582))
        let answer = try XCTUnwrap(Data(hexString: "06000000" + "14000000" + "04000000" + "08000000" + "0a000000" + "44c3701fa1010000"))
        XCTAssertEqual(NanoInputPacket.clientHandshake(version: 4, capabilities: 8, maxTouches: 10, referenceTime: 0x1A1_1F70_C344).encoded(), answer)
        XCTAssertEqual(try NanoInputPacket(try XCTUnwrap(Data(hexString: "03000000" + "04000000" + "83e5a3c2"))), .frameAck(frameId: 0xC2A3_E583))
        // The first pointer frame of the recording: a position, nothing pressed.
        let body = "000100000000" + "0000" + "00000000000000" + "11040000" + "6c020000" + "00000000" + "00000000" + "0000000000000000"
        let frame = try XCTUnwrap(Data(hexString: "07000000" + "33000000" + "83e5a3c2" + "0268ade70c000000" + body))
        XCTAssertEqual(try NanoInputPacket(frame), .frame(frameId: 0xC2A3_E583, timestamp: 0x0C_E7AD_6802, body: try XCTUnwrap(Data(hexString: body))))
        var pointer = NanoPointerState()
        pointer.x = 1041
        pointer.y = 620
        XCTAssertEqual(pointer.frameBody().hex, body)
        XCTAssertEqual(NanoInputPacket.frame(frameId: 0xC2A3_E583, timestamp: 0x0C_E7AD_6802, body: pointer.frameBody()).encoded(), frame)
        // A press and a release each count; the wheel adds up, as after the recorded scroll.
        pointer.setPressed(true)
        pointer.setPressed(true)
        XCTAssertEqual(pointer.leftButton, 1)
        pointer.setPressed(false)
        XCTAssertEqual(pointer.leftButton, 2)
        pointer.wheelX = -480
        pointer.wheelY = 1800
        XCTAssertEqual(pointer.frameBody().hex.suffix(32), "20feffff" + "08070000" + "0000000000000000")
    }

    func testTheSoundPacketsAsRecorded() throws {
        // The kind of a sound packet is the datagram's payload type; these are the bodies.
        let format = NanoAudioFormat(channels: 2, sampleRate: 48_000)
        let offer = try XCTUnwrap(Data(hexString: "07000000" + "4e8fa51fa1010000" + "01000000" + "02000000" + "80bb0000" + "00000000"))
        XCTAssertEqual(try NanoAudioPacket(payloadType: 36, offer), .serverHandshake(version: 7, referenceTime: 0x1A1_1FA5_8F4E, formats: [format]))
        let answer = NanoAudioPacket.clientHandshake(initialFrameId: 0xA151_98DE, format: format)
        XCTAssertEqual(answer.encoded().hex, "de9851a1" + "02000000" + "80bb0000" + "00000000")
        XCTAssertEqual(answer.payloadType, 37)
        let start = NanoAudioPacket.control(flags: NanoAudioPacket.startStream)
        XCTAssertEqual(start.encoded().hex, "10000000")
        XCTAssertEqual(start.payloadType, 38)
        let frame = NanoAudioPacket.data(flags: 4, frameId: 9, timestamp: 40_000, data: Data([1, 2, 3]))
        XCTAssertEqual(try NanoAudioPacket(payloadType: frame.payloadType, frame.encoded()), frame)
        XCTAssertThrowsError(try NanoAudioPacket(payloadType: 39, Data([1, 2, 3])))
    }

    func testAKeyFrameAsRecorded() {
        // The window's Back button in the recording, pressed and released.
        XCTAssertEqual(NanoKey.frameBody(key: NanoKey.back, count: 1).hex, "00000001000000016e010000000000000000")
        XCTAssertEqual(NanoKey.frameBody(key: NanoKey.back, count: 2).hex, "00000001000000016e020000000000000000")
        XCTAssertEqual([NanoKey.home, NanoKey.recents, NanoKey.back], [106, 109, 110], "the phone's own numbers for its three buttons")
    }

    func testAStreamIsCutIntoItsUnits() {
        let stream = Data([0, 0, 0, 1, 0x67, 9, 9, 0, 0, 1, 0x68, 8, 0, 0, 0, 1, 0x65, 1, 2, 3])
        XCTAssertEqual(H264.units(in: stream), [Data([0x67, 9, 9]), Data([0x68, 8]), Data([0x65, 1, 2, 3])])
        XCTAssertEqual(H264.units(in: Data([1, 2, 3])), [])
    }
}
