import CoreBluetooth
import Foundation
import IOBluetooth
import WinPhoneCore

/// A phone paired with this Mac that could carry calls.
struct CallDevice: Equatable, Identifiable {
    var name: String
    /// The Bluetooth address, the device's identity here. Never written to the log.
    var address: String
    var id: String { address }
}

/// Where the hands-free link to the phone stands.
enum CallLinkState: Equatable {
    case off
    /// The user has not let the app use Bluetooth.
    case notAllowed
    /// No paired phone could be told to be the linked one.
    case noPhone
    case connecting
    case connected
    /// The phone is not in reach, or refused. Tried again by itself.
    case unreachable
}

/// Asks, once, whether the app may use Bluetooth. The system shows its question the first time
/// anything touches Bluetooth; what is asked for before the user has answered comes back
/// empty, so the answer is waited for here.
@MainActor
final class BluetoothAccess: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var waiting: [(Bool) -> Void] = []

    func request(_ done: @escaping (Bool) -> Void) {
        switch CBManager.authorization {
        case .allowedAlways: done(true)
        case .denied, .restricted: done(false)
        default:
            waiting.append(done)
            if manager == nil {
                diag("calls", "bluetooth: asking for permission")
                manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        BluetoothCalls.onMain { [self] in
            guard CBManager.authorization != .notDetermined else { return }
            let allowed = CBManager.authorization == .allowedAlways
            diag("calls", "bluetooth: permission \(allowed ? "given" : "refused")")
            let callbacks = waiting
            waiting = []
            manager = nil
            for done in callbacks { done(allowed) }
        }
    }
}

/// Phone calls over Bluetooth: this Mac as the phone's hands-free unit, as Phone Link makes a
/// Windows PC one. The phone has to be paired with the Mac in Bluetooth settings first.
///
/// Calls can be seen, answered, declined, ended and placed from here. The talking is done on
/// the phone: the call's sound would need a second, synchronous Bluetooth connection, and on
/// current macOS the system's calls that set one up or accept one do nothing (tried on macOS 27
/// on 2026-10-10: the hands-free class answers "unsupported", and the controller's methods for
/// it are empty). `protocol/specs/calls-bluetooth.md`, section 5.
///
/// Two ways to hold the connection, tried in this order:
/// - the system's own hands-free class (worked at the first try with a Galaxy S21+);
/// - this app's own dialogue (`HandsFreeLink`) on a plain serial channel.
///
/// Never logs a number or a name.
@MainActor
final class BluetoothCalls: NSObject {
    enum Backend: String { case system, own }

    var onState: (CallLinkState) -> Void = { _ in }
    var onCall: (LiveCall?) -> Void = { _ in }
    /// Something the user should know, briefly.
    var onNotice: (String) -> Void = { _ in }
    /// Whether this phone mutes its microphone when asked from here.
    var onCanMute: (Bool) -> Void = { _ in }
    private var canMute = false { didSet { if canMute != oldValue { onCanMute(canMute) } } }

    private(set) var state = CallLinkState.off { didSet { if state != oldValue { onState(state) } } }
    private var running = false
    private var device: IOBluetoothDevice?
    private var backend: Backend?
    private var generation = 0
    private var retry: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var failures = 0
    private var connectWatch: IOBluetoothUserNotification?

    // The system's class.
    private var handsFree: IOBluetoothHandsFreeDevice?
    private var indicators = CallIndicators()

    // The own dialogue.
    private var channel: IOBluetoothRFCOMMChannel?
    private var link = HandsFreeLink()
    private var commandTimer: Task<Void, Never>?
    private var writes: [NSMutableData] = []

    /// Which way to try first; "system" or "own" in the defaults pins one.
    private var preference: Backend? { UserDefaults.standard.string(forKey: "calls.backend").flatMap(Backend.init) }

    /// Runs on the main thread: at once when already there, as the system's Bluetooth classes
    /// usually call, and later otherwise.
    nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }

    // MARK: Devices

    /// The paired devices that are phones.
    static func pairedPhones() -> [CallDevice] {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return unique(paired.filter { $0.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPhone) || $0.isHandsFreeAudioGateway }
            .compactMap { device in device.addressString.map { CallDevice(name: device.name ?? "Phone", address: $0) } })
    }

    /// Each device once. The system lists a paired device once for each way it is known
    /// (seen on 2026-10-10: every phone twice, under one address), which also kept a phone
    /// from being found by its name, there being "two" of that name.
    static func unique(_ devices: [CallDevice]) -> [CallDevice] {
        var seen: Set<String> = []
        return devices.filter { seen.insert($0.address.lowercased()).inserted }
    }

    /// Letters and digits only, so that the two kinds of apostrophe and spacing do not matter.
    static func plain(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// The paired phone meant: the one chosen, else the one named like the linked phone, else
    /// the only one there is.
    static func choose(from phones: [CallDevice], chosen: String?, linkedName: String?) -> CallDevice? {
        if let chosen, let match = phones.first(where: { $0.address == chosen }) { return match }
        if let linkedName, !plain(linkedName).isEmpty {
            let wanted = plain(linkedName)
            let named = phones.filter { plain($0.name) == wanted }
            if named.count == 1 { return named[0] }
            // The relay may give the model's name where Bluetooth has the owner's, or the
            // other way round: one within the other is taken when only one phone fits.
            let similar = phones.filter { plain($0.name).contains(wanted) || (plain($0.name).count >= 3 && wanted.contains(plain($0.name))) }
            if named.isEmpty, similar.count == 1 { return similar[0] }
        }
        return phones.count == 1 ? phones[0] : nil
    }

    // MARK: Life cycle

    /// Starts holding a connection to the phone at this address, for as long as it can be had.
    func start(address: String) {
        stop()
        guard let device = IOBluetoothDevice(addressString: address) else {
            state = .noPhone
            return
        }
        running = true
        self.device = device
        failures = 0
        diag("calls", "bluetooth: starting; the phone is \(device.isPaired() ? "paired" : "not paired"), \(device.isConnected() ? "connected" : "not connected"), \(device.isHandsFreeAudioGateway ? "lists" : "does not list") a hands-free service among \(device.services?.count ?? 0)")
        // A phone that comes back into reach connects by itself sooner or later: take that
        // as the moment to try, instead of searching for it all the time.
        connectWatch = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        attempt()
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device connected: IOBluetoothDevice) {
        guard running, state == .unreachable, connected.addressString == device?.addressString else { return }
        diag("calls", "bluetooth: the phone connected to this Mac; trying now")
        retry?.cancel()
        failures = 0
        attempt()
    }

    func stop() {
        running = false
        generation += 1
        retry?.cancel()
        retry = nil
        connectWatch?.unregister()
        connectWatch = nil
        teardown()
        device = nil
        state = .off
    }

    private func teardown() {
        watchdog?.cancel()
        commandTimer?.cancel()
        if let handsFree {
            handsFree.delegate = nil
            if handsFree.isConnected { handsFree.disconnect() }
        }
        if let channel {
            channel.setDelegate(nil)
            channel.close()
        }
        // This may run inside a call from one of the two: let them finish before they go.
        let leaving: [AnyObject] = [handsFree, channel].compactMap { $0 }
        if !leaving.isEmpty { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { _ = leaving } }
        handsFree = nil
        channel = nil
        writes.removeAll()
        canMute = false
        backend = nil
        link = HandsFreeLink()
        if indicators.liveCall != nil || indicators != CallIndicators() {
            indicators = CallIndicators()
        }
        onCall(nil)
    }

    private func attempt() {
        guard running, let device else { return }
        generation += 1
        let attempt = generation
        state = .connecting
        // The system's class first, and always once it has worked. Until then the two take
        // turns, unless one is pinned.
        // The app's own dialogue first: Apple's class took the whole app down with an
        // "unrecognized selector" inside it (2026-10-12, after 29 hours of a quiet link), and
        // the own dialogue did the same job live at the first try.
        let first: Backend = preference ?? (failures % 2 == 0 ? .own : .system)
        diag("calls", "bluetooth: connecting, \(first.rawValue) hands-free, try \(failures + 1)")
        backend = first
        switch first {
        case .system:
            let handsFree = IOBluetoothHandsFreeDevice(device: device, delegate: self)
            self.handsFree = handsFree
            handsFree?.connect()
        case .own:
            // The channel number of the phone's hands-free service is in its service list.
            device.performSDPQuery(self)
        }
        watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled, self.generation == attempt, self.state == .connecting else { return }
            diag("calls", "bluetooth: no answer in 20 s")
            self.failed()
        }
    }

    /// The connection could not be made or was lost: clean up, try again later.
    private func failed() {
        guard running else { return }
        teardown()
        failures += 1
        state = .unreachable
        // Soon the other way, then slower: a phone out of reach costs a radio search each time.
        let wait: Duration = failures == 1 ? .seconds(2) : failures < 6 ? .seconds(20) : failures < 20 ? .seconds(60) : .seconds(300)
        retry?.cancel()
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled, self.running else { return }
            self.attempt()
        }
    }

    private func connected() {
        watchdog?.cancel()
        failures = 0
        state = .connected
        diag("calls", "bluetooth: hands-free connection ready (\(backend?.rawValue ?? "?"))")
    }

    // MARK: Commands

    var isConnected: Bool { if case .connected = state { return true } else { return false } }

    func answer() {
        diag("calls", "bluetooth: answering")
        switch backend {
        case .system: handsFree?.acceptCall()
        case .own: perform(link.answer())
        case nil: break
        }
    }

    /// Ends the call, or declines the one that rings.
    func hangUp() {
        diag("calls", "bluetooth: ending the call")
        switch backend {
        case .system: handsFree?.endCall()
        case .own: perform(link.hangUp())
        case nil: break
        }
    }

    /// - Returns: false when there is no connection to place the call over.
    @discardableResult
    func dial(_ number: String) -> Bool {
        let digits = HandsFreeLink.dialable(number)
        guard isConnected, digits.contains(where: \.isNumber) else { return false }
        diag("calls", "bluetooth: dialling a number of \(digits.count) characters")
        switch backend {
        case .system:
            indicators.number = digits
            handsFree?.dialNumber(digits)
        case .own: perform(link.dial(digits))
        case nil: return false
        }
        return true
    }

    /// Puts the call on hold or takes it back. What became of it shows as the call's state.
    func toggleHold() {
        diag("calls", "bluetooth: hold or resume")
        switch backend {
        case .system: handsFree?.holdCall()
        case .own: perform(link.toggleHold())
        case nil: break
        }
    }

    /// Mutes the phone's microphone, on a phone that said it can.
    func setMuted(_ muted: Bool) {
        guard canMute else { return }
        diag("calls", "bluetooth: \(muted ? "muting" : "unmuting")")
        switch backend {
        case .system: handsFree?.send(atCommand: "AT+CMUT=\(muted ? 1 : 0)")
        case .own: perform(link.mute(muted))
        case nil: break
        }
    }

    func tone(_ key: Character) {
        switch backend {
        case .system: handsFree?.sendDTMF(String(key))
        case .own: perform(link.tone(key))
        case nil: break
        }
    }

    // MARK: The own dialogue

    private func perform(_ output: HandsFreeLink.Output) {
        for line in output.send { write(line) }
        for event in output.events {
            switch event {
            case .ready:
                connected()
                perform(link.askAboutMute())
            case .canMute:
                diag("calls", "bluetooth: the phone can mute on request")
                canMute = true
            case .callChanged(let call):
                diag("calls", "bluetooth: call \(BluetoothCalls.describe(call))")
                onCall(call)
            case .ring: break
            case .indicator: break
            case .refused(let command):
                // "No" to the question about muting is the expected answer, not a fault.
                if command != "AT+CMUT" { diag("calls", "bluetooth: the phone refused \(command)") }
                if command == "ATD" { onNotice("The phone could not place the call.") }
                if command == "AT+CHLD" { onNotice("The phone could not put the call on hold.") }
            }
        }
        // A command without an answer must not hold up the ones behind it.
        commandTimer?.cancel()
        if link.isWaiting {
            commandTimer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard let self, !Task.isCancelled else { return }
                diag("calls", "bluetooth: a command had no answer")
                self.perform(self.link.timedOut())
            }
        }
    }

    private func write(_ line: String) {
        guard let channel else { return }
        // Not the waiting kind of write: this runs inside the channel's own calls. The bytes
        // are kept until the channel says they went out.
        let bytes = NSMutableData(data: Data((line + "\r").utf8))
        writes.append(bytes)
        let status = channel.writeAsync(bytes.mutableBytes, length: UInt16(bytes.length), refcon: nil)
        if status != kIOReturnSuccess {
            writes.removeLast()
            diag("calls", "bluetooth: write failed, \(String(status, radix: 16))")
        }
    }

    static func describe(_ call: LiveCall?) -> String {
        guard let call else { return "ended" }
        return "\(call.phase), number \(call.number == nil ? "not known" : "known")"
    }

    /// The system's class reported one of the three call indicators, or a number.
    private func indicatorsChanged(_ change: (inout CallIndicators) -> Void) {
        let before = indicators.liveCall
        change(&indicators)
        let after = indicators.liveCall
        guard after != before else { return }
        diag("calls", "bluetooth: call \(BluetoothCalls.describe(after))")
        // The indicators say that a call is there, not with whom.
        if after != nil, indicators.number == nil { handsFree?.currentCallList() }
        onCall(after)
    }
}

// MARK: - The own dialogue's channel

extension BluetoothCalls: IOBluetoothRFCOMMChannelDelegate {
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard running, backend == .own, channel == nil, let device else { return }
        guard status == kIOReturnSuccess else {
            diag("calls", "bluetooth: the phone's service list could not be read, \(String(status, radix: 16))")
            failed()
            return
        }
        var id: BluetoothRFCOMMChannelID = 0
        // 0x111F: the audio gateway side of the Hands-Free Profile.
        guard let record = device.getServiceRecord(for: IOBluetoothSDPUUID(uuid16: 0x111F)), record.getRFCOMMChannelID(&id) == kIOReturnSuccess else {
            diag("calls", "bluetooth: the phone lists no hands-free service")
            failed()
            return
        }
        var opened: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&opened, withChannelID: id, delegate: self)
        guard result == kIOReturnSuccess, let opened else {
            diag("calls", "bluetooth: the channel could not be opened, \(String(result, radix: 16))")
            failed()
            return
        }
        channel = opened
    }

    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        BluetoothCalls.onMain { [self] in
            guard running, backend == .own else { return }
            guard error == kIOReturnSuccess else {
                diag("calls", "bluetooth: the channel did not open, \(String(error, radix: 16))")
                failed()
                return
            }
            diag("calls", "bluetooth: channel open, starting the dialogue")
            link = HandsFreeLink()
            perform(link.start())
        }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let data = Data(bytes: dataPointer, count: dataLength)
        BluetoothCalls.onMain { [self] in
            guard running, backend == .own else { return }
            perform(link.receive(data))
        }
    }

    nonisolated func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        BluetoothCalls.onMain { [self] in
            if !writes.isEmpty { writes.removeFirst() }
            if error != kIOReturnSuccess { diag("calls", "bluetooth: a write did not go out, \(String(error, radix: 16))") }
        }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        BluetoothCalls.onMain { [self] in
            guard running, backend == .own else { return }
            diag("calls", "bluetooth: the channel closed")
            channel = nil
            failed()
        }
    }
}

// MARK: - The system's class

extension BluetoothCalls: IOBluetoothHandsFreeDeviceDelegate {
    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        let code = status?.intValue ?? -1
        BluetoothCalls.onMain { [self] in
            guard running, backend == .system else { return }
            guard code == 0 else {
                diag("calls", "bluetooth: the system's hands-free connection failed, \(String(code, radix: 16))")
                failed()
                return
            }
            connected()
            // The caller's number with each ring.
            handsFree?.send(atCommand: "AT+CLIP=1")
            // Whether the phone would mute on request; a phone that would answers with a line
            // of its own, which arrives as an "unhandled result code".
            handsFree?.send(atCommand: HandsFreeLink.muteQuestion)
            indicatorsChanged { indicators in
                indicators.call = Int(self.handsFree?.indicator("call") ?? 0)
                indicators.setup = Int(self.handsFree?.indicator("callsetup") ?? 0)
                indicators.held = Int(self.handsFree?.indicator("callheld") ?? 0)
            }
        }
    }

    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        BluetoothCalls.onMain { [self] in
            guard running, backend == .system else { return }
            diag("calls", "bluetooth: the system's hands-free connection ended")
            failed()
        }
    }

    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        let code = status?.intValue ?? -1
        BluetoothCalls.onMain { [self] in
            guard running, backend == .system else { return }
            // Never seen to succeed: see the note on sound at the top.
            diag("calls", "bluetooth: sound connection opened, status \(code)")
        }
    }

    nonisolated func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        BluetoothCalls.onMain { [self] in
            guard running, backend == .system else { return }
            diag("calls", "bluetooth: sound connection closed")
        }
    }

    nonisolated func handsFree(_ device: IOBluetoothHandsFreeDevice!, isCallActive: NSNumber!) {
        let value = isCallActive?.intValue ?? 0
        BluetoothCalls.onMain { [self] in indicatorsChanged { $0.set("call", to: value) } }
    }

    nonisolated func handsFree(_ device: IOBluetoothHandsFreeDevice!, callSetupMode: NSNumber!) {
        let value = callSetupMode?.intValue ?? 0
        BluetoothCalls.onMain { [self] in indicatorsChanged { $0.set("callsetup", to: value) } }
    }

    nonisolated func handsFree(_ device: IOBluetoothHandsFreeDevice!, callHoldState: NSNumber!) {
        let value = callHoldState?.intValue ?? 0
        BluetoothCalls.onMain { [self] in indicatorsChanged { $0.set("callheld", to: value) } }
    }

    nonisolated func handsFree(_ device: IOBluetoothHandsFreeDevice!, incomingCallFrom number: String!) {
        let number = number.flatMap { $0.isEmpty ? nil : $0 }
        BluetoothCalls.onMain { [self] in
            indicatorsChanged { indicators in
                if let number { indicators.number = number }
                if indicators.call == 0, indicators.setup == 0 { indicators.setup = 1 }
            }
        }
    }

    nonisolated func handsFree(_ device: IOBluetoothHandsFreeDevice!, ringAttempt: NSNumber!) {
        BluetoothCalls.onMain { [self] in
            indicatorsChanged { indicators in
                if indicators.call == 0, indicators.setup == 0 { indicators.setup = 1 }
            }
        }
    }

    nonisolated func handsFree(_ device: IOBluetoothHandsFreeDevice!, currentCall: [AnyHashable: Any]!) {
        let number = currentCall?[IOBluetoothHandsFreeCallNumber] as? String
        BluetoothCalls.onMain { [self] in
            guard let number, !number.isEmpty, indicators.number == nil, indicators.liveCall != nil else { return }
            indicatorsChanged { $0.number = number }
            // The same call, now with its number.
            onCall(indicators.liveCall)
        }
    }

    nonisolated func handsFree(_ device: IOBluetoothHandsFreeDevice!, unhandledResultCode resultCode: String!) {
        // What the phone said may hold a number: only its first letters go to the log.
        let head = String((resultCode ?? "").prefix(while: { $0 != ":" && $0 != "=" }).prefix(12))
        BluetoothCalls.onMain { [self] in
            diag("calls", "bluetooth: the phone said \(head)")
            if head.trimmingCharacters(in: .whitespaces) == "+CMUT", backend == .system { canMute = true }
        }
    }
}
