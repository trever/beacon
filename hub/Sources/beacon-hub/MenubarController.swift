import AppKit
import SwiftUI
import BeaconHubKit

// The replacement setup-hint row (design §2.3): which provider, if any, needs the menu's
// "<Provider> hooks not installed · Set up" item shown. Pure so it's host-testable without AppKit/NSMenu.
// `.checking` deliberately does NOT count as "needs setup" -- the first hooks check hasn't resolved yet,
// and flashing the hint before it does would be the same premature-failure-state bug StatusRow's glyph
// comment already calls out for the Settings UI.
enum MenubarHooksHint {
    static func providerNeedingSetup(_ toggles: [ProviderToggle]) -> ProviderToggle? {
        toggles.first { $0.buddyOn && $0.hooks == .bad }
    }
}

// NSStatusItem + NSPopover hosting the SwiftUI HubPanel (design 4A). Mirrors link status + last-sync age,
// the four usage values, any provider error strings, a pairing hint, and Quit. Pure display; AppDelegate
// pushes state in via the same setters and `on*` closures as before. The status-bar icon and the prompt
// sound stay here (container-independent). Main-thread only. NSObject for Obj-C target-action (togglePopover).
@MainActor
final class MenubarController: NSObject {
    enum Link {
        case bluetoothOff, unauthorized, unavailable
        case searching, connecting(String), connected(String), reconnecting
        case pairingFailed
    }

    // UI-facing login-item state (issue #16). AppDelegate maps SMAppService.Status onto this so this
    // pure-display layer never imports ServiceManagement. .requiresApproval is surfaced honestly instead
    // of a silent false "off".
    enum LoginItemStatus { case enabled, disabled, requiresApproval }

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model = HubViewModel()
    // The replacement setup-hint row (design §2.3): lives in the app menu (installQuitShortcut) rather than
    // the popover, hidden until MenubarHooksHint finds a provider that needs it. Non-modal, no focus theft --
    // a menu item only reveals itself on an explicit click, same as the old checkbox's replacement was
    // supposed to be.
    private var hooksHintItem: NSMenuItem?

    // The shared view model, exposed so the dedicated ticker editor window (issue #92) observes the same
    // live tickerSync/tickerRows/search closure that the popover panel does.
    var viewModel: HubViewModel { model }

    private var link: Link = .searching
    private var alert: String?         // persistent loud surface for an undeliverable prompt; nil => none.
    private var bridgeAlert: String?   // bridge bind failure; nil => none. Independent of `alert`.

    // URL the fix link opens; set per-state in setLink, read by openLink.
    private var fixURL: URL?

    // Opens the dedicated Settings window; AppDelegate wires it to SettingsWindowController.show().
    var onOpenSettings: (() -> Void)?
    // Install one provider's hooks + jump to Bluetooth settings (setup lives in the Settings window now).
    var onInstallProviderHooks: ((String) -> Void)?
    var onOpenBluetooth: (() -> Void)?

    // Login-item + forget-device callbacks (issue #16); AppDelegate owns the side effects.
    var onToggleLoginItem: ((Bool) -> Void)?   // desired on/off; AppDelegate re-reads truth + calls setLoginItemState.
    var onForgetDevice: (() -> Void)?
    var onRetryPairing: (() -> Void)?          // in-app "try again" after a .pairingFailed escalation (issue #17).
    var onMenuWillOpen: (() -> Void)?          // accessory app: popoverWillShow is the reliable login-item refresh hook.
    var onApplyTickerEdit: (([TickerRow]) -> Void)?   // issue #92: editor commits the desired list; AppDelegate persists + pushes.
    var onOpenTickerEditor: (() -> Void)?             // issue #92: opens the dedicated ticker editor window.
    // Per-provider live toggles (design 2026-07-19); AppDelegate persists via ProviderSettings + calls setEnabled.
    var onSetProviderUsage: ((String, Bool) -> Void)?
    var onSetProviderBuddy: ((String, Bool) -> Void)?

    // Bundled custom chime; falls back to a system sound when run without the .app bundle (bare dev build).
    private let promptSound: NSSound? = {
        if let url = Bundle.main.url(forResource: "beacon-prompt", withExtension: "wav") {
            return NSSound(contentsOf: url, byReference: true)
        }
        return NSSound(named: "Glass")
    }()
    private let attentionSound: NSSound? = {
        if let url = Bundle.main.url(forResource: "beacon-attention", withExtension: "wav") {
            return NSSound(contentsOf: url, byReference: true)
        }
        return NSSound(named: "Submarine")
    }()
    private var promptSoundMuted: Bool {
        get { UserDefaults.standard.bool(forKey: "BeaconPromptSoundMuted") }
        set { UserDefaults.standard.set(newValue, forKey: "BeaconPromptSoundMuted") }
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        wireModel()
        buildPopover()
        installQuitShortcut()
        applyBarIcon()
    }

    // Forward the panel's intents to the public closures / internal methods. Weak captures: the controller
    // owns the model, so a strong capture here would be a retain cycle.
    private func wireModel() {
        model.onToggleMute = { [weak self] in self?.promptSoundMuted = self?.model.muted ?? false }
        model.onRequestLoginItem = { [weak self] on in self?.onToggleLoginItem?(on) }
        model.onInstallProviderHooks = { [weak self] id in self?.onInstallProviderHooks?(id) }
        model.onOpenBluetooth = { [weak self] in self?.onOpenBluetooth?() }
        model.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        model.onForget = { [weak self] in self?.onForgetDevice?() }
        model.onRetryPairing = { [weak self] in self?.onRetryPairing?() }
        model.onApplyTickerEdit = { [weak self] rows in self?.onApplyTickerEdit?(rows) }
        model.onOpenTickerEditor = { [weak self] in self?.onOpenTickerEditor?() }
        model.onOpenFixURL = { [weak self] in self?.openLink() }
        model.onQuit = { NSApp.terminate(nil) }
        model.onSetProviderUsage = { [weak self] id, on in self?.onSetProviderUsage?(id, on) }
        model.onSetProviderBuddy = { [weak self] id, on in self?.onSetProviderBuddy?(id, on) }
    }

    private func buildPopover() {
        popover.behavior = .transient
        popover.delegate = self
        // closeAndRun: dismiss the popover, then run the action. performClose animates asynchronously, so
        // an action that opens a modal/first-run window proceeds while the popover slides away behind it.
        let panel = HubPanel(model: model) { [weak self] action in
            self?.popover.performClose(nil)
            action()
        }
        let host = NSHostingController(rootView: panel)
        // Keep preferredContentSize tracking the SwiftUI intrinsic size; without this the popover gets a
        // stale/short height and positions itself too high, clipping the header off the top of the screen.
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
        }
    }

    // Accessory apps have no main menu, so ⌘Q has nowhere to bind. Install a minimal application menu with
    // Settings…/⌘, (design §2.3), the hooks-hint row (hidden until needed), Close Window/⌘W (so the new
    // real Settings window has the standard close shortcut, design §5 acceptance gate (e)), and Quit; every
    // key equivalent fires while the app is active (it is, after activate-on-show, and §9.1 additionally
    // makes it .regular while Settings is open).
    private func installQuitShortcut() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = appMenu.addItem(withTitle: "Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self   // MenubarController is not in the responder chain; nil target would silently no-op.

        let hint = NSMenuItem(title: "", action: #selector(openSettingsOnSources), keyEquivalent: "")
        hint.target = self
        hint.isHidden = true
        hooksHintItem = hint
        appMenu.addItem(hint)

        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Beacon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        NSApp.mainMenu = main
    }

    @objc private func openSettings() { onOpenSettings?() }

    // Opens Settings pre-steered at the Sources tab (design §2.3's "opens Settings on the Sources tab").
    // Pre-seeds the persisted tab selection, which SettingsRootView's @AppStorage picks up whether the
    // window is being built for the first time or was already alive -- see SettingsTabPersistence's doc
    // comment for why this goes through UserDefaults rather than a new AppDelegate-wired closure.
    @objc private func openSettingsOnSources() {
        SettingsTabPersistence.save(.sources)
        onOpenSettings?()
    }

    // Recomputed on every provider-toggle refresh (registration, live toggle, hooks install/refresh) so the
    // hint appears/disappears live rather than only at menu-open time.
    private func updateHooksHint(_ toggles: [ProviderToggle]) {
        guard let hint = hooksHintItem else { return }
        if let needy = MenubarHooksHint.providerNeedingSetup(toggles) {
            hint.title = "\(needy.label) hooks not installed \u{00B7} Set up"
            hint.isHidden = false
        } else {
            hint.isHidden = true
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)   // status-bar popover: SwiftUI controls need a key window
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // Render the RE-READ login-item truth (issue #16). requiresApproval keeps the toggle off but labels
    // the row so the user knows the toggle is pending their approval in System Settings.
    func setLoginItemState(_ status: LoginItemStatus) { model.loginItem = status }

    func setLink(_ link: Link) {
        self.link = link
        model.link = link
        // Two distinct fix remediations; the URL is stored so a single openLink serves both.
        switch link {
        case .bluetoothOff: fixURL = SettingsLinks.bluetooth
        case .unauthorized: fixURL = SettingsLinks.privacyBluetooth
        default:            fixURL = nil
        }
        applyBarIcon()
    }

    func setAlert(_ message: String?) { alert = message; model.alert = message; applyBarIcon() }
    func setBridgeAlert(_ message: String?) { bridgeAlert = message; model.bridgeAlert = message; applyBarIcon() }

    func setUsage(_ usage: Usage, notes: [UsageNote]) {
        model.usage = usage
        model.notes = notes
        model.lastSync = Date()
        model.now = Date()   // restamp so reset hints stay fresh even while the popover is open
    }

    // Rebuild the per-provider toggle cards (design 2026-07-19). Called on registration and on every live
    // toggle so the switches reflect the persisted ProviderSettings truth. Also drives the replacement
    // setup-hint row (design §2.3) live, since this fires on every hooks re-check/install, not just at
    // menu-open time.
    func setProviderToggles(_ toggles: [ProviderToggle]) {
        model.providers = toggles
        updateHooksHint(toggles)
    }

    // Global (non-provider) setup checks shown in the Settings window.
    func setBluetoothCheck(_ s: CheckState) { model.setupBluetooth = s }
    func setPairedCheck(_ s: CheckState) { model.setupPaired = s }

    func setTickerSync(_ status: TickerSyncStatus) { model.tickerSync = status }

    /// Seed the page editor: `ids` is the list currently on the device, ordered. Enabled pages come
    /// first in that order, then the rest of the catalog as unchecked options.
    func setPages(ids: [String], opts: [String: [String: String]] = [:]) {
        let rows = PageCatalog.editorRows(applied: ids).map {
            PageRow(id: $0.entry.id, title: $0.entry.title, detail: $0.entry.detail,
                    pinned: !$0.entry.removable, enabled: $0.enabled, opts: opts[$0.entry.id] ?? [:])
        }
        model.pageRows = rows
        model.appliedPageIDs = rows.filter(\.enabled).map(\.id)
        model.appliedPageOpts = Dictionary(uniqueKeysWithValues:
            rows.filter { $0.enabled && !$0.opts.isEmpty }.map { ($0.id, $0.opts) })
    }

    func setPageSync(_ text: String?) { model.pageSync = text }

    /// Seed the complication editor: `slots` is the assignment currently on the device (face id -> wire
    /// strings). Mirrors setPages: both the staged edit and the applied baseline start here.
    func setComps(_ slots: [String: [String]]) {
        model.compSlots = slots
        model.appliedCompSlots = slots
    }

    func setCompSync(_ text: String?) { model.compSync = text }
    func setTickerRows(_ rows: [TickerRow]) { model.tickerRows = rows }   // issue #92: seed the editor with the persisted list
    func setTickerSearch(_ search: @escaping (String, @escaping ([TickerCandidate]) -> Void) -> Void) {
        model.onSearchTickers = search
    }
    func setTickerValidate(_ validate: @escaping (TickerRow, @escaping (Bool, String?) -> Void) -> Void) {
        model.onValidateTicker = validate
    }

    // contentTintColor must be assigned (color OR nil) on EVERY call: AppKit only tints template images,
    // and a stale tint from a fault/working render would otherwise leak into a later neutral/connected one.
    private func applyBarIcon() {
        guard let button = statusItem.button else { return }

        // An active alert overrides the link state so it's visible without opening the panel.
        let symbol: String
        let tint: NSColor?
        let description: String
        if bridgeAlert != nil || alert != nil {
            symbol = "exclamationmark.triangle.fill"; tint = .systemRed; description = "Beacon: alert"
        } else {
            switch link {
            case .bluetoothOff:
                symbol = "exclamationmark.triangle.fill"; tint = .systemOrange; description = "Beacon: Bluetooth off"
            case .unauthorized:
                symbol = "exclamationmark.triangle.fill"; tint = .systemOrange; description = "Beacon: permission needed"
            case .unavailable:
                symbol = "exclamationmark.triangle.fill"; tint = .systemRed; description = "Beacon: Bluetooth unavailable"
            case .pairingFailed:
                // Orange (recoverable via "try again"), matching the bluetoothOff/unauthorized convention;
                // red is reserved for the bridge/alert safety surface.
                symbol = "exclamationmark.triangle.fill"; tint = .systemOrange; description = "Beacon: pairing failed"
            // Connectivity states share the connected color (nil => adaptive label color, fully visible in
            // dark mode); status is read off the glyph instead. Stripped beacon (slash) = not linked,
            // probing dot = handshaking, full beacon = linked.
            case .searching:
                symbol = "antenna.radiowaves.left.and.right.slash"; tint = nil; description = "Beacon: searching"
            case .connecting:
                symbol = "dot.radiowaves.left.and.right"; tint = nil; description = "Beacon: connecting"
            case .reconnecting:
                symbol = "dot.radiowaves.left.and.right"; tint = nil; description = "Beacon: reconnecting"
            case .connected:
                symbol = "antenna.radiowaves.left.and.right"; tint = nil; description = "Beacon: connected"
            }
        }

        button.title = ""
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
    }

    // Play even if the previous cue is still ringing (stop+play) so back-to-back prompts each sound.
    func playPromptSoundIfEnabled() {
        guard !promptSoundMuted else { return }
        promptSound?.stop()
        promptSound?.play()
    }
    func playAttentionSoundIfEnabled() { guard !promptSoundMuted else { return }; attentionSound?.stop(); attentionSound?.play() }

    private func openLink() {
        SettingsLinks.open(fixURL ?? SettingsLinks.fallback)
    }
}

extension MenubarController: NSPopoverDelegate {
    // accessory app: popoverWillShow is the reliable login-item refresh hook (mirrors the old menuWillOpen).
    func popoverWillShow(_ notification: Notification) {
        onMenuWillOpen?()
        model.now = Date()   // refresh reset hints between polls
    }
}
