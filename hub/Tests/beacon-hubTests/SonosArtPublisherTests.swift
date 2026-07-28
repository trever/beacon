import XCTest
import Network
import BeaconHubKit
@testable import beacon_hub

// SonosArtPublisher is the impure integration point: SonosArtDecision (pure) + LanAssetServer.arm (WS-1)
// + SonosArtRenderer.fetchAndRender (Phase A) + the `sart` frame (WS-0, frozen). These tests substitute a
// spy for the server and a controllable stub for the fetch, so the whole pipeline runs in-process with no
// network and no LAN listener -- see this file's report section on how the publish path is tested without
// live Sonos credentials or a network.
//
// Timing note: `SonosArtPublisher` confines all of its state to a private serial queue and calls back out
// asynchronously (`onFrame`/`onLocalNetworkOutcome`). Tests that expect a REAL event wait on an
// `XCTestExpectation` fulfilled by that event -- the only reliable signal. Tests that assert something
// must NOT happen use either `drain(_:)` (safe only when the code path under test does no further async
// work of its own, e.g. the page-list/link gates, which return before ever calling fetchAndRender) or an
// `isInverted` expectation with a short real wait (safe for paths that DO fan out through an async fetch,
// where enqueue-ordering against a bare `drain()` would not be deterministic).
final class SonosArtPublisherTests: XCTestCase {

    // MARK: - test doubles

    private final class ArmSpy: SonosArtPublisher.Arming {
        struct Call { let payloadCount: Int; let contentType: String; let peer: IPv4Address; let ttl: TimeInterval; let maxServes: Int }
        private(set) var calls: [Call] = []
        var onServed: ((Bool) -> Void)?
        var result: Result<URL, LanAssetServer.ArmError> = .success(
            URL(string: "http://127.0.0.1:54321/a/" + String(repeating: "0", count: 32))!)

        func arm(_ data: Data, contentType: String, peer: IPv4Address, ttl: TimeInterval, maxServes: Int,
                 completion: @escaping (Result<URL, LanAssetServer.ArmError>) -> Void) {
            calls.append(Call(payloadCount: data.count, contentType: contentType, peer: peer, ttl: ttl, maxServes: maxServes))
            completion(result)
        }
        func disarm() {}
    }

    private final class FetchSpy {
        var handler: (URL, @escaping (Result<SonosArtRenderer.Tile, SonosArtRenderer.FetchError>) -> Void) -> Void
            = { _, completion in completion(.failure(.decodeFailed)) }
        // Counts attempts, so a test can assert a fetch did NOT happen -- the deferred-url tests need
        // "nothing was spent" as a positive assertion, not an absence of some other signal.
        private(set) var callCount = 0
        private(set) var urls: [URL] = []
        func call(_ url: URL, _ completion: @escaping (Result<SonosArtRenderer.Tile, SonosArtRenderer.FetchError>) -> Void) {
            callCount += 1
            urls.append(url)
            handler(url, completion)
        }
    }

    // A spy PowerAsserting that only counts -- mirrors LanAssetServerTests' own spy (file-private there,
    // so this file needs its own).
    private final class PowerAssertionSpy: PowerAsserting {
        private(set) var beginCount = 0
        func begin(_ reason: String) -> UUID { beginCount += 1; return UUID() }
        func end(_ token: UUID) {}
    }

    // A controllable clock (mirrors LanAssetServerTests' ttlScheduler stub, one layer up):
    // SonosArtPublisher takes an injectable `now: () -> Date`, and several tests here need to issue a
    // second real tick after the first -- without this, `Date()` elapses only a few milliseconds between
    // two calls made back to back in-process, comfortably inside SonosArtDecision's 2 s debounce window,
    // and would make a test pass (or hang) for the wrong reason: the debounce silently swallowing the
    // second tick rather than the behaviour actually under test running. This bit twice while writing
    // this suite (testToggleOnRepublishesOnNextTick, testIdenticalDigestUnderANewURLPublishesNothing) --
    // both were passing before this fix, for the wrong reason. Advance the clock explicitly wherever a
    // test needs a second tick to be genuinely past the debounce window.
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private func tile(stamp: UInt8 = 0xAA, digest: String = "digest-a") -> SonosArtRenderer.Tile {
        SonosArtRenderer.Tile(pixels: Data(repeating: stamp, count: 32), sha256Hex: digest)
    }

    private func makePublisher(artEnabled: Bool = true, server: SonosArtPublisher.Arming, clock: Clock,
                               fetch: @escaping (URL, @escaping (Result<SonosArtRenderer.Tile, SonosArtRenderer.FetchError>) -> Void) -> Void)
        -> SonosArtPublisher {
        SonosArtPublisher(artEnabled: artEnabled, server: server, fetchAndRender: fetch, now: { clock.now })
    }

    private func openGate(_ pub: SonosArtPublisher, ip: String = "192.168.1.55") {
        pub.setSonosPageEnabled(true)
        pub.setLinkUp(true)
        pub.setDeviceIP(ip)
    }

    private func decode(_ data: Data) -> SonosArtFrame.SonosArt? {
        (try? JSONDecoder().decode(SonosArtFrame.self, from: data))?.sart
    }

    private func drain(_ pub: SonosArtPublisher) {
        let exp = expectation(description: "drain")
        pub.drain { exp.fulfill() }
        wait(for: [exp], timeout: 5)
    }

    // MARK: - arm parameters (design §7.1: strictly tighter than OTA on every axis)

    func testArmParametersMatchDesign() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        let t = tile()
        fetch.handler = { _, completion in completion(.success(t)) }
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)
        openGate(pub)

        let frame = expectation(description: "S1")
        pub.onFrame = { _ in frame.fulfill() }
        pub.handleArtURL("http://cdn.example/a.jpg")
        wait(for: [frame], timeout: 5)

        XCTAssertEqual(arm.calls.count, 1)
        XCTAssertEqual(arm.calls.first?.ttl, 30)
        XCTAssertEqual(arm.calls.first?.maxServes, 1)
        XCTAssertEqual(arm.calls.first?.contentType, "application/octet-stream")
        XCTAssertEqual(arm.calls.first?.payloadCount, t.pixels.count)
    }

    // MARK: - the two gates: no sonos page, no BLE link (design §7.1's real gate, not a comment)

    func testNoArmWhenSonosPageAbsent() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        var fetchCalled = false
        fetch.handler = { _, completion in fetchCalled = true; completion(.success(self.tile())) }
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)
        pub.setLinkUp(true)
        pub.setDeviceIP("192.168.1.55")
        // sonos page deliberately left disabled

        pub.handleArtURL("http://cdn.example/a.jpg")
        drain(pub)   // safe: the gate returns before ever calling fetchAndRender, so there is no further
                     // async work in flight for drain() to race against.

        XCTAssertFalse(fetchCalled, "must not even fetch, let alone arm, with no sonos page in the page list")
        XCTAssertTrue(arm.calls.isEmpty)
    }

    func testNoArmWhenLinkDown() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        var fetchCalled = false
        fetch.handler = { _, completion in fetchCalled = true; completion(.success(self.tile())) }
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)
        pub.setSonosPageEnabled(true)
        pub.setDeviceIP("192.168.1.55")
        // BLE link deliberately left down

        pub.handleArtURL("http://cdn.example/a.jpg")
        drain(pub)

        XCTAssertFalse(fetchCalled, "must not even fetch, let alone arm, while the BLE link is down")
        XCTAssertTrue(arm.calls.isEmpty)
    }

    // MARK: - D-5: never a sleep assertion

    func testArtPublishTakesNoSleepAssertion() {
        let spy = PowerAssertionSpy()
        let previous = PowerAssertions.shared
        PowerAssertions.shared = spy
        defer { PowerAssertions.shared = previous }

        let arm = ArmSpy()
        let fetch = FetchSpy()
        let t = tile()
        fetch.handler = { _, completion in completion(.success(t)) }
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)
        openGate(pub)

        let frame = expectation(description: "S1")
        pub.onFrame = { _ in frame.fulfill() }
        pub.handleArtURL("http://cdn.example/a.jpg")
        wait(for: [frame], timeout: 5)

        XCTAssertEqual(spy.beginCount, 0, "album art must never take an idle-sleep assertion (design §7.2)")
    }

    // MARK: - D-6: the toggle clears, it does not go quiet

    func testToggleOffEmitsExactlyOneS2ThenSilence() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        let t = tile()
        fetch.handler = { _, completion in completion(.success(t)) }
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)
        openGate(pub)

        var frames: [Data] = []
        let s1 = expectation(description: "S1")
        pub.onFrame = { data in frames.append(data); s1.fulfill() }
        pub.handleArtURL("http://cdn.example/a.jpg")
        wait(for: [s1], timeout: 5)
        XCTAssertEqual(frames.count, 1)

        let s2 = expectation(description: "S2 on toggle-off")
        pub.onFrame = { data in frames.append(data); s2.fulfill() }
        pub.setArtEnabled(false)
        wait(for: [s2], timeout: 5)
        XCTAssertEqual(frames.count, 2)
        XCTAssertNil(decode(frames[1])?.url, "S2 must omit url")
        XCTAssertNotEqual(decode(frames[0])?.gen, decode(frames[1])?.gen, "the clear must carry a fresh gen (D-6)")

        // Then silence: the SAME (still-playing, per Sonos) URL on every subsequent tick must never
        // re-clear. artEnabled=false collapses urlStep's effective URL to nil unconditionally, and the
        // cache is already nil from the clear above, so this never reaches fetchAndRender -- drain() is
        // safe here for the same reason as the gate tests above (no debounce interaction either: the
        // urlStep identity check short-circuits before the debounce check is ever reached).
        var extraFrames = 0
        pub.onFrame = { _ in extraFrames += 1 }
        pub.handleArtURL("http://cdn.example/a.jpg")
        pub.handleArtURL("http://cdn.example/a.jpg")
        drain(pub)
        XCTAssertEqual(extraFrames, 0, "toggled off must go quiet, not re-clear every tick")
    }

    func testToggleOnRepublishesOnNextTick() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        let t = tile()
        fetch.handler = { _, completion in completion(.success(t)) }
        let clock = Clock()
        let pub = makePublisher(server: arm, clock: clock, fetch: fetch.call)
        openGate(pub)

        var frames: [Data] = []
        let s1 = expectation(description: "S1")
        pub.onFrame = { data in frames.append(data); s1.fulfill() }
        pub.handleArtURL("http://cdn.example/a.jpg")
        wait(for: [s1], timeout: 5)

        let s2 = expectation(description: "S2 on toggle-off")
        pub.onFrame = { data in frames.append(data); s2.fulfill() }
        pub.setArtEnabled(false)
        wait(for: [s2], timeout: 5)

        pub.setArtEnabled(true)   // re-enable: nothing forced synchronously (see report, judgment calls)
        clock.advance(3)   // past the 2 s debounce -- production relies on the 5 s poll interval for this
                          // margin; this test makes that assumption explicit rather than racing real time.

        let s1Again = expectation(description: "republished S1 on the next real tick")
        pub.onFrame = { data in frames.append(data); s1Again.fulfill() }
        pub.handleArtURL("http://cdn.example/a.jpg")   // the provider's next poll would report this
        wait(for: [s1Again], timeout: 5)

        XCTAssertEqual(frames.count, 3)
        XCTAssertNotNil(decode(frames[2])?.url, "re-enabling must republish real art, not another clear")
    }

    // MARK: - reconnect: fresh gen, fresh arm, S1 re-pushed (design §5, not optional)

    func testReconnectRepublishesWithFreshGenAndFreshArm() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        let t = tile()
        fetch.handler = { _, completion in completion(.success(t)) }
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)
        openGate(pub)

        var frames: [Data] = []
        let s1 = expectation(description: "initial S1")
        pub.onFrame = { data in frames.append(data); s1.fulfill() }
        pub.handleArtURL("http://cdn.example/a.jpg")
        wait(for: [s1], timeout: 5)
        XCTAssertEqual(arm.calls.count, 1)

        let s1Again = expectation(description: "reconnect S1")
        pub.onFrame = { data in frames.append(data); s1Again.fulfill() }
        pub.noteReconnected()
        wait(for: [s1Again], timeout: 5)

        XCTAssertEqual(arm.calls.count, 2, "reconnect must re-arm, not resend a cached URL")
        XCTAssertEqual(frames.count, 2)
        let firstGen = decode(frames[0])?.gen
        let secondGen = decode(frames[1])?.gen
        XCTAssertNotNil(firstGen); XCTAssertNotNil(secondGen)
        XCTAssertNotEqual(firstGen, secondGen, "reconnect must mint a fresh gen even though the pixels are unchanged")
    }

    // The integration trap this project's brief calls out by name: BLE connects before WiFi joins, so
    // the device's IP is very often unknown at the moment `central.onReady` fires. The reconnect
    // republish must not be lost -- it must wait for an address, however long that takes. This test
    // caught a real bug: tryFlushPendingReconnect was clearing `pendingReconnectRepublish` before
    // confirming a device IP was available, so the republish silently vanished forever the first time
    // this path ran without one. See SonosArtPublisher.tryFlushPendingReconnect's comment.
    func testReconnectDefersUntilDeviceIPArrives() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        let t = tile()
        fetch.handler = { _, completion in completion(.success(t)) }
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)
        openGate(pub)

        let s1 = expectation(description: "initial S1")
        pub.onFrame = { _ in s1.fulfill() }
        pub.handleArtURL("http://cdn.example/a.jpg")
        wait(for: [s1], timeout: 5)
        XCTAssertEqual(arm.calls.count, 1)

        // The device's IP drops out of the picture (a fresh BLE connection whose first report(s) carry
        // no IP at all), THEN it reconnects.
        pub.setDeviceIP(nil)
        pub.noteReconnected()
        drain(pub)   // no fetch is involved in the reconnect path at all -- see noteReconnected's
                     // implementation -- so this has no nested async work to race against.
        XCTAssertEqual(arm.calls.count, 1, "must not arm with no address to advertise to")

        let s1Deferred = expectation(description: "deferred reconnect S1")
        pub.onFrame = { _ in s1Deferred.fulfill() }
        pub.setDeviceIP("192.168.1.55")   // WiFi joins; a later deviceReport carries a real address
        wait(for: [s1Deferred], timeout: 5)
        XCTAssertEqual(arm.calls.count, 2, "the deferred reconnect re-arm must fire once an address is known")
    }

    // MARK: - the no-device-IP-yet state generally (not just via reconnect)

    func testNoArmWithNoDeviceIPYetThenSucceedsOnceIPArrives() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        let t = tile()
        fetch.handler = { _, completion in completion(.success(t)) }
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)
        pub.setSonosPageEnabled(true)
        pub.setLinkUp(true)
        // No setDeviceIP call at all yet -- e.g. BLE just connected, WiFi not yet up.

        pub.handleArtURL("http://cdn.example/a.jpg")

        // The SAME track is still playing once an address shows up -- this also proves the earlier,
        // blocked attempt did not corrupt the cache into thinking it already published (lastImageUrl
        // never got set, since armAndEmit's guard returns before applyArmResult ever runs).
        pub.setDeviceIP("192.168.1.55")
        let s1 = expectation(description: "publishes once an address is known")
        pub.onFrame = { _ in s1.fulfill() }
        pub.handleArtURL("http://cdn.example/a.jpg")
        wait(for: [s1], timeout: 5)
        XCTAssertEqual(arm.calls.count, 1, "exactly one arm -- the pre-IP attempt must never have armed")
    }

    // MARK: - fetch/decode failure: publish S2, not silence (design §6.3/§8)

    func testFetchFailurePublishesS2NotSilence() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        fetch.handler = { _, completion in completion(.failure(.httpStatus(500))) }
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)
        openGate(pub)

        let s2 = expectation(description: "S2 on fetch failure")
        var frame: Data?
        pub.onFrame = { data in frame = data; s2.fulfill() }
        pub.handleArtURL("http://cdn.example/a.jpg")
        wait(for: [s2], timeout: 5)

        XCTAssertNil(decode(frame ?? Data())?.url)
        XCTAssertTrue(arm.calls.isEmpty, "a fetch failure must never reach arm()")
    }

    // MARK: - the expiring-signature case, end to end through the publisher

    func testIdenticalDigestUnderANewURLPublishesNothing() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        let t = tile(stamp: 0xAA, digest: "same-digest")
        fetch.handler = { _, completion in completion(.success(t)) }
        let clock = Clock()
        let pub = makePublisher(server: arm, clock: clock, fetch: fetch.call)
        openGate(pub)

        let s1 = expectation(description: "S1")
        pub.onFrame = { _ in s1.fulfill() }
        pub.handleArtURL("http://cdn.example/signed?exp=1")
        wait(for: [s1], timeout: 5)
        XCTAssertEqual(arm.calls.count, 1)

        // A fresh signed URL for the SAME underlying image (a CDN rotating its signature, not the art).
        // Advance PAST the 2 s debounce first, or this tick would be silently swallowed by the debounce
        // gate before ever reaching fetchAndRender/digestStep -- which would make this assertion pass for
        // the wrong reason (nothing ran) rather than the reason under test (digestStep said doNothing).
        // This DOES trigger a fetch, so an inverted expectation with a real wait is used rather than
        // drain() -- see the file header note on why a bare drain() would not be deterministic here.
        clock.advance(3)
        let noFrame = expectation(description: "no frame for an identical-digest URL")
        noFrame.isInverted = true
        pub.onFrame = { _ in noFrame.fulfill() }
        pub.handleArtURL("http://cdn.example/signed?exp=2")
        wait(for: [noFrame], timeout: 0.5)

        XCTAssertEqual(arm.calls.count, 1, "must not re-arm for identical content")
    }

    // MARK: - sart_stat feeds the Local Network row

    func testSartStatFeedsLocalNetworkOutcome() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)

        let exp = expectation(description: "outcome")
        var outcome: LanServeOutcome?
        pub.onLocalNetworkOutcome = { o in outcome = o; exp.fulfill() }
        pub.handleSartStat(ok: false, err: "conn_refused")
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(outcome, .deviceErr("conn_refused"))
    }

    func testSartStatOKFeedsServed() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)

        let exp = expectation(description: "outcome")
        var outcome: LanServeOutcome?
        pub.onLocalNetworkOutcome = { o in outcome = o; exp.fulfill() }
        pub.handleSartStat(ok: true, err: nil)
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(outcome, .served)
    }

    // MARK: - a url that arrives while a gate is shut (found on hardware 2026-07-28)

    // SonosProvider fires onArtURL only when the url CHANGES, so a url turned away by a shut gate is
    // never re-delivered. Before deferredURL existed it was dropped outright, and the art simply never
    // appeared until the track changed -- on a long track, never. Reopening the gate must publish it.
    func testURLBlockedByAClosedLinkPublishesWhenTheLinkComesUp() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        fetch.handler = { _, completion in completion(.success(self.tile())) }
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)
        pub.setSonosPageEnabled(true)
        pub.setDeviceIP("192.168.1.55")
        pub.setLinkUp(false)

        pub.handleArtURL("http://albumart.example.com/a.jpg")
        drain(pub)
        XCTAssertEqual(fetch.callCount, 0, "a shut link must not spend an HTTPS GET")
        XCTAssertEqual(arm.calls.count, 0)

        let frame = expectation(description: "S1 after the link comes up")
        pub.onFrame = { _ in frame.fulfill() }
        pub.setLinkUp(true)
        wait(for: [frame], timeout: 5)
        XCTAssertEqual(fetch.callCount, 1, "the deferred url must be retried exactly once")
        XCTAssertEqual(arm.calls.count, 1)
    }

    // Same rule for the other gate, so neither one can strand a url on its own.
    func testURLBlockedByAMissingSonosPagePublishesWhenThePageIsAdded() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        fetch.handler = { _, completion in completion(.success(self.tile())) }
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)
        pub.setLinkUp(true)
        pub.setDeviceIP("192.168.1.55")
        pub.setSonosPageEnabled(false)

        pub.handleArtURL("http://albumart.example.com/b.jpg")
        drain(pub)
        XCTAssertEqual(fetch.callCount, 0)

        let frame = expectation(description: "S1 after the page is added")
        pub.onFrame = { _ in frame.fulfill() }
        pub.setSonosPageEnabled(true)
        wait(for: [frame], timeout: 5)
        XCTAssertEqual(fetch.callCount, 1)
    }

    // Reopening ONE gate while the other is still shut must not fetch -- it re-defers instead, so the
    // retry cannot burn a request that still has nowhere to go.
    func testReopeningOneGateWhileTheOtherIsShutStillDefers() {
        let arm = ArmSpy()
        let fetch = FetchSpy()
        fetch.handler = { _, completion in completion(.success(self.tile())) }
        let pub = makePublisher(server: arm, clock: Clock(), fetch: fetch.call)
        pub.setDeviceIP("192.168.1.55")
        pub.setLinkUp(false)
        pub.setSonosPageEnabled(false)

        pub.handleArtURL("http://albumart.example.com/c.jpg")
        drain(pub)
        pub.setLinkUp(true)          // page still disabled
        drain(pub)
        XCTAssertEqual(fetch.callCount, 0, "one open gate is not enough")

        let frame = expectation(description: "S1 once both gates are open")
        pub.onFrame = { _ in frame.fulfill() }
        pub.setSonosPageEnabled(true)
        wait(for: [frame], timeout: 5)
        XCTAssertEqual(fetch.callCount, 1)
    }
}
