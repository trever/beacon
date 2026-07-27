import SwiftUI

// General tab (design §3.4 tier 4, plan §5): the hub APP itself, not the device or its data sources --
// start at login, prompt mute, about/version.
struct GeneralTab: View {
    @ObservedObject var model: HubViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HubSpace.xl) {
                generalSection
                aboutSection
            }
            .padding(HubSpace.xl)
        }
    }

    @ViewBuilder private var generalSection: some View {
        VStack(alignment: .leading, spacing: HubSpace.m) {
            SectionHeader(title: "General", subtitle: "Beacon Hub, the menu-bar app")
            Card(padding: .rows) {
                VStack(spacing: 0) {
                    SettingsRow(icon: "person.fill", title: "Start at login",
                                subtitle: model.loginItem == .requiresApproval ? "Approve in Login Items" : nil) {
                        Toggle("", isOn: loginBinding).labelsHidden().toggleStyle(.switch)
                    }
                    RowSeparator(hasLeadingIcon: true)
                    SettingsRow(icon: "speaker.slash.fill", title: "Mute prompt sound") {
                        Toggle("", isOn: muteBinding).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
    }

    @ViewBuilder private var aboutSection: some View {
        VStack(alignment: .leading, spacing: HubSpace.m) {
            SectionHeader(title: "About", subtitle: "Beacon Hub")
            Card {
                VStack(alignment: .leading, spacing: HubSpace.xs) {
                    Text("Beacon Hub \(Self.appVersion)")
                        .font(HubType.body).foregroundStyle(HubColor.inkPrimary)
                    Text("The menu-bar companion that bridges this Mac's Claude/Codex usage and Sonos household to your Beacon device.")
                        .font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // No optimistic flip: request the opposite of the re-read truth; the UI only changes when
    // refreshLoginItem/applyLoginItem writes back model.loginItem (ad-hoc signing can land on
    // .requiresApproval). Mirrors HubPanel's TogglesModule binding.
    private var loginBinding: Binding<Bool> {
        Binding(get: { model.loginItem == .enabled },
                set: { _ in model.onRequestLoginItem(model.loginItem != .enabled) })
    }
    private var muteBinding: Binding<Bool> {
        Binding(get: { model.muted }, set: { model.muted = $0; model.onToggleMute() })
    }

    private static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

#if DEBUG
#Preview("Light") {
    GeneralTab(model: HubViewModel(now: Date(timeIntervalSince1970: 1_733_800_000)))
        .frame(width: 720, height: 560)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    GeneralTab(model: HubViewModel(now: Date(timeIntervalSince1970: 1_733_800_000)))
        .frame(width: 720, height: 560)
        .preferredColorScheme(.dark)
}
#endif
