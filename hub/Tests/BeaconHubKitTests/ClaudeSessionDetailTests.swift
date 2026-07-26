import XCTest
@testable import BeaconHubKit

// The row content the device shows for a session: project (repo), title, and the last message.
final class ClaudeSessionDetailTests: XCTestCase {

    private func line(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }
    private func asst(_ text: String, stop: String? = "end_turn") -> [String: Any] {
        var msg: [String: Any] = ["content": [["type": "text", "text": text]]]
        if let stop { msg["stop_reason"] = stop }
        return ["type": "assistant", "sessionId": "s", "timestamp": "2026-07-26T21:00:00.000Z", "message": msg]
    }
    private func user(_ text: String) -> [String: Any] {
        ["type": "user", "sessionId": "s", "timestamp": "2026-07-26T21:00:01.000Z",
         "message": ["content": [["type": "text", "text": text]]]]
    }

    // --- title ---

    func testTitleComesFromCustomTitleRecord() {
        let text = [line(user("hello")),
                    line(["type": "custom-title", "sessionId": "s", "customTitle": "deals_v2 schema alignment"])]
            .joined(separator: "\n")
        let s = ClaudeSessionScan.parse(text)
        XCTAssertEqual(s?.title, "deals_v2 schema alignment")
        XCTAssertEqual(s?.displayTitle, "deals_v2 schema alignment")
    }

    // Most transcripts carry no custom-title, so the opening prompt stands in -- it reads like a title.
    func testDisplayTitleFallsBackToFirstPrompt() {
        let text = [line(user("add a graph screen")), line(asst("on it")), line(user("also fahrenheit"))]
            .joined(separator: "\n")
        let s = ClaudeSessionScan.parse(text)
        XCTAssertNil(s?.title)
        XCTAssertEqual(s?.displayTitle, "add a graph screen", "the FIRST prompt titles the session")
    }

    // --- last message ---

    func testLastMessageIsTheNewestProse() {
        let text = [line(user("first")), line(asst("middle")), line(user("newest"))].joined(separator: "\n")
        XCTAssertEqual(ClaudeSessionScan.parse(text)?.lastMessage, "newest")
    }

    // A tool result is a user-typed record carrying machine output; it must not become "the last message".
    func testToolResultsAreNotMessages() {
        var toolRec = user("total 48 -rw-r--r-- 1 trever staff")
        toolRec["toolUseResult"] = ["stdout": "..."]
        let text = [line(asst("running ls")), line(toolRec)].joined(separator: "\n")
        XCTAssertEqual(ClaudeSessionScan.parse(text)?.lastMessage, "running ls")
    }

    // Sidechain records are a Task subagent's own conversation, not this session's.
    func testSidechainRecordsAreExcluded() {
        var sub = asst("subagent chatter")
        sub["isSidechain"] = true
        let text = [line(asst("main thread")), line(sub)].joined(separator: "\n")
        XCTAssertEqual(ClaudeSessionScan.parse(text)?.lastMessage, "main thread")
    }

    // tool_use / tool_result blocks are dropped because only `text` blocks are read.
    func testOnlyTextBlocksAreRead() {
        let rec: [String: Any] = ["type": "assistant", "sessionId": "s",
                                  "timestamp": "2026-07-26T21:00:00.000Z",
                                  "message": ["content": [["type": "text", "text": "editing the view"],
                                                           ["type": "tool_use", "name": "Edit",
                                                            "input": ["file_path": "/secret/path"]]]]]
        let s = ClaudeSessionScan.parse(line(rec))
        XCTAssertEqual(s?.lastMessage, "editing the view")
    }

    func testOneLineCollapsesWhitespaceRuns() {
        XCTAssertEqual(ClaudeSessionScan.oneLine("a\n\n  b\tc  "), "a b c")
        XCTAssertEqual(ClaudeSessionScan.oneLine("   "), "")
    }

    func testMessageContentMayBeABareString() {
        let rec: [String: Any] = ["type": "user", "sessionId": "s",
                                  "timestamp": "2026-07-26T21:00:00.000Z",
                                  "message": ["content": "plain string form"]]
        XCTAssertEqual(ClaudeSessionScan.parse(line(rec))?.lastMessage, "plain string form")
    }

    // --- project name ---

    // cwd follows the agent into subdirectories: a `cd hub` makes cwd's basename "hub" for a session
    // rooted at "beacon". Observed live on 2 of 3 active sessions, so this is the common case, not an edge.
    func testProjectRecoversRootFromTranscriptDirName() {
        XCTAssertEqual(ClaudeSessionScan.projectName(cwd: "/Users/t/eng-stuff/beacon/hub",
                                                     transcriptDirName: "-Users-t-eng-stuff-beacon"),
                       "beacon")
    }

    // The whole dashed string is compared, never split on "-", so a repo whose own name contains dashes
    // resolves correctly instead of yielding its last fragment.
    func testProjectHandlesDashesInTheRepoName() {
        XCTAssertEqual(ClaudeSessionScan.projectName(cwd: "/Users/t/tinyunicorns/ice-tracker-bar/Sources",
                                                     transcriptDirName: "-Users-t-tinyunicorns-ice-tracker-bar"),
                       "ice-tracker-bar")
    }

    func testProjectUsesCwdWhenAlreadyAtTheRoot() {
        XCTAssertEqual(ClaudeSessionScan.projectName(cwd: "/Users/t/eng-stuff/beacon",
                                                     transcriptDirName: "-Users-t-eng-stuff-beacon"),
                       "beacon")
    }

    // Irreconcilable (agent cded somewhere unrelated, or the directory was renamed): the cwd basename is
    // still a better label than nothing, and must not loop or crash.
    func testProjectFallsBackWhenDirNameCannotBeReconciled() {
        XCTAssertEqual(ClaudeSessionScan.projectName(cwd: "/tmp/elsewhere",
                                                     transcriptDirName: "-Users-t-eng-stuff-beacon"),
                       "elsewhere")
        XCTAssertEqual(ClaudeSessionScan.projectName(cwd: "/", transcriptDirName: "-nope"), "/")
        XCTAssertNil(ClaudeSessionScan.projectName(cwd: nil, transcriptDirName: "-x"))
        XCTAssertEqual(ClaudeSessionScan.projectName(cwd: "/a/b", transcriptDirName: nil), "b")
    }
}
