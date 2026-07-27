import SwiftUI

// The four-tab IA (design §2.2/§3.1, plan §5): Settings is one real window now, not a flat panel plus two
// more windows. Pages/Sources/Device/General map onto the design's four tiers -- what the device shows,
// what produces the data it shows, this specific Beacon, and the hub app itself.
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

// Tab selection persistence (design §2.2: "reopening lands where you left"). A plain UserDefaults key
// rather than routing through HubViewModel -- MenubarController's replacement setup-hint row (§2.3) needs
// to steer a NOT-YET-BUILT settings window at a specific tab, and the existing `onOpenSettings` closure
// AppDelegate already wires takes no argument (WS-2 is not authorized to add AppDelegate plumbing beyond
// deleting the two retired window controllers, plan §5 "Files to edit"). `@AppStorage` observes this key
// however it's written -- including a plain `UserDefaults.standard.set` from MenubarController -- so
// pre-seeding it before calling `onOpenSettings()` steers SettingsRootView whether the window is being
// built for the first time or was already alive and is only being reordered to front.
enum SettingsTabPersistence {
    static let key = "BeaconSettingsTab"
    static func save(_ tab: SettingsTab) { UserDefaults.standard.set(tab.rawValue, forKey: key) }
}

// The Settings window's root content: toolbar-style tabs (via SwiftUI's native TabView, which renders the
// same top pill-style bar System Settings uses) over one HubViewModel. Design §2.4 rejects the `Settings`
// SCENE (it forces a fixed-size, non-resizable preferences look) -- that is unrelated to using `TabView` as
// plain content inside our own resizable NSWindow, which is what this is.
struct SettingsRootView: View {
    @ObservedObject var model: HubViewModel
    @AppStorage(SettingsTabPersistence.key) private var tabRaw: String = SettingsTab.pages.rawValue

    private var tab: Binding<SettingsTab> {
        Binding(get: { SettingsTab(rawValue: tabRaw) ?? .pages },
                set: { tabRaw = $0.rawValue })
    }

    // The frozen seam with WS-3 (plan §5): the Pages tab body is exactly `PageDesignerView(model: model)`.
    // `.tabItem`/`.tag` are TabView-level annotations, not additional body content, so this holds.
    var body: some View {
        TabView(selection: tab) {
            PageDesignerView(model: model)
                .tabItem { Label(pagesTabTitle, systemImage: SettingsTab.pages.systemImage) }
                .tag(SettingsTab.pages)

            SourcesTab(model: model)
                .tabItem { Label(SettingsTab.sources.title, systemImage: SettingsTab.sources.systemImage) }
                .tag(SettingsTab.sources)

            DeviceTab(model: model)
                .tabItem { Label(SettingsTab.device.title, systemImage: SettingsTab.device.systemImage) }
                .tag(SettingsTab.device)

            GeneralTab(model: model)
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.systemImage) }
                .tag(SettingsTab.general)
        }
    }

    // Dirty badge (plan §5 "What to build"): staged Pages OR Home-complication edits both live under this
    // one tab now (the complication editor is Home's page inspector, design §3.2), so either being dirty
    // marks it. A literal bullet appended to the title, not `.badge(_:)` -- macOS's TabView badge support
    // is iOS-first and not reliably visible on the desktop tab bar, and this cannot silently fail to render.
    private var pagesTabTitle: String {
        (model.pagesDirty || model.compsDirty) ? "\(SettingsTab.pages.title) \u{2022}" : SettingsTab.pages.title
    }
}
