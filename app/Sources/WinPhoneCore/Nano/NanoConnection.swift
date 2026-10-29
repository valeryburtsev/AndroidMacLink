import Foundation
import Network

/// Where a Nano connection sends and receives its datagrams.
public protocol NanoDatagramTransport: Sendable {
    func send(_ datagram: Data) async throws
    /// Every datagram that arrives, until the transport closes.
    var incoming: AsyncStream<Data> { get }
    func close()
    /// How many datagrams the transport has taken off the network so far; -1 where it does
    /// not count. Against the number handled, it shows a backlog.
    var receivedCount: Int { get }
}

extension NanoDatagramTransport {
    public var receivedCount: Int { -1 }
}

/// UDP to one address, over the system's network stack.
public final class NanoUDPTransport: NanoDatagramTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: AsyncStream<Data>.Continuation
    public let incoming: AsyncStream<Data>

    public init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 1, using: .udp)
        (incoming, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    /// Opens the socket. Returns once it is usable; throws if it cannot be.
    public func start(timeout: Duration = .seconds(5)) async throws {
        let ready = AsyncStream<Result<Void, Error>>.makeStream()
        connection.stateUpdateHandler = { [continuation] state in
            switch state {
            case .ready: ready.continuation.yield(.success(()))
            case .failed(let error): ready.continuation.yield(.failure(error)); continuation.finish()
            case .cancelled: continuation.finish()
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "winphone.nano.udp"))
        let timer = Task {
            try? await Task.sleep(for: timeout)
            ready.continuation.yield(.failure(NanoConnection.ConnectionError.noAnswer))
        }
        defer { timer.cancel() }
        for await result in ready.stream {
            try result.get()
            break
        }
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.continuation.yield(data) }
            if error != nil {
                self.continuation.finish()
                return
            }
            self.receive()
        }
    }

    public func send(_ datagram: Data) async throws {
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            connection.send(content: datagram, completion: .contentProcessed { error in
                if let error { waiter.resume(throwing: error) } else { waiter.resume() }
            })
        }
    }

    public func close() {
        connection.cancel()
        continuation.finish()
    }
}

/// One Nano connection as the PC runs it: the side that opens the UDP path.
///
/// It performs the start sequence seen from Windows (size probe, keep-alive answer,
/// rate-control handshake, the burst of filler packets that lets the other side measure the
/// link), then acknowledges what arrives, delivers its own packets reliably, accepts the
/// channels the phone creates and hands their messages and blobs to the caller. Layouts and
/// order are those of a recorded Windows session (`protocol/specs/nano-wire-notes.md`,
/// section 10); the retransmission behaviour is this client's own, as none was recorded.
public actor NanoConnection {
    public enum ConnectionError: Error, Equatable {
        /// The phone did not complete the start sequence in time.
        case noAnswer
        case closed
        /// A file being sent could not be read to its announced end.
        case sourceEnded
    }

    public enum Event: Equatable, Sendable {
        case channelCreated(channel: UInt16, NanoChannelDescription)
        case channelClosed(channel: UInt16)
        case messageHandshake(channel: UInt16)
        case message(channel: UInt16, NanoMessageAssembler.Message)
        case blobStarted(channel: UInt16, name: String, size: UInt64)
        case blobProgress(channel: UInt16, name: String, received: Int, total: Int)
        case blobReceived(channel: UInt16, name: String, content: NanoBlobContent)
        case blobCompletion(channel: UInt16, kind: UInt32, name: String)
        /// A blob could not be stored: no room on the disk, or its file could not be written.
        case blobRefused(channel: UInt16)
        /// The phone offered video on a channel and this side accepted the format.
        case videoStarted(channel: UInt16, NanoVideoFormat)
        /// A whole frame of video.
        case videoFrame(channel: UInt16, NanoVideoFrame)
        /// The phone takes pointer and key input on a channel: the size of its screen in its
        /// own pixels, and the number the next input frame must carry.
        case inputReady(channel: UInt16, width: UInt32, height: UInt32, nextFrameId: UInt32)
        /// The phone offered sound on a channel and this side accepted the format.
        case audioStarted(channel: UInt16, NanoAudioFormat)
        /// One encoded frame of sound.
        case audioFrame(channel: UInt16, data: Data)
        /// The connection ended; the text says why, for the log.
        case closed(String)
    }

    public struct Settings: Sendable {
        public var probeSize = 1200
        /// Filler packets sent after the handshake, as Windows sends them.
        public var fillerCount = 123
        public var fillerSize = 1000
        public var handshakeRetry: Duration = .milliseconds(800)
        /// About ten seconds in all: the first try may sit behind macOS's local-network prompt.
        public var handshakeAttempts = 12
        public var keepAliveInterval: Duration = .seconds(2)
        /// Silence from the phone for this long ends the connection.
        public var silenceLimit: Duration = .seconds(15)
        public var retransmitAfter: Duration = .milliseconds(400)
        public var retransmitAttempts = 12
        /// The largest blob accepted, in bytes.
        public var blobLimit: UInt64 = 1024 * 1024 * 1024
        /// Where blobs are written as they arrive; without it they are held in memory.
        public var blobDirectory: URL?
        /// File bytes per packet when sending a blob. With every header the datagram stays
        /// below the 1,200 bytes the start sequence has shown to pass.
        public var pieceSize = 1040
        /// The most packets of a blob in flight at once.
        public var sendWindowLimit = 384
        /// Where whole frames of video go, straight from the connection, when set: a picture
        /// many times a second should not queue behind everything else that is reported.
        public var videoSink: (@Sendable (NanoVideoFrame) -> Void)?
        public init() {}
    }

    static let firstSequence: UInt16 = 100
    static let logWindowSize: UInt8 = 13

    private let transport: NanoDatagramTransport
    private let keys: NanoSessionKeys
    private let settings: Settings
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private let continuation: AsyncStream<Event>.Continuation
    public nonisolated let events: AsyncStream<Event>

    // Encryption layer.
    private var outgoingIndex: UInt64 = 0
    private var incomingRollover: UInt32 = 0
    private var incomingHighest: UInt16?

    // Start sequence.
    private var handshakeDone = false
    private var handshakeWaiters: [CheckedContinuation<Void, Error>] = []
    private var synRetry: UInt16 = 0
    private var synStarted = false
    private var largestReceived: UInt32 = 0

    // Reliability.
    private var nextDataSequence = NanoConnection.firstSequence
    private var unacknowledged: [UInt16: (type: UInt8, channel: UInt16, body: Data, inner: UInt16, sent: ContinuousClock.Instant, attempts: Int)] = [:]
    /// Which of the phone's packets arrived, what is owed an acknowledgement, what is missing.
    private var inbound = NanoInbound(first: NanoConnection.firstSequence)
    /// Arrivals since the last acknowledgement went out.
    private var unreported = 0
    /// What has been seen lately, to tell a repeat from a new packet.
    private var seenData: Set<UInt16> = []
    private var highestSeen: UInt16 = NanoConnection.firstSequence &- 1
    private var ackTimer: Task<Void, Never>?
    /// The last report of missing packets sent, and how often it was repeated unchanged.
    private var lastVector: NanoInbound.Signature?
    private var vectorRepeats = 0
    private var holeTimer: Task<Void, Never>?
    private var sentDelayedAckInfo = false
    /// How many packets of a blob may be unacknowledged right now: grows while they are
    /// acknowledged, halves when one is lost.
    private var sendWindow = 32
    private var windowWaiters: [CheckedContinuation<Void, Never>] = []
    private var windowCutAt: ContinuousClock.Instant?
    /// While a blob is being sent the phone is told it may acknowledge many packets at once.
    private var bulkSending = false
    private var sinceDelayedAckInfo = 0
    private var lostPackets = 0
    // Counters for the log.
    private var dataPackets = 0, duplicatePackets = 0, lastStatsAt: ContinuousClock.Instant?
    private var fillerPackets = 0, vectorsFromPhone = 0, vectorsSent = 0, resentOnReport = 0

    // Channels.
    private var channels: [UInt16: NanoChannelDescription] = [:]
    private var innerSequence: [UInt16: UInt64] = [:]
    private var seenInner: [UInt16: Set<UInt16>] = [:]
    private var messages: [UInt16: NanoMessageAssembler] = [:]
    private var blobs: [UInt16: NanoBlobAssembler] = [:]
    private var blobPercent: [String: Int] = [:]
    private var videos: [UInt16: NanoVideoAssembler] = [:]
    private var videoFrames = 0, videoGaps = 0, videoKeyframes = 0, videoBytes = 0
    /// Since when the picture has been broken and a whole frame is awaited, and when one was last asked for.
    private var videoBrokenSince: ContinuousClock.Instant?
    /// When the picture broke, kept while it is asked for again; and the frames last reported lost.
    private var videoBrokenAt: ContinuousClock.Instant?
    private var videoLost: (channel: UInt16, first: UInt32, last: UInt32)?

    /// How long the picture has waited for a whole frame; nil while it is whole.
    public func videoBrokenDuration() -> Duration? { videoBrokenAt.map { clock.now - $0 } }
    private var videoStats: (at: ContinuousClock.Instant, frames: Int, bytes: Int)?
    private var nextMessageId = UInt32.random(in: 1...UInt32.max / 2)

    /// What was sent and received while the connection started: packet types, sizes and
    /// flags only. Written to the log when the start ends, either way.
    private var startTrace: [String] = []

    private func trace(_ text: String) {
        guard startTrace.count < 120 else { return }
        let ms = (clock.now - started).microseconds / 1000
        startTrace.append("+\(ms) \(text)")
    }

    private func flushTrace(_ outcome: String) {
        guard !startTrace.isEmpty else { return }
        diag("nano", "start sequence (\(outcome)): " + startTrace.joined(separator: " | "))
        startTrace = []
    }

    private var tasks: [Task<Void, Never>] = []
    private var lastHeard: ContinuousClock.Instant
    private var isClosed = false

    public init(transport: NanoDatagramTransport, keys: NanoSessionKeys, settings: Settings = Settings()) {
        self.transport = transport
        self.keys = keys
        self.settings = settings
        started = clock.now
        lastHeard = clock.now
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
    }

    // MARK: Lifecycle

    /// Runs the start sequence. Returns when the phone has completed the rate-control
    /// handshake, after which channels can be used.
    public func start() async throws {
        tasks.append(Task { [weak self, transport] in
            for await datagram in transport.incoming {
                guard let self else { return }
                let began = ContinuousClock.now
                await self.receive(datagram)
                await self.handled(after: began)
            }
            await self?.finish("the socket closed")
        })
        // First packet: the size probe, as from Windows.
        var probe = Data([1, 0])
        probe.append(Data((0..<max(0, settings.probeSize - 2)).map { _ in UInt8.random(in: 0...255) }))
        try await send(type: 102, channel: 0, payload: probe, inner: 0)
        diag("nano", "probe sent")
        // The handshake starts when the phone is heard from, or shortly after in any case.
        tasks.append(Task { [weak self, settings] in
            try? await Task.sleep(for: .milliseconds(500))
            await self?.beginHandshake()
            for _ in 0..<settings.handshakeAttempts {
                try? await Task.sleep(for: settings.handshakeRetry)
                guard let self, await !self.handshakeDone, await !self.isClosed else { return }
                await self.sendSyn()
            }
            await self?.finish("the phone did not answer the handshake")
        })
        try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, Error>) in
            if handshakeDone { waiter.resume() } else if isClosed { waiter.resume(throwing: ConnectionError.closed) } else { handshakeWaiters.append(waiter) }
        }
    }

    public func close() {
        finish("closed here")
    }

    private func finish(_ reason: String) {
        guard !isClosed else { return }
        isClosed = true
        for task in tasks { task.cancel() }
        tasks.removeAll()
        ackTimer?.cancel()
        holeTimer?.cancel()
        releaseWindow()
        transport.close()
        for waiter in handshakeWaiters { waiter.resume(throwing: handshakeDone ? ConnectionError.closed : ConnectionError.noAnswer) }
        handshakeWaiters.removeAll()
        flushTrace("ended")
        diag("nano", "connection ended: \(reason)")
        continuation.yield(.closed(reason))
        continuation.finish()
    }

    // MARK: Sending

    /// Seals and sends one datagram with the next packet counter.
    private func send(type: UInt8, channel: UInt16, payload: Data, inner: UInt16) async throws {
        guard !isClosed else { throw ConnectionError.closed }
        let index = outgoingIndex
        outgoingIndex += 1
        let header = NanoHeader(payloadType: type, sequence: UInt16(truncatingIfNeeded: index), ssrc: UInt32(channel))
        if !handshakeDone { trace("tx t\(type) seq\(index) len\(payload.count)") }
        let sealed = try NanoDatagram(header: header, payload: payload, innerSequence: inner).sealed(with: keys, rollover: UInt32(truncatingIfNeeded: index >> 16))
        try await transport.send(sealed)
    }

    private func beginHandshake() async {
        guard !synStarted, !isClosed else { return }
        synStarted = true
        await sendSyn()
    }

    private func sendSyn() async {
        let syn = NanoRateHandshake.syn(version: 3, receiverLogSize: 14, initialSendSequence: UInt64(NanoConnection.firstSequence), controllerType: 5, retry: synRetry)
        synRetry += 1
        try? await send(type: 100, channel: 0, payload: syn.encoded(), inner: 0)
    }

    private var now: Int64 { (clock.now - started).microseconds }

    /// What goes in the "ack of acks" part: the lowest number of ours still outstanding, or
    /// the next to be used. The phone stops waiting for anything below it, which is how it
    /// learns that a packet sent again under a new number will not come under the old one.
    private var ownAckOfAcks: UInt16 {
        var lowest = nextDataSequence
        for sequence in unacknowledged.keys where Int16(bitPattern: sequence &- lowest) < 0 { lowest = sequence }
        return lowest
    }

    /// The acknowledgement owed, taken for a packet that is about to leave.
    private func takeAck() -> NanoRateHeader.Ack? {
        guard let ack = inbound.takeAck(at: now) else { return nil }
        unreported = 0
        ackTimer?.cancel()
        ackTimer = nil
        return ack
    }

    /// Sends what is owed, alone. Like Windows: payload type 35 on channel 0.
    private func sendAck() async {
        guard handshakeDone else { return }
        while let ack = takeAck() {
            let header = NanoRateHeader(logWindowSize: NanoConnection.logWindowSize, ack: ack, ackOfAcks: ownAckOfAcks)
            try? await send(type: 35, channel: 0, payload: header.encoded(), inner: 0)
        }
    }

    /// Tells the phone which packets are missing. A plain acknowledgement cannot: it covers
    /// everything below the number it names. The phone sends the missing content again once
    /// it has seen enough later packets arrive, or at once when the same report comes twice.
    /// - Parameter repeating: Send it although nothing changed, to have the phone act now.
    private func reportHole(repeating: Bool = false) async {
        await sendAck()
        guard handshakeDone, let report = inbound.vector(at: now) else { return }
        // Never twice by accident: an unchanged report means "lost" to the phone.
        guard repeating || report.signature != lastVector else { return }
        if !repeating { vectorRepeats = 0 }
        lastVector = report.signature
        vectorsSent += 1
        let header = NanoRateHeader(logWindowSize: NanoConnection.logWindowSize, ackOfAcks: ownAckOfAcks, ackVector: report.vector)
        try? await send(type: 35, channel: 0, payload: header.encoded(), inner: 0)
        armHoleTimer()
    }

    /// While packets are missing and nothing arrives, the report is repeated: first after
    /// 20 ms, when anything on its way has had time to arrive, then more slowly.
    private func armHoleTimer() {
        holeTimer?.cancel()
        let seen = dataPackets
        let delay: Duration = vectorRepeats == 0 ? .milliseconds(20) : .milliseconds(150)
        holeTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { await self?.holeTimerFired(seen) }
        }
    }

    private func holeTimerFired(_ seen: Int) async {
        holeTimer = nil
        guard inbound.hasHole, !isClosed else { return }
        // Packets are still arriving: each brings its own report.
        if seen != dataPackets { armHoleTimer(); return }
        guard vectorRepeats < 40 else { return }
        vectorRepeats += 1
        await reportHole(repeating: true)
    }

    /// After the book of arrivals changed: reports what is missing, or acknowledges, at once
    /// or together with the next few packets.
    private func acknowledge(_ arrival: NanoInbound.Arrival?) async {
        if inbound.hasHole {
            if arrival != .repeated { await reportHole() }
            return
        }
        lastVector = nil
        holeTimer?.cancel()
        holeTimer = nil
        if arrival != nil { unreported += 1 }
        if arrival == .late || unreported >= 16 {
            await sendAck()
        } else if ackTimer == nil {
            ackTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(10))
                if !Task.isCancelled { await self?.ackTimerFired() }
            }
        }
    }

    private func ackTimerFired() async {
        ackTimer = nil
        await sendAck()
    }

    /// Sends a packet that must arrive: it gets the next data sequence number and is sent
    /// again until the phone acknowledges it.
    private func sendReliable(type: UInt8, channel: UInt16, body: Data, inner: UInt16) async throws {
        guard handshakeDone else { throw ConnectionError.closed }
        let sequence = nextDataSequence
        nextDataSequence &+= 1
        unacknowledged[sequence] = (type, channel, body, inner, clock.now, 1)
        try await transmit(sequence)
    }

    private func transmit(_ sequence: UInt16) async throws {
        guard let entry = unacknowledged[sequence] else { return }
        var header = NanoRateHeader(logWindowSize: NanoConnection.logWindowSize, ack: takeAck(), ackOfAcks: ownAckOfAcks, dataSequence: sequence)
        sinceDelayedAckInfo += 1
        if !sentDelayedAckInfo || (bulkSending && sinceDelayedAckInfo >= 16) {
            // How many packets the phone may let pass before it acknowledges, and how long it
            // may wait: one and 20 ms as Windows asks at first, many while a file is sent,
            // repeated every sixteenth packet as the phone itself does.
            sentDelayedAckInfo = true
            sinceDelayedAckInfo = 0
            header = NanoRateHeader(logWindowSize: NanoConnection.logWindowSize, ack: header.ack, delayedAck: (bulkSending ? 39 : 1, 20), ackOfAcks: header.ackOfAcks, dataSequence: sequence)
        }
        try await send(type: entry.type, channel: entry.channel, payload: header.encoded() + entry.body, inner: entry.inner)
    }

    private func retransmitDue() async {
        let now = clock.now
        for (sequence, entry) in unacknowledged where now - entry.sent >= settings.retransmitAfter {
            guard await resend(sequence) else { return }
        }
    }

    /// Sends a packet again under a new number, as this transport does: the old number is
    /// dead, and the layers above tell a repeat by the packet's own channel number.
    /// - Returns: False when the connection was given up instead.
    private func resend(_ sequence: UInt16) async -> Bool {
        guard let entry = unacknowledged[sequence] else { return true }
        lostPackets += 1
        // A loss says the link has less room than assumed, at most once per stretch of losses.
        let now = clock.now
        if windowCutAt.map({ now - $0 > .milliseconds(200) }) ?? true {
            windowCutAt = now
            sendWindow = max(16, sendWindow / 2)
        }
        if entry.attempts >= settings.retransmitAttempts {
            finish("the phone stopped acknowledging")
            return false
        }
        unacknowledged.removeValue(forKey: sequence)
        let fresh = nextDataSequence
        nextDataSequence &+= 1
        unacknowledged[fresh] = (entry.type, entry.channel, entry.body, entry.inner, clock.now, entry.attempts + 1)
        try? await transmit(fresh)
        return true
    }

    /// The phone's report of which of our packets it has: everything below the base and
    /// every one marked arrived is done with; one marked missing is sent again now.
    private func apply(_ vector: NanoRateHeader.AckVector) async {
        let base = vector.baseSequence
        let before = unacknowledged.count
        for sequence in Array(unacknowledged.keys) where Int16(bitPattern: sequence &- base) < 0 { unacknowledged.removeValue(forKey: sequence) }
        let now = clock.now
        let elements = vector.elements
        let newest = elements.lastIndex(of: true) ?? 0
        for (index, arrived) in elements.enumerated() where arrived { unacknowledged.removeValue(forKey: base &+ UInt16(truncatingIfNeeded: index)) }
        noteAcknowledged(before - unacknowledged.count)
        for (index, arrived) in elements.enumerated() where !arrived {
            let sequence = base &+ UInt16(truncatingIfNeeded: index)
            // Lost, not late: eight packets sent after it have arrived, or it has had its time.
            guard let entry = unacknowledged[sequence], newest - index >= 8 || now - entry.sent >= .milliseconds(50) else { continue }
            resentOnReport += 1
            guard await resend(sequence) else { return }
        }
    }

    /// Packets of ours were acknowledged: the window opens a little and waiting senders go on.
    private func noteAcknowledged(_ count: Int) {
        guard count > 0 else { return }
        // Quickly at first, then a packet at a time.
        sendWindow = min(settings.sendWindowLimit, sendWindow + (sendWindow < 128 ? count : 1))
        releaseWindow()
    }

    private func releaseWindow() {
        let waiters = windowWaiters
        windowWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Returns once another packet of a blob may be sent.
    private func waitForWindow() async {
        while unacknowledged.count >= sendWindow, !isClosed {
            await withCheckedContinuation { windowWaiters.append($0) }
        }
    }

    /// The filler burst Windows sends right after the handshake: packets of zeros that the
    /// other side's rate controller measures the link with. The phone sends the same.
    private func sendFiller() async {
        for index in 0..<settings.fillerCount {
            let sequence = nextDataSequence
            nextDataSequence &+= 1
            var header = NanoRateHeader(logWindowSize: NanoConnection.logWindowSize, ackOfAcks: NanoConnection.firstSequence, dataSequence: sequence)
            if index % 16 == 0 {
                sentDelayedAckInfo = true
                header = NanoRateHeader(logWindowSize: NanoConnection.logWindowSize, delayedAck: (1, 20), ackOfAcks: NanoConnection.firstSequence, dataSequence: sequence)
            }
            // Filler is not sent again when lost; nothing depends on it.
            try? await send(type: 104, channel: 0, payload: header.encoded() + Data(count: settings.fillerSize), inner: 0)
        }
    }

    // MARK: Channels, for the caller

    /// Sends a message on a `Messaging` channel.
    public func sendMessage(channel: UInt16, path: String, body: Data) async throws {
        let id = nextMessageId
        nextMessageId &+= 1
        try await sendChannelPacket(channel: channel, NanoMessagePacket.message(id: id, path: path, body: body).encoded())
    }

    public func sendBlobPacket(channel: UInt16, _ packet: NanoBlobPacket) async throws {
        try await sendChannelPacket(channel: channel, packet.encoded())
    }

    /// - Parameters:
    ///   - mode: the first byte of the packet's sequencer header where the channel's class
    ///     uses another than the usual one; such packets name no packet before them.
    ///   - reliable: false for what is worthless late, such as a pointer position: it is
    ///     sent once and never again.
    ///   - type: the datagram's payload type; an audio channel names the kind of its packets with it.
    private func sendChannelPacket(channel: UInt16, _ packet: Data, mode: UInt8? = nil, reliable: Bool = true, type: UInt8 = 35) async throws {
        let number = innerSequence[channel, default: 0]
        innerSequence[channel] = number + 1
        let header = mode.map { NanoSequencerHeader(mode: $0, dependsOn: 0) } ?? NanoSequencerHeader(forPacket: number)
        let body = header.encoded() + packet
        if reliable {
            try await sendReliable(type: type, channel: channel, body: body, inner: UInt16(truncatingIfNeeded: number))
        } else {
            guard handshakeDone else { throw ConnectionError.closed }
            // Before the number is taken: what is still outstanding below it stays so.
            let outstanding = ownAckOfAcks
            let sequence = nextDataSequence
            nextDataSequence &+= 1
            let rate = NanoRateHeader(logWindowSize: NanoConnection.logWindowSize, ack: takeAck(), ackOfAcks: outstanding, dataSequence: sequence)
            try await send(type: 35, channel: channel, payload: rate.encoded() + body, inner: UInt16(truncatingIfNeeded: number))
        }
    }

    // MARK: Screen mirroring

    /// Sequencer modes of the video and input channels, as recorded from Windows: 4 on a
    /// handshake, 5 on the request to start, 1 on input frames, the usual chain on the rest.
    private enum MediaMode { static let handshake: UInt8 = 4, start: UInt8 = 5, input: UInt8 = 1 }

    /// Sends one input frame: what the pointer and keys did. Sent once; a lost one is
    /// overtaken by the next.
    public func sendInputFrame(channel: UInt16, frameId: UInt32, body: Data) async throws {
        try await sendChannelPacket(channel: channel, NanoInputPacket.frame(frameId: frameId, timestamp: now, body: body).encoded(),
                                    mode: MediaMode.input, reliable: false)
    }

    /// Asks the phone to send a whole frame next, as after a frame went missing.
    /// How many frames of video have arrived on this connection.
    public var videoFrameCount: Int { videoFrames }

    /// Asks once more for the stream to start with a whole picture: for a phone that was
    /// asked while it had nothing to show.
    public func restartVideo(channel: UInt16) async throws {
        try await sendChannelPacket(channel: channel, NanoVideoPacket.start().encoded(), mode: MediaMode.start)
    }

    public func requestKeyframe(channel: UInt16) async throws {
        try await sendChannelPacket(channel: channel, NanoVideoPacket.control(flags: NanoVideoPacket.Control.requestKeyframe, body: Data()).encoded())
    }

    /// Where each video channel's frame numbers last began.
    private var videoStarts: [UInt16: UInt32] = [:]

    private func receiveVideo(_ packet: NanoVideoPacket, channel: UInt16) async {
        switch packet {
        case .serverHandshake(_, let width, let height, let rate, _, let formats):
            // Take what the phone offers first; it offered one format in the recording.
            let format = formats.first ?? NanoVideoFormat(framesPerSecond: rate, width: width, height: height)
            diag("nano", "channel \(channel): video offered, \(format.width) x \(format.height) at \(format.framesPerSecond), codec \(format.codec)")
            // An offer in the middle of a stream is a new stream, as after the phone was turned:
            // its frames are counted afresh.
            // The new stream is numbered well above the old one: a straggler of the old stream
            // arriving now cannot make the new frames look late.
            let before = videos[channel]?.lastCompleted ?? videoStarts[channel]
            videos[channel] = nil
            videoShown[channel] = nil
            videoReleaseTimers.removeValue(forKey: channel)?.cancel()
            videoBrokenSince = nil
            videoBrokenAt = nil
            let first = before.map { $0 &+ 1_000_000 } ?? UInt32.random(in: 1...UInt32.max / 2)
            videoStarts[channel] = first
            try? await sendChannelPacket(channel: channel, NanoVideoPacket.clientHandshake(initialFrameId: first, format: format).encoded(), mode: MediaMode.handshake)
            try? await sendChannelPacket(channel: channel, NanoVideoPacket.start().encoded(), mode: MediaMode.start)
            continuation.yield(.videoStarted(channel: channel, format))
        case .data:
            var assembler = videos.removeValue(forKey: channel) ?? NanoVideoAssembler()
            let ready = assembler.take(packet, at: clock.now)
            videos[channel] = assembler
            scheduleVideoRelease(channel: channel, at: assembler.releaseDeadline)
            for frame in ready { await deliverVideo(frame, channel: channel) }
        default:
            break
        }
    }

    /// The frame last shown on each video channel.
    private var videoShown: [UInt16: UInt32] = [:]
    private var videoReleaseTimers: [UInt16: Task<Void, Never>] = [:]

    /// Frames held for a missing one are let go at their time, whether or not it came.
    private func scheduleVideoRelease(channel: UInt16, at deadline: ContinuousClock.Instant?) {
        guard let deadline else {
            videoReleaseTimers.removeValue(forKey: channel)?.cancel()
            return
        }
        guard videoReleaseTimers[channel] == nil else { return }
        videoReleaseTimers[channel] = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.releaseVideo(channel: channel)
        }
    }

    private func releaseVideo(channel: UInt16) async {
        videoReleaseTimers[channel] = nil
        guard var assembler = videos[channel] else { return }
        let ready = assembler.release(at: clock.now)
        videos[channel] = assembler
        for frame in ready { await deliverVideo(frame, channel: channel) }
    }

    private func deliverVideo(_ frame: NanoVideoFrame, channel: UInt16) async {
            let before = videoShown[channel]
            videoShown[channel] = frame.id
            videoFrames += 1
            videoBytes += frame.data.count
            if frame.isKeyframe { videoKeyframes += 1 }
            // The phone learns which frame was shown, as Windows tells it for every frame.
            try? await sendChannelPacket(channel: channel, NanoVideoPacket.displayed(frameId: frame.id, at: now).encoded(), reliable: false)
            let instant = clock.now
            if frame.isKeyframe {
                videoBrokenSince = nil
                videoBrokenAt = nil
            } else if let before, frame.id != before &+ 1 {
                // Frames in between never arrived whole, even after the wait: the picture is
                // broken until a whole one comes.
                videoGaps += 1
                videoBrokenSince = instant
                if videoBrokenAt == nil { videoBrokenAt = instant }
                videoLost = (channel, before &+ 1, frame.id &- 1)
                var lost = Data()
                lost.appendLE(before &+ 1)
                lost.appendLE(frame.id &- 1)
                try? await sendChannelPacket(channel: channel, NanoVideoPacket.control(flags: 0x122, body: lost).encoded())
            } else if let since = videoBrokenSince, instant - since > .milliseconds(700) {
                // Still no whole frame: the request may have been lost. Asked again.
                videoBrokenSince = instant
                try? await requestKeyframe(channel: channel)
            }
            if let sink = settings.videoSink { sink(frame) } else { continuation.yield(.videoFrame(channel: channel, frame)) }
    }

    private var audioFrames = 0, audioUnread = 0

    private func receiveAudio(payloadType: UInt8, _ inside: Data, channel: UInt16) async {
        guard let packet = try? NanoAudioPacket(payloadType: payloadType, inside) else {
            // The data packet's layout was never recorded: say how it differs, in sizes only.
            audioUnread += 1
            if audioUnread <= 3 { diag("nano", "channel \(channel): audio packet of type \(payloadType), \(inside.count) bytes, not understood") }
            return
        }
        switch packet {
        case .serverHandshake(let version, _, let formats):
            guard let format = formats.first else { return }
            diag("nano", "channel \(channel): audio offered, version \(version), \(format.channels) channels at \(format.sampleRate) Hz, codec \(format.codec), \(formats.count) formats")
            let answer = NanoAudioPacket.clientHandshake(initialFrameId: UInt32.random(in: 1...UInt32.max / 2), format: format)
            try? await sendChannelPacket(channel: channel, answer.encoded(), type: answer.payloadType)
            let start = NanoAudioPacket.control(flags: NanoAudioPacket.startStream)
            try? await sendChannelPacket(channel: channel, start.encoded(), type: start.payloadType)
            continuation.yield(.audioStarted(channel: channel, format))
        case .data(let flags, _, _, let data):
            audioFrames += 1
            if audioFrames <= 3 { diag("nano", "channel \(channel): audio frame \(audioFrames), flags \(flags), \(data.count) bytes of \(inside.count)") }
            continuation.yield(.audioFrame(channel: channel, data: data))
        default:
            break
        }
    }

    private func receiveInput(_ packet: NanoInputPacket, channel: UInt16) async {
        guard case .serverHandshake(let version, let capabilities, let width, let height, let touches, let first) = packet else { return }
        diag("nano", "channel \(channel): input offered, version \(version), screen \(width) x \(height)")
        let time = UInt64(Date().timeIntervalSince1970 * 1000)
        try? await sendChannelPacket(channel: channel, NanoInputPacket.clientHandshake(version: version, capabilities: capabilities, maxTouches: touches, referenceTime: time).encoded(),
                                     mode: MediaMode.handshake)
        continuation.yield(.inputReady(channel: channel, width: width, height: height, nextFrameId: first &+ 1))
    }

    /// Sends a file as one blob, in the form the phone sends its own: a start packet, the
    /// bytes in segments of 100,000 cut into pieces, a completion packet. Reads the file as it
    /// goes and keeps no more of it in flight than the window allows. Stops when its task is
    /// cancelled.
    /// - Parameter onProgress: called with the bytes handed over so far, per whole percent.
    public func sendBlob(channel: UInt16, name: String, file: URL, size: Int, onProgress: (@Sendable (Int) async -> Void)? = nil) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        bulkSending = true
        defer { bulkSending = false; sentDelayedAckInfo = false }
        try await sendBlobPacket(channel: channel, .start(totalSize: UInt64(size), name: name))
        let pieceSize = max(1, settings.pieceSize)
        var sent = 0, percent = -1
        var segment: UInt64 = 0
        while sent < size {
            let length = min(NanoBlobAssembler.usualSegmentLength, size - sent)
            var bytes = Data()
            while bytes.count < length, let more = try handle.read(upToCount: length - bytes.count), !more.isEmpty { bytes.append(more) }
            guard bytes.count == length else { throw ConnectionError.sourceEnded }
            let pieces = UInt32((length + pieceSize - 1) / pieceSize)
            for offset in stride(from: 0, to: length, by: pieceSize) {
                await waitForWindow()
                try Task.checkCancellation()
                guard !isClosed else { throw ConnectionError.closed }
                let piece = bytes.subdata(in: offset..<min(offset + pieceSize, length))
                try await sendBlobPacket(channel: channel, .data(flags: 0, pieces: pieces, segment: segment, totalSize: UInt64(size), name: name,
                                                                 size: UInt32(length), offset: UInt32(offset), data: piece))
            }
            sent += length
            segment += 1
            let now = size > 0 ? sent * 100 / size : 100
            if now != percent {
                percent = now
                await onProgress?(sent)
            }
        }
        try await sendBlobPacket(channel: channel, .completion(kind: 1, name: name))
        diag("nano", "blob sent: \(size) bytes in \(segment) segments, \(lostPackets) packets sent again so far, window \(sendWindow)")
    }

    public func closeChannel(_ channel: UInt16) async throws {
        try await sendReliable(type: 97, channel: channel, body: NanoMuxControl.close(reason: 0).encoded(), inner: 0)
        channels[channel] = nil
    }

    /// Waits until everything sent so far has been acknowledged, or the time runs out.
    public func flush(timeout: Duration = .seconds(5)) async {
        let deadline = clock.now + timeout
        while !unacknowledged.isEmpty, !isClosed, clock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Receiving

    /// Datagrams handled, and how long the handling took, for the log while video runs.
    private var datagramsHandled = 0, handlingTime = Duration.zero, slowestHandling = Duration.zero

    private func handled(after began: ContinuousClock.Instant) {
        let took = ContinuousClock.now - began
        datagramsHandled += 1
        handlingTime += took
        if took > slowestHandling { slowestHandling = took }
    }

    private func receive(_ datagram: Data) async {
        guard !isClosed else { return }
        guard let header = NanoHeader(datagram) else { return }
        // The packet index: the header's 16 bits plus how often they have wrapped.
        var rollover = incomingRollover
        if let highest = incomingHighest {
            if header.sequence < 0x4000, highest > 0xC000 { rollover &+= 1 } else if header.sequence > 0xC000, highest < 0x4000, rollover > 0 { rollover -= 1 }
        }
        guard let packet = try? NanoDatagram(opening: datagram, keys: keys, rollover: rollover) else {
            trace("rx UNOPENED t\(header.payloadType) seq\(header.sequence) ssrc\(header.ssrc) size\(datagram.count)")
            // A probe that does not open, as when it arrives cut short: answered by its size
            // all the same, less the header and the trailer.
            if header.payloadType == 102, datagram.count > 64 {
                var report = Data([2, 0])
                report.appendLE(UInt16(clamping: datagram.count - 14))
                try? await send(type: 102, channel: 0, payload: report, inner: 0)
                await beginHandshake()
            }
            return
        }
        if rollover > incomingRollover || incomingHighest == nil || (rollover == incomingRollover && header.sequence > (incomingHighest ?? 0)) {
            incomingRollover = rollover
            incomingHighest = header.sequence
        }
        if largestReceived == 0 { diag("nano", "first packet from the phone opened, type \(header.payloadType)") }
        if !handshakeDone {
            var note = "rx t\(header.payloadType) seq\(header.sequence) ch\(header.channelId) len\(packet.payload.count)"
            switch header.kind {
            case .probing:
                if let probe = try? NanoProbe(packet.payload) { note += " \(probe)" }
                // The start of the first probe, to learn its form; it is filler, not content.
                if startTrace.count < 3 { note += " head \(packet.payload.prefix(28).map { String(format: "%02x", $0) }.joined())" }
            case .keepAlive: if let keepAlive = try? NanoKeepAlive(packet.payload) { note += " mtu\(keepAlive.reportedMTU) flags\(keepAlive.flags.rawValue)" }
            case .rateControl: if let handshake = try? NanoRateHandshake(packet.payload) { note += " \(handshake)" } else { note += " head \(packet.payload.prefix(4).map { String(format: "%02x", $0) }.joined())" }
            case .rateControlNoData: note = ""
            default: break
            }
            if !note.isEmpty { trace(note) }
        }
        lastHeard = clock.now
        largestReceived = max(largestReceived, UInt32(packet.payload.count))
        switch header.kind {
        case .probing:
            // The phone searches for the largest datagram that gets through: it sends probes
            // of falling sizes until one is reported back. Each is answered with its size.
            if case .probe(let size)? = try? NanoProbe(packet.payload) {
                var report = Data([2, 0])
                report.appendLE(UInt16(clamping: size))
                try? await send(type: 102, channel: 0, payload: report, inner: 0)
            }
            await beginHandshake()
        case .keepAlive:
            guard let keepAlive = try? NanoKeepAlive(packet.payload) else { return }
            if keepAlive.flags.contains(.close) {
                finish("the phone closed the connection")
            } else if keepAlive.flags.contains(.handshake) {
                var answer = Data()
                answer.appendLE(largestReceived)
                answer.appendLE(UInt32(0x12))
                try? await send(type: 101, channel: 0, payload: answer, inner: 0)
                await beginHandshake()
            }
        case .rateControl:
            guard let handshake = try? NanoRateHandshake(packet.payload) else { return }
            switch handshake {
            case .syn(_, _, let first, _, _):
                // Where the phone's numbering starts.
                if dataPackets == 0 {
                    highestSeen = UInt16(truncatingIfNeeded: first) &- 1
                    inbound = NanoInbound(first: UInt16(truncatingIfNeeded: first))
                }
                let stamp = UInt32(truncatingIfNeeded: (clock.now - started).microseconds / 1000)
                try? await send(type: 100, channel: 0, payload: NanoRateHandshake.synAck(timestamp: stamp, retry: 0).encoded(), inner: 0)
            case .synAckOfAck:
                await completeHandshake()
            case .synAck:
                break
            }
        case .rateControlNoData, .channelData, .muxControl:
            await receiveRated(packet)
        default:
            break
        }
    }

    private func completeHandshake() async {
        guard !handshakeDone else { return }
        handshakeDone = true
        flushTrace("handshake complete")
        diag("nano", "rate-control handshake complete")
        for waiter in handshakeWaiters { waiter.resume() }
        handshakeWaiters.removeAll()
        await sendFiller()
        tasks.append(Task { [weak self, settings] in
            // Keep-alives, retransmissions and the silence check share one timer.
            var sinceKeepAlive = Duration.zero
            let tick = Duration.milliseconds(100)
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard let self else { return }
                await self.retransmitDue()
                await self.logTransferStats()
                sinceKeepAlive += tick
                if sinceKeepAlive >= settings.keepAliveInterval {
                    sinceKeepAlive = .zero
                    await self.sendKeepAlive()
                }
            }
        })
    }

    private func sendKeepAlive() async {
        if clock.now - lastHeard > settings.silenceLimit {
            finish("the phone went silent")
            return
        }
        var payload = Data()
        payload.appendLE(largestReceived)
        payload.appendLE(UInt32(0))
        try? await send(type: 101, channel: 0, payload: payload, inner: 0)
    }

    /// A line for the log every two seconds while a blob is arriving: how far it is and
    /// whether packets are missing. Sizes and counts only.
    private func logTransferStats() {
        let now = clock.now
        // A broken picture on a still screen gets no further frames, and so no asking again on
        // their arrival (2026-10-16: frozen for good after a lossy minute). Asked here as well,
        // once a second, with the frames that were lost, as Windows reports them.
        if let since = videoBrokenSince, let lost = videoLost, now - since > .seconds(1) {
            videoBrokenSince = now
            var body = Data()
            body.appendLE(lost.first)
            body.appendLE(lost.last)
            Task { try? await self.sendChannelPacket(channel: lost.channel, NanoVideoPacket.control(flags: 0x122, body: body).encoded()) }
        }
        // While video runs: how many frames a second arrive whole, and how the link is doing.
        if videoFrames > 0 {
            if let last = videoStats {
                let seconds = Double((now - last.at).microseconds) / 1_000_000
                if seconds >= 5 {
                    let rate = Double(videoFrames - last.frames) / seconds, bits = Double(videoBytes - last.bytes) * 8 / seconds / 1000
                    // How the Mac keeps up: datagrams waiting to be handled, and the time each took.
                    let taken = transport.receivedCount
                    let average = datagramsHandled > 0 ? handlingTime / datagramsHandled : .zero
                    let keeping = "handled \(datagramsHandled)\(taken >= 0 ? ", waiting \(taken - datagramsHandled)" : ""), \(average.microsecondsText) µs each, slowest \(slowestHandling.microsecondsText) µs"
                    slowestHandling = .zero
                    diag("nano", "video: \(String(format: "%.1f", rate)) frames a second, \(Int(bits)) kbit/s; in all \(videoFrames) frames, \(videoKeyframes) whole, \(videoGaps) gaps, \(videos.values.reduce(0) { $0 + $1.mended }) mended in time; packets: \(inbound.missing) missing now, \(vectorsSent) reports of missing sent, the phone gave up \(inbound.abandoned) in \(inbound.jumps) steps; \(keeping)")
                    videoStats = (now, videoFrames, videoBytes)
                }
            } else {
                videoStats = (now, videoFrames, videoBytes)
            }
        }
        if let last = lastStatsAt, now - last < .seconds(2) { return }
        var lines: [String] = []
        for (channel, assembler) in blobs {
            for name in assembler.names {
                guard let state = assembler.progress(of: name), state.received < state.total else { continue }
                var line = "channel \(channel): \(state.received) of \(state.total) bytes, \(assembler.holeCount) holes"
                if let hole = assembler.firstHole(of: name) { line += ", first hole at byte \(hole.offset) for \(hole.length)" }
                lines.append(line)
            }
        }
        guard !lines.isEmpty else { return }
        lastStatsAt = now
        diag("nano", "receiving: " + lines.joined(separator: "; ") + "; newest packet \(highestSeen), \(dataPackets) data packets, \(duplicatePackets) repeats, \(fillerPackets) filler; \(inbound.missing) missing now, \(vectorsSent) reports of missing packets sent, the phone gave up \(inbound.abandoned) numbers in \(inbound.jumps) steps; \(unacknowledged.count) of ours unacknowledged, \(vectorsFromPhone) reports from the phone, \(resentOnReport) sent again on them")
    }

    /// A packet of the layers above the handshake: it starts with the rate-control header.
    private func receiveRated(_ packet: NanoDatagram) async {
        guard let header = try? NanoRateHeader(packet.payload) else { return }
        // The phone may send before its "handshake complete" packet has arrived here.
        if !handshakeDone, header.dataSequence != nil { await completeHandshake() }
        if let ack = header.ack, !unacknowledged.isEmpty {
            // The packet named and every one before it: the phone never names one above a gap.
            let before = unacknowledged.count
            for sequence in Array(unacknowledged.keys) where Int16(bitPattern: ack.sequence &- sequence) >= 0 { unacknowledged.removeValue(forKey: sequence) }
            noteAcknowledged(before - unacknowledged.count)
        }
        if let vector = header.ackVector {
            vectorsFromPhone += 1
            await apply(vector)
        }
        // Before the packet's own data: what the phone has given up is no longer waited for.
        var gaveUp = false
        if let value = header.ackOfAcks { gaveUp = inbound.noteAckOfAcks(value) > 0 }
        guard let sequence = header.dataSequence else {
            if gaveUp { await acknowledge(nil) }
            return
        }
        dataPackets += 1
        if packet.header.kind == .rateControlNoData { fillerPackets += 1 }
        // Bounded memory of what was seen: the phone's numbers only move forward.
        let isNew = seenData.insert(sequence).inserted
        if seenData.count > 8192 { seenData = seenData.filter { sequence &- $0 < 4096 } }
        if isNew {
            if Int16(bitPattern: sequence &- highestSeen) > 0 { highestSeen = sequence }
        } else {
            duplicatePackets += 1
        }
        await acknowledge(inbound.noteData(sequence, at: now))
        guard isNew, packet.payload.count > header.length else { return }
        let body = Data(packet.payload.dropFirst(header.length))
        let channel = packet.header.channelId
        switch packet.header.kind {
        case .muxControl:
            guard let control = try? NanoMuxControl(body) else { return }
            switch control {
            case .create(let description, _, _, _):
                guard channels[channel] == nil else { return }
                channels[channel] = description
                // The class and the names of its properties; "workflow" is a fixed word, the others are identifiers.
                diag("nano", "channel \(channel) created: \(description.channelClass), properties \(description.properties.keys.sorted().joined(separator: ","))\(description.properties["workflow"].map { ", workflow \($0)" } ?? "")")
                // Accept, then greet, in the order Windows does.
                try? await sendReliable(type: 97, channel: channel, body: NanoMuxControl.open(initialization: "", weight: 1).encoded(), inner: 0)
                switch description.channelClass {
                case "Messaging": try? await sendChannelPacket(channel: channel, NanoMessagePacket.handshake(version: 1).encoded())
                case "Blob": try? await sendChannelPacket(channel: channel, NanoBlobPacket.handshake(minVersion: 2, maxVersion: 3).encoded())
                default: break
                }
                continuation.yield(.channelCreated(channel: channel, description))
            case .open:
                break
            case .close:
                if channels.removeValue(forKey: channel) != nil {
                    try? await sendReliable(type: 97, channel: channel, body: NanoMuxControl.close(reason: 0).encoded(), inner: 0)
                }
                continuation.yield(.channelClosed(channel: channel))
            }
        case .channelData:
            guard body.count >= NanoSequencerHeader.length, seenInner[channel, default: []].insert(packet.innerSequence).inserted else { return }
            // The channel's packet number has 16 bits and comes round again in a large file:
            // only the recent ones are remembered, so that a later lap is not taken for a repeat.
            if let count = seenInner[channel]?.count, count > 8192 {
                let current = packet.innerSequence
                seenInner[channel] = seenInner[channel]?.filter { current &- $0 < 4096 }
            }
            let inside = Data(body.dropFirst(NanoSequencerHeader.length))
            switch channels[channel]?.channelClass {
            case "Video": if let parsed = try? NanoVideoPacket(inside) { await receiveVideo(parsed, channel: channel) }
            case "Input": if let parsed = try? NanoInputPacket(inside) { await receiveInput(parsed, channel: channel) }
            case "Audio": await receiveAudio(payloadType: packet.header.payloadType, inside, channel: channel)
            default: receiveChannelPacket(inside, channel: channel)
            }
        default:
            break
        }
    }

    private func receiveChannelPacket(_ packet: Data, channel: UInt16) {
        switch channels[channel]?.channelClass {
        case "Messaging":
            guard let parsed = try? NanoMessagePacket(packet) else { return }
            if case .handshake = parsed {
                continuation.yield(.messageHandshake(channel: channel))
                return
            }
            var assembler = messages.removeValue(forKey: channel) ?? NanoMessageAssembler()
            if let message = assembler.add(parsed) { continuation.yield(.message(channel: channel, message)) }
            messages[channel] = assembler
        case "Blob":
            guard let parsed = try? NanoBlobPacket(packet) else { return }
            // Taken out while in use, for the same reason as inside the assembler.
            var assembler = blobs.removeValue(forKey: channel) ?? NanoBlobAssembler(sizeLimit: settings.blobLimit, directory: settings.blobDirectory)
            switch parsed {
            case .start(let size, let name): continuation.yield(.blobStarted(channel: channel, name: name, size: size))
            case .completion(let kind, let name): continuation.yield(.blobCompletion(channel: channel, kind: kind, name: name))
            default: break
            }
            let refusedBefore = assembler.refused.count
            let finished = assembler.add(parsed)
            if assembler.refused.count > refusedBefore {
                // No room for it, or the file could not be made: the share cannot complete.
                diag("nano", "a blob was turned away: not enough free disk space, or its file could not be written")
                blobs[channel] = assembler
                continuation.yield(.blobRefused(channel: channel))
                return
            }
            if case .data(_, _, _, _, let name, _, _, _) = parsed, finished == nil, let progress = assembler.progress(of: name), progress.total > 0 {
                // Reported per whole percent, not per piece: a large file has tens of thousands.
                let percent = progress.received * 100 / progress.total
                if blobPercent[name] != percent {
                    blobPercent[name] = percent
                    continuation.yield(.blobProgress(channel: channel, name: name, received: progress.received, total: progress.total))
                }
            }
            if let finished { blobPercent[finished.name] = nil }
            if let finished { continuation.yield(.blobReceived(channel: channel, name: finished.name, content: finished.content)) }
            blobs[channel] = assembler
        default:
            break
        }
    }
}

extension Duration {
    /// Whole microseconds, for the protocol's time stamps.
    var microseconds: Int64 {
        let parts = components
        return parts.seconds * 1_000_000 + parts.attoseconds / 1_000_000_000_000
    }
}

extension Duration {
    /// Whole microseconds, for the log.
    var microsecondsText: String { String(Int(Double(components.seconds) * 1_000_000 + Double(components.attoseconds) / 1e12)) }
}
