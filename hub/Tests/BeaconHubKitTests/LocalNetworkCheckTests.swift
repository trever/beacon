import XCTest
@testable import BeaconHubKit

// LocalNetworkCheck.derive is the entire payoff of prerequisite P-1 (design §7.1/§7.3): there is no
// macOS API to ask "do I have Local Network permission," so the Settings row's truth comes entirely from
// what the device's own `sart_stat` reported the last time the hub tried to serve it something. One test
// per value in the frozen six error strings (CONTRACT.md §B4), plus the two non-error outcomes.
final class LocalNetworkCheckTests: XCTestCase {

    func testNeverAttemptedIsChecking() {
        let (state, _) = LocalNetworkCheck.derive(.neverAttempted)
        XCTAssertEqual(state, .checking)
    }

    func testServedIsOK() {
        let (state, _) = LocalNetworkCheck.derive(.served)
        XCTAssertEqual(state, .ok)
    }

    // The TCC-denial shape: zero bytes received presents identically to a genuine network timeout, so
    // this is the row's one piece of ACTIONABLE evidence for "you probably denied Local Network
    // permission" -- the message must name that specifically, not a generic "network error".
    func testTimeoutIsBadAndNamesLocalNetworkPermission() {
        let (state, message) = LocalNetworkCheck.derive(.deviceErr("timeout"))
        XCTAssertEqual(state, .bad)
        XCTAssertTrue((message ?? "").localizedCaseInsensitiveContains("local network"),
                      "message must name Local Network permission specifically: \(message ?? "nil")")
    }

    // The firewall shape: an actively refused connection, distinct from a silent TCC drop.
    func testConnRefusedIsBadAndNamesTheFirewall() {
        let (state, message) = LocalNetworkCheck.derive(.deviceErr("conn_refused"))
        XCTAssertEqual(state, .bad)
        XCTAssertTrue((message ?? "").localizedCaseInsensitiveContains("firewall"),
                      "message must name the macOS firewall specifically: \(message ?? "nil")")
    }

    // `no_wifi`: the device never even attempted the connection, so this proves nothing either way about
    // the HUB's Local Network permission -- the row must not claim `.ok` (unproven) or `.bad` (unearned).
    func testNoWifiIsInconclusiveNotOKOrBad() {
        let (state, _) = LocalNetworkCheck.derive(.deviceErr("no_wifi"))
        XCTAssertEqual(state, .checking)
    }

    // http / size / net: in every one of these the device's TCP connection to the hub's listener was NOT
    // blocked at the OS level (a block would surface as conn_refused or timeout instead) -- whatever went
    // wrong happened AFTER connecting, which is unrelated to Local Network permission.
    func testHTTPErrorIsOK() {
        XCTAssertEqual(LocalNetworkCheck.derive(.deviceErr("http")).state, .ok)
    }

    func testSizeErrorIsOK() {
        XCTAssertEqual(LocalNetworkCheck.derive(.deviceErr("size")).state, .ok)
    }

    func testNetErrorIsOK() {
        XCTAssertEqual(LocalNetworkCheck.derive(.deviceErr("net")).state, .ok)
    }

    // An unrecognized error string (future firmware, or a value outside the frozen six) must degrade the
    // same way http/size/net do, never crash or produce a `.bad` claim this type cannot justify.
    func testUnknownErrorStringDoesNotCrashAndIsOK() {
        XCTAssertEqual(LocalNetworkCheck.derive(.deviceErr("something_new")).state, .ok)
    }
}
