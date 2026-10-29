import CryptoKit
import Foundation
import SwiftProtobuf
import WinPhoneCore

// winphone-probe nano-check <recording.pcap> <flows.jsonl>
//
// Tries the Nano decoder on a recording of the peer-to-peer traffic. The keys are read from
// the connection descriptions in the relay capture taken at the same time. Prints counts and
// packet kinds only: no key, no address beyond what tcpdump itself shows, no payload.

/// The master key and salt of every connection description in a relay capture.
func nanoKeySets(inFlows path: String) -> [NanoSessionKeys] {
    guard let contents = FileManager.default.contents(atPath: path) else { return [] }
    return NanoRecording.keySets(inRelayCapture: String(decoding: contents, as: UTF8.self))
}

func runNanoCheck(pcap: String, flows: String) -> Never {
    guard let file = FileManager.default.contents(atPath: pcap) else {
        print("cannot open \(pcap)")
        exit(1)
    }
    let datagrams: [PacketCapture.Datagram]
    do {
        datagrams = try PacketCapture.udpDatagrams(in: file)
    } catch PacketCapture.CaptureError.pcapng {
        print("this is a pcapng file; convert it first: tcpdump -r \(pcap) -w converted.pcap")
        exit(1)
    } catch {
        print("could not read the recording: \(error)")
        exit(1)
    }
    let keySets = nanoKeySets(inFlows: flows)
    print("\(datagrams.count) UDP datagrams in the recording, \(keySets.count) key sets in the relay capture")
    let candidates = datagrams.filter { NanoHeader($0.payload) != nil && $0.payload.count >= NanoDatagram.overhead }
    print("\(candidates.count) look like RTP version 2 and are long enough")
    var flowsSeen: [String: Int] = [:]
    for datagram in candidates { flowsSeen["\(datagram.source) > \(datagram.destination)", default: 0] += 1 }
    for (flow, count) in flowsSeen.sorted(by: { $0.value > $1.value }).prefix(6) { print("  \(count) datagrams \(flow)") }
    guard !keySets.isEmpty, !candidates.isEmpty else {
        print(keySets.isEmpty ? "no connection description with a key was found: was the relay proxy recording at the same time?" : "nothing to try the keys on")
        exit(0)
    }
    var opened = 0
    var byKey: [Int: Int] = [:], byKind: [String: Int] = [:]
    var firstKinds: [String] = []
    var byFlow: [String: Int] = [:], channels: [String: (count: Int, bytes: Int)] = [:], unopened: [String] = []
    var innerOrder: [String: (last: UInt16, steps: Int, inOrder: Int)] = [:]
    for datagram in candidates {
        var didOpen = false
        for (index, keys) in keySets.enumerated() {
            // The sequence number wraps after 65,536 packets; a short recording needs 0 or 1.
            guard let packet = (0...1).lazy.compactMap({ try? NanoDatagram(opening: datagram.payload, keys: keys, rollover: UInt32($0)) }).first else { continue }
            opened += 1
            byKey[index, default: 0] += 1
            let kind = "\(packet.header.kind) (type \(packet.header.payloadType))"
            byKind[kind, default: 0] += 1
            if firstKinds.count < 24 { firstKinds.append("\(kind), channel \(packet.header.channelId), \(packet.payload.count) bytes") }
            didOpen = true
            let flow = "\(datagram.source) > \(datagram.destination)"
            byFlow["\(flow) with key set \(index + 1)", default: 0] += 1
            if packet.header.kind == .channelData {
                let name = "\(flow) channel \(packet.header.channelId) connection \(packet.header.connectionId) type \(packet.header.payloadType)"
                channels[name, default: (0, 0)].count += 1
                channels[name, default: (0, 0)].bytes += packet.payload.count
                // Whether the number carried inside rises by one from packet to packet.
                var order = innerOrder[name] ?? (packet.innerSequence &- 1, 0, 0)
                order.steps += 1
                if packet.innerSequence == order.last &+ 1 { order.inOrder += 1 }
                order.last = packet.innerSequence
                innerOrder[name] = order
            }
            break
        }
        if !didOpen, let header = NanoHeader(datagram.payload) {
            unopened.append("type \(header.payloadType), \(datagram.payload.count) bytes, \(datagram.source) > \(datagram.destination)")
        }
    }
    for (flow, count) in byFlow.sorted(by: { $0.key < $1.key }) { print("  \(count) \(flow)") }
    for (name, total) in channels.sorted(by: { $0.key < $1.key }) {
        let order = innerOrder[name]
        print("  data: \(total.count) packets, \(total.bytes) bytes, inner numbers consecutive in \(order?.inOrder ?? 0) of \(order?.steps ?? 0): \(name)")
    }
    for line in unopened.prefix(5) { print("  not opened: \(line)") }
    print("\(opened) of \(candidates.count) opened with a key from the relay capture")
    let origins = nanoKeyOrigins(inFlows: flows)
    for (index, count) in byKey.sorted(by: { $0.key < $1.key }) {
        let origin = origins.first { $0.keys == keySets[index] }?.origin ?? "unknown"
        print("  key set \(index + 1): \(count) datagrams; it came in a description from \(origin)")
    }
    for (kind, count) in byKind.sorted(by: { $0.value > $1.value }) { print("  \(count) \(kind)") }
    if !firstKinds.isEmpty {
        print("first packets, in order:")
        for line in firstKinds { print("  \(line)") }
    }
    if opened == 0 {
        print("""
        none opened. In protocol/specs/nano-wire-notes.md section 2.5, the things to vary are, in order: \
        the key derivation's cipher mode, which end of the salt is dropped, and separate keys per direction.
        """)
    }
    exit(0)
}

// winphone-probe nano-dump <recording.pcap> <flows.jsonl> [head-bytes]
//
// Lists every datagram that opens: order, direction by UDP flow, packet kind, channel, the
// inner sequence number, the payload length and the first bytes of the payload in hex. For
// working out the layers above the encryption. The head is short by default so that protocol
// headers show and content mostly does not; the recording holds real content all the same.
func runNanoDump(pcap: String, flows: String, head: Int) -> Never {
    guard let file = FileManager.default.contents(atPath: pcap), let datagrams = try? PacketCapture.udpDatagrams(in: file) else {
        print("cannot read \(pcap)")
        exit(1)
    }
    let opened = NanoRecording.open(datagrams, keySets: nanoKeySets(inFlows: flows))
    var flowNames: [String: String] = [:]
    let start = opened.first?.time ?? 0
    for packet in opened {
        if flowNames[packet.flow] == nil { flowNames[packet.flow] = "f\(flowNames.count + 1)" }
        let header = packet.datagram.header
        let bytes = packet.datagram.payload.prefix(head).map { String(format: "%02x", $0) }.joined()
        print(String(format: "%8.3f", packet.time - start) + " \(flowNames[packet.flow]!) pt\(header.payloadType)\(header.marker ? "m" : "") ch\(header.channelId) seq\(header.sequence) ts\(header.timestamp) in\(packet.datagram.innerSequence) len\(packet.datagram.payload.count) \(bytes)")
    }
    for (flow, name) in flowNames.sorted(by: { $0.value < $1.value }) { print("\(name) = \(flow)") }
    exit(0)
}

// winphone-probe nano-file <recording.pcap> <flows.jsonl> [--save <folder>]
//
// Follows each recorded connection through all its layers and reports what happened on it:
// channels, messages by path, and every blob that was transferred, reassembled. Identifiers
// in paths are shortened and no content is printed; with --save the blobs are written to the
// given folder (keep that inside the git-ignored captures/ directory: it is real content).
func runNanoFile(pcap: String, flows: String, saveTo: String?) -> Never {
    guard let file = FileManager.default.contents(atPath: pcap), let datagrams = try? PacketCapture.udpDatagrams(in: file),
          let relay = FileManager.default.contents(atPath: flows) else {
        print("cannot read the recording or the relay capture")
        exit(1)
    }
    let keySets = NanoRecording.keySets(inRelayCapture: String(decoding: relay, as: UTF8.self))
    let opened = NanoRecording.open(datagrams, keySets: keySets)
    print("\(opened.count) datagrams opened")
    /// Shortens the long identifiers in a path or description.
    func brief(_ text: String) -> String {
        text.replacingOccurrences(of: "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}", with: "<id>", options: .regularExpression)
    }
    var decoders: [String: NanoTraceDecoder] = [:]
    var order: [String] = []
    var undecoded = 0
    // Screen mirroring: frames are counted, not listed, and never shown.
    var assembler = NanoVideoAssembler()
    var frames = 0, keyframes = 0, frameBytes = 0, firstFrameAt: Double?, lastFrameAt = 0.0
    var controls: [String: Int] = [:]
    var unitKinds: [UInt8: Int] = [:]
    var stream = Data()
    let saveVideo = CommandLine.arguments.firstIndex(of: "--save-video").flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    var inputFrames = 0
    let start = opened.first?.time ?? 0
    for packet in opened {
        if decoders[packet.connection] == nil { decoders[packet.connection] = NanoTraceDecoder(); order.append(packet.connection) }
        let label = "connection \(order.firstIndex(of: packet.connection)! + 1), \(packet.flow.hasPrefix(packet.connection.components(separatedBy: "<>")[0]) ? "A>B" : "B>A")"
        for event in decoders[packet.connection]!.decode(packet.datagram, direction: packet.flow) {
            switch event {
            case .probe, .keepAlive: continue
            case .rateHandshake(let handshake):
                switch handshake {
                case .syn(let version, _, let sequence, let controller, _): print("\(label): rate-control SYN, version \(version), first sequence \(sequence), controller \(controller)")
                case .synAck: print("\(label): rate-control SYN ACK")
                case .synAckOfAck: print("\(label): rate-control handshake complete")
                }
            case .channelCreated(let channel, let description): print("\(label): channel \(channel) created, \(description.channelClass), \(brief(description.text.components(separatedBy: ",").dropFirst().joined(separator: ",")))")
            case .channelOpened(let channel): print("\(label): channel \(channel) open")
            case .channelClosed(let channel): print("\(label): channel \(channel) closed")
            case .messageHandshake(let channel, let version): print("\(label): channel \(channel) message handshake, version \(version)")
            case .message(let channel, let message):
                print("\(label): channel \(channel) message \(brief(message.path)), body \(message.body.count) bytes")
                if let shape = describeNanoBody(path: message.path, body: message.body) { print("    \(shape)") }
            case .blobHandshake(let channel, let low, let high): print("\(label): channel \(channel) blob handshake, versions \(low) to \(high)")
            case .blobStarted(let channel, let name, let size): print("\(label): channel \(channel) blob \(brief(name)) announced, \(size) bytes")
            case .blobWritten(let channel, let queued, _): print("\(label): channel \(channel) receiver wrote data, \(queued) queued")
            case .blobCompletion(let channel, let kind, _): print("\(label): channel \(channel) blob completion, kind \(kind)")
            case .blobReceived(let channel, let name, let data):
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let kind = NanoFileKind.guess(data)
                print("\(label): channel \(channel) blob complete: \(data.count) bytes, looks like \(kind), SHA-256 \(digest.prefix(16))…")
                if let saveTo {
                    let folder = URL(fileURLWithPath: saveTo, isDirectory: true)
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent("blob-\(name.prefix(8)).\(NanoFileKind.fileExtension(data))")
                    do { try data.write(to: url); print("  saved to \(url.path)") } catch { print("  could not save: \(error)") }
                }
            case .video(let channel, let video):
                switch video {
                case .serverHandshake(let version, let width, let height, let rate, _, let formats):
                    print("\(label): channel \(channel) video offer, version \(version), \(width) x \(height) at \(rate) frames a second, formats \(formats.map { "\($0.width)x\($0.height)@\($0.framesPerSecond) codec \($0.codec)" })")
                case .clientHandshake(_, let format):
                    print("\(label): channel \(channel) video accepted, \(format.width) x \(format.height) at \(format.framesPerSecond), codec \(format.codec)")
                case .control(let flags, let body):
                    let key = "\(label.suffix(3)) flags 0x\(String(flags, radix: 16)) with \(body.count) bytes"
                    controls[key, default: 0] += 1
                    if controls[key] == 1 { print("\(label): channel \(channel) video control, flags 0x\(String(flags, radix: 16)), \(body.count) bytes: \(body.prefix(40).map { String(format: "%02x", $0) }.joined())") }
                case .data:
                    guard let frame = assembler.add(video) else { break }
                    frames += 1
                    frameBytes += frame.data.count
                    if frame.isKeyframe { keyframes += 1 }
                    if firstFrameAt == nil { firstFrameAt = packet.time }
                    lastFrameAt = packet.time
                    for unit in H264.units(in: frame.data) { unitKinds[unit.first.map { $0 & 0x1F } ?? 0, default: 0] += 1 }
                    if frames <= 3 || frame.isKeyframe && keyframes <= 3 {
                        print("\(label): channel \(channel) frame \(frames): \(frame.data.count) bytes, \(frame.isKeyframe ? "keyframe" : "delta"), units \(H264.units(in: frame.data).map { "\(($0.first ?? 0) & 0x1F):\($0.count)" })")
                    }
                    if saveVideo != nil { stream.append(frame.data) }
                }
            case .input(let channel, let input):
                switch input {
                case .serverHandshake(let version, let capabilities, let width, let height, let touches, _):
                    print("\(label): channel \(channel) input offer, version \(version), capabilities \(capabilities), screen \(width) x \(height), \(touches) touches")
                case .clientHandshake(let version, let capabilities, let touches, _):
                    print("\(label): channel \(channel) input accepted, version \(version), capabilities \(capabilities), \(touches) touches")
                case .frameAck:
                    break
                case .frame(_, _, let body):
                    inputFrames += 1
                    // What the pointer and keys did, for working out the format: no screen content.
                    if CommandLine.arguments.contains("--input") {
                        print(String(format: "%7.2f", packet.time - start) + " input \(body.count) bytes: " + body.map { String(format: "%02x", $0) }.joined())
                    }
                }
            case .undecoded(let reason):
                undecoded += 1
                if undecoded <= 8 { print("\(label): NOT DECODED: \(reason)") }
            }
        }
    }
    if frames > 0 {
        let seconds = max(0.001, lastFrameAt - (firstFrameAt ?? 0))
        print("video: \(frames) frames in \(String(format: "%.1f", seconds)) s (\(String(format: "%.1f", Double(frames) / seconds)) a second), \(keyframes) keyframes, \(frameBytes) bytes; unit kinds \(unitKinds.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })")
        for (key, count) in controls.sorted(by: { $0.value > $1.value }) { print("  control \(key): \(count) times") }
        if let saveVideo {
            do { try stream.write(to: URL(fileURLWithPath: saveVideo)); print("  video stream saved to \(saveVideo)") } catch { print("  could not save the video: \(error)") }
        }
    }
    if inputFrames > 0 { print("input: \(inputFrames) frames") }
    print(undecoded == 0 ? "every packet decoded" : "\(undecoded) packets not decoded")
    exit(0)
}

/// What a file is, by its first bytes.
enum NanoFileKind {
    static func guess(_ data: Data) -> String {
        let head = [UInt8](data.prefix(12))
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "a JPEG image" }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "a PNG image" }
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "a PDF document" }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "a ZIP container (also Office documents)" }
        if head.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "a GIF image" }
        if head.count >= 12, Array(head[4..<8]) == [0x66, 0x74, 0x79, 0x70] { return "an MP4 or HEIC file" }
        if head.count >= 12, Array(head[0..<4]) == [0x52, 0x49, 0x46, 0x46], Array(head[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return "a WebP image" }
        if !data.isEmpty, String(data: data.prefix(512), encoding: .utf8) != nil { return "text" }
        return "an unrecognised format"
    }

    static func fileExtension(_ data: Data) -> String {
        switch guess(data) {
        case "a JPEG image": return "jpg"
        case "a PNG image": return "png"
        case "a PDF document": return "pdf"
        case "a GIF image": return "gif"
        case "a WebP image": return "webp"
        case "text": return "txt"
        default: return "bin"
        }
    }
}

/// The structure of a channel message's body: which fields are set, enum values, counts and
/// lengths. Never a name, an identifier or any other text from it.
func describeNanoBody(path: String, body: Data) -> String? {
    // JSON, as the Phone Link workflows speak it: the names and kinds of its values, or with
    // "--text" the text itself, for working out a protocol on one's own recording.
    if body.first == UInt8(ascii: "{"), let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
        if CommandLine.arguments.contains("--text") { return "JSON: " + String(decoding: body.prefix(1200), as: UTF8.self) }
        func kind(_ value: Any) -> String {
            switch value {
            case let text as String: return "text(\(text.count))"
            case let list as [Any]: return "list(\(list.count))"
            case let nested as [String: Any]: return "{" + nested.keys.sorted().map { "\($0): \(kind(nested[$0]!))" }.joined(separator: ", ") + "}"
            case is NSNumber: return "number"
            default: return "null"
            }
        }
        return "JSON " + kind(object)
    }
    if path.hasSuffix("/ProtoCreatePlatformChannelRequest"), let message = try? PlatformSdk_V1_ProtoCreatePlatformChannelRequest(serializedBytes: body) {
        return "create platform channel: type \(message.type), scenario id \(message.scenarioID.count) chars, channel id \(message.channelID.count) chars, "
            + "trace context \(message.hasTraceContext), additional properties \(message.additionalProperties.keys.sorted())"
    }
    if path.hasSuffix("/ProtoPeerPlatformChannelCreationResult"), let message = try? PlatformSdk_V1_ProtoPeerPlatformChannelCreationResult(serializedBytes: body) {
        return "creation result: type \(message.type), result \(message.resultCode), reason \(message.resultReason), channel id \(message.channelID.count) chars"
    }
    if path.contains("/NamedStreams/"), let message = try? FileTransfer_V1_FileShareMessage(serializedBytes: body), !message.scenario.isEmpty {
        let items = message.content.map { "{id \($0.fileID.count) chars, name \($0.fileName.count) chars, size \($0.fileSize), hash \($0.fileHash.count) chars, status \($0.fileStatus)}" }
        return "file share message: scenario \(message.scenario), transfer id \(message.transferID.count) chars, sender name \(message.senderName.count) chars, "
            + "received \(message.receivedFileCount), try \(message.sessionTryCount), folder \(message.pcFolder.count) chars, concurrent \(message.isConcurrentMode), items \(items)"
    }
    if path.hasSuffix("/ManifestRequest") {
        var text = "manifest request, field numbers \(fieldNumbers(body))"
        if let manifest = try? PlatformSdk_V1_ProtoManifest(serializedBytes: body), !manifest.entries.isEmpty {
            text += "; as a manifest: \(manifest.entries.count) entries, " + manifest.entries.values.map { "{id \($0.id.count) chars, size \($0.size), metadata \($0.metadata.keys.sorted())}" }.joined(separator: " ")
                + ", trace context \(manifest.hasTraceContext)"
        }
        if let request = try? PlatformSdk_V1_ProtoManifestStreamRequest(serializedBytes: body), !request.id.isEmpty { text += "; as a stream request: id \(request.id.count) chars" }
        return text
    }
    return "field numbers \(fieldNumbers(body))"
}

// winphone-probe nano-signalling <flows.jsonl> [from-seq]
//
// The peer-to-peer signalling on the relay, in order, with the fields a client has to
// reproduce. Keys, salts, relay credentials and candidate lists are never printed; addresses
// are reduced to whether they are private ones.
func runNanoSignalling(flows: String, from: Int) -> Never {
    guard let handle = FileHandle(forReadingAtPath: flows) else { exit(1) }
    let contents = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    var requestRoutes: [String: String] = [:]
    func show(_ any: Any?) -> String {
        switch any {
        case let text as String: return "\"\(text)\""
        case let number as NSNumber: return "\(number)"
        default: return "?"
        }
    }
    for line in contents.split(separator: "\n") {
        guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              record["type"] as? String == "ws", let raw = (record["raw_b64"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let frames = try? SignalR.splitFrames(raw) else { continue }
        let seq = (record["seq"] as? NSNumber)?.intValue ?? 0
        guard seq >= from else { continue }
        let direction = record["dir"] as? String == "c2s" ? "PC>" : "PH>"
        let stamp = (record["ts"] as? NSNumber)?.doubleValue ?? 0
        let time = Date(timeIntervalSince1970: stamp).formatted(date: .omitted, time: .standard)
        for frame in frames {
            guard case .invocation(_, _, _, let arguments)? = try? HubMessage(frame: frame), arguments.count >= 3,
                  case .fragment(let fragment)? = try? DcgPacket(arguments[2]), fragment.messageType == .platform,
                  let envelope = try? PlatformEnvelope(decoding: fragment.raw) else { continue }
            let route = envelope.route ?? ""
            if let id = envelope.requestId { requestRoutes[id] = route }
            let headers = envelope.headers.filter { !$0.key.hasPrefix("_") || $0.key == "_rejectedReason" }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            if route.hasPrefix("/Context/Message") {
                let suffix = route.dropFirst("/Context/Message".count)
                var text = "#\(seq) \(time) \(direction) /Context/Message\(suffix.isEmpty ? "" : "/<\(suffix.dropFirst().prefix(8))>") [\(headers)]"
                if let message = try? PlatformSdk_V1_ContextSourceMessage(serializedBytes: envelope.payload), let kind = message.type {
                    switch kind {
                    case .csInitializeMessage(let value):
                        text += " initialize: source id <\(value.contextSourceID.prefix(8))>, preference \(value.transportPreference), trace \(value.hasTraceContext)"
                    case .csInitializeAckMessage(let value): text += " initialize ack: \(value.status)"
                    case .csOpenDeviceConnectionRequest(let value): text += " open device connection: scenario \"\(value.scenarioID)\""
                    case .csConnectionInfo(let description):
                        let object = (try? JSONSerialization.jsonObject(with: Data(description.connectionInfo.utf8)) as? [String: Any]) ?? [:]
                        let info = object["connectioninformation"] as? [String: Any] ?? [:]
                        text += " connection info: connectionid <\((object["connectionid"] as? String ?? "").count) chars>, connectiontype \(show(object["connectiontype"])), multipleconnections \(show(object["multipleconnections"])), trace \(description.hasTraceContext)"
                        if let ip = info["ip"] as? [String: Any] {
                            var entries: [String] = []
                            for index in 0..<8 { if let entry = ip["\(index)"] as? [String: Any] { entries.append("\(entry["iname"] as? String ?? "?")") } }
                            text += ", ip count \(show(ip["count"])) interfaces \(entries), port type \(type(of: info["port"] as Any)), keepalive \(show((info["keepalive"] as? [String: Any])?["warningtimeout"]))"
                        }
                        if info["ice"] != nil { text += ", ice" }
                        if let security = info["security"] as? [String: Any] {
                            text += ", security key \((security["key"] as? String ?? "").count) chars"
                            if let keys = NanoRecording.keys(inConnectionDescription: description.connectionInfo) { text += " (key set \(nanoKeyIndex(keys)))" }
                        }
                        if info.isEmpty { text += ", empty information" }
                        // The description itself, with every secret and address replaced by its shape.
                        if (object["connectiontype"] as? NSNumber)?.intValue == 0 {
                            var masked = description.connectionInfo
                            for pattern in ["(\"key\"\\s*:\\s*\")[0-9a-fA-F]+", "(\"salt\"\\s*:\\s*\")[0-9a-fA-F]+"] {
                                masked = masked.replacingOccurrences(of: pattern, with: "$1<hex>", options: .regularExpression)
                            }
                            masked = masked.replacingOccurrences(of: "[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}", with: "<ipv4>", options: .regularExpression)
                            masked = masked.replacingOccurrences(of: "\"[0-9a-fA-F:]*:[0-9a-fA-F:]*:[0-9a-fA-F:%a-z0-9]*\"", with: "\"<ipv6>\"", options: .regularExpression)
                            let connectionId = object["connectionid"] as? String ?? ""
                            let letterCase = connectionId == connectionId.lowercased() ? "lower case" : connectionId == connectionId.uppercased() ? "upper case" : "mixed case"
                            masked = masked.replacingOccurrences(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", with: "<guid, \(letterCase), id \(nanoIdIndex(connectionId))>", options: .regularExpression)
                            text += "\n      " + masked
                        }
                    default: text += " \(kind)"
                    }
                } else {
                    text += " payload \(envelope.payload.count) bytes, field numbers \(fieldNumbers(envelope.payload))"
                }
                print(text)
            } else if route == DeviceResources.route, let message = try? PlatformSdk_V1_DeviceResourceManagerMessage(serializedBytes: envelope.payload),
                      message.resourcePath.contains("fileshare") || message.resourcePath.contains("permissions") {
                print("#\(seq) \(time) \(direction) resource \(message.resourcePath) \(message.requestType), type \(message.resourceType), payload \(message.payload.count) bytes fields \(fieldNumbers(message.payload))")
            } else if route == PeerMessenger.responseRoute, let id = envelope.originalRequestId, let original = requestRoutes[id],
                      original.hasPrefix("/Context/Message") || original == DeviceResources.route {
                var text = "#\(seq) \(time) \(direction) answer to \(original.hasPrefix("/Context/Message") ? "/Context/Message…" : original) [\(headers)] \(envelope.payload.count) bytes"
                if original.hasPrefix("/Context/Message") { text += " fields \(fieldNumbers(envelope.payload)) hex \(envelope.payload.prefix(40).map { String(format: "%02x", $0) }.joined())" }
                if original == DeviceResources.route, let response = try? PlatformSdk_V1_DeviceResourceManagerResponseMessage(serializedBytes: envelope.payload) {
                    text += " response type \(response.responseType), payload \(response.payload.count) bytes fields \(fieldNumbers(response.payload))"
                }
                if original.hasPrefix("/Context/Message") || envelope.payload.count < 200 { print(text) }
            }
        }
    }
    exit(0)
}

nonisolated(unsafe) var nanoKeyOrder: [NanoSessionKeys] = []
/// A small number standing for a key set, the same for the same keys, so that two lines can
/// be seen to carry the same key without showing it.
func nanoKeyIndex(_ keys: NanoSessionKeys) -> Int {
    if let index = nanoKeyOrder.firstIndex(of: keys) { return index + 1 }
    nanoKeyOrder.append(keys)
    return nanoKeyOrder.count
}

nonisolated(unsafe) var nanoIdOrder: [String] = []
/// A small number standing for an identifier, to show which lines share one.
func nanoIdIndex(_ id: String) -> Int {
    if let index = nanoIdOrder.firstIndex(of: id) { return index + 1 }
    nanoIdOrder.append(id)
    return nanoIdOrder.count
}

/// For each key set in a relay capture: who sent the description that carried it and of
/// which connection type. Shows nothing of the key.
func nanoKeyOrigins(inFlows path: String) -> [(keys: NanoSessionKeys, origin: String)] {
    guard let contents = FileManager.default.contents(atPath: path) else { return [] }
    var result: [(NanoSessionKeys, String)] = []
    for line in String(decoding: contents, as: UTF8.self).split(separator: "\n") {
        guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              record["type"] as? String == "ws", let raw = (record["raw_b64"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let frames = try? SignalR.splitFrames(raw) else { continue }
        let direction = record["dir"] as? String == "c2s" ? "the PC" : "the phone"
        for frame in frames {
            guard case .invocation(_, _, _, let arguments)? = try? HubMessage(frame: frame), arguments.count >= 3,
                  case .fragment(let fragment)? = try? DcgPacket(arguments[2]),
                  let envelope = try? PlatformEnvelope(decoding: fragment.raw), envelope.route?.hasPrefix("/Context/Message") == true,
                  let message = try? PlatformSdk_V1_ContextSourceMessage(serializedBytes: envelope.payload),
                  case .csConnectionInfo(let info)? = message.type,
                  let keys = NanoRecording.keys(inConnectionDescription: info.connectionInfo),
                  let object = try? JSONSerialization.jsonObject(with: Data(info.connectionInfo.utf8)) as? [String: Any] else { continue }
            result.append((keys, "\(direction), connection type \((object["connectiontype"] as? NSNumber)?.intValue ?? -1)"))
        }
    }
    return result
}
