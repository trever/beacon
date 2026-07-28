import XCTest
import Network
@testable import beacon_hub

// LanInterface's decision core -- "does this candidate interface's network contain the device's IP" --
// is pure over three dotted-quad strings (plan 2026-07-27-sonos-album-art-plan.md §4 WS-1's required
// coverage list). These tests exercise exactly that pure function against synthetic interface tables
// shaped like a real multi-homed Mac (Wi-Fi + Ethernet + a VPN utun + a Thunderbolt bridge), never the
// real `getifaddrs` walk -- so they are deterministic regardless of which interfaces exist on the
// machine running the suite.
final class LanInterfaceTests: XCTestCase {

    func testMatchesWithinSameSlash24() {
        let candidates = [LanInterface.Candidate(address: "192.168.1.5", netmask: "255.255.255.0")]
        XCTAssertEqual(LanInterface.match(candidates: candidates, deviceIP: "192.168.1.42"), "192.168.1.5")
    }

    func test10DotDoesNotMatchA192168Device() {
        let candidates = [LanInterface.Candidate(address: "10.0.0.5", netmask: "255.0.0.0")]
        XCTAssertNil(LanInterface.match(candidates: candidates, deviceIP: "192.168.1.42"))
    }

    func testOnlyOneOfTwoCandidatesContainsTheDevice() {
        // Shaped like a real machine: en0 Wi-Fi is the device's actual network; a VPN utun with a
        // /32 point-to-point address is present but irrelevant to this device.
        let candidates = [
            LanInterface.Candidate(address: "100.64.0.3", netmask: "255.255.255.255"),   // utun, /32
            LanInterface.Candidate(address: "192.168.1.5", netmask: "255.255.255.0"),    // en0 Wi-Fi
        ]
        XCTAssertEqual(LanInterface.match(candidates: candidates, deviceIP: "192.168.1.42"), "192.168.1.5")
    }

    func testFirstMatchWinsWhenOrderReversed() {
        let candidates = [
            LanInterface.Candidate(address: "192.168.1.5", netmask: "255.255.255.0"),    // en0 Wi-Fi
            LanInterface.Candidate(address: "100.64.0.3", netmask: "255.255.255.255"),   // utun, /32
        ]
        XCTAssertEqual(LanInterface.match(candidates: candidates, deviceIP: "192.168.1.42"), "192.168.1.5")
    }

    func testZeroMatchesReturnsNilNeverAGuess() {
        // Wi-Fi, Ethernet, VPN utun, and a Thunderbolt bridge, none of which contain the device.
        let candidates = [
            LanInterface.Candidate(address: "192.168.1.5", netmask: "255.255.255.0"),
            LanInterface.Candidate(address: "192.168.50.9", netmask: "255.255.255.0"),
            LanInterface.Candidate(address: "100.64.0.3", netmask: "255.255.255.255"),
            LanInterface.Candidate(address: "169.254.10.1", netmask: "255.255.0.0"),
        ]
        XCTAssertNil(LanInterface.match(candidates: candidates, deviceIP: "10.20.30.40"))
    }

    func testEmptyCandidateListReturnsNil() {
        XCTAssertNil(LanInterface.match(candidates: [], deviceIP: "192.168.1.42"))
    }

    func testMalformedCandidateIsSkippedNotFatal() {
        let candidates = [
            LanInterface.Candidate(address: "not-an-ip", netmask: "255.255.255.0"),
            LanInterface.Candidate(address: "192.168.1.5", netmask: "255.255.255.0"),
        ]
        XCTAssertEqual(LanInterface.match(candidates: candidates, deviceIP: "192.168.1.42"), "192.168.1.5")
    }

    func testMalformedDeviceIPReturnsNil() {
        let candidates = [LanInterface.Candidate(address: "192.168.1.5", netmask: "255.255.255.0")]
        XCTAssertNil(LanInterface.match(candidates: candidates, deviceIP: "not-an-ip"))
    }

    func testIpv4ToUInt32RoundTripsOrdering() {
        // 192.168.1.42 -> 0xC0A8012A, most-significant octet first.
        XCTAssertEqual(LanInterface.ipv4ToUInt32("192.168.1.42"), 0xC0A8_012A)
        XCTAssertEqual(LanInterface.ipv4ToUInt32("0.0.0.0"), 0)
        XCTAssertEqual(LanInterface.ipv4ToUInt32("255.255.255.255"), 0xFFFF_FFFF)
    }

    func testIpv4ToUInt32RejectsOutOfRangeOctet() {
        XCTAssertNil(LanInterface.ipv4ToUInt32("192.168.1.256"))
        XCTAssertNil(LanInterface.ipv4ToUInt32("192.168.1"))
        XCTAssertNil(LanInterface.ipv4ToUInt32("192.168.1.1.1"))
    }

    func testStringFromIPv4AddressMatchesDottedReadingOrder() {
        let addr = IPv4Address("203.0.113.7")!
        XCTAssertEqual(LanInterface.string(from: addr), "203.0.113.7")
    }

    // The impure half: not mockable without a real multi-homed rig, but it must at least run without
    // crashing and return loopback among a real Mac's live interfaces (lo0 is always present and up).
    func testLiveIPv4CandidatesIncludesLoopbackOnAnyMac() {
        let live = LanInterface.liveIPv4Candidates()
        XCTAssertTrue(live.contains { $0.address == "127.0.0.1" })
    }
}
