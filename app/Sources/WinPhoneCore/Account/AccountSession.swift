import Foundation

/// The signed-in Microsoft account: hands out a current access token for DCG, refreshing it
/// with the stored refresh token when needed, and runs the device-code sign-in.
public actor AccountSession {
    public enum AccountError: Error, Equatable {
        case notSignedIn
    }

    private let account: MicrosoftAccount
    private let vault: StateVault
    private let now: @Sendable () -> Date
    private var accessToken: (value: String, expires: Date)?
    private var refreshing: Task<String, Error>?

    /// Tokens are refreshed this long before they expire.
    public static let refreshLeeway: TimeInterval = 5 * 60

    public init(account: MicrosoftAccount, vault: StateVault, now: @escaping @Sendable () -> Date = { Date() }) {
        self.account = account
        self.vault = vault
        self.now = now
    }

    public var isSignedIn: Bool {
        get async { await vault.state.isSignedIn }
    }

    /// Starts the device-code flow. The caller shows `userCode` and `verificationURI`, then
    /// calls `finishSignIn`.
    public func beginSignIn() async throws -> MicrosoftAccount.DeviceCode {
        try await account.requestDeviceCode()
    }

    /// Waits for the user to enter the code, then stores the refresh token.
    public func finishSignIn(_ code: MicrosoftAccount.DeviceCode) async throws {
        let tokens = try await account.waitForTokens(code)
        try await store(tokens)
    }

    /// A valid access token for the DCG scope.
    public func token() async throws -> String {
        if let accessToken, accessToken.expires.timeIntervalSince(now()) > AccountSession.refreshLeeway {
            return accessToken.value
        }
        if let refreshing { return try await refreshing.value }
        let task = Task { [self] in
            defer { Task { await self.clearRefreshing() } }
            return try await self.refreshNow()
        }
        refreshing = task
        return try await task.value
    }

    /// Drops the cached token so the next call fetches a new one.
    public func invalidateToken() {
        accessToken = nil
    }

    public func signOut() async throws {
        accessToken = nil
        try await vault.clear()
    }

    private func clearRefreshing() { refreshing = nil }

    private func refreshNow() async throws -> String {
        guard let refreshToken = await vault.state.refreshToken else { throw AccountError.notSignedIn }
        do {
            let tokens = try await account.refresh(refreshToken: refreshToken)
            try await store(tokens)
            return tokens.accessToken
        } catch MicrosoftAccount.SignInError.reauthorizationRequired(let reason) {
            // The refresh token is dead. Forget it so the interface asks the user to sign in again.
            try await vault.update { $0.refreshToken = nil }
            throw MicrosoftAccount.SignInError.reauthorizationRequired(reason)
        }
    }

    private func store(_ tokens: MicrosoftAccount.Tokens) async throws {
        accessToken = (tokens.accessToken, now().addingTimeInterval(TimeInterval(tokens.expiresIn)))
        if let refreshToken = tokens.refreshToken {
            try await vault.update { $0.refreshToken = refreshToken }
        }
    }
}
