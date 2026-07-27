import SwiftUI
import AppKit
import BeaconHubKit

// The device glass, both halves (design SS6, plan WS-7). WS-0 built only the FRAME below (the bezel, the
// corner geometry, the outside selection ring). WS-7 adds everything that goes inside it: `BeaconPalette`,
// the device's re-derived type scale, the bundled device faces, and every per-page sketch -- moved here
// from `DevicePreview.swift`, which now holds only the `DevicePreview` entry point (plan WS-7 step 1).
//
// The boundary this file sits on (design SS6.1): nothing OUTSIDE this file may read a device token, and
// nothing INSIDE it may read a hub token -- except `DeviceGlassPanel` itself, whose entire job is being
// that seam. It takes hub-side chrome decisions (the bezel, the shadow, the selection ring) and wraps
// device-side content supplied entirely by its caller; it has no opinion about what that content is.
// `DeviceGlassContent` at the bottom of this file is the OTHER seam: it takes domain data (`HubViewModel`,
// a resolved `chartLabel`/`sonosRoom` string) from `DevicePreview.swift` but never a hub style token, and
// is the only thing `DevicePreview.swift` itself is allowed to touch -- which is how that file gets to
// keep zero references to `BeaconPalette` while still rendering device content.

/// Geometry for the device panel's frame. `cornerRatio` and `safeInsetRatio` are the device panel's own
/// proportions (its corner is ~90/466 of its own size, not a hub radius token); `bezel` is the width of
/// the ring drawn around it.
enum GlassMetric {
    static let bezel: CGFloat = 3
    static let cornerRatio: CGFloat = 0.22
    static let safeInsetRatio: CGFloat = 40.0 / 466.0
}

/// The bezel colour is one of the few surfaces in the whole hub that deliberately does NOT use a system
/// colour (design SS6.2): its only job is separating the glass from the window behind it, which is an
/// appearance-dependent problem, not a system-chrome one. Note the inversion -- the bezel goes LIGHTER
/// than the glass in dark appearance, because a black-on-near-black panel with an even darker frame
/// around it disappears entirely.
enum GlassColor {
    static let bezel = HubDynamic.color(
        light: NSColor(srgbRed: CGFloat(0x10) / 255.0, green: CGFloat(0x10) / 255.0,
                       blue: CGFloat(0x10) / 255.0, alpha: 1),
        dark: NSColor(srgbRed: CGFloat(0x2E) / 255.0, green: CGFloat(0x2E) / 255.0,
                      blue: CGFloat(0x2E) / 255.0, alpha: 1))
}

/// Frames arbitrary device-glass content: the bezel ring, `shadow.card`, a rounded clip at the panel's
/// own corner ratio, and an OUTSIDE accent selection ring (design SS6.2). Selection changes the ring's
/// colour only, never its width, and the ring sits outside the bezel at `radius.card + 3` -- never
/// touching the glass, because hub state is drawn around device content, never on it. `Content` is
/// supplied entirely by the caller (WS-2, WS-3, WS-7); this type has no opinion about what is inside the
/// panel.
struct DeviceGlassPanel<Content: View>: View {
    let size: CGFloat
    let isSelected: Bool
    let content: Content

    init(size: CGFloat, isSelected: Bool = false, @ViewBuilder content: () -> Content) {
        self.size = size
        self.isSelected = isSelected
        self.content = content()
    }

    // The bezel's own corner radius is derived from the device panel's proportional corner (not from a
    // hub radius token) so a 3 pt-wide ring hugs a panel whose corner scales with `size`. The selection
    // ring, drawn further out, is the one place a fixed hub radius is correct instead (see `body`) --
    // that ring is hub chrome drawn OUTSIDE the panel, not part of the device's own proportions.
    var glassCornerRadius: CGFloat { size * GlassMetric.cornerRatio }
    var bezelCornerRadius: CGFloat { glassCornerRadius + GlassMetric.bezel }

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: glassCornerRadius, style: .continuous))
            .padding(GlassMetric.bezel)
            .background(GlassColor.bezel,
                        in: RoundedRectangle(cornerRadius: bezelCornerRadius, style: .continuous))
            .hubCardShadow()
            .overlay(
                RoundedRectangle(cornerRadius: HubRadius.card + 3, style: .continuous)
                    .strokeBorder(isSelected ? HubColor.accent : Color.clear, lineWidth: 2)
                    .padding(-3)
            )
    }
}

// MARK: - Device palette (design SS6.1)

// A miniature of the Beacon panel's own visual language, drawn in SwiftUI -- not the device's own render.
// The device runs LVGL with its own fonts; nothing here shares code with it. This is a REPRESENTATION,
// and the panel is the source of truth (`DevicePreview.swift`'s file header carries the fuller honesty
// note; it applies to everything below just as much as it did when this lived there).
enum BeaconPalette {
    static let bg = Color.black                                   // AMOLED off-pixels (DESIGN.md)
    static let ink = Color(red: 0.957, green: 0.953, blue: 0.937)   // #f4f3ef
    static let inkDim = Color(red: 0.455, green: 0.447, blue: 0.424) // #74726c
    static let accent = Color(red: 1.0, green: 0.290, blue: 0.169)   // #ff4a2b
    static let line = Color.white.opacity(0.14)
}

// MARK: - Device type scale (design SS6.1, plan WS-7 step 2)

/// The device's real text sizes (`firmware/src/ui/fonts/MANIFEST.md`'s role table), each expressed as a
/// fraction of the 466 px panel so a sketch drawn at any preview `size` reproduces the device's own
/// proportions instead of a designer's eyeballed guess. Four constants because the device has four text
/// sizes -- there is no fifth to invent, and this is what makes the preview checkable against the
/// firmware's `env:capture` output instead of merely plausible.
enum DeviceType {
    /// 15 px -- `DESIGN.md`'s font-mono role: eyebrows, data, codes, timestamps.
    static let mono: CGFloat = 15.0 / 466.0
    /// 18 px -- font-body role: headings, labels, list rows.
    static let body: CGFloat = 18.0 / 466.0
    /// 30 px -- font-display role at its smaller size: emphasized values that are not the screen's hero
    /// figure (a list row's own value, per `DESIGN.md`'s "label (body) + value (mono/display)").
    static let display: CGFloat = 30.0 / 466.0
    /// 84 px -- font-display role at its largest size: `DESIGN.md`'s "hero figures (clock, big %, track
    /// title)" -- the exact three roles `hero()` below is used for.
    static let hero: CGFloat = 84.0 / 466.0
}

// MARK: - Device fonts (design SS6.4, plan WS-7 step 5)

// Space Grotesk and JetBrains Mono, instanced to static wght=500 from the google/fonts (OFL) variable
// sources the firmware's own font pipeline is built from (`firmware/src/ui/fonts/MANIFEST.md`). Bundled
// as `hub/Resources/fonts/<Family>/<Family>-Medium.ttf` + that family's own `OFL.txt`, copied into the
// app bundle by `build-app.sh` and registered here.
//
// These are OFL-licensed ASSETS, not a code dependency -- CLAUDE.md's no-third-party-deps rule is about
// libraries linked into the build; a font file has no code, no build-system involvement and no API
// surface. (Ruled 2026-07-27 in the plan; noted here so nobody reads this file as relitigating that rule.)
//
// Instanced statics were chosen over shipping the upstream variable fonts: deterministic rendering,
// smaller, no CoreText variable-axis surprises, and they match the exact instance the firmware itself is
// built from -- the whole point of bundling real faces instead of drawing SF Pro at device proportions.

/// One of the two bundled device faces. `mono` pairs with `DeviceType.mono`; `sans` covers the other three
/// roles, because `DESIGN.md` uses the same Space Grotesk family for font-body AND font-display (only the
/// size differs, not the family).
enum DeviceFace {
    case sans   // Space Grotesk Medium
    case mono   // JetBrains Mono Medium

    /// The PostScript name the instanced TTF actually registers under (verified against the file's own
    /// `name` table -- see the WS-7 report). This is NOT the family's display name; CoreText/`NSFont`
    /// lookups by PostScript name are unambiguous where a family-name lookup could collide with an
    /// already-installed system copy of the same family.
    fileprivate var postScriptName: String {
        switch self {
        case .sans: return "SpaceGrotesk-Medium"
        case .mono: return "JetBrainsMonoRoman-Medium"
        }
    }

    /// The system-font substitute used only when the bundled face did not resolve (see
    /// `DeviceGlassFont.resolve` below) -- close in spirit (grotesque sans / monospace) but explicitly NOT
    /// the device's real face, so a registration failure reads as "slightly off" rather than invisible.
    fileprivate var fallbackDesign: Font.Design {
        switch self {
        case .sans: return .default
        case .mono: return .monospaced
        }
    }
}

/// Resolves and registers the device's bundled faces. `resolve` is the only thing sketches below call --
/// they never construct `Font.custom` themselves and never assume registration worked.
enum DeviceGlassFont {
    /// Registers every bundled TTF under `<bundle>/Contents/Resources/fonts/` into the process's font
    /// collection. Call once, before any glass view is built (`main.swift` does this before
    /// `NSApplication` even exists).
    ///
    /// `swift build`/`swift test` run the plain executable/test bundle, not `Beacon Hub.app` -- there is
    /// no `fonts/` directory to find, so this silently no-ops. That is expected and is exactly why
    /// `resolve` below re-checks CoreText itself on every call instead of trusting that this function
    /// succeeded: a font registered but not found must fail to a documented fallback, never render blank.
    static func registerBundledFonts() {
        guard let resourceURL = Bundle.main.resourceURL else { return }
        registerFonts(in: resourceURL.appendingPathComponent("fonts", isDirectory: true))
    }

    /// Registers every `.ttf` found (recursively) under `directory`. Split out from
    /// `registerBundledFonts()` above so tests can point it at the repo's own `hub/Resources/fonts/`
    /// directly -- `swift test` has no app bundle, so `Bundle.main` never has a `fonts/` resource to hand
    /// that function, and without this seam the "does registration actually work" half of the fallback
    /// contract would be untestable.
    static func registerFonts(in directory: URL) {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "ttf" {
            var unmanagedErr: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedErr)
            // A duplicate-registration error (e.g. a second launch in the same session re-registering the
            // same URL) is not a failure worth reporting -- `resolve` below is the actual proof the face
            // is usable, not this call returning true.
        }
    }

    /// The bundled face at `size`, or a documented system fallback if it did not resolve. Never trusts
    /// that `registerBundledFonts()` ran or succeeded -- it asks CoreText directly, every call, via
    /// `NSFont(name:size:)`: that is the assertion that the face actually resolved, not merely that
    /// registration was attempted. `weight` only affects the fallback path's synthesis; the bundled TTF is
    /// a single static instance (wght 500) and SwiftUI's `.weight(_:)` on a custom font asks CoreText for
    /// synthetic emphasis rather than a different file.
    static func resolve(_ face: DeviceFace, size: CGFloat, weight: Font.Weight = .medium) -> Font {
        guard NSFont(name: face.postScriptName, size: size) != nil else {
            return .system(size: size, weight: weight, design: face.fallbackDesign)
        }
        return .custom(face.postScriptName, size: size).weight(weight)
    }
}

// MARK: - Shared sketch bits

private func eyebrow(_ s: String, _ size: CGFloat) -> some View {
    Text(s.uppercased())
        .font(DeviceGlassFont.resolve(.mono, size: size * DeviceType.mono, weight: .semibold))
        .kerning(size * 0.006)
        .foregroundStyle(BeaconPalette.inkDim)
}

/// `DESIGN.md`'s "hero figures (clock, big %, track title)" -- the three call sites below (the Home
/// clock, the Chart/ICE placeholder figure, the Sonos track title) are exactly that list.
private func hero(_ s: String, _ size: CGFloat, color: Color = BeaconPalette.ink) -> some View {
    Text(s).font(DeviceGlassFont.resolve(.sans, size: size * DeviceType.hero))
        .foregroundStyle(color)
        .minimumScaleFactor(0.5).lineLimit(1)
}

// MARK: - Per-page sketches

private struct HomeSketch: View {
    let model: HubViewModel
    let size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: size * 0.028) {
            HStack(alignment: .firstTextBaseline, spacing: size * 0.02) {
                hero(clock, size)
                Text(meridiem).font(DeviceGlassFont.resolve(.sans, size: size * DeviceType.body))
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
                    Text(sessionLine).font(DeviceGlassFont.resolve(.sans, size: size * DeviceType.body))
                        .foregroundStyle(BeaconPalette.ink).lineLimit(1)
                    Text(sessionSub).font(DeviceGlassFont.resolve(.mono, size: size * DeviceType.mono))
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
            Text(label).font(DeviceGlassFont.resolve(.sans, size: size * DeviceType.body))
                .foregroundStyle(BeaconPalette.inkDim)
            Spacer()
            Text(value).font(DeviceGlassFont.resolve(.sans, size: size * DeviceType.display))
                .foregroundStyle(BeaconPalette.ink)
            Text(pct).font(DeviceGlassFont.resolve(.mono, size: size * DeviceType.mono))
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
                Text("no active sessions").font(DeviceGlassFont.resolve(.sans, size: size * DeviceType.body))
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
                    .font(DeviceGlassFont.resolve(.sans, size: size * DeviceType.body))
                    .foregroundStyle(BeaconPalette.ink).lineLimit(1)
                Text(detail?.msg ?? s.state.rawValue)
                    .font(DeviceGlassFont.resolve(.mono, size: size * DeviceType.mono))
                    .foregroundStyle(BeaconPalette.inkDim).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(s.state.rawValue.uppercased())
                .font(DeviceGlassFont.resolve(.mono, size: size * DeviceType.mono, weight: .semibold))
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
            Spacer(minLength: 0)
            ForEach(["Dec26", "Mar27"], id: \.self) { r in
                HStack {
                    Text(r).font(DeviceGlassFont.resolve(.mono, size: size * DeviceType.mono))
                        .foregroundStyle(BeaconPalette.inkDim)
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
                    Text(t.name.isEmpty ? t.sym : t.name)
                        .font(DeviceGlassFont.resolve(.sans, size: size * DeviceType.body))
                        .lineLimit(1)
                        .foregroundStyle(BeaconPalette.ink)
                    Spacer()
                    Text("--").font(DeviceGlassFont.resolve(.mono, size: size * DeviceType.mono))
                        .foregroundStyle(BeaconPalette.inkDim)
                }
            }
            if model.tickerRows.isEmpty {
                Text("no tickers configured")
                    .font(DeviceGlassFont.resolve(.sans, size: size * DeviceType.body))
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
            Text("Soundgarden").font(DeviceGlassFont.resolve(.sans, size: size * DeviceType.body))
                .foregroundStyle(BeaconPalette.inkDim)
            Text("Superunknown").font(DeviceGlassFont.resolve(.mono, size: size * DeviceType.mono))
                .foregroundStyle(BeaconPalette.inkDim)
            Spacer(minLength: 0)
            HStack(spacing: size * 0.02) {
                Circle().fill(BeaconPalette.accent).frame(width: size * 0.03, height: size * 0.03)
                Text("playing").font(DeviceGlassFont.resolve(.mono, size: size * DeviceType.mono))
                    .foregroundStyle(BeaconPalette.inkDim)
                Spacer()
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
                    Text(r).font(DeviceGlassFont.resolve(.sans, size: size * DeviceType.body))
                        .foregroundStyle(BeaconPalette.ink)
                    Spacer()
                    // DESIGN.md's own list-row spec calls this an "optional caret", not an icon -- a plain
                    // glyph in the device's own face is the faithful rendering; the device has a lucide
                    // subset, not SF Symbols (design SS6.3), so no symbol-font image belongs in here.
                    Text("\u{203A}").font(DeviceGlassFont.resolve(.sans, size: size * DeviceType.mono,
                                                                   weight: .semibold))
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
            // A drawn shape, not an SF Symbol (design SS6.3: the device has a lucide glyph subset, not SF
            // Symbols) -- a dashed square echoes the same "no data yet" dash language `ChartSketch`'s
            // placeholder line already uses, rather than borrowing a Mac icon the device could never draw.
            RoundedRectangle(cornerRadius: size * 0.03, style: .continuous)
                .strokeBorder(BeaconPalette.inkDim,
                              style: StrokeStyle(lineWidth: 1.5, dash: [size * 0.018, size * 0.018]))
                .frame(width: size * 0.22, height: size * 0.22)
            Text("no preview").font(DeviceGlassFont.resolve(.sans, size: size * DeviceType.body))
                .foregroundStyle(BeaconPalette.inkDim)
        }
    }
}

// MARK: - Entry-point content (the seam `DevicePreview.swift` is allowed to touch)

/// Renders one page's device-glass content: the panel's own black background and rounded clip, then the
/// page's sketch. The background is drawn HERE, inside the glass, rather than left to `DeviceGlassPanel`
/// -- that frame's clip is otherwise transparent, so a gap in a sketch would let hub chrome show through
/// behind it, the exact leak in reverse this whole workstream exists to close.
///
/// `DevicePreview.swift` is the only caller and supplies domain data only (`model`, plus `chartLabel` /
/// `sonosRoom` already resolved from it) -- never a hub style token, and it never reaches past this type
/// into `BeaconPalette`/`DeviceType`/`DeviceFace` directly. That is what keeps that file's own
/// `BeaconPalette` reference count at zero after the split.
struct DeviceGlassContent: View {
    let pageID: String
    let size: CGFloat
    let chartLabel: String
    let sonosRoom: String
    let model: HubViewModel

    private var inset: CGFloat { size * GlassMetric.safeInsetRatio }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * GlassMetric.cornerRatio, style: .continuous)
                .fill(BeaconPalette.bg)
            RoundedRectangle(cornerRadius: size * GlassMetric.cornerRatio, style: .continuous)
                .strokeBorder(BeaconPalette.line, lineWidth: 1)
            content
                .padding(inset)
                .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * GlassMetric.cornerRatio, style: .continuous))
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
