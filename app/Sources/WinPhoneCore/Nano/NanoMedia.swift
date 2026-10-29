import Foundation

// The channels screen mirroring adds to a Nano connection, as recorded from Windows mirroring
// the phone on 2026-10-09 (`protocol/specs/mirroring.md`): the phone's screen as H.264 video
// on a channel of class `Video`, and the pointer and keys going back on one of class `Input`.
// Both speak the "streamer" protocol of Microsoft's Nano library; everything is little-endian.

/// One picture format a video stream can have.
public struct NanoVideoFormat: Equatable, Sendable {
    public var framesPerSecond: UInt32
    public var width: UInt32
    public var height: UInt32
    /// 0 is H.264; nothing else was seen.
    public var codec: UInt32

    public init(framesPerSecond: UInt32, width: UInt32, height: UInt32, codec: UInt32 = 0) {
        self.framesPerSecond = framesPerSecond
        self.width = width
        self.height = height
        self.codec = codec
    }

    init(_ reader: inout ByteReader) throws {
        framesPerSecond = try reader.u32LE()
        width = try reader.u32LE()
        height = try reader.u32LE()
        codec = try reader.u32LE()
    }

    func append(to data: inout Data) {
        data.appendLE(framesPerSecond)
        data.appendLE(width)
        data.appendLE(height)
        data.appendLE(codec)
    }
}

/// A packet of a `Video` channel. Each starts with its kind, the number 1, and the length of
/// what follows.
public enum NanoVideoPacket: Equatable, Sendable {
    /// From the sender of the video, first: the protocol version (6), the picture it offers,
    /// a clock reading in milliseconds, and the formats it can send.
    case serverHandshake(version: UInt32, width: UInt32, height: UInt32, framesPerSecond: UInt32, referenceTime: UInt64, formats: [NanoVideoFormat])
    /// The viewer's answer: the number its frame reports start at, and the format it takes.
    case clientHandshake(initialFrameId: UInt32, format: NanoVideoFormat)
    /// Requests and reports; what follows the flags depends on them.
    case control(flags: UInt32, body: Data)
    /// One piece of one frame. `flags` 6 marks a frame that can be decoded on its own, 4 one
    /// that builds on those before it. `timestamp` counts microseconds.
    case data(flags: UInt32, frameId: UInt32, timestamp: Int64, reserved: UInt32, totalSize: UInt32, packetCount: UInt32, offset: UInt32,
              metadata: Data, data: Data)

    /// Flags of a control packet from the viewer, as in the recording.
    public enum Control {
        /// Followed by a frame number and the viewer's clock: that frame was shown.
        public static let lastDisplayedFrame: UInt32 = 0x01
        /// Followed by the first and last number of frames that never arrived whole.
        public static let lostFrames: UInt32 = 0x02
        public static let startStream: UInt32 = 0x10
        public static let requestKeyframe: UInt32 = 0x20
        /// Goes with `lastDisplayedFrame` in every report of the recording.
        public static let frameRendered: UInt32 = 0x80
    }

    public static let keyframeFlags: UInt32 = 6

    public init(_ packet: Data) throws {
        var reader = ByteReader(packet)
        do {
            let kind = try reader.u32LE()
            _ = try reader.u32LE()
            let length = Int(try reader.u32LE())
            guard length <= reader.remaining else { throw NanoError.truncated }
            switch kind {
            case 1:
                let version = try reader.u32LE(), width = try reader.u32LE(), height = try reader.u32LE(), rate = try reader.u32LE()
                let time = try reader.u64LE()
                let count = try reader.u32LE()
                guard count <= 64 else { throw NanoError.malformed("video formats") }
                var formats: [NanoVideoFormat] = []
                for _ in 0..<count { formats.append(try NanoVideoFormat(&reader)) }
                self = .serverHandshake(version: version, width: width, height: height, framesPerSecond: rate, referenceTime: time, formats: formats)
            case 2:
                self = .clientHandshake(initialFrameId: try reader.u32LE(), format: try NanoVideoFormat(&reader))
            case 3:
                let flags = try reader.u32LE()
                self = .control(flags: flags, body: try reader.bytes(max(0, length - 4)))
            case 4:
                let flags = try reader.u32LE(), frame = try reader.u32LE()
                let timestamp = Int64(bitPattern: try reader.u64LE())
                let reserved = try reader.u32LE(), total = try reader.u32LE(), count = try reader.u32LE(), offset = try reader.u32LE()
                let metadata = try reader.bytes(Int(try reader.u32LE()))
                let data = try reader.bytes(Int(try reader.u32LE()))
                self = .data(flags: flags, frameId: frame, timestamp: timestamp, reserved: reserved, totalSize: total, packetCount: count, offset: offset,
                             metadata: metadata, data: data)
            default:
                throw NanoError.malformed("video packet kind \(kind)")
            }
        } catch let error as NanoError {
            throw error
        } catch {
            throw NanoError.truncated
        }
    }

    public func encoded() -> Data {
        var body = Data()
        let kind: UInt32
        switch self {
        case .serverHandshake(let version, let width, let height, let rate, let time, let formats):
            kind = 1
            body.appendLE(version); body.appendLE(width); body.appendLE(height); body.appendLE(rate)
            body.appendLE(time)
            body.appendLE(UInt32(formats.count))
            for format in formats { format.append(to: &body) }
        case .clientHandshake(let frame, let format):
            kind = 2
            body.appendLE(frame)
            format.append(to: &body)
        case .control(let flags, let rest):
            kind = 3
            body.appendLE(flags)
            body.append(rest)
        case .data(let flags, let frame, let timestamp, let reserved, let total, let count, let offset, let metadata, let data):
            kind = 4
            body.appendLE(flags); body.appendLE(frame)
            body.appendLE(UInt64(bitPattern: timestamp))
            body.appendLE(reserved); body.appendLE(total); body.appendLE(count); body.appendLE(offset)
            body.appendLE(UInt32(metadata.count)); body.append(metadata)
            body.appendLE(UInt32(data.count)); body.append(data)
        }
        var packet = Data()
        packet.appendLE(kind)
        packet.appendLE(UInt32(1))
        packet.appendLE(UInt32(body.count))
        packet.append(body)
        return packet
    }

    /// The viewer's "start, and begin with a whole frame".
    public static func start() -> NanoVideoPacket {
        .control(flags: Control.startStream | Control.requestKeyframe, body: Data())
    }

    /// The viewer's report that a frame was shown, with its own clock in microseconds.
    public static func displayed(frameId: UInt32, at time: Int64) -> NanoVideoPacket {
        var body = Data()
        body.appendLE(frameId)
        body.appendLE(UInt64(bitPattern: time))
        return .control(flags: Control.lastDisplayedFrame | Control.frameRendered, body: body)
    }
}

/// A whole frame of video, put together from its pieces.
public struct NanoVideoFrame: Equatable, Sendable {
    public var id: UInt32
    public var timestamp: Int64
    public var isKeyframe: Bool
    /// The encoded picture: H.264 with start codes.
    public var data: Data
}

/// Puts frames together from the data packets of a video channel. Pieces may come in any
/// order; a frame is handed over once all of it is there, and what is older is then dropped.
public struct NanoVideoAssembler: Sendable {
    /// The largest frame accepted.
    public var sizeLimit: UInt32

    private var frames: [UInt32: (flags: UInt32, timestamp: Int64, data: Data, covered: IndexSet)] = [:]
    public private(set) var lastCompleted: UInt32?

    public init(sizeLimit: UInt32 = 16 * 1024 * 1024) {
        self.sizeLimit = sizeLimit
    }

    /// Takes a packet and returns its frame as soon as that is whole, giving up on any frame
    /// before it (for offline reading; the live picture uses `take`).
    public mutating func add(_ packet: NanoVideoPacket) -> NanoVideoFrame? {
        guard let frame = assemble(packet) else { return nil }
        lastCompleted = frame.id
        frames = frames.filter { Int32(bitPattern: $0.key &- frame.id) > 0 }
        return frame
    }

    /// Puts the piece in its frame; the frame when it is whole. Frames before it stay.
    private mutating func assemble(_ packet: NanoVideoPacket) -> NanoVideoFrame? {
        guard case .data(let flags, let id, let timestamp, _, let total, _, let offset, _, let data) = packet,
              total > 0, total <= sizeLimit, UInt64(offset) + UInt64(data.count) <= UInt64(total) else { return nil }
        // A frame from before the last one handed over is too late to be of use.
        if let last = lastCompleted, Int32(bitPattern: id &- last) <= 0 { return nil }
        var frame = frames.removeValue(forKey: id) ?? (flags, timestamp, Data(count: Int(total)), IndexSet())
        guard frame.data.count == Int(total) else { return nil }
        frame.data.replaceSubrange(Int(offset)..<(Int(offset) + data.count), with: data)
        frame.covered.insert(integersIn: Int(offset)..<(Int(offset) + data.count))
        guard frame.covered.count == Int(total) else {
            frames[id] = frame
            // Never more than a few frames in the making: older ones lost their chance.
            if frames.count > 8, let oldest = frames.keys.min(by: { Int32(bitPattern: $0 &- $1) < 0 }) { frames[oldest] = nil }
            return nil
        }
        return NanoVideoFrame(id: id, timestamp: frame.timestamp, isKeyframe: frame.flags == NanoVideoPacket.keyframeFlags, data: frame.data)
    }

    // MARK: In order, with a moment's patience

    /// Whole frames that came before an earlier one was whole, held for it a moment.
    private var held: [UInt32: NanoVideoFrame] = [:]
    /// Since when frames are held.
    public private(set) var holdingSince: ContinuousClock.Instant?
    /// How long frames behind a missing one wait for it. None by default: the phone does not
    /// send lost video again (2026-10-16: 60 ms of waiting mended none of 11 gaps), so a wait
    /// only delays the picture. Kept for a sender that does.
    public var reorderWait = Duration.zero
    public var releaseDeadline: ContinuousClock.Instant? { holdingSince.map { $0 + reorderWait } }

    /// Takes a packet and returns the frames ready to be shown, in order. A frame whose
    /// predecessor is not whole yet waits for it until `releaseDeadline`; a whole picture
    /// never waits, as nothing before it is needed.
    public mutating func take(_ packet: NanoVideoPacket, at now: ContinuousClock.Instant) -> [NanoVideoFrame] {
        guard let frame = assemble(packet), held[frame.id] == nil else { return released(ifDueAt: now) }
        if let last = delivered, !frame.isKeyframe, frame.id != last &+ 1 {
            held[frame.id] = frame
            if holdingSince == nil { holdingSince = now }
            return released(ifDueAt: now)
        }
        return deliver(frame)
    }

    /// The frames held past their time, in order, missing ones left out.
    public mutating func release(at now: ContinuousClock.Instant) -> [NanoVideoFrame] {
        guard !held.isEmpty else { holdingSince = nil; return [] }
        let ordered = held.values.sorted { Int32(bitPattern: $0.id &- $1.id) < 0 }
        held = [:]
        holdingSince = nil
        if let newest = ordered.last {
            delivered = newest.id
            lastCompleted = newest.id
            frames = frames.filter { Int32(bitPattern: $0.key &- newest.id) > 0 }
        }
        return ordered
    }

    /// How often a missing frame came in time for the ones waiting behind it.
    public private(set) var mended = 0

    /// The last frame handed over by `take` or `release`.
    private var delivered: UInt32?

    private mutating func released(ifDueAt now: ContinuousClock.Instant) -> [NanoVideoFrame] {
        guard let due = releaseDeadline, now >= due || held.count > 8 else { return [] }
        return release(at: now)
    }

    private mutating func deliver(_ frame: NanoVideoFrame) -> [NanoVideoFrame] {
        var out = [frame]
        delivered = frame.id
        // Held frames that were behind this one are of no use now; those that follow it go too.
        held = held.filter { Int32(bitPattern: $0.key &- frame.id) > 0 }
        while let next = held.removeValue(forKey: delivered! &+ 1) {
            out.append(next)
            delivered = next.id
        }
        if out.count > 1 { mended += 1 }
        lastCompleted = delivered
        frames = frames.filter { Int32(bitPattern: $0.key &- delivered!) > 0 }
        if held.isEmpty { holdingSince = nil }
        return out
    }
}

/// A packet of an `Input` channel. Each starts with its kind and the length of what follows.
public enum NanoInputPacket: Equatable, Sendable {
    /// From the phone, first: the size of its screen in its own pixels, how many touches it
    /// takes at once, and the number the first input frame must carry.
    case serverHandshake(version: UInt32, capabilities: UInt32, width: UInt32, height: UInt32, maxTouches: UInt32, firstFrameId: UInt32)
    /// The answer: the same numbers back, and a clock reading in milliseconds.
    case clientHandshake(version: UInt32, capabilities: UInt32, maxTouches: UInt32, referenceTime: UInt64)
    /// The phone has taken the input frame with this number.
    case frameAck(frameId: UInt32)
    /// One input frame: its number, the sender's clock in microseconds, and what happened.
    case frame(frameId: UInt32, timestamp: Int64, body: Data)

    public init(_ packet: Data) throws {
        var reader = ByteReader(packet)
        do {
            let kind = try reader.u32LE()
            let length = Int(try reader.u32LE())
            guard length <= reader.remaining else { throw NanoError.truncated }
            switch kind {
            case 5:
                self = .serverHandshake(version: try reader.u32LE(), capabilities: try reader.u32LE(), width: try reader.u32LE(), height: try reader.u32LE(),
                                        maxTouches: try reader.u32LE(), firstFrameId: try reader.u32LE())
            case 6:
                self = .clientHandshake(version: try reader.u32LE(), capabilities: try reader.u32LE(), maxTouches: try reader.u32LE(), referenceTime: try reader.u64LE())
            case 3:
                self = .frameAck(frameId: try reader.u32LE())
            case 7:
                let frame = try reader.u32LE()
                let timestamp = Int64(bitPattern: try reader.u64LE())
                self = .frame(frameId: frame, timestamp: timestamp, body: try reader.bytes(max(0, length - 12)))
            default:
                throw NanoError.malformed("input packet kind \(kind)")
            }
        } catch let error as NanoError {
            throw error
        } catch {
            throw NanoError.truncated
        }
    }

    public func encoded() -> Data {
        var body = Data()
        let kind: UInt32
        switch self {
        case .serverHandshake(let version, let capabilities, let width, let height, let touches, let first):
            kind = 5
            body.appendLE(version); body.appendLE(capabilities); body.appendLE(width); body.appendLE(height); body.appendLE(touches); body.appendLE(first)
        case .clientHandshake(let version, let capabilities, let touches, let time):
            kind = 6
            body.appendLE(version); body.appendLE(capabilities); body.appendLE(touches); body.appendLE(time)
        case .frameAck(let frame):
            kind = 3
            body.appendLE(frame)
        case .frame(let frame, let timestamp, let rest):
            kind = 7
            body.appendLE(frame)
            body.appendLE(UInt64(bitPattern: timestamp))
            body.append(rest)
        }
        var packet = Data()
        packet.appendLE(kind)
        packet.appendLE(UInt32(body.count))
        packet.append(body)
        return packet
    }
}

/// One sound format an audio stream can have.
public struct NanoAudioFormat: Equatable, Sendable {
    public var channels: UInt32
    public var sampleRate: UInt32
    /// 0 is Opus; nothing else was seen.
    public var codec: UInt32

    public init(channels: UInt32, sampleRate: UInt32, codec: UInt32 = 0) {
        self.channels = channels
        self.sampleRate = sampleRate
        self.codec = codec
    }
}

/// A packet of an `Audio` channel. Unlike video, its kind is not inside it: it travels as
/// the datagram's payload type, 35 plus the kind.
public enum NanoAudioPacket: Equatable, Sendable {
    /// From the phone, first: the protocol version (7), a clock reading in milliseconds, and
    /// the formats it can send.
    case serverHandshake(version: UInt32, referenceTime: UInt64, formats: [NanoAudioFormat])
    /// The listener's answer: the number its frames start at, and the format it takes.
    case clientHandshake(initialFrameId: UInt32, format: NanoAudioFormat)
    /// 0x10 starts the stream, 0x08 stops it.
    case control(flags: UInt32)
    /// One frame of sound. Not in the recording, where nothing played: the layout is that
    /// of the same protocol elsewhere, flags, a frame number, a time, then the encoded frame.
    case data(flags: UInt32, frameId: UInt32, timestamp: Int64, data: Data)

    public static let startStream: UInt32 = 0x10
    public static let stopStream: UInt32 = 0x08

    /// The datagram payload type that carries this packet.
    public var payloadType: UInt8 {
        switch self {
        case .serverHandshake: return 36
        case .clientHandshake: return 37
        case .control: return 38
        case .data: return 39
        }
    }

    public init(payloadType: UInt8, _ packet: Data) throws {
        var reader = ByteReader(packet)
        do {
            switch payloadType {
            case 36:
                let version = try reader.u32LE()
                let time = try reader.u64LE()
                let count = try reader.u32LE()
                guard count <= 64 else { throw NanoError.malformed("audio formats") }
                var formats: [NanoAudioFormat] = []
                for _ in 0..<count { formats.append(NanoAudioFormat(channels: try reader.u32LE(), sampleRate: try reader.u32LE(), codec: try reader.u32LE())) }
                self = .serverHandshake(version: version, referenceTime: time, formats: formats)
            case 37:
                self = .clientHandshake(initialFrameId: try reader.u32LE(),
                                        format: NanoAudioFormat(channels: try reader.u32LE(), sampleRate: try reader.u32LE(), codec: try reader.u32LE()))
            case 38:
                self = .control(flags: try reader.u32LE())
            case 39:
                let flags = try reader.u32LE(), frame = try reader.u32LE()
                let timestamp = Int64(bitPattern: try reader.u64LE())
                self = .data(flags: flags, frameId: frame, timestamp: timestamp, data: try reader.bytes(Int(try reader.u32LE())))
            default:
                throw NanoError.malformed("audio payload type \(payloadType)")
            }
        } catch let error as NanoError {
            throw error
        } catch {
            throw NanoError.truncated
        }
    }

    public func encoded() -> Data {
        var body = Data()
        switch self {
        case .serverHandshake(let version, let time, let formats):
            body.appendLE(version)
            body.appendLE(time)
            body.appendLE(UInt32(formats.count))
            for format in formats { body.appendLE(format.channels); body.appendLE(format.sampleRate); body.appendLE(format.codec) }
        case .clientHandshake(let frame, let format):
            body.appendLE(frame)
            body.appendLE(format.channels); body.appendLE(format.sampleRate); body.appendLE(format.codec)
        case .control(let flags):
            body.appendLE(flags)
        case .data(let flags, let frame, let timestamp, let data):
            body.appendLE(flags); body.appendLE(frame)
            body.appendLE(UInt64(bitPattern: timestamp))
            body.appendLE(UInt32(data.count)); body.append(data)
        }
        return body
    }
}

/// Keys as input frames name them: the usage numbers of a USB keyboard, which is what the
/// phone's own table maps from, and three numbers of its own for the navigation buttons.
public enum NanoKey {
    public static let home: UInt8 = 106
    public static let recents: UInt8 = 109
    public static let back: UInt8 = 110

    /// The body of an input frame with one key entry, as recorded from Windows: six bytes
    /// saying what the frame holds, then the key and the count of its presses and releases
    /// (odd while held).
    public static func frameBody(key: UInt8, count: UInt8) -> Data {
        Data([0, 0, 0, 1, 0, 0, 0, 1, key, count]) + Data(count: 8)
    }
}
