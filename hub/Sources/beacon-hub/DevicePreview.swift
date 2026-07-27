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

enum BeaconPalette {
    static let bg = Color.black                                   // AMOLED off-pixels (DESIGN.md)
    static let ink = Color(red: 0.957, green: 0.953, blue: 0.937)   // #f4f3ef
    static let inkDim = Color(red: 0.455, green: 0.447, blue: 0.424) // #74726c
    static let accent = Color(red: 1.0, green: 0.290, blue: 0.169)   // #ff4a2b
    static let line = Color.white.opacity(0.14)
}

/// The 466x466 rounded-square panel, scaled to `size`. The device insets content >= 40 px from the edge
/// (its corners are cut), so the preview reproduces that safe area proportionally. The corner radius is
/// eyeballed, not measured off the panel -- it reads as the right shape, but do not treat it as spec.
struct DevicePreview: View {
    let pageID: String
    let model: HubViewModel
    var size: CGFloat = 210

    /// 40 px of the device's 466 px panel.
    private var inset: CGFloat { size * (40.0 / 466.0) }

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
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(BeaconPalette.bg)
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(BeaconPalette.line, lineWidth: 1)
            content
                .padding(inset)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    @ViewBuilder private var content: some View {
        switch pageID {
        case "home":     HomeSketch(model: model, size: size)
        case "agents":   AgentsSketch(model: model, size: size)
        case "chart":    ChartSketch(size: size, label: chartLabel)
        case "ice":      IceSketch(size: size)
        case "markets":  MarketsSketch(model: model, size: size)
        case "sonos":    SonosSketch(size: size, room: sonosRoom)
        case "settings": SettingsSketch(size: size)
        default:         UnknownSketch(size: size)
        }
    }
}

// --- shared bits ---

private func eyebrow(_ s: String, _ size: CGFloat) -> some View {
    Text(s.uppercased())
        .font(.system(size: size * 0.042, weight: .semibold)).kerning(size * 0.006)
        .foregroundStyle(BeaconPalette.inkDim)
}

private func hero(_ s: String, _ size: CGFloat, color: Color = BeaconPalette.ink) -> some View {
    Text(s).font(.system(size: size * 0.135, weight: .medium)).foregroundStyle(color)
        .minimumScaleFactor(0.5).lineLimit(1)
}

// --- per-page sketches ---

private struct HomeSketch: View {
    let model: HubViewModel
    let size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.028) {
            HStack(alignment: .firstTextBaseline, spacing: size * 0.02) {
                hero(clock, size)
                Text(meridiem).font(.system(size: size * 0.05, weight: .medium))
                    .foregroundStyle(BeaconPalette.inkDim)
            }
            eyebrow(Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), size)
            Spacer(minLength: 0)
            // Device-plane values the hub never sees; shown as placeholders, not invented numbers.
            miniRow("S&P", "—.——", "", up: true)
            miniRow("D4 RIN", "—.——", "", up: true)
            Spacer(minLength: 0)
            HStack(spacing: size * 0.03) {
                Circle().fill(sessionColor).frame(width: size * 0.03, height: size * 0.03)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sessionLine).font(.system(size: size * 0.045, weight: .medium))
                        .foregroundStyle(BeaconPalette.ink).lineLimit(1)
                    Text(sessionSub).font(.system(size: size * 0.038))
                        .foregroundStyle(BeaconPalette.inkDim).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var clock: String { Date().formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()) }
    private var meridiem: String { Calendar.current.component(.hour, from: Date()) < 12 ? "AM" : "PM" }
    private var newest: Session? { model.sessions.first }
    private var sessionColor: Color {
        switch newest?.state {
        case .attention, .question: return BeaconPalette.accent
        case .working:              return BeaconPalette.ink
        default:                    return BeaconPalette.inkDim
        }
    }
    private var sessionLine: String { newest.map { $0.label } ?? "no active sessions" }
    private var sessionSub: String {
        guard let s = newest else { return "" }
        return s.state.rawValue
    }

    private func miniRow(_ label: String, _ value: String, _ pct: String, up: Bool) -> some View {
        HStack {
            Text(label).font(.system(size: size * 0.04)).foregroundStyle(BeaconPalette.inkDim)
            Spacer()
            Text(value).font(.system(size: size * 0.048, weight: .medium)).foregroundStyle(BeaconPalette.ink)
            Text(pct).font(.system(size: size * 0.038))
                .foregroundStyle(up ? BeaconPalette.ink : BeaconPalette.accent)
        }
    }
}

private struct AgentsSketch: View {
    let model: HubViewModel
    let size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.03) {
            eyebrow("Agents", size)
            if model.sessions.isEmpty {
                Spacer()
                Text("no active sessions").font(.system(size: size * 0.05))
                    .foregroundStyle(BeaconPalette.inkDim)
                Spacer()
            } else {
                ForEach(model.sessions.prefix(4), id: \.id) { s in
                    row(s)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ s: Session) -> some View {
        let attn = s.state == .attention || s.state == .question
        let detail = model.sessionDetails.first { $0.id == s.id }
        let head = [detail?.project, detail?.title].compactMap { $0 }.joined(separator: " - ")
        return HStack(alignment: .top, spacing: size * 0.025) {
            Rectangle().fill(attn ? BeaconPalette.accent : BeaconPalette.inkDim)
                .frame(width: 1.5, height: size * 0.075)
            VStack(alignment: .leading, spacing: 1) {
                Text(head.isEmpty ? s.label : head)
                    .font(.system(size: size * 0.044, weight: .medium))
                    .foregroundStyle(BeaconPalette.ink).lineLimit(1)
                Text(detail?.msg ?? s.state.rawValue)
                    .font(.system(size: size * 0.036))
                    .foregroundStyle(BeaconPalette.inkDim).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(s.state.rawValue.uppercased())
                .font(.system(size: size * 0.032, weight: .semibold))
                .foregroundStyle(attn ? BeaconPalette.accent : BeaconPalette.inkDim)
        }
    }
}

private struct ChartSketch: View {
    let size: CGFloat
    let label: String
    /// Shape only. Intraday series are fetched by the DEVICE and never reach the hub, so there is no
    /// real line to draw -- the figures are struck out as a sample rather than shown as if live, which
    /// previously made two different instruments look like the same chart.
    private let pts: [CGFloat] = [0.42, 0.38, 0.5, 0.46, 0.58, 0.55, 0.66, 0.62, 0.74, 0.7, 0.82, 0.86]
    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.02) {
            eyebrow(label, size)
            hero("—.——", size, color: BeaconPalette.inkDim)
            Text("sample shape · live on device").font(.system(size: size * 0.036))
                .foregroundStyle(BeaconPalette.inkDim)
            Spacer(minLength: 0)
            GeometryReader { geo in
                Path { p in
                    for (i, v) in pts.enumerated() {
                        let x = geo.size.width * CGFloat(i) / CGFloat(pts.count - 1)
                        let y = geo.size.height * (1 - v)
                        i == 0 ? p.move(to: .init(x: x, y: y)) : p.addLine(to: .init(x: x, y: y))
                    }
                }
                .stroke(BeaconPalette.inkDim, style: .init(lineWidth: 1.5, lineJoin: .round,
                                                          dash: [size * 0.02, size * 0.02]))
            }
            .frame(height: size * 0.30)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IceSketch: View {
    let size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.022) {
            eyebrow("D4 RIN", size)
            hero("—.——", size, color: BeaconPalette.inkDim)
            Text("live on device").font(.system(size: size * 0.036))
                .foregroundStyle(BeaconPalette.inkDim)
            Spacer(minLength: 0)
            ForEach(["Dec26", "Mar27"], id: \.self) { r in
                HStack {
                    Text(r).font(.system(size: size * 0.038)).foregroundStyle(BeaconPalette.inkDim)
                    Spacer()
                }
                Rectangle().fill(BeaconPalette.line).frame(height: 0.5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarketsSketch: View {
    let model: HubViewModel
    let size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.018) {
            eyebrow("Markets", size)
            // The symbols ARE known to the hub (it owns the ticker list); the prices are not.
            ForEach(Array(model.tickerRows.prefix(6).enumerated()), id: \.offset) { _, t in
                HStack {
                    Text(t.name.isEmpty ? t.sym : t.name).font(.system(size: size * 0.04, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(BeaconPalette.ink)
                    Spacer()
                    Text("--").font(.system(size: size * 0.04)).foregroundStyle(BeaconPalette.inkDim)
                }
            }
            if model.tickerRows.isEmpty {
                Text("no tickers configured").font(.system(size: size * 0.04))
                    .foregroundStyle(BeaconPalette.inkDim)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SonosSketch: View {
    let size: CGFloat
    let room: String
    /// Text only in phase 1 -- no album art (`docs/specs/2026-07-26-hub-as-controller-and-sonos-design.md`
    /// §3: a BLE tile transport is 15-30 s per track change, so art waits on a phase-2 hub-served LAN
    /// URL). The hub proxies live playback once its Sonos provider lands (out of scope here); until then
    /// this is a representative sample, same honesty rule as the device-plane sketches above -- it is not
    /// wired to any live model field.
    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.024) {
            eyebrow(room, size)
            hero("Black Hole Sun", size)
            Text("Soundgarden").font(.system(size: size * 0.05)).foregroundStyle(BeaconPalette.inkDim)
            Text("Superunknown").font(.system(size: size * 0.038)).foregroundStyle(BeaconPalette.inkDim)
            Spacer(minLength: 0)
            HStack(spacing: size * 0.02) {
                Circle().fill(BeaconPalette.accent).frame(width: size * 0.03, height: size * 0.03)
                Text("playing").font(.system(size: size * 0.036)).foregroundStyle(BeaconPalette.inkDim)
                Spacer()
                Text("sample · live once connected").font(.system(size: size * 0.03))
                    .foregroundStyle(BeaconPalette.inkDim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSketch: View {
    let size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.03) {
            eyebrow("Settings", size)
            ForEach(["Brightness", "Theme", "Auto-rotate", "Sleep"], id: \.self) { r in
                HStack {
                    Text(r).font(.system(size: size * 0.042)).foregroundStyle(BeaconPalette.ink)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: size * 0.032))
                        .foregroundStyle(BeaconPalette.inkDim)
                }
                Rectangle().fill(BeaconPalette.line).frame(height: 0.5)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct UnknownSketch: View {
    let size: CGFloat
    var body: some View {
        VStack(spacing: size * 0.03) {
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: size * 0.12)).foregroundStyle(BeaconPalette.inkDim)
            Text("no preview").font(.system(size: size * 0.04)).foregroundStyle(BeaconPalette.inkDim)
        }
    }
}
