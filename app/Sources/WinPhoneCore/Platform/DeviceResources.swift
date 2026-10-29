import Foundation
import SwiftProtobuf

/// The device resource manager: a small request and response protocol carried on the PLATFORM
/// route `/DeviceResourceManager`. A request names a resource path such as `/clipboard` and
/// carries a resource-specific protobuf; the answer comes back on `/internal/response`.
public actor DeviceResources {
    public static let route = "/DeviceResourceManager"

    public enum RequestType: Int, Sendable {
        case get = 1, update = 2, delete = 3, sync = 4
    }

    public enum ResourceError: Error, Equatable {
        /// The peer has no handler for the resource.
        case unsupportedResource(String)
        case malformedResponse
    }

    public struct IncomingRequest: Sendable {
        public var path: String
        public var query: String?
        public var type: RequestType?
        public var payload: Data
    }

    /// Returns the payload to send back, or nil to report "no handler".
    public typealias ResourceHandler = @Sendable (IncomingRequest) async -> Data?

    private let messenger: PeerMessenger
    private var handlers: [String: ResourceHandler] = [:]

    public init(messenger: PeerMessenger) {
        self.messenger = messenger
    }

    /// Starts answering the peer's resource requests. Call once.
    public func start() async {
        await messenger.handle(DeviceResources.route) { [weak self] request, messenger in
            await self?.serve(request, messenger)
        }
    }

    /// Serves a resource path to the peer.
    public func serve(_ path: String, _ handler: @escaping ResourceHandler) {
        handlers[path] = handler
    }

    /// Requests a resource from the peer and returns the resource-specific payload.
    /// - Parameter timeout: how long to wait for the answer; nil is the messenger's own limit.
    /// - Parameter legacyType: the older way of naming the resource, which Windows still
    ///   fills in for some resources beside the path.
    public func request(_ path: String, type: RequestType = .get, payload: Data = Data(), trace: TraceContext = TraceContext(),
                        timeout: Duration? = nil, legacyType: PlatformSdk_V1_ProtoDeviceResourceType = .unknown) async throws -> Data {
        var message = PlatformSdk_V1_DeviceResourceManagerMessage()
        // The path selects the handler; the legacy type field is UNKNOWN unless asked otherwise.
        message.resourceType = legacyType
        message.requestType = PlatformSdk_V1_ProtoDeviceResourceRequestType(rawValue: type.rawValue) ?? .get
        message.payload = payload
        message.resourcePath = path
        let response = try await messenger.request(route: DeviceResources.route, payload: try message.serializedData(), trace: trace, timeout: timeout)
        guard let parsed = try? PlatformSdk_V1_DeviceResourceManagerResponseMessage(serializedBytes: response.payload) else {
            throw ResourceError.malformedResponse
        }
        if parsed.hasResponseType, parsed.responseType == .resourceHandlerNotRegistered {
            throw ResourceError.unsupportedResource(path)
        }
        return parsed.payload
    }

    private func serve(_ request: PeerMessenger.IncomingRequest, _ messenger: PeerMessenger) async {
        var response = PlatformSdk_V1_DeviceResourceManagerResponseMessage()
        if let message = try? PlatformSdk_V1_DeviceResourceManagerMessage(serializedBytes: request.payload) {
            let parts = message.resourcePath.split(separator: "?", maxSplits: 1).map(String.init)
            // An empty path falls back to the lowercase name of the legacy resource type.
            let path = parts.first ?? "/" + String(describing: message.resourceType).lowercased()
            if let handler = handlers[path] {
                let incoming = IncomingRequest(path: path, query: parts.count > 1 ? parts[1] : nil,
                                               type: RequestType(rawValue: message.requestType.rawValue), payload: message.payload)
                if let payload = await handler(incoming) {
                    response.payload = payload
                    response.responseType = .success
                } else {
                    response.responseType = .resourceHandlerNotRegistered
                }
            } else {
                response.responseType = .resourceHandlerNotRegistered
            }
        } else {
            response.responseType = .resourceHandlerNotRegistered
        }
        try? await messenger.respond(to: request, payload: (try? response.serializedData()) ?? Data())
    }
}
