import XCTest
@testable import beacon_hub

// Fixture-based tests for the pure parts of the Sonos OAuth flow: the authorize URL and the token
// response shape. No network, no live calls (per the plan's instruction) -- exchange()/refresh() themselves
// are thin URLSession glue over parseTokenResponse and are not separately tested, the same way
// ClaudeTokenRefresher's direct-refresh POST has no dedicated test beyond its parser.
final class SonosOAuthTests: XCTestCase {

    func testAuthorizeURLContainsExpectedParamsAndNoSecret() {
        let url = SonosOAuth.authorizeURL(state: "the-state-value")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["state"], "the-state-value")
        XCTAssertEqual(items["scope"], "playback-control-all")
        XCTAssertEqual(items["client_id"], SonosOAuth.clientID)
        XCTAssertEqual(items["redirect_uri"], SonosOAuth.redirectURI)
        // The authorize URL is a GET the browser navigates to -- it must never carry the client secret
        // (that only ever appears in the token-exchange POST's Basic-auth header).
        XCTAssertNil(items["client_secret"])
        XCTAssertFalse(url.absoluteString.lowercased().contains("secret"))
    }

    func testRedirectURIUsesFixedLoopbackPortAndPath() {
        XCTAssertEqual(SonosOAuth.redirectURI, "http://127.0.0.1:\(SonosLoopbackServer.port)\(SonosLoopbackServer.callbackPath)")
    }

    func testParseTokenResponseValid() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = #"{"access_token":"tok-1","token_type":"bearer","expires_in":3600,"refresh_token":"ref-1"}"#
        let got = SonosOAuth.parseTokenResponse(Data(json.utf8), now: now)
        XCTAssertEqual(got?.accessToken, "tok-1")
        XCTAssertEqual(got?.refreshToken, "ref-1")
        XCTAssertEqual(got?.expiresAt, now.addingTimeInterval(3600))
    }

    // Sonos does not guarantee a fresh refresh_token on every response; SonosProvider is the one that
    // falls back to the prior token when this is nil (see SonosProvider.applyRefresh).
    func testParseTokenResponseMissingRefreshTokenIsNilNotError() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let json = #"{"access_token":"tok-1","expires_in":3600}"#
        let got = SonosOAuth.parseTokenResponse(Data(json.utf8), now: now)
        XCTAssertEqual(got?.accessToken, "tok-1")
        XCTAssertNil(got?.refreshToken)
    }

    func testParseTokenResponseMissingExpiresInIsNeverExpired() {
        let json = #"{"access_token":"tok-1"}"#
        let got = SonosOAuth.parseTokenResponse(Data(json.utf8), now: Date())
        XCTAssertNil(got?.expiresAt)
    }

    func testParseTokenResponseMissingAccessTokenIsNil() {
        XCTAssertNil(SonosOAuth.parseTokenResponse(Data(#"{"refresh_token":"r"}"#.utf8), now: Date()))
    }

    func testParseTokenResponseMalformedJSON() {
        XCTAssertNil(SonosOAuth.parseTokenResponse(Data("not json".utf8), now: Date()))
    }

    func testParseTokenResponseEmptyAccessTokenIsNil() {
        XCTAssertNil(SonosOAuth.parseTokenResponse(Data(#"{"access_token":""}"#.utf8), now: Date()))
    }
}
