import Foundation

// The layers of a Nano datagram above the encryption, in the order they are peeled off:
// connection probing, keep-alive, the rate-control handshake, the rate-control header that
// every later packet starts with, the channel multiplexer, and the two channel protocols a
// file transfer uses. Layouts first came from static reading of the phone's library and were
// then read in the clear from a recording of a real phone-to-PC transfer (2026-10-09);
// `protocol/specs/nano-wire-notes.md` says which is which. All numbers are little-endian.

public enum NanoError: Error, Equatable {
    case truncated
    case unknownType(UInt32)
    case malformed(String)
}

extension ByteReader {
    /// A string with a 32-bit length in front, as the channel protocols write them.
    mutating func nanoString() throws -> String {
        let length = Int(try u32LE())
        guard length <= remaining else { throw NanoError.truncated }
        return String(decoding: try bytes(length), as: UTF8.self)
    }
}

extension Data {
    mutating func appendNanoString(_ text: String) {
        let bytes = Data(text.utf8)
        appendLE(UInt32(bytes.count))
        append(bytes)
    }
}

// MARK: Probing, payload type 102

/// Sent by both sides when the UDP path opens, to learn how large a datagram gets through.
public enum NanoProbe: Equatable, Sendable {
    /// A full-size packet. Its content is filler shaped like a STUN message.
    case probe(size: Int)
    /// The answer: the size of the probe that arrived.
    case report(receivedSize: UInt16)

    public init(_ payload: Data) throws {
        var reader = ByteReader(payload)
        switch try reader.u16LE() {
        case 1: self = .probe(size: payload.count)
        case 2: self = .report(receivedSize: try reader.u16LE())
        case let other: throw NanoError.unknownType(UInt32(other))
        }
    }
}

// MARK: Keep-alive, payload type 101

public struct NanoKeepAlive: Equatable, Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }
        /// Carries the sender's timing configuration.
        public static let handshake = Flags(rawValue: 1)
        public static let handshakeAck = Flags(rawValue: 2)
        public static let close = Flags(rawValue: 4)
        /// The MTU probing configuration follows the timing.
        public static let mtuConfiguration = Flags(rawValue: 8)
    }

    public struct Timing: Equatable, Sendable {
        public var interval: UInt64
        public var disconnectTimeout: UInt64
        public var mtuFrequency: UInt32?
        public var mtuProbeFrequency: UInt32?
        public var mtuTimeout: UInt64?
    }

    /// The largest datagram payload the sender has received so far.
    public var reportedMTU: UInt32
    public var flags: Flags
    public var timing: Timing?
    /// Total payload length; larger than the fields need when the packet doubles as an MTU probe.
    public var length: Int

    public init(_ payload: Data) throws {
        var reader = ByteReader(payload)
        length = payload.count
        do {
            reportedMTU = try reader.u32LE()
            flags = Flags(rawValue: try reader.u32LE())
            if flags.contains(.handshake) {
                var timing = Timing(interval: try reader.u64LE(), disconnectTimeout: try reader.u64LE())
                if flags.contains(.mtuConfiguration) {
                    timing.mtuFrequency = try reader.u32LE()
                    timing.mtuProbeFrequency = try reader.u32LE()
                    timing.mtuTimeout = try reader.u64LE()
                }
                self.timing = timing
            }
        } catch {
            throw NanoError.truncated
        }
    }
}

// MARK: Rate-control handshake, payload type 100

public enum NanoRateHandshake: Equatable, Sendable {
    /// Sent first by the side that opened the UDP path, then by the other in answer.
    case syn(version: UInt16, receiverLogSize: UInt8, initialSendSequence: UInt64, controllerType: UInt16, retry: UInt16)
    case synAck(timestamp: UInt32, retry: UInt16)
    case synAckOfAck

    public init(_ payload: Data) throws {
        var reader = ByteReader(payload)
        do {
            switch try reader.u16LE() {
            case 0:
                self = .syn(version: try reader.u16LE(), receiverLogSize: try reader.u8(), initialSendSequence: try reader.u64LE(),
                            controllerType: try reader.u16LE(), retry: try reader.u16LE())
            case 1: self = .synAck(timestamp: try reader.u32LE(), retry: try reader.u16LE())
            case 2: self = .synAckOfAck
            case let other: throw NanoError.unknownType(UInt32(other))
            }
        } catch let error as NanoError {
            throw error
        } catch {
            throw NanoError.truncated
        }
    }

    public func encoded() -> Data {
        var data = Data()
        switch self {
        case .syn(let version, let logSize, let sequence, let controller, let retry):
            data.appendLE(UInt16(0)); data.appendLE(version); data.append(logSize); data.appendLE(sequence); data.appendLE(controller); data.appendLE(retry)
        case .synAck(let timestamp, let retry):
            data.appendLE(UInt16(1)); data.appendLE(timestamp); data.appendLE(retry)
        case .synAckOfAck:
            data.appendLE(UInt16(2))
        }
        return data
    }
}

// MARK: Rate-control header

/// What every packet after the handshake starts with: acknowledgements for the other
/// direction and, when the packet carries data, that data's sequence number. The layout is
/// that of Microsoft's published RDP-UDP version 2 transport.
public struct NanoRateHeader: Equatable, Sendable {
    public struct Ack: Equatable, Sendable {
        public var sequence: UInt16
        /// 24 bits.
        public var timestamp: UInt32
        public var timeGap: UInt8
        public var timeScale: UInt8
        /// Receive-time differences of the packets acknowledged just before this one.
        public var delayedTimeDifferences: [UInt8]
    }

    public struct AckVector: Equatable, Sendable {
        public var baseSequence: UInt16
        public var timestamp: UInt32?
        public var timeGap: UInt8?
        /// Run lengths and bitmaps, as sent.
        public var coded: [UInt8]
    }

    static let ackFlag: UInt16 = 0x001, dataFlag: UInt16 = 0x004, ackVectorFlag: UInt16 = 0x008, ackOfAcksFlag: UInt16 = 0x010
    static let overheadFlag: UInt16 = 0x040, delayedAckFlag: UInt16 = 0x100, correlationFlag: UInt16 = 0x200

    /// The top four bits of the first word: the receive window as a power of two.
    public var logWindowSize: UInt8
    public var ack: Ack?
    public var overheadSize: UInt8?
    public var delayedAck: (maxDelayedAcks: UInt8, timeout: UInt16)?
    public var ackOfAcks: UInt16?
    /// Present when user data follows the header.
    public var dataSequence: UInt16?
    public var ackVector: AckVector?
    public var correlationId: UInt64?
    /// Bytes the header took.
    public var length: Int

    public static func == (lhs: NanoRateHeader, rhs: NanoRateHeader) -> Bool {
        lhs.logWindowSize == rhs.logWindowSize && lhs.ack == rhs.ack && lhs.overheadSize == rhs.overheadSize
            && lhs.delayedAck?.maxDelayedAcks == rhs.delayedAck?.maxDelayedAcks && lhs.delayedAck?.timeout == rhs.delayedAck?.timeout
            && lhs.ackOfAcks == rhs.ackOfAcks && lhs.dataSequence == rhs.dataSequence && lhs.ackVector == rhs.ackVector
            && lhs.correlationId == rhs.correlationId
    }

    public init(logWindowSize: UInt8, ack: Ack? = nil, overheadSize: UInt8? = nil, delayedAck: (maxDelayedAcks: UInt8, timeout: UInt16)? = nil,
                ackOfAcks: UInt16? = nil, dataSequence: UInt16? = nil, ackVector: AckVector? = nil, correlationId: UInt64? = nil) {
        self.logWindowSize = logWindowSize
        self.ack = ack
        self.overheadSize = overheadSize
        self.delayedAck = delayedAck
        self.ackOfAcks = ackOfAcks
        self.dataSequence = dataSequence
        self.ackVector = ackVector
        self.correlationId = correlationId
        length = 0
        length = encoded().count
    }

    /// Parses the header at the start of a payload; the user data, if any, begins at `length`.
    public init(_ payload: Data) throws {
        var reader = ByteReader(payload)
        do {
            let word = try reader.u16LE()
            let flags = word & 0x0FFF
            logWindowSize = UInt8(word >> 12)
            if flags & NanoRateHeader.ackFlag != 0 {
                let sequence = try reader.u16LE()
                let timestamp = UInt32(try reader.u16LE()) | UInt32(try reader.u8()) << 16
                let gap = try reader.u8()
                let counts = try reader.u8()
                var differences: [UInt8] = []
                for _ in 0..<(counts & 0x0F) { differences.append(try reader.u8()) }
                ack = Ack(sequence: sequence, timestamp: timestamp, timeGap: gap, timeScale: counts >> 4, delayedTimeDifferences: differences)
            }
            if flags & NanoRateHeader.overheadFlag != 0 { overheadSize = try reader.u8() }
            if flags & NanoRateHeader.delayedAckFlag != 0 { delayedAck = (try reader.u8(), try reader.u16LE()) }
            if flags & NanoRateHeader.ackOfAcksFlag != 0 { ackOfAcks = try reader.u16LE() }
            if flags & NanoRateHeader.dataFlag != 0 { dataSequence = try reader.u16LE() }
            if flags & NanoRateHeader.ackVectorFlag != 0 {
                let base = try reader.u16LE()
                let counts = try reader.u8()
                var vector = AckVector(baseSequence: base, timestamp: nil, timeGap: nil, coded: [])
                if counts & 0x80 != 0 {
                    vector.timestamp = UInt32(try reader.u16LE()) | UInt32(try reader.u8()) << 16
                    vector.timeGap = try reader.u8()
                }
                for _ in 0..<(counts & 0x7F) { vector.coded.append(try reader.u8()) }
                ackVector = vector
            }
            if flags & NanoRateHeader.correlationFlag != 0 { correlationId = try reader.u64LE() }
            length = reader.position
        } catch {
            throw NanoError.truncated
        }
    }

    public func encoded() -> Data {
        var flags: UInt16 = 0
        if ack != nil { flags |= NanoRateHeader.ackFlag }
        if overheadSize != nil { flags |= NanoRateHeader.overheadFlag }
        if delayedAck != nil { flags |= NanoRateHeader.delayedAckFlag }
        if ackOfAcks != nil { flags |= NanoRateHeader.ackOfAcksFlag }
        if dataSequence != nil { flags |= NanoRateHeader.dataFlag }
        if ackVector != nil { flags |= NanoRateHeader.ackVectorFlag }
        if correlationId != nil { flags |= NanoRateHeader.correlationFlag }
        var data = Data()
        data.appendLE(flags | UInt16(logWindowSize & 0x0F) << 12)
        if let ack {
            data.appendLE(ack.sequence)
            data.appendLE(UInt16(truncatingIfNeeded: ack.timestamp))
            data.append(UInt8(truncatingIfNeeded: ack.timestamp >> 16))
            data.append(ack.timeGap)
            let differences = ack.delayedTimeDifferences.prefix(15)
            data.append(UInt8(differences.count) | (ack.timeScale & 0x0F) << 4)
            data.append(contentsOf: differences)
        }
        if let overheadSize { data.append(overheadSize) }
        if let delayedAck { data.append(delayedAck.maxDelayedAcks); data.appendLE(delayedAck.timeout) }
        if let ackOfAcks { data.appendLE(ackOfAcks) }
        if let dataSequence { data.appendLE(dataSequence) }
        if let ackVector {
            data.appendLE(ackVector.baseSequence)
            let coded = ackVector.coded.prefix(127)
            data.append(UInt8(coded.count) | (ackVector.timestamp != nil ? 0x80 : 0))
            if let timestamp = ackVector.timestamp {
                data.appendLE(UInt16(truncatingIfNeeded: timestamp))
                data.append(UInt8(truncatingIfNeeded: timestamp >> 16))
                data.append(ackVector.timeGap ?? 0)
            }
            data.append(contentsOf: coded)
        }
        if let correlationId { data.appendLE(correlationId) }
        return data
    }
}

// MARK: Channel multiplexer, payload type 97

/// What a channel is, as its creator describes it: the class, two numbers and properties
/// such as `ScenarioId=…`, joined by commas.
public struct NanoChannelDescription: Equatable, Sendable {
    public static let classPrefix = "Microsoft::Basix::Dct::Channel::Class::"

    public var text: String

    public init(text: String) { self.text = text }

    private var parts: [Substring] { text.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false) }
    /// `Messaging`, `Blob`, …
    public var channelClass: String {
        let name = String(parts.first ?? "")
        return name.hasPrefix(NanoChannelDescription.classPrefix) ? String(name.dropFirst(NanoChannelDescription.classPrefix.count)) : name
    }
    /// The properties after the two numbers, by name.
    public var properties: [String: String] {
        guard parts.count == 4 else { return [:] }
        var result: [String: String] = [:]
        for pair in parts[3].split(separator: "&") {
            let sides = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if sides.count == 2 { result[String(sides[0])] = String(sides[1]) }
        }
        return result
    }
}

/// A control packet for one channel, whose number is in the packet header. It follows the
/// rate-control header directly.
public enum NanoMuxControl: Equatable, Sendable {
    /// Sent by the side that creates the channel, followed by an open request.
    case create(NanoChannelDescription, fec: UInt32, initialization: String, weight: Double)
    /// Sent by both sides; the acceptor's has an empty initialization string.
    case open(initialization: String, weight: Double)
    case close(reason: UInt32)

    public init(_ payload: Data) throws {
        var reader = ByteReader(payload)
        do {
            switch try reader.u32LE() {
            case 2:
                let length = Int(try reader.u16LE())
                let description = String(decoding: try reader.bytes(length), as: UTF8.self)
                let fec = try reader.u32LE()
                let initialization = try reader.nanoString()
                self = .create(NanoChannelDescription(text: description), fec: fec, initialization: initialization, weight: Double(bitPattern: try reader.u64LE()))
            case 3:
                let initialization = try reader.nanoString()
                self = .open(initialization: initialization, weight: Double(bitPattern: try reader.u64LE()))
            case 4:
                self = .close(reason: try reader.u32LE())
            case let other:
                throw NanoError.unknownType(other)
            }
        } catch let error as NanoError {
            throw error
        } catch {
            throw NanoError.truncated
        }
    }

    public func encoded() -> Data {
        var data = Data()
        switch self {
        case .create(let description, let fec, let initialization, let weight):
            data.appendLE(UInt32(2))
            let name = Data(description.text.utf8)
            data.appendLE(UInt16(clamping: name.count))
            data.append(name)
            data.appendLE(fec)
            data.appendNanoString(initialization)
            data.appendLE(weight.bitPattern)
        case .open(let initialization, let weight):
            data.appendLE(UInt32(3))
            data.appendNanoString(initialization)
            data.appendLE(weight.bitPattern)
        case .close(let reason):
            data.appendLE(UInt32(4))
            data.appendLE(reason)
        }
        return data
    }
}

/// The eight bytes in front of each packet of a reliable channel: the delivery mode and the
/// number of the packet this one must follow. The packet's own number travels encrypted at
/// the end of the datagram.
public struct NanoSequencerHeader: Equatable, Sendable {
    public static let length = 8

    /// 2 on a channel's first packet, 3 on the later ones.
    public var mode: UInt8
    /// 48 bits; the packet's own number minus one, and zero for the first two.
    public var dependsOn: UInt64

    public init(mode: UInt8, dependsOn: UInt64) {
        self.mode = mode
        self.dependsOn = dependsOn
    }

    /// The header of the packet with the given number on its channel.
    public init(forPacket number: UInt64) {
        mode = number == 0 ? 2 : 3
        dependsOn = number == 0 ? 0 : number - 1
    }

    public init(_ payload: Data) throws {
        guard payload.count >= NanoSequencerHeader.length else { throw NanoError.truncated }
        var reader = ByteReader(payload)
        mode = (try? reader.u8()) ?? 0
        _ = try? reader.u8()
        let low = UInt64((try? reader.u32LE()) ?? 0), high = UInt64((try? reader.u16LE()) ?? 0)
        dependsOn = low | high << 32
    }

    public func encoded() -> Data {
        var data = Data([mode, 0])
        data.appendLE(UInt32(truncatingIfNeeded: dependsOn))
        data.appendLE(UInt16(truncatingIfNeeded: dependsOn >> 32))
        return data
    }
}

// MARK: Message channel

/// A packet of a `Messaging` channel: a type, the length of the rest, the rest.
public enum NanoMessagePacket: Equatable, Sendable {
    case handshake(version: UInt32)
    /// A message, or one piece of it. The message is its path followed by its body; `data`
    /// is the piece of that starting at `offset`.
    case data(flags: UInt32, id: UInt32, count: UInt32, pathLength: UInt32, bodyLength: UInt32, offset: UInt32, data: Data)
    case cancel(id: UInt32)

    public init(_ payload: Data) throws {
        var reader = ByteReader(payload)
        do {
            let type = try reader.u32LE()
            let length = Int(try reader.u32LE())
            guard length <= reader.remaining else { throw NanoError.truncated }
            switch type {
            case 1: self = .handshake(version: try reader.u32LE())
            case 2:
                let flags = try reader.u32LE(), id = try reader.u32LE(), count = try reader.u32LE()
                let pathLength = try reader.u32LE(), bodyLength = try reader.u32LE(), offset = try reader.u32LE()
                let size = Int(try reader.u32LE())
                self = .data(flags: flags, id: id, count: count, pathLength: pathLength, bodyLength: bodyLength, offset: offset, data: try reader.bytes(size))
            case 3: self = .cancel(id: try reader.u32LE())
            default: throw NanoError.unknownType(type)
            }
        } catch let error as NanoError {
            throw error
        } catch {
            throw NanoError.truncated
        }
    }

    public func encoded() -> Data {
        var body = Data()
        let type: UInt32
        switch self {
        case .handshake(let version):
            type = 1
            body.appendLE(version)
        case .data(let flags, let id, let count, let pathLength, let bodyLength, let offset, let data):
            type = 2
            for value in [flags, id, count, pathLength, bodyLength, offset, UInt32(clamping: data.count)] { body.appendLE(value) }
            body.append(data)
        case .cancel(let id):
            type = 3
            body.appendLE(id)
        }
        var packet = Data()
        packet.appendLE(type)
        packet.appendLE(UInt32(clamping: body.count))
        packet.append(body)
        return packet
    }

    /// A whole message in one packet, as every message in the recording was sent.
    public static func message(id: UInt32, path: String, body: Data) -> NanoMessagePacket {
        let pathBytes = Data(path.utf8)
        return .data(flags: 0, id: id, count: 1, pathLength: UInt32(clamping: pathBytes.count), bodyLength: UInt32(clamping: body.count), offset: 0, data: pathBytes + body)
    }
}

/// Puts the pieces of messages back together.
public struct NanoMessageAssembler: Sendable {
    public struct Message: Equatable, Sendable {
        public var id: UInt32
        public var path: String
        public var body: Data
    }

    /// The most one message may claim to hold; more is refused before any memory is set aside.
    public static let sizeLimit = 16 * 1024 * 1024

    private var partial: [UInt32: (pathLength: Int, total: Int, received: Int, data: Data)] = [:]

    public init() {}

    /// Feeds one data packet; returns the message when its last piece has arrived.
    public mutating func add(_ packet: NanoMessagePacket) -> Message? {
        guard case .data(_, let id, _, let pathLength, let bodyLength, let offset, let data) = packet else { return nil }
        let total = Int(pathLength) + Int(bodyLength)
        guard total <= NanoMessageAssembler.sizeLimit, Int(offset) + data.count <= total else { return nil }
        var entry = partial.removeValue(forKey: id) ?? (Int(pathLength), total, 0, Data(count: total))
        guard entry.total == total else {
            partial[id] = entry
            return nil
        }
        entry.data.replaceSubrange(Int(offset)..<(Int(offset) + data.count), with: data)
        entry.received += data.count
        guard entry.received >= total else {
            partial[id] = entry
            return nil
        }
        partial[id] = nil
        return Message(id: id, path: String(decoding: entry.data.prefix(entry.pathLength), as: UTF8.self), body: Data(entry.data.dropFirst(entry.pathLength)))
    }
}

// MARK: Blob channel

/// A packet of a `Blob` channel, which carries a file's bytes.
public enum NanoBlobPacket: Equatable, Sendable {
    case handshake(minVersion: UInt32, maxVersion: UInt32)
    /// One piece of a blob. A blob travels in segments (of 100,000 bytes from the phone):
    /// `segment` is the number of this piece's segment, counted from zero, `size` that
    /// segment's own length (the last one is shorter), `pieces` how many pieces the segment
    /// has, and `offset` this piece's place inside the segment. The piece belongs at
    /// `segment` times the full segment length, plus `offset`. Seen live on 2026-10-09 with a
    /// file of 259 segments; a file that fits one segment has `segment` 0 throughout.
    case data(flags: UInt32, pieces: UInt32, segment: UInt64, totalSize: UInt64, name: String, size: UInt32, offset: UInt32, data: Data)
    /// From the sender when everything was sent (kind 1 in the recording), and from the
    /// receiver when everything was stored (kind 4).
    case completion(kind: UInt32, name: String)
    /// Announces a blob and its size before the first piece.
    case start(totalSize: UInt64, name: String)
    /// The receiver's report that pieces were written, with how many still wait.
    case written(queued: UInt32, name: String)

    public init(_ payload: Data) throws {
        var reader = ByteReader(payload)
        do {
            let type = try reader.u32LE()
            let length = Int(try reader.u32LE())
            guard length <= reader.remaining else { throw NanoError.truncated }
            switch type {
            case 1: self = .handshake(minVersion: try reader.u32LE(), maxVersion: try reader.u32LE())
            case 2:
                let flags = try reader.u32LE(), pieces = try reader.u32LE(), segment = try reader.u64LE(), total = try reader.u64LE()
                let name = try reader.nanoString()
                let size = try reader.u32LE(), offset = try reader.u32LE()
                let count = Int(try reader.u32LE())
                self = .data(flags: flags, pieces: pieces, segment: segment, totalSize: total, name: name, size: size, offset: offset, data: try reader.bytes(count))
            case 3: self = .completion(kind: try reader.u32LE(), name: try reader.nanoString())
            case 4: self = .start(totalSize: try reader.u64LE(), name: try reader.nanoString())
            case 5: self = .written(queued: try reader.u32LE(), name: try reader.nanoString())
            default: throw NanoError.unknownType(type)
            }
        } catch let error as NanoError {
            throw error
        } catch {
            throw NanoError.truncated
        }
    }

    public func encoded() -> Data {
        var body = Data()
        let type: UInt32
        switch self {
        case .handshake(let minVersion, let maxVersion):
            type = 1
            body.appendLE(minVersion); body.appendLE(maxVersion)
        case .data(let flags, let pieces, let segment, let total, let name, let size, let offset, let data):
            type = 2
            body.appendLE(flags); body.appendLE(pieces); body.appendLE(segment); body.appendLE(total)
            body.appendNanoString(name)
            body.appendLE(size); body.appendLE(offset); body.appendLE(UInt32(clamping: data.count))
            body.append(data)
        case .completion(let kind, let name):
            type = 3
            body.appendLE(kind); body.appendNanoString(name)
        case .start(let total, let name):
            type = 4
            body.appendLE(total); body.appendNanoString(name)
        case .written(let queued, let name):
            type = 5
            body.appendLE(queued); body.appendNanoString(name)
        }
        var packet = Data()
        packet.appendLE(type)
        packet.appendLE(UInt32(clamping: body.count))
        packet.append(body)
        return packet
    }
}

/// A blob that has arrived whole: in memory, or as a file when the assembler was given a
/// folder to write to.
public enum NanoBlobContent: Equatable, Sendable {
    case data(Data)
    /// A file of exactly this many bytes. Whoever takes the content moves or deletes it.
    case file(URL, size: Int)

    public var count: Int {
        switch self {
        case .data(let data): return data.count
        case .file(_, let size): return size
        }
    }

    /// The bytes; a file is read whole, so this is for small blobs and for tests.
    public var data: Data {
        switch self {
        case .data(let data): return data
        case .file(let url, _): return (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()
        }
    }
}

/// A file being filled piece by piece, in any order. Deleted again unless it is kept.
final class NanoBlobFile: @unchecked Sendable {
    let url: URL
    private let descriptor: Int32
    private let lock = NSLock()
    private var kept = false
    private(set) var failed = false

    /// Creates the file under a random name, at its final length.
    init?(in directory: URL, size: Int) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(UUID().uuidString.lowercased() + ".part")
        descriptor = open(url.path, O_CREAT | O_EXCL | O_RDWR, 0o644)
        guard descriptor >= 0 else { return nil }
        // On failure the file goes with this object: it is closed and removed as it is let go.
        if ftruncate(descriptor, off_t(size)) != 0 { return nil }
    }

    func write(_ data: Data, at offset: Int) {
        let ok = data.withUnsafeBytes { buffer -> Bool in
            var done = 0
            while done < buffer.count {
                let written = pwrite(descriptor, buffer.baseAddress! + done, buffer.count - done, off_t(offset + done))
                if written <= 0 { return false }
                done += written
            }
            return true
        }
        if !ok { lock.withLock { failed = true } }
    }

    /// The file stays when this object goes.
    func keep() { lock.withLock { kept = true } }

    deinit {
        if descriptor >= 0 { close(descriptor) }
        if !kept { unlink(url.path) }
    }
}

/// Puts a blob together from its data packets. Pieces may arrive in any order and more than
/// once; the blob is complete when every byte has been covered.
public struct NanoBlobAssembler: Sendable {
    /// The largest blob accepted; a larger announcement is refused before room is set aside.
    public var sizeLimit: UInt64
    /// Where blobs are written as they arrive. Without it they are held in memory.
    public var directory: URL?

    /// The length of a full segment when the sender does not let it be worked out: what the
    /// phone uses.
    public static let usualSegmentLength = 100_000
    /// Free space that must remain on the disk after a blob has been written to it.
    static let diskReserve: Int64 = 256 * 1024 * 1024

    enum Store: Sendable {
        case memory(Data)
        case file(NanoBlobFile)
    }

    public struct Finished: Sendable {
        public var name: String
        public var content: NanoBlobContent
        public var data: Data { content.data }
    }

    private var blobs: [String: (total: Int, store: Store, covered: IndexSet)] = [:]
    /// The length of a full segment per blob, learnt from a piece of its first segment.
    private var segmentLengths: [String: Int] = [:]
    /// Blobs turned away, so that each is reported once.
    public private(set) var refused: Set<String> = []
    /// Blobs handed over: a piece of one that comes again afterwards starts nothing new.
    private var completed: Set<String> = []

    public init(sizeLimit: UInt64 = 2 * 1024 * 1024 * 1024, directory: URL? = nil) {
        self.sizeLimit = sizeLimit
        self.directory = directory
    }

    /// Bytes received so far and the announced size, per blob.
    public var progress: [String: (received: Int, total: Int)] {
        blobs.mapValues { ($0.covered.count, $0.total) }
    }

    /// Gaps between the pieces received so far, over all blobs: zero while pieces arrive in order.
    public var holeCount: Int {
        blobs.values.reduce(0) { $0 + max(0, $1.covered.rangeView.count - 1) + (($1.covered.first ?? 0) > 0 ? 1 : 0) }
    }

    /// Where the first missing stretch of a blob begins and how long it is, if pieces after
    /// it have already arrived.
    public func firstHole(of name: String) -> (offset: Int, length: Int)? {
        guard let blob = blobs[name] else { return nil }
        var expected = 0
        for range in blob.covered.rangeView {
            if range.lowerBound > expected { return (expected, range.lowerBound - expected) }
            expected = range.upperBound
        }
        return nil
    }

    /// The names of the blobs still arriving.
    public var names: [String] { Array(blobs.keys) }

    /// How far one blob has come, without touching the others.
    public func progress(of name: String) -> (received: Int, total: Int)? {
        blobs[name].map { ($0.covered.count, $0.total) }
    }

    /// Whether the disk under a folder can take this many bytes and keep its reserve. True
    /// when the free space cannot be found out.
    public static func hasRoom(for bytes: UInt64, in directory: URL) -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let free = (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage else { return true }
        return Int64(clamping: bytes) <= free - diskReserve
    }

    /// Room for a blob of this size: a file when there is a folder and the disk has the
    /// space, memory when there is no folder.
    private mutating func makeStore(_ total: UInt64, name: String) -> Store? {
        guard total <= sizeLimit, !refused.contains(name), !completed.contains(name) else { return nil }
        guard let directory else { return .memory(Data(count: Int(total))) }
        guard NanoBlobAssembler.hasRoom(for: total, in: directory) else {
            refused.insert(name)
            return nil
        }
        guard let file = NanoBlobFile(in: directory, size: Int(total)) else {
            refused.insert(name)
            return nil
        }
        return .file(file)
    }

    /// Feeds one packet. Returns a blob's name and content once every byte of it has arrived.
    public mutating func add(_ packet: NanoBlobPacket) -> Finished? {
        switch packet {
        case .start(let total, let name):
            guard blobs[name] == nil, let store = makeStore(total, name: name) else { return nil }
            blobs[name] = (Int(total), store, IndexSet())
            return total == 0 ? finish(name) : nil
        case .data(_, _, let segment, let total, let name, let size, let offset, let data):
            guard total <= sizeLimit, segment <= total else { return nil }
            // The first segment is a full one whenever there are more, so its length is the
            // length of every full segment.
            if segment == 0, UInt64(size) < total, size > 0 { segmentLengths[name] = Int(size) }
            let segmentStart = segment == 0 ? 0 : Int(segment) * (segmentLengths[name] ?? NanoBlobAssembler.usualSegmentLength)
            // Taken out of the table while it is written to: a buffer that is also held
            // there would be copied whole for every piece.
            var blob: (total: Int, store: Store, covered: IndexSet)
            if let known = blobs.removeValue(forKey: name) {
                blob = known
            } else if let store = makeStore(total, name: name) {
                blob = (Int(total), store, IndexSet())
            } else {
                return nil
            }
            let start = segmentStart + Int(offset)
            guard !data.isEmpty, start + data.count <= blob.total else {
                blobs[name] = blob
                return nil
            }
            switch blob.store {
            case .memory(var bytes):
                blob.store = .memory(Data())
                bytes.withUnsafeMutableBytes { buffer in
                    data.withUnsafeBytes { piece in
                        if let target = buffer.baseAddress, let source = piece.baseAddress { memcpy(target + start, source, data.count) }
                    }
                }
                blob.store = .memory(bytes)
            case .file(let file):
                file.write(data, at: start)
            }
            blob.covered.insert(integersIn: start..<(start + data.count))
            let complete = blob.covered.count == blob.total
            blobs[name] = blob
            return complete ? finish(name) : nil
        default:
            return nil
        }
    }

    private mutating func finish(_ name: String) -> Finished? {
        segmentLengths[name] = nil
        guard let blob = blobs.removeValue(forKey: name) else { return nil }
        completed.insert(name)
        switch blob.store {
        case .memory(let bytes):
            return Finished(name: name, content: .data(bytes))
        case .file(let file):
            // A write that failed leaves a file that is not the blob: it is dropped.
            guard !file.failed else {
                refused.insert(name)
                return nil
            }
            file.keep()
            return Finished(name: name, content: .file(file.url, size: blob.total))
        }
    }
}
