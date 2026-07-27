import XCTest
import BeaconHubKit
@testable import beacon_hub

// A terminal outcome (401/403, dead credential) must gate the next poll -- mirrors ClaudeUsageGateTests
// exactly, because SonosProvider.noteOutcome/shouldPoll deliberately mirrors
// ClaudeCodeProvider.noteUsageOutcome/shouldPollUsage. Without this gate, a 403 that can never succeed for
// the stored credential would be re-issued every tick forever (issue #7's lesson, restated here per the
// plan's explicit instruction to write tests for it).
final class SonosGateTests: XCTestCase {

    func testTerminalGatesTheNextPoll() {
        let p = SonosProvider()
        let now = Date()
        XCTAssertTrue(p.shouldPoll(now: now), "an ungated provider should poll")

        p.noteOutcome(.terminal(reason: "Sonos not authorized for this scope (HTTP 403)", kind: .other))
        XCTAssertFalse(p.shouldPoll(now: now), "a terminal must gate the next poll")
    }

    // The gate is a window, not a permanent stop: a fixed credential is retried once it lapses, so the
    // hub self-heals without a restart.
    func testTerminalGateLapses() {
        let p = SonosProvider()
        let now = Date()
        p.noteOutcome(.terminal(reason: "x", kind: .other))
        XCTAssertTrue(p.shouldPoll(now: now.addingTimeInterval(901)),
                     "the gate should lapse so a fixed credential is retried")
    }

    // A live poll clears the gate outright, so recovery does not wait out the window.
    func testLiveClearsTheGate() {
        let p = SonosProvider()
        p.noteOutcome(.terminal(reason: "x", kind: .other))
        p.noteOutcome(.live)
        XCTAssertTrue(p.shouldPoll(now: Date()), "live must clear the backoff")
    }

    // .inactive ("no room selected yet") deliberately sets no gate: it is cheap to recheck and must stay
    // able to notice the user picking a room without waiting out a cooldown.
    func testInactiveDoesNotGate() {
        let p = SonosProvider()
        p.noteOutcome(.inactive(reason: "Sonos: no room selected"))
        XCTAssertTrue(p.shouldPoll(now: Date()), "inactive must not gate")
    }

    // A transient failure backs off but does not gate as hard as terminal (base-cadence exponential
    // backoff via UsagePollDecision.pollDelay, not the fixed terminal cap).
    func testTransientGatesBrieflyThenLapses() {
        let p = SonosProvider(interval: 5)
        let now = Date()
        p.noteOutcome(.transient(retryAfter: nil, reason: "Sonos unavailable (HTTP 500)"))
        XCTAssertFalse(p.shouldPoll(now: now), "a fresh transient failure should still back off briefly")
        XCTAssertTrue(p.shouldPoll(now: now.addingTimeInterval(901)),
                     "a transient backoff must never exceed the terminal cap")
    }

    // A server-directed Retry-After is honored even beyond the exponential curve (mirrors Claude's gate).
    func testTransientHonorsServerRetryAfter() {
        let p = SonosProvider(interval: 5)
        let now = Date()
        p.noteOutcome(.transient(retryAfter: 20, reason: "Sonos unavailable (HTTP 429)"))
        XCTAssertFalse(p.shouldPoll(now: now.addingTimeInterval(5)),
                      "a 20s server-directed Retry-After must not be undercut by the base interval")
    }
}
