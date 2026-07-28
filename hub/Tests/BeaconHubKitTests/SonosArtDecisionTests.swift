import XCTest
@testable import BeaconHubKit

// SonosArtDecision is the two-level cache design 2026-07-27-sonos-album-art-design.md §5 hinges on: a
// cheap URL-identity check first (kills ~99% of ticks at zero cost), then a tile-digest check second
// (the one that makes an expiring-signature CDN URL cost one HTTPS GET instead of a BLE frame + device
// download). These tests exercise both levels as pure functions, no network, no CoreGraphics, no
// LanAssetServer -- see SonosArtPublisherTests for the impure pipeline that wires them together.
final class SonosArtDecisionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let debounce: TimeInterval = 2

    // --- urlStep: the ~99% case, asserted first ---

    func testIdenticalURLDoesNothing() {
        let state = SonosArtCacheState(lastImageUrl: "http://cdn.example/a.jpg", gen: 3)
        let action = SonosArtDecision.urlStep(newImageUrl: "http://cdn.example/a.jpg", state: state,
                                              artEnabled: true, now: now, debounce: debounce)
        XCTAssertEqual(action, .doNothing, "a byte-identical URL must never fetch, arm or publish")
    }

    func testChangedURLPublishes() {
        let state = SonosArtCacheState(lastImageUrl: "http://cdn.example/old.jpg", gen: 3)
        let action = SonosArtDecision.urlStep(newImageUrl: "http://cdn.example/new.jpg", state: state,
                                              artEnabled: true, now: now, debounce: debounce)
        XCTAssertEqual(action, .publish, "a genuinely changed URL must trigger a fetch+render")
    }

    func testNilURLClears() {
        let state = SonosArtCacheState(lastImageUrl: "http://cdn.example/a.jpg", gen: 3)
        let action = SonosArtDecision.urlStep(newImageUrl: nil, state: state,
                                              artEnabled: true, now: now, debounce: debounce)
        XCTAssertEqual(action, .clear, "no art for this track must clear explicitly, never go quiet")
    }

    func testFirstEverURLWithNoPriorStatePublishes() {
        let action = SonosArtDecision.urlStep(newImageUrl: "http://cdn.example/a.jpg",
                                              state: SonosArtCacheState(),
                                              artEnabled: true, now: now, debounce: debounce)
        XCTAssertEqual(action, .publish)
    }

    // --- digestStep: the correct-second level ---

    func testDifferentURLWithIdenticalDigestDoesNothing() {
        // The expiring-signature case: the URL string changed but the actual pixels did not. `digestStep`
        // is a pure function that only REPORTS the decision -- it is the caller (SonosArtPublisher) that
        // is responsible for calling `nextGen` on `.publish` and never on `.doNothing`; that "no gen bump"
        // property is asserted end-to-end in SonosArtPublisherTests, since a pure `SonosArtCacheState`
        // value here has no gen-mutation behaviour of its own to observe.
        let state = SonosArtCacheState(lastImageUrl: "http://cdn.example/signed?exp=1", lastTileDigest: "deadbeef", gen: 5)
        let action = SonosArtDecision.digestStep(newDigest: "deadbeef", state: state)
        XCTAssertEqual(action, .doNothing)
    }

    func testDifferentURLWithDifferentDigestPublishes() {
        let state = SonosArtCacheState(lastImageUrl: "http://cdn.example/a.jpg", lastTileDigest: "aaaa", gen: 5)
        let action = SonosArtDecision.digestStep(newDigest: "bbbb", state: state)
        XCTAssertEqual(action, .publish)
    }

    // --- art disabled: D-6, folds into "the effective URL is nil" ---

    func testArtDisabledClearsOnceThenDoesNothing() {
        let playing = SonosArtCacheState(lastImageUrl: "http://cdn.example/a.jpg", lastTileDigest: "aaaa", gen: 5)
        let first = SonosArtDecision.urlStep(newImageUrl: "http://cdn.example/a.jpg", state: playing,
                                             artEnabled: false, now: now, debounce: debounce)
        XCTAssertEqual(first, .clear, "toggling off must publish exactly one S2")

        // The caller commits `.clear` by nil-ing the cached URL/digest and bumping gen (SonosArtPublisher
        // does this; simulated here so this suite stays a pure function test).
        let cleared = SonosArtCacheState(lastImageUrl: nil, lastTileDigest: nil, gen: 6)
        let second = SonosArtDecision.urlStep(newImageUrl: "http://cdn.example/a.jpg", state: cleared,
                                              artEnabled: false, now: now, debounce: debounce)
        XCTAssertEqual(second, .doNothing, "every subsequent tick while disabled must go quiet, not re-clear")
    }

    func testArtDisabledWithNothingEverPublishedDoesNothing() {
        // Fresh launch, toggle already off, first-ever tick against an empty cache: `urlStep` alone
        // correctly says "nothing to do" here (effective nil == the cache's already-nil lastImageUrl).
        // This is deliberately NOT the same code path that guarantees D-6's "publish exactly one S2 on
        // the OFF transition" -- that guarantee lives in SonosArtPublisher.setArtEnabled, which clears
        // unconditionally on every OFF transition regardless of what urlStep alone would say (see
        // SonosArtPublisherTests.testToggleOffEmitsExactlyOneS2ThenSilence). urlStep's own role here is
        // only the ongoing "stay quiet while already disabled" tick-by-tick check.
        let action = SonosArtDecision.urlStep(newImageUrl: "http://cdn.example/a.jpg", state: SonosArtCacheState(),
                                              artEnabled: false, now: now, debounce: debounce)
        XCTAssertEqual(action, .doNothing)
    }

    // --- debounce, both directions ---

    func testDebounceSuppressesAPublishWithinTheWindow() {
        let state = SonosArtCacheState(lastImageUrl: "http://cdn.example/old.jpg",
                                       lastPublishedAt: now, gen: 3)
        let action = SonosArtDecision.urlStep(newImageUrl: "http://cdn.example/new.jpg", state: state,
                                              artEnabled: true, now: now.addingTimeInterval(1.999),
                                              debounce: debounce)
        XCTAssertEqual(action, .doNothing, "a tile current for less than the debounce window must not publish yet")
    }

    func testDebounceAllowsAPublishAtOrAfterTheWindow() {
        let state = SonosArtCacheState(lastImageUrl: "http://cdn.example/old.jpg",
                                       lastPublishedAt: now, gen: 3)
        let action = SonosArtDecision.urlStep(newImageUrl: "http://cdn.example/new.jpg", state: state,
                                              artEnabled: true, now: now.addingTimeInterval(2.0),
                                              debounce: debounce)
        XCTAssertEqual(action, .publish, "exactly at the debounce window a genuinely changed URL must publish")
    }

    func testDebounceNeverAppliesToClear() {
        // A toggle-off (or a track with no art) must clear immediately -- it carries no URL and arms
        // nothing, so there is no reason to delay it behind the scrub-protection window meant for `.publish`.
        let state = SonosArtCacheState(lastImageUrl: "http://cdn.example/a.jpg", lastPublishedAt: now, gen: 3)
        let action = SonosArtDecision.urlStep(newImageUrl: nil, state: state, artEnabled: true,
                                              now: now.addingTimeInterval(0.001), debounce: debounce)
        XCTAssertEqual(action, .clear)
    }

    // --- gen: opaque identity, not an ordering (D-2) ---

    func testNextGenIncrements() {
        XCTAssertEqual(SonosArtDecision.nextGen(7), 8)
    }

    func testNextGenWrapsRatherThanTraps() {
        XCTAssertEqual(SonosArtDecision.nextGen(UInt32.max), 0, "gen is an opaque identity (D-2); overflow must not trap")
    }

    // MARK: - httpsUpgraded (the ATS failure found on real hardware 2026-07-28)

    // The exact shape Sonos returned for a SiriusXM track. Plain http, which macOS ATS refuses.
    func testHTTPArtURLIsUpgradedToHTTPS() {
        XCTAssertEqual(
            SonosArtDecision.httpsUpgraded("http://albumart.siriusxm.com/albumart/1300/WBVARI_x_m.jpg"),
            "https://albumart.siriusxm.com/albumart/1300/WBVARI_x_m.jpg")
    }

    func testHTTPSArtURLIsLeftAlone() {
        let u = "https://albumart.siriusxm.com/albumart/1300/WBVARI_x_m.jpg"
        XCTAssertEqual(SonosArtDecision.httpsUpgraded(u), u)
    }

    // Only the scheme changes: path, query and port must survive untouched, because art URLs can carry
    // an expiring signature in the query and dropping it would turn a working fetch into a 403.
    func testUpgradePreservesPortQueryAndPath() {
        XCTAssertEqual(
            SonosArtDecision.httpsUpgraded("http://h.example.com:8080/a/b.jpg?sig=abc&t=1"),
            "https://h.example.com:8080/a/b.jpg?sig=abc&t=1")
    }

    // A scheme we do not recognise is returned verbatim rather than rewritten into something that would
    // fail differently -- the caller's URL(string:) is the one that decides it is unusable.
    func testUnknownSchemeIsUntouched() {
        XCTAssertEqual(SonosArtDecision.httpsUpgraded("data:image/png;base64,AAAA"),
                       "data:image/png;base64,AAAA")
        XCTAssertEqual(SonosArtDecision.httpsUpgraded("not a url"), "not a url")
    }

    // Case-insensitive per RFC 3986: schemes are not case sensitive and Sonos is not contractually
    // bound to lowercase them.
    func testUppercaseHTTPSchemeIsUpgraded() {
        XCTAssertEqual(SonosArtDecision.httpsUpgraded("HTTP://h.example.com/a.jpg"),
                       "https://h.example.com/a.jpg")
    }
}
