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
}
