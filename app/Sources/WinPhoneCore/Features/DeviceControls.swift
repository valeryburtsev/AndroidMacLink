import Foundation
import SwiftProtobuf

/// Why the phone did not do what a control asked. See `protocol/specs/device-controls.md`.
public enum PhoneControlError: Error, Equatable {
    case notConnected
    /// The phone has no such control.
    case unsupported
    /// Link to Windows lacks the access it needs: notification access for the ringer and
    /// Do Not Disturb. The phone may be asking its user for it now.
    case needsPermission
    /// Sync is switched off on the phone.
    case syncDisabled
    /// Android's Do Not Disturb rule for Link to Windows was disabled in the phone's settings.
    case ruleDisabled
    /// The phone did not answer in time.
    case noAnswer
    case failed(Int?)

    /// A sentence for the interface.
    public var explanation: String {
        switch self {
        case .notConnected: return "The phone is not connected."
        case .unsupported: return "This phone does not support that."
        case .needsPermission: return "Link to Windows needs notification access on the phone for this. Check the phone."
        case .syncDisabled: return "Syncing is switched off on the phone."
        case .ruleDisabled: return "Do Not Disturb for Link to Windows is disabled in the phone's settings."
        case .noAnswer: return "The phone did not answer."
        case .failed: return "The phone could not do that."
        }
    }
}

/// A transport key for whatever is playing on the phone.
public enum MediaCommand: Int32, Sendable {
    case play = 1, pause = 2, next = 3, previous = 4
}

/// Requests that act on the phone: ringing it, its ringer mode and Do Not Disturb, and the
/// media keys. None of these has been captured from Windows; every message follows the phone's
/// own handlers and Phone Link's senders, as the specification records.
public struct DeviceControls: Sendable {
    public static let ringPath = "/ringmyphone"
    public static let statusCommandRoute = "/command/devicestatus"
    public static let audioRoute = "/command/audio"
    /// How long the phone rings for one request. Nothing tells the PC when it stops.
    public static let ringDuration: Duration = .seconds(20)
    /// How long a control waits for the phone. These answer at once or not at all (a handler
    /// that fails on the phone sends nothing), and the user is watching a button.
    public static let answerTimeout: Duration = .seconds(12)

    public var sender: AppSender

    public init(sender: AppSender) {
        self.sender = sender
    }

    // MARK: Ring my phone

    static func ringRequest(on: Bool) -> Data {
        var message = RingMyPhone_V1_RingMyPhoneRequestMessage()
        message.requestType = on ? .on : .off
        return (try? message.serializedData()) ?? Data()
    }

    /// Starts or stops the phone's "find me" ring: about three seconds of vibration, then the
    /// alarm sound at full volume, twenty seconds in all. A repeated start extends it.
    /// Success means the phone accepted the request, not that it is audible.
    public static func ring(_ on: Bool, through resources: DeviceResources) async throws {
        let answer: Data
        do {
            answer = try await resources.request(DeviceControls.ringPath, type: .update, payload: ringRequest(on: on),
                                                 trace: TraceContext(scenarioId: "RingMyPhone", triggerId: on ? "Start" : "Stop"),
                                                 timeout: DeviceControls.answerTimeout)
        } catch DeviceResources.ResourceError.unsupportedResource {
            throw PhoneControlError.unsupported
        } catch PeerMessenger.MessagingError.rejected {
            throw PhoneControlError.unsupported
        } catch PeerMessenger.MessagingError.timedOut {
            throw PhoneControlError.noAnswer
        }
        guard let message = try? RingMyPhone_V1_RingMyPhoneResponseMessage(serializedBytes: answer) else { throw PhoneControlError.failed(nil) }
        switch message.status {
        case .ok: return
        case .featureNotSupport: throw PhoneControlError.unsupported
        default: throw PhoneControlError.failed(message.status.rawValue)
        }
    }

    // MARK: Ringer mode and Do Not Disturb, as Phone Link sends them

    /// Command types of `/command/devicestatus`.
    enum StatusCommand: Int32 { case doNotDisturb = 2, ringer = 3, syncOverMeteredConnection = 5 }

    func statusCommand(_ type: StatusCommand, value: Int32) -> ValueSet {
        var values = sender.request(contentType: "deviceStatusCommand", userInitiated: true)
        values["deviceStatusCommandType"] = .int32(type.rawValue)
        values["deviceStatusCommandValue"] = .int32(value)
        return values
    }

    /// Sets the ringer mode. The new state arrives later as a status update.
    public func setRinger(_ ringer: PhoneStatus.Ringer, through messenger: PeerMessenger) async throws {
        try await send(statusCommand(.ringer, value: ringer.androidMode), route: DeviceControls.statusCommandRoute, through: messenger)
    }

    /// Switches Do Not Disturb. Android's filter 2 is "priority only", 1 is "everything".
    public func setDoNotDisturb(_ on: Bool, through messenger: PeerMessenger) async throws {
        try await send(statusCommand(.doNotDisturb, value: on ? 2 : 1), route: DeviceControls.statusCommandRoute, through: messenger)
    }

    /// Stores the phone's "sync over mobile data" setting, the one command the phone takes
    /// even while it refuses to sync. Switching it off on a phone that is on mobile data is
    /// answered with "metered connection", which then means it worked.
    public func setSyncOverMobileData(_ on: Bool, through messenger: PeerMessenger) async throws {
        try await send(statusCommand(.syncOverMeteredConnection, value: on ? 1 : 0), route: DeviceControls.statusCommandRoute, through: messenger,
                       acceptingMetered: !on)
    }

    // MARK: Media keys

    func mediaCommand(_ command: MediaCommand, key: String) -> ValueSet {
        // No content type: Phone Link sends none and the phone reads none.
        var values = sender.request(contentType: "", userInitiated: false)
        values.entries.removeValue(forKey: "contentType")
        values["audioCommandValue"] = .int32(command.rawValue)
        values["key"] = .string(key)
        return values
    }

    /// Presses a media key for the session behind a media notification. The phone answers at
    /// once; the effect shows as an update of that notification.
    public func media(_ command: MediaCommand, notificationKey key: String, through messenger: PeerMessenger) async throws {
        try await send(mediaCommand(command, key: key), route: DeviceControls.audioRoute, through: messenger)
    }

    private func send(_ values: ValueSet, route: String, through messenger: PeerMessenger, acceptingMetered: Bool = false) async throws {
        let response: PlatformEnvelope
        do {
            response = try await messenger.appRequest(route: route, payload: values.serialized(), timeout: DeviceControls.answerTimeout)
        } catch PeerMessenger.MessagingError.timedOut {
            throw PhoneControlError.noAnswer
        }
        let code = (try? ValueSet(serialized: response.payload))?.int("result")
        switch code.flatMap(ScenarioResult.init) {
        case .some(let result) where result.countsAsSuccess: return
        case .meteredConnection where acceptingMetered, .meteredConnectionSyncDisabled where acceptingMetered: return
        case .needsPermission, .needsInitialPermission: throw PhoneControlError.needsPermission
        // The phone reuses 14 for "its Do Not Disturb rule is disabled".
        case .invalidRequest where route == DeviceControls.statusCommandRoute: throw PhoneControlError.ruleDisabled
        case .allFeaturesDisabled, .meteredConnection, .meteredConnectionSyncDisabled, .twoPhoneModeSyncDisabled, .nonDefaultUserProfile:
            throw PhoneControlError.syncDisabled
        default: throw PhoneControlError.failed(code)
        }
    }
}

extension PhoneStatus.Ringer {
    /// Android's `AudioManager` ringer mode.
    var androidMode: Int32 {
        switch self {
        case .silent: return 0
        case .vibrate: return 1
        case .normal: return 2
        }
    }
}

extension DeviceStatusSync {
    /// A change to the phone's ringer or Do Not Disturb, in the protobuf form.
    public enum Setting: Equatable, Sendable {
        case ringer(PhoneStatus.Ringer)
        case doNotDisturb(Bool)

        var requestType: DeviceInfo_V1_DeviceStatusRequestType {
            switch self {
            case .doNotDisturb(true): return .setDoNotDisturbOn
            case .doNotDisturb(false): return .setDoNotDisturbOff
            case .ringer(.normal): return .setRingerNormal
            case .ringer(.vibrate): return .setRingerVibrate
            case .ringer(.silent): return .setRingerSilent
            }
        }

        func encoded() -> Data {
            var message = DeviceInfo_V1_DeviceStatusRequestMessage()
            message.requestType = requestType
            return (try? message.serializedData()) ?? Data()
        }
    }

    /// Changes the ringer mode or Do Not Disturb with an UPDATE on `/devicestatus`. The answer
    /// carries the phone's status after the attempt, which is applied here.
    /// - Throws: `PhoneControlError.unsupported` when the phone has no handler, so the caller
    ///   can fall back to the value-set command.
    @discardableResult
    public func apply(_ setting: Setting, timeout: Duration = DeviceControls.answerTimeout) async throws -> PhoneStatus? {
        let answer: Data
        do {
            answer = try await resources.request(DeviceStatusSync.phonePath, type: .update, payload: setting.encoded(),
                                                 trace: TraceContext(scenarioId: "SetRemoteDeviceStatus", triggerId: "User"), timeout: timeout)
        } catch DeviceResources.ResourceError.unsupportedResource {
            throw PhoneControlError.unsupported
        } catch PeerMessenger.MessagingError.rejected {
            throw PhoneControlError.unsupported
        } catch PeerMessenger.MessagingError.timedOut {
            throw PhoneControlError.noAnswer
        }
        guard let message = try? DeviceInfo_V1_DeviceStatusResponseMessage(serializedBytes: answer) else { throw PhoneControlError.failed(nil) }
        // Every answer but "sync disabled" carries the state after the attempt.
        let status = message.hasInfo ? PhoneStatus(message.info) : nil
        if let status { update(status) }
        switch message.status {
        case .ok: return status
        case .syncDisabled: throw PhoneControlError.syncDisabled
        case .needsPermission: throw PhoneControlError.needsPermission
        case .featureNotSupported:
            // Also what the phone says when its Do Not Disturb rule is disabled.
            if case .doNotDisturb = setting, status?.doNotDisturbRuleEnabled == false { throw PhoneControlError.ruleDisabled }
            throw PhoneControlError.unsupported
        default: throw PhoneControlError.failed(message.status.rawValue)
        }
    }
}
