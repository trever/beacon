import XCTest
import BeaconHubKit
@testable import beacon_hub

// Half two of the 403 fix: a terminal outcome must gate the next poll. Terminal used to set no gate at
// all, which was harmless only for the pre-network terminals (-1 missing / -2 unusable credential, which
// issue no request). A terminal reached THROUGH the network -- 401 revoked, 403 missing scope -- re-issued
// the HTTP call on every 45s tick forever.
final class ClaudeUsageGateTests: XCTestCase {

    func testTerminalGatesTheNextPoll() {
        let p = ClaudeCodeProvider(server: LocalIngestServer())
        let now = Date()
        XCTAssertTrue(p.shouldPollUsage(now: now, interval: 45), "an ungated provider should poll")

        p.noteUsageOutcome(.terminal(reason: "Claude usage not authorized for this token (HTTP 403)",
                                     kind: .other))
        XCTAssertFalse(p.shouldPollUsage(now: now, interval: 45), "a terminal must gate the next poll")
    }

    // The gate is a window, not a permanent stop: a fixed credential is retried once it lapses, so the
    // hub self-heals without a restart.
    func testTerminalGateLapses() {
        let p = ClaudeCodeProvider(server: LocalIngestServer())
        let now = Date()
        p.noteUsageOutcome(.terminal(reason: "x", kind: .other))
        XCTAssertTrue(p.shouldPollUsage(now: now.addingTimeInterval(901), interval: 45),
                      "the gate should lapse so a fixed credential is retried")
    }

    // A live poll clears the gate outright, so recovery does not wait out the window.
    func testLiveClearsTheGate() {
        let p = ClaudeCodeProvider(server: LocalIngestServer())
        p.noteUsageOutcome(.terminal(reason: "x", kind: .other))
        p.noteUsageOutcome(.live)
        XCTAssertTrue(p.shouldPollUsage(now: Date(), interval: 45), "live must clear the backoff")
    }

    // .inactive is the abandoned-provider state (#126) and deliberately sets no gate: it is already quiet
    // and must stay able to notice the user coming back.
    func testInactiveDoesNotGate() {
        let p = ClaudeCodeProvider(server: LocalIngestServer())
        p.noteUsageOutcome(.inactive(reason: "Claude inactive"))
        XCTAssertTrue(p.shouldPollUsage(now: Date(), interval: 45), "inactive must not gate")
    }
}
