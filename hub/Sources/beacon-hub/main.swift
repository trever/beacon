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

// Menubar agent entry point. .accessory => no Dock icon / app bundle needed for development.
// AppKit + AppDelegate are main-actor isolated; the bootstrap runs there explicitly.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
