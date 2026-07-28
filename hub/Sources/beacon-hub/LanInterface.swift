import Foundation
import Network

// Picks which of the hub Mac's own IPv4 addresses to embed in a LanAssetServer URL, so a device on
// 192.168.1.x is handed a hub address on 192.168.1.x, not the hub's Ethernet, VPN utun, or Thunderbolt
// bridge address (plan 2026-07-27-sonos-album-art-plan.md §4 WS-1). A Mac routinely carries several live
// IPv4 interfaces at once (Wi-Fi, Ethernet, a VPN's utun, a Thunderbolt bridge, plus loopback); picking
// the wrong one hands the device a URL it cannot reach.
//
// The decision itself -- "does this candidate's network contain the device's IP" -- is a pure function
// over three dotted-quad strings and is fully host-testable without a real network stack. Only the
// enumeration of the Mac's live interfaces (`getifaddrs`) is impure; keep it that way so the interesting
// logic never needs a multi-homed test rig.
enum LanInterface {
    // One of the hub's own live IPv4 interfaces: its address and netmask, both dotted-quad.
    struct Candidate: Equatable {
        let address: String
        let netmask: String
    }

    // Impure: walks the Mac's live interfaces via getifaddrs and picks the one whose network contains
    // `peer` (the device's reported IP). Returns nil when none does -- callers must treat that as
    // `.noRoutableInterface`, never fall back to a guess.
    static func selectAdvertiseAddress(forPeer peer: IPv4Address) -> String? {
        match(candidates: liveIPv4Candidates(), deviceIP: string(from: peer))
    }

    // Pure. First candidate whose (address & netmask) equals (deviceIP & netmask) wins; no match is a
    // caller-visible nil, never a guess. Malformed dotted-quads in a candidate are skipped, not fatal --
    // a single unparsable interface must not take down interface selection for every other interface.
    static func match(candidates: [Candidate], deviceIP: String) -> String? {
        guard let device = ipv4ToUInt32(deviceIP) else { return nil }
        for candidate in candidates {
            guard let addr = ipv4ToUInt32(candidate.address), let mask = ipv4ToUInt32(candidate.netmask) else { continue }
            if (addr & mask) == (device & mask) { return candidate.address }
        }
        return nil
    }

    // Pure. "192.168.1.42" -> 0xC0A8012A (most-significant octet first, i.e. conventional reading
    // order), or nil for anything that is not exactly four dot-separated 0-255 integers.
    static func ipv4ToUInt32(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    // Pure. The `IPv4Address` -> dotted-quad conversion used to feed `match`'s string-typed API from a
    // real `Network.IPv4Address`. `rawValue` is documented as four bytes in network byte order, which is
    // the same order as conventional dotted-quad reading order.
    static func string(from address: IPv4Address) -> String {
        [UInt8](address.rawValue).map(String.init).joined(separator: ".")
    }

    // Impure: the only part of this file that touches the live network configuration. Deliberately does
    // NOT exclude loopback -- a loopback peer's network (127.0.0.0/8) legitimately matches lo0's own
    // 127.0.0.1/8, which is exactly what lets LanAssetServerTests arm against a peer of 127.0.0.1 and get
    // back a usable http://127.0.0.1:<port>/... URL. On a real device peer (e.g. 192.168.1.55), lo0
    // simply never matches -- the subnet arithmetic excludes it without any special-casing.
    static func liveIPv4Candidates() -> [Candidate] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [Candidate] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            guard Int32(ifa.ifa_flags) & IFF_UP != 0 else { continue }
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            guard let maskSA = ifa.ifa_netmask, maskSA.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let mask = maskSA.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            result.append(Candidate(address: dottedString(fromNetworkOrder: addr), netmask: dottedString(fromNetworkOrder: mask)))
        }
        return result
    }

    // `in_addr.s_addr` is populated by the kernel as raw network-order bytes; reading it byte-wise (not
    // as a numeric value to bit-shift) is what makes this correct on both little- and big-endian hosts --
    // the same reason `inet_ntoa`/`inet_ntop` need no explicit byte-order handling either.
    private static func dottedString(fromNetworkOrder value: in_addr_t) -> String {
        var v = value
        return withUnsafeBytes(of: &v) { buf in
            buf.map { String($0) }.joined(separator: ".")
        }
    }
}
