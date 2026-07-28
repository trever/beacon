import XCTest
import Network
@testable import beacon_hub

// LanAssetServer is the shared LAN byte-serving component album art and (later) OTA both build on
// (plan 2026-07-27-sonos-album-art-plan.md §4 WS-1). These tests drive a genuine loopback `URLSession`
// GET against a really-armed `NWListener`, as the plan requires -- not a mocked handler -- because the
// thing under test is an HTTP parser and a constant-time token compare, and both are exactly the kind of
// code a mock would paper over.
//
// Two internal seams make the timing-sensitive cases deterministic without a real wall-clock wait:
//   - `ttlScheduler` lets a test fake "the TTL elapsed" by posting the expiry work immediately.
//   - `onTornDown` gives a test an explicit barrier to wait on before asserting the port is closed,
//     instead of racing disarm()'s async teardown against a subsequent connection attempt.
// Neither is part of arm()/disarm()'s public contract -- see LanAssetServer.swift's doc comments.
final class LanAssetServerTests: XCTestCase {

    private let loopbackPeer = IPv4Address("127.0.0.1")!

    // MARK: - helpers

    @discardableResult
    private func arm(
        _ server: LanAssetServer, data: Data, contentType: String = "application/octet-stream",
        peer: IPv4Address? = nil, ttl: TimeInterval = 30, maxServes: Int = 1
    ) -> Result<URL, LanAssetServer.ArmError> {
        let exp = expectation(description: "armed")
        var outcome: Result<URL, LanAssetServer.ArmError>!
        server.arm(data, contentType: contentType, peer: peer ?? loopbackPeer, ttl: ttl, maxServes: maxServes) { result in
            outcome = result
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        return outcome
    }

    private func requireURL(_ result: Result<URL, LanAssetServer.ArmError>, file: StaticString = #filePath, line: UInt = #line) -> URL {
        guard case .success(let url) = result else {
            XCTFail("expected a successful arm, got \(result)", file: file, line: line)
            return URL(string: "http://127.0.0.1/unreachable")!
        }
        return url
    }

    private struct HTTPResult {
        let status: Int
        let response: HTTPURLResponse
        let body: Data
        func header(_ name: String) -> String? { response.value(forHTTPHeaderField: name) }
    }

    private func get(_ url: URL, method: String = "GET") -> HTTPResult? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        let exp = expectation(description: "http")
        var out: HTTPResult?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                out = HTTPResult(status: http.statusCode, response: http, body: data ?? Data())
            }
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 5)
        return out
    }

    // A connection attempt to a closed/never-armed port must fail at the transport level (no listener),
    // not resolve to any HTTP response at all.
    private func expectConnectionRefused(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        let exp = expectation(description: "refused")
        var sawError = false
        URLSession.shared.dataTask(with: url) { _, response, error in
            sawError = (error != nil) || (response == nil)
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(sawError, "expected the connection to fail once the listener is torn down", file: file, line: line)
    }

    private func waitForTeardown(_ server: LanAssetServer, do action: () -> Void) {
        let exp = expectation(description: "torn down")
        server.onTornDown = { exp.fulfill() }
        action()
        wait(for: [exp], timeout: 5)
    }

    // MARK: - route shape / token

    // Judgment call, recorded here because it decides what this test asserts: the plan's required-
    // coverage list says "the second request 404s (maxServes: 1)", but plan §4 WS-1 rule 7 says disarm()
    // -- full teardown, "the listener is gone and the token is dead" -- fires "on: first successful
    // serve reaching maxServes". Those two are mutually exclusive at the socket level: a listener that
    // is fully gone cannot also hand back an HTTP 404, only a connection failure. Rule 7 is the more
    // precise, explicitly-reasoned acceptance item (least exposure window, matches "armed only for the
    // transfer, never at rest"), so this implementation tears the listener down synchronously the
    // instant maxServes is reached, and this test asserts the resulting connection-refused rather than
    // a 404 body. See the workstream report for the full note.
    func testCorrectTokenServesOnceThenSecondRequestIsRefused() {
        let server = LanAssetServer()
        let payload = Data("hello lan".utf8)
        let url = requireURL(arm(server, data: payload, maxServes: 1))

        let tornDown = expectation(description: "torn down after exhausting maxServes")
        server.onTornDown = { tornDown.fulfill() }

        let first = get(url)
        XCTAssertEqual(first?.status, 200)
        XCTAssertEqual(first?.body, payload)

        wait(for: [tornDown], timeout: 5)
        expectConnectionRefused(url)
    }

    func testWrongTokenReturns404() {
        let server = LanAssetServer()
        let url = requireURL(arm(server, data: Data("x".utf8), maxServes: 1))
        let wrongPath = url.deletingLastPathComponent().appendingPathComponent(String(repeating: "0", count: 32))
        let result = get(wrongPath)
        XCTAssertEqual(result?.status, 404)
    }

    func testTokenDifferingInLastCharacterReturns404() {
        let server = LanAssetServer()
        let url = requireURL(arm(server, data: Data("x".utf8), maxServes: 1))
        var s = url.absoluteString
        let last = s.removeLast()
        let replacement: Character = last == "0" ? "1" : "0"
        let tampered = URL(string: s + String(replacement))!

        let result = get(tampered)
        XCTAssertEqual(result?.status, 404)
    }

    func testPostToCorrectPathReturns404() {
        let server = LanAssetServer()
        let url = requireURL(arm(server, data: Data("x".utf8), maxServes: 1))
        let result = get(url, method: "POST")
        XCTAssertEqual(result?.status, 404)
    }

    func testPathWithQueryStringReturns404() {
        let server = LanAssetServer()
        let url = requireURL(arm(server, data: Data("x".utf8), maxServes: 1))
        let queried = URL(string: url.absoluteString + "?x=1")!
        let result = get(queried)
        XCTAssertEqual(result?.status, 404)
    }

    // MARK: - lifecycle

    func testAfterDisarmPortIsClosed() {
        let server = LanAssetServer()
        let url = requireURL(arm(server, data: Data("x".utf8), maxServes: 1))
        waitForTeardown(server) { server.disarm() }
        expectConnectionRefused(url)
    }

    func testTTLExpiryDisarmsWithoutServe() {
        let server = LanAssetServer()
        // Fake "time elapsed" instantly: post the expiry work onto `queue` right away instead of really
        // waiting out `ttl`. The real production scheduler (DispatchQueue.asyncAfter) is never exercised
        // here -- that path is a one-line default and not itself timing-sensitive to test.
        server.ttlScheduler = { _, queue, work in queue.async(execute: work) }

        let exp = expectation(description: "armed")
        var captured: URL?
        server.arm(Data("x".utf8), contentType: "application/octet-stream", peer: loopbackPeer, ttl: 30, maxServes: 1) { result in
            if case .success(let url) = result { captured = url }
            exp.fulfill()
        }
        let tornDown = expectation(description: "torn down by ttl")
        server.onTornDown = { tornDown.fulfill() }
        wait(for: [exp, tornDown], timeout: 5)

        guard let url = captured else { return XCTFail("expected a successful arm") }
        expectConnectionRefused(url)
    }

    func testAlreadyArmedRejectsSecondArmWhileActive() {
        let server = LanAssetServer()
        _ = requireURL(arm(server, data: Data("x".utf8), maxServes: 1))
        let second = arm(server, data: Data("y".utf8), maxServes: 1)
        XCTAssertEqual(second, .failure(.alreadyArmed))
    }

    func testNoRoutableInterfaceNeverGuesses() {
        let server = LanAssetServer()
        server.advertiseAddressResolver = { _ in nil }
        let result = arm(server, data: Data("x".utf8), maxServes: 1)
        XCTAssertEqual(result, .failure(.noRoutableInterface))
    }

    // MARK: - generality (this workstream's headline deliverable)

    func testGeneralityRoundTripsSmallImageAndLargeOctetStreamThroughTheSameArm() {
        let jpeg = Data((0..<2_048).map { UInt8($0 % 256) })
        let firmware = Data((0..<1_800_000).map { UInt8(truncatingIfNeeded: $0) })

        let jpegServer = LanAssetServer()
        let jpegURL = requireURL(arm(jpegServer, data: jpeg, contentType: "image/jpeg", ttl: 600, maxServes: 3))
        let jpegResult = get(jpegURL)
        XCTAssertEqual(jpegResult?.status, 200)
        XCTAssertEqual(jpegResult?.body, jpeg)
        XCTAssertEqual(jpegResult?.header("Content-Type"), "image/jpeg")

        let firmwareServer = LanAssetServer()
        let firmwareURL = requireURL(arm(firmwareServer, data: firmware, contentType: "application/octet-stream", ttl: 600, maxServes: 3))
        let firmwareResult = get(firmwareURL)
        XCTAssertEqual(firmwareResult?.status, 200)
        XCTAssertEqual(firmwareResult?.body, firmware)
        XCTAssertEqual(firmwareResult?.header("Content-Type"), "application/octet-stream")

        // maxServes: 3 -- two more correct-token serves must still succeed, then the budget is exhausted
        // and the listener tears down (rule 7; see the note on testCorrectTokenServesOnceThenSecondRequestIsRefused).
        let second = get(firmwareURL)
        XCTAssertEqual(second?.status, 200)

        let tornDown = expectation(description: "torn down after exhausting maxServes: 3")
        firmwareServer.onTornDown = { tornDown.fulfill() }
        let third = get(firmwareURL)
        XCTAssertEqual(third?.status, 200)
        wait(for: [tornDown], timeout: 5)

        expectConnectionRefused(firmwareURL)
    }

    // MARK: - D-5: the divergence that would otherwise ship as a bug

    func testArtSizedArmTakesNoSleepAssertion() {
        let spy = PowerAssertionSpy()
        let previous = PowerAssertions.shared
        PowerAssertions.shared = spy
        defer { PowerAssertions.shared = previous }

        let server = LanAssetServer()
        let payload = Data((0..<80_000).map { UInt8(truncatingIfNeeded: $0) })
        let url = requireURL(arm(server, data: payload, ttl: 30, maxServes: 1))
        let result = get(url)
        XCTAssertEqual(result?.status, 200)
        waitForTeardown(server) { server.disarm() }

        XCTAssertEqual(spy.beginCount, 0, "the LAN asset path must never take an idle-sleep assertion (design §7.2)")
    }
}

// A spy PowerAsserting that only counts -- it never actually calls ProcessInfo, so running this suite
// cannot itself affect the test machine's sleep behaviour regardless of what it is asserting about.
private final class PowerAssertionSpy: PowerAsserting {
    private(set) var beginCount = 0
    func begin(_ reason: String) -> UUID {
        beginCount += 1
        return UUID()
    }
    func end(_ token: UUID) {}
}
