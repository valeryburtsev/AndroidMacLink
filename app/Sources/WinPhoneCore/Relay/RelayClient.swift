import Foundation

/// Reliable message exchange with paired devices over the hub relay.
///
/// Each outbound message is split into fragments. Every fragment is a `SendMessageAsync`
/// invocation and must be answered twice: by the hub (a Completion, meaning the relay accepted
/// it) and by the peer (a DCG acknowledgement packet carrying the same sequence number). The two
/// are tracked separately because they fail differently.
public actor RelayClient {
    public struct Configuration: Sendable {
        /// Largest payload carried by one fragment. Both real clients use 512 MiB, so in practice
        /// a message is always a single fragment; multi-fragment delivery is untested end to end.
        public var fragmentSize = 512 << 20
        /// How long to wait for the peer's acknowledgement of one fragment. Both clients use 15 s.
        public var ackTimeout: Duration = .seconds(15)
        /// Additional attempts after an acknowledgement times out.
        public var retries = 2
        /// Upper bounds for reassembling an inbound message.
        public var maxMessageBytes = 32 << 20
        public var maxFragments = 4096
        /// Incomplete inbound messages kept at once; further ones are refused.
        public var maxAssemblies = 16
        /// An incomplete inbound message is dropped after this long without a new fragment.
        public var assemblyLifetime: Duration = .seconds(60)
        public init() {}
    }

    public struct InboundMessage: Equatable, Sendable {
        public var source: String
        public var type: RelayMessageType
        public var payload: Data
        public var trace: TraceContext?
    }

    public enum Event: Equatable, Sendable {
        /// The hub accepted the connection. `partners` are the peers currently present.
        case connected(region: String?, partners: [String])
        case partnerConnected(id: String, region: String?)
        case partnerDisconnected(id: String)
        case partnerHeartbeat(id: String)
        case message(InboundMessage)
        case closed
    }

    public enum RelayError: Error, Equatable {
        /// The peer did not acknowledge a fragment in time, after all retries.
        case acknowledgementTimeout(sequenceNumber: Int)
        /// The peer rejected a fragment.
        case negativeAcknowledgement(sequenceNumber: Int, errorNumber: Int)
        case closed
    }

    private struct OutboundState {
        var sessionId = UUID().uuidString.lowercased()
        var nextSequence = 1
        var nextMessageId = 1
    }

    private struct AckKey: Hashable { var peer: String; var session: String; var sequence: Int }
    private struct AssemblyKey: Hashable { var peer: String; var session: String; var messageId: Int; var type: Int }
    private struct Assembly { var count: Int; var parts: [Int: Data] = [:]; var bytes = 0; var trace: TraceContext?; var touched = ContinuousClock.now }

    private let hub: HubConnection
    private let configuration: Configuration
    private var outbound: [String: OutboundState] = [:]
    private var ackWaiters: [AckKey: CheckedContinuation<DcgPacket.Ack, Error>] = [:]
    private var earlyAcks: [(key: AckKey, ack: DcgPacket.Ack)] = []
    private var assemblies: [AssemblyKey: Assembly] = [:]
    private var delivered: [AssemblyKey] = []
    private var pumpTask: Task<Void, Never>?
    private let continuation: AsyncStream<Event>.Continuation

    /// Presence changes and reassembled inbound messages, in order.
    public nonisolated let events: AsyncStream<Event>

    public init(hub: HubConnection, configuration: Configuration = Configuration()) {
        self.hub = hub
        self.configuration = configuration
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
    }

    /// Starts consuming hub events. Call once, after `HubConnection.start()`.
    public func start() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self, hub] in
            for await invocation in hub.events { await self?.handle(invocation) }
            await self?.finish()
        }
    }

    public func close() async {
        await hub.close()
    }

    // MARK: Outbound

    /// Announces presence to a peer. Phone Link does this right after the hub connects and again
    /// whenever the peer appears.
    public func sendConnected(to peer: String, trace: TraceContext = TraceContext(scenarioId: "SendConnectedMessage", triggerId: "ConnectingWithPartner")) async throws {
        try await hub.invoke("SendConnectedAsync", arguments: [trace.encoded, .string(peer), .map([])],
                             headers: RelayClient.invocationHeaders(trace))
    }

    /// Sends one message to a peer and returns when every fragment has been acknowledged.
    public func send(_ payload: Data, type: RelayMessageType, to peer: String, trace: TraceContext = TraceContext()) async throws {
        var state = outbound[peer] ?? OutboundState()
        let messageId = state.nextMessageId
        state.nextMessageId += 1
        let chunks = RelayClient.split(payload, size: configuration.fragmentSize)
        let firstSequence = state.nextSequence
        state.nextSequence += chunks.count
        outbound[peer] = state

        for (index, chunk) in chunks.enumerated() {
            let fragment = DcgPacket.Fragment(sessionId: state.sessionId, sequenceNumber: firstSequence + index, messageId: messageId,
                                              messageType: type, fragmentId: index + 1, fragmentCount: chunks.count, raw: chunk)
            try await sendFragment(fragment, to: peer, trace: trace)
        }
    }

    private func sendFragment(_ fragment: DcgPacket.Fragment, to peer: String, trace: TraceContext) async throws {
        let arguments: [MsgPack] = [trace.encoded, .string(peer), DcgPacket.fragment(fragment).encoded]
        let key = AckKey(peer: peer, session: fragment.sessionId, sequence: fragment.sequenceNumber)
        var attempt = 0
        while true {
            earlyAcks.removeAll { $0.key == key }
            // The hub's Completion only says the relay accepted the fragment.
            try await hub.invoke("SendMessageAsync", arguments: arguments, headers: RelayClient.invocationHeaders(trace))
            do {
                // The peer's acknowledgement may already have arrived while we awaited the hub.
                let ack = try await waitForAck(key)
                guard ack.success else {
                    throw RelayError.negativeAcknowledgement(sequenceNumber: ack.sequenceNumber, errorNumber: ack.errorNumber)
                }
                return
            } catch RelayError.acknowledgementTimeout {
                attempt += 1
                if attempt > configuration.retries { throw RelayError.acknowledgementTimeout(sequenceNumber: fragment.sequenceNumber) }
            }
        }
    }

    private func waitForAck(_ key: AckKey) async throws -> DcgPacket.Ack {
        if let index = earlyAcks.firstIndex(where: { $0.key == key }) { return earlyAcks.remove(at: index).ack }
        let timeout = configuration.ackTimeout
        return try await withCheckedThrowingContinuation { continuation in
            ackWaiters[key] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.cancelAck(key, error: RelayError.acknowledgementTimeout(sequenceNumber: key.sequence))
            }
        }
    }

    private func cancelAck(_ key: AckKey, error: Error) {
        ackWaiters.removeValue(forKey: key)?.resume(throwing: error)
    }

    // MARK: Inbound

    private func handle(_ invocation: HubConnection.Invocation) {
        let arguments = invocation.arguments
        switch invocation.target {
        case "OnConnected":
            let info = arguments.first
            let partners = info?["Partners"]?.arrayValue?.compactMap(\.stringValue) ?? []
            continuation.yield(.connected(region: info?["RegionName"]?.stringValue, partners: partners))
        case "OnPartnerConnected":
            guard let id = arguments.first?.stringValue else { return }
            continuation.yield(.partnerConnected(id: id, region: arguments.count > 2 ? arguments[2]["RegionName"]?.stringValue : nil))
        case "OnPartnerDisconnected":
            guard let id = arguments.first?.stringValue else { return }
            continuation.yield(.partnerDisconnected(id: id))
        case "OnPartnerHeartBeat":
            guard let id = arguments.first?.stringValue else { return }
            continuation.yield(.partnerHeartbeat(id: id))
        case "OnReceiveMessage", "OnReceiveSessionBasedMessage":
            guard arguments.count >= 3, let source = arguments[0].stringValue, let packet = try? DcgPacket(arguments[2]) else { return }
            receive(packet, from: source, trace: TraceContext(arguments[1]))
        default:
            break
        }
    }

    private func receive(_ packet: DcgPacket, from source: String, trace: TraceContext?) {
        switch packet {
        case .ack(let ack):
            let key = AckKey(peer: source, session: ack.sessionId, sequence: ack.sequenceNumber)
            if let waiter = ackWaiters.removeValue(forKey: key) {
                waiter.resume(returning: ack)
            } else if outbound[source]?.sessionId == ack.sessionId {
                // Arrived before the sender started waiting. Keep the newest few.
                if earlyAcks.count >= 64 { earlyAcks.removeFirst() }
                earlyAcks.append((key, ack))
            }
        case .fragment(let fragment):
            let key = AssemblyKey(peer: source, session: fragment.sessionId, messageId: fragment.messageId, type: fragment.messageType.rawValue)
            let accepted = store(fragment, key: key, trace: trace)
            // Acknowledge first, then deliver: the sender retries anything left unacknowledged.
            acknowledge(fragment, to: source, success: accepted, trace: trace)
            guard accepted, let assembly = assemblies[key], assembly.parts.count == assembly.count else { return }
            assemblies.removeValue(forKey: key)
            delivered.append(key)
            if delivered.count > 256 { delivered.removeFirst(delivered.count - 256) }
            let payload = (1...assembly.count).reduce(into: Data()) { $0.append(assembly.parts[$1]!) }
            continuation.yield(.message(InboundMessage(source: source, type: fragment.messageType, payload: payload, trace: assembly.trace)))
        }
    }

    /// Stores a fragment. Returns false when it violates the message's shape or the size limits.
    private func store(_ fragment: DcgPacket.Fragment, key: AssemblyKey, trace: TraceContext?) -> Bool {
        // A retransmission of a message already delivered is acknowledged but not delivered again.
        if delivered.contains(key) { return true }
        guard fragment.fragmentCount >= 1, fragment.fragmentCount <= configuration.maxFragments,
              (1...fragment.fragmentCount).contains(fragment.fragmentId) else { return false }
        // Forget partial messages the peer abandoned, and refuse new ones beyond the cap.
        let now = ContinuousClock.now
        assemblies = assemblies.filter { now - $0.value.touched < configuration.assemblyLifetime }
        if assemblies[key] == nil, assemblies.count >= configuration.maxAssemblies { return false }
        var assembly = assemblies[key] ?? Assembly(count: fragment.fragmentCount, trace: trace)
        assembly.touched = now
        guard assembly.count == fragment.fragmentCount else { return false }
        if let existing = assembly.parts[fragment.fragmentId] { return existing == fragment.raw }
        guard assembly.bytes + fragment.raw.count <= configuration.maxMessageBytes else {
            assemblies.removeValue(forKey: key)
            return false
        }
        assembly.parts[fragment.fragmentId] = fragment.raw
        assembly.bytes += fragment.raw.count
        assemblies[key] = assembly
        return true
    }

    private func acknowledge(_ fragment: DcgPacket.Fragment, to peer: String, success: Bool, trace: TraceContext?) {
        let ack = DcgPacket.ack(.init(sessionId: fragment.sessionId, sequenceNumber: fragment.sequenceNumber,
                                      success: success, errorNumber: success ? 0 : 1))
        let outTrace = TraceContext(traceId: trace?.traceId ?? TraceContext.randomHex(bytes: 16),
                                    scenarioId: trace?.scenarioId, triggerId: trace?.triggerId)
        let arguments: [MsgPack] = [outTrace.encoded, .string(peer), ack.encoded]
        Task { [hub] in
            _ = try? await hub.invoke("SendMessageAsync", arguments: arguments, headers: RelayClient.invocationHeaders(outTrace))
        }
    }

    private func finish() {
        for (_, waiter) in ackWaiters { waiter.resume(throwing: RelayError.closed) }
        ackWaiters.removeAll()
        continuation.yield(.closed)
        continuation.finish()
    }

    // MARK: Helpers

    static func split(_ payload: Data, size: Int) -> [Data] {
        guard payload.count > size else { return [payload] }
        var chunks: [Data] = []
        var index = payload.startIndex
        while index < payload.endIndex {
            let end = min(index + size, payload.endIndex)
            chunks.append(Data(payload[index..<end]))
            index = end
        }
        return chunks
    }

    /// Phone Link sends a `traceparent` header on every hub invocation.
    static func invocationHeaders(_ trace: TraceContext) -> MsgPack {
        .map(["traceparent": .string(trace.traceparent())])
    }
}
