import Foundation
import SwiftProtobuf

/// The phone's battery, network and ringer state.
public struct PhoneStatus: Equatable, Sendable {
    public enum Network: Equatable, Sendable { case wifi, ethernet, cellular, unknown }

    /// 0 to 100, or nil when the device reports none (a desktop PC reports -1).
    public var batteryPercent: Int?
    public var isCharging: Bool
    public var isPowerSaving: Bool
    public var networkOperator: String?
    public var signalBars: Int
    public var signalBarsMax: Int
    public var wifiEnabled: Bool
    public var wifiLevel: Int
    public var network: Network
    public var airplaneMode: Bool
    /// Android's ringer mode: 0 silent, 1 vibrate, 2 normal, -5 when the phone has a hardware
    /// slider and the mode cannot be set from outside.
    public var ringerMode: Int
    public var doNotDisturb: Int
    /// False when the user disabled Link to Windows' own Do Not Disturb rule on the phone, in
    /// which case the phone refuses to switch Do Not Disturb.
    public var doNotDisturbRuleEnabled: Bool
    /// The phone's "sync over mobile data" setting, nil until the phone has said. While it is
    /// off, a phone without Wi-Fi keeps its connection but refuses to sync anything.
    public var syncOverMobileData: Bool?
    /// Whether the phone is set up for its hotspot to be switched on from a computer; nil
    /// until the phone has said anything about it.
    public var hotspot: HotspotReadiness?

    public init(batteryPercent: Int? = nil, isCharging: Bool = false, isPowerSaving: Bool = false, networkOperator: String? = nil,
                signalBars: Int = 0, signalBarsMax: Int = 4, wifiEnabled: Bool = false, wifiLevel: Int = 0, network: Network = .unknown,
                airplaneMode: Bool = false, ringerMode: Int = 2, doNotDisturb: Int = 1, doNotDisturbRuleEnabled: Bool = true,
                syncOverMobileData: Bool? = nil) {
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.isPowerSaving = isPowerSaving
        self.networkOperator = networkOperator
        self.signalBars = signalBars
        self.signalBarsMax = signalBarsMax
        self.wifiEnabled = wifiEnabled
        self.wifiLevel = wifiLevel
        self.network = network
        self.airplaneMode = airplaneMode
        self.ringerMode = ringerMode
        self.doNotDisturb = doNotDisturb
        self.doNotDisturbRuleEnabled = doNotDisturbRuleEnabled
        self.syncOverMobileData = syncOverMobileData
    }

    /// Whether the phone is holding its content back now: on mobile data with that not allowed.
    public var isSyncPausedOnMobileData: Bool { network == .cellular && syncOverMobileData == false }

    /// Android ringer modes: 0 silent, 1 vibrate, 2 normal.
    public enum Ringer: Equatable, Sendable { case silent, vibrate, normal }
    public var ringer: Ringer { ringerMode == 0 ? .silent : ringerMode == 1 ? .vibrate : .normal }
    /// Android's interruption filter: 1 lets everything through, higher values are Do Not Disturb.
    public var isDoNotDisturbOn: Bool { doNotDisturb > 1 }
    /// Whether the ringer mode can be changed from here.
    public var canSetRinger: Bool { (0...2).contains(ringerMode) }
    /// Whether Do Not Disturb can be switched from here. 0 means the phone does not know.
    public var canSetDoNotDisturb: Bool { doNotDisturb >= 1 && doNotDisturbRuleEnabled }

    init(_ info: DeviceInfo_V1_DeviceStatus) {
        batteryPercent = (0...100).contains(Int(info.batteryPercent)) ? Int(info.batteryPercent) : nil
        isCharging = info.batteryCharging
        isPowerSaving = info.batteryPowerSave
        networkOperator = info.networkOperator.isEmpty ? nil : info.networkOperator
        signalBars = Int(info.networkSignalStrength)
        signalBarsMax = Int(info.networkSignalStrengthMax)
        wifiEnabled = info.wifiState
        wifiLevel = Int(info.wifiSignalLevel)
        switch info.networkType {
        case .wifi: network = .wifi
        case .ethernet: network = .ethernet
        case .cellular: network = .cellular
        default: network = .unknown
        }
        airplaneMode = info.airplaneMode
        ringerMode = Int(info.ringerMode)
        doNotDisturb = Int(info.doNotDisturbStatus)
        // Absent on phones without the Android 15 rule model, which reads as enabled.
        doNotDisturbRuleEnabled = info.hasDoNotDisturbRuleEnabled ? info.doNotDisturbRuleEnabled : true
        syncOverMobileData = info.syncOverMeteredConnection
    }

    /// The status the phone attaches to every content push, as top-level keys of the value
    /// set. Returns nil for a message without them. `base` supplies what the value set does
    /// not say, the kind of network in use.
    public init?(push values: ValueSet, base: PhoneStatus? = nil) {
        guard let battery = values.int("batteryPercent"), let ringer = values.int("ringerMode") else { return nil }
        self = base ?? PhoneStatus()
        batteryPercent = (0...100).contains(battery) ? battery : nil
        isCharging = values.bool("batteryCharging") ?? isCharging
        isPowerSaving = values.bool("batteryPowerSave") ?? isPowerSaving
        if let name = values.string("networkOperator") { networkOperator = name.isEmpty ? nil : name }
        signalBars = values.int("networkSignalStrength") ?? signalBars
        signalBarsMax = values.int("networkSignalStrengthMax") ?? signalBarsMax
        wifiEnabled = values.bool("wifiState") ?? wifiEnabled
        wifiLevel = values.int("wifiSignalLevel") ?? wifiLevel
        airplaneMode = values.bool("airplaneMode") ?? airplaneMode
        ringerMode = ringer
        doNotDisturb = values.int("doNotDisturbStatus") ?? doNotDisturb
        // Absent on phones without the Android 15 rule model, which reads as enabled.
        doNotDisturbRuleEnabled = values.bool("doNotDisturbRuleEnabled") ?? true
        syncOverMobileData = values.bool("syncOverMeteredConnection") ?? syncOverMobileData
        applyHotspot(values)
    }

    /// The phone's word on its hotspot set-up: in its status, and when the user changes it.
    /// - Returns: whether the values said anything about it.
    @discardableResult
    public mutating func applyHotspot(_ values: ValueSet) -> Bool {
        let consent = values.bool("hotspotUserConsent"), open = values.bool("oemBluetoothRfcommServerOpen")
        guard consent != nil || open != nil else { return false }
        diag("hotspot", "the phone's status: consent \(consent.map(String.init) ?? "not said"), Bluetooth channel open \(open.map(String.init) ?? "not said")")
        hotspot = HotspotReadiness(consent: consent ?? hotspot?.consent ?? false, channelOpen: open ?? hotspot?.channelOpen ?? false)
        return true
    }

    /// Parses a `DeviceStatusResponseMessage`. Returns nil unless its status is OK.
    public init?(response: Data) {
        guard let message = try? DeviceInfo_V1_DeviceStatusResponseMessage(serializedBytes: response),
              message.status == .ok, message.hasInfo else { return nil }
        self.init(message.info)
    }
}

/// Device status in both directions: the phone's status is fetched from `/devicestatus` and
/// kept current by publications with tag 8; our own is served on `/remotedevicestatus`.
public actor DeviceStatusSync {
    public static let phonePath = "/devicestatus"
    public static let ownPath = "/remotedevicestatus"

    /// What this computer reports about itself.
    public struct OwnStatus: Sendable {
        /// 0 to 100, or nil for a computer without a battery.
        public var batteryPercent: Int?
        public var isCharging: Bool
        public var network: PhoneStatus.Network

        public init(batteryPercent: Int? = nil, isCharging: Bool = false, network: PhoneStatus.Network = .wifi) {
            self.batteryPercent = batteryPercent
            self.isCharging = isCharging
            self.network = network
        }

        func encoded() -> Data {
            var info = DeviceInfo_V1_DeviceStatus()
            // A PC without a battery reports -1, as Windows does.
            info.batteryPercent = Int32(batteryPercent ?? -1)
            info.batteryCharging = isCharging
            switch network {
            case .wifi: info.networkType = .wifi
            case .ethernet: info.networkType = .ethernet
            case .cellular: info.networkType = .cellular
            case .unknown: info.networkType = .unspecified
            }
            var message = DeviceInfo_V1_DeviceStatusResponseMessage()
            message.status = .ok
            message.info = info
            return (try? message.serializedData()) ?? Data()
        }
    }

    let resources: DeviceResources
    private let publisher: ContextPublisher
    private let ownStatus: @Sendable () async -> OwnStatus
    private let continuation: AsyncStream<PhoneStatus>.Continuation
    public private(set) var latest: PhoneStatus?

    /// The phone's status whenever it changes.
    public nonisolated let updates: AsyncStream<PhoneStatus>

    public init(resources: DeviceResources, publisher: ContextPublisher, ownStatus: @escaping @Sendable () async -> OwnStatus = { OwnStatus() }) {
        self.resources = resources
        self.publisher = publisher
        self.ownStatus = ownStatus
        (updates, continuation) = AsyncStream.makeStream(of: PhoneStatus.self, bufferingPolicy: .bufferingNewest(8))
    }

    /// Registers handlers. Call once.
    public func start() async {
        await resources.serve(DeviceStatusSync.ownPath) { [ownStatus] _ in await ownStatus().encoded() }
        await publisher.subscribe(.deviceStatus) { [weak self] publication in
            guard let status = PhoneStatus(response: publication.body) else { return }
            await self?.update(status)
        }
    }

    /// Asks the phone for its current status.
    @discardableResult
    public func refresh() async throws -> PhoneStatus? {
        let payload = try await resources.request(DeviceStatusSync.phonePath,
                                                  trace: TraceContext(scenarioId: "GetRemoteDeviceStatus", triggerId: "Refresh"))
        guard let status = PhoneStatus(response: payload) else { return nil }
        update(status)
        return status
    }

    func update(_ status: PhoneStatus) {
        guard status != latest else { return }
        latest = status
        continuation.yield(status)
    }
}
