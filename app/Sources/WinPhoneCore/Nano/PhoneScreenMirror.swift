import Foundation

/// Shows the phone's screen: asks the phone, on the Phone Link session, to listen for a
/// direct connection, then runs a mirroring session over it. One at a time.
public actor PhoneScreenMirror {
    public enum Update: Equatable, Sendable {
        /// The connection to the phone is being set up.
        case connecting
        /// The phone is asking its user whether the screen may be shown.
        case waitingForPermission
        /// Video is on its way in this format.
        case started(NanoVideoFormat)
        /// The size of the phone's screen in the pixels pointer positions are given in.
        case inputSize(width: Int, height: Int)
        /// The picture is to be shown turned by this many quarter turns against the clock.
        case rotation(Int)
        case frame(NanoVideoFrame)
        /// The phone's sound comes in this format, then frame by frame.
        case soundStarted(NanoAudioFormat)
        case sound(Data)
        case locked(Bool)
        /// The app on show protects its screen: the picture is blank on purpose.
        case protectedContent(Bool)
        /// Mirroring ended because it was stopped here.
        case ended
        case failed(String)
    }

    private let connector: NanoConnector
    private nonisolated let continuation = Broadcast<Update>()
    /// What happens, for whoever listens from now on: each read of this is a stream of its
    /// own, so that a connection rebuilt after a drop can listen again.
    public nonisolated var updates: AsyncStream<Update> { continuation.stream() }
    private var session: NanoMirrorSession?
    private var options = NanoMirrorSession.Options()
    private var frameSink: (@Sendable (NanoVideoFrame) -> Void)?
    private var running = false, stopRequested = false
    /// The breath between a session that ended itself and the one that replaces it.
    private var restartPause = Duration.milliseconds(1200)
    public func setRestartPause(_ pause: Duration) { restartPause = pause }

    /// - Parameter relayServers: where the helping servers for a connection over the internet
    ///   come from; without it only the same network is tried.
    public init(relayServers: (@Sendable () async -> NanoRelayServers?)? = nil,
                makeTransport: @escaping @Sendable (_ host: String, _ port: UInt16) async throws -> NanoDatagramTransport = { host, port in
        try NanoSocketTransport(host: host, port: port)
    }) {
        connector = NanoConnector(makeTransport: makeTransport, relayServers: relayServers)
    }

    public var isRunning: Bool { running }

    /// Mirrors until stopped or until the connection ends. The outcome arrives on `updates`.
    /// - Parameter frameSink: where frames of video go, straight from the connection; without
    ///   it they arrive on `updates` with everything else.
    public func start(messenger: PeerMessenger, sender: AppSender, options: NanoMirrorSession.Options = .init(),
                      frameSink: (@Sendable (NanoVideoFrame) -> Void)? = nil) async {
        guard !running else { return }
        self.options = options
        self.frameSink = frameSink
        running = true
        stopRequested = false
        defer { running = false; session = nil }
        continuation.send(.connecting)
        diag("screen", "asking the phone to listen for a connection")
        do {
            var settings = NanoConnection.Settings()
            settings.videoSink = frameSink
            var restarts = 0, stallRetried = false
            while true {
                let opened = try await connector.open(messenger: messenger, sender: sender, workflow: "permission", transferId: UUID().uuidString.lowercased(),
                                                      settings: settings, tag: "screen")
                let began = ContinuousClock.now
                // A session that ended itself for want of a picture is started afresh, a
                // few times at most; one that showed the screen for a while counts afresh.
                // One whose phone stalled before opening anything gets one more go.
                let outcome = try await mirror(over: opened.connection, mayRetryStall: !stallRetried)
                if outcome == .stalled { stallRetried = true }
                let wantsAgain = outcome != .ended
                if ContinuousClock.now - began > .seconds(30) { restarts = 0 }
                guard wantsAgain, restarts < 3, !stopRequested else { break }
                restarts += 1
                diag("screen", "starting again, try \(restarts + 1)")
                continuation.send(.connecting)
                // The phone takes a moment to put the old session away. A new one begun at
                // once got channels and no picture; one begun a second later, by hand, was fine.
                try? await Task.sleep(for: restartPause)
                if stopRequested { break }
            }
            continuation.send(.ended)
            diag("screen", "mirroring ended")
        } catch {
            if stopRequested {
                continuation.send(.ended)
                diag("screen", "mirroring stopped here")
            } else {
                diag("screen", "mirroring failed: \(error)")
                continuation.send(.failed(PhoneScreenMirror.describe(error)))
            }
        }
    }

    private enum Outcome { case ended, restartWanted, stalled }

    /// - Returns: Whether the session asked to be started again, or stalled at its start and
    ///   may be, rather than failing.
    private func mirror(over connection: NanoConnection, mayRetryStall: Bool) async throws -> Outcome {
        let session = NanoMirrorSession(connection: connection, options: options) { [continuation] event in
            switch event {
            case .waitingForPermission: continuation.send(.waitingForPermission)
            case .started(let format): continuation.send(.started(format))
            case .frame(let frame): continuation.send(.frame(frame))
            case .locked(let locked): continuation.send(.locked(locked))
            case .protectedContent(let protected): continuation.send(.protectedContent(protected))
            case .inputSize(let width, let height): continuation.send(.inputSize(width: width, height: height))
            case .rotation(let turns): continuation.send(.rotation(turns))
            case .soundStarted(let format): continuation.send(.soundStarted(format))
            case .sound(let data): continuation.send(.sound(data))
            }
        }
        self.session = session
        if stopRequested { await session.stop() }
        do {
            try await session.run()
        } catch {
            await connection.close()
            if mayRetryStall, !stopRequested, await session.stalledAtStart {
                diag("screen", "trying once more")
                return .stalled
            }
            throw error
        }
        await connection.close()
        return await session.restartWanted ? .restartWanted : .ended
    }

    public func stop() async {
        guard running else { return }
        stopRequested = true
        await session?.stop()
    }

    /// The size of the phone's screen for pointer positions, once the phone has said it.
    public func inputSize() async -> (width: Int, height: Int)? {
        await session?.inputSize
    }

    public func pointer(x: Int, y: Int, pressed: Bool, rightPressed: Bool = false, middlePressed: Bool = false, wheelX: Int = 0, wheelY: Int = 0) async {
        await session?.pointer(x: x, y: y, pressed: pressed, rightPressed: rightPressed, middlePressed: middlePressed, wheelX: wheelX, wheelY: wheelY)
    }

    public func gesture(_ gesture: NanoMirrorSession.Gesture) async {
        await session?.gesture(gesture)
    }

    /// Asks the phone to switch its screen on and show its unlock prompt.
    public func wake() async {
        await session?.wake()
    }

    public func key(_ usage: UInt8, pressed: Bool) async {
        await session?.key(usage, pressed: pressed)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case NanoMirrorSession.MirrorError.permissionDenied: return "Showing the screen was not allowed on the phone."
        case NanoMirrorSession.MirrorError.refused("appNotExist"): return "That app is no longer on the phone."
        case NanoMirrorSession.MirrorError.refused("notSupported"), NanoMirrorSession.MirrorError.refused("appUnavailable"),
             NanoMirrorSession.MirrorError.refused("trueTouchWarning"):
            return "The phone cannot show that app on its own. Open the whole phone screen instead."
        case NanoMirrorSession.MirrorError.refused("overheated"): return "The phone is too warm to show apps right now."
        case NanoMirrorSession.MirrorError.refused("powerSavingMode"): return "The phone does not show apps while it is in power saving mode."
        case NanoMirrorSession.MirrorError.refused("duplicateLaunch"): return "That app is already open here."
        case NanoMirrorSession.MirrorError.refused: return "The phone could not show its screen."
        case NanoMirrorSession.MirrorError.connectionLost: return "The connection to the phone was lost."
        case NanoSocketTransport.SocketError.blocked: return PhoneFileReceiver.blockedExplanation
        case NanoConnection.ConnectionError.noAnswer: return "The phone could not be reached, neither on this network nor over the internet."
        case NanoSignalling.SignallingError.refused: return "The phone refused the connection."
        case PeerMessenger.MessagingError.timedOut: return "The phone did not answer the request for a connection."
        default: return "The phone's screen could not be shown."
        }
    }
}
