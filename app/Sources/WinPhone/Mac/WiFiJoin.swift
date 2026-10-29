import CoreWLAN
import Foundation
import WinPhoneCore

/// Joins a Wi-Fi network by its name and password: the phone's hotspot, once the phone has
/// switched it on and said what it is called.
enum WiFiJoin {
    enum Outcome: Equatable {
        case joined
        /// The network is not in the air (yet): a hotspot takes a few seconds to come up.
        case notFound
        /// The Mac would not join: a wrong password, or the network turned it away.
        case refused(String)
        /// This Mac has no Wi-Fi, or it is switched off.
        case noWiFi
    }

    /// The Wi-Fi interface's name, `en0` on most Macs.
    static func interfaceName() -> String? { CWWiFiClient.shared().interface()?.interfaceName }

    static func isPoweredOn() -> Bool { CWWiFiClient.shared().interface()?.powerOn() ?? false }

    /// What `networksetup` is run with. The password travels as an argument, as that tool
    /// wants it; it is the fallback, used only where the system's own call finds nothing.
    static func arguments(interface: String, ssid: String, password: String) -> [String] {
        ["-setairportnetwork", interface, ssid] + (password.isEmpty ? [] : [password])
    }

    /// What `networksetup` meant: it says nothing when it joined, and explains itself, with a
    /// status of success all the same, when it did not.
    static func outcome(ofOutput output: String, status: Int32) -> Outcome {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return status == 0 ? .joined : .refused("status \(status)") }
        if text.localizedCaseInsensitiveContains("could not find network") { return .notFound }
        // Its own number for the reason, where it gives one; never the network's name.
        let number = text.split(whereSeparator: { !$0.isNumber && $0 != "-" }).first { $0.count >= 3 }.map(String.init)
        return .refused(number.map { "error \($0)" } ?? "the Mac could not join")
    }

    /// One try with the system's own call. Nil where it cannot tell (nothing found by that
    /// name, which on newer systems also happens without the right to see network names).
    private static func joinWithSystemCall(ssid: String, password: String) -> Outcome? {
        guard let interface = CWWiFiClient.shared().interface() else { return .noWiFi }
        guard let found = try? interface.scanForNetworks(withName: ssid), let network = found.first else { return nil }
        // Without the right to know where the Mac is, the system hands out networks with
        // their names taken off, and joining such a one fails ("network (null)", error
        // -3900, 2026-10-12) after dropping the network the Mac was on. Left to the tool,
        // which is given the name itself.
        guard network.ssid != nil else {
            diag("hotspot", "the system found the network but hides its name from this app; joining with the Mac's network tool")
            return nil
        }
        do {
            try interface.associate(to: network, password: password.isEmpty ? nil : password)
            return .joined
        } catch {
            return .refused("error \((error as NSError).code)")
        }
    }

    private static func joinWithTool(interface: String, ssid: String, password: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments(interface: interface, ssid: ssid, password: password)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return .refused("the Mac's network tool could not be run")
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return outcome(ofOutput: output, status: process.terminationStatus)
    }

    private static func runTool(_ arguments: [String]) -> (output: String, status: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (output, process.terminationStatus)
    }

    /// The names in the tool's list of remembered networks: one a line, after a heading.
    static func remembered(inList output: String) -> [String] {
        output.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The networks the Mac remembers, to join them by itself. Nil where the tool does not tell.
    static func rememberedNetworks() async -> [String]? {
        guard let interface = interfaceName() else { return nil }
        return await Task.detached { runTool(["-listpreferredwirelessnetworks", interface]).map { remembered(inList: $0.output) } }.value
    }

    static func remembers(ssid: String) async -> Bool? { await rememberedNetworks().map { $0.contains(ssid) } }

    /// Takes a network off the Mac's remembered ones.
    static func forget(ssid: String) async {
        guard let interface = interfaceName() else { return }
        await Task.detached { _ = runTool(["-removepreferredwirelessnetwork", interface, ssid]) }.value
    }

    /// Takes the Mac off the network it is on, so that it goes back to one of its own.
    /// - Parameter forgetting: a network to take off the Mac's remembered ones first, so
    ///   that it does not go straight back to it: the phone's, where joining it put it there.
    static func leave(forgetting ssid: String?) async {
        guard let interface = interfaceName() else { return }
        await Task.detached(priority: .userInitiated) {
            if let ssid { _ = runTool(["-removepreferredwirelessnetwork", interface, ssid]) }
            CWWiFiClient.shared().interface()?.disassociate()
        }.value
    }

    /// Wi-Fi off and on again: the system then looks for a network it remembers.
    static func restartWiFi() async {
        await Task.detached(priority: .userInitiated) {
            guard let interface = CWWiFiClient.shared().interface() else { return }
            try? interface.setPower(false)
            try? await Task.sleep(for: .seconds(2))
            try? interface.setPower(true)
        }.value
    }

    /// Joins, trying for a while: a hotspot that was just switched on is not in the air at once.
    /// - Parameter tries: how often to look for the network, two seconds apart.
    static func join(ssid: String, password: String, tries: Int = 8) async -> Outcome {
        guard let interface = interfaceName(), isPoweredOn() else { return .noWiFi }
        var last = Outcome.notFound
        for attempt in 0..<max(1, tries) {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            if Task.isCancelled { return last }
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                switch joinWithSystemCall(ssid: ssid, password: password) {
                case .joined: return .joined
                case .noWiFi: return .noWiFi
                // Not found, or found and not joined: the tool has its own way of doing both.
                default: return joinWithTool(interface: interface, ssid: ssid, password: password)
                }
            }.value
            diag("hotspot", "joining the phone's network, try \(attempt + 1): \(describe(outcome))")
            if outcome != .notFound { return outcome }
            last = outcome
        }
        return last
    }

    /// For the log: the kind of outcome, never a name or a password.
    static func describe(_ outcome: Outcome) -> String {
        switch outcome {
        case .joined: return "joined"
        case .notFound: return "not in the air"
        case .refused(let why): return "refused (\(why))"
        case .noWiFi: return "no Wi-Fi"
        }
    }
}
