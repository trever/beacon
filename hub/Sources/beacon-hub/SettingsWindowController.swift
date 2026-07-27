import AppKit
import SwiftUI

// The single Settings window (design SS4): one real, resizable NSWindow with a sidebar of destinations,
// replacing the fixed-size panel plus the two now-deleted PageDesignerWindowController/
// TickerEditorWindowController windows. Lazily built, reused across opens (isReleasedWhenClosed = false),
// observing the SAME HubViewModel every other surface does. The app is .accessory at rest, so showing it
// needs NSApp.activate; SS9.3 additionally promotes the app to .regular while this window is open (see
// `show`/`windowWillClose` below) so it gets a real menu bar, Cmd-comma, Cmd-W, and window cycling.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    // `BeaconFirstRunComplete`: no longer drives window presentation -- AppDelegate's SettingsLaunch gate
    // (BeaconDidAutoOpenSettings) owns that now. This key survives purely as the menubar setup-hint latch
    // (AppDelegate.maybeMarkComplete still writes it); do not delete the key or this latch.
    static let completeKey = "BeaconFirstRunComplete"

    private let model: HubViewModel
    private var window: NSWindow?

    /// Set just before this controller calls `window.close()` itself (from a chosen close-sheet intent),
    /// so the `windowShouldClose` that close triggers does not re-derive dirtiness and re-present the sheet
    /// (plan SS1 trap 2: `Save & push` does not clear the dirty flags synchronously -- `appliedPageIDs`
    /// only updates once `AppDelegate` acknowledges the push -- so the decision, once made, must not be
    /// re-checked). Reset in `windowWillClose` so the NEXT open/close cycle starts fresh; the window is
    /// reused for the app's lifetime, so this flag must not stay latched forever (plan SS1 trap 3).
    private var isClosing = false

    init(model: HubViewModel) {
        self.model = model
        super.init()
    }

    func show() {
        // SS9.3 (design): promote before activating so the freshly-regular app gets a proper menu bar the
        // instant the window is key.
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
        let root = SettingsRootView(
            model: model,
            onTitleChange: { [weak self] title in self?.window?.title = title },
            onDirtyChange: { [weak self] dirty in self?.window?.isDocumentEdited = dirty }
        )
        let host = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Read the persisted destination directly rather than waiting for SwiftUI's onAppear, so the very
        // first frame already has the right per-destination title (design SS4.4) instead of a generic one.
        let startingTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: SettingsTabPersistence.key) ?? "")
            ?? .pages
        w.title = startingTab.title
        w.isDocumentEdited = model.pagesDirty || model.compsDirty
        w.delegate = self
        // A settings window that forgets where it was is the tell that it is not a real window.
        w.setContentSize(NSSize(width: 820, height: 580))
        // The sidebar costs ~180 pt the Pages destination did not have to give (design SS5.1); 720x520
        // (the old TabView minimum) no longer fits it. 820x560 is the derived floor (design SS4.4).
        w.contentMinSize = NSSize(width: 820, height: 560)
        w.setFrameAutosaveName("BeaconSettingsWindow")
        w.isRestorable = true
        w.isReleasedWhenClosed = false   // reused across opens
        return w
    }

    // The close sheet (design SS4.3 "Approved: the close sheet", plan SS1 step 5): `windowWillClose` used
    // to silently revert staged edits, which was fine when nothing on screen said there was anything to
    // lose. Now that `isDocumentEdited` tells the user there is unsaved work, closing without asking is a
    // visible data-loss path. `windowShouldClose` is the delegate method that can actually refuse the
    // close (`windowWillClose` fires after the decision is already made and cannot cancel it, plan SS1
    // trap 1) -- so the revert moves here, gated behind a three-button sheet.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosing { return true }
        let pagesDirty = model.pagesDirty
        let compsDirty = model.compsDirty
        guard SettingsClosePolicy.needsConfirmation(pagesDirty: pagesDirty, compsDirty: compsDirty) else {
            return true
        }
        presentCloseSheet(on: sender, pagesDirty: pagesDirty, compsDirty: compsDirty)
        return false
    }

    private func presentCloseSheet(on window: NSWindow, pagesDirty: Bool, compsDirty: Bool) {
        let alert = NSAlert()
        // Title is a question naming the object; the message states what is lost and what is kept (design
        // SS3.10), extended here to a three-button sheet rather than SS3.10's plain destructive pair.
        alert.messageText = "Save changes before closing Settings?"
        alert.informativeText = closeMessage(pagesDirty: pagesDirty, compsDirty: compsDirty)
        alert.addButton(withTitle: "Save & Push")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let intent: CloseIntent
            switch response {
            case .alertFirstButtonReturn:  intent = .saveAndPush
            case .alertSecondButtonReturn: intent = .discard
            default:                       intent = .cancel
            }
            self.apply(SettingsClosePolicy.effects(for: intent, pagesDirty: pagesDirty, compsDirty: compsDirty),
                       to: window)
        }
    }

    private func closeMessage(pagesDirty: Bool, compsDirty: Bool) -> String {
        switch (pagesDirty, compsDirty) {
        case (true, true):
            return "Closing without saving discards your staged page and complication changes. " +
                   "Save & Push applies both to the Beacon now; Discard reverts to what it already runs."
        case (true, false):
            return "Closing without saving discards your staged page changes (applying restarts the " +
                   "Beacon, ~5 s). Save & Push applies them now; Discard reverts to what it already runs."
        case (false, true):
            return "Closing without saving discards your staged complication changes. " +
                   "Save & Push applies them to the Beacon now; Discard reverts to what it already runs."
        case (false, false):
            return ""
        }
    }

    private func apply(_ effects: [CloseEffect], to window: NSWindow) {
        for effect in effects {
            switch effect {
            case .applyComps:  model.onApplyComps(model.compSlots)
            case .applyPages:  model.onApplyPages(model.enabledPageIDs, model.enabledPageOpts)
            case .revertComps: model.onRevertComps()
            case .revertPages: model.onRevertPages()
            case .stayOpen:
                break   // Cancel: leave every staged edit exactly as it was.
            case .close:
                // `windowShouldClose` fires again from this call; the latch above short-circuits it so the
                // sheet does not re-present itself over a decision that has already been made.
                isClosing = true
                window.close()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // SS9.3: back to accessory once Settings is gone.
        isClosing = false                       // The window is reused; the next close needs a fresh check.
    }
}

// isRestorable = true (above) needs this delegate answer on modern macOS or restoration silently no-ops;
// an extension here (rather than editing AppDelegate.swift, which this workstream is not authorized to
// touch) satisfies the same NSApplicationDelegate conformance from this file instead.
extension AppDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
