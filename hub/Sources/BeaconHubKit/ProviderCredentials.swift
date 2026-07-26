import Foundation

// Pure parsers for the two providers' on-disk credential blobs, split out of UsagePoller so the JSON
// SHAPE is unit-testable. The privileged READ (Keychain for Claude, ~/.codex/auth.json for Codex) stays
// in the executable; what breaks when a CLI changes its blob is the shape, so isolate + test it here
// (mirrors UsageNormalizer's "expect breakage, isolate the shape"). expiresAt is read so an expired-on-disk
// token is reported as "stale, waiting for the CLI" instead of a misleading "re-login". refreshToken and
// refreshTokenExpiresAt are now parsed too, for the #132 source ladder: when the claude CLI is installed
// it remains the sole token owner (its refresh is single-use/rotating, so we delegate to it rather than
// race it); a hub-side direct OAuth grant only fires when the CLI is absent. OPENAI_API_KEY stays unused.
// An empty-string token is treated as absent (=> nil).
public struct ClaudeCredential: Equatable {
    public let accessToken: String
    public let expiresAt: Date?              // nil when absent/unparseable; treated as never-expired.
    public let refreshToken: String?         // nil when absent/empty.
    public let refreshTokenExpiresAt: Date?  // nil when absent/unparseable; treated as never-expired.

    public init(accessToken: String, expiresAt: Date?,
                refreshToken: String? = nil, refreshTokenExpiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    // Whether a refresh is even worth attempting: a present, non-empty refresh token whose own expiry
    // (if any) has not passed. Used to gate the #132 source ladder before picking delegated vs. direct.
    public func refreshTokenAlive(at now: Date) -> Bool {
        guard let refreshToken, !refreshToken.isEmpty else { return false }
        guard let refreshTokenExpiresAt else { return true }
        return now < refreshTokenExpiresAt
    }

    // Usable = can produce a working access token now, either directly or via a refresh. A credential
    // that is expired with a dead refresh token is inert: nothing short of re-login revives it.
    public func isUsable(at now: Date) -> Bool {
        !isExpired(at: now) || refreshTokenAlive(at: now)
    }

}

public enum ProviderCredentials {
    // The blob shape to persist a long-lived token (`claude setup-token`) into Beacon's own Keychain
    // item. No expiresAt/refreshToken: absent expiry is read as never-expiring, which is precisely what
    // a long-lived token is, and there is nothing to refresh.
    public static func longLivedBlob(accessToken: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": accessToken]])
    }


    // Which of the two Claude credential sources to use.
    //
    // The claude CLI's Keychain item wins WHILE IT IS USABLE: its refresh token is single-use and
    // rotating, so racing the CLI with our own refresh would invalidate its copy. But "usable" is the
    // qualifier that matters -- a CLI credential that is expired AND whose refresh token is dead has no
    // value at all, and preferring it unconditionally means the hub can never use a working token even
    // when one exists. That is exactly the dead end observed on a Claude-Code-Desktop-only host: the CLI
    // item was a stale leftover nothing would ever refresh.
    //
    // So: CLI if usable, else Beacon's own item (which is where a long-lived `claude setup-token` token
    // is parked -- that command prints a token for CLAUDE_CODE_OAUTH_TOKEN and does NOT write the
    // Keychain, and a LaunchServices-launched GUI app never inherits shell environment anyway).
    public static func preferred(cli: ClaudeCredential?, beacon: ClaudeCredential?,
                                now: Date) -> ClaudeCredential? {
        if let cli, cli.isUsable(at: now) { return cli }
        if let beacon, beacon.isUsable(at: now) { return beacon }
        // Neither is usable: still return the CLI one if present so the caller reports the CLI's own
        // failure ("run claude login") rather than a confusing message about a token the user may never
        // have configured.
        return cli ?? beacon
    }

    // Claude Keychain blob: { claudeAiOauth: { accessToken, expiresAt (epoch ms), refreshToken,
    // refreshTokenExpiresAt (epoch ms), ... } }.
    public static func parseClaude(_ blob: Data) -> ClaudeCredential? {
        guard let obj = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        let expiresAt = (oauth["expiresAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let refreshToken = (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let refreshTokenExpiresAt = (oauth["refreshTokenExpiresAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeCredential(accessToken: token, expiresAt: expiresAt,
                                refreshToken: refreshToken, refreshTokenExpiresAt: refreshTokenExpiresAt)
    }

    // Codex ~/.codex/auth.json: { tokens: { access_token, account_id, ... } }.
    public static func parseCodex(_ json: Data) -> (accessToken: String, accountId: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty,
              let account = tokens["account_id"] as? String, !account.isEmpty
        else { return nil }
        return (token, account)
    }
}
