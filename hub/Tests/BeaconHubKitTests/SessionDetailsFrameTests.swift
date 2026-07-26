import XCTest
@testable import BeaconHubKit

// The session-detail frame carries project/title/last-message per session row. Its whole reason for
// existing separately is the device's hard HUB_FRAME_MAX (1024 B) -- a longer frame is DROPPED, so the
// encoder must guarantee the ceiling for arbitrary human prose, not merely for well-behaved ASCII.
final class SessionDetailsFrameTests: XCTestCase {

    private func decode(_ d: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: d) as! [String: Any]
    }

    func testEncodesWireShape() throws {
        let d = try SessionDetailsFrame([
            SessionDetail(id: "s3", project: "beacon", title: "graph screen", msg: "on it")
        ]).encoded()
        let s = String(decoding: d, as: UTF8.self)
        XCTAssertTrue(s.hasSuffix("\n"), "frames are newline-delimited")
        XCTAssertTrue(s.contains("\"v\":1"))
        XCTAssertTrue(s.contains("\"project\":\"beacon\""))
        XCTAssertTrue(s.contains("\"msg\":\"on it\""))
    }

    func testCapsCountAndFieldLengths() throws {
        let rows = (0..<9).map { i in
            SessionDetail(id: "s\(i)",
                          project: String(repeating: "p", count: 60),
                          title: String(repeating: "t", count: 60),
                          msg: String(repeating: "m", count: 200))
        }
        let obj = decode(try SessionDetailsFrame(rows).encoded())
        let list = obj["sdetail"] as! [[String: Any]]
        XCTAssertEqual(list.count, SessionDetailLimits.maxCount)
        for r in list {
            XCTAssertEqual((r["project"] as! String).count, SessionDetailLimits.projectMaxChars)
            XCTAssertEqual((r["title"] as! String).count, SessionDetailLimits.titleMaxChars)
            XCTAssertEqual((r["msg"] as! String).count, SessionDetailLimits.msgMaxChars)
        }
    }

    func testNilFieldsAreOmitted() throws {
        let obj = decode(try SessionDetailsFrame([SessionDetail(id: "s1")]).encoded())
        let row = (obj["sdetail"] as! [[String: Any]])[0]
        XCTAssertNil(row["project"]); XCTAssertNil(row["title"]); XCTAssertNil(row["msg"])
        XCTAssertEqual(row["id"] as? String, "s1")
    }

    // --- the ceiling, which is the point of the whole design ---

    func testWorstCaseAsciiFitsWithMargin() throws {
        let rows = (0..<SessionDetailLimits.maxCount).map { _ in
            SessionDetail(id: "s99999",
                          project: String(repeating: "W", count: SessionDetailLimits.projectMaxChars),
                          title: String(repeating: "W", count: SessionDetailLimits.titleMaxChars),
                          msg: String(repeating: "W", count: SessionDetailLimits.msgMaxChars))
        }
        let bytes = try SessionDetailsFrame(rows).encoded().count
        XCTAssertLessThan(bytes, SessionDetailLimits.frameMaxBytes)
    }

    // Every character escapes to two bytes: the char caps are satisfied while the byte count doubles.
    func testAllQuotesStillFits() throws {
        let rows = (0..<SessionDetailLimits.maxCount).map { _ in
            SessionDetail(id: "s99999",
                          project: String(repeating: "\"", count: SessionDetailLimits.projectMaxChars),
                          title: String(repeating: "\\", count: SessionDetailLimits.titleMaxChars),
                          msg: String(repeating: "\"", count: SessionDetailLimits.msgMaxChars))
        }
        let d = try SessionDetailsFrame(rows).encoded()
        XCTAssertLessThan(d.count, SessionDetailLimits.frameMaxBytes)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: d), "shrinking must leave valid JSON")
    }

    // Emoji are 4 bytes each and JSON-encode as surrogate pairs; a char-capped field can blow the byte
    // ceiling several times over. The shrink loop is the only thing standing between this and a dropped
    // frame on the device.
    func testEmojiHeavyProseIsShrunkUnderTheCeiling() throws {
        let rows = (0..<SessionDetailLimits.maxCount).map { _ in
            SessionDetail(id: "s99999",
                          project: String(repeating: "🔥", count: SessionDetailLimits.projectMaxChars),
                          title: String(repeating: "🎯", count: SessionDetailLimits.titleMaxChars),
                          msg: String(repeating: "🚀", count: SessionDetailLimits.msgMaxChars))
        }
        let d = try SessionDetailsFrame(rows).encoded()
        XCTAssertLessThan(d.count, SessionDetailLimits.frameMaxBytes, "emoji prose must be shrunk, not dropped")
        let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        XCTAssertNotNil(obj, "shrinking must never split a scalar into invalid UTF-8")
        XCTAssertEqual((obj?["sdetail"] as? [[String: Any]])?.count, SessionDetailLimits.maxCount,
                       "shrinking trims text; it must not drop whole rows")
    }

    // Shrinking spends the message first -- it is the least load-bearing field, and the project/title are
    // what identify the row. The emoji project is what pushes this case over the ceiling at all: with an
    // ASCII project the frame lands near 850 B and never shrinks, so the assertion below would be vacuous.
    func testShrinkPrefersTheMessageOverTheTitle() throws {
        let rows = (0..<SessionDetailLimits.maxCount).map { _ in
            SessionDetail(id: "s99999",
                          project: String(repeating: "🔥", count: SessionDetailLimits.projectMaxChars),
                          title: String(repeating: "T", count: SessionDetailLimits.titleMaxChars),
                          msg: String(repeating: "🚀", count: SessionDetailLimits.msgMaxChars))
        }
        let obj = decode(try SessionDetailsFrame(rows).encoded())
        let list = obj["sdetail"] as! [[String: Any]]
        XCTAssertEqual((list[0]["title"] as! String).count, SessionDetailLimits.titleMaxChars,
                       "the title should survive intact while the message absorbs the trim")
        XCTAssertLessThan((list[0]["msg"] as! String).count, SessionDetailLimits.msgMaxChars)
    }
}
