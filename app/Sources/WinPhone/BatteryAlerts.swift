import Foundation
import WinPhoneCore

/// Decides when the phone's battery is worth a word: once when it runs low, once more when
/// it runs very low, and, if wanted, once when it is full. No word is repeated until the
/// battery has been somewhere else in between.
struct BatteryAlerts: Equatable {
    enum Alert: Equatable {
        case low(Int)
        case full

        var title: String {
            switch self {
            case .low(let percent): return "Phone battery at \(percent)%"
            case .full: return "Phone fully charged"
            }
        }
        var body: String {
            switch self {
            case .low(let percent): return percent <= BatteryAlerts.veryLow ? "It will switch off soon unless it is charged." : "Time to charge it."
            case .full: return "It can come off the charger."
            }
        }
    }

    static let low = 20, veryLow = 10
    /// The lowest step already announced, until the battery is charged or well above it again.
    private var announced: Int?
    private var fullAnnounced = false

    mutating func check(_ status: PhoneStatus, lowWanted: Bool, fullWanted: Bool) -> Alert? {
        guard let percent = status.batteryPercent else { return nil }
        if status.isCharging {
            announced = nil
            if percent >= 100 {
                defer { fullAnnounced = true }
                return fullWanted && !fullAnnounced ? .full : nil
            }
            fullAnnounced = false
            return nil
        }
        fullAnnounced = false
        if percent > BatteryAlerts.low + 5 { announced = nil }
        let step = percent <= BatteryAlerts.veryLow ? BatteryAlerts.veryLow : percent <= BatteryAlerts.low ? BatteryAlerts.low : nil
        guard let step, announced.map({ step < $0 }) ?? true else { return nil }
        announced = step
        return lowWanted ? .low(percent) : nil
    }
}
