import AppKit
import Foundation
import BeaconHubKit

// `set-claude-token`: park a long-lived `claude setup-token` token in Beacon's own Keychain item.
//
// Why a subcommand at all: setup-token prints a token for CLAUDE_CODE_OAUTH_TOKEN and does NOT write
// the Keychain, and a LaunchServices-launched GUI app never inherits shell environment -- so there is
// no path from that env var to this app. Read from STDIN, never argv: an argument would land in shell
// history, and a file would leave the token in plaintext on disk.
//
// Handled before NSApplication exists so it never touches CoreBluetooth (a bare binary that does is
// TCC-killed within seconds).
if CommandLine.arguments.dropFirst().first == "set-claude-token" {
    FileHandle.standardError.write(Data("Paste the token from `claude setup-token`, then press Return and Ctrl-D:\n".utf8))
    let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    // Reject obvious non-tokens early so a stray paste is not silently stored as a credential.
    guard token.count >= 20, !token.contains(" ") else {
        FileHandle.standardError.write(Data("refused: that does not look like a token (>=20 chars, no spaces)\n".utf8))
        exit(2)
    }
    guard let blob = ProviderCredentials.longLivedBlob(accessToken: token),
          ClaudeKeychain.writeBeaconCache(blob) else {
        FileHandle.standardError.write(Data("failed: could not write the Keychain item\n".utf8))
        exit(1)
    }
    // Length only -- never echo the token itself.
    FileHandle.standardError.write(Data("stored \(token.count) chars in the Beacon Keychain item. Restart Beacon Hub.\n".utf8))
    exit(0)
}

// `set-sonos-secret`: park the Sonos OAuth client secret in Beacon's own Keychain item (design
// 2026-07-26-sonos-now-playing-plan step 1). Mirrors set-claude-token exactly -- stdin only (never argv:
// an argument would land in shell history), and only a character count is ever echoed back. This
// repository is public; the secret must never be logged, committed, or typed by anything other than the
// user themselves. Handled before NSApplication exists, same reasoning as set-claude-token above.
if CommandLine.arguments.dropFirst().first == "set-sonos-secret" {
    FileHandle.standardError.write(Data("Paste the Sonos client secret, then press Return and Ctrl-D:\n".utf8))
    let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let secret = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard secret.count >= 16, !secret.contains(" ") else {
        FileHandle.standardError.write(Data("refused: that does not look like a client secret (>=16 chars, no spaces)\n".utf8))
        exit(2)
    }
    guard SonosKeychain.writeSecret(secret) else {
        FileHandle.standardError.write(Data("failed: could not write the Keychain item\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data("stored \(secret.count) chars in the Beacon Keychain item. Run `beacon-hub sonos-authorize` next.\n".utf8))
    exit(0)
}

// `sonos-authorize`: one-time OAuth authorize + token exchange for the Sonos Control API (design
// 2026-07-26-sonos-now-playing-plan step 2). Requires the client secret to already be stored via
// set-sonos-secret. Opens the default browser to the Sonos consent screen, listens on a fixed loopback
// port for the redirect, exchanges the code for tokens, and stores the result in Beacon's Keychain item.
// Never touches CoreBluetooth, so handled before NSApplication exists just like the other CLI subcommands.
if CommandLine.arguments.dropFirst().first == "sonos-authorize" {
    SonosAuthorizerCLI.run()   // never returns; exits via exit(0)/exit(1)/exit(2)
}

// Menubar agent entry point. .accessory => no Dock icon / app bundle needed for development.
// AppKit + AppDelegate are main-actor isolated; the bootstrap runs there explicitly.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
