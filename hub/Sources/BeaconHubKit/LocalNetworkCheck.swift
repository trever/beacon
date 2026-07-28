import Foundation

// Outcome-derived Local Network diagnostics for the Settings "Local Network" row (design
// 2026-07-27-sonos-album-art-design.md §7.1/§7.3, plan 2026-07-27-sonos-album-art-plan.md §4 WS-4). There
// is no macOS API to query Local Network permission directly (design §0, the OTA plan's §3) -- the only
// evidence is what actually happened the last time the hub tried to serve the device something, i.e. the
// device's own `sart_stat` outcome (CONTRACT.md §B4). This type turns that outcome into the row's state
// and message; it has no knowledge of BLE, LanAssetServer, or Sonos at all.
//
// `err:"timeout"` at zero bytes received is the TCC-denial shape and `err:"conn_refused"` is the firewall
// shape (design §2.3) -- those two strings are precisely the evidence prerequisite P-1 exists to surface,
// so they get their own named messages. The other four values in the frozen six
// (`http`/`size`/`net`/`no_wifi`) all imply the device's TCP connection to the hub's listener was NOT
// blocked at the OS level -- `http`/`size` mean it connected and got a malformed/short response, and
// `net` means some other failure past the connect step -- so none of them says anything bad about Local
// Network permission; the row stays `.ok`. `no_wifi` means the device never even attempted the connection
// (its own WiFi is down, design §8), which proves nothing either way about the hub's permission state, so
// the row goes back to `.checking` rather than falsely claiming `.ok` or `.bad`.
public enum LanServeOutcome: Equatable {
    case neverAttempted
    case served
    case deviceErr(String)
}

public enum LocalNetworkCheck {
    // `State` deliberately mirrors `beacon-hub`'s `CheckState` (checking/ok/bad) rather than importing it
    // -- BeaconHubKit is the lower-level target `beacon-hub` depends on, never the reverse, so this type
    // cannot reference anything in `beacon-hub`. The caller (HubViewModel/AppDelegate, both in
    // `beacon-hub`) bridges this 1:1 into `CheckState`, the same shape `HubState.init(_ checkState:)`
    // already bridges the other direction (HubRows.swift).
    public enum State: Equatable { case checking, ok, bad }

    public static func derive(_ outcome: LanServeOutcome) -> (state: State, message: String?) {
        switch outcome {
        case .neverAttempted:
            return (.checking, nil)
        case .served:
            return (.ok, nil)
        case .deviceErr(let err):
            switch err {
            case "timeout":
                return (.bad, "The Beacon timed out reaching this Mac. Check Local Network permission in "
                    + "System Settings \u{203A} Privacy & Security \u{203A} Local Network.")
            case "conn_refused":
                return (.bad, "The connection was refused. Check the macOS firewall settings for Beacon Hub.")
            case "no_wifi":
                return (.checking, "The Beacon's WiFi is down, so it has not attempted a connection.")
            default:
                // http / size / net: the device reached the hub's listener at the TCP level -- whatever
                // went wrong from there is unrelated to Local Network permission.
                return (.ok, nil)
            }
        }
    }
}
