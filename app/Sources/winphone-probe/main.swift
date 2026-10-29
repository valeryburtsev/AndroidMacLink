import Foundation
import SwiftProtobuf
import WinPhoneCore

// Command-line companion to the app. Today it decodes relay traffic from the capture proxy:
//
//   winphone-probe app-messages <flows.jsonl> [--route /legacy/phonecontent] [--content-type notifications] [--full]
//
// It reads the raw WebSocket records written by tools/capture (`phonelink_raw_ws=true`), splits
// the SignalR frames, unwraps the DCG fragments and envelopes with the library's own codecs, and
// prints APP payloads as value sets. Long strings are shortened unless `--full` is given.

struct Options {
    var file: String
    var route: String?
    var contentType: String?
    var full = false
    /// Print field names, types and sizes only, never values.
    var shape = false
    var fromSeq = 0
}

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: winphone-probe app-messages <flows.jsonl> [--route R] [--content-type T] [--full] [--shape] [--from seq]\n       winphone-probe nano-check <recording.pcap> <flows.jsonl>\n       winphone-probe nano-file <recording.pcap> <flows.jsonl> [--save <folder>]\n       winphone-probe nano-dump <recording.pcap> <flows.jsonl> [head-bytes]\n".utf8))
    exit(2)
}

func parse(_ arguments: [String]) -> Options {
    guard arguments.count >= 3, arguments[1] == "app-messages" else { usage() }
    var options = Options(file: arguments[2])
    var index = 3
    while index < arguments.count {
        switch arguments[index] {
        case "--route" where index + 1 < arguments.count: options.route = arguments[index + 1]; index += 2
        case "--content-type" where index + 1 < arguments.count: options.contentType = arguments[index + 1]; index += 2
        case "--full": options.full = true; index += 1
        case "--shape": options.shape = true; index += 1
        case "--from" where index + 1 < arguments.count: options.fromSeq = Int(arguments[index + 1]) ?? 0; index += 2
        default: usage()
        }
    }
    return options
}

func shorten(_ text: String, full: Bool) -> String {
    if full || text.count <= 200 { return text }
    return String(text.prefix(200)) + "… (\(text.count) chars)"
}

/// Values that say what a message is rather than what the user wrote; safe to show in shape mode.
let structuralKeys: Set<String> = ["contentType", "operation", "operations", "result", "itemCount", "incremental", "contractVersion", "retryCount"]

func shapeOf(_ value: ValueSet.Value, indent: String) -> String {
    switch value {
    case .int32: return "Int32"
    case .int64: return "Int64"
    case .uint32: return "UInt32"
    case .double: return "Double"
    case .bool: return "Bool"
    case .string(let v): return "String(\(v.utf16.count))"
    case .int32Array(let v): return "Int32[\(v.count)]"
    case .int64Array(let v): return "Int64[\(v.count)]"
    case .stringArray(let v): return "String[\(v.count)]" + (v.isEmpty ? "" : " lengths \(v.prefix(6).map { $0.utf16.count })")
    case .bytes(let v): return "Bytes(\(v.count))"
    case .boolArray(let v): return "Bool[\(v.count)]"
    case .object(let v): return "Object" + render(v, full: false, indent: indent + "  ", shape: true)
    case .other(let v): return "Other(type \(v.valueType.rawValue), \((try? v.serializedData().count) ?? 0) bytes)"
    }
}

func describe(_ value: ValueSet.Value, full: Bool, indent: String) -> String {
    switch value {
    case .int32(let v): return "Int32 \(v)"
    case .int64(let v): return "Int64 \(v)"
    case .uint32(let v): return "UInt32 \(v)"
    case .double(let v): return "Double \(v)"
    case .bool(let v): return "Bool \(v)"
    case .string(let v): return "String \"\(shorten(v, full: full))\""
    case .int32Array(let v): return "Int32[\(v.count)] \(v.prefix(16).map(String.init).joined(separator: ","))"
    case .int64Array(let v): return "Int64[\(v.count)] \(v.prefix(16).map(String.init).joined(separator: ","))"
    case .stringArray(let v):
        let items = v.map { "\n\(indent)    \"\(shorten($0, full: full))\"" }.joined()
        return "String[\(v.count)]" + items
    case .bytes(let v): return "Bytes(\(v.count))"
    case .boolArray(let v): return "Bool[\(v.count)] \(v.prefix(16).map { $0 ? "1" : "0" }.joined())"
    case .object(let v): return "Object" + render(v, full: full, indent: indent + "  ")
    case .other(let v): return "Other(type \(v.valueType.rawValue))"
    }
}

func render(_ values: ValueSet, full: Bool, indent: String, shape: Bool = false) -> String {
    values.entries.keys.sorted().map { key in
        if shape, !structuralKeys.contains(key) { return "\n\(indent)\(key): \(shapeOf(values.entries[key]!, indent: indent))" }
        // The phone reports the account's sign-in name here; never print it.
        if key == "userId" { return "\n\(indent)\(key): String (hidden)" }
        return "\n\(indent)\(key): \(describe(values.entries[key]!, full: full, indent: indent))"
    }.joined()
}

func prettyJSON(_ text: String) -> String? {
    guard let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return nil }
    return String(data: pretty, encoding: .utf8)
}

/// Resource path of each device-resource request seen, by request ID, to decode its answer.
var resourcePaths: [String: String] = [:]

/// Sizes and types of a clipboard message, never its content.
func describeClipboard(_ message: Clipboard_V1_ClipboardResponseMessage) -> String {
    var parts = ["clipboard status \(message.status)"]
    if !message.correlationID.isEmpty { parts.append("correlation \(message.correlationID.prefix(8))") }
    if message.errorType != .unspecified || !message.errorDetail.isEmpty { parts.append("error \(message.errorType) \(message.errorDetail)") }
    for item in message.clipboardItem {
        parts.append("item \(item.itemType): text \(item.text.utf16.count) units, image \(item.imageBytes.count) bytes")
    }
    return parts.joined(separator: "; ")
}

/// Top-level protobuf field numbers of a message, to identify an unknown body without its values.
func fieldNumbers(_ data: Data) -> [Int] {
    var numbers: [Int] = [], index = data.startIndex
    func varint() -> UInt64? {
        var value: UInt64 = 0, shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]; index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
    while index < data.endIndex {
        guard let key = varint() else { break }
        numbers.append(Int(key >> 3))
        switch key & 7 {
        case 0: _ = varint()
        case 1: index += 8
        case 2: guard let length = varint(), Int(length) <= data.endIndex - index else { return numbers }; index += Int(length)
        case 5: index += 4
        default: return numbers
        }
    }
    return numbers
}

/// What a PLATFORM envelope carries, for the routes this project understands.
func describePlatform(_ envelope: PlatformEnvelope) -> String? {
    switch envelope.route {
    case ContextPublisher.route:
        guard let message = try? PlatformSdk_V1_MsaepMessage(serializedBytes: envelope.payload),
              let payload = try? PlatformSdk_V1_PubSubPayload(serializedBytes: message.payload) else { return nil }
        let body = payload.additional.isEmpty ? payload.data : payload.additional
        var text = "publish tag \(message.messageTag), \(body.count) bytes"
        if message.messageTag == ContextPublisher.Tag.clipboard.rawValue, let clip = try? Clipboard_V1_ClipboardResponseMessage(serializedBytes: body) {
            text += ": " + describeClipboard(clip)
        }
        if message.messageTag == ContextPublisher.Tag.deviceStatus.rawValue {
            if let status = PhoneStatus(response: body) {
                text += ": status response, battery \(status.batteryPercent.map(String.init) ?? "none"), charging \(status.isCharging), network \(status.network)"
            } else {
                text += ": not a status response (field numbers \(fieldNumbers(body)))"
            }
        }
        return text
    case DeviceResources.route:
        guard let message = try? PlatformSdk_V1_DeviceResourceManagerMessage(serializedBytes: envelope.payload) else { return nil }
        if let id = envelope.requestId { resourcePaths[id] = message.resourcePath }
        var text = "resource \(message.resourcePath) request type \(message.requestType)"
        if message.resourcePath == ClipboardSync.resourcePath, let request = try? Clipboard_V1_ClipboardRequestMessage(serializedBytes: message.payload) {
            text += ": clipboard request \(request.requestType), correlation \(request.correlationID.prefix(8))"
        }
        return text
    case PeerMessenger.responseRoute:
        guard let id = envelope.originalRequestId, let path = resourcePaths[id],
              let response = try? PlatformSdk_V1_DeviceResourceManagerResponseMessage(serializedBytes: envelope.payload) else { return nil }
        var text = "answer for \(path), response type \(response.responseType), \(response.payload.count) bytes"
        if path == ClipboardSync.resourcePath, let clip = try? Clipboard_V1_ClipboardResponseMessage(serializedBytes: response.payload) {
            text += ": " + describeClipboard(clip)
        }
        return text
    default:
        if envelope.route?.hasPrefix("/Context/Message") == true { return describeContextSource(envelope.payload) }
        return nil
    }
}

/// The names of a JSON object's keys, nested, without any value.
func keyNames(_ object: Any, depth: Int = 0) -> String {
    guard depth < 4, let dictionary = object as? [String: Any] else { return "" }
    return "{" + dictionary.keys.sorted().map { key in key + keyNames(dictionary[key] as Any, depth: depth + 1) }.joined(separator: ", ") + "}"
}

/// A peer-to-peer signalling message: which kind, and the shape of what it carries. The
/// connection description holds key material, so only its key names are shown.
func describeContextSource(_ payload: Data) -> String? {
    var message = try? PlatformSdk_V1_ContextSourceMessage(serializedBytes: payload)
    if message?.type == nil, let wrapped = try? PlatformSdk_V1_MsaepMessage(serializedBytes: payload) {
        message = try? PlatformSdk_V1_ContextSourceMessage(serializedBytes: wrapped.payload)
    }
    guard let type = message?.type else { return "context source message, field numbers \(fieldNumbers(payload))" }
    switch type {
    case .csInitializeMessage(let value): return "initialize, source id \(value.contextSourceID.count) chars, transport preference \(value.transportPreference)"
    case .csInitializeAckMessage(let value): return "initialize ack, status \(value.status)"
    case .csOpenDeviceConnectionRequest(let value): return "open device connection, scenario \(value.scenarioID.count) chars"
    case .csConnectionInfo(let value):
        let info = value.connectionInfo
        var text = "connection info, \(info.count) chars"
        if let object = try? JSONSerialization.jsonObject(with: Data(info.utf8)) { text += ", keys " + keyNames(object) }
        return text
    case .csErrorInfo: return "error info"
    case .csWifiP2PInfo: return "Wi-Fi Direct info"
    case .csIdentityChallenge(let value): return "identity challenge, \(value.challenge.count) bytes"
    case .csIdentityResponse(let value): return "identity response, \(value.challenge.count) bytes"
    }
}

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "nano-descriptions" {
    // Every connection description of a relay capture as one JSON object per line, for study.
    // The output holds key material: write it to a scratch place and delete it.
    let contents = (try? String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)) ?? ""
    var lines: [String] = []
    for entry in NanoRecording.descriptions(inRelayCapture: contents) {
        let object: [String: Any] = ["ts": entry.time, "route": entry.route, "text": entry.text]
        if let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8) { lines.append(line) }
    }
    try? lines.joined(separator: "\n").write(toFile: CommandLine.arguments[3], atomically: true, encoding: .utf8)
    print("\(lines.count) connection descriptions")
    exit(0)
}
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "nano-signalling" {
    runNanoSignalling(flows: CommandLine.arguments[2], from: CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 0 : 0)
}
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "nano-file" {
    let arguments = CommandLine.arguments
    let save = arguments.firstIndex(of: "--save").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    runNanoFile(pcap: arguments[2], flows: arguments[3], saveTo: save)
}
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "nano-dump" {
    runNanoDump(pcap: CommandLine.arguments[2], flows: CommandLine.arguments[3], head: CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4]) ?? 32 : 32)
}
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "nano-check" {
    runNanoCheck(pcap: CommandLine.arguments[2], flows: CommandLine.arguments[3])
}
let options = parse(CommandLine.arguments)
guard let handle = FileHandle(forReadingAtPath: options.file) else {
    FileHandle.standardError.write(Data("cannot open \(options.file)\n".utf8))
    exit(1)
}
let contents = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
var shown = 0
var shownRequests: Set<String> = []
for line in contents.split(separator: "\n") {
    guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          record["type"] as? String == "ws", let raw = (record["raw_b64"] as? String).flatMap({ Data(base64Encoded: $0) }),
          let frames = try? SignalR.splitFrames(raw) else { continue }
    let direction = record["dir"] as? String == "c2s" ? "PC>" : "PH>"
    let seq = (record["seq"] as? NSNumber)?.stringValue ?? record["seq"] as? String ?? "?"
    if (Int(seq) ?? 0) < options.fromSeq { continue }
    let stamp = (record["ts"] as? NSNumber)?.doubleValue ?? (record["ts"] as? String).flatMap(Double.init)
    let time = stamp.map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .standard) } ?? ""
    for frame in frames {
        guard case .invocation(_, _, let target, let arguments)? = try? HubMessage(frame: frame),
              ["SendMessageAsync", "OnReceiveMessage", "OnReceiveSessionBasedMessage"].contains(target), arguments.count >= 3,
              case .fragment(let fragment)? = try? DcgPacket(arguments[2]),
              let envelope = try? PlatformEnvelope(decoding: fragment.raw) else { continue }
        let route = envelope.route ?? "(no route)"
        let isReply = envelope.route == PeerMessenger.responseRoute
        var values: ValueSet?
        if fragment.messageType == .app { values = try? ValueSet(serialized: envelope.payload) }
        if isReply {
            // With a filter, a reply is shown only when its request was.
            if options.route != nil || options.contentType != nil {
                guard let id = envelope.originalRequestId, shownRequests.contains(id) else { continue }
            }
        } else {
            if let wanted = options.route, route != wanted { continue }
            if let wanted = options.contentType, values?.string("contentType") != wanted { continue }
            if let id = envelope.requestId { shownRequests.insert(id) }
        }
        shown += 1
        let kind = fragment.messageType == .app ? "APP" : "PLATFORM"
        var text = "#\(seq) \(time) \(direction) \(kind) \(route)"
        let headers = envelope.headers.filter { $0.key != PlatformEnvelope.Header.route }.map { "\($0.key)=\($0.value)" }
        if !headers.isEmpty { text += "  [" + headers.joined(separator: " ") + "]" }
        text += "  payload \(envelope.payload.count) bytes"
        if let values {
            text += render(values, full: options.full, indent: "  ", shape: options.shape)
            // Notification documents are JSON strings inside the value set; show them readably.
            for document in (options.shape ? [] : values.strings("notifications") ?? []) where !document.isEmpty {
                if let pretty = prettyJSON(document) { text += "\n  notification:\n" + pretty.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n") }
            }
        } else if fragment.messageType == .app {
            text += "\n  (payload is not a value set)"
        } else if let detail = describePlatform(envelope) {
            text += "\n  " + detail
        }
        print(text)
    }
}
if shown == 0 { print("no matching messages in \(options.file)") }
