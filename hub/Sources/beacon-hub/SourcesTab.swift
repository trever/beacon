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
                                ProviderRowGroup(model: model, provider: pair.element)
                            }
                        }
                    }
                }

                SonosSettingsSection(model: model)
            }
            .padding(HubSpace.xl)
        }
    }
}

/// One provider's status row plus its two independent toggle rows -- `SettingsRow` carries exactly one
/// trailing control (design §3.2: "a row that needs two is two rows"), so Usage and Coding buddy are two
/// separate rows rather than one crowded one. `SourcesTab` (above) and `PageDesignerInspector`'s Agents
/// section both project the SAME `model.providers` store through this exact composition (design §1.2/§3.1:
/// "ten ways to draw a row"). Before this type existed the two files rendered it from two
/// verbatim-duplicated private method groups -- not a divergence like the old `ProviderRow` /
/// `AgentProviderRow`, but the same smaller-scale hazard: identical logic living in two places stays
/// identical only by discipline, and the whole reason this component layer exists is to make that
/// structural instead (`PageDesignerView.swift:740`). `internal`, never `private`, is what lets both files
/// reach it.
internal struct ProviderRowGroup: View {
    @ObservedObject var model: HubViewModel
    let provider: ProviderToggle

    var body: some View {
        Group {
            StatusRow(state: state, title: provider.label, hint: hint) { setupTrailing }
            SettingsRow(title: "Usage") { toggle(supported: provider.supportsUsage, isOn: usageBinding) }
            SettingsRow(title: "Coding buddy") { toggle(supported: provider.supportsBuddy, isOn: buddyBinding) }
        }
    }

    private var state: HubState { provider.installing ? .checking : HubState(provider.hooks) }

    private var hint: String? {
        if provider.installing { return "Setting up\u{2026}" }
        switch provider.hooks {
        case .ok:       return "Ready"
        case .checking: return nil
        case .bad:      return "Needs setup"
        }
    }

    @ViewBuilder private var setupTrailing: some View {
        if !provider.installing && provider.hooks == .bad {
            HubButton(title: "Set up", kind: .secondary) { model.onInstallProviderHooks(provider.id) }
        }
    }

    // ink.secondary, not ink.tertiary (design §2.3: "ink.tertiary may not carry content... the
    // unsupported — markers... move to ink.secondary").
    @ViewBuilder private func toggle(supported: Bool, isOn: Binding<Bool>) -> some View {
        if supported {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        } else {
            Text("\u{2014}").font(HubType.body).foregroundStyle(HubColor.inkSecondary)
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
