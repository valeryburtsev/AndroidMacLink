import Foundation
import IOBluetooth
import WinPhoneCore

/// Carries one request to the phone's side channel and brings back its answer: a Bluetooth
/// serial connection to a service the phone keeps open for its linked computers
/// (`protocol/specs/hotspot.md`). One request, one answer, then the connection is closed.
@MainActor
final class HotspotChannel: NSObject {
    /// The side channel's service on the phone.
    static let serviceUUID = UUID(uuidString: "111FAB8F-00A2-4935-B6B4-ACA388CDD473")!

    enum ChannelError: Error, Equatable {
        /// No such paired device.
        case noDevice
        /// The phone could not be asked what services it has: out of reach, or Bluetooth off.
        case unreachable(Int32)
        /// The phone does not offer the service (to this computer).
        case noService
        case openFailed(Int32)
        /// The connection ended before the answer was whole.
        case closed
        case timedOut
    }

    private var device: IOBluetoothDevice?
    private var channel: IOBluetoothRFCOMMChannel?
    private var waiter: CheckedContinuation<Data, Error>?
    private var outgoing = Data()
    private var incoming = Data()
    /// Buffers handed to the system stay alive until it says they were written.
    private var writing: NSMutableData?
    private var timer: Task<Void, Never>?

    static func uuidBytes(_ uuid: UUID) -> Data { withUnsafeBytes(of: uuid.uuid) { Data($0) } }

    /// Sends the framed request to the device and returns the answer without its length.
    func exchange(_ request: Data, with address: String, timeout: Duration = .seconds(25)) async throws -> Data {
        guard waiter == nil else { throw ChannelError.timedOut }
        guard let device = IOBluetoothDevice(addressString: address) else { throw ChannelError.noDevice }
        self.device = device
        outgoing = request
        incoming = Data()
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { self?.finish(.failure(ChannelError.timedOut)) }
            }
            // What the Mac already knows of the phone's services may hold the channel: then
            // it is opened at once.
            if HotspotChannel.channelNumber(of: device) != nil {
                diag("hotspot", "the side channel is among the services the Mac knows of the phone")
                open()
                return
            }
            // Else the phone is asked afresh which services it has. Asked plainly: the form
            // that names the wanted service got no answer at all (2026-10-11, twice 25 s).
            let status = device.performSDPQuery(self)
            // And the way Windows asks, by the service's own identifier: the phone says its
            // channel is open now, and an answer to this form may be the one that tells.
            _ = device.performSDPQuery(self, uuids: [HotspotChannel.wantedService() as Any])
            diag("hotspot", "asking the phone which services it has (\(HotspotChannel.describe(device))): \(status == kIOReturnSuccess ? "asked" : "status \(status)")")
            if status != kIOReturnSuccess { return finish(.failure(ChannelError.unreachable(status))) }
            // The answer may never be told to this app; what the Mac knows is looked at again
            // after a while all the same.
            // The system reports "done" at once, with what it already knew; a service the
            // phone opened a moment ago shows up later, if at all. So what the Mac knows is
            // looked at again and again for a while, and the phone asked once more.
            lookAgain = Task { [weak self] in
                for attempt in 1...12 {
                    try? await Task.sleep(for: .milliseconds(750))
                    guard !Task.isCancelled, let self, self.waiter != nil, self.channel == nil else { return }
                    if HotspotChannel.channelNumber(of: device) != nil {
                        diag("hotspot", "the side channel appeared after \(attempt) looks")
                        return self.open()
                    }
                    if attempt == 4 || attempt == 8 { _ = device.performSDPQuery(self) }
                }
                guard !Task.isCancelled, let self, self.waiter != nil, self.channel == nil else { return }
                self.open()
            }
        }
    }

    private var lookAgain: Task<Void, Never>?

    static func wantedService() -> IOBluetoothSDPUUID {
        let bytes = uuidBytes(serviceUUID)
        return bytes.withUnsafeBytes { IOBluetoothSDPUUID(bytes: $0.baseAddress, length: bytes.count) }
    }

    /// The number of the serial channel the side channel listens on, if the phone lists it.
    static func channelNumber(of device: IOBluetoothDevice) -> BluetoothRFCOMMChannelID? {
        var id: BluetoothRFCOMMChannelID = 0
        guard let record = device.getServiceRecord(for: wantedService()), record.getRFCOMMChannelID(&id) == kIOReturnSuccess else { return nil }
        return id
    }

    /// For the log: how the Mac stands with the device. Counts and yes or no, nothing that names it.
    static func describe(_ device: IOBluetoothDevice) -> String {
        let services = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
        let age = device.getLastServicesUpdate().map { "\(Int(-$0.timeIntervalSinceNow)) s ago" } ?? "never"
        return "\(device.isConnected() ? "connected" : "not connected"), \(services.count) services known, looked up \(age)"
    }

    /// Development aid: says in the log what the phone offers over Bluetooth, by the names of
    /// the services (profile names, the same on every phone of the kind), and whether the
    /// side channel is among them. Sends nothing to the phone but the question.
    func diagnose(address: String) async {
        guard let device = IOBluetoothDevice(addressString: address) else { return diag("hotspot", "self-check: no such paired device") }
        func report(_ when: String) {
            let services = (device.services as? [IOBluetoothSDPServiceRecord]) ?? []
            // A service by its name, or by the identifiers of its kind where it has none
            // (profile identifiers, the same on every phone).
            let names = services.map { record -> String in
                if let name = record.getServiceName(), !name.isEmpty { return name }
                // The kind of service (attribute 1) and where it listens: profile identifiers and a
                // channel number, nothing of the user's.
                var channel: BluetoothRFCOMMChannelID = 0
                let listens = record.getRFCOMMChannelID(&channel) == kIOReturnSuccess ? "channel \(channel)" : "no serial channel"
                let kind = String(describing: record.getAttributeDataElement(1) as Any).replacingOccurrences(of: "\n", with: " ")
                return "unnamed[\(listens); \(kind.prefix(180))]"
            }.sorted().joined(separator: ", ")
            diag("hotspot", "self-check \(when): \(HotspotChannel.describe(device)); side channel \(HotspotChannel.channelNumber(of: device).map { "on channel \($0)" } ?? "not listed"); services: \(names)")
        }
        report("before asking")
        diagnosing = true
        let status = device.performSDPQuery(self)
        diag("hotspot", "self-check: asked the phone, status \(status)")
        // And once the way Windows asks: by the service's own identifier.
        let byUUID = device.performSDPQuery(self, uuids: [HotspotChannel.wantedService() as Any])
        diag("hotspot", "self-check: asked for the service by its identifier, status \(byUUID)")
        for _ in 0..<30 where diagnosing { try? await Task.sleep(for: .milliseconds(500)) }
        diag("hotspot", "self-check: \(diagnosing ? "no word from the system after 15 s" : "the system reported the answer")")
        diagnosing = false
        report("after asking")
        // Once more after a while, and after asking again: what the phone opened lately may come late.
        try? await Task.sleep(for: .seconds(4))
        _ = device.performSDPQuery(self)
        try? await Task.sleep(for: .seconds(3))
        report("seven seconds later")
    }

    private var diagnosing = false

    /// Whether the channel has reported itself open, the watch for that, and how often the
    /// opening was begun anew in this exchange.
    private var isOpen = false
    private var openWatch: Task<Void, Never>?
    private var reopened = 0

    private func finish(_ result: Result<Data, Error>) {
        guard let waiter else { return }
        self.waiter = nil
        timer?.cancel()
        timer = nil
        openWatch?.cancel()
        openWatch = nil
        isOpen = false
        reopened = 0
        lookAgain?.cancel()
        lookAgain = nil
        let channel = self.channel
        self.channel = nil
        channel?.setDelegate(nil)
        _ = channel?.close()
        // Let go of the system's objects a turn later, not inside their own callbacks.
        let device = self.device
        self.device = nil
        DispatchQueue.main.async { _ = (channel, device) }
        waiter.resume(with: result)
    }

    private func open() {
        guard let device, waiter != nil, channel == nil else { return }
        lookAgain?.cancel()
        lookAgain = nil
        guard let id = HotspotChannel.channelNumber(of: device) else {
            // The list is the one macOS remembered: it does not ask the phone again when an
            // app asks it to (its own log shows no query), and a connection of the app's own
            // to the phone's service directory is closed by the system as soon as it opens
            // (macOS 27, 2026-10-12). Only pairing anew refreshes it.
            diag("hotspot", "the Mac's remembered list of the phone's services has no side channel (\(HotspotChannel.describe(device)))")
            return finish(.failure(ChannelError.noService))
        }
        var opened: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(&opened, withChannelID: id, delegate: self)
        diag("hotspot", "opening the side channel, number \(id): \(status == kIOReturnSuccess ? "started" : "status \(status)")")
        guard status == kIOReturnSuccess, let opened else { return finish(.failure(ChannelError.openFailed(status))) }
        channel = opened
        // An opening that runs into the end of another connection to the phone fails inside
        // the system without a word to the app (its log, 2026-10-12 20:50: "connect failure
        // 560", no callback). Not heard of in a few seconds: begun anew, twice at most.
        openWatch?.cancel()
        openWatch = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.waiter != nil, !self.isOpen, self.reopened < 2 else { return }
            self.reopened += 1
            diag("hotspot", "the side channel has not opened in 4 s; opening it anew (\(self.reopened))")
            let stale = self.channel
            self.channel = nil
            stale?.setDelegate(nil)
            _ = stale?.close()
            try? await Task.sleep(for: .milliseconds(600))
            DispatchQueue.main.async { _ = stale }
            if !Task.isCancelled { self.open() }
        }
    }

    /// Writes the next piece: no more at a time than the connection carries.
    private func writeNext() {
        guard let channel, waiter != nil, !outgoing.isEmpty else { return }
        let size = min(outgoing.count, max(1, Int(channel.getMTU())))
        let piece = NSMutableData(data: outgoing.prefix(size))
        outgoing.removeFirst(size)
        writing = piece
        let status = channel.writeAsync(piece.mutableBytes, length: UInt16(piece.length), refcon: nil)
        if status != kIOReturnSuccess { finish(.failure(ChannelError.openFailed(status))) }
    }

    private func received(_ data: Data) {
        if incoming.isEmpty { diag("hotspot", "first bytes from the phone: \(data.count), beginning \(data.prefix(2).map { String(format: "%02x", $0) }.joined())") }
        incoming.append(data)
        do {
            if let message = try SideChannelFraming.take(from: &incoming) {
                diag("hotspot", "answer here, \(message.count) bytes")
                finish(.success(message))
            }
        } catch {
            finish(.failure(error))
        }
    }
}

extension HotspotChannel: IOBluetoothRFCOMMChannelDelegate {
    @objc nonisolated func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        BluetoothCalls.onMain { [self] in
            if diagnosing {
                diag("hotspot", "self-check: answer reported, status \(status)")
                diagnosing = false
                return
            }
            guard waiter != nil else { return }
            if status != kIOReturnSuccess {
                diag("hotspot", "the phone did not say what services it has: status \(status)")
                return finish(.failure(ChannelError.unreachable(status)))
            }
            // Open at once where the service is listed; else the looking goes on for a while.
            if let device, channel == nil, HotspotChannel.channelNumber(of: device) != nil { open() }
        }
    }

    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        BluetoothCalls.onMain { [self] in
            guard waiter != nil else { return }
            if error != kIOReturnSuccess {
                diag("hotspot", "the side channel did not open: status \(error)")
                return finish(.failure(ChannelError.openFailed(error)))
            }
            // Not the report of an opening that was given up meanwhile.
            guard rfcommChannel === channel else { return }
            isOpen = true
            openWatch?.cancel()
            diag("hotspot", "side channel open; sending the request, \(outgoing.count) bytes")
            writeNext()
        }
    }

    nonisolated func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        BluetoothCalls.onMain { [self] in
            writing = nil
            if error != kIOReturnSuccess { return finish(.failure(ChannelError.openFailed(error))) }
            if outgoing.isEmpty, waiter != nil { diag("hotspot", "the request went out whole") }
            writeNext()
        }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let data = Data(bytes: dataPointer, count: dataLength)
        BluetoothCalls.onMain { [self] in received(data) }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        BluetoothCalls.onMain { [self] in
            guard waiter != nil else { return }
            diag("hotspot", "the side channel was closed before the answer was whole")
            finish(.failure(ChannelError.closed))
        }
    }
}
