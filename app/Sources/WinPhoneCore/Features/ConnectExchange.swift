import Foundation

/// The start-of-session exchange on `/connect/v1`: the PC states which features it supports
/// and how much of each content type it already holds; the phone answers with its permissions
/// and capabilities and then pushes whatever the PC is missing.
public enum ConnectExchange {
    public static let route = "/connect/v1"

    /// The switches Phone Link 1.26072.257.0 sends, value for value (capture of 2026-10-09).
    ///
    /// The phone stores most of these for the whole device, not per computer, and a change in
    /// the messaging switches makes it drop its sync state for every computer. Sending the same
    /// values as Windows keeps a Mac and a Windows PC linked to one phone from resetting each
    /// other. Which content the phone then pushes is decided by `sequenceNumbers`, so only the
    /// types this client handles are asked for.
    public static let configuration = ValueSet([
        "AirplaneMode": .bool(true),
        "AndroidCanaryOptInNotifications": .bool(false),
        "AppHandoff": .bool(true),
        "AudioInfoSyncEnabled": .bool(true),
        "AutoHydratedThumbnailsCount": .int32(25),
        "BatteryIndicator": .bool(true),
        "BrowserHistory": .bool(true),
        "CallLogs": .bool(false),
        "ContactThumbnails": .bool(true),
        "ContactsV2Sync": .bool(true),
        "ContentTransferCopyPaste": .bool(false),
        "DeviceIndicators": .bool(true),
        "DeviceIndicatorsBluetooth": .bool(true),
        "DeviceIndicatorsDND": .bool(true),
        "DeviceIndicatorsVolume": .bool(true),
        "Exp006": .bool(true),
        "MediaInfoSnapshotSize": .int32(2000),
        "MediaInfoSync": .bool(true),
        "PhotosLegacySync": .bool(false),
        "RecentApps": .bool(true),
        "RemoteControlPhoneToPc": .bool(true),
        "SequencedContentSyncs": .bool(true),
        "SyncSkipMetadataForAuto": .bool(false),
        "TaskContinuity": .bool(true),
        "TaskContinuityVersion": .uint32(1),
        "UnlinkableVersion": .int32(2),
        "Wallpaper": .bool(true),
        "btWakeUserEnabled": .bool(false),
        "fileTransferToPcRetryEnabled": .bool(true),
        "yppPresenceFlowConfig": .bool(true),
    ].merging(messagingConfiguration.entries) { $1 })

    /// The messaging switches. Windows repeats exactly these in every `/chat/v1` request.
    public static let messagingConfiguration = ValueSet([
        "MessagingMassText": .bool(true),
        "MessagingRcsReceive": .bool(true),
        "MessagingRcsSend": .bool(false),
        "MessagingRcsUnsupportedMessageTypes": .int32Array([10, 9]),
        "MessagingSend": .bool(true),
        "MessagingSync": .bool(true),
    ])

    /// What the phone reports about itself in its reply.
    public struct PhoneInfo: Equatable, Sendable {
        public var result: ScenarioResult?
        public var permissions: [String: Bool]
        public var capabilities: [String: Int]
        /// The phone's current sequence number per content type.
        public var sequenceNumbers: [String: Int64]

        public var messagingAllowed: Bool { permissions["messaging"] ?? false }
        public var photosAllowed: Bool { permissions["photos"] ?? false }
        public var notificationsAllowed: Bool { permissions["notifications"] ?? false }
        public var callLogAllowed: Bool { permissions["call_logs"] ?? false }
        /// Bit 16 of the messaging capabilities: the phone can send messages for the PC.
        public var canSendMessages: Bool { (capabilities["messaging"] ?? 0) & 16 != 0 }
    }

    /// Builds the request.
    /// - Parameter sequenceNumbers: per content type, the phone's sequence number this client
    ///   holds, or -1 for "nothing". Only listed types are synced.
    /// - Parameter callLogs: whether to ask for the call history. This sets the phone-wide
    ///   `CallLogs` switch, and only then may `call_logs` be among the sequence numbers: the
    ///   phone's handshake can wait forever for a call log scan that never runs otherwise.
    public static func request(sender: AppSender, sequenceNumbers: [String: Int64], callLogs: Bool = false) -> ValueSet {
        var configuration = configuration
        var sequenceNumbers = sequenceNumbers
        if callLogs {
            configuration["CallLogs"] = .bool(true)
        } else {
            sequenceNumbers.removeValue(forKey: CallLogSync.sequenceKey)
        }
        return ValueSet([
            "contentType": .string("connect"),
            "contractVersion": .double(ValueSet.contractVersion),
            "correlationVector": .string(TraceContext.randomHex(bytes: 8)),
            "appVersion": .string(sender.appVersion),
            "displayName": .string(sender.displayName),
            "installationId": .string(sender.installationId),
            "attributes": .object(ValueSet(["appVersion": .string(sender.appVersion), "displayName": .string(sender.displayName),
                                            "flightRing": .string("Public")])),
            "configuration": .object(configuration),
            // Must be Int64: the phone casts each value.
            "sequenceNumbers": .object(ValueSet(sequenceNumbers.mapValues { ValueSet.Value.int64($0) })),
            "FlightRing": .string("Retail"),
            "IsSampled": .bool(false),
        ])
    }

    public static func parse(_ reply: ValueSet) -> PhoneInfo {
        var permissions: [String: Bool] = [:]
        for (key, value) in reply.object("permissions")?.entries ?? [:] {
            if case .bool(let granted) = value { permissions[key] = granted }
        }
        var capabilities: [String: Int] = [:]
        for key in reply.object("capabilities")?.entries.keys.map({ $0 }) ?? [] {
            if let number = reply.object("capabilities")?.int(key) { capabilities[key] = number }
        }
        var numbers: [String: Int64] = [:]
        for (key, value) in reply.entries {
            if case .int64(let number) = value { numbers[key] = number }
        }
        return PhoneInfo(result: reply.int("result").flatMap(ScenarioResult.init), permissions: permissions,
                         capabilities: capabilities, sequenceNumbers: numbers)
    }

    /// Phone Link waits this long for the reply; a phone busy with a sync answers late.
    public static let replyTimeout: Duration = .seconds(600)

    /// Sends the request and returns what the phone reported.
    public static func perform(with messenger: PeerMessenger, sender: AppSender, sequenceNumbers: [String: Int64], callLogs: Bool = false,
                               timeout: Duration = ConnectExchange.replyTimeout) async throws -> PhoneInfo {
        let envelope = try await messenger.appRequest(route: route,
                                                      payload: request(sender: sender, sequenceNumbers: sequenceNumbers, callLogs: callLogs).serialized(),
                                                      timeout: timeout)
        return parse(try ValueSet(serialized: envelope.payload))
    }
}
