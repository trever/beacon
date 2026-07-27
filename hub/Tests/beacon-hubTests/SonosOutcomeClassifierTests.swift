import XCTest
import BeaconHubKit
@testable import beacon_hub

// The single most important correctness requirement in the Sonos brief: 401/403 must classify .terminal,
// not .transient, because retrying either can never succeed for the same credential/scope (issue #7's
// lesson, restated for Sonos). 404 is deliberately different -- see SonosOutcomeClassifier's doc comment.
final class SonosOutcomeClassifierTests: XCTestCase {

    func test401IsTerminalStaleToken() {
        let outcome = SonosOutcomeClassifier.classify(status: 401, retryAfter: nil)
        guard case .terminal(_, let kind) = outcome else { return XCTFail("401 must classify .terminal, got \(outcome)") }
        XCTAssertEqual(kind, .staleToken)
    }

    func test403IsTerminal() {
        let outcome = SonosOutcomeClassifier.classify(status: 403, retryAfter: nil)
        guard case .terminal = outcome else { return XCTFail("403 must classify .terminal, got \(outcome)") }
    }

    func test404IsTransientNotTerminal() {
        // Unlike 401/403, a stale Sonos group id is a normal, frequent, recoverable event (the user
        // grouped/ungrouped speakers) -- it must stay retryable, not gate at the terminal cap.
        let outcome = SonosOutcomeClassifier.classify(status: 404, retryAfter: nil)
        guard case .transient = outcome else { return XCTFail("404 must classify .transient, got \(outcome)") }
    }

    func testTransientStatusesHonorRetryAfter() {
        let cases = [429, 500, 502, 503]
        for status in cases {
            let outcome = SonosOutcomeClassifier.classify(status: status, retryAfter: 30)
            guard case .transient(let retryAfter, _) = outcome else {
                XCTFail("HTTP \(status) must classify .transient, got \(outcome)"); continue
            }
            XCTAssertEqual(retryAfter, 30, "HTTP \(status) must carry the server's Retry-After through")
        }
    }

    func testUnknownStatusFallsBackToTransient() {
        let outcome = SonosOutcomeClassifier.classify(status: 418, retryAfter: nil)
        guard case .transient = outcome else { return XCTFail("an unrecognized status must default .transient, got \(outcome)") }
    }
}
