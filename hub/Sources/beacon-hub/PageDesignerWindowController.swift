import AppKit
import SwiftUI

// Standalone window for the page designer, mirroring SettingsWindowController: a lazily built, reused
// NSWindow hosting SwiftUI over the SAME HubViewModel, so the preview cards stay live while sessions
// change underneath. The app is .accessory, so showing it needs NSApp.activate.
@MainActor
final class PageDesignerWindowController: NSObject, NSWindowDelegate {
    private let model: HubViewModel
    private var window: NSWindow?

    init(model: HubViewModel) {
        self.model = model
        super.init()
    }

    func show() {
        let w = window ?? buildWindow()
        window = w
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func buildWindow() -> NSWindow {
        let host = NSHostingController(rootView: PageDesignerView(model: model))
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .resizable]
        w.title = "Beacon Pages"
        w.delegate = self
        w.isReleasedWhenClosed = false   // reused across opens
        return w
    }

    // Closing with edits pending would silently strand them: the designer's state lives in the view
    // model, so a reopen would still show the unsaved list with no hint it was never pushed. Drop back to
    // what the device is running instead.
    func windowWillClose(_ notification: Notification) {
        if model.pagesDirty { model.onRevertPages() }
    }
}
