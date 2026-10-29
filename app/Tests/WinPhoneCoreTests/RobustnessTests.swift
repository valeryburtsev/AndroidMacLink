import XCTest
@testable import WinPhoneCore

/// Regression tests for the robustness audit of 2026-10-09: inputs from the service or the
/// phone must fail cleanly, never crash or hang the client.
final class RobustnessTests: XCTestCase {
    let peer = "22222222-2222-4222-8222-222222222222"

    func testCertificateWithGarbledTimeDoesNotCrash() throws {
        let certificate = try DeviceCertificate.generate(commonName: "x")
        var der = certificate.der
        // Overwrite the content of the second UTCTime (notAfter) with non-digits.
        var seen = 0
        var index = der.startIndex
        while index < der.endIndex - 14 {
            if der[index] == 0x17, der[index + 1] == 13 {
                seen += 1
                if seen == 2 {
                    for offset in 2..<15 { der[index + offset] = UInt8(ascii: "Z") }
                    break
                }
            }
            index += 1
        }
        XCTAssertEqual(seen, 2)
        let info = try DeviceCertificate.inspect(der: der)
        XCTAssertEqual(info.commonName, "x")
        XCTAssertNil(info.notAfter)
        // An empty time is handled too.
        XCTAssertNil(DeviceCertificate.parseTime(DER.Node(tag: 0x17, content: Data(), raw: Data([0x17, 0]))))
    }

    func testAbandonedPartialMessagesAreBounded() async throws {
        var configuration = RelayClient.Configuration()
        configuration.maxAssemblies = 2
        let tests = RelayClientTests()
        let (relay, socket) = try await tests.makeRelay(configuration: configuration)
        func first(message: Int, seq: Int) -> HubMessage {
            RelayClientTests.inbound(from: peer, .fragment(.init(sessionId: "s", sequenceNumber: seq, messageId: message, messageType: .app,
                                                                 fragmentId: 1, fragmentCount: 2, raw: Data([1]))))
        }
        socket.deliver(first(message: 1, seq: 1), first(message: 2, seq: 2), first(message: 3, seq: 3))
        let done = await waitUntil { tests.sentPackets(socket).count == 3 }
        XCTAssertTrue(done)
        let acks = tests.sentPackets(socket).compactMap { packet -> DcgPacket.Ack? in
            if case .ack(let a) = packet { return a }
            return nil
        }.sorted { $0.sequenceNumber < $1.sequenceNumber }
        XCTAssertEqual(acks.map(\.success), [true, true, false], "the third partial message is refused")
        await relay.close()
    }

    func testStaleAcknowledgementFromAnotherSessionIsIgnored() async throws {
        var configuration = RelayClient.Configuration()
        configuration.ackTimeout = .milliseconds(150)
        configuration.retries = 0
        let tests = RelayClientTests()
        let (relay, socket) = try await tests.makeRelay(autoAck: false, configuration: configuration)
        let peer = self.peer
        // An ack with the right sequence number but a session we never used.
        socket.onClientMessage = { data, socket in
            for frame in (try? SignalR.splitFrames(data)) ?? [] {
                guard case .invocation(_, let id?, let target, _)? = try? HubMessage(frame: frame) else { continue }
                socket.deliver(.completion(headers: .map([]), invocationId: id, resultKind: 3, value: .null))
                if target == "SendMessageAsync" {
                    socket.deliver(RelayClientTests.inbound(from: peer, .ack(.init(sessionId: "someone-elses-session", sequenceNumber: 1))))
                }
            }
        }
        do {
            try await relay.send(Data([1]), type: .platform, to: peer)
            XCTFail("the stale acknowledgement must not satisfy the send")
        } catch RelayClient.RelayError.acknowledgementTimeout {}
        await relay.close()
    }

    func testSilentHubIsClosedAfterTheServerTimeout() async throws {
        let socket = MockWebSocket.autoCompleting()
        let hub = HubConnection(socket: socket)
        try await hub.start(keepAlive: .milliseconds(30), serverTimeout: .milliseconds(120))
        var ended = false
        for await _ in hub.events {}
        ended = true
        XCTAssertTrue(ended)
        let closed = await hub.isClosed
        XCTAssertTrue(closed)
        do {
            try await hub.invoke("SendConnectedAsync", arguments: [])
            XCTFail("expected closed")
        } catch HubConnection.HubError.closed(let reason) {
            XCTAssertEqual(reason, "server timeout")
        }
    }

    func testPingsKeepASilentHubAliveOnlyWhenItAnswers() async throws {
        let socket = MockWebSocket.autoCompleting()
        let original = socket.onClientMessage
        socket.onClientMessage = { data, socket in
            original?(data, socket)
            // The hub answers every client ping with its own ping.
            if data == HubMessage.ping.framed { socket.deliver(.ping) }
        }
        let hub = HubConnection(socket: socket)
        try await hub.start(keepAlive: .milliseconds(30), serverTimeout: .milliseconds(120))
        try await Task.sleep(for: .milliseconds(300))
        let closed = await hub.isClosed
        XCTAssertFalse(closed, "a hub that keeps pinging stays open")
        await hub.close()
    }
}

final class GzipTests: XCTestCase {
    /// A gzip stream made by the system's own gzip, for "hello hello hello hello".
    static let sample = Data(base64Encoded: "H4sIACfsyGoAA8tIzcnJV8hAJwHjUT2NFwAAAA==")!

    func testDecompressesAGzipStream() throws {
        let text = String(decoding: try XCTUnwrap(Gzip.decompress(Self.sample)), as: UTF8.self)
        XCTAssertEqual(text, "hello hello hello hello")
        XCTAssertTrue(Gzip.isGzip(Self.sample))
    }

    func testRefusesBrokenAndOversizedInput() {
        XCTAssertNil(Gzip.decompress(Data([1, 2, 3])))
        XCTAssertNil(Gzip.decompress(Self.sample.prefix(20)), "a truncated stream")
        XCTAssertNil(Gzip.decompress(Self.sample, maxOutput: 5), "more output than allowed")
        var corrupt = Self.sample
        corrupt[12] ^= 0xFF
        // A damaged body either fails or yields something else; it must not crash.
        _ = Gzip.decompress(corrupt)
    }

    func testACompressedPushIsUnpackedBeforeItIsHandled() async throws {
        let phone = FakePhone()
        let (messenger, relay) = try await phone.connect()
        let sync = NotificationSync(messenger: messenger, displayName: "Mac", installationId: "I")
        await sync.start()
        // A notification push, gzipped, with the header that says so.
        let json = #"{"key":"k","packageName":"p","postTime":1}"#
        let values = ValueSet(["contentType": .string("notifications"), "notificationKeys": .stringArray(["k"]), "operations": .int32Array([1]),
                               "notifications": .stringArray([json])])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(values.serialized())
        input.fileHandleForWriting.closeFile()
        let compressed = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertTrue(Gzip.isGzip(compressed))

        let id = UUID().uuidString.lowercased()
        phone.deliver(PlatformEnvelope(headers: [("_requestId", id), ("_route", "/legacy/phonecontent"), ("_isGzippedCompressed", "true")],
                                       payload: compressed, convention: .android), type: .app)
        let answered = await waitUntil { !phone.responses(to: id).isEmpty }
        XCTAssertTrue(answered)
        XCTAssertEqual((try? ValueSet(serialized: phone.responses(to: id)[0].payload))?.int("result"), 0)
        let stored = await sync.notifications
        XCTAssertEqual(stored.map(\.key), ["k"])
        await relay.close()
    }
}

final class DiagnosticsTests: XCTestCase {
    func testTheLogFileStartsOverAtItsSizeLimitKeepingOneOlderCopy() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winphone-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.log")
        let log = Diagnostics()
        log.sizeLimit = 2000
        log.writeToFile(url)
        for index in 0..<60 { log.log("test", "line \(index) " + String(repeating: "x", count: 40)) }
        let current = try Data(contentsOf: url).count, older = try Data(contentsOf: url.appendingPathExtension("1")).count
        XCTAssertLessThan(current, 2100)
        XCTAssertGreaterThan(older, 1900)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2, "one current file and one older copy, never more")
    }
}
