import XCTest
@testable import WinPhoneCore

/// The acknowledgement vector and the receiver's book of arrivals, against the worked examples
/// of `protocol/specs/nano-wire-notes.md`, section 13.
final class NanoReliabilityTests: XCTestCase {
    typealias Vector = NanoRateHeader.AckVector

    func testAShortVectorIsOneBitmapByteEndingAtTheNewestPacket() {
        // 104 and 105 missing, 106...110 arrived.
        let (coded, count) = Vector.code([false, false, true, true, true, true, true])
        XCTAssertEqual(coded, [0x7C])
        XCTAssertEqual(count, 7)
        // One arrival after the gap: the byte ends at its highest set bit.
        XCTAssertEqual(Vector.code([false, false, true]).coded, [0x04])
        XCTAssertEqual(Vector(baseSequence: 104, timestamp: nil, timeGap: nil, coded: [0x04]).elements, [false, false, true])
    }

    func testLongRunsBecomeRunBytes() {
        // 104 and 105 missing, 106...200 arrived: a bitmap, a run of 63, a run of 27.
        let elements = [false, false] + [Bool](repeating: true, count: 95)
        let (coded, count) = Vector.code(elements)
        XCTAssertEqual(coded, [0x7C, 0xFF, 0xDB])
        XCTAssertEqual(count, 97)
        XCTAssertEqual(Vector(baseSequence: 104, timestamp: nil, timeGap: nil, coded: coded).elements, elements)
        // 160 missing in a row, then 20 arrived: missing runs carry no state bit.
        let burst = [Bool](repeating: false, count: 160) + [Bool](repeating: true, count: 20)
        XCTAssertEqual(Vector.code(burst).coded, [0xBF, 0xBF, 0xA2, 0xD4])
        XCTAssertEqual(Vector(baseSequence: 0, timestamp: nil, timeGap: nil, coded: [0xBF, 0xBF, 0xA2, 0xD4]).elements, burst)
    }

    func testEveryCodingReadsBackAsItWasWritten() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            var elements: [Bool] = [false]
            while elements.count < Int.random(in: 2...400, using: &generator) {
                let state = Bool.random(using: &generator)
                elements.append(contentsOf: repeatElement(state, count: Int.random(in: 1...(Bool.random(using: &generator) ? 3 : 90), using: &generator)))
            }
            elements.append(true)
            let (coded, count) = Vector.code(elements)
            XCTAssertLessThanOrEqual(coded.count, Vector.codedLimit)
            let read = Vector(baseSequence: 0, timestamp: nil, timeGap: nil, coded: coded).elements
            XCTAssertEqual(read.count, count)
            XCTAssertEqual(read, Array(elements.prefix(count)), "what fits is told truthfully")
            if count < elements.count, read.contains(true) { XCTAssertEqual(read.last, true, "a vector cut short ends on a packet that arrived") }
        }
    }

    func testTheHeaderWithAVectorMatchesTheWorkedExample() throws {
        var inbound = NanoInbound(first: 100)
        for number in UInt16(100)...103 { XCTAssertEqual(inbound.noteData(number, at: Int64(number) * 40), .new) }
        let ack = try XCTUnwrap(inbound.takeAck(at: 5000))
        XCTAssertEqual(ack.sequence, 103)
        XCTAssertEqual(ack.delayedTimeDifferences, [10, 10, 10], "40 microseconds apart, in units of four")
        XCTAssertNil(inbound.takeAck(at: 5000))
        for number in UInt16(106)...110 { XCTAssertEqual(inbound.noteData(number, at: 6000), .new) }
        XCTAssertNil(inbound.takeAck(at: 6000), "nothing above a gap is acknowledged plainly")
        XCTAssertEqual(inbound.missing, 2)
        let report = try XCTUnwrap(inbound.vector(at: 6000))
        let header = NanoRateHeader(logWindowSize: 13, ackOfAcks: 100, ackVector: report.vector).encoded()
        XCTAssertEqual([UInt8](header), [0x18, 0xD0, 0x64, 0x00, 0x68, 0x00, 0x81, 0xDC, 0x05, 0x00, 0x00, 0x7C])
        XCTAssertEqual(try NanoRateHeader(header).ackVector, report.vector)
        XCTAssertEqual(report.signature, .init(base: 0x1_0000 + 104, count: 7, arrived: 5))
        // A repeat changes nothing, so the next vector would be the same one.
        XCTAssertEqual(inbound.noteData(108, at: 6100), .repeated)
        XCTAssertEqual(inbound.vector(at: 6100)?.signature, report.signature)
    }

    func testTheSendersAckOfAcksEndsTheWaitForWhatItGaveUp() throws {
        var inbound = NanoInbound(first: 100)
        for number in [100, 101, 104, 105, 107] as [UInt16] { _ = inbound.noteData(number, at: 0) }
        _ = inbound.takeAck(at: 0)
        XCTAssertTrue(inbound.hasHole)
        // A stale value changes nothing.
        XCTAssertEqual(inbound.noteAckOfAcks(100), 0)
        XCTAssertEqual(inbound.noteAckOfAcks(104), 2, "102 and 103 will not come")
        XCTAssertEqual(inbound.missing, 1, "106 is still awaited")
        XCTAssertEqual(try XCTUnwrap(inbound.takeAck(at: 0)).sequence, 105)
        XCTAssertEqual(inbound.noteAckOfAcks(110), 3, "106, 108 and 109")
        XCTAssertFalse(inbound.hasHole)
        XCTAssertNil(inbound.takeAck(at: 0), "nothing arrived just below the new start")
        XCTAssertEqual(inbound.noteData(110, at: 0), .new)
        XCTAssertEqual(try XCTUnwrap(inbound.takeAck(at: 0)).sequence, 110)
        // One given up that arrives after all is acknowledged alone.
        XCTAssertEqual(inbound.noteData(103, at: 0), .late)
        let late = try XCTUnwrap(inbound.takeAck(at: 0))
        XCTAssertEqual(late.sequence, 103)
        XCTAssertEqual(late.delayedTimeDifferences, [])
    }

    func testNumbersCarryOnPastSixtyFiveThousand() throws {
        var inbound = NanoInbound(first: 65_530)
        for step in 0..<20 where step != 9 { XCTAssertEqual(inbound.noteData(UInt16(truncatingIfNeeded: 65_530 + step), at: 0), .new) }
        XCTAssertEqual(try XCTUnwrap(inbound.takeAck(at: 0)).sequence, 2, "65,530 to 65,535, then 0 to 2")
        let report = try XCTUnwrap(inbound.vector(at: 0))
        XCTAssertEqual(report.vector.baseSequence, 3)
        XCTAssertEqual(report.vector.elements, [false] + [Bool](repeating: true, count: 10))
        XCTAssertEqual(inbound.noteData(3, at: 0), .new)
        XCTAssertEqual(try XCTUnwrap(inbound.takeAck(at: 0)).sequence, 13)
    }
}
