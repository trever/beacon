import XCTest
@testable import BeaconHubKit

// The oauth/usage endpoint answers 403 for a token that is perfectly live but lacks the scope the
// endpoint wants (a Claude Desktop token). Classified transient it was re-issued on every backoff tick
// until the edge answered 429 with Retry-After: 3600 -- the retry loop manufactured its own rate limit.
final class ClaudeUsageClassifyTests: XCTestCase {

    // The regression that mattered. If this ever reads .transient again, the hub is back to re-firing a
    // call that cannot succeed until the endpoint rate-limits it.
    func testForbiddenIsTerminalNotTransient() {
        let o = UsagePollDecision.classifyClaudeUsageFailure(status: 403, retryAfter: nil)
        guard case .terminal(let reason, let kind) = o else {
            return XCTFail("403 must be terminal, got \(o)")
        }
        // .other, not .staleToken: providerInactive() never auto-demotes .other to a quiet "inactive", so
        // the actionable reason stays visible instead of being hidden as an abandoned provider.
        XCTAssertEqual(kind, .other)
        XCTAssertTrue(reason.contains("403"), "reason should name the status: \(reason)")
    }

    // A 403 must stay terminal even when the server attaches a Retry-After -- the header would otherwise
    // look like an invitation to retry something that structurally cannot succeed.
    func testForbiddenIgnoresRetryAfter() {
        guard case .terminal = UsagePollDecision.classifyClaudeUsageFailure(status: 403, retryAfter: 30) else {
            return XCTFail("403 with Retry-After must still be terminal")
        }
    }

    // 429 keeps its meaning: it IS retryable, and the server's Retry-After is what paces it.
    func testTooManyRequestsStaysTransientAndCarriesRetryAfter() {
        let o = UsagePollDecision.classifyClaudeUsageFailure(status: 429, retryAfter: 3600)
        guard case .transient(let retryAfter, let reason) = o else {
            return XCTFail("429 must stay transient, got \(o)")
        }
        XCTAssertEqual(retryAfter, 3600)
        XCTAssertTrue(reason.contains("429"), "reason should name the status: \(reason)")
    }

    func testServerErrorStaysTransient() {
        guard case .transient = UsagePollDecision.classifyClaudeUsageFailure(status: 503, retryAfter: nil) else {
            return XCTFail("5xx must stay transient")
        }
    }

    // A 3600s Retry-After sits exactly at the sanity cap, so it is honored in full rather than clamped
    // down -- this is the value the live endpoint actually returned.
    func testHourLongRetryAfterIsHonoredInFull() {
        let delay = UsagePollDecision.pollDelay(consecutiveFails: 1, retryAfter: 3600,
                                                base: 45, cap: 900, retryAfterSanityCap: 3600,
                                                jitterFraction: 0)
        XCTAssertEqual(delay, 3600, "a 3600s Retry-After should not be clamped below the server's ask")
    }
}
