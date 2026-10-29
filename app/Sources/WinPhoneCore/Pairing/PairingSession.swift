import Foundation

/// The pairing flows the Mac supports. The service knows eleven; Phone Link's third one,
/// `QR_TransferMSA_V2`, needs Windows' account manager and cannot be offered here.
public enum PairingFlow: String, Sendable {
    /// QR code. The phone opens the link, signs in itself and confirms a PIN shown on the PC.
    case qrCode = "QRLINK_CHALLENGEPIN_SIGNIN"
    /// Manual pairing with a PIN typed on the phone.
    case manual = "SIGNIN_PIN"
}

/// States reported by the pairing service.
public enum PairingServiceState: String, Sendable, CaseIterable {
    case pendingPairingLinkVisit = "PENDING_PAIRING_LINK_VISIT"
    case pairingLinkExpired = "PAIRING_LINK_EXPIRED"
    case pendingChallengePinValidate = "PENDING_CHALLENGE_PIN_VALIDATE"
    case challengePinExpired = "CHALLENGE_PIN_EXPIRED"
    case challengePinValidateFailed = "CHALLENGE_PIN_VALIDATE_FAILED"
    case pendingPairingPinValidate = "PENDING_PAIRING_PIN_VALIDATE"
    case pairingAccountMismatched = "PAIRING_ACCOUNT_MISMATCHED"
    case pairingPinExpired = "PAIRING_PIN_EXPIRED"
    case pendingPairingPermissionApprove = "PENDING_PAIRING_PERMISSION_APPROVE"
    case pairingRequiredPermissionDenied = "PAIRING_REQUIRED_PERMISSION_DENIED"
    case readyForComplete = "READY_FOR_COMPLETE"
    case pairingFailed = "PAIRING_FAILED"
    case devicePaired = "DEVICE_PAIRED"
    case pairingSessionExpired = "PAIRING_SESSION_EXPIRED"
}

/// What the user interface should show for a pairing session.
public enum PairingStep: Equatable, Sendable {
    /// Show the QR code (and the manual link and PIN when the flow is manual).
    case showLink(link: String, expires: Date?, manualLink: String?, pairingPIN: String?)
    /// The phone scanned the code. Show this PIN for the user to confirm on the phone.
    case confirmChallengePIN(pin: String, expires: Date?)
    /// The PIN ran out or was rejected. Offer a new one.
    case challengePINProblem(expired: Bool)
    /// Manual flow: show the pairing PIN to type on the phone.
    case enterPairingPIN(pin: String, expires: Date?)
    /// Waiting for the user to grant permissions on the phone.
    case approvePermissionsOnPhone
    /// The service is ready and the client must call Complete.
    case completing
    case paired(partnerDcgClientId: String?)
    case failed(PairingFailure)
}

public enum PairingFailure: Equatable, Sendable {
    /// The phone is signed in to a different Microsoft account.
    case accountMismatch
    case linkExpired
    case pinExpired
    case sessionExpired
    case requiredPermissionDenied
    case serviceFailure(type: String?)
    /// The service reported a state this client does not know.
    case unknownState(String)

    /// Whether starting a new session is a sensible next action.
    public var canRestart: Bool {
        switch self {
        case .accountMismatch, .requiredPermissionDenied: return false
        default: return true
        }
    }
}

public extension PairingSessionResponse {
    static func parseTime(_ text: String?) -> Date? {
        guard var text else { return nil }
        // The service sends seven fractional digits; ISO8601DateFormatter accepts at most three
        // reliably, so trim them.
        if let range = text.range(of: #"\.\d+"#, options: .regularExpression) {
            text.replaceSubrange(range, with: "")
        }
        return ISO8601DateFormatter().date(from: text)
    }

    /// Maps the service response to what the UI should show.
    var step: PairingStep {
        guard let state = PairingServiceState(rawValue: state) else { return .failed(.unknownState(self.state)) }
        switch state {
        case .pendingPairingLinkVisit:
            guard let link = pairingLink else { return .failed(.serviceFailure(type: "missing pairingLink")) }
            return .showLink(link: link, expires: Self.parseTime(pairingLinkExpireTime),
                             manualLink: pairingLinkForSignInPINFlow, pairingPIN: pairingPIN)
        case .pendingChallengePinValidate:
            guard let pin = challengePIN else { return .failed(.serviceFailure(type: "missing challengePIN")) }
            return .confirmChallengePIN(pin: pin, expires: Self.parseTime(challengePINExpireTime))
        case .challengePinExpired: return .challengePINProblem(expired: true)
        case .challengePinValidateFailed: return .challengePINProblem(expired: false)
        case .pendingPairingPinValidate:
            guard let pin = pairingPIN else { return .failed(.serviceFailure(type: "missing pairingPIN")) }
            return .enterPairingPIN(pin: pin, expires: Self.parseTime(pairingPINExpireTime))
        case .pendingPairingPermissionApprove: return .approvePermissionsOnPhone
        case .readyForComplete: return .completing
        case .devicePaired: return .paired(partnerDcgClientId: partnerDcgClientId)
        case .pairingAccountMismatched: return .failed(.accountMismatch)
        case .pairingLinkExpired: return .failed(.linkExpired)
        case .pairingPinExpired: return .failed(.pinExpired)
        case .pairingSessionExpired: return .failed(.sessionExpired)
        case .pairingRequiredPermissionDenied: return .failed(.requiredPermissionDenied)
        case .pairingFailed: return .failed(.serviceFailure(type: failureType))
        }
    }
}

/// Drives one pairing session: creates it, polls, calls Complete when asked to, and reports each
/// step until the phone is paired or the session fails.
public struct PairingCoordinator: Sendable {
    public var client: DCGClient
    public var msaToken: @Sendable () async throws -> String
    /// Two-letter region sent as `clientRegionName`.
    public var region: String
    /// Delay between polls. The service is polled every 5 s early on and about every 15 s later.
    public var pollInterval: @Sendable (_ attempt: Int) -> Duration
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(client: DCGClient, region: String = Locale.current.region?.identifier ?? "US",
                msaToken: @escaping @Sendable () async throws -> String,
                pollInterval: @escaping @Sendable (Int) -> Duration = { $0 < 3 ? .seconds(5) : .seconds(15) },
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.client = client
        self.region = region
        self.msaToken = msaToken
        self.pollInterval = pollInterval
        self.sleep = sleep
    }

    /// Runs a session to its end. `onStep` is called whenever the step changes.
    /// - Returns: the final step, `.paired` or `.failed`.
    @discardableResult
    public func run(flow: PairingFlow = .qrCode, permissions: [String] = ["ALL"],
                    onStep: @Sendable (PairingStep, PairingSessionResponse) async -> Void) async throws -> PairingStep {
        var session = try await client.createPairingSession(
            CreatePairingSessionRequest(flow: flow.rawValue, optionalPermission: permissions),
            msaToken: try await msaToken(), region: region)
        var last: PairingStep?
        var attempt = 0
        while true {
            let step = session.step
            if step != last {
                await onStep(step, session)
                last = step
            }
            switch step {
            case .paired, .failed:
                return step
            case .completing:
                session = try await client.completePairingSession(id: session.pairingSessionId, msaToken: try await msaToken())
                continue
            default:
                break
            }
            try await sleep(pollInterval(attempt))
            attempt += 1
            session = try await client.pairingSession(id: session.pairingSessionId, msaToken: try await msaToken())
        }
    }

    /// Asks for a new challenge PIN after `.challengePINProblem`.
    public func refreshChallengePIN(sessionId: String) async throws -> PairingSessionResponse {
        try await client.refreshChallengePIN(sessionId: sessionId, msaToken: try await msaToken())
    }
}
