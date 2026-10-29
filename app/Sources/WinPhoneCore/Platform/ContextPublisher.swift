import Foundation
import SwiftProtobuf

/// Publish and subscribe over the relay. A publication is a PLATFORM request on
/// `/Context/Publish` carrying a tagged message; there is no subscribe message, a subscriber
/// simply reacts to the tags it cares about.
public actor ContextPublisher {
    public static let route = "/Context/Publish"

    /// Feature tags of published messages.
    public enum Tag: Int32, Sendable {
        case proximalOnboarding = 1, cameraStreaming = 2, permissionSyncResponse = 3, phoneFiles = 4
        case wallpaper = 5, media = 6, contentUpdate = 7, deviceStatus = 8, clipboard = 9, phoneMirroring = 10, hotspot = 11
    }

    public struct Publication: Equatable, Sendable {
        public var tag: Int32
        /// The publisher's DCG client ID.
        public var publisher: String
        public var messageId: String
        /// The feature message. The phone puts it in `additional`; cameras and PCs use `data`.
        public var body: Data
    }

    public typealias Subscriber = @Sendable (Publication) async -> Void

    private let messenger: PeerMessenger
    private let ownId: String
    private var subscribers: [Int32: Subscriber] = [:]
    private var lastMessageId: [Int32: String] = [:]

    /// - Parameter ownId: this device's DCG client ID, sent as the publisher.
    public init(messenger: PeerMessenger, ownId: String) {
        self.messenger = messenger
        self.ownId = ownId
    }

    /// Starts receiving the peer's publications. Call once.
    public func start() async {
        await messenger.handle(ContextPublisher.route) { [weak self] request, messenger in
            // Phone Link acknowledges every publication with an empty JSON object.
            try? await messenger.respond(to: request, payload: Data("{}".utf8), contentType: PeerMessenger.jsonContentType)
            await self?.receive(request.payload)
        }
    }

    public func subscribe(_ tag: Tag, _ subscriber: @escaping Subscriber) {
        subscribers[tag.rawValue] = subscriber
    }

    /// Publishes a feature message to the peer. Windows sends publications one-way and puts the
    /// message in `data`, which is the field the phone's subscribers read.
    public func publish(_ tag: Tag, body: Data, trace: TraceContext = TraceContext()) async throws {
        var payload = PlatformSdk_V1_PubSubPayload()
        payload.data = body
        var message = PlatformSdk_V1_MsaepMessage()
        message.messageTag = tag.rawValue
        message.dcgClientID = ownId
        message.messageID = UUID().uuidString.lowercased()
        message.payload = try payload.serializedData()
        message.platformMajorVersion = 1
        message.platformMinorVersion = 1
        try await messenger.post(route: ContextPublisher.route, payload: try message.serializedData(), trace: trace)
    }

    private func receive(_ bytes: Data) async {
        guard let message = try? PlatformSdk_V1_MsaepMessage(serializedBytes: bytes),
              let payload = try? PlatformSdk_V1_PubSubPayload(serializedBytes: message.payload) else { return }
        // A repeat of the last message for a tag is dropped, as the real subscribers do.
        if lastMessageId[message.messageTag] == message.messageID, !message.messageID.isEmpty { return }
        lastMessageId[message.messageTag] = message.messageID
        let body = payload.additional.isEmpty ? payload.data : payload.additional
        await subscribers[message.messageTag]?(Publication(tag: message.messageTag, publisher: message.dcgClientID,
                                                           messageId: message.messageID, body: body))
    }
}

/// The optional capability exchange on `/SessionValidation`.
public enum SessionValidation {
    public static let route = "/SessionValidation"

    public struct PeerCapabilities: Equatable, Sendable {
        public var sessionValidation: Bool
        /// Version of the persistent message channel, or nil if unsupported. The phone reports 14.
        public var persistentMessageChannelVersion: Int?
        /// Version of the Nano transport preference, or nil if unsupported. The phone reports 3.
        public var nanoTransportPreferenceVersion: Int?
    }

    /// The request Phone Link sends: capabilities `[SESSION_VALIDATION]`, bytes `0A 01 01`.
    public static func requestPayload() -> Data {
        var request = PlatformSdk_V1_ProtoPlatformSessionValidationRequest()
        request.platformCapabilities = [.sessionValidation]
        return (try? request.serializedData()) ?? Data()
    }

    public static func parseResponse(_ payload: Data) -> PeerCapabilities? {
        guard !payload.isEmpty, let response = try? PlatformSdk_V1_ProtoPlatformSessionValidationResponse(serializedBytes: payload) else { return nil }
        let capabilities = response.platformCapabilities
        return PeerCapabilities(
            sessionValidation: capabilities.contains(.sessionValidation),
            persistentMessageChannelVersion: capabilities.contains(.persistentMessageChannel) ? Int(response.persistentMessagingChannelVersion) : nil,
            nanoTransportPreferenceVersion: capabilities.contains(.nanoTransportPreference) ? Int(response.nanoTransportPreferenceVersion) : nil)
    }

    public static func exchange(with messenger: PeerMessenger) async throws -> PeerCapabilities? {
        parseResponse(try await messenger.request(route: route, payload: requestPayload()).payload)
    }
}
