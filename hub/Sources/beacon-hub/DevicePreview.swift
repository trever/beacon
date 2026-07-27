import SwiftUI
import BeaconHubKit

// A miniature of the Beacon panel for the page designer.
//
// HONEST SCOPE: this is a REPRESENTATION drawn in SwiftUI, not the device's own render. The device runs
// LVGL with its own fonts; nothing here shares code with it. It exists so the page list reads as pages
// rather than rows -- treat it as a wireframe, and the panel as the source of truth.
//
// Live where we can be: Agents and Home draw from the same session data the hub is already pushing. The
// device-plane pages (Chart, ICE, Markets) CANNOT be live -- the device fetches those over WiFi itself
// and the hub never sees the values -- so they are drawn with representative sample figures. Sonos is
// hub-plane (the hub will proxy the Sonos API once its provider lands), but that provider does not exist
// yet, so its sketch is sample data too -- not wired to a live model field, same honesty rule.
//
// FILE BOUNDARY (design SS6.1, plan WS-7): the device colour palette, the device's re-derived type scale,
// the bundled device faces and every per-page sketch live in DeviceGlass.swift, not here. This file keeps
// only the `DevicePreview` entry point -- it resolves domain data (`chartLabel`, `sonosRoom`) from
// `HubViewModel` and hands off to `DeviceGlassContent` (DeviceGlass.swift), but never reads a device
// token itself. This file's own device-palette reference count must stay at zero; that is the enforcement.

/// The 466x466 rounded-square panel, scaled to `size`. Callers wrap this in `DeviceGlassPanel`
/// (`DeviceGlass.swift`) for the bezel/shadow/selection ring -- this type only ever renders what the
/// device itself would show inside that frame.
struct DevicePreview: View {
    let pageID: String
    let model: HubViewModel
    var size: CGFloat = 210

    /// The instrument the chart page is configured to follow. Resolved from the ticker list so the card
    /// changes when you change the selection -- it used to say "S&P 500" whatever was picked, which made
    /// two different instruments look identical.
    private var chartLabel: String {
        let sym = model.pageRows.first { $0.id == "chart" }?.opts["sym"] ?? "sp500"
        if let t = model.tickerRows.first(where: { $0.id == sym }) {
            return t.name.isEmpty ? t.sym : t.name
        }
        return sym
    }

    /// The Sonos room this page is configured to follow, from the page's own `opts["room"]` -- mirrors
    /// how `chartLabel` resolves the chart's instrument from `opts["sym"]`. The room picker itself lives
    /// in PageDesignerView (owned elsewhere); this only reads whatever value has already been set.
    private var sonosRoom: String {
        model.pageRows.first { $0.id == "sonos" }?.opts["room"] ?? "Living Room"
    }

    var body: some View {
        DeviceGlassContent(pageID: pageID, size: size, chartLabel: chartLabel, sonosRoom: sonosRoom,
                            model: model)
    }
}
