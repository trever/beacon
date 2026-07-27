import XCTest
@testable import BeaconHubKit

final class ProviderCredentialsTests: XCTestCase {

    func testParseClaude() {
        struct Case { let name: String; let json: String; let want: ClaudeCredential? }
        let cases: [Case] = [
            Case(name: "valid, no expiry", json: #"{"claudeAiOauth":{"accessToken":"tok-123"}}"#,
                 want: ClaudeCredential(accessToken: "tok-123", expiresAt: nil)),
            Case(name: "valid with expiry (epoch ms)",
                 json: #"{"claudeAiOauth":{"accessToken":"tok-123","expiresAt":1773751428445}}"#,
                 want: ClaudeCredential(accessToken: "tok-123",
                                        expiresAt: Date(timeIntervalSince1970: 1_773_751_428.445))),
            Case(name: "non-numeric expiresAt tolerated",
                 json: #"{"claudeAiOauth":{"accessToken":"tok-123","expiresAt":"soon"}}"#,
                 want: ClaudeCredential(accessToken: "tok-123", expiresAt: nil)),
            Case(name: "malformed json", json: "not json", want: nil),
            Case(name: "missing claudeAiOauth", json: #"{"other":{"accessToken":"t"}}"#, want: nil),
            Case(name: "missing accessToken", json: #"{"claudeAiOauth":{"refreshToken":"r"}}"#, want: nil),
            Case(name: "empty token => absent", json: #"{"claudeAiOauth":{"accessToken":""}}"#, want: nil),
            Case(name: "refreshToken present",
                 json: #"{"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r-1"}}"#,
                 want: ClaudeCredential(accessToken: "tok-123", expiresAt: nil, refreshToken: "r-1")),
            Case(name: "refreshToken empty => absent",
                 json: #"{"claudeAiOauth":{"accessToken":"tok-123","refreshToken":""}}"#,
                 want: ClaudeCredential(accessToken: "tok-123", expiresAt: nil, refreshToken: nil)),
            Case(name: "refreshToken absent",
                 json: #"{"claudeAiOauth":{"accessToken":"tok-123"}}"#,
                 want: ClaudeCredential(accessToken: "tok-123", expiresAt: nil, refreshToken: nil)),
            Case(name: "refreshTokenExpiresAt valid (epoch ms)",
                 json: #"{"claudeAiOauth":{"accessToken":"tok-123","refreshTokenExpiresAt":1773751428445}}"#,
                 want: ClaudeCredential(accessToken: "tok-123", expiresAt: nil, refreshToken: nil,
                                        refreshTokenExpiresAt: Date(timeIntervalSince1970: 1_773_751_428.445))),
            Case(name: "refreshTokenExpiresAt non-numeric tolerated",
                 json: #"{"claudeAiOauth":{"accessToken":"tok-123","refreshTokenExpiresAt":"soon"}}"#,
                 want: ClaudeCredential(accessToken: "tok-123", expiresAt: nil, refreshToken: nil,
                                        refreshTokenExpiresAt: nil)),
            Case(name: "refreshTokenExpiresAt absent",
                 json: #"{"claudeAiOauth":{"accessToken":"tok-123"}}"#,
                 want: ClaudeCredential(accessToken: "tok-123", expiresAt: nil, refreshToken: nil,
                                        refreshTokenExpiresAt: nil)),
        ]
        for c in cases {
            XCTAssertEqual(
                ProviderCredentials.parseClaude(Data(c.json.utf8)), c.want, "case: \(c.name)")
        }
    }

    func testClaudeCredentialIsExpired() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        struct Case { let name: String; let expiresAt: Date?; let want: Bool }
        let cases: [Case] = [
            Case(name: "no expiry => never stale", expiresAt: nil, want: false),
            Case(name: "future expiry", expiresAt: now.addingTimeInterval(60), want: false),
            Case(name: "past expiry", expiresAt: now.addingTimeInterval(-60), want: true),
            Case(name: "exactly now => expired", expiresAt: now, want: true),
        ]
        for c in cases {
            let cred = ClaudeCredential(accessToken: "t", expiresAt: c.expiresAt)
            XCTAssertEqual(cred.isExpired(at: now), c.want, "case: \(c.name)")
        }
    }

    func testRefreshTokenAlive() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        struct Case { let name: String; let refreshToken: String?; let refreshTokenExpiresAt: Date?; let want: Bool }
        let cases: [Case] = [
            Case(name: "nil token => not alive", refreshToken: nil, refreshTokenExpiresAt: nil, want: false),
            Case(name: "empty token => not alive", refreshToken: "", refreshTokenExpiresAt: nil, want: false),
            Case(name: "no expiry => alive", refreshToken: "r", refreshTokenExpiresAt: nil, want: true),
            Case(name: "future expiry => alive", refreshToken: "r",
                 refreshTokenExpiresAt: now.addingTimeInterval(60), want: true),
            Case(name: "past expiry => not alive", refreshToken: "r",
                 refreshTokenExpiresAt: now.addingTimeInterval(-60), want: false),
            Case(name: "boundary now==expiry => not alive", refreshToken: "r",
                 refreshTokenExpiresAt: now, want: false),
        ]
        for c in cases {
            let cred = ClaudeCredential(accessToken: "t", expiresAt: nil,
                                        refreshToken: c.refreshToken,
                                        refreshTokenExpiresAt: c.refreshTokenExpiresAt)
            XCTAssertEqual(cred.refreshTokenAlive(at: now), c.want, "case: \(c.name)")
        }
    }

    func testParseCodex() {
        struct Case { let name: String; let json: String; let want: (String, String)? }
        let cases: [Case] = [
            Case(name: "valid", json: #"{"tokens":{"access_token":"at","account_id":"acc"}}"#, want: ("at", "acc")),
            Case(name: "malformed json", json: "{", want: nil),
            Case(name: "missing tokens", json: #"{"OPENAI_API_KEY":"k"}"#, want: nil),
            Case(name: "missing access_token", json: #"{"tokens":{"account_id":"acc"}}"#, want: nil),
            Case(name: "missing account_id", json: #"{"tokens":{"access_token":"at"}}"#, want: nil),
            Case(name: "empty access_token => absent", json: #"{"tokens":{"access_token":"","account_id":"acc"}}"#, want: nil),
            Case(name: "empty account_id => absent", json: #"{"tokens":{"access_token":"at","account_id":""}}"#, want: nil),
        ]
        for c in cases {
            let got = ProviderCredentials.parseCodex(Data(c.json.utf8))
            switch (got, c.want) {
            case let (g?, w?):
                XCTAssertEqual(g.accessToken, w.0, "case: \(c.name)")
                XCTAssertEqual(g.accountId, w.1, "case: \(c.name)")
            case (nil, nil):
                break
            default:
                XCTFail("case: \(c.name) -- got \(String(describing: got)), want \(String(describing: c.want))")
            }
        }
    }

    // --- Sonos (design 2026-07-26-sonos-now-playing-plan) ---

    func testParseSonos() {
        struct Case { let name: String; let json: String; let want: SonosCredential? }
        let cases: [Case] = [
            Case(name: "valid, no expiry", json: #"{"sonosOAuth":{"accessToken":"tok-123"}}"#,
                 want: SonosCredential(accessToken: "tok-123", expiresAt: nil, refreshToken: nil)),
            Case(name: "valid with expiry (epoch ms) and refresh token",
                 json: #"{"sonosOAuth":{"accessToken":"tok-123","expiresAt":1773751428445,"refreshToken":"r-1"}}"#,
                 want: SonosCredential(accessToken: "tok-123",
                                       expiresAt: Date(timeIntervalSince1970: 1_773_751_428.445),
                                       refreshToken: "r-1")),
            Case(name: "non-numeric expiresAt tolerated",
                 json: #"{"sonosOAuth":{"accessToken":"tok-123","expiresAt":"soon"}}"#,
                 want: SonosCredential(accessToken: "tok-123", expiresAt: nil, refreshToken: nil)),
            Case(name: "malformed json", json: "not json", want: nil),
            Case(name: "missing sonosOAuth", json: #"{"other":{"accessToken":"t"}}"#, want: nil),
            Case(name: "missing accessToken", json: #"{"sonosOAuth":{"refreshToken":"r"}}"#, want: nil),
            Case(name: "empty token => absent", json: #"{"sonosOAuth":{"accessToken":""}}"#, want: nil),
            Case(name: "refreshToken empty => absent",
                 json: #"{"sonosOAuth":{"accessToken":"tok-123","refreshToken":""}}"#,
                 want: SonosCredential(accessToken: "tok-123", expiresAt: nil, refreshToken: nil)),
        ]
        for c in cases {
            XCTAssertEqual(ProviderCredentials.parseSonos(Data(c.json.utf8)), c.want, "case: \(c.name)")
        }
    }

    // Round-trips through the exact shape sonosBlob builds, the same guarantee ClaudeTokenRefresher's
    // buildKeychainBlob provides for parseClaude -- a freshly refreshed token must read back identically.
    func testSonosBlobRoundTrips() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let blob = ProviderCredentials.sonosBlob(accessToken: "tok-1", expiresAt: now, refreshToken: "ref-1")
        XCTAssertNotNil(blob)
        let parsed = blob.flatMap(ProviderCredentials.parseSonos)
        XCTAssertEqual(parsed?.accessToken, "tok-1")
        XCTAssertEqual(parsed?.refreshToken, "ref-1")
        XCTAssertEqual(parsed?.expiresAt?.timeIntervalSince1970 ?? 0, now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSonosBlobOmitsAbsentFields() {
        let blob = ProviderCredentials.sonosBlob(accessToken: "tok-1", expiresAt: nil, refreshToken: nil)
        let parsed = blob.flatMap(ProviderCredentials.parseSonos)
        XCTAssertEqual(parsed, SonosCredential(accessToken: "tok-1", expiresAt: nil, refreshToken: nil))
    }

    func testSonosCredentialIsExpired() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(SonosCredential(accessToken: "t", expiresAt: nil, refreshToken: nil).isExpired(at: now))
        XCTAssertFalse(SonosCredential(accessToken: "t", expiresAt: now.addingTimeInterval(60), refreshToken: nil).isExpired(at: now))
        XCTAssertTrue(SonosCredential(accessToken: "t", expiresAt: now.addingTimeInterval(-60), refreshToken: nil).isExpired(at: now))
        XCTAssertTrue(SonosCredential(accessToken: "t", expiresAt: now, refreshToken: nil).isExpired(at: now))
    }

    func testSonosRefreshTokenAlive() {
        XCTAssertFalse(SonosCredential(accessToken: "t", expiresAt: nil, refreshToken: nil).refreshTokenAlive)
        XCTAssertFalse(SonosCredential(accessToken: "t", expiresAt: nil, refreshToken: "").refreshTokenAlive)
        XCTAssertTrue(SonosCredential(accessToken: "t", expiresAt: nil, refreshToken: "r").refreshTokenAlive)
    }
}
