import Foundation

/// Pressing a notification's button the way Phone Link does on phones that show their apps
/// on the computer: not with the notification command (which this phone answers "needs
/// permission" to, capture of 2026-10-13), but over a short connection of the phone-screen
/// kind. In its "early launch" workflow the phone takes the notification's key and the
/// button's number and presses the button itself (`EarlyLaunchDelegate`, which may fire a
/// button's intent directly), then says how it went. See `protocol/specs/mirroring.md`.
public enum NotificationLaunch {
    /// What the connection is opened for, and the workflow asked for on its launcher channel.
    public static let workflow = "earlyLaunch"
    static let requestPath = "/mirror/phone/launchNotification"
    static let resultPath = "/mirror/phone/launchNotificationResult"

    public enum Outcome: Equatable, Sendable {
        /// The button was pressed.
        case pressed
        /// The button was pressed and opened something on the phone's own screen.
        case openedOnPhone
        /// The phone could not: its number for why (2 launch failed, 3 another error).
        case failed(Int)
    }

    public enum LaunchError: Error, Equatable {
        /// The phone opened the connection and never said how the press went.
        case noAnswer
        case connectionLost(String)
        /// The phone's screen is being shown: the phone runs one such connection at a time.
        case screenInUse
    }

    /// The phone's numbers (`NotificationLaunchResult`): 0 launched on a virtual display,
    /// 1 on the phone's own display, 2 failed, 3 error, 4 the notification was already used.
    static func outcome(of result: Int) -> Outcome {
        switch result {
        case 0, 4: return .pressed
        case 1: return .openedOnPhone
        default: return .failed(result)
        }
    }

    static func request(transactionId: String, key: String, actionIndex: Int) -> [String: Any] {
        ["transactionId": transactionId, "key": key, "actionIndex": actionIndex]
    }

    /// Presses the button over an open connection and returns what the phone said. The
    /// connection is left open; whoever opened it closes it.
    public static func press(over connection: NanoConnection, key: String, actionIndex: Int, timeout: Duration = .seconds(15)) async throws -> Outcome {
        try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                try await Task.sleep(for: timeout)
                throw LaunchError.noAnswer
            }
            group.addTask {
                let workflowId = UUID().uuidString.lowercased(), transaction = UUID().uuidString.lowercased()
                var launcher: UInt16?, early: UInt16?
                var asked = false, sent = false
                func send(_ channel: UInt16?, _ path: String, _ object: [String: Any]) async throws {
                    guard let channel else { return }
                    try await connection.sendMessage(channel: channel, path: path, body: try JSONSerialization.data(withJSONObject: object))
                }
                for await event in connection.events {
                    switch event {
                    case .channelCreated(let channel, let description):
                        guard description.channelClass == "Messaging" else { continue }
                        if description.properties["workflow"] == "launcher" { launcher = channel }
                        if description.properties["workflow"] == NotificationLaunch.workflow { early = channel }
                    case .messageHandshake(let channel):
                        if channel == launcher, !asked {
                            asked = true
                            diag("notify", "launcher channel ready; asking for the early-launch workflow")
                            try await send(launcher, "/workflow", ["workflow": NotificationLaunch.workflow, "workflowId": workflowId])
                        } else if channel == early, !sent {
                            sent = true
                            diag("notify", "early-launch channel ready; asking the phone to press the button")
                            try await send(early, requestPath, request(transactionId: transaction, key: key, actionIndex: actionIndex))
                        }
                    case .message(_, let message) where message.path == resultPath:
                        let object = (try? JSONSerialization.jsonObject(with: message.body)) as? [String: Any] ?? [:]
                        // An answer to another request than this one is not this one's.
                        if let answered = object["transactionId"] as? String, answered != transaction { continue }
                        let result = (object["launchResult"] as? NSNumber)?.intValue ?? 3
                        diag("notify", "the phone's answer to the button: \(result)")
                        try? await send(launcher, "/stopWorkflow", ["workflow": NotificationLaunch.workflow, "workflowId": workflowId])
                        await connection.flush(timeout: .seconds(1))
                        return outcome(of: result)
                    case .closed(let reason):
                        throw LaunchError.connectionLost(reason)
                    default:
                        break
                    }
                }
                throw LaunchError.connectionLost("the connection ended")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw LaunchError.noAnswer }
            return first
        }
    }
}
