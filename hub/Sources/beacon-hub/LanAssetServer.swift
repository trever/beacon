import Foundation
import Network
import Security

// The general-purpose LAN byte-serving component (design 2026-07-27-sonos-album-art-design.md §1.5/§7,
// plan 2026-07-27-sonos-album-art-plan.md §4 WS-1). Two callers: Sonos album art (the first, this repo)
// and a firmware OTA image transfer (planned, not built yet). Both need the exact same shape -- hand it
// a `Data`, get back a single-use `http://` URL on the hub's LAN, and the device fetches once. The server
// must never learn what a pixel or a firmware image is: no `80_000`, no `Tile`, no `firmware`, no `ota`
// anywhere below, and the `contentType` it serves is whatever the caller supplies.
//
// Security model, all of it in one place because there is exactly one handler:
//   - GET only, one route shape (`/a/<32-hex>`); anything else is a 404 with the connection closed.
//   - Ephemeral port, armed only for the transfer -- never at rest.
//   - 128-bit single-use path token, compared in constant time.
//   - Source-address restriction: only the caller-supplied `peer`, and only if `peer` itself is
//     RFC1918/link-local/loopback -- both checked before a byte is read off the connection.
//   - `maxServes` and `ttl` are caller arguments, not constants here.
//   - No sleep assertion of any kind. This file has no import and no symbol reference reaching the
//     sibling power-assertion seam anywhere in the codebase -- that absence is a compile-time fact, not
//     a runtime one, and it is what the behavioural test in LanAssetServerTests relies on (design §7.2).
//   - Logs an id and an outcome only. Never the token, never the URL, never the payload.
final class LanAssetServer {
    enum ArmError: Error, Equatable {
        case listenerFailed(String)
        case noRoutableInterface
        case alreadyArmed
    }

    // One call per completed/failed serve, for the caller's telemetry. Not called for a rejected
    // connection (wrong token, wrong method, wrong path, wrong peer) -- those never reach a serve.
    var onServed: ((Bool) -> Void)?

    // --- test seams (internal, not part of arm()/disarm()'s public contract; WS-4 must not depend on
    //     these -- they exist only so LanAssetServerTests can be deterministic and fast) ---

    // Resolves which of the hub's own addresses to advertise for a given peer. Defaults to the real
    // getifaddrs-backed resolver; tests substitute a stub to prove `.noRoutableInterface` without
    // depending on which interfaces happen to exist on the machine running the suite.
    var advertiseAddressResolver: (IPv4Address) -> String? = LanInterface.selectAdvertiseAddress

    // Fires `work` after `delay` on `queue`. Defaults to a real `DispatchQueue.asyncAfter`. Tests
    // substitute a stub that posts `work` onto `queue` immediately, faking "the TTL elapsed" without any
    // real wall-clock wait -- see LanAssetServerTests for the full rationale (D-5's sibling problem: TTL
    // expiry needs to be provably tested, not just asserted to eventually happen).
    var ttlScheduler: (TimeInterval, DispatchQueue, @escaping () -> Void) -> Void = { delay, queue, work in
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // Fires once after the current arm window's listener/token/payload are torn down, for whatever
    // reason (serve exhaustion, TTL, explicit disarm, listener failure). Gives tests a deterministic
    // barrier to wait on before asserting the port is closed, instead of racing an async teardown.
    var onTornDown: (() -> Void)?

    // --- state, confined entirely to `queue` ---

    private let queue = DispatchQueue(label: "beacon.lanasset")
    private var listener: NWListener?
    private var gen: UInt64 = 0
    private var tokenBytes: [UInt8] = []
    private var payload: Data?
    private var contentType: String = ""
    private var peer: IPv4Address?
    private var remainingServes: Int = 0

    func arm(
        _ data: Data, contentType: String, peer: IPv4Address,
        ttl: TimeInterval, maxServes: Int,
        completion: @escaping (Result<URL, ArmError>) -> Void
    ) {
        queue.async { [weak self] in
            self?.armOnQueue(data, contentType: contentType, peer: peer, ttl: ttl, maxServes: maxServes, completion: completion)
        }
    }

    func disarm() {
        queue.async { [weak self] in self?.disarmOnQueue() }
    }

    // MARK: - arm

    private func armOnQueue(
        _ data: Data, contentType: String, peer: IPv4Address,
        ttl: TimeInterval, maxServes: Int,
        completion: @escaping (Result<URL, ArmError>) -> Void
    ) {
        guard listener == nil else {
            completion(.failure(.alreadyArmed))
            return
        }
        guard let advertiseAddress = advertiseAddressResolver(peer) else {
            completion(.failure(.noRoutableInterface))
            return
        }

        let myGen = gen &+ 1
        let newToken = Self.generateToken()
        let l: NWListener
        do {
            // Ephemeral port on all interfaces -- no `requiredLocalEndpoint`, no `allowLocalEndpointReuse`
            // (that flag is for LocalIngestServer's fixed-port rebind; an ephemeral listener never needs it).
            l = try NWListener(using: .tcp)
        } catch {
            completion(.failure(.listenerFailed(error.localizedDescription)))
            return
        }

        gen = myGen
        self.payload = data
        self.contentType = contentType
        self.peer = peer
        self.remainingServes = maxServes
        self.tokenBytes = newToken
        self.listener = l

        var completionCalled = false
        func complete(_ result: Result<URL, ArmError>) {
            guard !completionCalled else { return }
            completionCalled = true
            completion(result)
        }

        l.newConnectionHandler = { [weak self] conn in self?.accept(conn, gen: myGen) }
        l.stateUpdateHandler = { [weak self] state in
            guard let self, self.gen == myGen else { return }
            switch state {
            case .ready:
                guard let port = l.port?.rawValue else {
                    complete(.failure(.listenerFailed("listener reached .ready with no assigned port")))
                    self.teardownIfCurrent(gen: myGen)
                    return
                }
                let hex = Self.hex(newToken)
                guard let url = URL(string: "http://\(advertiseAddress):\(port)/a/\(hex)") else {
                    complete(.failure(.listenerFailed("could not construct URL")))
                    self.teardownIfCurrent(gen: myGen)
                    return
                }
                self.scheduleTTL(ttl, gen: myGen)
                complete(.success(url))
            case .failed(let error):
                complete(.failure(.listenerFailed(error.localizedDescription)))
                self.teardownIfCurrent(gen: myGen)
            default:
                break
            }
        }
        l.start(queue: queue)
    }

    private func scheduleTTL(_ ttl: TimeInterval, gen: UInt64) {
        ttlScheduler(ttl, queue) { [weak self] in
            guard let self, self.gen == gen else { return }
            self.teardownIfCurrent(gen: gen)
        }
    }

    // MARK: - teardown

    private func teardownIfCurrent(gen expectedGen: UInt64) {
        guard gen == expectedGen else { return }
        disarmOnQueue()
    }

    private func disarmOnQueue() {
        gen &+= 1
        listener?.cancel()
        listener = nil
        payload = nil
        contentType = ""
        tokenBytes = []
        peer = nil
        remainingServes = 0
        onTornDown?()
    }

    // MARK: - connection handling

    private func accept(_ conn: NWConnection, gen expectedGen: UInt64) {
        guard gen == expectedGen else { conn.cancel(); return }
        guard remainingServes > 0 else { conn.cancel(); return }
        // Source-address restriction, checked before a single byte is read: the remote must be exactly
        // the reported device peer, and that peer must itself be non-WAN-routable. Loopback is included
        // in the private set deliberately -- it is what makes `peer: IPv4Address("127.0.0.1")` a valid,
        // fully-exercised test configuration rather than a special case the tests have to route around.
        guard let remote = Self.remoteIPv4(of: conn), let peer, remote == peer, Self.isNonWANRoutable(remote) else {
            conn.cancel()
            return
        }
        conn.start(queue: queue)
        readRequest(conn, buffer: Data(), gen: expectedGen)
    }

    private func readRequest(_ conn: NWConnection, buffer: Data, gen expectedGen: UInt64) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, self.gen == expectedGen else { conn.cancel(); return }
            if error != nil { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = Self.range(of: Data("\r\n\r\n".utf8), in: buf) {
                let head = buf.subdata(in: buf.startIndex..<range.lowerBound)
                self.handleRequest(head, conn: conn, gen: expectedGen)
                return
            }
            if isComplete || buf.count > 8 * 1024 { conn.cancel(); return }
            self.readRequest(conn, buffer: buf, gen: expectedGen)
        }
    }

    private func handleRequest(_ head: Data, conn: NWConnection, gen expectedGen: UInt64) {
        guard gen == expectedGen else { conn.cancel(); return }
        let (method, target) = Self.parseRequestLine(head)

        // GET only, one exact route shape: "/a/" + exactly 32 lowercase hex chars, nothing after --
        // no query string, no trailing slash, no path traversal. The "/a/" prefix is public route
        // shape, not secret, so a plain prefix compare is fine; the 32-char suffix is the actual
        // capability and is never compared with `==`.
        guard method == "GET", target.hasPrefix("/a/") else { respond404(conn); return }
        let suffix = String(target.dropFirst(3))
        guard target.utf8.count == 3 + 32, let suffixBytes = Self.hexBytes(suffix) else { respond404(conn); return }
        guard Self.constantTimeEqual(suffixBytes, tokenBytes) else { respond404(conn); return }
        guard remainingServes > 0 else { respond404(conn); return }

        remainingServes -= 1
        let exhausted = remainingServes <= 0
        respondPayload(conn)
        if exhausted { teardownIfCurrent(gen: expectedGen) }
    }

    // MARK: - raw HTTP write

    private func respond404(_ conn: NWConnection) {
        let head = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    // Sends the header and the payload as two separate writes rather than one concatenated buffer, so a
    // large (OTA-scale) payload is never copied into a second allocation just to prefix it with a header.
    private func respondPayload(_ conn: NWConnection) {
        guard let payload else { respond404(conn); return }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                conn.cancel()
                self?.onServed?(false)
                return
            }
            conn.send(content: payload, completion: .contentProcessed { error in
                conn.cancel()
                self?.onServed?(error == nil)
            })
        })
    }

    private static func parseRequestLine(_ head: Data) -> (method: String, target: String) {
        guard let text = String(data: head, encoding: .utf8) else { return ("", "") }
        guard let firstLine = text.components(separatedBy: "\r\n").first else { return ("", "") }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return ("", "") }
        return (String(parts[0]), String(parts[1]))
    }

    private static func range(of needle: Data, in haystack: Data) -> Range<Data.Index>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        return haystack.range(of: needle)
    }

    // MARK: - token

    private static func generateToken() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // The system CSPRNG failing has no sane fallback for a security token; surface it loudly in
            // debug rather than silently arming with a weak/all-zero one.
            assertionFailure("SecRandomCopyBytes failed with status \(status)")
        }
        return bytes
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // Strict lowercase-hex only, matching exactly what `hex(_:)` produces -- anything else (including a
    // syntactically-valid uppercase hex string) is rejected rather than normalized.
    private static func hexBytes(_ text: String) -> [UInt8]? {
        guard text.utf8.count == 32 else { return nil }
        guard text.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var idx = text.startIndex
        while idx < text.endIndex {
            let next = text.index(idx, offsetBy: 2)
            guard let byte = UInt8(text[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        return bytes
    }

    // Fixed-length XOR-accumulate over both byte arrays, not `==` and not `hasPrefix` -- a short-
    // circuiting compare would leak timing information about how many leading bytes matched.
    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    // MARK: - peer / address

    private static func remoteIPv4(of conn: NWConnection) -> IPv4Address? {
        guard case let .hostPort(host, _) = conn.endpoint, case let .ipv4(addr) = host else { return nil }
        return addr
    }

    // RFC1918 + link-local + loopback. Loopback is included deliberately -- see the comment at its call
    // site in `accept(_:gen:)`.
    private static func isNonWANRoutable(_ address: IPv4Address) -> Bool {
        let b = [UInt8](address.rawValue)
        guard b.count == 4 else { return false }
        if b[0] == 10 { return true }
        if b[0] == 172, (16...31).contains(b[1]) { return true }
        if b[0] == 192, b[1] == 168 { return true }
        if b[0] == 169, b[1] == 254 { return true }
        if b[0] == 127 { return true }
        return false
    }
}
