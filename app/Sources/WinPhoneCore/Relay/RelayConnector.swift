import Foundation

/// Opens the hub relay: negotiate with the gateway, follow its redirect to Azure SignalR
/// Service, negotiate there, then upgrade to a WebSocket (capture of 2026-10-09).
public struct RelayConnector: Sendable {
    public var baseURL: URL
    public var profile: ClientProfile
    public var instance: ClientInstance
    public var http: HTTPTransport
    public var webSockets: WebSocketConnector
    /// `dcg-heartbeatfrequency`, in seconds.
    public var heartbeatSeconds = 30

    public enum ConnectError: Error, Equatable {
        case http(step: String, status: Int)
        case malformed(String)
    }

    public init(baseURL: URL = DCGClient.productionBaseURL, profile: ClientProfile = .phoneLink, instance: ClientInstance,
                http: HTTPTransport, webSockets: WebSocketConnector) {
        self.baseURL = baseURL
        self.profile = profile
        self.instance = instance
        self.http = http
        self.webSockets = webSockets
    }

    /// Headers common to both negotiate calls and the WebSocket upgrade.
    func relayHeaders(bearer: String, partnerId: String?, trace: TraceContext) -> [(name: String, value: String)] {
        let spanId = trace.parentId ?? TraceContext.randomHex(bytes: 8)
        var state: [String] = []
        if let scenario = trace.scenarioId { state.append("ypScenarioId=\(scenario)") }
        if let trigger = trace.triggerId { state.append("ypTriggerId=\(trigger)") }
        state.append("yppHttpParent=\(spanId)")
        let traceState = state.joined(separator: ",")
        var headers: [(name: String, value: String)] = [
            ("X-Requested-With", "XMLHttpRequest"),
            ("DCG-LogicalDeviceId", instance.logicalDeviceId),
            ("DCG-AppVersion", profile.appVersion),
            ("DCG-AppId", profile.appId),
            ("DCG-SessionId", instance.sessionId),
            ("DCG-RingName", profile.ringName),
            ("DCG-OS", profile.osName),
            ("DCG-OSVersion", profile.osVersion),
        ]
        if let partnerId { headers.append(("DCG-PartnerId", partnerId)) }
        headers += [
            ("traceparent", trace.traceparent(spanId: spanId)),
            ("tracestate", traceState),
            ("DCG-TraceState", traceState),
            ("DCG-HeartBeatFrequency", String(heartbeatSeconds)),
            ("Authorization", "Bearer " + bearer),
        ]
        return headers
    }

    /// - Parameters:
    ///   - dcgToken: the device's DCG token.
    ///   - partnerId: sent as `DCG-PartnerId`.
    public func connect(dcgToken: String, partnerId: String?,
                        trace: TraceContext = TraceContext(scenarioId: "connectApi", triggerId: "StartSession")) async throws -> HubConnection {
        // 1. Gateway negotiate: answers with the Azure SignalR URL and an access token for it.
        var gateway = URLComponents(url: baseURL.appendingPathComponent("relayhub/negotiate"), resolvingAgainstBaseURL: false)!
        gateway.queryItems = [URLQueryItem(name: "negotiateVersion", value: "1")]
        let first = try await http.send(HTTPRequest(method: "POST", url: gateway.url!,
                                                    headers: relayHeaders(bearer: dcgToken, partnerId: partnerId, trace: trace)))
        guard first.status == 200 else { throw ConnectError.http(step: "gateway negotiate", status: first.status) }
        guard let redirect = try? JSONDecoder().decode(RelayNegotiateResponse.self, from: first.body),
              let target = redirect.url, let accessToken = redirect.accessToken,
              var service = URLComponents(string: target) else { throw ConnectError.malformed("gateway negotiate response") }

        // 2. Service negotiate: same query, path `/client/negotiate`, bearer = the access token.
        let query = service.queryItems ?? []
        var negotiate = service
        negotiate.path = service.path.hasSuffix("/") ? service.path + "negotiate" : service.path + "/negotiate"
        let second = try await http.send(HTTPRequest(method: "POST", url: negotiate.url!,
                                                     headers: relayHeaders(bearer: accessToken, partnerId: partnerId, trace: trace)))
        guard second.status == 200 else { throw ConnectError.http(step: "service negotiate", status: second.status) }
        guard let connection = try? JSONDecoder().decode(RelayNegotiateResponse.self, from: second.body),
              let connectionToken = connection.connectionToken ?? connection.connectionId else {
            throw ConnectError.malformed("service negotiate response")
        }

        // 3. WebSocket: same URL with the scheme switched and the connection token as `id`.
        service.scheme = service.scheme == "http" ? "ws" : "wss"
        service.queryItems = query + [URLQueryItem(name: "id", value: connectionToken)]
        diag("relay", "opening WebSocket to \(service.host ?? "?")")
        let socket = try await webSockets.connect(url: service.url!, headers: relayHeaders(bearer: accessToken, partnerId: partnerId, trace: trace))
        return HubConnection(socket: socket)
    }
}
