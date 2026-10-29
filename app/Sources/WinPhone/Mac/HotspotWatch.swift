import CoreWLAN
import Foundation
import SystemConfiguration
import WinPhoneCore

/// Where an interface's traffic goes: its router, the Mac's own address there, and the
/// system's own mark of the network (which holds the router's hardware address). A change
/// in any of them tells that the network is another one. Used instead of the network's
/// name, which the system keeps from apps that may not know where the Mac is.
struct NetworkRoute: Equatable {
    var router: String
    var address: String
    var signature: String?

    /// What the system holds for the interface right now; nil while it has no address.
    static func of(interface: String) -> NetworkRoute? {
        guard let keys = SCDynamicStoreCopyKeyList(nil, "State:/Network/Service/.*/IPv4" as CFString) as? [String] else { return nil }
        for key in keys {
            guard let values = SCDynamicStoreCopyValue(nil, key as CFString) as? [String: Any], values["InterfaceName"] as? String == interface,
                  let route = NetworkRoute(service: values) else { continue }
            return route
        }
        return nil
    }

    /// From a network service's entry in the system's store.
    init?(service values: [String: Any]) {
        guard let router = values["Router"] as? String, let address = (values["Addresses"] as? [String])?.first else { return nil }
        self.router = router
        self.address = address
        signature = values["NetworkSignature"] as? String
    }

    init(router: String, address: String, signature: String? = nil) {
        self.router = router
        self.address = address
        self.signature = signature
    }
}

/// Notices when the Mac is no longer on the network it joined: the user picked another one,
/// Wi-Fi was switched off, or the phone's hotspot went away.
@MainActor
final class HotspotWatch: NSObject, CWEventDelegate {
    private var interface: String?
    private var joined: NetworkRoute?
    private var onLeft: (() -> Void)?
    private var pending: Task<Void, Never>?
    private var poll: Task<Void, Never>?

    /// The interface's route once it has settled after a join: an address from the new
    /// network takes a few seconds to arrive. Nil when none came.
    static func settledRoute(of interface: String, before: NetworkRoute?, within seconds: Double = 15) async -> NetworkRoute? {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if let now = NetworkRoute.of(interface: interface) {
                // Another route than before, or the same one for long enough to be the new one.
                if now != before || Date().timeIntervalSince(start) > 6 { return now }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return NetworkRoute.of(interface: interface)
    }

    /// Whether the Mac is still where it joined.
    static func isStillOn(_ joined: NetworkRoute, now: NetworkRoute?) -> Bool { now == joined }

    func start(interface: String, joined: NetworkRoute, onLeft: @escaping () -> Void) {
        stop()
        self.interface = interface
        self.joined = joined
        self.onLeft = onLeft
        let client = CWWiFiClient.shared()
        client.delegate = self
        for event in [CWEventType.ssidDidChange, .linkDidChange, .powerDidChange] { try? client.startMonitoringEvent(with: event) }
        // And a slow look of its own, should the system keep its events from the app.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.look()
            }
        }
    }

    func stop() {
        guard joined != nil else { return }
        pending?.cancel()
        poll?.cancel()
        pending = nil
        poll = nil
        joined = nil
        onLeft = nil
        let client = CWWiFiClient.shared()
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
    }

    /// Something about the network changed: looked at once it has settled.
    func networkChanged() {
        guard joined != nil else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.look() }
        }
    }

    private func look() {
        guard let interface, let joined else { return }
        guard !HotspotWatch.isStillOn(joined, now: NetworkRoute.of(interface: interface)) else { return }
        let onLeft = self.onLeft
        stop()
        onLeft?()
    }

    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) { Task { @MainActor in networkChanged() } }
    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) { Task { @MainActor in networkChanged() } }
    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { Task { @MainActor in networkChanged() } }
}
