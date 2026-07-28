import XCTest
@testable import beacon_hub

// D-7 (plan §3): `onArtURL` must fire on its OWN last-URL comparison, before and independent of
// `onUpdate`'s `guard np != lastSent` text gate -- a station rotating cover art under one unchanging
// title/artist/album must not be swallowed by widening onUpdate's five-tuple instead.
//
// `emitNowPlaying` is internal (not private) precisely so this suite can drive the emission logic
// directly with a synthetic `SonosAPI.TrackMetadata`, the same "test the pure decision, not the network
// plumbing" convention SonosGateTests already established for noteOutcome/shouldPoll -- there is no
// URLProtocol-based HTTP mock in this test target, and building one just for this would be a bigger
// surface than the behaviour under test needs.
final class SonosProviderArtTests: XCTestCase {

    private func track(_ url: String?, title: String = "Black Hole Sun") -> SonosAPI.TrackMetadata {
        SonosAPI.TrackMetadata(track: title, artist: "Soundgarden", album: "Superunknown", imageUrl: url)
    }

    func testArtURLFiresOnFirstEmission() {
        let p = SonosProvider()
        let exp = expectation(description: "onArtURL")
        var seen: String??
        p.onArtURL = { url in seen = url; exp.fulfill() }
        p.emitNowPlaying(room: "Kitchen", track: track("http://cdn.example/a.jpg"), playing: true)
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(seen, "http://cdn.example/a.jpg")
    }

    // The whole point of D-7: the art URL changes while room/track/artist/album/playing do not, so
    // onUpdate's own dedup would swallow it -- onArtURL must fire anyway.
    func testArtURLFiresWhenOnlyArtChangesUnderAnUnchangedTextTuple() {
        let p = SonosProvider()
        let firstArt = expectation(description: "first art")
        p.onArtURL = { _ in firstArt.fulfill() }
        p.emitNowPlaying(room: "Kitchen", track: track("http://cdn.example/a.jpg"), playing: true)
        wait(for: [firstArt], timeout: 5)

        var updateFireCount = 0
        p.onUpdate = { _, _, _, _, _ in updateFireCount += 1 }

        let secondArt = expectation(description: "second art")
        var seen: String??
        p.onArtURL = { url in seen = url; secondArt.fulfill() }
        // Same room/track/artist/album/playing -- only the art URL differs (a station rotating covers).
        p.emitNowPlaying(room: "Kitchen", track: track("http://cdn.example/b.jpg"), playing: true)
        wait(for: [secondArt], timeout: 5)

        XCTAssertEqual(seen, "http://cdn.example/b.jpg")
        XCTAssertEqual(updateFireCount, 0, "onUpdate's own text-tuple gate correctly stays silent here -- "
            + "onArtURL must not depend on it firing")
    }

    func testArtURLDoesNotRefireForAnIdenticalURL() {
        let p = SonosProvider()
        let first = expectation(description: "first")
        p.onArtURL = { _ in first.fulfill() }
        p.emitNowPlaying(room: "Kitchen", track: track("http://cdn.example/a.jpg"), playing: true)
        wait(for: [first], timeout: 5)

        let noRefire = expectation(description: "no refire for an identical URL")
        noRefire.isInverted = true
        p.onArtURL = { _ in noRefire.fulfill() }
        p.emitNowPlaying(room: "Kitchen", track: track("http://cdn.example/a.jpg"), playing: true)
        wait(for: [noRefire], timeout: 0.5)
    }

    // The very first "no art" tick must still fire (nil is a real, reportable value distinct from
    // "never checked yet") -- this is what makes SonosArtPublisher's urlStep able to tell "no art ever
    // reported" from "art was cleared."
    func testArtURLFiresWithNilOnTheFirstNoArtTrack() {
        let p = SonosProvider()
        let exp = expectation(description: "nil art")
        var seen: String?? = "unset"
        p.onArtURL = { url in seen = url; exp.fulfill() }
        p.emitNowPlaying(room: "Kitchen", track: track(nil), playing: true)
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(seen, .some(nil))
    }

    func testArtURLDoesNotRefireWhenStillNilAcrossTicks() {
        let p = SonosProvider()
        let first = expectation(description: "first nil")
        p.onArtURL = { _ in first.fulfill() }
        p.emitNowPlaying(room: "Kitchen", track: track(nil), playing: true)
        wait(for: [first], timeout: 5)

        let noRefire = expectation(description: "no refire while still nil")
        noRefire.isInverted = true
        p.onArtURL = { _ in noRefire.fulfill() }
        p.emitNowPlaying(room: "Kitchen", track: track(nil, title: "A New Track"), playing: true)
        wait(for: [noRefire], timeout: 0.5)
    }
}
