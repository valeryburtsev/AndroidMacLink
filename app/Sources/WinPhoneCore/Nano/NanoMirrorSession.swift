import Foundation

/// What the pointer has done so far, in the form an input frame carries it: a position, and
/// running totals. A button is a count of its presses and releases (odd while held), the
/// wheels are sums of every turn, so a frame that goes missing loses nothing.
public struct NanoPointerState: Equatable, Sendable {
    /// In the phone's own pixels, as its input offer gave the screen's size.
    public var x: UInt32 = 0
    public var y: UInt32 = 0
    public var leftButton: UInt8 = 0
    /// The phone numbers its buttons left, middle, right; the entry is taken to hold them
    /// in that order. Only the left one is in the recording.
    public var middleButton: UInt8 = 0
    public var rightButton: UInt8 = 0
    public var wheelX: Int32 = 0
    public var wheelY: Int32 = 0

    public init() {}

    public var isPressed: Bool { leftButton % 2 == 1 }

    public mutating func setPressed(_ pressed: Bool) {
        if pressed != isPressed { leftButton &+= 1 }
    }

    public mutating func setRightPressed(_ pressed: Bool) {
        if pressed != (rightButton % 2 == 1) { rightButton &+= 1 }
    }

    public mutating func setMiddlePressed(_ pressed: Bool) {
        if pressed != (middleButton % 2 == 1) { middleButton &+= 1 }
    }

    /// The body of an input frame with one pointer entry, as recorded from Windows: six
    /// bytes saying what the frame holds, then the entry.
    public func frameBody() -> Data {
        var body = Data([0, 1, 0, 0, 0, 0])
        body.append(0)
        body.append(leftButton)
        body.append(middleButton)
        body.append(rightButton)
        body.append(Data(count: 5))
        body.appendLE(x)
        body.appendLE(y)
        body.appendLE(UInt32(bitPattern: wheelX))
        body.appendLE(UInt32(bitPattern: wheelY))
        body.append(Data(count: 8))
        return body
    }
}

/// Mirrors the phone's screen over a Nano connection, playing the part Phone Link plays, as
/// recorded from Windows on 2026-10-09 (`protocol/specs/mirroring.md`):
///
/// 1. on the phone's "launcher" channel this side asks for the `permission` workflow and, on
///    the channel the phone then creates, for the permission to show the screen; the phone
///    asks its user and answers "inProgress", then "accept" or "deny";
/// 2. this side asks for the `remote` workflow; on its "orchestrator" channel it describes
///    its display and asks for the app `yourphone.phonescreen`, which is the whole screen;
/// 3. the phone creates a message, a blob, an input and a video channel for that app; video
///    arrives as H.264 frames, and input frames go back.
///
/// Sound is another workflow (`audio`) and is left out.
public actor NanoMirrorSession {
    public static let screenPackage = "yourphone.phonescreen"

    public enum MirrorError: Error, Equatable {
        /// The phone's user said no, or the phone could not ask.
        case permissionDenied
        /// The phone would not start the screen.
        case refused(String)
        case connectionLost(String)
    }

    public enum Event: Sendable {
        /// The phone is asking its user whether the screen may be shown.
        case waitingForPermission
        case started(NanoVideoFormat)
        case frame(NanoVideoFrame)
        /// The phone's screen is locked or off, or neither.
        case locked(Bool)
        /// The app on show protects its screen (Android blanks it for every capture), or no
        /// longer does.
        case protectedContent(Bool)
        /// The size of the phone's screen in the pixels pointer positions are given in.
        case inputSize(width: Int, height: Int)
        /// The picture is to be shown turned by this many quarter turns against the clock:
        /// an app that lies on its side on a display that stands upright.
        case rotation(Int)
        /// The phone's sound is on its way in this format.
        case soundStarted(NanoAudioFormat)
        /// One encoded frame of sound.
        case sound(Data)
    }

    /// What to show, and whether the phone's sound should come along.
    public struct Options: Sendable {
        /// The app to show by its package name; the default is the whole screen.
        public var packageName = NanoMirrorSession.screenPackage
        /// Also asks for the `audio` workflow: the phone then plays through this computer.
        public var sound = false
        /// How long a phone that is awake may take to send its first picture before the
        /// stream is asked for again.
        public var pictureWait = Duration.seconds(3)
        /// A picture broken this long is asked for afresh; this long, the session starts again.
        public var brokenAskAfter = Duration.seconds(3)
        public var brokenRestartAfter = Duration.seconds(10)
        public init() {}
    }

    /// The display this side says it has, in the words of the recorded request.
    public struct Display: Sendable {
        /// The most frames a second wanted. The phone keeps to 15, or 30 for the whole screen,
        /// unless this is 60 or more (`AppRemoteConfigObserver` in its code); Windows sends 0.
        public var maxFramesPerSecond = 60
        public var width = 2038
        public var height = 1622
        public var dpi = 192
        public var hostWidth = 2048
        public var hostHeight = 1834
        public init() {}
    }

    private let connection: NanoConnection
    private let display: Display
    private let options: Options
    private let onEvent: @Sendable (Event) async -> Void
    private var audio: UInt16?
    private var keyCounts: [UInt8: UInt8] = [:]
    private let audioWorkflow = UUID().uuidString.lowercased()

    private var launcher: UInt16?
    private var permission: UInt16?
    private var orchestrator: UInt16?
    /// The phone's screen is off or locked, as it last said.
    private var asleep = false
    private var wokenOnce = false
    private var lastWake: ContinuousClock.Instant?
    private var input: (channel: UInt16, width: UInt32, height: UInt32)?
    /// The phone's screen as it last gave it, before any turning on this side.
    private var deviceSize: (width: UInt32, height: UInt32)?
    /// Quarter turns the phone asked for the picture to be shown with.
    private var quarterTurns = 0
    private var nextInputFrame: UInt32 = 0
    private var pointer = NanoPointerState()
    private var askedPermission = false, askedRemote = false, launched = false, stopping = false
    private let permissionWorkflow = UUID().uuidString.lowercased(), remoteWorkflow = UUID().uuidString.lowercased()
    private let sessionId = UUID().uuidString.lowercased()

    public init(connection: NanoConnection, display: Display = Display(), options: Options = Options(), onEvent: @escaping @Sendable (Event) async -> Void) {
        self.connection = connection
        self.display = display
        self.options = options
        self.onEvent = onEvent
    }

    /// The size of the phone's screen in the pixels input positions are given in, once known.
    public var inputSize: (width: Int, height: Int)? { input.map { (Int($0.width), Int($0.height)) } }

    private func send(_ channel: UInt16?, _ path: String, _ object: [String: Any]) async throws {
        guard let channel else { return }
        try await connection.sendMessage(channel: channel, path: path, body: try JSONSerialization.data(withJSONObject: object))
    }

    /// Runs until the connection ends. Returns normally when it was stopped from here.
    public func run() async throws {
        for await event in connection.events {
            switch event {
            case .channelCreated(let channel, let description):
                channelSeen = true
                let workflow = description.properties["workflow"], type = description.properties["type"]
                guard description.channelClass == "Messaging" else { continue }
                if workflow == "launcher" { launcher = channel }
                if workflow == "permission" { permission = channel }
                if workflow == "remote", type == "orchestrator" { orchestrator = channel }
                if workflow == "audio" { audio = channel }
            case .messageHandshake(let channel):
                if channel == launcher, !askedPermission {
                    askedPermission = true
                    diag("screen", "launcher channel ready; asking for the permission workflow")
                    try await send(launcher, "/workflow", ["workflow": "permission", "workflowId": permissionWorkflow])
                } else if channel == permission {
                    try await send(permission, "/permission/requestPermission", ["permission": "screenScrape"])
                } else if channel == audio {
                    try await send(audio, "/audio/pcStreamingAllowed", ["isAudioStreamingAllowed": true])
                } else if channel == orchestrator, !launched {
                    launched = true
                    diag("screen", "orchestrator channel ready; asking for the phone's screen")
                    try await send(orchestrator, "/mirror/phone/config", [
                        "maxMainDisplayFps": display.maxFramesPerSecond, "appsFeatureType": 2, "width": display.width, "height": display.height, "dpi": display.dpi,
                        "hostDisplayWidth": display.hostWidth, "hostDisplayHeight": display.hostHeight,
                    ])
                    try await send(orchestrator, "/mirror/phone/alwaysInExpandedLayoutChanged", ["isAlwaysInExpandLayout": false])
                    try await launch(bypassingChecks: options.packageName == NanoMirrorSession.screenPackage)
                }
            case .message(let channel, let message):
                try await handle(message, on: channel)
                // The phone closed what was shown, and has been answered: nothing is left to mirror.
                if closedByPhone {
                    await stop()
                    return
                }
            case .videoStarted(let channel, let format):
                videoChannel = channel
                await onEvent(.started(format))
                watchForTheFirstPicture()
                watchForABrokenPicture()
            case .channelClosed(let channel):
                // The phone took the picture's channel away: what it showed is gone.
                if channel == videoChannel, !stopping {
                    diag("screen", "the phone closed the video channel")
                    await stop()
                    return
                }
            case .videoFrame(_, let frame):
                await onEvent(.frame(frame))
            case .audioStarted(_, let format):
                await onEvent(.soundStarted(format))
            case .audioFrame(_, let data):
                await onEvent(.sound(data))
            case .inputReady(let channel, let width, let height, let next):
                input = (channel, width, height)
                nextInputFrame = next
                // A size the phone has sent by message since is the newer one.
                if deviceSize == nil { deviceSize = (width, height) }
                await sizeChanged()
            case .closed(let reason):
                if stopping { return }
                if !channelSeen {
                    stalledAtStart = true
                    diag("screen", "the phone went silent before opening anything")
                }
                throw MirrorError.connectionLost(reason)
            default:
                break
            }
        }
        if !stopping { throw MirrorError.connectionLost("the connection ended") }
    }

    private var closedByPhone = false
    private var videoChannel: UInt16?

    private func handle(_ message: NanoMessageAssembler.Message, on channel: UInt16) async throws {
        let object = (try? JSONSerialization.jsonObject(with: message.body)) as? [String: Any] ?? [:]
        switch message.path {
        case "/permission/permissionStatus":
            let status = object["status"] as? String ?? ""
            diag("screen", "the phone says the permission is \(status == "accept" || status == "deny" || status == "inProgress" ? status : "something else")")
            if status == "inProgress" {
                await onEvent(.waitingForPermission)
            } else if status == "accept", !askedRemote {
                askedRemote = true
                if options.sound {
                    // As Windows goes about sound: it asks whether the phone may hand its sound
                    // over, has the phone ask its user where that is needed, then starts the workflow.
                    try await send(permission, "/permission/checkPermission", ["permission": "oemAudio", "transactionId": UUID().uuidString.lowercased()])
                    try await send(permission, "/permission/checkPermission", ["permission": "audio", "transactionId": UUID().uuidString.lowercased()])
                    try await send(permission, "/permission/showPermission", ["permission": "audio", "transactionId": UUID().uuidString.lowercased()])
                    try await send(launcher, "/workflow", ["workflow": "audio", "workflowId": audioWorkflow])
                }
                try await send(launcher, "/workflow", ["workflow": "remote", "workflowId": remoteWorkflow])
            } else if status == "deny" {
                throw MirrorError.permissionDenied
            }
        case "/mirror/phone/appLaunchResult":
            let result = object["result"] as? String ?? ""
            // One of the phone's own words for the outcome, never anything of the user's.
            let known = ["success", "appUnavailable", "appNotExist", "trueTouchWarning", "notSupported", "overheated", "powerSavingMode", "duplicateLaunch", "unknownError"]
            diag("screen", "the phone's answer to opening \(options.packageName == NanoMirrorSession.screenPackage ? "its screen" : "the app"): \(known.contains(result) ? result : "something else")")
            if result == "trueTouchWarning", !relaunched {
                // The app may want a real touch screen. Phone Link warns and opens it all the same
                // when told to; here it is opened at once, with the phone's checks set aside.
                relaunched = true
                try await launch(bypassingChecks: true)
            } else if result != "success" {
                throw MirrorError.refused(result)
            }
        case "/mirror/phone/secureContentChanged":
            let protected = object["isSecureContent"] as? Bool ?? false
            diag("screen", protected ? "the app on show protects its screen" : "the app on show no longer protects its screen")
            await onEvent(.protectedContent(protected))
        case "/mirror/phone/setLockedState":
            let locked = object["isLocked"] as? Bool ?? false, on = object["isScreenOn"] as? Bool ?? true
            let wasAsleep = asleep
            asleep = locked || !on
            // A phone that was locked when the session began sends no picture, and none after
            // it is unlocked either (seen on 2026-10-10, three times).
            if wasAsleep, !asleep, await connection.videoFrameCount == 0 { recoverPicture() }
            diag("screen", "the phone says: \(locked ? "locked" : "unlocked"), screen \(on ? "on" : "off")\(object["isSecureLocked"] as? Bool == true ? ", with a secret" : "")")
            await onEvent(.locked(asleep))
            // As Phone Link does when its window opens: light the phone up and bring its
            // unlock prompt forward, once, without being asked.
            if asleep, !wokenOnce {
                wokenOnce = true
                await wake()
            }
        case "/mirror/phone/disconnecting":
            // The app was closed on the phone, or by its own Back at its first page: the
            // phone says so and waits for the answer before it lets go.
            let reason = object["reason"] as? String ?? ""
            let known = ["none", "unknown", "userClosed", "appIsClosed", "maxApps", "appIsMovedToAnotherDisplay", "closeWindow", "closeAll", "heat", "closedByBack", "powerSavingMode", "error2"]
            diag("screen", "the phone is closing what it showed: \(known.contains(reason) ? reason : "another reason")")
            try await send(channel, "/mirror/phone/disconnectingResult", ["transactionId": object["transactionId"] as? String ?? ""])
            closedByPhone = true
        case "/mirror/phone/deviceResolutionChanged":
            // The phone was turned, or its screen changed otherwise: positions are counted in
            // the new size from here on. The picture's own new size comes with the video.
            guard let width = object["width"] as? Int, let height = object["height"] as? Int, (1...32768).contains(width), (1...32768).contains(height) else { break }
            let changed = deviceSize.map { $0.width != UInt32(width) || $0.height != UInt32(height) } ?? true
            deviceSize = (UInt32(width), UInt32(height))
            if changed {
                diag("screen", "the phone's screen is now \(width) x \(height)")
                await sizeChanged()
            }
        case "/mirror/phone/orientationChanged":
            // An app turned on its side while the picture the phone sends stays as it was:
            // this side turns it, as Phone Link does (0 upright, 1 to 3 quarter turns).
            let turns = object["orientationInfo"] as? Int ?? 0
            guard (0...3).contains(turns), turns != quarterTurns else { break }
            quarterTurns = turns
            diag("screen", "the phone asks for the picture turned by \(turns) quarter turns")
            await onEvent(.rotation(turns))
            await sizeChanged()
        case "/mirror/phone/requestBlackScreenState":
            // Windows answers "on": the phone may darken its own display while it is shown here.
            try await send(orchestrator, "/mirror/phone/blackScreen", ["blackScreenToggleState": true])
        default:
            break
        }
    }

    private var relaunched = false

    /// The size positions are counted in: the phone's screen, lying on its side while the
    /// picture is turned by one or three quarters.
    private func sizeChanged() async {
        guard let deviceSize else { return }
        let turned = quarterTurns % 2 == 1
        let width = turned ? deviceSize.height : deviceSize.width, height = turned ? deviceSize.width : deviceSize.height
        guard let current = input else { return }
        guard !inputAnnounced || current.width != width || current.height != height else { return }
        inputAnnounced = true
        input = (current.channel, width, height)
        // A position from the old shape may lie outside the new one.
        pointer.x = min(pointer.x, width - 1)
        pointer.y = min(pointer.y, height - 1)
        await onEvent(.inputSize(width: Int(width), height: Int(height)))
    }

    private var inputAnnounced = false

    /// Asks the phone to open the whole screen or one app. The flags, from the phone's own
    /// reading of them (`AppLaunchMessagePayload`): 1 sets its checks aside (is the app
    /// installed, can it be shown on another display), 2 says "this is the whole screen".
    private func launch(bypassingChecks: Bool) async throws {
        let wholeScreen = options.packageName == NanoMirrorSession.screenPackage
        try await send(orchestrator, "/mirror/phone/launchApp", [
            "packageName": options.packageName, "sessionId": sessionId, "targetScreenLayout": 0,
            "flags": (bypassingChecks ? 1 : 0) | (wholeScreen ? 2 : 0),
        ])
    }

    /// The phone's navigation where it is done with swipes: the phone took no key for these
    /// when tried, and Phone Link itself leaves them to the pointer.
    public enum Gesture: Sendable {
        /// A quick swipe up from the bottom edge.
        case home
        /// The same swipe, held before letting go.
        case recents
    }

    /// Set when the session ended itself because only a new one will bring a picture.
    public private(set) var restartWanted = false
    /// The connection ended before the phone opened anything on it: its Link to Windows
    /// stalled between the handshake and the first channel (seen 2026-10-27). Worth one more go.
    public private(set) var stalledAtStart = false
    private var channelSeen = false
    private var recovery: Task<Void, Never>?

    /// The phone is unlocked and there has been no picture yet: ask for the stream once more,
    /// and if that brings nothing, end the session so that it is started afresh, which is
    /// known to work with an unlocked phone.
    private func recoverPicture() {
        guard recovery == nil, !stopping else { return }
        recovery = Task { [weak self] in
            await self?.askForThePictureAgain()
            try? await Task.sleep(for: .milliseconds(1500))
            await self?.restartIfStillDark()
        }
    }

    private var firstPictureWatch: Task<Void, Never>?
    private var brokenPictureWatch: Task<Void, Never>?

    /// A picture that broke and stays broken (frames lost on a poor network, and the whole
    /// frame that would mend it lost too) is asked for afresh, as a new stream, and if that
    /// brings nothing the session is started again. Before, it stayed frozen (2026-10-16).
    private func watchForABrokenPicture() {
        guard brokenPictureWatch == nil else { return }
        brokenPictureWatch = Task { [weak self, connection, ask = options.brokenAskAfter, restart = options.brokenRestartAfter] in
            var askedAt: Duration?
            while !Task.isCancelled {
                try? await Task.sleep(for: min(.seconds(1), ask / 3))
                guard let self, await !self.stopping else { return }
                guard let broken = await connection.videoBrokenDuration() else { askedAt = nil; continue }
                if broken > restart {
                    diag("screen", "the picture has been broken for \(Int(broken.components.seconds)) s; starting the session again")
                    await self.restartForAPicture()
                    return
                }
                if broken > ask, askedAt.map({ broken - $0 > ask }) ?? true, let channel = await self.videoChannel {
                    askedAt = broken
                    diag("screen", "the picture has been broken for \(Int(broken.components.seconds)) s; asking for the stream afresh")
                    try? await connection.restartVideo(channel: channel)
                }
            }
        }
    }

    private func restartForAPicture() async {
        restartWanted = true
        await stop()
    }

    /// A session started right after the phone was unlocked may get its channels and no
    /// picture, with the phone awake all the while (seen on 2026-10-10, 20:07: twelve seconds
    /// of nothing until it was stopped by hand, and a fresh session then worked). So an awake
    /// phone that stays dark is treated like one that was just unlocked.
    private func watchForTheFirstPicture() {
        guard firstPictureWatch == nil else { return }
        firstPictureWatch = Task { [weak self, wait = options.pictureWait] in
            try? await Task.sleep(for: wait)
            await self?.recoverIfDarkAndAwake()
        }
    }

    private func recoverIfDarkAndAwake() async {
        guard !stopping, !asleep, await connection.videoFrameCount == 0 else { return }
        diag("screen", "awake and no picture after the stream was started")
        recoverPicture()
    }

    private func askForThePictureAgain() async {
        guard let videoChannel else { return }
        diag("screen", "unlocked without a picture so far; asking for the stream again")
        try? await connection.restartVideo(channel: videoChannel)
    }

    private func restartIfStillDark() async {
        recovery = nil
        guard !stopping, !asleep, await connection.videoFrameCount == 0 else { return }
        diag("screen", "still no picture; starting the session again")
        restartWanted = true
        await stop()
    }

    /// Asks the phone to switch its screen on and, if it is locked, to bring its unlock prompt
    /// forward. A lock with a PIN, pattern or fingerprint still wants that from the user: on
    /// the phone, or typed and drawn here once the prompt shows in the picture. Not more often
    /// than every two seconds.
    public func wake() async {
        let now = ContinuousClock.now
        if let last = lastWake, now - last < .seconds(2) { return }
        lastWake = now
        diag("screen", "asking the phone to wake")
        try? await send(orchestrator, "/mirror/phone/wakeScreen", [:])
    }

    /// Draws a navigation swipe with the pointer, as a hand would on the mirrored screen.
    public func gesture(_ gesture: Gesture) async {
        guard let input, !pointer.isPressed else { return }
        let x = Int(input.width) / 2, bottom = Int(input.height) - 2
        let top = Int(Double(input.height) * (gesture == .home ? 0.45 : 0.62))
        await self.pointer(x: x, y: bottom, pressed: false)
        await self.pointer(x: x, y: bottom, pressed: true)
        let steps = gesture == .home ? 8 : 14
        for step in 1...steps {
            try? await Task.sleep(for: .milliseconds(gesture == .home ? 12 : 22))
            await self.pointer(x: x, y: bottom - (bottom - top) * step / steps, pressed: true)
        }
        if gesture == .recents { try? await Task.sleep(for: .milliseconds(550)) }
        await self.pointer(x: x, y: top, pressed: false)
    }

    /// Presses or releases a key: a USB keyboard usage number, or one of `NanoKey`.
    public func key(_ usage: UInt8, pressed: Bool) async {
        // A key or a click on a sleeping phone is first of all a wish to wake it.
        if pressed, asleep { await wake() }
        guard let input else { return }
        let count = keyCounts[usage, default: 0]
        guard pressed != (count % 2 == 1) else { return }
        keyCounts[usage] = count &+ 1
        let frame = nextInputFrame
        nextInputFrame &+= 1
        try? await connection.sendInputFrame(channel: input.channel, frameId: frame, body: NanoKey.frameBody(key: usage, count: count &+ 1))
    }

    /// Moves the pointer, presses or releases its buttons, and turns the wheel. Positions
    /// are in the phone's own pixels and kept inside its screen.
    public func pointer(x: Int, y: Int, pressed: Bool, rightPressed: Bool = false, middlePressed: Bool = false, wheelX: Int = 0, wheelY: Int = 0) async {
        if pressed, !pointer.isPressed, asleep { await wake() }
        guard let input else { return }
        pointer.x = UInt32(max(0, min(Int(input.width) - 1, x)))
        pointer.y = UInt32(max(0, min(Int(input.height) - 1, y)))
        pointer.setPressed(pressed)
        pointer.setRightPressed(rightPressed)
        pointer.setMiddlePressed(middlePressed)
        pointer.wheelX &+= Int32(clamping: wheelX)
        pointer.wheelY &+= Int32(clamping: wheelY)
        let frame = nextInputFrame
        nextInputFrame &+= 1
        try? await connection.sendInputFrame(channel: input.channel, frameId: frame, body: pointer.frameBody())
    }

    /// Ends the mirroring as Windows does: both workflows are told to stop, then the
    /// connection goes.
    public func stop() async {
        guard !stopping else { return }
        stopping = true
        try? await send(launcher, "/stopWorkflow", ["workflow": "permission", "workflowId": permissionWorkflow])
        if askedRemote, options.sound { try? await send(launcher, "/stopWorkflow", ["workflow": "audio", "workflowId": audioWorkflow]) }
        if askedRemote { try? await send(launcher, "/stopWorkflow", ["workflow": "remote", "workflowId": remoteWorkflow]) }
        await connection.flush(timeout: .seconds(1))
        await connection.close()
    }
}
