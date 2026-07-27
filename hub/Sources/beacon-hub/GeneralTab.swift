import SwiftUI

// General tab (design §3.4 tier 4, plan §5): the hub APP itself, not the device or its data sources --
// start at login, prompt mute, about/version.
struct GeneralTab: View {
    @ObservedObject var model: HubViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "General", subtitle: "Beacon Hub, the menu-bar app")
                Module(padding: 0) {
                    VStack(spacing: 0) {
                        ToggleRow(icon: "person.fill", title: "Start at login",
                                  subtitle: model.loginItem == .requiresApproval ? "Approve in Login Items" : nil,
                                  isOn: loginBinding)
                        Divider().padding(.leading, 12)
                        ToggleRow(icon: "speaker.slash.fill", title: "Mute prompt sound", isOn: muteBinding)
                    }
                }

                SectionHeader(title: "About", subtitle: "Beacon Hub")
                Module {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Beacon Hub \(Self.appVersion)")
                            .font(.system(size: 12, weight: .medium))
                        Text("The menu-bar companion that bridges this Mac's Claude/Codex usage and Sonos household to your Beacon device.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
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
#Preview {
    GeneralTab(model: HubViewModel(now: Date(timeIntervalSince1970: 1_733_800_000)))
        .frame(width: 720, height: 560)
}
#endif
