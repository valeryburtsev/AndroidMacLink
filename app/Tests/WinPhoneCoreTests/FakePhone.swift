import Foundation
import SwiftProtobuf
@testable import WinPhoneCore

/// Plays the phone at the envelope level over a scripted socket: completes hub invocations,
/// acknowledges fragments, answers requests through `responder`, and can send its own requests.
final class FakePhone: @unchecked Sendable {
    static let id = "22222222-2222-4222-8222-222222222222"
    let socket = MockWebSocket()
    private let lock = NSLock()
    private var _received: [(PlatformEnvelope, RelayMessageType)] = []
    private var sequence = 1000
    /// Returns the response payload for a request the PC sent, or nil to stay silent.
    var responder: (@Sendable (PlatformEnvelope) -> Data?)?

    /// Everything the PC sent, requests and responses alike.
    var received: [PlatformEnvelope] { lock.lock(); defer { lock.unlock() }; return _received.map(\.0) }
    func received(route: String) -> [PlatformEnvelope] { received.filter { $0.route == route } }
    /// Responses the PC sent to a request with this ID.
    func responses(to requestId: String) -> [PlatformEnvelope] { received.filter { $0.originalRequestId == requestId } }

    init() {
        socket.onClientMessage = { [weak self] data, socket in
            if data == SignalR.handshakeRequest { socket.deliver(Data("{}".utf8) + [SignalR.recordSeparator]); return }
            for frame in (try? SignalR.splitFrames(data)) ?? [] {
                guard case .invocation(_, let id?, let target, let arguments)? = try? HubMessage(frame: frame) else { continue }
                socket.deliver(.completion(headers: .map([]), invocationId: id, resultKind: 3, value: .null))
                guard target == "SendMessageAsync", case .fragment(let fragment)? = try? DcgPacket(arguments[2]) else { continue }
                socket.deliver(RelayClientTests.inbound(from: FakePhone.id, .ack(.init(sessionId: fragment.sessionId, sequenceNumber: fragment.sequenceNumber))))
                guard let self, let envelope = try? PlatformEnvelope(decoding: fragment.raw) else { continue }
                self.lock.lock(); self._received.append((envelope, fragment.messageType)); let responder = self.responder; self.lock.unlock()
                if envelope.route != PeerMessenger.responseRoute, let id = envelope.requestId, let payload = responder?(envelope) {
                    self.deliver(PlatformEnvelope(headers: [("ms-content-type", "application/x-binary"), ("_route", "/internal/response"), ("_originalRequestId", id)],
                                                  payload: payload, convention: .android), type: fragment.messageType)
                }
            }
        }
    }

    /// Sends an envelope to the PC, framed the way the phone's client does.
    func deliver(_ envelope: PlatformEnvelope, type: RelayMessageType = .platform) {
        lock.lock(); sequence += 1; let n = sequence; lock.unlock()
        socket.deliver(RelayClientTests.inbound(from: FakePhone.id, .fragment(.init(
            sessionId: "phone-session", sequenceNumber: n, messageId: n, messageType: type, fragmentId: 1, fragmentCount: 1, raw: envelope.encoded()))))
    }

    /// Sends a PLATFORM request with the header order the phone uses. Returns its request ID.
    @discardableResult
    func request(route: String, payload: Data) -> String {
        let id = UUID().uuidString.lowercased()
        deliver(PlatformEnvelope(headers: [("ms-content-type", "application/x-binary"), ("_route", route), ("_rejectionVersion", "1"), ("_requestId", id)],
                                 payload: payload, convention: .android))
        return id
    }

    /// Builds the stack a session would: hub, relay, messenger, with inbound messages pumped.
    func connect(timeout: Duration = .seconds(5)) async throws -> (PeerMessenger, RelayClient) {
        let hub = HubConnection(socket: socket)
        try await hub.start(keepAlive: .seconds(3600))
        let relay = RelayClient(hub: hub)
        await relay.start()
        let messenger = PeerMessenger(relay: relay, peer: FakePhone.id, requestTimeout: timeout)
        Task {
            for await event in relay.events {
                if case .message(let message) = event { await messenger.receive(message) }
                if event == .closed { await messenger.connectionLost() }
            }
        }
        return (messenger, relay)
    }
}

/// An in-memory clipboard for tests.
actor TestClipboard: LocalClipboard {
    var content: ClipboardContent?
    var writes: [ClipboardContent] = []
    init(_ content: ClipboardContent? = nil) { self.content = content }
    func read() async -> ClipboardContent? { content }
    func write(_ content: ClipboardContent) async { self.content = content; writes.append(content) }
    func set(_ content: ClipboardContent?) { self.content = content }
}
