import SwiftUI

// The sidebar destinations (design SS4.1, plan SS1 "WS-1 -- window chrome"): Settings is one real window
// with a source-list sidebar now, not a toolbar of tabs. Pages/Sources/Device/General map onto the
// design's four tiers -- what the device shows, what produces the data it shows, this specific Beacon,
// and the hub app itself. A fifth destination (Firmware) is already specified in the OTA plan's Phase 0;
// that is the reason this is a sidebar rather than a toolbar (design SS4.2) -- five icon-over-label items
// is where the toolbar idiom starts to crowd, and a sidebar scrolls, labels destinations in full, and can
// carry per-destination status.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case pages, sources, device, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pages:   return "Pages"
        case .sources: return "Sources"
        case .device:  return "Device"
        case .general: return "General"
        }
    }

    var systemImage: String {
        switch self {
        case .pages:   return "square.grid.2x2"
        case .sources: return "antenna.radiowaves.left.and.right"
        case .device:  return "cpu"
        case .general: return "gearshape"
        }
    }
}

// Tab selection persistence (design SS4.1: "reopening lands where you left"). A plain UserDefaults key
// rather than routing through HubViewModel -- MenubarController's setup-hint row (and AppDelegate's ticker
// editor route) need to steer a settings window that may not be built yet, and the existing
// `onOpenSettings` closure AppDelegate wires takes no argument. `@AppStorage` observes this key however
// it's written -- including a plain `UserDefaults.standard.set` from another file -- so pre-seeding it
// before calling `onOpenSettings()` steers SettingsRootView whether the window is being built for the
// first time or was already alive and is only being reordered to front.
enum SettingsTabPersistence {
    static let key = "BeaconSettingsTab"
    static func save(_ tab: SettingsTab) { UserDefaults.standard.set(tab.rawValue, forKey: key) }
}

// The Settings window's root content (design SS4): a two-column `NavigationSplitView`, a source-list
// sidebar of destinations over one HubViewModel. Replaces the retired pill-style tab control -- that
// control's job is switching an inspector's facets, not a window's top-level destinations, and it cost the
// per-destination window title, toolbar participation, Cmd-1..Cmd-n, and a badge API that did not render
// on macOS' version of that control (design SS4.2). A literal bullet character once appended to the Pages
// title was the correct response to that: the badge API did not work, so the conclusion was that the API
// was the wrong choice, not that the workaround was a bug. A `List` row's content is ours outright, so the
// badge problem has a real fix now (design SS4.3) and the string hack is gone.
struct SettingsRootView: View {
    @ObservedObject var model: HubViewModel
    @AppStorage(SettingsTabPersistence.key) private var tabRaw: String = SettingsTab.pages.rawValue

    /// Installed by `SettingsWindowController` so the AppKit-owned `NSWindow` can follow SwiftUI state it
    /// has no other way to observe -- there is no `Scene`/`WindowGroup` here to do that automatically
    /// (design SS4.4, plan SS1 steps 3-4). Defaulted to no-ops so previews and tests can construct this
    /// view without a controller.
    var onTitleChange: (String) -> Void = { _ in }
    var onDirtyChange: (Bool) -> Void = { _ in }

    /// `List(selection:)` wants an `Optional` binding; the persisted raw value is not optional. A typed
    /// computed `Binding` rather than an inline ternary (plan SS1 trap 6, design SS9.2).
    private var selection: Binding<SettingsTab?> {
        Binding<SettingsTab?>(
            get: { SettingsTab(rawValue: tabRaw) ?? .pages },
            set: { newValue in tabRaw = (newValue ?? .pages).rawValue }
        )
    }

    private var selectedTab: SettingsTab { SettingsTab(rawValue: tabRaw) ?? .pages }

    /// Both staged-edit channels the Pages destination owns (design SS4.3): pages themselves and Home's
    /// complications, which live in the same destination (the complication editor is Home's page
    /// inspector). Either being dirty marks the one sidebar row that can show it today.
    private var isPagesDirty: Bool { model.pagesDirty || model.compsDirty }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onAppear {
            onTitleChange(selectedTab.title)
            onDirtyChange(isPagesDirty)
        }
        // Single-parameter `onChange(of:)` only -- the two-parameter `{ old, new in }` overload is
        // macOS 14 and this target is macOS 13 (design SS9.1, plan SS1 traps).
        .onChange(of: tabRaw) { _ in onTitleChange(selectedTab.title) }
        .onChange(of: isPagesDirty) { dirty in onDirtyChange(dirty) }
    }

    @ViewBuilder private var sidebar: some View {
        List(selection: selection) {
            ForEach(SettingsTab.allCases) { tab in
                sidebarRow(tab).tag(tab)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        .background(shortcutButtons)
    }

    /// design SS4.3: a 6 pt `state.warn` dot as a trailing element in the row's own `HStack`, shown
    /// REGARDLESS of selection -- the reverse of the retired toolbar badge. Under a toolbar the selected
    /// item sits in a strip you look at edge-on; under a sidebar the row is a persistent item in a column
    /// whose whole job is showing every destination's state at once, so a dot that vanished on click would
    /// read as inconsistent. `.badge(_:)` is deliberately not used even though it now renders: a badge
    /// communicates a count, and this is a boolean.
    @ViewBuilder
    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let dirty = tab == .pages && isPagesDirty
        let accessibilityText: String = dirty ? "Unsaved changes" : ""
        HStack(spacing: HubSpace.s) {
            Label(tab.title, systemImage: tab.systemImage)
            Spacer()
            if dirty {
                Circle()
                    .fill(HubColor.stateWarn)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityValue(accessibilityText)
    }

    /// Cmd-1..Cmd-4 (design SS4.4, plan SS1 step 7): hidden buttons inside the sidebar rather than
    /// main-menu items -- adding menu items means editing `MenubarController.swift`, which this workstream
    /// does not own. Firmware's Cmd-5 arrives with the OTA workstream (plan SS10.2).
    @ViewBuilder private var shortcutButtons: some View {
        ForEach(Array(SettingsTab.allCases.enumerated()), id: \.offset) { index, tab in
            Button("") { selection.wrappedValue = tab }
                .keyboardShortcut(shortcutKeys[index], modifiers: [.command])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private let shortcutKeys: [KeyEquivalent] = ["1", "2", "3", "4"]

    /// The frozen seam with WS-2 (plan SS1 contract C2): the Pages destination's body is exactly
    /// `PageDesignerView(model: model)` -- not wrapped, not padded, no header added here.
    @ViewBuilder private var detail: some View {
        switch selectedTab {
        case .pages:   PageDesignerView(model: model)
        case .sources: SourcesTab(model: model)
        case .device:  DeviceTab(model: model)
        case .general: GeneralTab(model: model)
        }
    }
}
