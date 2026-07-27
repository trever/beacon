import AppKit
import SwiftUI
import BeaconHubKit

// Observable backing store for the SwiftUI HubPanel. MenubarController owns one of these and writes its
// setters into the @Published fields; the panel re-renders. The view never reaches back into AppKit
// business logic -- it calls the intent closures, which MenubarController wires to its own public
// closures / methods. Main-actor only (AppDelegate already marshals every callback onto @MainActor).
// Ack-driven ticker push status (issue #92). idle = nothing pushed yet; pending = chunks sent, awaiting
// the device's config_ack; synced(count) = device applied N rows; error(reason) = device rejected.
enum TickerSyncStatus: Equatable { case idle, pending, synced(Int), error(String) }

// Per-check state for setup rows. checking = neutral glyph until the first read resolves it, so we never
// flash a failed state before it's known. Shared by the global connection checks and per-provider hooks.
enum CheckState: Equatable { case checking, ok, bad }

// One provider's settings-row state (design 2026-07-19, extended 2026-07-20). Capabilities gate which
// toggles render; `hooks`/`installing`/`note` drive the per-provider setup line blended into the row.
// One row in the device-pages editor. Order in the array IS the device order; `enabled` decides whether
// the id is sent at all. `pinned` marks settings, which the device force-appends anyway -- showing it as
// removable would be a lie.
struct PageRow: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let pinned: Bool
    var enabled: Bool
    var opts: [String: String] = [:]
}

struct ProviderToggle: Identifiable, Equatable {
    let id: String
    let label: String
    let supportsUsage: Bool
    let supportsBuddy: Bool
    var usageOn: Bool
    var buddyOn: Bool
    var hooks: CheckState = .checking
    var installing: Bool = false
    var note: String? = nil
}

@MainActor
final class HubViewModel: ObservableObject {
    @Published var link: MenubarController.Link = .searching
    @Published var lastSync: Date?
    @Published var usage = Usage()   // provider array (design 2026-07-19); rendered as one card per entry
    @Published var notes: [UsageNote] = []   // #108: typed usage notes (info = rate-limited; error = banner)
    @Published var alert: String?          // undeliverable-prompt surface
    @Published var bridgeAlert: String?    // bridge bind failure; priority over alert
    @Published var loginItem: MenubarController.LoginItemStatus = .disabled
    @Published var muted: Bool
    @Published var now: Date
    @Published var tickerSync: TickerSyncStatus = .idle
    // Global (non-provider) setup checks surfaced in the Settings window.
    @Published var setupBluetooth: CheckState = .checking
    @Published var setupPaired: CheckState = .checking
    @Published var dontShowOnStartup: Bool = false   // first-run auto-open suppression (BeaconFirstRunComplete)
    @Published var tickerRows: [TickerRow] = []   // issue #92: current desired list, seeds the B4 editor
    // One dynamic card per registered provider (design 2026-07-19): the Usage / Coding Buddy toggles the
    // menubar shows, each gated by the provider's declared capabilities. Backed by ProviderSettings.
    @Published var providers: [ProviderToggle] = []
    // Mirrors of what the hub last pushed, so the page designer's previews show real session content
    // rather than placeholders. Device-plane pages (chart/ICE/markets) cannot be mirrored -- the device
    // fetches those itself and the hub never sees the values.
    @Published var sessions: [Session] = []
    @Published var sessionDetails: [SessionDetail] = []
    @Published var pageRows: [PageRow] = []
    /// The list last known to be on the device; Apply is enabled only when pageRows differ from it.
    @Published var appliedPageIDs: [String] = []
    @Published var pageSync: String?          // transient status under the Apply button

    var enabledPageIDs: [String] { pageRows.filter(\.enabled).map(\.id) }
    var enabledPageOpts: [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: pageRows.filter { $0.enabled && !$0.opts.isEmpty }
                                                 .map { ($0.id, $0.opts) })
    }
    @Published var appliedPageOpts: [String: [String: String]] = [:]
    var pagesDirty: Bool { enabledPageIDs != appliedPageIDs || enabledPageOpts != appliedPageOpts }

    // Home's six-slot complication assignment (design §4). Face id -> wire strings ("clock",
    // "fin.sp500", ...) -- the same raw shape ComplicationStore persists, so WS-3's editor and
    // AppDelegate never have to translate between two representations.
    @Published var compSlots: [String: [String]] = [:]
    /// The assignment last known to be on the device; Apply is enabled only when compSlots differs.
    @Published var appliedCompSlots: [String: [String]] = [:]
    @Published var compSync: String?          // transient status under the Apply button
    var compsDirty: Bool { compSlots != appliedCompSlots }

    // Intent closures, populated by MenubarController (weakly, so VM<->controller is not a retain cycle).
    var onToggleMute: () -> Void = {}
    var onRequestLoginItem: (Bool) -> Void = { _ in }   // desired on/off; truth re-read async
    var onForget: () -> Void = {}
    var onOpenSettings: () -> Void = {}          // opens the dedicated Settings window (from the popover)
    var onOpenBluetooth: () -> Void = {}         // jump to System Settings > Bluetooth
    var onInstallProviderHooks: (String) -> Void = { _ in }   // install the named provider's hooks
    var onToggleDontShow: (Bool) -> Void = { _ in }           // persist first-run auto-open suppression
    var onRetryPairing: () -> Void = {}
    var onApplyPages: ([String], [String: [String: String]]) -> Void = { _, _ in }   // push (restarts device)
    var onRevertPages: () -> Void = {}                // discard staged edits, back to what the device runs
    var onOpenPages: () -> Void = {}                  // open the page designer window
    var onApplyComps: ([String: [String]]) -> Void = { _ in }   // push (applies live, no restart)
    var onRevertComps: () -> Void = {}                // discard staged edits, back to what the device runs
    var onApplyTickerEdit: ([TickerRow]) -> Void = { _ in }   // issue #92: B4 editor commits the desired list
    var onOpenTickerEditor: () -> Void = {}                    // issue #92: open the dedicated editor window
    // issue #92: editor calls this with a query; AppDelegate runs Binance(local) + Yahoo(live) and delivers
    // the merged candidates on the main actor. The closure does not retain results; the editor owns them.
    var onSearchTickers: ((String, @escaping ([TickerCandidate]) -> Void) -> Void)?
    // issue #92: editor calls this before adding a candidate; AppDelegate test-fetches the device's data
    // endpoint and delivers (ok, failureReason) on the main actor so non-working symbols are rejected.
    var onValidateTicker: ((TickerRow, @escaping (Bool, String?) -> Void) -> Void)?
    var onOpenFixURL: () -> Void = {}
    var onQuit: () -> Void = {}
    var onSetProviderUsage: (String, Bool) -> Void = { _, _ in }   // provider id, desired on/off (live)
    var onSetProviderBuddy: (String, Bool) -> Void = { _, _ in }

    // `now` seeded once; refreshed on poll + popover open so reset hints stay fresh. `muted` seeded from
    // the same UserDefaults key the controller persists, so the first render matches the real state.
    init(now: Date = Date(), muted: Bool = UserDefaults.standard.bool(forKey: "BeaconPromptSoundMuted")) {
        self.now = now
        self.muted = muted
    }
}
