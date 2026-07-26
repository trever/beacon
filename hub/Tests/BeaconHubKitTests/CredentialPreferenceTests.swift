import XCTest
@testable import BeaconHubKit

// The rule that decides WHICH Claude credential the poller uses. Regression-critical: preferring the
// CLI item unconditionally is what kept usage dark on a Claude-Code-Desktop-only host, where the CLI
// item was a stale leftover nothing would ever refresh.
final class CredentialPreferenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private func cred(expiredBy: TimeInterval? = nil, refresh: String? = nil,
                      refreshExpiredBy: TimeInterval? = nil, token: String = "t") -> ClaudeCredential {
        ClaudeCredential(accessToken: token,
                         expiresAt: expiredBy.map { now.addingTimeInterval(-$0) },
                         refreshToken: refresh,
                         refreshTokenExpiresAt: refreshExpiredBy.map { now.addingTimeInterval(-$0) })
    }

    func testLiveCliWins() {
        let cli = ClaudeCredential(accessToken: "cli", expiresAt: now.addingTimeInterval(3600))
        let bea = ClaudeCredential(accessToken: "beacon", expiresAt: nil)
        // A live CLI token must win: its refresh is single-use/rotating and must not be raced.
        XCTAssertEqual(ProviderCredentials.preferred(cli: cli, beacon: bea, now: now)?.accessToken, "cli")
    }

    func testExpiredCliWithLiveRefreshStillWins() {
        // Still delegable -- the CLI can refresh itself, so don't step around it.
        let cli = cred(expiredBy: 60, refresh: "r", token: "cli")
        let bea = ClaudeCredential(accessToken: "beacon", expiresAt: nil)
        XCTAssertEqual(ProviderCredentials.preferred(cli: cli, beacon: bea, now: now)?.accessToken, "cli")
    }

    // THE regression: expired access token AND dead refresh token = inert. It must not shadow a
    // working long-lived token.
    func testDeadCliFallsBackToBeaconToken() {
        let cli = cred(expiredBy: 60, refresh: "r", refreshExpiredBy: 30, token: "cli")
        let bea = ClaudeCredential(accessToken: "beacon", expiresAt: nil)
        XCTAssertEqual(ProviderCredentials.preferred(cli: cli, beacon: bea, now: now)?.accessToken, "beacon")
    }

    func testDeadCliAndNoRefreshTokenFallsBack() {
        let cli = cred(expiredBy: 60, refresh: nil, token: "cli")
        let bea = ClaudeCredential(accessToken: "beacon", expiresAt: nil)
        XCTAssertEqual(ProviderCredentials.preferred(cli: cli, beacon: bea, now: now)?.accessToken, "beacon")
    }

    func testBeaconUsedWhenCliAbsent() {
        let bea = ClaudeCredential(accessToken: "beacon", expiresAt: nil)
        XCTAssertEqual(ProviderCredentials.preferred(cli: nil, beacon: bea, now: now)?.accessToken, "beacon")
    }

    // Both dead: report the CLI's own failure, so the user is told "run claude login" rather than
    // something about a token they may never have configured.
    func testBothDeadReportsCli() {
        let cli = cred(expiredBy: 60, token: "cli")
        let bea = cred(expiredBy: 60, token: "beacon")
        XCTAssertEqual(ProviderCredentials.preferred(cli: cli, beacon: bea, now: now)?.accessToken, "cli")
    }

    func testNeitherPresent() {
        XCTAssertNil(ProviderCredentials.preferred(cli: nil, beacon: nil, now: now))
    }

    // A long-lived token has no expiry, so it must never read as expired.
    func testLongLivedBlobRoundTripsAsNeverExpiring() throws {
        let blob = try XCTUnwrap(ProviderCredentials.longLivedBlob(accessToken: "abc123"))
        let c = try XCTUnwrap(ProviderCredentials.parseClaude(blob))
        XCTAssertEqual(c.accessToken, "abc123")
        XCTAssertNil(c.expiresAt)
        XCTAssertFalse(c.isExpired(at: now.addingTimeInterval(10 * 365 * 86400)))
        XCTAssertTrue(c.isUsable(at: now))
    }
}
