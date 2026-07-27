import Foundation
import Network
import BeaconHubKit

// One-shot localhost HTTP listener for the Sonos OAuth redirect (design 2026-07-26-sonos-now-playing-plan,
// RFC 8252 §7.3 loopback-redirect pattern -- the right shape for a menubar app with no custom URL scheme
// registered). The browser hits http://localhost:<fixed port>/callback?code=...&state=..., we grab the
// query string, answer with a "you can close this" page, and shut the listener down. Fixed (not
// ephemeral) port so the exact redirect URI can be registered once in the Sonos developer console -- see
// SonosOAuth.redirectURI. Deliberately its own tiny listener, not a route on LocalIngestServer: it needs
// GET + query-string parsing (the ingest server only ever does POST + JSON bodies) and it lives for one
// request during a manual `sonos-authorize` run, not for the app's lifetime.
//
// Binding: "localhost" resolves to BOTH ::1 and 127.0.0.1 on macOS, and browsers commonly race IPv6
// first. Pinning `requiredLocalEndpoint` to 127.0.0.1 (the old code) binds ONLY the IPv4 loopback --
// an IPv6-first browser then hits a closed port on ::1 and the flow hangs silently until the timeout.
// Empirically verified (throwaway harness, since Network.framework's actual behavior here is not
// obvious from the docs): a single NWListener created via `NWListener(using:on:)` with
// `requiredInterfaceType = .loopback` and NO `requiredLocalEndpoint` pin accepts both a 127.0.0.1 and a
// ::1 connection on the same fixed port, while a connection attempt from a real LAN address on this
// machine gets an immediate kernel-level "connection refused" (i.e. nothing is bound on that interface
// at all -- this is not an application-level filter on an otherwise-open wildcard bind).
final class SonosLoopbackServer {
    static let port: UInt16 = 53912
    static let callbackPath = "/callback"

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "beacon.sonos-oauth")
    private var completion: ((Result<(code: String, state: String), SonosAuthError>) -> Void)?
    private var timeoutWork: DispatchWorkItem?

    // Starts listening and returns immediately; `completion` fires exactly once -- with the parsed
    // code+state, or an error (bind failure, timeout, malformed callback). Safe to call from a bare CLI
    // process with no NSApplication/run loop consumer beyond GCD.
    func start(timeout: TimeInterval = 180,
              completion: @escaping (Result<(code: String, state: String), SonosAuthError>) -> Void) {
        self.completion = completion
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // requiredInterfaceType = .loopback (not a requiredLocalEndpoint pinned to 127.0.0.1) is what
        // makes this accept connections on both 127.0.0.1 and ::1 -- see the empirical note above.
        params.requiredInterfaceType = .loopback
        guard let port = NWEndpoint.Port(rawValue: Self.port), let l = try? NWListener(using: params, on: port) else {
            finish(.failure(.loopbackBindFailed))
            return
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(.failure(.loopbackBindFailed)) }
        }
        listener = l
        l.start(queue: queue)
        let work = DispatchWorkItem { [weak self] in self?.finish(.failure(.timedOut)) }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            guard let text = String(data: buf, encoding: .utf8),
                  let lineEnd = text.range(of: "\r\n")
            else {
                if isComplete || buf.count > 8192 { conn.cancel() } else { self.readRequest(conn, buffer: buf) }
                return
            }
            let requestLine = String(text[text.startIndex..<lineEnd.lowerBound])
            self.respond(conn)
            self.handle(requestLine: requestLine)
        }
    }

    private func handle(requestLine: String) {
        // "GET /callback?code=...&state=... HTTP/1.1"
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", String(parts[1]).hasPrefix(Self.callbackPath) else { return }
        guard let (code, state) = Self.parseQuery(String(parts[1])) else {
            finish(.failure(.malformedCallback))
            return
        }
        finish(.success((code: code, state: state)))
    }

    // Parses "/callback?code=X&state=Y" (order-independent, tolerates extra params such as a Sonos
    // householdId). Pure + internal so it is testable without a real socket -- see SonosAuthorizerTests.
    static func parseQuery(_ target: String) -> (code: String, state: String)? {
        guard let qIndex = target.firstIndex(of: "?") else { return nil }
        var values: [String: String] = [:]
        for pair in target[target.index(after: qIndex)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            values[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
        }
        guard let code = values["code"], let state = values["state"], !code.isEmpty, !state.isEmpty else { return nil }
        return (code, state)
    }

    private func respond(_ conn: NWConnection) {
        let body = "<html><body>Beacon Hub: Sonos connected. You can close this window.</body></html>"
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(Data(body.utf8))
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func finish(_ result: Result<(code: String, state: String), SonosAuthError>) {
        guard let completion else { return }   // already finished once
        self.completion = nil
        timeoutWork?.cancel(); timeoutWork = nil
        listener?.cancel(); listener = nil
        completion(result)
    }
}

// Reusable, non-blocking Sonos OAuth orchestration (design 2026-07-26-sonos-setup-ui: give the CLI-only
// `sonos-authorize` flow a real UI). This is the ONE implementation of "open the browser, wait for the
// loopback redirect, exchange the code, persist the result" -- both `sonos-authorize` (SonosAuthorizerCLI
// below) and the Settings UI drive it. Every path calls `completion` exactly once. Nothing here blocks any
// thread: SonosLoopbackServer and SonosOAuth.exchange are already callback-based, so a UI caller can
// invoke this straight from the main actor without hopping off it first -- only the CLI (a short-lived,
// otherwise-idle process with no run loop to hand work back to) still blocks its OWN thread afterward, via
// its own semaphore, purely to stay alive until `completion` fires.
enum SonosAuthorizer {
    // Retains the in-flight loopback server for the life of one authorize flow -- see the long comment
    // in authorize(). Also means a second authorize cannot start while one is pending, which is what we
    // want: two servers would fight over the fixed port.
    private static var active: SonosLoopbackServer?

    // Test seam: is a flow currently holding the loopback server open?
    static var hasActiveServer: Bool { active != nil }

    // Coarse progress the UI renders as the flow proceeds. The CLI ignores this -- it already prints its
    // own fixed messages at the start and the end.
    enum Stage: Equatable {
        case openingBrowser
        case waitingForRedirect
        case exchangingToken
    }

    // The two guard clauses the CLI used to check before ever starting the flow, now shared so the UI can
    // disable its Authorize button (with the same reason) without spinning up a listener first.
    static func preflight() -> SonosAuthError? {
        guard SonosKeychain.readSecret() != nil else { return .noClientSecret }
        guard SonosOAuth.clientID != SonosClientID.placeholder else { return .placeholderClientID }
        return nil
    }

    // `openURL` defaults to actually shelling out to `/usr/bin/open`; the CLI overrides it to ALSO print
    // the URL first (so "if it does not open, visit: <url>" keeps working), and a test could override it
    // to a no-op. `progress`/`completion` are `@escaping`: they outlive this call, carried into
    // SonosLoopbackServer's and SonosOAuth's own escaping completion handlers.
    static func authorize(timeout: TimeInterval = 180,
                          openURL: (URL) -> Void = defaultOpenURL,
                          progress: @escaping (Stage) -> Void = { _ in },
                          completion: @escaping (Result<Void, SonosAuthError>) -> Void) {
        if let refusal = preflight() { completion(.failure(refusal)); return }
        guard let secret = SonosKeychain.readSecret() else { completion(.failure(.noClientSecret)); return }

        let state = UUID().uuidString
        let url = SonosOAuth.authorizeURL(state: state)

        let server = SonosLoopbackServer()
        // The server MUST outlive this function. Everything the listener needs captures it weakly
        // (newConnectionHandler, the timeout work item, the per-connection receive), so if the only
        // reference is this local, `server` deallocates the moment authorize() returns. The socket
        // stays bound -- NWListener keeps its own bring-up alive -- but every accepted connection is
        // dropped on the floor: `self?.accept(conn)` no-ops, nothing is ever read or answered, and the
        // browser hangs on an ESTABLISHED connection forever because the timeout is weak too and never
        // fires either. Holding it here is what makes the callback actually arrive.
        Self.active = server
        let done: (Result<Void, SonosAuthError>) -> Void = { result in
            Self.active = nil
            completion(result)
        }
        server.start(timeout: timeout) { result in
            switch result {
            case .failure(let e):
                done(.failure(e))
            case .success(let callback):
                guard callback.state == state else { done(.failure(.stateMismatch)); return }
                progress(.exchangingToken)
                SonosOAuth.exchange(code: callback.code, secret: secret) { exResult in
                    switch exResult {
                    case .failure(let e):
                        done(.failure(e))
                    case .success(let cred):
                        guard let blob = ProviderCredentials.sonosBlob(accessToken: cred.accessToken,
                                                                       expiresAt: cred.expiresAt,
                                                                       refreshToken: cred.refreshToken),
                              SonosKeychain.writeOAuthBlob(blob)
                        else { done(.failure(.keychainWriteFailed)); return }
                        done(.success(()))
                    }
                }
            }
        }
        // The listener is already bound (NWListener.start queues its bring-up but SonosLoopbackServer's
        // newConnectionHandler is wired before this returns), so opening the browser now cannot race a
        // redirect that arrives before anyone is listening.
        progress(.openingBrowser)
        openURL(url)
        progress(.waitingForRedirect)
    }

    static func defaultOpenURL(_ url: URL) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url.absoluteString]
        try? open.run()
    }

    static func describe(_ e: SonosAuthError) -> String {
        switch e {
        case .noClientSecret:
            return "no Sonos client secret stored -- run `beacon-hub set-sonos-secret` first"
        case .placeholderClientID:
            return "the Client ID is still the placeholder -- set it in Settings (or SONOS_CLIENT_ID) with your integration's Client ID from https://integration.sonos.com/"
        case .loopbackBindFailed:
            return "could not open a local listener on localhost:\(SonosLoopbackServer.port)"
        case .timedOut:
            return "no redirect received in time"
        case .malformedCallback:
            return "redirect did not include code/state"
        case .stateMismatch:
            return "state mismatch"
        case .exchangeFailed(let m):
            return m
        case .keychainWriteFailed:
            return "could not write the Keychain item"
        }
    }
}

// CLI wrapper for `beacon-hub sonos-authorize` (design 2026-07-26-sonos-now-playing-plan step 2;
// refactored 2026-07-26-sonos-setup-ui so the Settings UI can drive the exact same flow instead of a
// second implementation). This invocation IS the whole program -- there is no app run loop to hand async
// work back to -- so it blocks its own main thread on a semaphore the same way a shell script would;
// SonosAuthorizer.authorize itself never blocks anything, and the UI calls it directly with no semaphore
// at all. Never runs inside the long-lived beacon-hub process. Handled before NSApplication exists
// (main.swift), same as set-claude-token/set-sonos-secret, so it never touches CoreBluetooth.
enum SonosAuthorizerCLI {
    static func run() -> Never {
        let waitSem = DispatchSemaphore(value: 0)
        var outcome: Result<Void, SonosAuthError>?

        SonosAuthorizer.authorize(openURL: { url in
            FileHandle.standardError.write(Data(
                "Opening your browser to authorize Beacon Hub with Sonos...\nIf it does not open, visit:\n\(url.absoluteString)\n".utf8))
            SonosAuthorizer.defaultOpenURL(url)
        }) { result in
            outcome = result
            waitSem.signal()
        }

        // One combined backstop covering the whole flow (loopback wait + token exchange). The prior code
        // split this into two separate semaphore waits (185s then 15s); merging them removes the risk of
        // the old fixed 15s exchange window firing "no response" while a slower-but-healthy exchange was
        // still legitimately in flight, while keeping the same worst-case ceiling (loopback default 180s
        // + a network round trip + margin).
        _ = waitSem.wait(timeout: .now() + 245)
        guard let outcome else {
            FileHandle.standardError.write(Data("timed out waiting for the Sonos redirect\n".utf8))
            exit(1)
        }

        switch outcome {
        case .success:
            FileHandle.standardError.write(Data(
                "Sonos connected. Restart Beacon Hub (or it will pick this up on its next poll).\n".utf8))
            exit(0)
        case .failure(let e):
            switch e {
            case .noClientSecret, .placeholderClientID:
                FileHandle.standardError.write(Data("refused: \(SonosAuthorizer.describe(e))\n".utf8))
                exit(2)
            case .stateMismatch:
                FileHandle.standardError.write(Data("refused: redirect state mismatch (possible CSRF) -- try again\n".utf8))
                exit(1)
            case .loopbackBindFailed, .timedOut, .malformedCallback:
                FileHandle.standardError.write(Data("authorize failed: \(SonosAuthorizer.describe(e))\n".utf8))
                exit(1)
            case .exchangeFailed:
                FileHandle.standardError.write(Data("token exchange failed: \(SonosAuthorizer.describe(e))\n".utf8))
                exit(1)
            case .keychainWriteFailed:
                FileHandle.standardError.write(Data("failed: \(SonosAuthorizer.describe(e))\n".utf8))
                exit(1)
            }
        }
    }
}
