import XCTest
@testable import WinPhoneCore

final class RelayWireTests: XCTestCase {
    func testLengthPrefixAndFrameSplitting() throws {
        XCTAssertEqual(SignalR.lengthPrefix(2), Data([2]))
        XCTAssertEqual(SignalR.lengthPrefix(300), Data([0xAC, 0x02]))
        let big = Data(repeating: 9, count: 70_000)
        let message = SignalR.frame(Data([0x91, 0x06])) + SignalR.frame(big)
        XCTAssertEqual(try SignalR.splitFrames(message), [Data([0x91, 0x06]), big])
        XCTAssertThrowsError(try SignalR.splitFrames(message.dropLast()))
        XCTAssertThrowsError(try SignalR.splitFrames(Data([0x80])))
        XCTAssertThrowsError(try SignalR.splitFrames(Data([0x80, 0x80, 0x80, 0x80, 0x80, 0x01])))
    }

    func testHandshake() throws {
        XCTAssertEqual(String(data: SignalR.handshakeRequest.dropLast(), encoding: .utf8), #"{"protocol":"messagepack","version":1}"#)
        let coalesced = Data("{}".utf8) + [0x1E] + HubMessage.ping.framed
        let (handshake, rest) = try SignalR.splitHandshake(coalesced)
        XCTAssertNoThrow(try SignalR.checkHandshakeResponse(handshake))
        XCTAssertEqual(try SignalR.splitFrames(rest).map { try HubMessage(frame: $0) }, [.ping])
        XCTAssertThrowsError(try SignalR.checkHandshakeResponse(Data(#"{"error":"Requested protocol 'x' is not available."}"#.utf8)))
        XCTAssertThrowsError(try SignalR.splitHandshake(Data("{}".utf8)))
    }

    func testPingAndCompletionBytesMatchTheWire() throws {
        XCTAssertEqual(HubMessage.ping.encoded.encoded().hex, "9106")
        // Completion seen from Azure SignalR for invocation "1": [3, {}, "1", 3, nil]
        let completion = try HubMessage(frame: Data(hex: "950380a13103c0"))
        XCTAssertEqual(completion, .completion(headers: .map([]), invocationId: "1", resultKind: 3, value: .null))
        XCTAssertEqual(completion.encoded.encoded().hex, "950380a13103c0")
    }

    /// Every real hub frame decodes to a typed message and re-encodes to the same bytes.
    func testRealHubMessagesRoundTripExactly() throws {
        var targets: [String: Int] = [:]
        for frame in try Fixtures.relayFrames() {
            let message = try HubMessage(frame: frame.bytes)
            XCTAssertEqual(message.encoded.encoded(), frame.bytes)
            if case .other = message { XCTFail("unrecognised hub message") }
            if case .invocation(_, _, let target, _) = message { targets[target, default: 0] += 1 }
        }
        for expected in ["SendMessageAsync", "OnReceiveMessage", "SendConnectedAsync", "OnConnected", "OnPartnerConnected"] {
            XCTAssertNotNil(targets[expected], "fixture lacks \(expected)")
        }
    }

    /// Packets built by Phone Link must be reproduced exactly by our encoder: same key order, same
    /// numeric types. Packets from the phone only need to decode.
    func testRealPacketsDecodeAndWindowsPacketsReEncodeExactly() throws {
        var fromPC = 0, fromPhone = 0, fragments = 0, acks = 0
        for frame in try Fixtures.relayFrames() {
            guard case .invocation(_, _, let target, let arguments) = try HubMessage(frame: frame.bytes),
                  target == "SendMessageAsync" || target == "OnReceiveMessage" else { continue }
            let packetValue = try XCTUnwrap(arguments.last)
            let packet = try DcgPacket(packetValue)
            switch packet {
            case .fragment(let f):
                fragments += 1
                XCTAssertGreaterThan(f.fragmentCount, 0)
                XCTAssertEqual(f.sessionId.count, 36)
            case .ack(let a):
                acks += 1
                XCTAssertTrue(a.success)
            }
            if frame.fromClient {
                fromPC += 1
                XCTAssertEqual(packet.encoded, packetValue, "our \(target) packet differs from Phone Link's")
                // Outbound argument order: trace, target id, packet.
                XCTAssertEqual(arguments.count, 3)
                let trace = try XCTUnwrap(TraceContext(arguments[0]))
                XCTAssertEqual(trace.encoded, arguments[0])
                XCTAssertEqual(trace.traceId.count, 32)
                XCTAssertEqual(arguments[1].stringValue?.count, 36)
            } else {
                fromPhone += 1
                // Inbound argument order: source id, trace, packet.
                XCTAssertEqual(arguments.count, 3)
                XCTAssertEqual(arguments[0].stringValue?.count, 36)
                XCTAssertNotNil(TraceContext(arguments[1]))
            }
        }
        XCTAssertGreaterThan(fromPC, 20)
        XCTAssertGreaterThan(fromPhone, 20)
        XCTAssertGreaterThan(fragments, 20)
        XCTAssertGreaterThan(acks, 20)
    }

    /// Fragment payloads are PLATFORM envelopes. PC ones use the Windows header-length convention
    /// and phone ones the Android convention; both re-encode to the same bytes.
    func testRealEnvelopesRoundTripWithTheRightConvention() throws {
        var routes: Set<String> = []
        var count = 0, withContentType = 0
        for frame in try Fixtures.relayFrames() {
            guard case .invocation(_, _, _, let arguments) = try HubMessage(frame: frame.bytes),
                  let last = arguments.last, case .fragment(let fragment)? = try? DcgPacket(last),
                  fragment.fragmentCount == 1 else { continue }
            let envelope = try PlatformEnvelope(decoding: fragment.raw)
            XCTAssertEqual(envelope.encoded(), fragment.raw)
            XCTAssertEqual(envelope.convention, frame.fromClient ? .windows : .android)
            // Not every message declares a content type; nine in this capture do not.
            if envelope[PlatformEnvelope.Header.contentType] != nil { withContentType += 1 }
            routes.insert(try XCTUnwrap(envelope.route).replacingOccurrences(of: #"/[0-9a-f-]{36}$"#, with: "/<id>", options: .regularExpression))
            count += 1
        }
        XCTAssertGreaterThan(count, 40)
        XCTAssertGreaterThan(withContentType, 30)
        XCTAssertTrue(routes.isSuperset(of: ["/DeviceResourceManager", "/internal/response"]), "\(routes)")
    }

    func testEnvelopeRejectsMalformedInput() throws {
        let envelope = PlatformEnvelope(headers: [("_route", "/SessionValidation"), ("_requestId", "abc")], payload: Data([1, 2, 3]))
        let bytes = envelope.encoded()
        XCTAssertEqual(try PlatformEnvelope(decoding: bytes), envelope)
        XCTAssertThrowsError(try PlatformEnvelope(decoding: bytes.dropLast()))
        XCTAssertThrowsError(try PlatformEnvelope(decoding: bytes + [0]))
        XCTAssertThrowsError(try PlatformEnvelope(decoding: Data([2]) + bytes.dropFirst()))
        var badLength = bytes
        badLength[1] = badLength[1] &+ 1
        XCTAssertThrowsError(try PlatformEnvelope(decoding: badLength))
        var android = envelope
        android.convention = .android
        XCTAssertEqual(try PlatformEnvelope(decoding: android.encoded()).convention, .android)
        XCTAssertNotEqual(android.encoded(), bytes)
    }
}
