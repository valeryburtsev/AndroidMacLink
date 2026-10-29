import Foundation
import SwiftProtobuf

/// Follows one recorded Nano connection, datagram by datagram, and says what happened on it:
/// channels created, messages exchanged, blobs transferred. It is the receiving half of the
/// protocol without the sending half, enough to read a recording and to be the core of a
/// receiver later.
public struct NanoTraceDecoder: Sendable {
    public enum Event: Equatable, Sendable {
        case probe(NanoProbe)
        case keepAlive(NanoKeepAlive)
        case rateHandshake(NanoRateHandshake)
        case channelCreated(channel: UInt16, NanoChannelDescription)
        case channelOpened(channel: UInt16)
        case channelClosed(channel: UInt16)
        case messageHandshake(channel: UInt16, version: UInt32)
        case message(channel: UInt16, NanoMessageAssembler.Message)
        case blobHandshake(channel: UInt16, minVersion: UInt32, maxVersion: UInt32)
        case blobStarted(channel: UInt16, name: String, size: UInt64)
        case blobReceived(channel: UInt16, name: String, data: Data)
        case blobCompletion(channel: UInt16, kind: UInt32, name: String)
        case blobWritten(channel: UInt16, queued: UInt32, name: String)
        /// A packet of a screen-mirroring video channel.
        case video(channel: UInt16, NanoVideoPacket)
        /// A packet of a screen-mirroring input channel.
        case input(channel: UInt16, NanoInputPacket)
        /// A packet whose inside did not parse; the text says which layer gave up.
        case undecoded(String)
    }

    private var channels: [UInt16: NanoChannelDescription] = [:]
    private var messages: [String: NanoMessageAssembler] = [:]
    private var blobs: [String: NanoBlobAssembler] = [:]
    /// Packets already seen, so that a retransmission is not counted twice.
    private var seen: Set<String> = []

    public init() {}

    /// The channels created so far, by number.
    public var knownChannels: [UInt16: NanoChannelDescription] { channels }

    /// - Parameter direction: any label that tells the two directions apart.
    public mutating func decode(_ datagram: NanoDatagram, direction: String) -> [Event] {
        let payload = datagram.payload
        do {
            switch datagram.header.kind {
            case .probing: return [.probe(try NanoProbe(payload))]
            case .keepAlive: return [.keepAlive(try NanoKeepAlive(payload))]
            case .rateControl: return [.rateHandshake(try NanoRateHandshake(payload))]
            case .rateControlNoData: return []
            case .muxControl:
                let header = try NanoRateHeader(payload)
                guard let sequence = header.dataSequence else { return [] }
                guard seen.insert("\(direction)|control|\(sequence)").inserted else { return [] }
                let channel = datagram.header.channelId
                switch try NanoMuxControl(payload.dropFirst(header.length)) {
                case .create(let description, _, _, _):
                    channels[channel] = description
                    return [.channelCreated(channel: channel, description)]
                case .open: return [.channelOpened(channel: channel)]
                case .close: return [.channelClosed(channel: channel)]
                }
            case .channelData:
                let header = try NanoRateHeader(payload)
                // Without the data part the packet only acknowledges.
                guard header.dataSequence != nil, payload.count > header.length else { return [] }
                let channel = datagram.header.channelId
                guard seen.insert("\(direction)|\(channel)|\(datagram.innerSequence)").inserted else { return [] }
                let inner = payload.dropFirst(header.length)
                _ = try NanoSequencerHeader(inner)
                return try channelEvents(Data(inner.dropFirst(NanoSequencerHeader.length)), channel: channel, direction: direction)
            default:
                return []
            }
        } catch {
            return [.undecoded("\(datagram.header.kind) on channel \(datagram.header.channelId): \(error)")]
        }
    }

    private mutating func channelEvents(_ packet: Data, channel: UInt16, direction: String) throws -> [Event] {
        let key = "\(direction)|\(channel)"
        switch channels[channel]?.channelClass {
        case "Messaging":
            let parsed = try NanoMessagePacket(packet)
            if case .handshake(let version) = parsed { return [.messageHandshake(channel: channel, version: version)] }
            var assembler = messages.removeValue(forKey: key) ?? NanoMessageAssembler()
            defer { messages[key] = assembler }
            return assembler.add(parsed).map { [.message(channel: channel, $0)] } ?? []
        case "Video":
            return [.video(channel: channel, try NanoVideoPacket(packet))]
        case "Input":
            return [.input(channel: channel, try NanoInputPacket(packet))]
        case "Blob":
            let parsed = try NanoBlobPacket(packet)
            var assembler = blobs.removeValue(forKey: key) ?? NanoBlobAssembler()
            defer { blobs[key] = assembler }
            var events: [Event] = []
            switch parsed {
            case .handshake(let minVersion, let maxVersion): events.append(.blobHandshake(channel: channel, minVersion: minVersion, maxVersion: maxVersion))
            case .start(let size, let name): events.append(.blobStarted(channel: channel, name: name, size: size))
            case .completion(let kind, let name): events.append(.blobCompletion(channel: channel, kind: kind, name: name))
            case .written(let queued, let name): events.append(.blobWritten(channel: channel, queued: queued, name: name))
            case .data: break
            }
            if let finished = assembler.add(parsed) { events.append(.blobReceived(channel: channel, name: finished.name, data: finished.data)) }
            return events
        case let other:
            return [.undecoded("data on channel \(channel) of class \(other ?? "unknown")")]
        }
    }
}

/// Reads what the two capture files of a Nano session hold: the keys from the relay capture
/// and the datagrams from the packet recording.
public enum NanoRecording {
    /// The master key and salt of every connection description in a relay capture
    /// (`flows.jsonl` of the capture proxy, with raw WebSocket recording on).
    public static func keySets(inRelayCapture contents: String) -> [NanoSessionKeys] {
        var found: [NanoSessionKeys] = []
        for line in contents.split(separator: "\n") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["type"] as? String == "ws", let raw = (record["raw_b64"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let frames = try? SignalR.splitFrames(raw) else { continue }
            for frame in frames {
                guard case .invocation(_, _, _, let arguments)? = try? HubMessage(frame: frame), arguments.count >= 3,
                      case .fragment(let fragment)? = try? DcgPacket(arguments[2]),
                      let envelope = try? PlatformEnvelope(decoding: fragment.raw) else { continue }
                var description: String?
                if envelope.route?.hasPrefix("/Context/Message") == true,
                   let message = try? PlatformSdk_V1_ContextSourceMessage(serializedBytes: envelope.payload),
                   case .csConnectionInfo(let info)? = message.type {
                    // The cross-device client's exchange.
                    description = info.connectionInfo
                } else if fragment.messageType == .app, let values = try? ValueSet(serialized: envelope.payload) {
                    // The Phone Link client's: the request on "/nanohandshake" and its answer.
                    description = values.string("handshake")
                }
                guard let description, let keys = keys(inConnectionDescription: description), !found.contains(keys) else { continue }
                found.append(keys)
            }
        }
        return found
    }

    /// Every connection description in a relay capture, in order, with the time it was sent:
    /// the texts the two sides hand to their transport libraries. They hold key material.
    public static func descriptions(inRelayCapture contents: String) -> [(time: Double, route: String, text: String)] {
        var found: [(time: Double, route: String, text: String)] = []
        for line in contents.split(separator: "\n") {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  record["type"] as? String == "ws", let raw = (record["raw_b64"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let frames = try? SignalR.splitFrames(raw) else { continue }
            let time = (record["ts"] as? NSNumber)?.doubleValue ?? 0
            for frame in frames {
                guard case .invocation(_, _, _, let arguments)? = try? HubMessage(frame: frame), arguments.count >= 3,
                      case .fragment(let fragment)? = try? DcgPacket(arguments[2]),
                      let envelope = try? PlatformEnvelope(decoding: fragment.raw) else { continue }
                if envelope.route?.hasPrefix("/Context/Message") == true,
                   let message = try? PlatformSdk_V1_ContextSourceMessage(serializedBytes: envelope.payload),
                   case .csConnectionInfo(let info)? = message.type {
                    found.append((time, "/Context/Message", info.connectionInfo))
                } else if fragment.messageType == .app, let values = try? ValueSet(serialized: envelope.payload), let text = values.string("handshake") {
                    found.append((time, envelope.route ?? "", text))
                }
            }
        }
        return found
    }

    /// The session keys a connection description offers, if it carries any.
    public static func keys(inConnectionDescription text: String) -> NanoSessionKeys? {
        // Nested in the cross-device form, at the top in the Phone Link form.
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let security = ((object["connectioninformation"] as? [String: Any])?["security"] ?? object["security"]) as? [String: Any],
              let key = security["key"] as? String, let salt = security["salt"] as? String else { return nil }
        return try? NanoSessionKeys(keyHex: key, saltHex: salt)
    }

    public struct Opened: Sendable {
        /// "address:port>address:port".
        public var flow: String
        /// The two directions of one connection share this.
        public var connection: String
        public var datagram: NanoDatagram
        public var time: Double = 0
        public var keys: NanoSessionKeys?
    }

    /// Opens every datagram of a recording that one of the key sets fits.
    public static func open(_ datagrams: [PacketCapture.Datagram], keySets: [NanoSessionKeys]) -> [Opened] {
        var working: [NanoSessionKeys] = []
        var result: [Opened] = []
        for datagram in datagrams where datagram.payload.count >= NanoDatagram.overhead && NanoHeader(datagram.payload) != nil {
            for keys in working + keySets {
                // The sequence number wraps after 65,536 packets; try the first two rounds.
                guard let opened = (0...1).lazy.compactMap({ try? NanoDatagram(opening: datagram.payload, keys: keys, rollover: UInt32($0)) }).first else { continue }
                if !working.contains(keys) { working.append(keys) }
                let ends = [datagram.source, datagram.destination].sorted()
                result.append(Opened(flow: "\(datagram.source)>\(datagram.destination)", connection: ends.joined(separator: "<>"), datagram: opened,
                                     time: datagram.time, keys: keys))
                break
            }
        }
        return result
    }
}
