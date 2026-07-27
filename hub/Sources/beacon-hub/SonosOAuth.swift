import Foundation
import BeaconHubKit

// Sonos Control API OAuth (design 2026-07-26-sonos-now-playing-plan): authorize URL + the token/refresh
// POSTs. Follows ClaudeTokenRefresher's direct-refresh idiom exactly -- percent-encode form values with
// the tightest safe (RFC 3986 unreserved) character set rather than trusting URLComponents' query
// encoding (which does not escape "+", and a literal "+" in an opaque code/token is misread as a space by
// a form-urlencoded parser), and build the Basic-auth header by hand so the secret only ever exists as a
// request header, never logged.
enum SonosOAuth {
    // Not secret (per the plan: "The client ID is not secret and may live in source or config"). Resolved
    // via SonosClientID.resolve's precedence (design 2026-07-26-sonos-setup-ui): the value saved in
    // Settings (SonosSetupStore, UserDefaults) wins; SONOS_CLIENT_ID keeps working as a fallback for
    // anyone who set it before the Settings UI existed; SonosClientID.placeholder is the last resort. Get
    // a real Client ID from a "Control" integration at https://integration.sonos.com/ (redirect URI =
    // SonosOAuth.redirectURI) -- Settings is the intended place to put it now.
    static var clientID: String {
        let env = ProcessInfo.processInfo.environment["SONOS_CLIENT_ID"]
        return SonosClientID.resolve(stored: SonosSetupStore().storedClientID, env: env)
    }

    static let authorizeEndpoint = "https://api.sonos.com/login/v3/oauth"
    static let tokenEndpoint = "https://api.sonos.com/login/v3/oauth/access"
    // Fixed (not ephemeral) loopback port + path, registered once as this integration's sole redirect URI
    // (RFC 8252 §7.3's loopback-redirect pattern -- the right shape for a menubar app with no custom URL
    // scheme registered). Host is "localhost", not "127.0.0.1": Sonos's redirect-URI registration refuses a
    // raw IP address, and redirect_uri is compared as an exact string both at authorize time and again at
    // token exchange (see `exchange` below) -- so this string must match the registered
    // "http://localhost:53912/callback" byte for byte. SonosLoopbackServer binds loopback on both address
    // families so that whichever one "localhost" resolves to on the browser's side (macOS returns both
    // ::1 and 127.0.0.1, and browsers commonly try IPv6 first) still lands on a live listener.
    static var redirectURI: String { "http://localhost:\(SonosLoopbackServer.port)\(SonosLoopbackServer.callbackPath)" }
    // playback-control-all is the narrowest scope that can still read now-playing metadata; the Sonos
    // Control API has no separate read-only scope as of this writing.
    static let scope = "playback-control-all"

    static func authorizeURL(state: String) -> URL {
        var comps = URLComponents(string: authorizeEndpoint)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        return comps.url!
    }

    // RFC 3986 unreserved characters -- see ClaudeTokenRefresher.formValueAllowed for why this (not
    // URLComponents' own percent-encoding) is the safe choice for an opaque, sensitive form value.
    private static let formValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
    private static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: formValueAllowed) ?? s }

    private static func basicAuthHeader(secret: String) -> String? {
        guard let data = "\(clientID):\(secret)".data(using: .utf8) else { return nil }
        return "Basic \(data.base64EncodedString())"
    }

    // Exchanges an authorization code (from the loopback redirect) for tokens.
    static func exchange(code: String, secret: String, session: URLSession = .shared,
                         completion: @escaping (Result<SonosCredential, SonosAuthError>) -> Void) {
        let body = "grant_type=authorization_code&code=\(encode(code))&redirect_uri=\(encode(redirectURI))"
        post(body: body, secret: secret, session: session, completion: completion)
    }

    // refresh_token is not guaranteed to rotate on every call; the caller (SonosProvider) keeps the prior
    // one when the response omits it, same fallback ClaudeTokenRefresher uses.
    static func refresh(refreshToken: String, secret: String, session: URLSession = .shared,
                        completion: @escaping (Result<SonosCredential, SonosAuthError>) -> Void) {
        let body = "grant_type=refresh_token&refresh_token=\(encode(refreshToken))"
        post(body: body, secret: secret, session: session, completion: completion)
    }

    private static func post(body: String, secret: String, session: URLSession,
                             completion: @escaping (Result<SonosCredential, SonosAuthError>) -> Void) {
        guard let url = URL(string: tokenEndpoint), let auth = basicAuthHeader(secret: secret) else {
            completion(.failure(.exchangeFailed("could not build request")))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.httpBody = Data(body.utf8)

        session.dataTask(with: req) { data, resp, err in
            if let err {
                completion(.failure(.exchangeFailed("network error: \(err.localizedDescription)")))
                return
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data, let cred = parseTokenResponse(data, now: Date()) else {
                completion(.failure(.exchangeFailed("HTTP \(code)")))
                return
            }
            completion(.success(cred))
        }.resume()
    }

    // { access_token, token_type, expires_in (seconds), refresh_token }. Pure so it is fixture-tested
    // without a network stack; internal (not private) for SonosOAuthTests.
    static func parseTokenResponse(_ data: Data, now: Date) -> SonosCredential? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String, !token.isEmpty
        else { return nil }
        let expiresAt: Date? = (obj["expires_in"] as? NSNumber).map { now.addingTimeInterval($0.doubleValue) }
        let refreshToken = (obj["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return SonosCredential(accessToken: token, expiresAt: expiresAt, refreshToken: refreshToken)
    }
}

enum SonosAuthError: Error, Equatable {
    // Preflight refusals (design 2026-07-26-sonos-setup-ui): checked before the flow ever starts a
    // listener, so both the CLI's up-front guard and the UI's disabled-button reason share one vocabulary.
    case noClientSecret
    case placeholderClientID
    case loopbackBindFailed
    case timedOut
    case malformedCallback
    case stateMismatch
    case exchangeFailed(String)
    case keychainWriteFailed
}
