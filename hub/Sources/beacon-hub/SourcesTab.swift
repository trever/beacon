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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HubSpace.xl) {
                if !model.providers.isEmpty {
                    SectionHeader(title: "Providers",
                                  subtitle: "Toggle what each agent sends; set up its hooks where needed")
                    Card(padding: .rows) {
                        VStack(spacing: 0) {
                            ForEach(Array(model.providers.enumerated()), id: \.element.id) { pair in
                                if pair.offset > 0 { RowSeparator(hasLeadingIcon: false) }
                                providerRows(pair.element)
                            }
                        }
                    }
                }

                SonosSettingsSection(model: model)
            }
            .padding(HubSpace.xl)
        }
    }

    // This is the SAME three-row composition (StatusRow + two SettingsRows) `PageDesignerInspector`'s
    // Agents section renders off the same `model.providers` store -- design §1.2/§3.1's "ten ways to draw
    // a row" is closed by both destinations projecting the one store through the same two shared
    // components at the same size, not by sharing a bespoke type across files (plan WS-4: "do not create
    // another private row type; that is the whole disease").
    @ViewBuilder private func providerRows(_ provider: ProviderToggle) -> some View {
        StatusRow(state: providerState(provider), title: provider.label, hint: providerHint(provider)) {
            providerSetupTrailing(provider)
        }
        SettingsRow(title: "Usage") {
            providerToggle(supported: provider.supportsUsage, isOn: usageBinding(provider))
        }
        SettingsRow(title: "Coding buddy") {
            providerToggle(supported: provider.supportsBuddy, isOn: buddyBinding(provider))
        }
    }

    private func providerState(_ provider: ProviderToggle) -> HubState {
        provider.installing ? .checking : HubState(provider.hooks)
    }

    private func providerHint(_ provider: ProviderToggle) -> String? {
        if provider.installing { return "Setting up\u{2026}" }
        switch provider.hooks {
        case .ok:       return "Ready"
        case .checking: return nil
        case .bad:      return "Needs setup"
        }
    }

    @ViewBuilder private func providerSetupTrailing(_ provider: ProviderToggle) -> some View {
        if !provider.installing && provider.hooks == .bad {
            HubButton(title: "Set up", kind: .secondary) { model.onInstallProviderHooks(provider.id) }
        }
    }

    // ink.secondary, not ink.tertiary (design §2.3: "ink.tertiary may not carry content... the
    // unsupported — markers... move to ink.secondary").
    @ViewBuilder private func providerToggle(supported: Bool, isOn: Binding<Bool>) -> some View {
        if supported {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        } else {
            Text("\u{2014}").font(HubType.body).foregroundStyle(HubColor.inkSecondary)
        }
    }

    private func usageBinding(_ provider: ProviderToggle) -> Binding<Bool> {
        Binding(get: { model.providers.first { $0.id == provider.id }?.usageOn ?? true },
                set: { on in
                    if let i = model.providers.firstIndex(where: { $0.id == provider.id }) { model.providers[i].usageOn = on }
                    model.onSetProviderUsage(provider.id, on)
                })
    }
    private func buddyBinding(_ provider: ProviderToggle) -> Binding<Bool> {
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
