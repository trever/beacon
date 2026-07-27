import SwiftUI
import BeaconHubKit

// Sources tab (design §3.1 tier 2, plan §5): the things that PRODUCE data for the Beacon, independent of
// which page happens to render them -- provider usage/coding-buddy toggles + hooks setup, and the Sonos
// account. A source keeps working when every page that shows it is hidden; that property is exactly why
// these live here and not folded into a page's own inspector. Coding-buddy-on holds real tool calls on this
// Mac for ~590s whether or not any page shows a prompt, and a hooks install writes
// ~/.claude/settings.json / ~/.codex/config.toml / ~/.omp/.../beacon.ts -- machine state, not page state.
// (Provider rows here are the SAME projection the Agents page inspector will show, design §3.1 -- one
// store, one set of controls, not a copy.)
struct SourcesTab: View {
    @ObservedObject var model: HubViewModel

    private let usageW: CGFloat = 70
    private let buddyW: CGFloat = 100

    var body: some View {
        ScrollView {
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

                SonosSettingsSection(model: model)
            }
            .padding(20)
        }
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
// (Moved verbatim from the old flat SettingsPanel.swift -- this is now its only home.)
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

#if DEBUG
#Preview {
    let m = HubViewModel(now: Date(timeIntervalSince1970: 1_733_800_000))
    m.providers = [
        ProviderToggle(id: "claude", label: "Claude", supportsUsage: true, supportsBuddy: true,
                       usageOn: true, buddyOn: true, hooks: .ok),
        ProviderToggle(id: "codex", label: "Codex", supportsUsage: true, supportsBuddy: false,
                       usageOn: true, buddyOn: true, hooks: .bad),
    ]
    return SourcesTab(model: m).frame(width: 720, height: 560)
}
#endif
