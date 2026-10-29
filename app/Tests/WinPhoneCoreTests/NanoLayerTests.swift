import XCTest
@testable import WinPhoneCore

/// The layers above the encryption. The byte layouts were read from a recording of a real
/// transfer; every value below is made up.
final class NanoLayerTests: XCTestCase {

    // MARK: Frames in order, with a moment's patience (2026-10-16)

    func piece(_ id: UInt32, key: Bool = false, of total: Int = 4, at offset: Int, _ length: Int = 2) -> NanoVideoPacket {
        .data(flags: key ? NanoVideoPacket.keyframeFlags : 4, frameId: id, timestamp: Int64(id) * 16_000, reserved: 0,
              totalSize: UInt32(total), packetCount: UInt32(total / 2), offset: UInt32(offset), metadata: Data(), data: Data(repeating: UInt8(id), count: length))
    }

    func testAFrameBehindAMissingPieceWaitsForItAndBothAreShownInOrder() {
        var assembler = NanoVideoAssembler()
        assembler.reorderWait = .milliseconds(60)
        let start = ContinuousClock.now
        XCTAssertEqual(assembler.take(piece(1, key: true, at: 0), at: start).map(\.id), [])
        XCTAssertEqual(assembler.take(piece(1, key: true, at: 2), at: start).map(\.id), [1])
        // Frame 2 lacks its second half; frame 3 arrives whole and waits.
        XCTAssertEqual(assembler.take(piece(2, at: 0), at: start).map(\.id), [])
        XCTAssertEqual(assembler.take(piece(3, at: 0), at: start).map(\.id), [])
        XCTAssertEqual(assembler.take(piece(3, at: 2), at: start + .milliseconds(5)).map(\.id), [], "held for frame 2")
        XCTAssertNotNil(assembler.releaseDeadline)
        // The piece sent again arrives: both go, in order.
        XCTAssertEqual(assembler.take(piece(2, at: 2), at: start + .milliseconds(20)).map(\.id), [2, 3])
        XCTAssertNil(assembler.releaseDeadline)
        XCTAssertEqual(assembler.take(piece(4, at: 0, 4), at: start + .milliseconds(30)).map(\.id), [4])
    }

    func testFramesHeldTooLongAreShownWithoutTheMissingOne() {
        var assembler = NanoVideoAssembler()
        assembler.reorderWait = .milliseconds(60)
        let start = ContinuousClock.now
        _ = assembler.take(piece(1, key: true, at: 0, 4), at: start)
        XCTAssertEqual(assembler.take(piece(3, at: 0, 4), at: start).map(\.id), [])
        XCTAssertEqual(assembler.release(at: start + assembler.reorderWait).map(\.id), [3], "frame 2 never came")
        // A late piece of the given-up frame is of no use any more.
        XCTAssertEqual(assembler.take(piece(2, at: 0, 4), at: start + .milliseconds(80)).map(\.id), [])
        // And a frame that arrives after the deadline lets the held ones go by itself.
        _ = assembler.take(piece(5, at: 0, 4), at: start + .milliseconds(90))
        XCTAssertEqual(assembler.take(piece(6, at: 0, 4), at: start + .milliseconds(200)).map(\.id), [5, 6], "both let go once the wait is over")
    }

    func testAWholePictureNeverWaitsAndEndsTheWait() {
        var assembler = NanoVideoAssembler()
        assembler.reorderWait = .milliseconds(60)
        let start = ContinuousClock.now
        _ = assembler.take(piece(1, key: true, at: 0, 4), at: start)
        XCTAssertEqual(assembler.take(piece(3, at: 0, 4), at: start).map(\.id), [])
        XCTAssertEqual(assembler.take(piece(5, key: true, at: 0, 4), at: start + .milliseconds(10)).map(\.id), [5])
        XCTAssertNil(assembler.releaseDeadline, "nothing before a whole picture is needed")
        XCTAssertEqual(assembler.take(piece(6, at: 0, 4), at: start + .milliseconds(20)).map(\.id), [6])
    }
    func testProbeAndItsReport() throws {
        XCTAssertEqual(try NanoProbe(Data(hex: "0100") + Data(count: 1200)), .probe(size: 1202))
        XCTAssertEqual(try NanoProbe(Data(hex: "0200" + "9e05")), .report(receivedSize: 1438))
        XCTAssertThrowsError(try NanoProbe(Data(hex: "0900")))
    }

    func testKeepAliveWithAndWithoutItsConfiguration() throws {
        let plain = try NanoKeepAlive(Data(hex: "28000000" + "12000000"))
        XCTAssertEqual(plain.reportedMTU, 40)
        XCTAssertTrue(plain.flags.contains(.handshakeAck))
        XCTAssertNil(plain.timing)
        // Handshake with the MTU block: interval, disconnect timeout, two frequencies, MTU timeout.
        let full = try NanoKeepAlive(Data(hex: "00000000" + "09000000" + "d007000000000000" + "983a000000000000" + "0a000000" + "64000000" + "40420f0000000000"))
        XCTAssertEqual(full.flags, [.handshake, .mtuConfiguration])
        XCTAssertEqual(full.timing?.interval, 2000)
        XCTAssertEqual(full.timing?.disconnectTimeout, 15000)
        XCTAssertEqual(full.timing?.mtuFrequency, 10)
        XCTAssertEqual(full.timing?.mtuProbeFrequency, 100)
        XCTAssertEqual(full.timing?.mtuTimeout, 1_000_000)
        XCTAssertEqual(full.length, 40)
        XCTAssertThrowsError(try NanoKeepAlive(Data(hex: "0000000009000000d007")), "says it carries a configuration but ends early")
    }

    func testRateControlHandshakeRoundTrips() throws {
        let syn = NanoRateHandshake.syn(version: 3, receiverLogSize: 14, initialSendSequence: 100, controllerType: 5, retry: 0)
        XCTAssertEqual(syn.encoded().hex, "0000" + "0300" + "0e" + "6400000000000000" + "0500" + "0000")
        XCTAssertEqual(try NanoRateHandshake(syn.encoded()), syn)
        let ack = NanoRateHandshake.synAck(timestamp: 0x1234, retry: 1)
        XCTAssertEqual(ack.encoded().hex, "0100" + "34120000" + "0100")
        XCTAssertEqual(try NanoRateHandshake(ack.encoded()), ack)
        XCTAssertEqual(try NanoRateHandshake(Data(hex: "0200")), .synAckOfAck)
        XCTAssertThrowsError(try NanoRateHandshake(Data(hex: "0000" + "0300")))
    }

    func testRateHeaderPartsComeInTheirFixedOrder() throws {
        // Ack with four time differences, then the ack of acks: 15 bytes, no data.
        let acks = try NanoRateHeader(Data(hex: "11d0" + "7c00" + "182800" + "00" + "04" + "0a0b0c0d" + "6400"))
        XCTAssertEqual(acks.logWindowSize, 13)
        XCTAssertEqual(acks.ack?.sequence, 124)
        XCTAssertEqual(acks.ack?.timestamp, 0x2818)
        XCTAssertEqual(acks.ack?.delayedTimeDifferences, [10, 11, 12, 13])
        XCTAssertEqual(acks.ackOfAcks, 100)
        XCTAssertNil(acks.dataSequence)
        XCTAssertEqual(acks.length, 15)
        // Ack, overhead byte, delayed-ack parameters, ack of acks, data: the data follows.
        let bytes = Data(hex: "55d1" + "d800" + "412c00" + "00" + "02" + "1c0d" + "27" + "011400" + "6400" + "df00") + Data("payload".utf8)
        let data = try NanoRateHeader(bytes)
        XCTAssertEqual(data.overheadSize, 0x27)
        XCTAssertEqual(data.delayedAck?.maxDelayedAcks, 1)
        XCTAssertEqual(data.delayedAck?.timeout, 20)
        XCTAssertEqual(data.dataSequence, 0xdf)
        XCTAssertEqual(String(decoding: bytes.dropFirst(data.length), as: UTF8.self), "payload")
        // Data alone, as a sender with nothing to acknowledge writes it.
        let alone = NanoRateHeader(logWindowSize: 12, dataSequence: 0x00e9)
        XCTAssertEqual(alone.encoded().hex, "04c0" + "e900")
        XCTAssertEqual(alone.length, 4)
        // An ack vector with a time stamp and two coded bytes.
        let vector = NanoRateHeader(logWindowSize: 13, ackVector: .init(baseSequence: 7, timestamp: 0x010203, timeGap: 4, coded: [0x85, 0x3f]))
        XCTAssertEqual(vector.encoded().hex, "08d0" + "0700" + "82" + "030201" + "04" + "853f")
        for header in [acks, data, alone, vector] { XCTAssertEqual(try NanoRateHeader(header.encoded()), header) }
        XCTAssertThrowsError(try NanoRateHeader(Data(hex: "11d07c00")))
    }

    func testChannelControlPackets() throws {
        let description = NanoChannelDescription(text: "Microsoft::Basix::Dct::Channel::Class::Blob,2,5,ConsumerId=abc&ScenarioId=fileShare_XYZ")
        XCTAssertEqual(description.channelClass, "Blob")
        XCTAssertEqual(description.properties, ["ConsumerId": "abc", "ScenarioId": "fileShare_XYZ"])
        let create = NanoMuxControl.create(description, fec: 0, initialization: description.text, weight: 1)
        let bytes = create.encoded()
        XCTAssertEqual(bytes.prefix(6).hex, "02000000" + "5700", "a 16-bit length before the description, unlike every other string")
        XCTAssertEqual(bytes.suffix(8).hex, "000000000000f03f", "the weight is a double")
        XCTAssertEqual(try NanoMuxControl(bytes), create)
        let accept = NanoMuxControl.open(initialization: "", weight: 1)
        XCTAssertEqual(accept.encoded().hex, "03000000" + "00000000" + "000000000000f03f")
        XCTAssertEqual(try NanoMuxControl(accept.encoded()), accept)
        XCTAssertEqual(try NanoMuxControl(Data(hex: "0400000000000000")), .close(reason: 0))
        XCTAssertThrowsError(try NanoMuxControl(Data(hex: "02000000ffff41")), "a length beyond the packet")
        XCTAssertThrowsError(try NanoMuxControl(Data(hex: "0900000000000000")))
    }

    func testSequencerHeaderNamesThePacketBefore() throws {
        XCTAssertEqual(NanoSequencerHeader(forPacket: 0).encoded().hex, "0200000000000000")
        XCTAssertEqual(NanoSequencerHeader(forPacket: 1).encoded().hex, "0300000000000000")
        XCTAssertEqual(NanoSequencerHeader(forPacket: 50).encoded().hex, "0300310000000000")
        XCTAssertEqual(try NanoSequencerHeader(Data(hex: "0300310000000000")), NanoSequencerHeader(mode: 3, dependsOn: 49))
        XCTAssertThrowsError(try NanoSequencerHeader(Data(hex: "0300")))
    }

    func testMessagePacketsAndReassembly() throws {
        XCTAssertEqual(NanoMessagePacket.handshake(version: 1).encoded().hex, "01000000" + "04000000" + "01000000")
        let whole = NanoMessagePacket.message(id: 7, path: "/a/b", body: Data([1, 2, 3]))
        XCTAssertEqual(whole.encoded().hex, "02000000" + "23000000" + "00000000" + "07000000" + "01000000" + "04000000" + "03000000" + "00000000" + "07000000" + "2f612f62" + "010203")
        XCTAssertEqual(try NanoMessagePacket(whole.encoded()), whole)
        var assembler = NanoMessageAssembler()
        XCTAssertEqual(assembler.add(whole), .init(id: 7, path: "/a/b", body: Data([1, 2, 3])))
        // The same message in two pieces, the second first.
        let first = NanoMessagePacket.data(flags: 0, id: 8, count: 2, pathLength: 4, bodyLength: 3, offset: 0, data: Data("/a/b".utf8) + Data([1]))
        let second = NanoMessagePacket.data(flags: 0, id: 8, count: 2, pathLength: 4, bodyLength: 3, offset: 5, data: Data([2, 3]))
        XCTAssertNil(assembler.add(second))
        XCTAssertEqual(assembler.add(first), .init(id: 8, path: "/a/b", body: Data([1, 2, 3])))
        // Pieces that claim more than they may, or lie about their place, are dropped.
        XCTAssertNil(assembler.add(.data(flags: 0, id: 9, count: 1, pathLength: 4, bodyLength: UInt32.max, offset: 0, data: Data([1]))))
        XCTAssertNil(assembler.add(.data(flags: 0, id: 9, count: 1, pathLength: 1, bodyLength: 1, offset: 5, data: Data([1, 2]))))
        XCTAssertThrowsError(try NanoMessagePacket(Data(hex: "02000000" + "ff000000" + "00")), "a length beyond the packet")
        XCTAssertEqual(try NanoMessagePacket(NanoMessagePacket.cancel(id: 3).encoded()), .cancel(id: 3))
    }

    func testBlobPacketsAndReassembly() throws {
        XCTAssertEqual(NanoBlobPacket.handshake(minVersion: 2, maxVersion: 3).encoded().hex, "01000000" + "08000000" + "02000000" + "03000000")
        let start = NanoBlobPacket.start(totalSize: 5, name: "n")
        XCTAssertEqual(start.encoded().hex, "04000000" + "0d000000" + "0500000000000000" + "01000000" + "6e")
        let piece = NanoBlobPacket.data(flags: 0, pieces: 2, segment: 0, totalSize: 5, name: "n", size: 5, offset: 3, data: Data([4, 5]))
        XCTAssertEqual(piece.encoded().hex, "02000000" + "2b000000" + "00000000" + "02000000" + "0000000000000000" + "0500000000000000" + "01000000" + "6e"
                       + "05000000" + "03000000" + "02000000" + "0405")
        for packet in [start, piece, .completion(kind: 1, name: "n"), .written(queued: 0, name: "n")] { XCTAssertEqual(try NanoBlobPacket(packet.encoded()), packet) }

        var assembler = NanoBlobAssembler()
        XCTAssertNil(assembler.add(start))
        XCTAssertNil(assembler.add(piece))
        XCTAssertNil(assembler.add(piece), "a piece sent twice counts once")
        XCTAssertEqual(assembler.progress["n"]?.received, 2)
        let done = assembler.add(.data(flags: 0, pieces: 2, segment: 0, totalSize: 5, name: "n", size: 5, offset: 0, data: Data([1, 2, 3])))
        XCTAssertEqual(done?.data, Data([1, 2, 3, 4, 5]))
        // A blob larger than allowed is refused before any memory is set aside.
        var small = NanoBlobAssembler(sizeLimit: 4)
        XCTAssertNil(small.add(start))
        XCTAssertNil(small.add(piece))
        XCTAssertTrue(small.progress.isEmpty)
        // A blob in three segments of four bytes, the last one short: a piece belongs at its
        // segment's number times the full segment length, plus its place inside the segment.
        var segmented = NanoBlobAssembler()
        XCTAssertNil(segmented.add(.data(flags: 0, pieces: 1, segment: 0, totalSize: 10, name: "s", size: 4, offset: 0, data: Data([1, 2, 3, 4]))))
        XCTAssertNil(segmented.add(.data(flags: 0, pieces: 2, segment: 2, totalSize: 10, name: "s", size: 2, offset: 1, data: Data([10]))))
        XCTAssertNil(segmented.add(.data(flags: 0, pieces: 2, segment: 1, totalSize: 10, name: "s", size: 4, offset: 2, data: Data([7, 8]))))
        XCTAssertNil(segmented.add(.data(flags: 0, pieces: 2, segment: 1, totalSize: 10, name: "s", size: 4, offset: 0, data: Data([5, 6]))))
        XCTAssertEqual(segmented.add(.data(flags: 0, pieces: 2, segment: 2, totalSize: 10, name: "s", size: 2, offset: 0, data: Data([9])))?.data, Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
        XCTAssertNil(segmented.add(.data(flags: 0, pieces: 1, segment: 99, totalSize: 6, name: "t", size: 1, offset: 0, data: Data([1]))), "a segment beyond the blob")
        // A piece that would land beyond the announced size is dropped.
        var strict = NanoBlobAssembler()
        _ = strict.add(start)
        XCTAssertNil(strict.add(.data(flags: 0, pieces: 1, segment: 0, totalSize: 5, name: "n", size: 5, offset: 4, data: Data([1, 2, 3]))))
        XCTAssertEqual(strict.progress["n"]?.received, 0)
    }

    /// A large file must cost time in proportion to its size: the buffer is written in place,
    /// not copied for each of its thousands of pieces.
    func testABlobIsWrittenToDiskAsItArrivesWhenThereIsAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winphone-blob-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func parts() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] }
        let bytes = Data((0..<250_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var pieces: [NanoBlobPacket] = []
        for start in stride(from: 0, to: bytes.count, by: 1000) {
            pieces.append(.data(flags: 0, pieces: 100, segment: UInt64(start / 100_000), totalSize: UInt64(bytes.count), name: "sendersname",
                                size: UInt32(min(100_000, bytes.count - start / 100_000 * 100_000)), offset: UInt32(start % 100_000), data: bytes[start..<(start + 1000)]))
        }
        var assembler = NanoBlobAssembler(directory: folder)
        var finished: NanoBlobAssembler.Finished?
        // Backwards, and one piece twice: the order does not matter on disk either.
        for piece in pieces.reversed() + [pieces[7]] { if let done = assembler.add(piece) { finished = done } }
        guard case .file(let url, let size)? = finished?.content else { return XCTFail("the blob came out in memory") }
        XCTAssertEqual(size, bytes.count)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(parts().count, 1)
        XCTAssertFalse(url.lastPathComponent.contains("sendersname"), "the file on disk is not named by the sender")
        // A blob that never completes leaves nothing behind once its assembler is gone.
        var abandoned: NanoBlobAssembler? = NanoBlobAssembler(directory: folder)
        XCTAssertNil(abandoned?.add(pieces[0]))
        XCTAssertEqual(parts().count, 2)
        XCTAssertEqual(abandoned?.progress(of: "sendersname")?.received, 1000)
        abandoned = nil
        XCTAssertEqual(parts().count, 1, "the unfinished file was removed")
        // One that the disk cannot hold is turned away, and said to be.
        var huge = NanoBlobAssembler(sizeLimit: .max, directory: folder)
        XCTAssertNil(huge.add(.start(totalSize: 1 << 60, name: "h")))
        XCTAssertEqual(huge.refused, ["h"])
        XCTAssertNil(huge.add(.data(flags: 0, pieces: 1, segment: 0, totalSize: 1 << 60, name: "h", size: 4, offset: 0, data: Data([1, 2, 3, 4]))))
        XCTAssertEqual(parts().count, 1)
        XCTAssertFalse(NanoBlobAssembler.hasRoom(for: 1 << 60, in: folder))
        XCTAssertTrue(NanoBlobAssembler.hasRoom(for: 1000, in: folder))
    }

    func testALargeBlobIsAssembledInLinearTime() throws {
        let total = 40 * 1024 * 1024, pieceSize = 1268
        let piece = Data(repeating: 0xAB, count: pieceSize)
        var assemblers: [UInt16: NanoBlobAssembler] = [:]
        let start = ContinuousClock.now
        var finished: Data?
        var offset = 0
        while offset < total {
            let length = min(pieceSize, total - offset)
            // Through a table, as the connection holds it.
            var assembler = assemblers.removeValue(forKey: 1026) ?? NanoBlobAssembler()
            let segment = offset / 100_000
            let packet = NanoBlobPacket.data(flags: 0, pieces: 0, segment: UInt64(segment), totalSize: UInt64(total), name: "big", size: 100_000, offset: UInt32(offset - segment * 100_000),
                                             data: length == pieceSize ? piece : piece.prefix(length))
            if let done = assembler.add(packet) { finished = done.data }
            _ = assembler.progress(of: "big")
            assemblers[1026] = assembler
            offset += length
        }
        XCTAssertEqual(finished?.count, total)
        XCTAssertEqual(finished?.last, 0xAB)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3), "40 MB in 33,000 pieces")
    }

    /// A whole small session, built packet by packet and sealed, then followed by the decoder.
    func testAConnectionIsFollowedFromChannelSetupToTheFinishedBlob() throws {
        let keys = try NanoSessionKeys(keyHex: "000102030405060708090a0b0c0d0e0f", saltHex: "101112131415161718191a1b1c1d")
        var outer: [String: UInt16] = [:], dataSequence: [String: UInt16] = [:], inner: [String: UInt64] = [:]
        func packet(_ direction: String, type: UInt8, channel: UInt16, _ content: Data, reliable: Bool = true) throws -> NanoDatagram {
            outer[direction, default: 0] += 1
            dataSequence[direction, default: 100] += 1
            var payload = NanoRateHeader(logWindowSize: 12, dataSequence: dataSequence[direction]).encoded()
            var number: UInt64 = 0
            if type == 35, reliable {
                number = inner["\(direction)\(channel)", default: 0]
                inner["\(direction)\(channel)"] = number + 1
                payload += NanoSequencerHeader(forPacket: number).encoded()
            }
            payload += content
            let sealed = try NanoDatagram(header: NanoHeader(payloadType: type, sequence: outer[direction]!, ssrc: UInt32(channel)), payload: payload,
                                          innerSequence: UInt16(truncatingIfNeeded: number)).sealed(with: keys)
            return try NanoDatagram(opening: sealed, keys: keys)
        }
        let messaging = NanoChannelDescription(text: NanoChannelDescription.classPrefix + "Messaging,1,4,ScenarioId=test")
        let blob = NanoChannelDescription(text: NanoChannelDescription.classPrefix + "Blob,2,5,ScenarioId=test")
        let file = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0) })
        var script: [(String, NanoDatagram)] = [
            ("phone", try packet("phone", type: 97, channel: 1025, NanoMuxControl.create(messaging, fec: 0, initialization: messaging.text, weight: 1).encoded())),
            ("phone", try packet("phone", type: 97, channel: 1025, NanoMuxControl.open(initialization: messaging.text, weight: 1).encoded())),
            ("pc", try packet("pc", type: 97, channel: 1025, NanoMuxControl.open(initialization: "", weight: 1).encoded())),
            ("phone", try packet("phone", type: 97, channel: 1026, NanoMuxControl.create(blob, fec: 0, initialization: blob.text, weight: 1).encoded())),
            ("phone", try packet("phone", type: 35, channel: 1025, NanoMessagePacket.handshake(version: 1).encoded())),
            ("phone", try packet("phone", type: 35, channel: 1025, NanoMessagePacket.message(id: 1, path: "/test/offer", body: Data([9, 9])).encoded())),
            ("phone", try packet("phone", type: 35, channel: 1026, NanoBlobPacket.handshake(minVersion: 2, maxVersion: 3).encoded())),
            ("phone", try packet("phone", type: 35, channel: 1026, NanoBlobPacket.start(totalSize: 3000, name: "f").encoded())),
        ]
        for offset in stride(from: 0, to: 3000, by: 1200) {
            let piece = NanoBlobPacket.data(flags: 0, pieces: 3, segment: 0, totalSize: 3000, name: "f", size: 3000, offset: UInt32(offset), data: file[offset..<min(offset + 1200, 3000)])
            script.append(("phone", try packet("phone", type: 35, channel: 1026, piece.encoded())))
        }
        // The second piece is sent again, as after a lost acknowledgement.
        script.insert(script[9], at: 10)
        script.append(("phone", try packet("phone", type: 35, channel: 1026, NanoBlobPacket.completion(kind: 1, name: "f").encoded())))
        script.append(("pc", try packet("pc", type: 97, channel: 1026, NanoMuxControl.close(reason: 0).encoded())))
        // A pure acknowledgement on channel 0 says nothing.
        let ackOnly = try NanoDatagram(opening: try NanoDatagram(header: NanoHeader(payloadType: 35, sequence: 900, ssrc: 0),
                                                                 payload: NanoRateHeader(logWindowSize: 13, ackOfAcks: 100).encoded(), innerSequence: 0).sealed(with: keys), keys: keys)
        script.append(("pc", ackOnly))

        var decoder = NanoTraceDecoder()
        var events: [NanoTraceDecoder.Event] = []
        for (direction, datagram) in script { events += decoder.decode(datagram, direction: direction) }
        XCTAssertEqual(events, [
            .channelCreated(channel: 1025, messaging), .channelOpened(channel: 1025), .channelOpened(channel: 1025),
            .channelCreated(channel: 1026, blob),
            .messageHandshake(channel: 1025, version: 1),
            .message(channel: 1025, .init(id: 1, path: "/test/offer", body: Data([9, 9]))),
            .blobHandshake(channel: 1026, minVersion: 2, maxVersion: 3),
            .blobStarted(channel: 1026, name: "f", size: 3000),
            .blobReceived(channel: 1026, name: "f", data: file),
            .blobCompletion(channel: 1026, kind: 1, name: "f"),
            .channelClosed(channel: 1026),
        ])
        XCTAssertEqual(decoder.knownChannels[1026]?.channelClass, "Blob")
        // Data on a channel nobody created is reported, not guessed at.
        let stray = try packet("phone", type: 35, channel: 2000, Data([1, 2, 3, 4, 5, 6, 7, 8]))
        guard case .undecoded? = decoder.decode(stray, direction: "phone").first else { return XCTFail("expected a report") }
    }

    /// The recording of 2026-10-09, when it is on this machine: every packet must decode and
    /// the transferred file must come out whole. Skipped elsewhere; nothing of it is asserted
    /// here beyond counts.
    func testTheRecordedTransferDecodesEndToEnd() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let recording = FileManager.default.contents(atPath: root.appendingPathComponent("captures/nano-udp-2.pcap").path),
              let relay = FileManager.default.contents(atPath: root.appendingPathComponent("captures/vm-raw-2026-10-09/flows.jsonl").path) else {
            throw XCTSkip("no local recording")
        }
        let keySets = NanoRecording.keySets(inRelayCapture: String(decoding: relay, as: UTF8.self))
        let opened = NanoRecording.open(try PacketCapture.udpDatagrams(in: recording), keySets: keySets)
        XCTAssertGreaterThan(opened.count, 400)
        var decoders: [String: NanoTraceDecoder] = [:]
        var announced: [UInt64] = [], received: [Int] = [], undecoded = 0, messages = 0
        for packet in opened {
            for event in decoders[packet.connection, default: NanoTraceDecoder()].decode(packet.datagram, direction: packet.flow) {
                switch event {
                case .blobStarted(_, _, let size): announced.append(size)
                case .blobReceived(_, _, let data): received.append(data.count)
                case .message: messages += 1
                case .undecoded: undecoded += 1
                default: break
                }
            }
        }
        XCTAssertEqual(undecoded, 0)
        XCTAssertEqual(announced.count, 1)
        XCTAssertEqual(received.map(UInt64.init), announced, "the file came out at its announced size")
        XCTAssertGreaterThanOrEqual(messages, 6)
    }
}
