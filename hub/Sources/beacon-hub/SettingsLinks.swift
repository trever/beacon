import AppKit
import Foundation

// Single source for the System Settings deep links so MenubarController and the Settings window can't
// drift. macOS 13+ pane ids; the pre-Ventura "com.apple.Bluetooth" no longer resolves.
enum SettingsLinks {
    static let bluetooth = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!
    static let privacyBluetooth = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
    // Album art plan §4 WS-4: the Local Network row's "Open Settings" action. Same pane family as
    // privacyBluetooth above, different anchor -- Local Network was added to Privacy & Security in
    // macOS 12 for exactly this per-app TCC toggle.
    static let privacyLocalNetwork = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
    static let fallback = URL(string: "x-apple.systempreferences:")!

    // Open `url`, falling back to the Settings root if a drifted pane id fails to resolve.
    static func open(_ url: URL) {
        if NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(fallback)
    }
}
