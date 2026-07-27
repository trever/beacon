import SwiftUI
import BeaconHubKit

// The Hub Deck panel (design 4A): a Control-Center-style surface hosted in the status-bar NSPopover.
// Pure presentation over HubViewModel -- it maps link/usage state to native controls and calls the
// view model's intent closures. Semantic decisions (level, fill fraction, reset form) come from
// BeaconHubKit; this view only turns them into colors, localized strings, and layout.
//
// WS-6 (2026-07-27-hub-visual-system-plan.md SS"WS-6", design SS2/SS3/SS9): re-tokenised, not
// redesigned -- the same card stack, in the same order, now built from HubStyle/HubRows/HubSurfaces.
// `ProviderCard`'s `.accessibilityElement(children: .combine)` is the VoiceOver template the plan names
// explicitly; it is kept and its pattern is propagated, never deleted. This is the one surface rendered
// inside an `NSPopover`'s vibrancy material rather than an opaque window (design SS9.3), which is exactly
// why every fill below goes through `HubColor`'s `NSColor`-backed dynamic providers instead of a raw
// opacity or an `@Environment(\.colorScheme)` branch -- that is what composites correctly over vibrancy.
// The popover root below declares the one permitted fixed width (340) and nothing beneath it declares
// `.infinity` width or a fixed height, per the `sizingOptions = [.preferredContentSize]` contract in
// MenubarController.swift (untouched by this file).
struct HubPanel: View {
    @ObservedObject var model: HubViewModel
    var closeAndRun: (@escaping () -> Void) -> Void   // dismiss the popover, then run the action

    var body: some View {
        VStack(spacing: HubSpace.m) {
            if let banner = model.bridgeAlert ?? model.alert.map({ "\($0) — couldn't show prompt" }) {
                Card(padding: .rows) {
                    StatusRow(state: .error, title: banner) { EmptyView() }
                }
            }
            HeaderModule(model: model, closeAndRun: closeAndRun)
            if !model.notes.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: HubSpace.xs) {
                        ForEach(model.notes, id: \.text) { note in
                            // The glyph carries the state colour; the word stays `ink.primary` -- design
                            // SS2.3's "state is never colour alone", same rule `StatusRow` enforces.
                            HStack(spacing: HubSpace.s) {
                                Image(systemName: note.severity == .error
                                          ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                                    .foregroundStyle(note.severity == .error ? HubColor.stateError : HubColor.inkSecondary)
                                Text(note.text).foregroundStyle(HubColor.inkPrimary)
                            }
                            .font(HubType.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !model.usage.providers.isEmpty {
                HStack(spacing: HubSpace.l) {
                    ForEach(model.usage.providers, id: \.id) { entry in
                        ProviderCard(entry: entry, now: model.now)
                    }
                }
            }
            TogglesModule(model: model)
            ActionBar(model: model, closeAndRun: closeAndRun)
        }
        .padding(HubSpace.m)
        .frame(width: 340)
    }
}

// MARK: - Header

private struct HeaderModule: View {
    @ObservedObject var model: HubViewModel
    var closeAndRun: (@escaping () -> Void) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: HubSpace.s) {
                HStack(spacing: HubSpace.m) {
                    ZStack {
                        // No `Color.blue` / `Color.white` (design SS7): a solid `accent` fill with the
                        // glyph in `HubColor.inkOnAccent` -- the on-accent foreground token this workstream
                        // added to close the shared-layer gap the old badge worked around by using a soft
                        // `fillSelected` tint plus an accent-coloured glyph instead of a real filled badge.
                        // `inkOnAccent` resolves per-accent and per-appearance itself, so this is not the
                        // fixed-white glyph design SS7 flags as wrong for a yellow or graphite accent.
                        Circle().fill(HubColor.accent).frame(width: 30, height: 30)
                        Image(systemName: "wave.3.right").font(HubType.section).foregroundStyle(HubColor.inkOnAccent)
                    }
                    VStack(alignment: .leading, spacing: HubSpace.hair) {
                        Text(deviceName).font(HubType.section).foregroundStyle(HubColor.inkPrimary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(statusText).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
                            .lineLimit(1)
                        Text(syncText).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if isConnected {
                        Circle().fill(HubColor.stateOk).frame(width: 8, height: 8)
                    }
                }
                if showPairingHint {
                    Text("Pair: enter the code shown on the device")
                        .font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
                }
                // `LinkButton` -> `HubButton` (plan WS-6): the icon is dropped -- `HubButton` has no icon
                // slot, matching the shared vocabulary's "button titles are text" rule (design SS2.2) --
                // but the description stays fully legible as button text rather than a bare tinted link.
                // Shared-layer gap #3 considered adding an icon+text `HubButton` mode for this, but this is
                // the ONLY call site in the product that ever had an icon here, so a mode nobody else needs
                // stays out (see this workstream's final report).
                if let fix = fixLabel {
                    HubButton(title: fix, kind: .secondary) { closeAndRun(model.onOpenFixURL) }
                }
                if case .pairingFailed = model.link {
                    HubButton(title: "Try pairing again", kind: .secondary) { closeAndRun(model.onRetryPairing) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var deviceName: String {
        switch model.link {
        case .connected(let n), .connecting(let n): return n
        default: return "Beacon"
        }
    }
    private var isConnected: Bool { if case .connected = model.link { return true }; return false }
    private var statusText: String {
        switch model.link {
        case .bluetoothOff:      return "Bluetooth is off"
        case .unauthorized:      return "Bluetooth permission needed"
        case .unavailable:       return "Bluetooth unavailable"
        case .searching:         return "Searching for device…"
        case .connecting(let n): return "Connecting to \(n)…"
        case .connected:         return "Connected"
        case .reconnecting:      return "Disconnected — reconnecting"
        case .pairingFailed:     return "Pairing failed"
        }
    }
    private var syncText: String {
        guard let last = model.lastSync else { return "Last sync: never" }
        return "Last sync: \(Self.time.string(from: last))"
    }
    private var showPairingHint: Bool {
        switch model.link {
        case .searching, .connecting, .pairingFailed: return true
        default: return false
        }
    }
    private var fixLabel: String? {
        switch model.link {
        case .bluetoothOff: return "Open Bluetooth settings…"
        case .unauthorized: return "Open Privacy settings…"
        default:            return nil
        }
    }

    static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()
}

// MARK: - Usage

private struct ProviderCard: View {
    let entry: UsageEntry
    let now: Date

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: HubSpace.s) {
                HStack(spacing: HubSpace.xs) {
                    Text(entry.label).font(HubType.section).foregroundStyle(HubColor.inkPrimary)
                        .lineLimit(1)
                    if entry.stale == true {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(HubType.caption).foregroundStyle(HubColor.inkSecondary)
                    }
                }
                WindowRow(label: "5h", window: entry.h5, now: now)
                WindowRow(label: "7d", window: entry.d7, now: now)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The VoiceOver template the plan names explicitly (design SS8) -- kept verbatim, and the pattern
        // (one accessibility element, a label, a composed value) is what `TogglesModule`/`ActionBar` below
        // follow too rather than reinventing their own.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.label)
        .accessibilityValue(summary)
    }

    private var summary: String {
        func part(_ unit: String, _ w: UsageWindow) -> String {
            let pct = w.pct.map { "\($0) percent" } ?? "unavailable"
            let reset = WindowRow.resetText(w.reset, now: now)
            return reset.isEmpty ? "\(unit) \(pct)" : "\(unit) \(pct), \(reset)"
        }
        return "\(part("5 hour", entry.h5)); \(part("7 day", entry.d7))."
    }
}

// `WindowRow` isn't one of the ten settings-style rows the shared `SettingsRow`/`StatusRow`/`ListRow`
// triad replaces (plan SS7.3) -- it is a usage-figure-plus-progress-bar visualisation, a different kind
// of content entirely, so it stays a local type. What DOES change is its typography: the big percentage
// now reads through `HubType.figure` (plan WS-6 trap 2) and everything else through the shared roles.
private struct WindowRow: View {
    let label: String
    let window: UsageWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: HubSpace.xs) {
            HStack {
                Text(label).font(HubType.caption).foregroundStyle(HubColor.inkSecondary).lineLimit(1)
                Spacer()
                Text(Self.resetText(window.reset, now: now))
                    .font(HubType.caption).foregroundStyle(HubColor.inkSecondary).lineLimit(1)
            }
            // `type.figure` is a `.title` text style, so it scales with the system text-size setting
            // inside a fixed 340 pt popover holding two `ProviderCard`s side by side (plan WS-6 trap 2).
            // `lineLimit(1)` + `minimumScaleFactor(0.7)` keep "100%" from clipping at the largest text
            // size rather than exempting this site from the token.
            Text(pctText)
                .font(HubType.figure)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(color ?? HubColor.inkSecondary)
            LevelBar(fraction: usageFillFraction(window.pct), color: color)
        }
    }

    private var color: Color? { Self.color(usageLevel(window.pct)) }
    private var pctText: String { window.pct.map { "\($0)%" } ?? "--" }

    static func color(_ level: UsageLevel) -> Color? {
        switch level {
        case .unavailable: return nil
        case .normal:      return HubColor.stateOk
        case .elevated:    return HubColor.stateWarn
        case .critical:    return HubColor.stateError
        }
    }

    // Localized reset hint, matching the old UsageRowView: "resets 9:40 AM" within 24h, "resets Mon" beyond.
    static func resetText(_ reset: Int, now: Date) -> String {
        switch resetDisplay(reset: reset, now: now) {
        case .none:           return ""
        case .time(let d):    return "resets \(time.string(from: d))"
        case .weekday(let d): return "resets \(weekday.string(from: d))"
        }
    }
    static let time: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f }()
    static let weekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
}

private struct LevelBar: View {
    let fraction: Double
    let color: Color?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(HubColor.fillControl)
                if fraction > 0, let color {
                    Capsule().fill(color).frame(width: max(2, geo.size.width * fraction))
                }
            }
        }
        .frame(height: 4)
    }
}

// MARK: - Toggles

private struct TogglesModule: View {
    @ObservedObject var model: HubViewModel

    var body: some View {
        Card(padding: .rows) {
            VStack(spacing: 0) {
                SettingsRow(icon: "speaker.slash.fill", title: "Mute prompt sound") {
                    Toggle("", isOn: muteBinding).labelsHidden().toggleStyle(.switch)
                }
                // The derived separator rule (design SS2.4): both rows have a leading icon column, so the
                // inset is `space.m + iconColumn + space.m` = 44, not the ad-hoc 12 the old literal used.
                RowSeparator(hasLeadingIcon: true)
                SettingsRow(icon: "person.fill", title: "Start at login",
                            subtitle: model.loginItem == .requiresApproval ? "Approve in Login Items" : nil) {
                    Toggle("", isOn: loginBinding).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    private var muteBinding: Binding<Bool> {
        Binding(get: { model.muted }, set: { model.muted = $0; model.onToggleMute() })
    }
    // No optimistic flip: request the opposite of the re-read truth; the UI only changes when
    // setLoginItemState writes back model.loginItem (ad-hoc signing can land on .requiresApproval).
    private var loginBinding: Binding<Bool> {
        Binding(get: { model.loginItem == .enabled }, set: { _ in model.onRequestLoginItem(model.loginItem != .enabled) })
    }
}

// MARK: - Actions

private struct ActionBar: View {
    @ObservedObject var model: HubViewModel
    var closeAndRun: (@escaping () -> Void) -> Void

    var body: some View {
        HStack(spacing: HubSpace.s) {
            actionItem(icon: "chart.line.uptrend.xyaxis", label: "Tickers…") {
                closeAndRun(model.onOpenTickerEditor)
            }
            actionItem(icon: "gearshape", label: "Settings…") {
                closeAndRun(model.onOpenSettings)
            }
            actionItem(icon: "power", label: "Quit Beacon", tint: HubColor.stateError) {
                closeAndRun(model.onQuit)
            }
        }
    }

    // `ActionButton` -> `IconButton` (plan WS-6): `IconButton`'s `label` parameter is non-optional, which
    // is what makes "the button is labelled" structural rather than something a call site can skip. The
    // caption below is additive -- it keeps the row's three actions visually named, exactly as they are
    // today -- and is hidden from the accessibility tree so VoiceOver reads `IconButton`'s own label once,
    // not the icon and the caption both. `IconButton` now takes `tint` (shared-layer gap #2, closed), so
    // `tint` here reaches the icon itself as well as the caption -- "Quit Beacon" is `state.error` red on
    // both, not just the caption underneath it.
    //
    // This vertical icon-above-caption composition itself stays a local helper rather than a shared
    // component: it has exactly one file's worth of call sites (the three below), already built from
    // shared leaf pieces (`IconButton` + `Text`), and a shared type with one consumer is the thing design
    // SS0 warns against adding (shared-layer gap #3 -- see this workstream's final report).
    private func actionItem(icon: String, label: String, tint: Color = HubColor.inkSecondary,
                             action: @escaping () -> Void) -> some View {
        VStack(spacing: HubSpace.xs) {
            IconButton(systemImage: icon, label: label, tint: tint, action: action)
            Text(label).font(HubType.caption).foregroundStyle(tint).lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }
}

#if DEBUG
#Preview {
    let m = HubViewModel(now: Date(timeIntervalSince1970: 1_733_800_000))
    m.link = .connected("Beacon-8428")
    m.lastSync = Date(timeIntervalSince1970: 1_733_800_000)
    m.usage = Usage(providers: [
        UsageEntry(id: "claude", label: "CLAUDE",
                   h5: UsageWindow(pct: 2, reset: 1_733_820_000),
                   d7: UsageWindow(pct: 0, reset: 1_734_200_000)),
        UsageEntry(id: "codex", label: "CODEX",
                   h5: UsageWindow(pct: 1, reset: 1_733_821_000),
                   d7: UsageWindow(pct: 93, reset: 1_734_300_000), stale: true),
    ])
    m.providers = [
        ProviderToggle(id: "claude", label: "Claude", supportsUsage: true, supportsBuddy: true, usageOn: true, buddyOn: true),
        ProviderToggle(id: "codex", label: "Codex", supportsUsage: true, supportsBuddy: false, usageOn: true, buddyOn: true),
    ]
    return HubPanel(model: m, closeAndRun: { $0() })
}

#Preview("Dark") {
    let m = HubViewModel(now: Date(timeIntervalSince1970: 1_733_800_000))
    m.link = .connected("Beacon-8428")
    m.lastSync = Date(timeIntervalSince1970: 1_733_800_000)
    m.usage = Usage(providers: [
        UsageEntry(id: "claude", label: "CLAUDE",
                   h5: UsageWindow(pct: 2, reset: 1_733_820_000),
                   d7: UsageWindow(pct: 0, reset: 1_734_200_000)),
        UsageEntry(id: "codex", label: "CODEX",
                   h5: UsageWindow(pct: 1, reset: 1_733_821_000),
                   d7: UsageWindow(pct: 93, reset: 1_734_300_000), stale: true),
    ])
    m.providers = [
        ProviderToggle(id: "claude", label: "Claude", supportsUsage: true, supportsBuddy: true, usageOn: true, buddyOn: true),
        ProviderToggle(id: "codex", label: "Codex", supportsUsage: true, supportsBuddy: false, usageOn: true, buddyOn: true),
    ]
    return HubPanel(model: m, closeAndRun: { $0() })
        .preferredColorScheme(.dark)
}
#endif
