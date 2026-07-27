import AppKit
import SwiftUI

// The single Settings window (design §2.2): one real, resizable NSWindow with four toolbar tabs, replacing
// the fixed-size panel plus the two now-deleted PageDesignerWindowController/TickerEditorWindowController
// windows. Lazily built, reused across opens (isReleasedWhenClosed = false), observing the SAME
// HubViewModel every other surface does. The app is .accessory at rest, so showing it needs
// NSApp.activate; §9.1 additionally promotes the app to .regular while this window is open (see `show`/
// `windowWillClose` below) so it gets a real menu bar, ⌘,, ⌘W, and window cycling.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    // `BeaconFirstRunComplete`: no longer drives window presentation -- AppDelegate's SettingsLaunch gate
    // (BeaconDidAutoOpenSettings) owns that now. This key survives purely as the menubar setup-hint latch
    // (AppDelegate.maybeMarkComplete still writes it); do not delete the key or this latch.
    static let completeKey = "BeaconFirstRunComplete"

    private let model: HubViewModel
    private var window: NSWindow?

    init(model: HubViewModel) {
        self.model = model
        super.init()
    }

    func show() {
        // §9.1 (provisional, design §2.4/§9): promote before activating so the freshly-regular app gets a
        // proper menu bar the instant the window is key.
        NSApp.setActivationPolicy(.regular)
        let w = window ?? buildWindow()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // First-run auto-open stops once Bluetooth + pairing + every provider's hooks are satisfied; still
    // called by AppDelegate.maybeMarkComplete(). The menubar setup hint is the only remaining reader of
    // this key.
    func markComplete() { UserDefaults.standard.set(true, forKey: Self.completeKey) }

    private func buildWindow() -> NSWindow {
        let host = NSHostingController(rootView: SettingsRootView(model: model))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = "Beacon Settings"
        w.delegate = self
        // A settings window that forgets where it was is the tell that it is not a real window.
        w.setContentSize(NSSize(width: 780, height: 580))
        w.contentMinSize = NSSize(width: 720, height: 520)   // the Pages tab needs the horizontal run.
        w.setFrameAutosaveName("BeaconSettingsWindow")
        w.isRestorable = true
        w.isReleasedWhenClosed = false   // reused across opens
        return w
    }

    // Revert-on-close (design §2.2): PageDesignerWindowController's old windowWillClose rule moves here
    // now that the designer is the Pages tab rather than its own window -- (a) window close, (b) nothing
    // else. Keeping a staged edit alive across a TAB switch is correct (the user may be in Sources adding
    // the ticker the chart wants); only closing the whole window drops it. Comps get the same treatment:
    // the complication editor is Home's page inspector, staged the same way pages are (plan §13 item 4).
    func windowWillClose(_ notification: Notification) {
        if model.pagesDirty { model.onRevertPages() }
        if model.compsDirty { model.onRevertComps() }
        NSApp.setActivationPolicy(.accessory)   // §9.1: back to accessory once Settings is gone.
    }
}

// isRestorable = true (above) needs this delegate answer on modern macOS or restoration silently no-ops;
// an extension here (rather than editing AppDelegate.swift, which WS-2 is not authorized to touch beyond
// its two deleted lazy vars) satisfies the same NSApplicationDelegate conformance from this file instead.
extension AppDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
