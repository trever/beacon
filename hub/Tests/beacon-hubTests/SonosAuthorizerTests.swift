import XCTest
@testable import beacon_hub

// Pure query-string parsing for the OAuth loopback redirect -- tested without a real socket. The listener
// lifecycle itself (NWListener bind/accept) is not covered here, the same way LocalIngestServer's socket
// plumbing has no dedicated test; parseQuery is the one piece with real decision logic.
final class SonosAuthorizerTests: XCTestCase {

    func testParseQueryValid() {
        let got = SonosLoopbackServer.parseQuery("/callback?code=abc123&state=xyz789")
        XCTAssertEqual(got?.code, "abc123")
        XCTAssertEqual(got?.state, "xyz789")
    }

    func testParseQueryOrderIndependent() {
        let got = SonosLoopbackServer.parseQuery("/callback?state=xyz789&code=abc123")
        XCTAssertEqual(got?.code, "abc123")
        XCTAssertEqual(got?.state, "xyz789")
    }

    func testParseQueryToleratesExtraParams() {
        // Sonos's own redirect may carry additional params (e.g. householdId); they must not break parsing.
        let got = SonosLoopbackServer.parseQuery("/callback?code=abc&state=xyz&householdId=Sonos_1")
        XCTAssertEqual(got?.code, "abc")
        XCTAssertEqual(got?.state, "xyz")
    }

    func testParseQueryPercentEncodedValues() {
        let got = SonosLoopbackServer.parseQuery("/callback?code=a%2Fb%2Bc&state=s1")
        XCTAssertEqual(got?.code, "a/b+c")
    }

    func testParseQueryMissingCode() {
        XCTAssertNil(SonosLoopbackServer.parseQuery("/callback?state=xyz789"))
    }

    func testParseQueryMissingState() {
        XCTAssertNil(SonosLoopbackServer.parseQuery("/callback?code=abc123"))
    }

    func testParseQueryNoQueryString() {
        XCTAssertNil(SonosLoopbackServer.parseQuery("/callback"))
    }

    func testParseQueryEmptyValues() {
        XCTAssertNil(SonosLoopbackServer.parseQuery("/callback?code=&state="))
    }

    // Regression: the loopback server used to be held only by a local in authorize(), so it deallocated
    // the instant that function returned. The socket stayed bound (NWListener keeps its own bring-up
    // alive) but newConnectionHandler captures the server weakly, so every accepted connection was
    // silently dropped -- the browser hung on an ESTABLISHED connection and the weakly-captured timeout
    // never fired to end it. Observed live against Sonos on 2026-07-27. authorize() must retain it.
    //
    // Needs a real stored secret + a non-placeholder client ID, since preflight() runs first; skipped
    // where those are absent (CI) rather than reaching into the Keychain from a test.
    func testAuthorizeRetainsTheLoopbackServerAfterReturning() throws {
        try XCTSkipIf(SonosAuthorizer.preflight() != nil, "no Sonos secret/client ID configured here")
        XCTAssertFalse(SonosAuthorizer.hasActiveServer, "precondition: no flow in flight")

        let finished = expectation(description: "flow ends")
        // Stubbed openURL: never launch a browser from a test.
        SonosAuthorizer.authorize(timeout: 1, openURL: { _ in }) { _ in finished.fulfill() }

        // The bug: this was false here, because `server` had already died.
        XCTAssertTrue(SonosAuthorizer.hasActiveServer,
                      "authorize() must retain the loopback server until the flow completes")

        wait(for: [finished], timeout: 5)
        XCTAssertFalse(SonosAuthorizer.hasActiveServer, "and must release it once the flow ends")
    }
}
