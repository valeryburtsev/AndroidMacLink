import Foundation
import SwiftProtobuf

/// One clipboard entry as exchanged with the phone.
public enum ClipboardContent: Equatable, Sendable {
    case text(String)
    case html(String)
    /// Encoded image bytes. The phone labels what it receives as PNG without inspecting it,
    /// and sends JPEG, PNG, GIF or BMP unchanged, so receivers must sniff the format.
    case image(Data)

    /// The phone refuses text of this many UTF-16 code units or more.
    public static let maxTextUnits = 131_072
    /// The phone keeps images within this many bytes.
    public static let maxImageBytes = 1_048_576

    var isWithinLimits: Bool {
        switch self {
        case .text(let s), .html(let s): return s.utf16.count < ClipboardContent.maxTextUnits
        case .image(let d): return !d.isEmpty && d.count <= ClipboardContent.maxImageBytes
        }
    }

    var item: Clipboard_V1_ClipboardItem {
        var item = Clipboard_V1_ClipboardItem()
        switch self {
        case .text(let s): item.itemType = .textPlain; item.text = s
        case .html(let s): item.itemType = .textHtml; item.text = s
        case .image(let d): item.itemType = .image; item.imageBytes = d
        }
        return item
    }

    init?(_ item: Clipboard_V1_ClipboardItem) {
        switch item.itemType {
        case .textPlain where item.hasText: self = .text(item.text)
        case .textHtml where item.hasText: self = .html(item.text)
        case .image where item.hasImageBytes && !item.imageBytes.isEmpty: self = .image(item.imageBytes)
        default: return nil
        }
    }
}

/// The local clipboard, as the sync engine needs it.
public protocol LocalClipboard: Sendable {
    /// The current content, or nil when the clipboard holds nothing we can send.
    func read() async -> ClipboardContent?
    func write(_ content: ClipboardContent) async
}

/// Cross-device clipboard sync with a phone, over the device resource manager (`/clipboard`)
/// and publications with tag 9.
///
/// Either side announces a change by publishing `CLIPBOARD_CHANGE` with a correlation ID; the
/// other side then pulls the content with a `CONTENT` request. Nothing is pushed unasked.
public actor ClipboardSync {
    public static let resourcePath = "/clipboard"

    public enum FeatureState: Equatable, Sendable { case on, off, disabled }

    public enum SyncError: Error, Equatable {
        case refused(status: Int, detail: String)
        case malformedResponse
    }

    private let resources: DeviceResources
    private let publisher: ContextPublisher
    private let local: LocalClipboard
    /// How long after the start to make the phone look at its clipboard watcher again; nil
    /// leaves that out. See `promptPhoneToWatch`.
    private let rewatchAfter: Duration?
    /// What we last wrote from the phone, so the resulting local change is not announced back.
    private var lastFromPeer: ClipboardContent?
    /// What we last announced, to avoid announcing the same content twice.
    private var lastAnnounced: ClipboardContent?
    public private(set) var peerState: FeatureState?
    public private(set) var isEnabled = true
    private let continuation: AsyncStream<ClipboardContent>.Continuation
    /// Content pulled from the phone and written locally, in order.
    public nonisolated let received: AsyncStream<ClipboardContent>

    public init(resources: DeviceResources, publisher: ContextPublisher, local: LocalClipboard, rewatchAfter: Duration? = nil) {
        self.resources = resources
        self.publisher = publisher
        self.local = local
        self.rewatchAfter = rewatchAfter
        (received, continuation) = AsyncStream.makeStream(of: ClipboardContent.self, bufferingPolicy: .bufferingNewest(16))
    }

    /// Registers handlers and tells the phone whether the feature is on.
    public func start(enabled: Bool = true) async throws {
        await resources.serve(ClipboardSync.resourcePath) { [weak self] request in
            await self?.answer(request)
        }
        await publisher.subscribe(.clipboard) { [weak self] publication in
            await self?.received(publication)
        }
        try await setEnabled(enabled)
        if enabled, let rewatchAfter {
            Task { [weak self] in
                try? await Task.sleep(for: rewatchAfter)
                await self?.promptPhoneToWatch()
            }
        }
    }

    /// Makes the phone watch its clipboard again, by turning the feature off and on.
    ///
    /// The phone watches its clipboard only while a WEA client is active, and decides that when
    /// a connection changes state. If it decides before this link is back, it stops watching,
    /// and a plain FEATURE_ON does not help: for a client already marked on it returns without
    /// deciding again. Copies on the phone then never arrive, while copies on the Mac still do
    /// (seen 2026-10-31). A FEATURE_OFF first makes the FEATURE_ON count. It also clears the
    /// phone's clipboard history for this client.
    func promptPhoneToWatch() async {
        guard isEnabled else { return }
        do {
            var off = Clipboard_V1_ClipboardRequestMessage()
            off.requestType = .featureOff
            _ = try await send(off)
            // Switched off here meanwhile: off is what the phone should stay.
            guard isEnabled else { return }
            var on = Clipboard_V1_ClipboardRequestMessage()
            on.requestType = .featureOn
            _ = try await send(on)
            diag("clipboard", "asked the phone to watch its clipboard again")
        } catch {
            // The next connection tells it again.
            diag("clipboard", "could not ask the phone to watch its clipboard again: \(error)")
        }
    }

    /// Turns sync on or off and tells the phone.
    public func setEnabled(_ enabled: Bool) async throws {
        isEnabled = enabled
        var request = Clipboard_V1_ClipboardRequestMessage()
        request.requestType = enabled ? .featureOn : .featureOff
        let response = try await send(request)
        guard response.status == .ok else {
            throw SyncError.refused(status: response.status.rawValue, detail: response.errorDetail)
        }
    }

    /// Call when the local clipboard changed. Announces the change to the phone unless the
    /// content is what the phone just sent us, or what we already announced.
    /// - Returns: What was announced, or nil when there was nothing new to tell the phone.
    @discardableResult
    public func localClipboardChanged() async throws -> ClipboardContent? {
        guard isEnabled, let content = await local.read(), content.isWithinLimits else { return nil }
        if content == lastFromPeer || content == lastAnnounced { return nil }
        lastAnnounced = content
        var message = Clipboard_V1_ClipboardResponseMessage()
        message.status = .clipboardChange
        message.correlationID = TraceContext.randomHex(bytes: 16)
        try await publisher.publish(.clipboard, body: try message.serializedData(),
                                    trace: TraceContext(scenarioId: "clipboard", triggerId: "clipboardChanged"))
        return content
    }

    /// Pulls the phone's current clipboard and writes it locally. The phone answers a content
    /// request with its current clip regardless of the correlation ID, so this also works
    /// without a preceding announcement.
    @discardableResult
    public func pull(correlationId: String = TraceContext.randomHex(bytes: 16)) async throws -> ClipboardContent {
        var request = Clipboard_V1_ClipboardRequestMessage()
        request.requestType = .content
        request.correlationID = correlationId
        let response = try await send(request)
        switch response.status {
        case .ok:
            guard response.clipboardItem.count == 1, let content = ClipboardContent(response.clipboardItem[0]) else {
                throw SyncError.malformedResponse
            }
            lastFromPeer = content
            lastAnnounced = nil
            await local.write(content)
            continuation.yield(content)
            return content
        case .featureOff:
            peerState = .off
        case .featureDisable:
            peerState = .disabled
        default:
            break
        }
        throw SyncError.refused(status: response.status.rawValue, detail: response.errorDetail)
    }

    // MARK: Phone-initiated

    private func received(_ publication: ContextPublisher.Publication) async {
        guard let message = try? Clipboard_V1_ClipboardResponseMessage(serializedBytes: publication.body) else { return }
        switch message.status {
        case .clipboardChange:
            guard isEnabled else { return }
            // Pull without holding up the handler queue: the phone may take a while to answer.
            diag("clipboard", "the phone says its clipboard changed")
            let correlation = message.correlationID
            Task {
                do {
                    _ = try await self.pull(correlationId: correlation)
                } catch {
                    diag("clipboard", "could not fetch it from the phone: \(error)")
                }
            }
        case .featureOn: peerState = .on
        case .featureOff: peerState = .off
        case .featureDisable: peerState = .disabled
        default: break
        }
    }

    /// Answers the phone's `/clipboard` request.
    private func answer(_ request: DeviceResources.IncomingRequest) async -> Data? {
        var response = Clipboard_V1_ClipboardResponseMessage()
        defer { _ = response }
        guard request.type == .get || request.type == .sync else {
            response.status = .invalidDeviceResourceRequestType
            return try? response.serializedData()
        }
        guard let message = try? Clipboard_V1_ClipboardRequestMessage(serializedBytes: request.payload) else {
            response.status = .unrecognizedPayload
            return try? response.serializedData()
        }
        response.correlationID = message.correlationID
        switch message.requestType {
        case .status:
            response.status = isEnabled ? .featureOn : .featureOff
        case .content:
            if !isEnabled {
                response.status = .featureOff
            } else if let content = await local.read() {
                if content.isWithinLimits {
                    var item = content.item
                    item.createdTime = Google_Protobuf_Timestamp(date: Date())
                    response.clipboardItem = [item]
                    response.status = .ok
                } else {
                    response.status = .invalidContent
                    response.errorType = .reject
                    response.errorDetail = "SizeExceed"
                }
            } else {
                response.status = .invalidContent
                response.errorType = .reject
                response.errorDetail = "NoClipData"
            }
        case .featureOn:
            peerState = .on
            response.status = .ok
        case .featureOff:
            peerState = .off
            response.status = .ok
        case .featureDisable:
            peerState = .disabled
            response.status = .ok
        default:
            response.status = .invalidClipboardRequestType
        }
        return try? response.serializedData()
    }

    private func send(_ request: Clipboard_V1_ClipboardRequestMessage) async throws -> Clipboard_V1_ClipboardResponseMessage {
        let payload = try await resources.request(ClipboardSync.resourcePath, payload: try request.serializedData(),
                                                  trace: TraceContext(scenarioId: "clipboard", triggerId: "request"))
        guard let response = try? Clipboard_V1_ClipboardResponseMessage(serializedBytes: payload) else { throw SyncError.malformedResponse }
        return response
    }
}
