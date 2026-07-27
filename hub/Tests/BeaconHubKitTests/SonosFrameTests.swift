import XCTest
@testable import BeaconHubKit

// The Sonos now-playing frame carries room/track/artist/album/playing as a standalone hub->device
// frame. Its whole reason for a shrink loop is the same as `sdetail`'s: the device DROPS a frame longer
// than HUB_FRAME_MAX (1024 B) outright, and track/artist/album are free-form text off the Sonos API --
// character caps do not bound bytes.
final class SonosFrameTests: XCTestCase {

    private func decode(_ d: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: d) as! [String: Any]
    }

    func testEncodesWireShape() throws {
        let d = try SonosFrame(SonosNowPlaying(room: "Kitchen", track: "Black Hole Sun",
                                                artist: "Soundgarden", album: "Superunknown",
                                                playing: true)).encoded()
        let s = String(decoding: d, as: UTF8.self)
        XCTAssertTrue(s.hasSuffix("\n"), "frames are newline-delimited")
        XCTAssertTrue(s.contains("\"v\":1"))
        XCTAssertTrue(s.contains("\"room\":\"Kitchen\""))
        XCTAssertTrue(s.contains("\"track\":\"Black Hole Sun\""))
        XCTAssertTrue(s.contains("\"artist\":\"Soundgarden\""))
        XCTAssertTrue(s.contains("\"album\":\"Superunknown\""))
        XCTAssertTrue(s.contains("\"playing\":true"))
    }

    func testCapsFieldLengths() throws {
        let np = SonosNowPlaying(room: String(repeating: "r", count: 60),
                                  track: String(repeating: "t", count: 60),
                                  artist: String(repeating: "a", count: 60),
                                  album: String(repeating: "b", count: 60),
                                  playing: false)
        let obj = decode(try SonosFrame(np).encoded())
        let s = obj["sonos"] as! [String: Any]
        XCTAssertEqual((s["room"] as! String).count, SonosLimits.roomMaxChars)
        XCTAssertEqual((s["track"] as! String).count, SonosLimits.trackMaxChars)
        XCTAssertEqual((s["artist"] as! String).count, SonosLimits.artistMaxChars)
        XCTAssertEqual((s["album"] as! String).count, SonosLimits.albumMaxChars)
    }

    func testNilFieldsAreOmittedNotNull() throws {
        let obj = decode(try SonosFrame(SonosNowPlaying()).encoded())
        let s = obj["sonos"] as! [String: Any]
        XCTAssertNil(s["room"]); XCTAssertNil(s["track"]); XCTAssertNil(s["artist"])
        XCTAssertNil(s["album"]); XCTAssertNil(s["playing"])
    }

    // A present `false` is a real value, distinct from "unknown" (nil/omitted) -- the wire must be able
    // to say "definitely paused", not just "definitely playing or absent".
    func testExplicitFalsePlayingIsEncoded() throws {
        let obj = decode(try SonosFrame(SonosNowPlaying(playing: false)).encoded())
        let s = obj["sonos"] as! [String: Any]
        XCTAssertEqual(s["playing"] as? Bool, false)
    }

    // --- the ceiling, which is the point of the whole design ---

    func testWorstCaseAsciiFitsWithMargin() throws {
        let np = SonosNowPlaying(room: String(repeating: "W", count: SonosLimits.roomMaxChars),
                                  track: String(repeating: "W", count: SonosLimits.trackMaxChars),
                                  artist: String(repeating: "W", count: SonosLimits.artistMaxChars),
                                  album: String(repeating: "W", count: SonosLimits.albumMaxChars),
                                  playing: true)
        let bytes = try SonosFrame(np).encoded().count
        XCTAssertLessThan(bytes, SonosLimits.frameMaxBytes)
    }

    // Every character escapes to two bytes: the char caps are satisfied while the byte count doubles.
    func testAllQuotesStillFits() throws {
        let np = SonosNowPlaying(room: String(repeating: "\"", count: SonosLimits.roomMaxChars),
                                  track: String(repeating: "\"", count: SonosLimits.trackMaxChars),
                                  artist: String(repeating: "\\", count: SonosLimits.artistMaxChars),
                                  album: String(repeating: "\"", count: SonosLimits.albumMaxChars),
                                  playing: true)
        let d = try SonosFrame(np).encoded()
        XCTAssertLessThan(d.count, SonosLimits.frameMaxBytes)
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: d), "shrinking must leave valid JSON")
    }

    // Emoji are 4 raw UTF-8 bytes each; a char-capped field can blow past a naive byte estimate.
    func testAllEmojiStillFits() throws {
        let np = SonosNowPlaying(room: String(repeating: "🔥", count: SonosLimits.roomMaxChars),
                                  track: String(repeating: "🎯", count: SonosLimits.trackMaxChars),
                                  artist: String(repeating: "🚀", count: SonosLimits.artistMaxChars),
                                  album: String(repeating: "🎧", count: SonosLimits.albumMaxChars),
                                  playing: true)
        let d = try SonosFrame(np).encoded()
        XCTAssertLessThan(d.count, SonosLimits.frameMaxBytes)
    }

    // Control characters escape to `\uXXXX` -- 6 bytes each, the worst single-scalar case, and still
    // fits without shrinking given these caps (124 chars total * 6 B = 744 B of text alone).
    func testAllControlCharsStillFits() throws {
        let np = SonosNowPlaying(room: String(repeating: "\u{01}", count: SonosLimits.roomMaxChars),
                                  track: String(repeating: "\u{01}", count: SonosLimits.trackMaxChars),
                                  artist: String(repeating: "\u{01}", count: SonosLimits.artistMaxChars),
                                  album: String(repeating: "\u{01}", count: SonosLimits.albumMaxChars),
                                  playing: true)
        let d = try SonosFrame(np).encoded()
        XCTAssertLessThan(d.count, SonosLimits.frameMaxBytes)
    }

    // THE genuinely pathological case: a single Swift `Character` need not be one Unicode scalar. A
    // ZWJ-joined emoji sequence ("family": man+woman+girl+boy joined by U+200D) is ONE Character by
    // Swift's grapheme-cluster counting -- so `.prefix(cap)` lets it through -- but 7 Unicode scalars /
    // 25 raw UTF-8 bytes. Filled to every cap this is ~3.1 KB before shrinking, over 3x HUB_FRAME_MAX;
    // only the shrink loop stands between this and a silently-dropped frame on the device.
    func testZWJGraphemeClusterIsShrunkUnderTheCeiling() throws {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"   // "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1, "precondition: this really is one Character")
        XCTAssertGreaterThan(family.utf8.count, 20, "precondition: and a very heavy one")

        let np = SonosNowPlaying(room: String(repeating: family, count: SonosLimits.roomMaxChars),
                                  track: String(repeating: family, count: SonosLimits.trackMaxChars),
                                  artist: String(repeating: family, count: SonosLimits.artistMaxChars),
                                  album: String(repeating: family, count: SonosLimits.albumMaxChars),
                                  playing: true)
        let frame = SonosFrame(np)

        // Pre-shrink (single encode, no trimming) really does blow the ceiling -- otherwise this test
        // would pass vacuously without exercising the shrink loop at all.
        let preShrinkBytes = try JSONEncoder().encode(frame).count
        XCTAssertGreaterThan(preShrinkBytes, SonosLimits.frameMaxBytes)

        let d = try frame.encoded()
        XCTAssertLessThan(d.count, SonosLimits.frameMaxBytes,
                          "a ZWJ grapheme cluster must be shrunk, not dropped")
        let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any]
        XCTAssertNotNil(obj, "shrinking must never split a scalar into invalid UTF-8")
    }

    // Shrinking spends album first, then artist, then track -- room survives intact because it is what
    // distinguishes pages in a multi-speaker household, and the least load-bearing field goes first.
    func testShrinkOrderPrefersAlbumThenArtistThenTrackOverRoom() throws {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let np = SonosNowPlaying(room: String(repeating: family, count: SonosLimits.roomMaxChars),
                                  track: String(repeating: family, count: SonosLimits.trackMaxChars),
                                  artist: String(repeating: family, count: SonosLimits.artistMaxChars),
                                  album: String(repeating: family, count: SonosLimits.albumMaxChars),
                                  playing: true)
        let obj = decode(try SonosFrame(np).encoded())
        let s = obj["sonos"] as! [String: Any]
        XCTAssertEqual((s["room"] as! String).count, SonosLimits.roomMaxChars,
                       "room must survive the trim intact")
        // Trimmed to nothing (like SessionDetailsFrame, the field is emptied, not nulled out) -- album
        // and, in this worst case, artist too are the least load-bearing fields and go first.
        XCTAssertEqual(s["album"] as? String, "", "album is the least load-bearing field and goes first")
        XCTAssertEqual(s["artist"] as? String, "", "artist goes next once album is exhausted")
        XCTAssertGreaterThan((s["track"] as! String).count, 0, "track absorbs only what's left to trim")
        XCTAssertLessThan((s["track"] as! String).count, SonosLimits.trackMaxChars)
    }
}
