import SwiftUI
import BeaconHubKit

// The single configuration surface (Hub Deck style), observing the SAME HubViewModel the popover panel
// uses so provider switches + setup state stay live-synced. Folds in what used to be three windows:
// per-provider toggles, the setup checklist (now blended per provider + a global Connection section),
// and the forget/re-pair guidance.
struct SettingsPanel: View {
    @ObservedObject var model: HubViewModel

    private let usageW: CGFloat = 70
    private let buddyW: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !model.providers.isEmpty {
                SectionHeader(title: "Providers",
                              subtitle: "Toggle what each agent sends; set up its hooks where needed")
                Module(padding: 0) {
                    VStack(spacing: 0) {
                        header
                        ForEach(model.providers) { p in
                            Divider().padding(.leading, 12)
                            ProviderRow(model: model, provider: p, usageW: usageW, buddyW: buddyW)
                        }
                    }
                }
            }

            if !model.pageRows.isEmpty {
                SectionHeader(title: "Device pages",
                              subtitle: "Which screens the Beacon shows, and in what order")
                Module(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(model.pageRows.enumerated()), id: \.element.id) { idx, row in
                            if idx > 0 { Divider().padding(.leading, 12) }
                            PageRowView(model: model, row: row, index: idx)
                        }
                        Divider()
                        applyBar
                    }
                }
            }

            SectionHeader(title: "Connection", subtitle: "Bluetooth link to this Beacon")
            Module(padding: 0) {
                VStack(spacing: 0) {
                    StatusRow(state: model.setupBluetooth, title: "Bluetooth") {
                        if model.setupBluetooth != .ok {
                            DeckButton(title: "Open Settings") { model.onOpenBluetooth() }
                        }
                    }
                    Divider().padding(.leading, 42)
                    StatusRow(state: model.setupPaired, title: "Device connected",
                              hint: "Power on the device; macOS will prompt to pair.") { EmptyView() }
                }
            }

            SectionHeader(title: "Forget device", subtitle: "macOS owns the pairing, not the hub")
            Module {
                VStack(alignment: .leading, spacing: 10) {
                    Text("In Bluetooth settings, click the info button next to Beacon, then choose \u{201C}Forget This Device.\u{201D} It reconnects on its own when back in range.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        DeckButton(title: "Open Bluetooth & forget", kind: .primary) { model.onForget() }
                    }
                }
            }

            Toggle("Don't open on startup", isOn: Binding(
                get: { model.dontShowOnStartup },
                set: { model.dontShowOnStartup = $0; model.onToggleDontShow($0) }))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 460)
    }

    // Applying restarts the device, so edits stage until you press Apply rather than firing per click.
    private var applyBar: some View {
        HStack(spacing: 8) {
            if let sync = model.pageSync {
                Text(sync).font(.system(size: 11)).foregroundStyle(.secondary)
            } else if model.pagesDirty {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("The Beacon restarts to apply (about 5 seconds)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            DeckButton(title: "Apply") { model.onApplyPages(model.enabledPageIDs) }
                .disabled(!model.pagesDirty)
                .opacity(model.pagesDirty ? 1 : 0.4)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Agent").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ColumnHeader(icon: "gauge.with.dots.needle.67percent", title: "Usage").frame(width: usageW)
            ColumnHeader(icon: "person.2.fill", title: "Coding buddy").frame(width: buddyW)
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }
}

private struct SectionHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct ColumnHeader: View {
    let icon: String
    let title: String
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(title).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }
}

// One provider as a table row: name + an inline setup chip on the left, the Usage / Coding buddy toggle
// columns on the right. The chip is an explicit "Set up" button until hooks are detected (then a green
// "Ready"), so setup reads as an action, not another switch. A post-install note drops below when present.
private struct ProviderRow: View {
    @ObservedObject var model: HubViewModel
    let provider: ProviderToggle
    let usageW: CGFloat
    let buddyW: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(provider.label).font(.system(size: 13, weight: .medium))
                    setupChip
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                toggleCell(supported: provider.supportsUsage, isOn: usageBinding).frame(width: usageW)
                toggleCell(supported: provider.supportsBuddy, isOn: buddyBinding).frame(width: buddyW)
            }
            if let note = provider.note {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: provider.hooks == .ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(provider.hooks == .ok ? Color.green : .secondary)
                    Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
    }

    // Setup state beside the name, labeled so it reads as an action rather than a toggle: a "Set up" button
    // until hooks are detected, a green "Ready" once installed, a disabled "Setting up…" mid-install, and
    // nothing while the first check resolves (so "Set up" never flashes).
    @ViewBuilder
    private var setupChip: some View {
        switch (provider.installing, provider.hooks) {
        case (true, _):
            DeckButton(title: "Setting up\u{2026}", enabled: false) {}
        case (false, .ok):
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.green)
        case (false, .checking):
            EmptyView()
        case (false, .bad):
            DeckButton(title: "Set up") { model.onInstallProviderHooks(provider.id) }
        }
    }

    @ViewBuilder
    private func toggleCell(supported: Bool, isOn: Binding<Bool>) -> some View {
        if supported {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        } else {
            Text("\u{2014}").foregroundStyle(.tertiary)
        }
    }

    private var usageBinding: Binding<Bool> {
        Binding(get: { model.providers.first { $0.id == provider.id }?.usageOn ?? true },
                set: { on in
                    if let i = model.providers.firstIndex(where: { $0.id == provider.id }) { model.providers[i].usageOn = on }
                    model.onSetProviderUsage(provider.id, on)
                })
    }
    private var buddyBinding: Binding<Bool> {
        Binding(get: { model.providers.first { $0.id == provider.id }?.buddyOn ?? true },
                set: { on in
                    if let i = model.providers.firstIndex(where: { $0.id == provider.id }) { model.providers[i].buddyOn = on }
                    model.onSetProviderBuddy(provider.id, on)
                })
    }
}

// One check: status glyph + title (+ optional hint) on the left, an optional fix button on the right.
struct StatusRow<Trailing: View>: View {
    let state: CheckState
    let title: String
    var hint: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: glyph.name).foregroundStyle(glyph.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    // Neutral while checking or unsatisfied (the fix button carries the call to action); green only when
    // satisfied. Deliberately no red -- a pending setup step is not an error.
    private var glyph: (name: String, color: Color) {
        switch state {
        case .checking: return ("circle.dashed", .secondary)
        case .ok:       return ("checkmark.circle.fill", .green)
        case .bad:      return ("circle", .secondary)
        }
    }
}

#if DEBUG
#Preview {
    let m = HubViewModel(now: Date(timeIntervalSince1970: 1_733_800_000))
    m.setupBluetooth = .ok
    m.setupPaired = .bad
    m.providers = [
        ProviderToggle(id: "claude", label: "Claude", supportsUsage: true, supportsBuddy: true,
                       usageOn: true, buddyOn: true, hooks: .ok),
        ProviderToggle(id: "codex", label: "Codex", supportsUsage: true, supportsBuddy: false,
                       usageOn: true, buddyOn: true, hooks: .bad),
    ]
    return SettingsPanel(model: m)
}
#endif

// One page: an include checkbox, its name and one line of description, and move up/down. Reordering uses
// buttons rather than drag: these rows live in a VStack inside a scrolling panel, where a drag gesture
// would fight the scroll, and the list is short enough that two clicks is not a burden.
private struct PageRowView: View {
    @ObservedObject var model: HubViewModel
    let row: PageRow
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { row.enabled },
                set: { on in
                    guard let i = model.pageRows.firstIndex(where: { $0.id == row.id }) else { return }
                    model.pageRows[i].enabled = on
                    model.pageSync = nil
                }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(row.pinned)
                .help(row.pinned ? "Settings is always on the device" : "")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: .medium))
                    if row.pinned {
                        Text("always on").font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 2) {
                moveButton(systemName: "chevron.up", enabled: index > 0) { move(by: -1) }
                moveButton(systemName: "chevron.down", enabled: index < model.pageRows.count - 1) { move(by: 1) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .opacity(row.enabled ? 1 : 0.55)
    }

    private func moveButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 16)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .opacity(enabled ? 0.7 : 0.2)
    }

    private func move(by delta: Int) {
        let to = index + delta
        guard model.pageRows.indices.contains(index), model.pageRows.indices.contains(to) else { return }
        model.pageRows.swapAt(index, to)
        model.pageSync = nil
    }
}
