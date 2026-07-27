import SwiftUI

// DEPRECATED COMPAT LAYER (plan SS3, WS-0). Every type in this file is superseded by the shared
// component layer -- HubSurfaces.swift's `Card`, `HubButton` and `SettingsRow` (via HubRows.swift).
// WS-0 converts zero call sites; every existing use of `Module`, `DeckButton` or `ToggleRow` keeps
// compiling against these wrappers and each one now emits a deprecation warning naming its replacement,
// so every unconverted site announces itself in the build log instead of hiding silently.
//
// `swift build 2>&1 | grep -c "is deprecated"` is the migration burn-down counter every downstream
// workstream is required to lower (plan SS2.2). WS-9 deletes this file entirely once that count reaches
// zero.
//
// Each wrapper's body is built on the NEW component, never on the old implementation -- a deprecated
// type whose own body still called itself (or another deprecated sibling) would re-trigger the very
// warning it is trying to phase out.

@available(*, deprecated, message: "Use Card (HubSurfaces.swift) instead.")
struct Module<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(padding: CGFloat = 11, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        Card(padding: padding == 0 ? .rows : .content) { content }
    }
}

@available(*, deprecated, message: "Use HubButtonKind (HubSurfaces.swift) instead.")
enum DeckButtonKind: Equatable { case secondary, primary }

@available(*, deprecated, message: "Use HubButton (HubSurfaces.swift) instead.")
struct DeckButton: View {
    let title: String
    let kind: DeckButtonKind
    let large: Bool
    let enabled: Bool
    let action: () -> Void

    init(title: String, kind: DeckButtonKind = .secondary, large: Bool = false, enabled: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.large = large
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        // Both of the old wrapper's manual opacity dimmings are gone: `HubButton` relies solely on the
        // system's own disabled rendering (design SS2.5).
        HubButton(title: title, kind: kind == .primary ? .primary : .secondary,
                  prominent: large, isEnabled: enabled, action: action)
    }
}

@available(*, deprecated, message: "Use SettingsRow (HubRows.swift) instead.")
struct ToggleRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    let isOn: Binding<Bool>

    init(icon: String, title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.isOn = isOn
    }

    var body: some View {
        SettingsRow(icon: icon, title: title, subtitle: subtitle) {
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}
