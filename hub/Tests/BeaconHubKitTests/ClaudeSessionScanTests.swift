import XCTest
@testable import BeaconHubKit

// Fixtures are shaped from real ~/.claude/projects transcripts (Claude Code 2.1.219,
// entrypoint claude-desktop), token-free by nature -- transcripts carry no credentials.
final class ClaudeSessionScanTests: XCTestCase {

    private func line(_ o: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
    }

    func testExtractsIdentityAndTokens() {
        let text = [
            line(["type": "user", "sessionId": "s-abc", "cwd": "/Users/t/eng-stuff/beacon",
                  "gitBranch": "perf/swipe-render", "timestamp": "2026-07-26T13:00:00.100Z"]),
            line(["type": "assistant", "sessionId": "s-abc", "timestamp": "2026-07-26T13:00:05.200Z",
                  "message": ["usage": ["input_tokens": 10, "output_tokens": 90,
                                        "cache_creation_input_tokens": 5,
                                        "cache_read_input_tokens": 358_410]]]),
        ].joined(separator: "\n")

        let s = ClaudeSessionScan.parse(text)
        XCTAssertEqual(s?.sessionId, "s-abc")
        XCTAssertEqual(s?.cwd, "/Users/t/eng-stuff/beacon")
        XCTAssertEqual(s?.gitBranch, "perf/swipe-render")
        // cache_read is excluded on purpose: 358k of cache reads would swamp the real 105.
        XCTAssertEqual(s?.tokens, 105)
        XCTAssertEqual(s?.lastActivity, ClaudeSessionScan.parseTimestamp("2026-07-26T13:00:05.200Z"))
    }

    func testTruncatedFirstLineIsSkippedNotFatal() {
        // The app tails the last N bytes of a growing file, so line 1 is routinely a fragment.
        let text = "{\"type\":\"assist" + "\n" + line(["type": "user", "sessionId": "s-1",
                                                       "timestamp": "2026-07-26T13:00:00Z"])
        XCTAssertEqual(ClaudeSessionScan.parse(text)?.sessionId, "s-1")
    }

    func testReturnsNilWhenNoSessionId() {
        XCTAssertNil(ClaudeSessionScan.parse(line(["type": "user", "cwd": "/tmp"])))
        XCTAssertNil(ClaudeSessionScan.parse(""))
        XCTAssertNil(ClaudeSessionScan.parse("not json at all"))
    }

    func testLastNonEmptyCwdAndBranchWin() {
        let text = [
            line(["sessionId": "s", "cwd": "/a", "gitBranch": "main", "timestamp": "2026-07-26T13:00:00Z"]),
            line(["sessionId": "s", "cwd": "/b", "gitBranch": "feat/x", "timestamp": "2026-07-26T13:00:01Z"]),
            line(["sessionId": "s", "timestamp": "2026-07-26T13:00:02Z"]),   // absent must not clobber
        ].joined(separator: "\n")
        let s = ClaudeSessionScan.parse(text)
        XCTAssertEqual(s?.cwd, "/b")
        XCTAssertEqual(s?.gitBranch, "feat/x")
    }

    func testTrailingAssistantEndTurnMeansFinished() {
        let text = [
            line(["type": "user", "sessionId": "s", "timestamp": "2026-07-26T13:00:00Z"]),
            line(["type": "assistant", "sessionId": "s", "timestamp": "2026-07-26T13:00:01Z",
                  "message": ["stop_reason": "end_turn"]]),
        ].joined(separator: "\n")
        XCTAssertEqual(ClaudeSessionScan.parse(text)?.turnFinished, true)
    }

    // Regression: a tool-using turn ALSO ends on an assistant record. Treating that as "finished"
    // marked every actively-working session as needing attention -- caught against live transcripts,
    // where an in-flight session read as attention at age=3s.
    func testToolUseStopReasonIsStillWorking() {
        let text = [
            line(["type": "user", "sessionId": "s", "timestamp": "2026-07-26T13:00:00Z"]),
            line(["type": "assistant", "sessionId": "s", "timestamp": "2026-07-26T13:00:01Z",
                  "message": ["stop_reason": "tool_use", "content": [["type": "tool_use"]]]]),
        ].joined(separator: "\n")
        XCTAssertEqual(ClaudeSessionScan.parse(text)?.turnFinished, false)
    }

    func testPauseTurnIsStillWorking() {
        let text = line(["type": "assistant", "sessionId": "s", "timestamp": "2026-07-26T13:00:01Z",
                         "message": ["stop_reason": "pause_turn"]])
        XCTAssertEqual(ClaudeSessionScan.parse(text)?.turnFinished, false)
    }

    // Absent stop_reason must not claim attention: over-reporting "working" is harmless, while a
    // false "attention" nags about a session that needs nothing.
    func testMissingStopReasonIsNotFinished() {
        let text = line(["type": "assistant", "sessionId": "s", "timestamp": "2026-07-26T13:00:01Z"])
        XCTAssertEqual(ClaudeSessionScan.parse(text)?.turnFinished, false)
    }

    func testTrailingUserMeansWorking() {
        let text = [
            line(["type": "assistant", "sessionId": "s", "timestamp": "2026-07-26T13:00:00Z"]),
            line(["type": "user", "sessionId": "s", "timestamp": "2026-07-26T13:00:01Z"]),
        ].joined(separator: "\n")
        XCTAssertEqual(ClaudeSessionScan.parse(text)?.turnFinished, false)
    }

    func testBookkeepingRecordsDoNotResetTurnState() {
        // `attachment` / `last-prompt` routinely trail an assistant turn; treating them as activity
        // would flip a finished turn back to "working" and the row would never ask for attention.
        let text = [
            line(["type": "assistant", "sessionId": "s", "timestamp": "2026-07-26T13:00:00Z",
                  "message": ["stop_reason": "end_turn"]]),
            line(["type": "attachment", "sessionId": "s", "timestamp": "2026-07-26T13:00:01Z"]),
            line(["type": "last-prompt", "sessionId": "s", "timestamp": "2026-07-26T13:00:02Z"]),
        ].joined(separator: "\n")
        XCTAssertEqual(ClaudeSessionScan.parse(text)?.turnFinished, true)
    }

    func testStateMapping() {
        let now = Date()
        func s(ago: TimeInterval, finished: Bool) -> ScannedSession {
            ScannedSession(sessionId: "s", lastActivity: now.addingTimeInterval(-ago),
                           turnFinished: finished)
        }
        XCTAssertEqual(ClaudeSessionScan.state(for: s(ago: 5, finished: false), now: now), .working)
        XCTAssertEqual(ClaudeSessionScan.state(for: s(ago: 5, finished: true), now: now), .attention)
        // Past the working window but still fresh, with no finished turn => not claiming activity.
        XCTAssertEqual(ClaudeSessionScan.state(for: s(ago: 300, finished: false), now: now), .idle)
        // Past the idle TTL, attention must decay -- otherwise an abandoned transcript nags forever.
        XCTAssertEqual(ClaudeSessionScan.state(for: s(ago: 7200, finished: true), now: now), .idle)
    }

    func testIsRecentBoundsTheFileWalk() {
        let now = Date()
        XCTAssertTrue(ClaudeSessionScan.isRecent(mtime: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(ClaudeSessionScan.isRecent(mtime: now.addingTimeInterval(-90_000), now: now))
    }
}
