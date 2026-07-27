import XCTest
@testable import BeaconHubKit

// Pure logic backing the Sonos setup UI (design 2026-07-26-sonos-setup-ui): client-ID precedence,
// secret-length validation, and status-state derivation -- the three things the plan calls out as
// testable without Keychain/UserDefaults/network.
final class SonosClientIDTests: XCTestCase {
    func testStoredWinsOverEnvAndPlaceholder() {
        XCTAssertEqual(SonosClientID.resolve(stored: "stored-id", env: "env-id"), "stored-id")
    }

    func testEnvWinsOverPlaceholderWhenStoredIsAbsent() {
        XCTAssertEqual(SonosClientID.resolve(stored: nil, env: "env-id"), "env-id")
    }

    func testEmptyStoredFallsThroughToEnv() {
        // "" (never explicitly cleared vs. blank UserDefaults read) must not shadow a working env value.
        XCTAssertEqual(SonosClientID.resolve(stored: "", env: "env-id"), "env-id")
    }

    func testNeitherStoredNorEnvFallsBackToPlaceholder() {
        XCTAssertEqual(SonosClientID.resolve(stored: nil, env: nil), SonosClientID.placeholder)
    }

    func testEmptyEnvIsTreatedAsAbsent() {
        XCTAssertEqual(SonosClientID.resolve(stored: nil, env: ""), SonosClientID.placeholder)
    }
}

final class SonosSecretValidationTests: XCTestCase {
    func testExactMinimumLengthIsValid() {
        XCTAssertTrue(SonosSecretValidation.isValid(String(repeating: "a", count: 16)))
    }

    func testTooShortIsInvalid() {
        XCTAssertFalse(SonosSecretValidation.isValid(String(repeating: "a", count: 15)))
    }

    func testContainsSpaceIsInvalidEvenIfLongEnough() {
        XCTAssertFalse(SonosSecretValidation.isValid("this has spaces in it"))
    }

    func testEmptyIsInvalid() {
        XCTAssertFalse(SonosSecretValidation.isValid(""))
    }
}

final class SonosSetupStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNoSecretIsNotConfiguredRegardlessOfCredential() {
        let cred = SonosCredential(accessToken: "t", expiresAt: nil, refreshToken: "r")
        let status = SonosSetupState.derive(secretStored: false, credential: cred, lastOutcome: nil, now: now)
        XCTAssertEqual(status, .notConfigured)
    }

    func testSecretStoredNoCredentialIsSecretStoredNotAuthorized() {
        let status = SonosSetupState.derive(secretStored: true, credential: nil, lastOutcome: nil, now: now)
        XCTAssertEqual(status, .secretStoredNotAuthorized)
    }

    func testUsableCredentialWithNoLiveOutcomeIsAuthorized() {
        let expiry = now.addingTimeInterval(3600)
        let cred = SonosCredential(accessToken: "t", expiresAt: expiry, refreshToken: "r")
        let status = SonosSetupState.derive(secretStored: true, credential: cred, lastOutcome: nil, now: now)
        XCTAssertEqual(status, .authorized(expiresAt: expiry))
    }

    func testExpiredCredentialWithDeadRefreshTokenIsFailingEvenWithoutALiveOutcome() {
        let expired = now.addingTimeInterval(-10)
        let cred = SonosCredential(accessToken: "t", expiresAt: expired, refreshToken: nil)
        let status = SonosSetupState.derive(secretStored: true, credential: cred, lastOutcome: nil, now: now)
        guard case .authorizedButFailing = status else {
            return XCTFail("expected authorizedButFailing, got \(status)")
        }
    }

    func testExpiredCredentialWithLiveRefreshTokenIsStillAuthorized() {
        // Expired-but-refreshable is exactly what SonosProvider refreshes transparently on its next poll --
        // must not be reported as broken.
        let expired = now.addingTimeInterval(-10)
        let cred = SonosCredential(accessToken: "t", expiresAt: expired, refreshToken: "still-alive")
        let status = SonosSetupState.derive(secretStored: true, credential: cred, lastOutcome: nil, now: now)
        XCTAssertEqual(status, .authorized(expiresAt: expired))
    }

    func testLiveTerminalOutcomeOverridesToFailingWithItsOwnReason() {
        let cred = SonosCredential(accessToken: "t", expiresAt: nil, refreshToken: "r")
        let outcome = ProviderOutcome.terminal(reason: "Sonos session invalid - re-run sonos-authorize", kind: .staleToken)
        let status = SonosSetupState.derive(secretStored: true, credential: cred, lastOutcome: outcome, now: now)
        XCTAssertEqual(status, .authorizedButFailing(reason: "Sonos session invalid - re-run sonos-authorize"))
    }

    func testLiveTransientOutcomeAlsoReportsAsFailing() {
        let cred = SonosCredential(accessToken: "t", expiresAt: nil, refreshToken: "r")
        let outcome = ProviderOutcome.transient(retryAfter: nil, reason: "Sonos unavailable (HTTP 500)")
        let status = SonosSetupState.derive(secretStored: true, credential: cred, lastOutcome: outcome, now: now)
        XCTAssertEqual(status, .authorizedButFailing(reason: "Sonos unavailable (HTTP 500)"))
    }

    func testLiveOutcomeIsInactiveIsNotTreatedAsFailure() {
        // .inactive means "no room selected yet" (SonosProvider.poll) -- not a broken connection.
        let expiry = now.addingTimeInterval(3600)
        let cred = SonosCredential(accessToken: "t", expiresAt: expiry, refreshToken: "r")
        let outcome = ProviderOutcome.inactive(reason: "Sonos: no room selected")
        let status = SonosSetupState.derive(secretStored: true, credential: cred, lastOutcome: outcome, now: now)
        XCTAssertEqual(status, .authorized(expiresAt: expiry))
    }

    func testLiveOutcomeIsLiveIsNotTreatedAsFailure() {
        let cred = SonosCredential(accessToken: "t", expiresAt: nil, refreshToken: "r")
        let status = SonosSetupState.derive(secretStored: true, credential: cred, lastOutcome: .live, now: now)
        XCTAssertEqual(status, .authorized(expiresAt: nil))
    }
}
