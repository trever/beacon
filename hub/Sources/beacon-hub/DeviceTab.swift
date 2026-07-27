import SwiftUI

// Device tab (design §3.4, plan §5): everything about THIS Beacon that has no page home -- Bluetooth
// pairing/forget, the shared ticker list, firmware version. Ticker-list placement here (rather than
// duplicated into the Markets and Chart page inspectors) is plan §13 item 6's provisional lean: one list
// serves both pages, so putting it inside either inspector would make the other page's dependency
// invisible. The Chart inspector (WS-3, PageDesignerView) keeps its own add-a-symbol picker, which still
// writes into this same shared list.
struct DeviceTab: View {
    @ObservedObject var model: HubViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HubSpace.xl) {
                connectionSection
                forgetSection
                tickerSection
                firmwareSection
            }
            .padding(HubSpace.xl)
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: HubSpace.m) {
            SectionHeader(title: "Connection", subtitle: "Bluetooth link to this Beacon")
            Card(padding: .rows) {
                VStack(spacing: 0) {
                    StatusRow(state: model.setupBluetooth, title: "Bluetooth") {
                        if model.setupBluetooth != .ok {
                            HubButton(title: "Open Settings") { model.onOpenBluetooth() }
                        }
                    }
                    RowSeparator(hasLeadingIcon: true)
                    StatusRow(state: model.setupPaired, title: "Device connected",
                              hint: "Power on the device; macOS will prompt to pair.") { EmptyView() }
                }
            }
        }
    }

    // MARK: - Forget / re-pair

    // CoreBluetooth cannot remove an OS-level bond (no API for it) -- this guidance text stays as-is, it
    // is not a WS-2 UI bug to "fix".
    private var forgetSection: some View {
        VStack(alignment: .leading, spacing: HubSpace.m) {
            SectionHeader(title: "Forget device", subtitle: "macOS owns the pairing, not the hub")
            Card {
                VStack(alignment: .leading, spacing: HubSpace.m) {
                    Text("In Bluetooth settings, click the info button next to Beacon, then choose \u{201C}Forget This Device.\u{201D} It reconnects on its own when back in range.")
                        .font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        HubButton(title: "Open Bluetooth & forget", kind: .primary) { model.onForget() }
                    }
                }
            }
        }
    }

    // MARK: - Tickers (issue #92; folds `TickerEditorWindowController` in the same way the page designer
    // folds into Pages -- one hub window total, design §3.4).

    private var tickerSection: some View {
        VStack(alignment: .leading, spacing: HubSpace.m) {
            SectionHeader(title: "Tickers", subtitle: "One shared list -- Markets and Chart both read from it")
            TickerEditorView(model: model)
        }
    }

    // MARK: - Firmware

    // No wire field carries a firmware version today (BeaconHubKit/Protocol.swift has none, and adding
    // one is a device-report change outside WS-2's file boundary) -- the on-device about screen
    // (firmware/src/ui/about_panel.cpp) shows it, but it never reaches the hub. Reporting "Not reported"
    // rather than inventing a value or silently dropping the row (plan §5 lists "firmware version" as
    // Device-tab content; see this agent's final report for the judgment call).
    private var firmwareSection: some View {
        VStack(alignment: .leading, spacing: HubSpace.m) {
            SectionHeader(title: "Firmware", subtitle: "This Beacon")
            Card {
                HStack {
                    Text("Version").font(HubType.body).foregroundStyle(HubColor.inkSecondary)
                    Spacer()
                    // Was `ink.tertiary` (~2.8:1, below the 4.5:1 floor) for genuine content (design §2.3,
                    // §8.1) -- moved to `ink.secondary`, then promoted again to `ink.primary` (WS-8): this
                    // VALUE is the row's entire answer to "what firmware version," with no other rendering
                    // anywhere -- exactly the sole-carrier case the WS-8 ruling narrows `ink.secondary` to
                    // exclude. "Version" (the field's own label, just above) stays `ink.secondary`: it is
                    // orientation, not the row's content.
                    Text("Not reported by this firmware build")
                        .font(HubType.body).foregroundStyle(HubColor.inkPrimary)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Light") {
    let m = HubViewModel(now: Date(timeIntervalSince1970: 1_733_800_000))
    m.setupBluetooth = .ok
    m.setupPaired = .ok
    return DeviceTab(model: m).frame(width: 720, height: 560)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    let m = HubViewModel(now: Date(timeIntervalSince1970: 1_733_800_000))
    m.setupBluetooth = .ok
    m.setupPaired = .ok
    return DeviceTab(model: m).frame(width: 720, height: 560)
        .preferredColorScheme(.dark)
}
#endif
