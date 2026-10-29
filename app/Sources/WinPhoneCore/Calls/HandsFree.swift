import Foundation

// Phone calls go over Bluetooth, not over the relay: the computer is the phone's hands-free
// unit, as a car kit would be (`protocol/specs/calls.md`, section 9, and `calls-bluetooth.md`).
// What is here is the Hands-Free Profile's control side as plain text in and text out, so that
// it can be tried without a radio: the phone is the "audio gateway" and answers AT commands.

/// A call in progress on the phone, as the hands-free link reports it.
public struct LiveCall: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The phone is ringing.
        case incoming
        /// A call from here is being set up; `alerting` once the other side rings.
        case dialing, alerting
        case active
        case held
    }

    public var phase: Phase
    /// The other side's number, when the phone said it. Never written to the log.
    public var number: String?

    public init(phase: Phase, number: String? = nil) {
        self.phase = phase
        self.number = number
    }
}

/// The three indicators every audio gateway reports, and the call they add up to.
public struct CallIndicators: Equatable, Sendable {
    /// 1 while a call is active.
    public var call = 0
    /// 0 none, 1 incoming, 2 outgoing being dialled, 3 outgoing and the other side rings.
    public var setup = 0
    /// 0 none, 1 one active and one held, 2 held only.
    public var held = 0
    public var number: String?

    public init(call: Int = 0, setup: Int = 0, held: Int = 0, number: String? = nil) {
        self.call = call
        self.setup = setup
        self.held = held
        self.number = number
    }

    public var liveCall: LiveCall? {
        // A second call coming in during a call does not replace the one being spoken.
        if call != 0 { return LiveCall(phase: held == 2 ? .held : .active, number: number) }
        switch setup {
        case 1: return LiveCall(phase: .incoming, number: number)
        case 2: return LiveCall(phase: .dialing, number: number)
        case 3: return LiveCall(phase: .alerting, number: number)
        default: return nil
        }
    }

    /// Sets one indicator and forgets the number once no call is left.
    public mutating func set(_ name: String, to value: Int) {
        switch name {
        case "call": call = value
        case "callsetup", "call_setup": setup = value
        case "callheld": held = value
        default: return
        }
        if call == 0, setup == 0 { number = nil }
    }
}

/// The hands-free side of the profile's dialogue. Feed it what the phone sent, send what it
/// returns; it holds no connection and no clock.
public struct HandsFreeLink {
    /// What this side says it can do: three-way calling, showing the caller's number, remote
    /// volume control, enhanced call status. No codec negotiation: this side has no say in
    /// the audio.
    public static let features = 0x02 | 0x04 | 0x10 | 0x20

    public enum Event: Equatable, Sendable {
        /// The opening exchange is done; calls can be made and are announced from now on.
        case ready
        case callChanged(LiveCall?)
        /// The phone rings once more.
        case ring
        /// "service", "signal", "battchg", "roam": the phone's own state, by its name.
        case indicator(String, Int)
        /// The phone refused the command named, by its first letters only.
        case refused(String)
        /// The phone takes "mute the microphone" from this side. Few do: the microphone in
        /// use is the phone's own, and the profile has no word for muting it; this is the
        /// general modem command, asked about once.
        case canMute
    }

    public struct Output: Equatable, Sendable {
        /// Lines to send, each to be ended with a carriage return.
        public var send: [String] = []
        public var events: [Event] = []
    }

    private enum Step: Equatable {
        case features, indicatorNames, indicatorValues, reporting, holdModes
        /// After the opening exchange: any other command.
        case plain
    }

    private var buffer = Data()
    private var queue: [(line: String, step: Step)] = []
    private var awaiting: (line: String, step: Step)?
    public private(set) var isReady = false
    public private(set) var gatewayFeatures = 0
    /// The gateway's indicators in its own order; `+CIEV` names them by position from 1.
    public private(set) var indicatorNames: [String] = []
    public private(set) var indicators = CallIndicators()

    public init() {}

    public var call: LiveCall? { indicators.liveCall }
    /// Whether a command is out and unanswered.
    public var isWaiting: Bool { awaiting != nil }

    // MARK: Sending

    /// Begins the opening exchange. Call once, when the channel is open.
    public mutating func start() -> Output {
        queue = [("AT+BRSF=\(HandsFreeLink.features)", .features), ("AT+CIND=?", .indicatorNames), ("AT+CIND?", .indicatorValues),
                 ("AT+CMER=3,0,0,1", .reporting)]
        return Output(send: pump())
    }

    private mutating func pump() -> [String] {
        guard awaiting == nil, !queue.isEmpty else { return [] }
        let next = queue.removeFirst()
        awaiting = next
        return [next.line]
    }

    private mutating func command(_ line: String) -> Output {
        queue.append((line, .plain))
        return Output(send: pump())
    }

    public mutating func answer() -> Output { command("ATA") }
    /// Ends the active call, gives up one being set up, or declines one that rings.
    public mutating func hangUp() -> Output { command("AT+CHUP") }

    /// Puts the call on hold, or takes it back: the same request either way.
    public mutating func toggleHold() -> Output { command("AT+CHLD=2") }

    /// Asks whether the phone would mute its microphone on request.
    public static let muteQuestion = "AT+CMUT=?"
    public mutating func askAboutMute() -> Output { command(HandsFreeLink.muteQuestion) }
    public mutating func mute(_ on: Bool) -> Output { command("AT+CMUT=\(on ? 1 : 0)") }

    /// What of a typed number can be dialled: digits, the signs of a keypad and a leading plus.
    public static func dialable(_ number: String) -> String {
        var result = ""
        for character in number where character.isASCII {
            if character.isNumber || character == "*" || character == "#" || (character == "+" && result.isEmpty) { result.append(character) }
        }
        return result
    }

    /// Places a call. Returns nothing to send for a number without digits.
    public mutating func dial(_ number: String) -> Output {
        let digits = HandsFreeLink.dialable(number)
        guard digits.contains(where: \.isNumber) else { return Output() }
        indicators.number = digits
        return command("ATD\(digits);")
    }

    /// Presses a keypad key during a call.
    public mutating func tone(_ key: Character) -> Output {
        guard key.isASCII, key.isNumber || "*#ABCD".contains(key) else { return Output() }
        return command("AT+VTS=\(key)")
    }

    /// The command out has had no answer for too long: go on as if it had been refused.
    public mutating func timedOut() -> Output {
        guard awaiting != nil else { return Output() }
        return finish(accepted: false)
    }

    // MARK: Receiving

    public mutating func receive(_ data: Data) -> Output {
        buffer.append(data)
        var output = Output()
        while let end = buffer.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) {
            let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            buffer.removeSubrange(buffer.startIndex...end)
            if line.isEmpty { continue }
            let part = handle(line)
            output.send += part.send
            output.events += part.events
        }
        // A phone that sends without line ends would otherwise fill memory.
        if buffer.count > 4096 { buffer.removeAll() }
        return output
    }

    private mutating func handle(_ line: String) -> Output {
        let before = indicators.liveCall
        var output = Output()
        if line == "OK" {
            output = finish(accepted: true)
        } else if line == "ERROR" || line.hasPrefix("+CME ERROR") || line == "NO CARRIER" || line == "BUSY" || line == "NO ANSWER" || line == "BLACKLISTED" || line == "DELAYED" {
            output = finish(accepted: false)
        } else if line == "RING" {
            if indicators.call == 0, indicators.setup == 0 { indicators.setup = 1 }
            output.events.append(.ring)
        } else if let rest = HandsFreeLink.value(of: "+BRSF", in: line) {
            gatewayFeatures = Int(rest.trimmingCharacters(in: .whitespaces)) ?? 0
        } else if let rest = HandsFreeLink.value(of: "+CIND", in: line) {
            if awaiting?.step == .indicatorNames {
                indicatorNames = HandsFreeLink.quoted(in: rest)
            } else {
                for (index, text) in rest.split(separator: ",", omittingEmptySubsequences: false).enumerated() where index < indicatorNames.count {
                    if let number = Int(text.trimmingCharacters(in: .whitespaces)) { output.events += note(indicatorNames[index], number) }
                }
            }
        } else if let rest = HandsFreeLink.value(of: "+CIEV", in: line) {
            let parts = rest.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, let index = parts[0], let number = parts[1], (1...indicatorNames.count).contains(index) {
                output.events += note(indicatorNames[index - 1], number)
                // The indicators say that a call is there, not with whom.
                if isReady, indicators.liveCall != nil, indicators.number == nil, !queue.contains(where: { $0.line == "AT+CLCC" }), awaiting?.line != "AT+CLCC" {
                    queue.append(("AT+CLCC", .plain))
                    output.send += pump()
                }
            }
        } else if let rest = HandsFreeLink.value(of: "+CLIP", in: line) {
            if let number = HandsFreeLink.quoted(in: rest).first, !number.isEmpty { indicators.number = number }
            if indicators.call == 0, indicators.setup == 0 { indicators.setup = 1 }
        } else if let rest = HandsFreeLink.value(of: "+CLCC", in: line) {
            // index, direction, status, mode, conference, "number", type. Only the first call's
            // number is wanted; a waiting or held second one does not replace it.
            let fields = rest.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if fields.count >= 3, let status = Int(fields[2]), status != 5, indicators.number == nil,
               let number = HandsFreeLink.quoted(in: rest).first, !number.isEmpty {
                indicators.number = number
            }
        }
        else if HandsFreeLink.value(of: "+CMUT", in: line) != nil, awaiting?.line == HandsFreeLink.muteQuestion {
            output.events.append(.canMute)
        }
        // Anything else (+CCWA, +COPS, +VGS, +BSIR, ...) needs no answer here.
        let after = indicators.liveCall
        if after != before { output.events.append(.callChanged(after)) }
        return output
    }

    private mutating func note(_ name: String, _ value: Int) -> [Event] {
        switch name {
        case "call", "callsetup", "call_setup", "callheld":
            indicators.set(name, to: value)
            return []
        default:
            return [.indicator(name, value)]
        }
    }

    /// The command out was answered. Moves the opening exchange on, or sends the next command.
    private mutating func finish(accepted: Bool) -> Output {
        guard let done = awaiting else { return Output() }
        awaiting = nil
        var output = Output()
        switch done.step {
        case .features, .indicatorNames, .indicatorValues:
            // A phone that refuses one of these is still asked for the rest.
            break
        case .reporting:
            // Both sides know three-way calling: the profile wants the hold modes asked for.
            if gatewayFeatures & 0x01 != 0 {
                queue.insert(("AT+CHLD=?", .holdModes), at: 0)
            } else {
                output.events += becomeReady()
            }
        case .holdModes:
            output.events += becomeReady()
        case .plain:
            if !accepted {
                output.events.append(.refused(String(done.line.prefix(while: { $0 != "=" && !$0.isNumber && $0 != ";" }))))
                // A call that could not be placed leaves no number behind.
                if done.line.hasPrefix("ATD"), indicators.liveCall == nil { indicators.number = nil }
            }
        }
        output.send += pump()
        return output
    }

    private mutating func becomeReady() -> [Event] {
        isReady = true
        // Caller's number with each ring, second calls announced, errors with their number.
        queue += [("AT+CLIP=1", .plain), ("AT+CCWA=1", .plain), ("AT+CMEE=1", .plain)]
        // A call that was there before this side connected: ask with whom.
        if indicators.liveCall != nil { queue.append(("AT+CLCC", .plain)) }
        return [.ready]
    }

    // MARK: Text

    /// What follows "+NAME:" in a line that starts with it.
    static func value(of name: String, in line: String) -> String? {
        guard line.hasPrefix(name) else { return nil }
        let rest = line.dropFirst(name.count)
        guard rest.first == ":" else { return nil }
        return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// The texts between double quotes, in order.
    static func quoted(in text: String) -> [String] {
        var result: [String] = []
        var current: String?
        for character in text {
            if character == "\"" {
                if let done = current {
                    result.append(done)
                    current = nil
                } else {
                    current = ""
                }
            } else {
                current?.append(character)
            }
        }
        return result
    }
}
