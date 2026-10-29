import Network
import SwiftProtobuf
import XCTest
@testable import WinPhoneCore

/// Datagrams passed in memory between this client and a scripted phone. Can lose packets.
final class MemoryNanoTransport: NanoDatagramTransport, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let inbox: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var peer: MemoryNanoTransport?
    /// Called for each datagram about to leave; return false to lose it.
    var shouldDeliver: (@Sendable (Data) -> Bool)?
    private(set) var sentCount = 0

    init() { (incoming, inbox) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded) }

    static func pair() -> (MemoryNanoTransport, MemoryNanoTransport) {
        let a = MemoryNanoTransport(), b = MemoryNanoTransport()
        a.peer = b
        b.peer = a
        return (a, b)
    }

    func send(_ datagram: Data) async throws {
        let (peer, filter) = lock.withLock { sentCount += 1; return (self.peer, shouldDeliver) }
        if filter?(datagram) ?? true { peer?.inbox.yield(datagram) }
    }

    func close() {
        inbox.finish()
        lock.withLock { peer }?.inbox.finish()
    }
}

/// Plays the phone's side of a Nano connection as the recording shows it: answers the start
/// sequence, creates the channels, offers files, sends them when asked.
actor ScriptedNanoPhone {
    struct File { var id: String; var name: String; var data: Data }

    let transport: MemoryNanoTransport
    let keys: NanoSessionKeys
    var files: [File]
    var refuseChannel = false
    var pieceSize = 1268
    /// Plays the exchange of a share toward the Phone Link client instead.
    var legacy = false
    private(set) var workflowRequest: [String: Any]?
    private(set) var legacyRequests: [[String: Any]] = []
    func setLegacy(_ legacy: Bool) { self.legacy = legacy }
    var workflowName: String? { workflowRequest?["workflow"] as? String }
    var legacyScenarios: [String] { legacyRequests.compactMap { $0["Scenario"] as? String } }
    var lastLegacyStatuses: [Int] { (legacyRequests.last?["Content"] as? [[String: Any]] ?? []).compactMap { ($0["FileStatus"] as? NSNumber)?.intValue } }
    var lastLegacyFolder: String? { legacyRequests.last?["PcFolder"] as? String }

    // What the PC did, for the tests to look at.
    private(set) var probesSeen = 0, reportsSeen: [UInt16] = [], keepAliveAnswers: [UInt32] = [], fillerSeen = 0
    private(set) var syn: NanoRateHandshake?
    private(set) var channelRequest: PlatformSdk_V1_ProtoCreatePlatformChannelRequest?
    private(set) var manifestPath: String?
    private(set) var manifest: PlatformSdk_V1_ProtoManifest?
    private(set) var completed: FileTransfer_V1_FileShareMessage?
    private(set) var blobPacketsFromPC: [NanoBlobPacket] = []
    private(set) var opened: Set<UInt16> = [], closed: Set<UInt16> = [], handshakes: Set<UInt16> = []
    private(set) var duplicateData = 0

    private var index: UInt64 = 0
    private var dataSequence: UInt16 = 100
    private var inner: [UInt16: UInt64] = [:]
    private var seen: Set<UInt16> = []
    private var messageId: UInt32 = 500
    private var started = false, greeted = false, offered = false
    private var assemblers: [UInt16: NanoMessageAssembler] = [:]
    private var pump: Task<Void, Never>?
    let transferId = "0123456789abcdef0123456789abcdef"

    init(transport: MemoryNanoTransport, keys: NanoSessionKeys, files: [File]) {
        self.transport = transport
        self.keys = keys
        self.files = files
    }

    func setRefuse(_ refuse: Bool) { refuseChannel = refuse }
    /// Takes the list of wanted files and then says nothing more.
    var silentAboutManifests = false
    func setSilentAboutManifests(_ silent: Bool) { silentAboutManifests = silent }

    func run() {
        pump = Task { for await datagram in transport.incoming { await self.receive(datagram) } }
        // Like a real sender: what is not acknowledged is sent again.
        resender = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
                await self.resendUnacknowledged()
            }
        }
    }

    // Showing the screen, as recorded from the real phone with Windows: a consent step, then
    // on request a message channel, an input channel and a video channel for the screen.
    private(set) var workflowsAsked: [String] = [], workflowsStopped: [String] = []
    private(set) var mirrorRequests: [(path: String, object: [String: Any])] = []
    private(set) var inputFramesFromPC: [(id: UInt32, body: Data)] = []
    private(set) var videoPacketsFromPC: [NanoVideoPacket] = []
    private var firstVideoFrame: UInt32 = 0
    private(set) var closingAnswers: [String] = []
    /// What the real phone sends on the app's own message channel when the app is closed.
    /// A phone that is locked when the session begins: it says so and sends no picture, as the
    /// real one does. Whether asking for the stream a second time helps is not known of the
    /// real phone; both are played.
    var startsLocked = false, answersASecondStart = false
    private(set) var videoStartsAsked = 0
    func setStartsLocked(_ locked: Bool, answersASecondStart: Bool = false) { startsLocked = locked; self.answersASecondStart = answersASecondStart }
    /// Awake, and sends no picture all the same, as the real phone did in a session begun
    /// right after it was unlocked.
    var staysDark = false
    func setStaysDark(_ dark: Bool, answersASecondStart: Bool = false) { staysDark = dark; self.answersASecondStart = answersASecondStart }
    /// What the real phone says when its screen goes off and it locks, and when it is back.
    /// An app that protects its screen comes up, or goes.
    func setProtected(_ protected: Bool) async {
        await message(1028, path: "/mirror/phone/secureContentChanged", Data("{\"isSecureContent\":\(protected)}".utf8))
    }
    func setLocked(_ locked: Bool) async {
        await message(1027, path: "/mirror/phone/setLockedState", Data("{\"isLocked\":\(locked),\"isScreenOn\":\(!locked),\"isSecureLocked\":\(locked)}".utf8))
    }
    /// A phone turned on its side while its whole screen is shown: the new size by message,
    /// and the picture offered anew in its new shape.
    func turnScreen(width: Int, height: Int, pictureWidth: UInt32, pictureHeight: UInt32) async {
        await message(1028, path: "/mirror/phone/deviceResolutionChanged", Data("{\"width\":\(width),\"height\":\(height)}".utf8))
        await channelPacket(1031, NanoVideoPacket.serverHandshake(version: 6, width: pictureWidth, height: pictureHeight, framesPerSecond: 60, referenceTime: 1,
                                                                 formats: [NanoVideoFormat(framesPerSecond: 60, width: pictureWidth, height: pictureHeight)]).encoded())
    }
    /// An app that turned on its side: the picture stays, and is to be shown turned.
    func turnApp(_ quarterTurns: Int) async {
        await message(1028, path: "/mirror/phone/orientationChanged", Data("{\"orientationInfo\":\(quarterTurns)}".utf8))
    }
    func closeApp() async {
        await message(1028, path: "/mirror/phone/disconnecting", Data(#"{"transactionId":"t-1","reason":"closedByBack"}"#.utf8))
    }
    private(set) var permissionRequests: [String] = []
    private(set) var audioPacketsFromPC: [NanoAudioPacket] = []
    static let soundFrames = [Data([0xFC, 1, 2, 3, 4]), Data([0xFC, 9, 8, 7])]
    var deniesScreen = false
    func setDeniesScreen(_ denies: Bool) { deniesScreen = denies }
    /// Answers the handshake, then neither opens a channel nor says anything more.
    var stallsAfterHandshake = false
    func setStallsAfterHandshake(_ stalls: Bool) { stallsAfterHandshake = stalls }
    /// What the phone says to a notification's button being pressed; nil for nothing at all.
    private var notificationLaunchResult: Int? = 0
    func setNotificationLaunchResult(_ result: Int?) { notificationLaunchResult = result }
    /// Stand-ins for the units of a stream: parameter sets, a whole picture, a picture that builds on it.
    static let screenFrames: [(key: Bool, data: Data)] = [
        (true, Data([0, 0, 0, 1, 0x67, 1, 2, 3, 0, 0, 0, 1, 0x68, 4, 5])),
        (true, Data([0, 0, 0, 1, 0x65]) + Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7 | 1) })),
        (false, Data([0, 0, 0, 1, 0x41]) + Data((0..<900).map { UInt8(truncatingIfNeeded: $0 &* 5 | 1) })),
    ]

    /// The picture breaks: a whole frame, then one that builds on a frame that never came,
    /// then nothing more, as on a poor network with a still screen. With `mends`, a later
    /// request for the stream brings whole frames again.
    var breaksPicture = false, mendsOnRestart = false
    func setBreaksPicture(_ breaks: Bool, mends: Bool) { breaksPicture = breaks; mendsOnRestart = mends }
    private var brokenFramesSent = false

    private func sendBrokenFrames() async {
        let frames = ScriptedNanoPhone.screenFrames
        for (number, frame) in [(1, frames[0]), (2, frames[1]), (4, frames[2])] {
            await channelPacket(1031, NanoVideoPacket.data(flags: frame.key ? 6 : 4, frameId: firstVideoFrame &+ UInt32(number), timestamp: Int64(number) * 16_000, reserved: 0,
                                                         totalSize: UInt32(frame.data.count), packetCount: 1, offset: 0, metadata: Data(), data: frame.data).encoded())
        }
    }

    private func sendScreenFrames() async {
        if breaksPicture {
            if !brokenFramesSent { brokenFramesSent = true; await sendBrokenFrames(); return }
            guard mendsOnRestart else { return }
            // Numbered after the broken ones, starting with a whole picture.
            firstVideoFrame &+= 10
        }
        for (index, frame) in ScriptedNanoPhone.screenFrames.enumerated() {
            let pieces = stride(from: 0, to: frame.data.count, by: 1275).map { ($0, frame.data.subdata(in: $0..<min($0 + 1275, frame.data.count))) }
            for (offset, piece) in pieces {
                await channelPacket(1031, NanoVideoPacket.data(flags: frame.key ? 6 : 4, frameId: firstVideoFrame &+ UInt32(index + 1), timestamp: Int64(index) * 16_000, reserved: 0,
                                                             totalSize: UInt32(frame.data.count), packetCount: UInt32(pieces.count), offset: UInt32(offset),
                                                             metadata: Data(), data: piece).encoded())
            }
        }
    }

    // Receiving files from the PC, as the phone's code does it: after the offer it asks for
    // one file at a time, takes the blob named by the file's ID and a send count, and says
    // "completed" when it has them all.
    private var pcOffer: [String: Any]?
    private var pcAssembler = NanoBlobAssembler()
    private(set) var receivedFromPC: [String: Data] = [:]
    private(set) var blobNamesFromPC: [String] = []
    private(set) var piecesFromPC = 0
    var rejectsOffers = false
    /// Cancels, as from the phone's screen, once this many pieces have arrived.
    var cancelsAfterPieces: Int?
    func setIncoming(rejects: Bool = false, cancelsAfterPieces: Int? = nil) { rejectsOffers = rejects; self.cancelsAfterPieces = cancelsAfterPieces }

    private func pcMessage(_ scenario: String, wanted: String?) -> Data {
        let items = (pcOffer?["Content"] as? [[String: Any]] ?? []).map { item -> [String: Any] in
            var item = item
            let id = item["FileId"] as? String ?? ""
            item["FileStatus"] = receivedFromPC[id] != nil ? 3 : (id == wanted ? 2 : 1)
            return item
        }
        let object: [String: Any] = ["Scenario": scenario, "TransferId": pcOffer?["TransferId"] as? String ?? "", "ReceivedFileCount": receivedFromPC.count,
                                     "SessionTryCount": 1, "Content": items]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func askPCForNextFile() async {
        let ids = (pcOffer?["Content"] as? [[String: Any]] ?? []).compactMap { $0["FileId"] as? String }
        if let next = ids.first(where: { receivedFromPC[$0] == nil }) {
            await message(1025, path: "/fileTransfer", pcMessage("FileTransferToPhoneFile", wanted: next))
        } else {
            await message(1025, path: "/fileTransfer", pcMessage("FileTransferToPhoneCompleted", wanted: nil))
        }
    }

    private func receiveFromPC(_ packet: NanoBlobPacket) async {
        if case .start(_, let name) = packet { blobNamesFromPC.append(name) }
        if let limit = cancelsAfterPieces, piecesFromPC == limit {
            cancelsAfterPieces = nil
            await message(1025, path: "/fileTransfer", try! JSONSerialization.data(withJSONObject: ["Scenario": "FileTransferToPcCancel", "TransferId": pcOffer?["TransferId"] as? String ?? ""]))
            return
        }
        guard let finished = pcAssembler.add(packet) else { return }
        // Everything from "#" on is the count of sends.
        let id = finished.name.components(separatedBy: "#")[0]
        receivedFromPC[id] = finished.data
        await channelPacket(1026, NanoBlobPacket.written(queued: 0, name: finished.name).encoded())
        await channelPacket(1026, NanoBlobPacket.completion(kind: 4, name: finished.name).encoded())
        await askPCForNextFile()
    }

    private var resender: Task<Void, Never>?
    private var unacknowledged: [UInt16: (type: UInt8, channel: UInt16, body: Data, inner: UInt16, sent: ContinuousClock.Instant)] = [:]
    private var seenInner: [UInt16: Set<UInt16>] = [:]
    private(set) var resent = 0, resentOnTimer = 0

    // The sending half as the real phone's code has it (wire notes, section 13): a plain
    // acknowledgement covers everything up to its number; a vector names what is missing;
    // a packet reported missing by two equal vectors, or with eight later ones arrived, is
    // sent again under a new number; a vector that calls missing what was acknowledged
    // before is a protocol error, counted here.
    private var acknowledgedNumbers: Set<UInt16> = []
    private var lastVector: (base: UInt16, count: Int, arrived: Int)?
    private(set) var vectorsSeen = 0, contradictions = 0
    /// How this phone notices loss: by the reports, by its own timer, or both.
    var usesVectors = true, usesTimer = true
    func setRecovery(vectors: Bool, timer: Bool) { usesVectors = vectors; usesTimer = timer }
    /// The Mac's packets, kept as the real phone's receiving half keeps them.
    private var macInbound = NanoInbound(first: 100)
    private let began = ContinuousClock.now

    private func settle(_ sequence: UInt16) {
        if unacknowledged.removeValue(forKey: sequence) != nil { acknowledgedNumbers.insert(sequence) }
    }

    private func sendAgain(_ sequence: UInt16) async {
        guard let entry = unacknowledged.removeValue(forKey: sequence) else { return }
        // Under a new number, as the real phone does; the old one is never used again.
        resent += 1
        await data(type: entry.type, channel: entry.channel, entry.body, inner: entry.inner)
    }

    private func resendUnacknowledged() async {
        guard usesTimer else { return }
        let now = ContinuousClock.now
        for (sequence, entry) in unacknowledged.sorted(by: { Int16(bitPattern: $0.key &- $1.key) < 0 }).prefix(64) where now - entry.sent > .milliseconds(120) {
            resentOnTimer += 1
            await sendAgain(sequence)
        }
    }

    private func apply(_ vector: NanoRateHeader.AckVector) async {
        vectorsSeen += 1
        let elements = vector.elements, base = vector.baseSequence
        let arrived = elements.filter { $0 }.count
        if elements.first == true || Int16(bitPattern: base &+ UInt16(elements.count) &- dataSequence) > 0 { contradictions += 1; return }
        let same = lastVector.map { $0.base == base && $0.count == elements.count && $0.arrived == arrived } ?? false
        lastVector = (base, elements.count, arrived)
        guard usesVectors else { return }
        for sequence in Array(unacknowledged.keys) where Int16(bitPattern: sequence &- base) < 0 { settle(sequence) }
        var lost: [UInt16] = []
        for (index, got) in elements.enumerated() {
            let sequence = base &+ UInt16(index)
            if got {
                settle(sequence)
            } else if acknowledgedNumbers.contains(sequence) {
                contradictions += 1
            } else if unacknowledged[sequence] != nil, same || elements.count - 1 - index >= 8 {
                lost.append(sequence)
            }
        }
        for sequence in lost { await sendAgain(sequence) }
    }

    /// The lowest number still outstanding, or the next to be used: the "ack of acks".
    private var lowestOutstanding: UInt16 {
        var lowest = dataSequence
        for sequence in unacknowledged.keys where Int16(bitPattern: sequence &- lowest) < 0 { lowest = sequence }
        return lowest
    }

    private func send(type: UInt8, channel: UInt16, _ payload: Data, inner: UInt16 = 0) async {
        let header = NanoHeader(payloadType: type, sequence: UInt16(truncatingIfNeeded: index), ssrc: UInt32(channel))
        index += 1
        if let sealed = try? NanoDatagram(header: header, payload: payload, innerSequence: inner).sealed(with: keys) { try? await transport.send(sealed) }
    }

    private func data(type: UInt8, channel: UInt16, _ body: Data, inner: UInt16 = 0) async {
        let header = NanoRateHeader(logWindowSize: 12, ackOfAcks: lowestOutstanding, dataSequence: dataSequence)
        let payload = header.encoded() + body
        // Filler is never sent again; everything else is, until acknowledged.
        if type != 104 { unacknowledged[dataSequence] = (type, channel, body, inner, ContinuousClock.now) }
        dataSequence &+= 1
        await send(type: type, channel: channel, payload, inner: inner)
    }

    private func channelPacket(_ channel: UInt16, _ packet: Data, type: UInt8 = 35) async {
        let number = inner[channel, default: 0]
        inner[channel] = number + 1
        await data(type: type, channel: channel, NanoSequencerHeader(forPacket: number).encoded() + packet, inner: UInt16(truncatingIfNeeded: number))
    }

    private func message(_ channel: UInt16, path: String, _ body: Data) async {
        messageId += 1
        await channelPacket(channel, NanoMessagePacket.message(id: messageId, path: path, body: body).encoded())
    }

    private func create(_ channel: UInt16, _ text: String) async {
        let description = NanoChannelDescription(text: NanoChannelDescription.classPrefix + text)
        await data(type: 97, channel: channel, NanoMuxControl.create(description, fec: 0, initialization: description.text, weight: 1).encoded())
        await data(type: 97, channel: channel, NanoMuxControl.open(initialization: description.text, weight: 1).encoded())
    }

    /// Sends one file as the real phone does: in segments of 100,000 bytes, each piece
    /// carrying its segment's start and its own place inside the segment.
    private func sendBlob(_ file: File) async {
        let segmentSize = 100_000
        await channelPacket(1026, NanoBlobPacket.start(totalSize: UInt64(file.data.count), name: file.id).encoded())
        for segmentStart in stride(from: 0, to: file.data.count, by: segmentSize) {
            let segment = file.data[segmentStart..<min(segmentStart + segmentSize, file.data.count)]
            let pieces = UInt32((segment.count + pieceSize - 1) / pieceSize)
            for offset in stride(from: 0, to: segment.count, by: pieceSize) {
                let piece = segment[(segment.startIndex + offset)..<min(segment.startIndex + offset + pieceSize, segment.endIndex)]
                await channelPacket(1026, NanoBlobPacket.data(flags: 0, pieces: pieces, segment: UInt64(segmentStart / segmentSize), totalSize: UInt64(file.data.count), name: file.id,
                                                             size: UInt32(segment.count), offset: UInt32(offset), data: Data(piece)).encoded())
            }
        }
        await channelPacket(1026, NanoBlobPacket.completion(kind: 1, name: file.id).encoded())
    }

    private func receive(_ datagram: Data) async {
        guard let packet = try? NanoDatagram(opening: datagram, keys: keys) else { return }
        switch packet.header.kind {
        case .probing:
            switch try? NanoProbe(packet.payload) {
            case .probe(let size):
                probesSeen += 1
                _ = size
                // As the real phone does: its own probe first, and nothing more until that
                // probe has been reported back.
                await send(type: 102, channel: 0, Data([1, 0]) + Data((0..<1456).map { _ in UInt8.random(in: 0...255) }))
            case .report(let size):
                reportsSeen.append(size)
                guard reportsSeen.count == 1 else { return }
                var report = Data([2, 0]); report.appendLE(UInt16(1200))
                await send(type: 102, channel: 0, report)
                var keepAlive = Data()
                keepAlive.appendLE(UInt32(0)); keepAlive.appendLE(UInt32(9)); keepAlive.appendLE(UInt64(2000)); keepAlive.appendLE(UInt64(15000))
                keepAlive.appendLE(UInt32(10)); keepAlive.appendLE(UInt32(100)); keepAlive.appendLE(UInt64(90_000_000))
                await send(type: 101, channel: 0, keepAlive)
            case nil: break
            }
        case .keepAlive:
            if let keepAlive = try? NanoKeepAlive(packet.payload) { keepAliveAnswers.append(keepAlive.flags.rawValue) }
        case .rateControl:
            switch try? NanoRateHandshake(packet.payload) {
            case .syn?:
                syn = try? NanoRateHandshake(packet.payload)
                await send(type: 100, channel: 0, NanoRateHandshake.syn(version: 3, receiverLogSize: 14, initialSendSequence: 100, controllerType: 5, retry: 0).encoded())
            case .synAck?:
                await send(type: 100, channel: 0, NanoRateHandshake.synAckOfAck.encoded())
                if stallsAfterHandshake {
                    pump?.cancel()
                    resender?.cancel()
                    return
                }
                if !started {
                    started = true
                    for _ in 0..<8 { await data(type: 104, channel: 0, Data(count: 1000)) }
                    await create(1024, legacy ? "Messaging,0,4,workflow=launcher" : "Messaging,0,4,ScenarioId=DeviceConnection")
                }
            default: break
            }
        case .rateControlNoData, .channelData, .muxControl:
            guard let header = try? NanoRateHeader(packet.payload) else { return }
            if let ack = header.ack {
                // Everything up to the number named, arrived or not: that is the real phone.
                for sequence in Array(unacknowledged.keys) where Int16(bitPattern: ack.sequence &- sequence) >= 0 { settle(sequence) }
            }
            if let vector = header.ackVector { await apply(vector) }
            if let limit = header.ackOfAcks { macInbound.noteAckOfAcks(limit) }
            guard let sequence = header.dataSequence else { return }
            // Acknowledge at once: plainly up to the first missing one, else what is missing.
            let time = (ContinuousClock.now - began).microseconds
            let arrival = macInbound.noteData(sequence, at: time)
            while let ack = macInbound.takeAck(at: time) {
                await send(type: 35, channel: 0, NanoRateHeader(logWindowSize: 12, ack: ack, ackOfAcks: lowestOutstanding).encoded())
            }
            if arrival != .repeated, let report = macInbound.vector(at: time) {
                await send(type: 35, channel: 0, NanoRateHeader(logWindowSize: 12, ackOfAcks: lowestOutstanding, ackVector: report.vector).encoded())
            }
            guard seen.insert(sequence).inserted else { duplicateData += 1; return }
            let body = Data(packet.payload.dropFirst(header.length))
            let channel = packet.header.channelId
            if packet.header.kind == .rateControlNoData { fillerSeen += 1; return }
            if packet.header.kind == .muxControl {
                switch try? NanoMuxControl(body) {
                case .open?:
                    guard opened.insert(channel).inserted else { return }
                    if channel == 1032 {
                        let offer = NanoAudioPacket.serverHandshake(version: 7, referenceTime: 1, formats: [NanoAudioFormat(channels: 2, sampleRate: 48_000)])
                        await channelPacket(channel, offer.encoded(), type: offer.payloadType)
                    } else if channel == 1030 {
                        // The screen's input channel: the size of the screen and where input frames start.
                        await channelPacket(channel, NanoInputPacket.serverHandshake(version: 4, capabilities: 8, width: 1080, height: 2400, maxTouches: 10, firstFrameId: 500).encoded())
                    } else if channel == 1031 {
                        await channelPacket(channel, NanoVideoPacket.serverHandshake(version: 6, width: 720, height: 1600, framesPerSecond: 60, referenceTime: 1,
                                                                                     formats: [NanoVideoFormat(framesPerSecond: 60, width: 720, height: 1600)]).encoded())
                    }
                    else if channel == 1026 { await channelPacket(channel, NanoBlobPacket.handshake(minVersion: 2, maxVersion: 3).encoded()) }
                    else { await channelPacket(channel, NanoMessagePacket.handshake(version: 1).encoded()) }
                case .close?:
                    guard closed.insert(channel).inserted else { return }
                    await data(type: 97, channel: channel, NanoMuxControl.close(reason: 0).encoded())
                default: break
                }
                return
            }
            // A repeat of a channel packet comes under a new number; its own number tells.
            guard seenInner[channel, default: []].insert(packet.innerSequence).inserted else { duplicateData += 1; return }
            let inside = Data(body.dropFirst(NanoSequencerHeader.length))
            if channel == 1032 {
                guard let audio = try? NanoAudioPacket(payloadType: packet.header.payloadType, inside) else { return }
                audioPacketsFromPC.append(audio)
                if audio == .control(flags: NanoAudioPacket.startStream) {
                    for (index, frame) in ScriptedNanoPhone.soundFrames.enumerated() {
                        let data = NanoAudioPacket.data(flags: 0, frameId: UInt32(index), timestamp: Int64(index) * 40_000, data: frame)
                        await channelPacket(1032, data.encoded(), type: data.payloadType)
                    }
                }
                return
            }
            if channel == 1030 {
                if case .frame(let id, _, let frame)? = try? NanoInputPacket(inside) { inputFramesFromPC.append((id, frame)) }
                return
            }
            if channel == 1031 {
                guard let video = try? NanoVideoPacket(inside) else { return }
                videoPacketsFromPC.append(video)
                if case .clientHandshake(let first, _) = video { firstVideoFrame = first }
                if case .control(let flags, _) = video, flags & NanoVideoPacket.Control.startStream != 0 {
                    videoStartsAsked += 1
                    if !(startsLocked || staysDark) || (answersASecondStart && videoStartsAsked > 1) { await sendScreenFrames() }
                }
                return
            }
            if channel == 1026 {
                guard let blob = try? NanoBlobPacket(inside) else { return }
                if case .data = blob { piecesFromPC += 1 } else { blobPacketsFromPC.append(blob) }
                await receiveFromPC(blob)
                return
            }
            guard let parsed = try? NanoMessagePacket(inside) else { return }
            if case .handshake = parsed {
                handshakes.insert(channel)
                if channel == 1025, !offered, !legacy, channelRequest?.scenarioID != NanoFileReceiver.storageScenarioId {
                    offered = true
                    var offer = FileTransfer_V1_FileShareMessage()
                    offer.transferID = transferId
                    offer.scenario = "FileTransferToPc"
                    offer.sessionTryCount = 1
                    offer.content = files.map { file in
                        var item = FileTransfer_V1_FileShareContentMessage()
                        item.fileID = file.id; item.fileName = file.name; item.fileSize = Int64(file.data.count); item.fileStatus = .inProgress
                        return item
                    }
                    await message(1025, path: "/\(NanoFileReceiver.scenarioId)/NamedStreams/fileTransfer/platform", try! offer.serializedData())
                }
                return
            }
            var assembler = assemblers[channel] ?? NanoMessageAssembler()
            let whole = assembler.add(parsed)
            assemblers[channel] = assembler
            guard let whole else { return }
            if legacy {
                guard let object = try? JSONSerialization.jsonObject(with: whole.body) as? [String: Any] else { return }
                if whole.path == "/workflow", object["workflow"] as? String == "permission" {
                    workflowsAsked.append("permission")
                    await create(1025, "Messaging,1,4,workflow=permission")
                } else if whole.path == "/workflow", object["workflow"] as? String == "audio" {
                    workflowsAsked.append("audio")
                    await create(1033, "Messaging,2,4,workflow=audio")
                } else if whole.path == "/audio/pcStreamingAllowed" {
                    await message(1033, path: "/audio/phoneConfig", Data(#"{"frameLengthMs":40}"#.utf8))
                    await create(1032, "Audio,8,7,packageName=yourphone.phonescreen&syncId=yourphone.phonescreen&workflow=audio")
                } else if whole.path.hasPrefix("/permission/") {
                    permissionRequests.append(whole.path + " " + (object["permission"] as? String ?? ""))
                    if whole.path == "/permission/requestPermission" {
                        // The real phone asks its user, and says so meanwhile.
                        await message(1025, path: "/permission/permissionStatus", Data(#"{"status":"inProgress"}"#.utf8))
                        await message(1025, path: "/permission/permissionStatus", Data((deniesScreen ? #"{"status":"deny"}"# : #"{"status":"accept"}"#).utf8))
                    }
                } else if whole.path == "/workflow", object["workflow"] as? String == "earlyLaunch" {
                    workflowsAsked.append("earlyLaunch")
                    await create(1035, "Messaging,5,4,workflow=earlyLaunch")
                } else if whole.path == "/mirror/phone/launchNotification" {
                    mirrorRequests.append((whole.path, object))
                    guard let result = notificationLaunchResult else { return }
                    // An answer to another request first, as a phone with two computers might send.
                    await message(1035, path: "/mirror/phone/launchNotificationResult", Data(#"{"transactionId":"someone-else","launchResult":2}"#.utf8))
                    await message(1035, path: "/mirror/phone/launchNotificationResult",
                                  try! JSONSerialization.data(withJSONObject: ["transactionId": object["transactionId"] as? String ?? "", "launchResult": result]))
                } else if whole.path == "/workflow", object["workflow"] as? String == "remote" {
                    workflowsAsked.append("remote")
                    await create(1027, "Messaging,3,4,type=orchestrator&workflow=remote")
                } else if whole.path == "/mirror/phone/disconnectingResult" {
                    closingAnswers.append(object["transactionId"] as? String ?? "")
                } else if whole.path.hasPrefix("/mirror/phone/") {
                    mirrorRequests.append((whole.path, object))
                    if whole.path == "/mirror/phone/launchApp" {
                        let session = object["sessionId"] as? String ?? ""
                        await message(1027, path: "/mirror/phone/setLockedState", Data("{\"isLocked\":\(startsLocked),\"isScreenOn\":true,\"isSecureLocked\":\(startsLocked)}".utf8))
                        await message(1027, path: "/mirror/phone/appLaunchResult", try! JSONSerialization.data(withJSONObject: ["result": "success", "sessionId": session]))
                        let properties = "packageName=yourphone.phonescreen&sessionId=\(session)&setId=phonescreen&type=container&workflow=remote"
                        await create(1028, "Messaging,4,4,\(properties)")
                        await create(1030, "Input,6,2,\(properties)")
                        await create(1031, "Video,7,1,\(properties)")
                        await message(1027, path: "/mirror/phone/requestBlackScreenState", Data("null".utf8))
                    }
                } else if whole.path == "/stopWorkflow" {
                    workflowsStopped.append(object["workflow"] as? String ?? "")
                } else if whole.path == "/workflow" {
                    workflowRequest = object
                    await create(1025, "Messaging,1,4,workflow=fileTransfer")
                    await create(1026, "Blob,2,5,workflow=fileTransfer")
                } else if whole.path == "/fileTransfer" {
                    legacyRequests.append(object)
                    let content = object["Content"] as? [[String: Any]] ?? []
                    if object["Scenario"] as? String == "FileTransferToPhone" {
                        // The PC offers files: taken one at a time, as the real phone takes them.
                        pcOffer = object
                        if rejectsOffers {
                            await message(1025, path: "/fileTransfer", try! JSONSerialization.data(withJSONObject: ["Scenario": "FileTransferToPhoneRejected"]))
                        } else {
                            await askPCForNextFile()
                        }
                    } else if object["Scenario"] as? String == "FileTransferToPcFile" {
                        // Send the one file marked "wanted now".
                        for item in content where (item["FileStatus"] as? NSNumber)?.intValue == 2 {
                            guard let file = files.first(where: { $0.id == item["FileId"] as? String }) else { continue }
                            await sendBlob(file)
                        }
                    } else if object["Scenario"] as? String == "FileTransferToPcCompleted" {
                        let answer: [String: Any] = ["Scenario": "FileTransferToPcCompleted", "TransferId": transferId, "SessionTryCount": 1]
                        await message(1025, path: "/fileTransfer", try! JSONSerialization.data(withJSONObject: answer))
                    }
                }
                return
            }
            if whole.path == "/Channel/ProtoCreatePlatformChannelRequest" {
                channelRequest = try? PlatformSdk_V1_ProtoCreatePlatformChannelRequest(serializedBytes: whole.body)
                var result = PlatformSdk_V1_ProtoPeerPlatformChannelCreationResult()
                result.type = .namedStreamsChannel
                result.scenarioID = channelRequest?.scenarioID ?? ""
                result.channelID = channelRequest?.channelID ?? ""
                result.resultCode = refuseChannel ? .remoteScenarioRejectedChannel : .success
                result.resultReason = refuseChannel ? .permissionRevoked : .success
                await message(1024, path: "/Channel/ProtoPeerPlatformChannelCreationResult", try! result.serializedData())
                guard !refuseChannel else { return }
                // The channels carry the scenario that was asked for: a share, or a file of the storage.
                let scenario = channelRequest?.scenarioID ?? NanoFileReceiver.scenarioId
                await create(1025, "Messaging,1,4,ConsumerId=c0ffee&ScenarioId=\(scenario)")
                await create(1026, "Blob,2,5,ConsumerId=c0ffee&ScenarioId=\(scenario)")
            } else if whole.path.hasSuffix("/ManifestRequest") {
                manifest = try? PlatformSdk_V1_ProtoManifest(serializedBytes: whole.body)
                manifestPath = whole.path
                for file in files where manifest?.entries[file.id] != nil { await sendBlob(file) }
                if channelRequest?.scenarioID == NanoFileReceiver.storageScenarioId, !silentAboutManifests {
                    // A file the phone cannot open: it says so, as its storage code does.
                    for id in (manifest?.entries.keys.sorted() ?? []) where !files.contains(where: { $0.id == id }) {
                        var problem = PhoneFiles_V1_FilesStreamsMessage()
                        problem.fileUri = id
                        problem.streamMessageStatus = .errorFileNotFound
                        await message(1025, path: "/\(NanoFileReceiver.storageScenarioId)/NamedStreams/com.microsoft.mmx.agents.files.transport.files_stream_error", try! problem.serializedData())
                    }
                }
            } else if whole.path.hasSuffix("/NamedStreams/fileTransfer/platform") {
                completed = try? FileTransfer_V1_FileShareMessage(serializedBytes: whole.body)
                var answer = FileTransfer_V1_FileShareMessage()
                answer.transferID = transferId
                answer.scenario = "FileTransferToPcCompleted"
                answer.sessionTryCount = 1
                await message(1025, path: whole.path, try! answer.serializedData())
            }
        default:
            break
        }
    }
}

final class NanoConnectionTests: XCTestCase {
    static let keys = try! NanoSessionKeys(keyHex: "000102030405060708090a0b0c0d0e0f", saltHex: "101112131415161718191a1b1c1d")

    func settings() -> NanoConnection.Settings {
        var settings = NanoConnection.Settings()
        settings.fillerCount = 10
        settings.handshakeRetry = .milliseconds(200)
        settings.retransmitAfter = .milliseconds(80)
        return settings
    }

    func file(_ id: String, _ name: String, bytes: Int) -> ScriptedNanoPhone.File {
        .init(id: id, name: name, data: Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 / 251) }))
    }

    func testAShareIsReceivedFromStartSequenceToCompletion() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let files = [file("11111111-aaaa", "Report.pdf", bytes: 60_559), file("22222222-bbbb", "photo.jpg", bytes: 3000)]
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: files)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let progress = ProgressLog()
        let receiver = NanoFileReceiver(connection: connection, senderName: "Test Mac") { await progress.add($0) }
        let received = try await receiver.run(timeout: .seconds(10))

        XCTAssertEqual(received.map(\.name), ["Report.pdf", "photo.jpg"])
        XCTAssertEqual(received.map(\.data), files.map(\.data), "every byte, in place")

        // The start sequence, as Windows does it.
        let probes = await phone.probesSeen, reports = await phone.reportsSeen, answers = await phone.keepAliveAnswers, syn = await phone.syn
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(reports, [1458], "the phone's own probe is answered with its size, as Windows answered it; the phone waits for that")
        XCTAssertEqual(answers.first, 0x12)
        XCTAssertEqual(syn, .syn(version: 3, receiverLogSize: 14, initialSendSequence: 100, controllerType: 5, retry: 0))
        let filler = await phone.fillerSeen
        XCTAssertEqual(filler, 10)

        // The three things the PC contributes to the exchange.
        let request = await phone.channelRequest
        XCTAssertEqual(request?.type, .namedStreamsChannel)
        XCTAssertEqual(request?.scenarioID, "fileShare_2B0F3A34-0C30-4CC0-8165-87FC30DB1E35")
        XCTAssertEqual(request?.channelID.count, 36)
        XCTAssertEqual(request?.hasTraceContext, true)
        let manifest = await phone.manifest
        XCTAssertEqual(manifest?.entries.keys.sorted(), ["11111111-aaaa", "22222222-bbbb"])
        XCTAssertEqual(manifest?.entries["11111111-aaaa"]?.size, 60_559)
        let completed = await phone.completed
        XCTAssertEqual(completed?.scenario, "FileTransferToPcCompleted")
        XCTAssertEqual(completed?.senderName, "Test Mac")
        XCTAssertEqual(completed?.receivedFileCount, 2)
        XCTAssertEqual(completed?.content.map(\.fileStatus), [.completed, .completed])
        XCTAssertEqual(completed?.transferID, "0123456789abcdef0123456789abcdef")
        let blobReplies = await phone.blobPacketsFromPC
        XCTAssertEqual(blobReplies.first, .handshake(minVersion: 2, maxVersion: 3))
        XCTAssertTrue(blobReplies.contains(.completion(kind: 4, name: "11111111-aaaa")))
        XCTAssertTrue(blobReplies.contains(.written(queued: 0, name: "22222222-bbbb")))
        // Channels were accepted, greeted and closed at the end.
        let opened = await phone.opened, closed = await phone.closed, greeted = await phone.handshakes
        XCTAssertEqual(opened, [1024, 1025, 1026])
        XCTAssertEqual(greeted, [1024, 1025])
        XCTAssertEqual(closed, [1025, 1026])
        let steps = await progress.items
        XCTAssertEqual(steps.first, .offered(names: ["Report.pdf", "photo.jpg"], totalBytes: 63_559))
        XCTAssertTrue(steps.contains(.received(received[0])))
        await connection.close()
    }

    /// The exchange toward the Phone Link client: launcher, one request per file, completion.
    /// A file of the phone's storage, asked for by its address: the exchange of a share
    /// without the offer, under the storage's own scenario. From the phone's code.
    func testAFileOfThePhonesStorageIsFetchedByItsAddress() async throws {
        let uri = "content://media/external/file/4711"
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let stored = file(uri, "ignored by the phone", bytes: 250_123)
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [stored])
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let progress = ProgressLog()
        let receiver = NanoFileReceiver(connection: connection, senderName: "Test Mac") { await progress.add($0) }
        let received = try await receiver.fetch(.init(uri: uri, name: "Lease.pdf", size: 250_123), timeout: .seconds(10))
        XCTAssertEqual(received.map(\.name), ["Lease.pdf"], "under the name the list gave it")
        XCTAssertEqual(received.first?.data, stored.data)

        let request = await phone.channelRequest
        XCTAssertEqual(request?.type, .namedStreamsChannel)
        XCTAssertEqual(request?.scenarioID, "fileTransfer_1EAA053C-0354-4DF8-AA05-888312CCC57E")
        let manifest = await phone.manifest, path = await phone.manifestPath
        XCTAssertEqual(path, "/fileTransfer_1EAA053C-0354-4DF8-AA05-888312CCC57E/ManifestRequest")
        XCTAssertEqual(manifest?.entries.keys.sorted(), [uri])
        XCTAssertEqual(manifest?.entries[uri]?.id, uri)
        XCTAssertEqual(manifest?.entries[uri]?.size, 250_123)
        let offered = await phone.completed
        XCTAssertNil(offered, "no share messages in this exchange")
        let blobReplies = await phone.blobPacketsFromPC
        XCTAssertTrue(blobReplies.contains(.completion(kind: 4, name: uri)))
        let closed = await waitUntil { await phone.closed.contains(1025) }
        XCTAssertTrue(closed, "the scenario's channels are closed at the end")
        await connection.close()
    }

    func testAStorageFileThePhoneCannotGiveEndsWithItsReason() async throws {
        // Not there any more.
        var (mac, phoneSide) = MemoryNanoTransport.pair()
        var phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.run()
        var connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        do {
            _ = try await NanoFileReceiver(connection: connection, senderName: "Test Mac").fetch(.init(uri: "content://media/external/file/1", name: "gone.txt", size: 5), timeout: .seconds(10))
            XCTFail("a file that is not there arrived")
        } catch {
            XCTAssertEqual(error as? NanoFileReceiver.ReceiveError, .refused("the phone could not read the file (2)"))
        }
        await connection.close()
        // The empty stream the phone sends for a file it cannot open is no file, whatever
        // the list said its size was.
        (mac, phoneSide) = MemoryNanoTransport.pair()
        phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [file("content://media/external/file/2", "x", bytes: 0)])
        await phone.run()
        connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        do {
            _ = try await NanoFileReceiver(connection: connection, senderName: "Test Mac").fetch(.init(uri: "content://media/external/file/2", name: "b.txt", size: 700), timeout: .seconds(10))
            XCTFail("nothing was taken for a file")
        } catch {
            XCTAssertEqual(error as? NanoFileReceiver.ReceiveError, .refused("the phone sent nothing for the file"))
        }
        await connection.close()
        // A phone that goes quiet in the middle: given up after the quiet time, not sooner.
        (mac, phoneSide) = MemoryNanoTransport.pair()
        phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.setRefuse(false)
        await phone.setSilentAboutManifests(true)
        await phone.run()
        connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let began = ContinuousClock.now
        do {
            _ = try await NanoFileReceiver(connection: connection, senderName: "Test Mac").fetch(.init(uri: "content://media/external/file/3", name: "c.txt", size: 5), timeout: .seconds(1))
            XCTFail("a file from a silent phone")
        } catch {
            guard case .connectionLost? = error as? NanoFileReceiver.ReceiveError else { return XCTFail("\(error)") }
        }
        XCTAssertGreaterThan(ContinuousClock.now - began, .milliseconds(900))
        // The phone's user has taken the permission away: the channel itself is refused.
        (mac, phoneSide) = MemoryNanoTransport.pair()
        phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.setRefuse(true)
        await phone.run()
        connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        do {
            _ = try await NanoFileReceiver(connection: connection, senderName: "Test Mac").fetch(.init(uri: "content://media/external/file/1", name: "a.txt", size: 5), timeout: .seconds(10))
            XCTFail("a refused channel gave a file")
        } catch {
            guard case .refused? = error as? NanoFileReceiver.ReceiveError else { return XCTFail("\(error)") }
        }
        await connection.close()
    }

    func testAShareOfferedToThePhoneLinkClientIsFetchedFileByFile() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let files = [file("aaaa-1", "First.pdf", bytes: 7000), file("bbbb-2", "Second.jpg", bytes: 2500)]
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: files)
        await phone.setLegacy(true)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let detail = #"{"TransferId":"0123456789abcdef0123456789abcdef","Scenario":"FileTransferToPc","SenderName":"","ReceivedFileCount":0,"SessionTryCount":1,"Content":[{"FileId":"aaaa-1","FileName":"First.pdf","FileSize":7000,"FileHash":"","FileStatus":1},{"FileId":"bbbb-2","FileName":"Second.jpg","FileSize":2500,"FileHash":"","FileStatus":1}]}"#
        let offer = try XCTUnwrap(LegacyFileOffer(json: detail))
        XCTAssertEqual(offer.items.map(\.name), ["First.pdf", "Second.jpg"])
        XCTAssertEqual(offer.sessionTryCount, 1)
        XCTAssertNil(LegacyFileOffer(json: detail.replacingOccurrences(of: "FileTransferToPc\"", with: "FileTransferToPhone\"")), "only an offer toward the PC")

        let received = try await NanoFileReceiver(connection: connection, senderName: "Test Mac").run(offer: offer, timeout: .seconds(10))
        XCTAssertEqual(received.map(\.name), ["First.pdf", "Second.jpg"])
        XCTAssertEqual(received.map(\.data), files.map(\.data))
        let workflow = await phone.workflowName
        XCTAssertEqual(workflow, "fileTransfer", "asked for on the launcher channel")
        let scenarios = await phone.legacyScenarios
        XCTAssertEqual(scenarios, ["FileTransferToPcFile", "FileTransferToPcFile", "FileTransferToPcCompleted"], "one request per file, then the end")
        let statuses = await phone.lastLegacyStatuses, folder = await phone.lastLegacyFolder
        XCTAssertEqual(statuses, [3, 3], "the phone checks that every file it offered is marked received")
        XCTAssertEqual(folder, "Downloads")
        let reports = await phone.blobPacketsFromPC
        XCTAssertTrue(reports.contains(.completion(kind: 4, name: "aaaa-1")))
        await connection.close()
    }

    /// Loss in the direction that matters for a large file: the phone's pieces. A lost packet
    /// is never acknowledged, the phone sends its content again under a new number, and the
    /// file, which spans several segments, still comes out whole.
    func testPiecesLostOnTheWayFromThePhoneArriveWhenSentAgain() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let counter = Counter()
        phoneSide.shouldDeliver = { _ in
            let n = counter.next()
            return n < 40 || n % 9 != 0
        }
        let files = [file("55555555-eeee", "clip.mp4", bytes: 400_000)]
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: files)
        await phone.setLegacy(true)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let offer = LegacyFileOffer(transferId: "0123456789abcdef0123456789abcdef", items: [.init(id: "55555555-eeee", name: "clip.mp4", size: 400_000)])
        let received = try await NanoFileReceiver(connection: connection, senderName: "Test Mac").run(offer: offer, timeout: .seconds(30))
        XCTAssertEqual(received.map(\.data), files.map(\.data), "every byte, although one datagram in nine was lost")
        let resent = await phone.resent
        XCTAssertGreaterThan(resent, 20, "the phone had to send the lost ones again")
        let contradictions = await phone.contradictions
        XCTAssertEqual(contradictions, 0, "no report called missing what an earlier one had acknowledged")
        await connection.close()
    }

    /// The phone's quick way of noticing loss, alone: it sends again only what a report of
    /// missing packets names. Without such reports nothing lost would ever come.
    func testMissingPacketsAreReportedAndThePhoneSendsThemAgain() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let counter = Counter()
        // Single losses, and a run of twenty-five in a row.
        phoneSide.shouldDeliver = { _ in
            let n = counter.next()
            return n < 40 || (n % 13 != 0 && !(150..<175).contains(n))
        }
        let files = [file("66666666-ffff", "clip.mp4", bytes: 400_000)]
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: files)
        await phone.setLegacy(true)
        await phone.setRecovery(vectors: true, timer: false)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let offer = LegacyFileOffer(transferId: "0123456789abcdef0123456789abcdef", items: [.init(id: "66666666-ffff", name: "clip.mp4", size: 400_000)])
        let received = try await NanoFileReceiver(connection: connection, senderName: "Test Mac").run(offer: offer, timeout: .seconds(30))
        XCTAssertEqual(received.map(\.data), files.map(\.data))
        let (vectors, resent, onTimer, contradictions) = await (phone.vectorsSeen, phone.resent, phone.resentOnTimer, phone.contradictions)
        XCTAssertGreaterThan(vectors, 20)
        XCTAssertGreaterThan(resent, 40)
        XCTAssertEqual(onTimer, 0)
        XCTAssertEqual(contradictions, 0)
        await connection.close()
    }

    /// A socket the system shuts at once, as macOS does while it checks the app's access to
    /// the local network: every send fails as "blocked".
    final class ShutTransport: NanoDatagramTransport, @unchecked Sendable {
        let incoming: AsyncStream<Data>
        private let end: AsyncStream<Data>.Continuation
        init() { (incoming, end) = AsyncStream.makeStream(of: Data.self) }
        func send(_ datagram: Data) async throws { throw NanoSocketTransport.SocketError.blocked }
        func close() { end.finish() }
    }

    func testASocketShutByTheSystemIsTriedAgainAndThenReported() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.run()
        // Shut twice, then let through: the connection comes up on the third socket.
        let tries = Counter()
        let connection = try await PhoneFileReceiver.open(host: "192.0.2.1", port: 9, keys: Self.keys, settings: settings()) { _, _ in
            let shut: NanoDatagramTransport = ShutTransport()
            return tries.next() < 3 ? shut : mac
        }
        XCTAssertEqual(tries.next(), 4, "three sockets were opened")
        await connection.close()
        // Shut every time: the caller is told so, in words that say what to do about it.
        do {
            _ = try await PhoneFileReceiver.open(host: "192.0.2.1", port: 9, keys: Self.keys, settings: settings()) { _, _ in ShutTransport() }
            XCTFail("a connection came up over sockets that were all shut")
        } catch {
            XCTAssertEqual(error as? NanoSocketTransport.SocketError, .blocked)
            XCTAssertTrue(PhoneFileReceiver.describe(error).contains("Local Network"))
            XCTAssertTrue(PhoneScreenMirror.describe(error).contains("Local Network"))
        }
    }

    // MARK: The phone's screen

    actor MirrorLog {
        var events: [String] = [], frames: [NanoVideoFrame] = [], sound: [Data] = []
        func add(_ event: NanoMirrorSession.Event) {
            switch event {
            case .waitingForPermission: events.append("waiting")
            case .started(let format): events.append("video \(format.width)x\(format.height)")
            case .frame(let frame): frames.append(frame)
            case .locked(let locked): events.append("locked \(locked)")
            case .protectedContent(let protected): events.append("protected \(protected)")
            case .inputSize(let width, let height): events.append("input \(width)x\(height)")
            case .rotation(let turns): events.append("turned \(turns)")
            case .soundStarted(let format): events.append("sound \(format.channels)ch \(format.sampleRate)")
            case .sound(let data): sound.append(data)
            }
        }
    }

    /// The whole exchange for showing the screen: consent, the request for the screen, video
    /// frames in, pointer frames out, and the stop.
    func testThePhonesScreenIsShownAndThePointerActsOnIt() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.setLegacy(true)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let log = MirrorLog()
        let session = NanoMirrorSession(connection: connection) { await log.add($0) }
        let running = Task { try await session.run() }
        // Until the frames of the scripted stream are all here.
        for _ in 0..<200 where await log.frames.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        let frames = await log.frames
        XCTAssertEqual(frames.map(\.data), ScriptedNanoPhone.screenFrames.map(\.data), "every frame, put together from its pieces")
        XCTAssertEqual(frames.map(\.isKeyframe), [true, true, false])
        let events = await log.events
        XCTAssertEqual(events.first, "waiting", "the phone asks its user first")
        XCTAssertTrue(events.contains("video 720x1600"))
        XCTAssertTrue(events.contains("input 1080x2400"))
        // What Windows asked for, in its order and words.
        let asked = await phone.workflowsAsked
        XCTAssertEqual(asked, ["permission", "remote"])
        let requests = await phone.mirrorRequests
        XCTAssertEqual(requests.map(\.path).prefix(3), ["/mirror/phone/config", "/mirror/phone/alwaysInExpandedLayoutChanged", "/mirror/phone/launchApp"])
        XCTAssertEqual(requests[2].object["packageName"] as? String, "yourphone.phonescreen")
        XCTAssertEqual((requests[2].object["flags"] as? NSNumber)?.intValue, 3)
        XCTAssertTrue(requests.contains { $0.path == "/mirror/phone/blackScreen" }, "the phone's question about its own display is answered")
        // The video channel: the format is taken, the stream started with a whole frame, every frame reported.
        let video = await phone.videoPacketsFromPC
        guard case .clientHandshake(_, let format)? = video.first else { return XCTFail("no answer to the video offer") }
        XCTAssertEqual(format, NanoVideoFormat(framesPerSecond: 60, width: 720, height: 1600))
        XCTAssertTrue(video.contains(.start()))
        XCTAssertEqual(video.filter { if case .control(let flags, _) = $0 { return flags == 0x81 } else { return false } }.count, 3)
        // The pointer: a press at a place, a drag, a release, a turn of the wheel.
        await session.pointer(x: 1041, y: 620, pressed: true)
        await session.pointer(x: 900, y: 620, pressed: true)
        await session.pointer(x: 900, y: 620, pressed: false)
        await session.pointer(x: 5000, y: -3, pressed: false, wheelY: -240)
        for _ in 0..<100 where await phone.inputFramesFromPC.count < 4 { try await Task.sleep(for: .milliseconds(20)) }
        let input = await phone.inputFramesFromPC
        XCTAssertEqual(input.map(\.id), [501, 502, 503, 504], "numbered on from the phone's offer")
        XCTAssertEqual(input.first?.body.hex, "000100000000" + "0001" + "00000000000000" + "11040000" + "6c020000" + "00000000" + "00000000" + "0000000000000000")
        XCTAssertEqual(input[2].body[7], 2, "a button counts its presses and releases")
        XCTAssertEqual(input[3].body.hex, "000100000000" + "0002" + "00000000000000" + "37040000" + "00000000" + "00000000" + "10ffffff" + "0000000000000000",
                       "kept inside the screen; the wheel adds up")
        // The other buttons, then keys: Back as the recording has it, and a letter held and let go.
        await session.pointer(x: 10, y: 10, pressed: false, rightPressed: true)
        await session.pointer(x: 10, y: 10, pressed: false, rightPressed: false, middlePressed: true)
        await session.key(NanoKey.back, pressed: true)
        await session.key(NanoKey.back, pressed: true)
        await session.key(NanoKey.back, pressed: false)
        await session.key(0x04, pressed: true)
        for _ in 0..<100 where await phone.inputFramesFromPC.count < 9 { try await Task.sleep(for: .milliseconds(20)) }
        let more = await phone.inputFramesFromPC
        XCTAssertEqual(more.count, 9, "a key reported down twice is sent once")
        XCTAssertEqual(more[4].body.prefix(10).hex, "000100000000" + "00020001", "the right button is the third of the entry")
        XCTAssertEqual(more[5].body.prefix(10).hex, "000100000000" + "00020102")
        XCTAssertEqual(more[6].body.hex, "000000010000" + "00016e01" + "0000000000000000", "as recorded from the window's Back button")
        XCTAssertEqual(more[7].body.hex, "000000010000" + "00016e02" + "0000000000000000")
        XCTAssertEqual(more[8].body.hex, "000000010000" + "00010401" + "0000000000000000")
        // Home is a swipe up from the bottom edge: a press there, a way up, a release.
        await session.gesture(.home)
        for _ in 0..<100 where await phone.inputFramesFromPC.count < 20 { try await Task.sleep(for: .milliseconds(20)) }
        let swipe = Array(await phone.inputFramesFromPC.dropFirst(9)).map(\.body)
        func place(_ body: Data) -> (x: Int, y: Int, held: Bool) {
            (Int(body[15]) | Int(body[16]) << 8, Int(body[19]) | Int(body[20]) << 8, body[7] % 2 == 1)
        }
        XCTAssertEqual(swipe.count, 11, "there, down, eight steps, up")
        XCTAssertEqual(place(swipe[0]).y, 2398)
        XCTAssertFalse(place(swipe[0]).held)
        XCTAssertTrue(swipe[1...9].allSatisfy { place($0).held })
        XCTAssertEqual(swipe.map { place($0).x }, Array(repeating: 540, count: 11), "straight up the middle")
        XCTAssertEqual(swipe.map { place($0).y }.dropFirst(2), swipe.map { place($0).y }.dropFirst(2).sorted(by: >)[...], "ever higher")
        XCTAssertEqual(place(swipe[10]).y, 1080)
        XCTAssertFalse(place(swipe[10]).held)
        await session.stop()
        try await running.value
        let stopped = await phone.workflowsStopped
        XCTAssertEqual(stopped, ["permission", "remote"])
    }

    /// With sound wanted, and one app instead of the whole screen: the questions about sound,
    /// the audio workflow, the answer to the phone's offer, and the frames of sound.
    /// A phone that is locked is asked to wake: once by itself when it says so, and again
    /// when the user clicks or types on the picture, but not at every move of the mouse.
    func testALockedPhoneIsAskedToWake() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.setLegacy(true)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let log = MirrorLog()
        let session = NanoMirrorSession(connection: connection) { await log.add($0) }
        let running = Task { try await session.run() }
        for _ in 0..<200 where await log.frames.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        func wakes() async -> Int { await phone.mirrorRequests.filter { $0.path == "/mirror/phone/wakeScreen" }.count }
        let before = await wakes()
        XCTAssertEqual(before, 0, "an unlocked phone is left alone")
        // A click on an unlocked phone is just a click.
        await session.pointer(x: 10, y: 10, pressed: true)
        await session.pointer(x: 10, y: 10, pressed: false)

        await phone.setLocked(true)
        let asked = await waitUntil { await wakes() == 1 }
        XCTAssertTrue(asked, "asked once, unprompted")
        let body = await phone.mirrorRequests.first { $0.path == "/mirror/phone/wakeScreen" }?.object
        XCTAssertEqual(body?.count, 0, "an empty object, as Phone Link sends")
        let events = await log.events
        XCTAssertTrue(events.contains("locked true"))
        // Clicks and keys right after do not pile up more requests.
        await session.pointer(x: 10, y: 10, pressed: true)
        await session.pointer(x: 10, y: 10, pressed: false)
        await session.key(4, pressed: true)
        await session.key(4, pressed: false)
        try await Task.sleep(for: .milliseconds(200))
        let soon = await wakes()
        XCTAssertEqual(soon, 1)
        // Later, a click on the still-locked picture asks again; moving the pointer does not.
        try await Task.sleep(for: .milliseconds(2000))
        await session.pointer(x: 20, y: 20, pressed: false)
        try await Task.sleep(for: .milliseconds(150))
        let afterMove = await wakes()
        XCTAssertEqual(afterMove, 1)
        await session.pointer(x: 20, y: 20, pressed: true)
        await session.pointer(x: 20, y: 20, pressed: false)
        let again = await waitUntil { await wakes() == 2 }
        XCTAssertTrue(again)
        // Unlocked: clicks are clicks again.
        await phone.setLocked(false)
        // A bank's app comes up, and goes: the window is told both.
        await phone.setProtected(true)
        let protected = await waitUntil { await log.events.contains("protected true") }
        XCTAssertTrue(protected, "an app that protects its screen is reported")
        await phone.setProtected(false)
        let unprotected = await waitUntil { await log.events.contains("protected false") }
        XCTAssertTrue(unprotected)
        _ = await waitUntil { await log.events.last == "locked false" }
        try await Task.sleep(for: .milliseconds(2100))
        await session.pointer(x: 30, y: 30, pressed: true)
        await session.pointer(x: 30, y: 30, pressed: false)
        try await Task.sleep(for: .milliseconds(150))
        let final = await wakes()
        XCTAssertEqual(final, 2)
        await session.stop()
        _ = try? await running.value
        await connection.close()
    }

    /// Turning, both ways the phone has for it (from its code and from Phone Link's; neither
    /// was in the recording): the whole screen comes in a new shape with a new size for
    /// positions; an app on its side keeps its picture and asks for it to be shown turned.
    func testThePictureFollowsThePhoneWhenItIsTurned() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.setLegacy(true)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let log = MirrorLog()
        let session = NanoMirrorSession(connection: connection) { await log.add($0) }
        let running = Task { try await session.run() }
        for _ in 0..<200 where await log.frames.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        let before = await log.events
        XCTAssertEqual(before.filter { $0.hasPrefix("input") }, ["input 1080x2400"])

        // The whole screen, turned on its side.
        await phone.turnScreen(width: 2400, height: 1080, pictureWidth: 1600, pictureHeight: 720)
        let turned = await waitUntil { let events = await log.events; return events.contains("input 2400x1080") && events.contains("video 1600x720") }
        XCTAssertTrue(turned, "the new size for positions, and the picture's new shape")
        // The new stream is answered and started like the first, and its frames arrive.
        let again = await waitUntil { await log.frames.count == 6 }
        XCTAssertTrue(again, "the frames of the new stream are shown")
        let offers = await phone.videoPacketsFromPC.compactMap { packet -> NanoVideoFormat? in
            if case .clientHandshake(_, let format) = packet { return format } else { return nil }
        }
        XCTAssertEqual(offers.map(\.width), [720, 1600])
        // Positions reach the whole of the new width and stop at the new height.
        let sent = await phone.inputFramesFromPC.count
        await session.pointer(x: 2300, y: 2000, pressed: false)
        _ = await waitUntil { await phone.inputFramesFromPC.count == sent + 1 }
        let frame = await phone.inputFramesFromPC.last?.body ?? Data()
        XCTAssertEqual(frame.subdata(in: 15..<23).hex, "fc080000" + "37040000", "2300 across, kept to 1079 down")
        // The same size said again is no news.
        await phone.turnScreen(width: 2400, height: 1080, pictureWidth: 1600, pictureHeight: 720)
        try await Task.sleep(for: .milliseconds(150))
        let inputs = await log.events.filter { $0.hasPrefix("input") }
        XCTAssertEqual(inputs, ["input 1080x2400", "input 2400x1080"])

        // Upright again, then an app that lies on its side: one quarter turn, and positions
        // are counted in the turned shape.
        await phone.turnScreen(width: 1080, height: 2400, pictureWidth: 720, pictureHeight: 1600)
        _ = await waitUntil { await log.events.last { $0.hasPrefix("input") } == "input 1080x2400" }
        await phone.turnApp(1)
        let quarter = await waitUntil { let events = await log.events; return events.contains("turned 1") && events.last { $0.hasPrefix("input") } == "input 2400x1080" }
        XCTAssertTrue(quarter)
        await phone.turnApp(1)
        await phone.turnApp(7)
        await phone.turnApp(0)
        let upright = await waitUntil { let events = await log.events; return events.last { $0.hasPrefix("turned") } == "turned 0" && events.last { $0.hasPrefix("input") } == "input 1080x2400" }
        XCTAssertTrue(upright)
        let turns = await log.events.filter { $0.hasPrefix("turned") }
        XCTAssertEqual(turns, ["turned 1", "turned 0"], "said twice, or something that is no quarter turn: nothing")
        await session.stop()
        _ = try? await running.value
        await connection.close()
    }

    /// Seen with the real phone: a session begun while it was locked got no picture, and none
    /// after it was unlocked. The stream is asked for again, and if nothing comes the session
    /// ends itself and says that it wants to be started afresh.
    /// Seen on 2026-10-10 in the evening: the session begun right after the unlock had all
    /// its channels, the phone awake, and no picture. It is asked for again, and failing
    /// that the session ends itself to be started afresh.
    func testAnAwakePhoneThatStaysDarkIsAskedAgainAndThenStartedAfresh() async throws {
        for answers in [true, false] {
            let (mac, phoneSide) = MemoryNanoTransport.pair()
            let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
            await phone.setLegacy(true)
            await phone.setStaysDark(true, answersASecondStart: answers)
            await phone.run()
            let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
            try await connection.start()
            let log = MirrorLog()
            var options = NanoMirrorSession.Options()
            options.pictureWait = .milliseconds(400)
            let session = NanoMirrorSession(connection: connection, options: options) { await log.add($0) }
            let running = Task { try await session.run() }
            let started = await waitUntil { await log.events.contains("video 720x1600") }
            XCTAssertTrue(started)
            let askedOnce = await phone.videoStartsAsked
            XCTAssertEqual(askedOnce, 1, "not asked again before the wait is over")
            if answers {
                let arrived = await waitUntil(timeout: 4) { await log.frames.count == 3 }
                XCTAssertTrue(arrived, "asking again brought the picture")
                try await Task.sleep(for: .milliseconds(1800))
                let wanted = await session.restartWanted
                XCTAssertFalse(wanted)
                await session.stop()
                _ = try? await running.value
            } else {
                _ = try await running.value
                let wanted = await session.restartWanted
                XCTAssertTrue(wanted, "still dark: started afresh")
            }
            let asked = await phone.videoStartsAsked
            XCTAssertEqual(asked, 2)
            await connection.close()
        }
        // A phone that shows its picture is left alone.
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.setLegacy(true)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        var options = NanoMirrorSession.Options()
        options.pictureWait = .milliseconds(300)
        let session = NanoMirrorSession(connection: connection, options: options) { _ in }
        let running = Task { try await session.run() }
        try await Task.sleep(for: .milliseconds(900))
        let asked = await phone.videoStartsAsked
        XCTAssertEqual(asked, 1)
        await session.stop()
        _ = try? await running.value
        await connection.close()
    }

    func testASessionBegunOnALockedPhoneRecoversItsPictureOrAsksForARestart() async throws {
        for answers in [true, false] {
            let (mac, phoneSide) = MemoryNanoTransport.pair()
            let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
            await phone.setLegacy(true)
            await phone.setStartsLocked(true, answersASecondStart: answers)
            await phone.run()
            let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
            try await connection.start()
            let log = MirrorLog()
            let session = NanoMirrorSession(connection: connection) { await log.add($0) }
            let running = Task { try await session.run() }
            let lockedSeen = await waitUntil { await log.events.contains("locked true") }
            XCTAssertTrue(lockedSeen)
            let woken = await waitUntil { await phone.mirrorRequests.contains { $0.path == "/mirror/phone/wakeScreen" } }
            XCTAssertTrue(woken, "a locked phone is asked to wake")
            try await Task.sleep(for: .milliseconds(300))
            let early = await log.frames.count
            XCTAssertEqual(early, 0, "no picture while locked")

            await phone.setLocked(false)
            if answers {
                let arrived = await waitUntil { await log.frames.count == 3 }
                XCTAssertTrue(arrived, "asking for the stream again brought the picture")
                try await Task.sleep(for: .milliseconds(1800))
                let wanted = await session.restartWanted
                XCTAssertFalse(wanted, "and then nothing is restarted")
                await session.stop()
                _ = try? await running.value
            } else {
                // Nothing comes: the session ends by itself, politely, within a few seconds.
                _ = try await running.value
                let wanted = await session.restartWanted
                XCTAssertTrue(wanted)
                let stopped = await phone.workflowsStopped
                XCTAssertTrue(stopped.contains("remote"), "ended as a stop from here ends it")
            }
            let asked = await phone.videoStartsAsked
            XCTAssertEqual(asked, 2, "the stream was asked for a second time")
            await connection.close()
        }
    }

    func testSoundComesAlongAndASingleAppCanBeAskedFor() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.setLegacy(true)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let log = MirrorLog()
        var options = NanoMirrorSession.Options()
        options.sound = true
        options.packageName = "com.example.notes"
        let session = NanoMirrorSession(connection: connection, options: options) { await log.add($0) }
        let running = Task { try await session.run() }
        for _ in 0..<200 where await log.sound.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let sound = await log.sound
        XCTAssertEqual(sound, ScriptedNanoPhone.soundFrames)
        let events = await log.events
        XCTAssertTrue(events.contains("sound 2ch 48000"))
        let asked = await phone.workflowsAsked
        XCTAssertEqual(asked, ["permission", "audio", "remote"], "sound before the screen, as Windows asks")
        let permissions = await phone.permissionRequests
        XCTAssertEqual(permissions, ["/permission/requestPermission screenScrape", "/permission/checkPermission oemAudio", "/permission/checkPermission audio",
                                     "/permission/showPermission audio"])
        let audio = await phone.audioPacketsFromPC
        guard case .clientHandshake(_, let format)? = audio.first else { return XCTFail("no answer to the sound offer") }
        XCTAssertEqual(format, NanoAudioFormat(channels: 2, sampleRate: 48_000))
        XCTAssertEqual(audio.last, .control(flags: NanoAudioPacket.startStream))
        let requests = await phone.mirrorRequests
        let launch = try XCTUnwrap(requests.first { $0.path == "/mirror/phone/launchApp" })
        XCTAssertEqual(launch.object["packageName"] as? String, "com.example.notes")
        XCTAssertEqual((launch.object["flags"] as? NSNumber)?.intValue, 0, "an app, not the whole screen: neither flag is set")
        // The app is closed on the phone: the phone says so, is answered, and the mirroring ends by itself.
        await phone.closeApp()
        try await running.value
        for _ in 0..<100 where await phone.closingAnswers.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let answers = await phone.closingAnswers
        XCTAssertEqual(answers, ["t-1"], "answered with the phone's own transaction id")
        let stopped = await phone.workflowsStopped
        XCTAssertEqual(stopped, ["permission", "audio", "remote"])
    }

    /// As Phone Link does it (capture of 2026-10-13): a connection opened for "earlyLaunch",
    /// that workflow asked for on the launcher channel, the notification's key and the
    /// button's number sent on the workflow's channel, the phone's word for how it went.
    func testANotificationsButtonIsPressedOverAnEarlyLaunchConnection() async throws {
        func press(_ result: Int?, timeout: Duration = .seconds(10)) async throws -> (NotificationLaunch.Outcome, ScriptedNanoPhone) {
            let (mac, phoneSide) = MemoryNanoTransport.pair()
            let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
            await phone.setLegacy(true)
            await phone.setNotificationLaunchResult(result)
            await phone.run()
            let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
            try await connection.start()
            defer { Task { await connection.close() } }
            return (try await NotificationLaunch.press(over: connection, key: "0|com.example|7|null|10123", actionIndex: 1, timeout: timeout), phone)
        }
        let (outcome, phone) = try await press(0)
        XCTAssertEqual(outcome, .pressed)
        let asked = await phone.workflowsAsked
        XCTAssertEqual(asked, ["earlyLaunch"], "nothing of the screen itself is asked for")
        let requests = await phone.mirrorRequests
        let request = try XCTUnwrap(requests.first { $0.path == "/mirror/phone/launchNotification" }?.object)
        XCTAssertEqual(request["key"] as? String, "0|com.example|7|null|10123")
        XCTAssertEqual(request["actionIndex"] as? Int, 1)
        XCTAssertEqual((request["transactionId"] as? String)?.count, 36)
        let stopped = await waitUntil { await phone.workflowsStopped == ["earlyLaunch"] }
        XCTAssertTrue(stopped, "the workflow is ended as it was begun")

        let onPhone = try await press(1).0
        XCTAssertEqual(onPhone, .openedOnPhone)
        let used = try await press(4).0
        XCTAssertEqual(used, .pressed, "already used up counts as done")
        let failed = try await press(2).0
        XCTAssertEqual(failed, .failed(2))
        do {
            _ = try await press(nil, timeout: .milliseconds(600))
            XCTFail("a phone that says nothing was taken for one that pressed")
        } catch let error as NotificationLaunch.LaunchError {
            XCTAssertEqual(error, .noAnswer)
        }
    }

    /// 2026-10-16: frames lost on a poor network, the whole frame that would mend the picture
    /// lost too, and a still screen sending nothing more. The picture stayed frozen.
    func testABrokenPictureIsAskedForAfreshAndTheSessionRestartedWhenThatBringsNothing() async throws {
        func run(mends: Bool) async throws -> (restart: Bool, phone: ScriptedNanoPhone) {
            let (mac, phoneSide) = MemoryNanoTransport.pair()
            let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
            await phone.setLegacy(true)
            await phone.setBreaksPicture(true, mends: mends)
            await phone.run()
            let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
            try await connection.start()
            var options = NanoMirrorSession.Options()
            options.brokenAskAfter = .milliseconds(400)
            options.brokenRestartAfter = .milliseconds(1800)
            let session = NanoMirrorSession(connection: connection, options: options) { _ in }
            let running = Task { try await session.run() }
            // Long enough for the restart to be decided, where it is.
            try? await Task.sleep(for: .milliseconds(2600))
            let restart = await session.restartWanted
            if !restart { await session.stop() }
            _ = try? await running.value
            await connection.close()
            return (restart, phone)
        }
        let (gaveUp, phone) = try await run(mends: false)
        XCTAssertTrue(gaveUp, "a picture that stays broken ends in a new session")
        let packets = await phone.videoPacketsFromPC
        let lost = packets.filter { if case .control(let flags, _) = $0 { return flags == 0x122 } else { return false } }
        XCTAssertGreaterThan(lost.count, 1, "the lost frames are reported again while nothing comes")
        let starts = packets.filter { if case .control(let flags, _) = $0 { return flags & NanoVideoPacket.Control.startStream != 0 } else { return false } }
        XCTAssertGreaterThan(starts.count, 1, "the stream is asked for afresh before the session is given up")

        let (restarted, _) = try await run(mends: true)
        XCTAssertFalse(restarted, "a picture mended by asking again needs no new session")
    }

    /// 2026-10-16: after the link to the phone was rebuilt, the screen's events reached
    /// nobody: the reader of the old connection had been cancelled, which ends a single stream.
    func testAListenerThatComesAfterACancelledOneStillHearsEverything() async {
        let broadcast = Broadcast<Int>()
        let first = broadcast.stream()
        let reading = Task { var got: [Int] = []; for await value in first { got.append(value) }; return got }
        try? await Task.sleep(for: .milliseconds(50))
        broadcast.send(1)
        try? await Task.sleep(for: .milliseconds(50))
        reading.cancel()
        let before = await reading.value
        XCTAssertEqual(before, [1])
        let gone = await waitUntil { broadcast.listenerCount == 0 }
        XCTAssertTrue(gone, "a reader that stopped is let go")

        // As the next connection does: listens afresh, and hears what comes now.
        let second = broadcast.stream()
        broadcast.send(2)
        broadcast.send(3)
        var iterator = second.makeAsyncIterator()
        let a = await iterator.next(), b = await iterator.next()
        XCTAssertEqual([a, b], [2, 3])

        // And the screen itself gives each listener its own stream.
        let mirror = PhoneScreenMirror()
        XCTAssertNotNil(mirror.updates.makeAsyncIterator() as AsyncStream<PhoneScreenMirror.Update>.Iterator?)
    }

    /// Seen 2026-10-27: the handshake completed, then the phone opened nothing and fell silent.
    /// The session says so, so that the screen can be tried once more instead of failing.
    func testAPhoneThatStallsAfterTheHandshakeIsToldApartFromOtherFailures() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.setLegacy(true)
        await phone.setStallsAfterHandshake(true)
        await phone.run()
        var quick = settings()
        quick.silenceLimit = .milliseconds(600)
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: quick)
        try await connection.start()
        let session = NanoMirrorSession(connection: connection) { _ in }
        do {
            try await session.run()
            XCTFail("a silent phone ended the session without an error")
        } catch let error as NanoMirrorSession.MirrorError {
            guard case .connectionLost = error else { return XCTFail("\(error)") }
        }
        let stalled = await session.stalledAtStart
        XCTAssertTrue(stalled)
        await connection.close()
    }

    func testAPhoneWhoseUserSaysNoEndsTheMirroring() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.setLegacy(true)
        await phone.setDeniesScreen(true)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        do {
            try await NanoMirrorSession(connection: connection) { _ in }.run()
            XCTFail("mirroring went on although it was denied")
        } catch let error as NanoMirrorSession.MirrorError {
            XCTAssertEqual(error, .permissionDenied)
        }
        await connection.close()
    }

    // MARK: Sending to the phone

    func temporaryFile(_ name: String, bytes: Int, in folder: URL) throws -> (OutgoingFile, Data) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: ($0 &* 131) ^ ($0 >> 9)) })
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return (try XCTUnwrap(OutgoingFile(url: url)), data)
    }

    /// The whole exchange for files going to the phone: workflow request, offer, the phone's
    /// request for each file, the blob in the phone's own layout, the phone's "completed".
    func testFilesAreSentToThePhoneOneByOneAsItAsksForThem() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winphone-outgoing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (first, firstData) = try temporaryFile("Report.pdf", bytes: 250_123, in: folder)
        let (second, secondData) = try temporaryFile("Notes.txt", bytes: 777, in: folder)
        let (empty, _) = try temporaryFile("Empty.bin", bytes: 0, in: folder)
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.setLegacy(true)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let log = SendLog()
        let sender = NanoFileSender(connection: connection, senderName: "Test Mac") { await log.add($0) }
        let confirmed = try await sender.run(files: [first, second, empty], transferId: "aaaaaaaa-0000-4000-8000-000000000001", timeout: .seconds(30))
        XCTAssertEqual(confirmed, 3)
        let received = await phone.receivedFromPC
        XCTAssertEqual(received[first.id], firstData)
        XCTAssertEqual(received[second.id], secondData)
        XCTAssertEqual(received[empty.id], Data())
        // The blob is named by the file's ID, "#" and how often that file has been sent.
        let names = await phone.blobNamesFromPC
        XCTAssertEqual(names, ["\(first.id)#1", "\(second.id)#1", "\(empty.id)#1"])
        // The offer, as Phone Link words it.
        let requests = await phone.legacyRequests
        let offer = try XCTUnwrap(requests.first { $0["Scenario"] as? String == "FileTransferToPhone" })
        XCTAssertEqual(offer["TransferId"] as? String, "aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertEqual(offer["SenderName"] as? String, "Test Mac")
        XCTAssertEqual((offer["SessionTryCount"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((offer["ReceivedFileCount"] as? NSNumber)?.intValue, 0)
        let content = try XCTUnwrap(offer["Content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["FileName"] as? String }, ["Report.pdf", "Notes.txt", "Empty.bin"])
        XCTAssertEqual(content.map { ($0["FileSize"] as? NSNumber)?.intValue }, [250_123, 777, 0])
        XCTAssertEqual(content.map { ($0["FileStatus"] as? NSNumber)?.intValue }, [1, 1, 1])
        XCTAssertEqual(content.map { $0["FileHash"] as? String }, ["", "", ""])
        // The blob's layout: segments of 100,000 bytes, each piece saying how many its segment has.
        let packets = await phone.blobPacketsFromPC
        XCTAssertTrue(packets.contains(.start(totalSize: 250_123, name: "\(first.id)#1")))
        XCTAssertTrue(packets.contains(.completion(kind: 1, name: "\(first.id)#1")))
        let progress = await log.items
        XCTAssertEqual(progress.filter { if case .sent = $0 { return true } else { return false } }, [.sent(name: "Report.pdf"), .sent(name: "Notes.txt"), .sent(name: "Empty.bin")])
        XCTAssertTrue(progress.contains(.sending(name: "Report.pdf", sent: 250_123, total: 250_123)))
        await connection.close()
    }

    /// A larger file with packets lost both ways: every byte still arrives, and no more of the
    /// file is in flight at once than the window allows.
    func testAFileSentToThePhoneSurvivesLossInBothDirections() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winphone-outgoing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (file, data) = try temporaryFile("Clip.mp4", bytes: 1_500_000, in: folder)
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let fromMac = Counter(), fromPhone = Counter()
        mac.shouldDeliver = { _ in
            let n = fromMac.next()
            return n < 30 || n % 23 != 0
        }
        phoneSide.shouldDeliver = { _ in
            let n = fromPhone.next()
            return n < 40 || n % 19 != 0
        }
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.setLegacy(true)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let confirmed = try await NanoFileSender(connection: connection, senderName: "Test Mac").run(files: [file], timeout: .seconds(60))
        XCTAssertEqual(confirmed, 1)
        let received = await phone.receivedFromPC
        XCTAssertEqual(received[file.id], data)
        await connection.close()
    }

    func testAPhoneThatIsBusyOrCancelsEndsTheSending() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winphone-outgoing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (file, _) = try temporaryFile("Clip.mp4", bytes: 900_000, in: folder)
        for cancels in [false, true] {
            let (mac, phoneSide) = MemoryNanoTransport.pair()
            let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
            await phone.setLegacy(true)
            await phone.setIncoming(rejects: !cancels, cancelsAfterPieces: cancels ? 100 : nil)
            await phone.run()
            let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
            try await connection.start()
            do {
                _ = try await NanoFileSender(connection: connection, senderName: "Test Mac").run(files: [file], timeout: .seconds(30))
                XCTFail("the transfer should not have completed")
            } catch let error as NanoFileSender.SendError {
                XCTAssertEqual(error, cancels ? .cancelled : .busy)
            }
            await connection.close()
            if cancels {
                // Nothing more goes out once the phone has called it off; what was already on
                // its way is let in first.
                var before = -1, after = await phone.piecesFromPC
                for _ in 0..<20 where before != after {
                    before = after
                    try await Task.sleep(for: .milliseconds(150))
                    after = await phone.piecesFromPC
                }
                XCTAssertEqual(before, after, "the pieces stopped")
                XCTAssertLessThan(after, 800)
            }
        }
    }

    /// A file that is shorter on disk than was offered cannot be sent to the end.
    func testAFileThatShrinksIsReportedAsUnreadable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winphone-outgoing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var (file, _) = try temporaryFile("Log.txt", bytes: 5000, in: folder)
        file.size = 400_000
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.setLegacy(true)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        do {
            _ = try await NanoFileSender(connection: connection, senderName: "Test Mac").run(files: [file], timeout: .seconds(30))
            XCTFail("the transfer should not have completed")
        } catch let error as NanoFileSender.SendError {
            XCTAssertEqual(error, .unreadable("Log.txt"))
        }
    }

    actor SendLog {
        var items: [NanoFileSender.Progress] = []
        func add(_ item: NanoFileSender.Progress) { items.append(item) }
    }

    /// With a folder to write to, files arrive as files, also when packets were lost, and
    /// nothing is left in the folder but what was handed over.
    func testFilesAreWrittenToDiskAsTheyArrive() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("winphone-incoming-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let counter = Counter()
        phoneSide.shouldDeliver = { _ in
            let n = counter.next()
            return n < 40 || n % 17 != 0
        }
        let files = [file("88888888-aaaa", "one.bin", bytes: 250_000), file("88888888-bbbb", "two.bin", bytes: 30_000)]
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: files)
        await phone.setLegacy(true)
        await phone.run()
        var onDisk = settings()
        onDisk.blobDirectory = folder
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: onDisk)
        try await connection.start()
        let offer = LegacyFileOffer(transferId: "0123456789abcdef0123456789abcdef",
                                    items: [.init(id: "88888888-aaaa", name: "one.bin", size: 250_000), .init(id: "88888888-bbbb", name: "two.bin", size: 30_000)])
        let received = try await NanoFileReceiver(connection: connection, senderName: "Test Mac").run(offer: offer, timeout: .seconds(30))
        XCTAssertEqual(received.map(\.name), ["one.bin", "two.bin"])
        for (file, sent) in zip(received, files) {
            guard case .file(let url, let size) = file.content else { XCTFail("held in memory"); continue }
            XCTAssertEqual(size, sent.data.count)
            XCTAssertEqual(try Data(contentsOf: url), sent.data)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
        await connection.close()
    }

    /// The phone's slow way, alone: it ignores the reports, gives packets up when their time
    /// runs out, sends them under new numbers and says how far it has given up. This client
    /// must then stop waiting for the old numbers.
    func testAPhoneThatGivesPacketsUpOnItsTimerIsFollowed() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let counter = Counter()
        phoneSide.shouldDeliver = { _ in
            let n = counter.next()
            return n < 40 || n % 11 != 0
        }
        let files = [file("77777777-aaaa", "clip.mp4", bytes: 300_000)]
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: files)
        await phone.setLegacy(true)
        await phone.setRecovery(vectors: false, timer: true)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let offer = LegacyFileOffer(transferId: "0123456789abcdef0123456789abcdef", items: [.init(id: "77777777-aaaa", name: "clip.mp4", size: 300_000)])
        let received = try await NanoFileReceiver(connection: connection, senderName: "Test Mac").run(offer: offer, timeout: .seconds(40))
        XCTAssertEqual(received.map(\.data), files.map(\.data))
        let contradictions = await phone.contradictions
        XCTAssertEqual(contradictions, 0)
        await connection.close()
    }

    func testLostPacketsAreSentAgainAndNothingIsDuplicated() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        // Lose every fifth datagram from the Mac, after the start sequence.
        let counter = Counter()
        mac.shouldDeliver = { _ in
            let n = counter.next()
            return n < 20 || n % 5 != 0
        }
        let files = [file("33333333-cccc", "notes.txt", bytes: 5000)]
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: files)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        let received = try await NanoFileReceiver(connection: connection, senderName: "Test Mac").run(timeout: .seconds(15))
        XCTAssertEqual(received.map(\.data), files.map(\.data))
        let completed = await phone.completed
        XCTAssertEqual(completed?.receivedFileCount, 1, "the completion message got through although packets were lost")
        await connection.close()
    }

    func testARefusedChannelIsReportedAsSuch() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: Self.keys, files: [])
        await phone.setRefuse(true)
        await phone.run()
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: settings())
        try await connection.start()
        do {
            _ = try await NanoFileReceiver(connection: connection, senderName: "Test Mac").run(timeout: .seconds(5))
            XCTFail("expected a refusal")
        } catch let error as NanoFileReceiver.ReceiveError {
            guard case .refused = error else { return XCTFail("\(error)") }
        }
        await connection.close()
    }

    func testAPhoneThatNeverAnswersEndsTheStart() async throws {
        let (mac, _) = MemoryNanoTransport.pair()
        var quick = settings()
        quick.handshakeAttempts = 2
        quick.handshakeRetry = .milliseconds(100)
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: quick)
        do {
            try await connection.start()
            XCTFail("expected no answer")
        } catch let error as NanoConnection.ConnectionError {
            XCTAssertEqual(error, .noAnswer)
        }
    }

    func testDatagramsWithTheWrongKeyAreIgnored() async throws {
        let (mac, phoneSide) = MemoryNanoTransport.pair()
        let other = try NanoSessionKeys(keyHex: "ffffffffffffffffffffffffffffffff", saltHex: "101112131415161718191a1b1c1d")
        let phone = ScriptedNanoPhone(transport: phoneSide, keys: other, files: [])
        await phone.run()
        var quick = settings()
        quick.handshakeAttempts = 2
        quick.handshakeRetry = .milliseconds(100)
        let connection = NanoConnection(transport: mac, keys: Self.keys, settings: quick)
        do {
            try await connection.start()
            XCTFail("a phone with another key cannot complete the start")
        } catch {}
    }

    /// The real socket, against a listener on this machine.
    func testTheUDPTransportCarriesDatagramsBothWays() async throws {
        let listener = try NWListener(using: .udp, on: .any)
        let echoed = AsyncStream<Data>.makeStream()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            func receive() {
                connection.receiveMessage { data, _, _, error in
                    if let data, !data.isEmpty {
                        echoed.continuation.yield(data)
                        connection.send(content: Data("re:".utf8) + data, completion: .contentProcessed { _ in })
                    }
                    if error == nil { receive() }
                }
            }
            receive()
        }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        var port: UInt16 = 0
        for await value in ready.stream { port = value; break }
        let transport = NanoUDPTransport(host: "127.0.0.1", port: port)
        try await transport.start()
        try await transport.send(Data("hello".utf8))
        for await data in echoed.stream { XCTAssertEqual(data, Data("hello".utf8)); break }
        for await data in transport.incoming { XCTAssertEqual(data, Data("re:hello".utf8)); break }
        transport.close()

        // The plain-socket transport the app uses, against the same listener.
        let socket = try NanoSocketTransport(host: "127.0.0.1", port: port)
        XCTAssertGreaterThanOrEqual(socket.receiveBufferSize, 256 * 1024, "a buffer large enough for a burst")
        try await socket.send(Data("again".utf8))
        for await data in socket.incoming { XCTAssertEqual(data, Data("re:again".utf8)); break }
        socket.close()
        socket.close()
        XCTAssertThrowsError(try NanoSocketTransport(host: "not an address", port: 1))
    }

    actor ProgressLog {
        var items: [NanoFileReceiver.Progress] = []
        func add(_ item: NanoFileReceiver.Progress) { items.append(item) }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }
}
