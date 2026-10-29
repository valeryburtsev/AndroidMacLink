import Foundation
import IOKit.ps
import Network
import WinPhoneCore

/// What this Mac reports about itself when the phone asks: battery and kind of network. Link
/// to Windows shows it on the phone next to the computer's name.
enum MacStatus {
    /// The battery of a portable Mac, or nil for a desktop.
    static func battery() -> (percent: Int, isCharging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int, let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            return (min(100, Swift.max(0, current * 100 / max)), charging || state == kIOPSACPowerValue)
        }
        return nil
    }

    static func status(network: PhoneStatus.Network) -> DeviceStatusSync.OwnStatus {
        let battery = battery()
        return DeviceStatusSync.OwnStatus(batteryPercent: battery?.percent, isCharging: battery?.isCharging ?? false, network: network)
    }
}

/// The kind of network the Mac is on, kept current by the path monitor.
final class NetworkKind: @unchecked Sendable {
    private let lock = NSLock()
    private var kind: PhoneStatus.Network = .wifi

    var current: PhoneStatus.Network { lock.withLock { kind } }

    func update(_ path: NWPath) {
        let now: PhoneStatus.Network = path.usesInterfaceType(.wiredEthernet) ? .ethernet : path.usesInterfaceType(.wifi) ? .wifi
            : path.usesInterfaceType(.cellular) ? .cellular : .unknown
        lock.withLock { kind = now }
    }
}
