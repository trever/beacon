import SwiftUI

// Shared chrome (design §2.2/§5): the flat single-panel "SettingsPanel" this file used to define is gone --
// SettingsTabs.swift (the window root) plus SourcesTab.swift/DeviceTab.swift/GeneralTab.swift (the tab
// bodies) replace it; the page designer folds into the Pages tab instead of a Providers/Device
// pages/Sonos list living behind a "Don't open on startup" checkbox. `SectionHeader` and `StatusRow`
// outlived the panel they were built for: every tab uses them, and so does SonosSettingsView.swift and
// (WS-3's) PageDesignerView.swift, so they stay here as this file's sole remaining job.
struct SectionHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
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
