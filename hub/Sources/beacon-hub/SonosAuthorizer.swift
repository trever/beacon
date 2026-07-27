import Foundation
import Network
import BeaconHubKit

// One-shot localhost HTTP listener for the Sonos OAuth redirect (design 2026-07-26-sonos-now-playing-plan,
// RFC 8252 §7.3 loopback-redirect pattern -- the right shape for a menubar app with no custom URL scheme
// registered). The browser hits http://127.0.0.1:<fixed port>/callback?code=...&state=..., we grab the
// query string, answer with a "you can close this" page, and shut the listener down. Fixed (not
// ephemeral) port so the exact redirect URI can be registered once in the Sonos developer console -- see
// SonosOAuth.redirectURI. Deliberately its own tiny listener, not a route on LocalIngestServer: it needs
// GET + query-string parsing (the ingest server only ever does POST + JSON bodies) and it lives for one
// request during a manual `sonos-authorize` run, not for the app's lifetime.
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
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        guard let l = try? NWListener(using: params) else {
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

// Synchronous CLI orchestration for `beacon-hub sonos-authorize` (design 2026-07-26-sonos-now-playing-plan
// step 2). This invocation IS the whole program -- there is no app run loop to hand async work back to --
// so it blocks on semaphores the same way a shell script would, unlike the menubar app's callback style.
// Never runs inside the long-lived beacon-hub process. Handled before NSApplication exists (main.swift),
// same as set-claude-token/set-sonos-secret, so it never touches CoreBluetooth.
enum SonosAuthorizerCLI {
    static func run() -> Never {
        guard let secret = SonosKeychain.readSecret() else {
            FileHandle.standardError.write(Data("refused: no Sonos client secret stored -- run `beacon-hub set-sonos-secret` first\n".utf8))
            exit(2)
        }
        if SonosOAuth.clientID == "REPLACE_WITH_SONOS_CLIENT_ID" {
            FileHandle.standardError.write(Data(
                "refused: SonosOAuth.clientID is still the placeholder -- set SONOS_CLIENT_ID or edit SonosOAuth.swift with your integration's Client ID from https://integration.sonos.com/\n".utf8))
            exit(2)
        }

        let state = UUID().uuidString
        let url = SonosOAuth.authorizeURL(state: state)

        let waitSem = DispatchSemaphore(value: 0)
        var callbackOutcome: Result<(code: String, state: String), SonosAuthError>?
        let server = SonosLoopbackServer()
        server.start { result in callbackOutcome = result; waitSem.signal() }

        FileHandle.standardError.write(Data(
            "Opening your browser to authorize Beacon Hub with Sonos...\nIf it does not open, visit:\n\(url.absoluteString)\n".utf8))
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url.absoluteString]
        try? open.run()

        _ = waitSem.wait(timeout: .now() + 185)
        guard let callbackOutcome else {
            FileHandle.standardError.write(Data("timed out waiting for the Sonos redirect\n".utf8))
            exit(1)
        }
        let callback: (code: String, state: String)
        switch callbackOutcome {
        case .success(let v): callback = v
        case .failure(let e):
            FileHandle.standardError.write(Data("authorize failed: \(describe(e))\n".utf8))
            exit(1)
        }
        guard callback.state == state else {
            FileHandle.standardError.write(Data("refused: redirect state mismatch (possible CSRF) -- try again\n".utf8))
            exit(1)
        }

        let exchangeSem = DispatchSemaphore(value: 0)
        var exchangeOutcome: Result<SonosCredential, SonosAuthError>?
        SonosOAuth.exchange(code: callback.code, secret: secret) { result in exchangeOutcome = result; exchangeSem.signal() }
        _ = exchangeSem.wait(timeout: .now() + 15)
        guard case .success(let cred) = exchangeOutcome else {
            let reason: String
            if case .failure(let e) = exchangeOutcome { reason = describe(e) } else { reason = "no response" }
            FileHandle.standardError.write(Data("token exchange failed: \(reason)\n".utf8))
            exit(1)
        }

        guard let blob = ProviderCredentials.sonosBlob(accessToken: cred.accessToken, expiresAt: cred.expiresAt,
                                                       refreshToken: cred.refreshToken),
              SonosKeychain.writeOAuthBlob(blob)
        else {
            FileHandle.standardError.write(Data("failed: could not write the Keychain item\n".utf8))
            exit(1)
        }
        FileHandle.standardError.write(Data("Sonos connected. Restart Beacon Hub (or it will pick this up on its next poll).\n".utf8))
        exit(0)
    }

    private static func describe(_ e: SonosAuthError) -> String {
        switch e {
        case .loopbackBindFailed: return "could not open a local listener on 127.0.0.1:\(SonosLoopbackServer.port)"
        case .timedOut: return "no redirect received in time"
        case .malformedCallback: return "redirect did not include code/state"
        case .stateMismatch: return "state mismatch"
        case .exchangeFailed(let m): return m
        }
    }
}
