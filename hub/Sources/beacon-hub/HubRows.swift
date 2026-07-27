import SwiftUI

// The row layer (design SS3.1-SS3.4). Replaces every hand-rolled row in the product -- `ToggleRow`,
// `ProviderRow`, `AgentProviderRow`, `InstrumentRow`, `RoomRow`, `ResultRow`, `CurrentRow`, and
// `ArgPickerList`'s inline button (plan SS3.1's "do not redefine" table). If a caller needs a row shape
// this file does not provide, the answer is to stop and report it (plan SS0), never to add a file-local
// row type.

/// The one status vocabulary (design SS3.3), replacing five independent glyph mappings that grew up
/// separately across the product. `checking` is deliberately distinct from `notSetUp` -- a first check
/// still in flight is not the same claim as "you have not set this up yet" -- and `warn` is distinct from
/// `error`: recoverable by the user themselves is `warn`; recoverable only by changing something else
/// (a different setting, a different device) is `error`.
enum HubState: Equatable {
    case checking, notSetUp, ok, warn, error

    var glyph: String {
        switch self {
        case .checking: return "circle.dashed"
        case .notSetUp: return "circle"
        case .ok:       return "checkmark.circle.fill"
        case .warn:     return "exclamationmark.triangle.fill"
        case .error:    return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .checking: return HubColor.inkTertiary
        case .notSetUp: return HubColor.inkSecondary
        case .ok:       return HubColor.stateOk
        case .warn:     return HubColor.stateWarn
        case .error:    return HubColor.stateError
        }
    }
}

extension HubState {
    /// `CheckState` (`HubViewModel.swift`) is the three-state vocabulary every call site the shared
    /// layer must stay compatible with already passes. `.bad` maps to `.notSetUp`, never `.error` -- a
    /// pending setup step is not a failure, it just has not happened yet.
    init(_ checkState: CheckState) {
        switch checkState {
        case .checking: self = .checking
        case .ok:       self = .ok
        case .bad:      self = .notSetUp
        }
    }
}

/// A group label (design SS3.1). Never placed inside a `Card` -- a header labels a group, so putting it
/// in the group it labels is circular. The caller is responsible for the `space.xl` above and `space.m`
/// below; this view has no opinion about its neighbours.
struct SectionHeader: View {
    let title: String
    let subtitle: String?

    /// The shape every existing call site (`DeviceTab`, `GeneralTab`, `SourcesTab`, `SonosSettingsView`)
    /// already uses, kept so none of those files needs to change for this type to move here.
    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    /// The new, optional-subtitle overload. Swift resolves a plain `String` argument to the exact-match
    /// initializer above rather than this one, so existing two-string call sites are unaffected.
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HubSpace.xs) {
            Text(title).font(HubType.section).foregroundStyle(HubColor.inkPrimary)
            if let subtitle {
                Text(subtitle).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
            }
        }
    }
}

/// The settings-row workhorse (design SS3.2). Exactly one trailing control; a row that needs two is two
/// rows. Deliberately not a whole-row tap target -- that reads naturally on iOS but on macOS it produces
/// an accidental toggle when the user meant to select the row's text instead.
struct SettingsRow<Trailing: View>: View {
    let icon: String?
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(icon: String? = nil, title: String, subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: HubSpace.m) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(HubColor.inkSecondary)
                    .frame(width: HubControlMetrics.iconColumn)
            }
            VStack(alignment: .leading, spacing: HubSpace.xs) {
                Text(title).font(HubType.body).foregroundStyle(HubColor.inkPrimary)
                if let subtitle {
                    Text(subtitle).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
                }
            }
            Spacer(minLength: HubSpace.s)
            trailing
        }
        .padding(.horizontal, HubSpace.m)
        .frame(minHeight: subtitle == nil ? 36 : 52)
    }
}

/// A settings row whose leading column is a state glyph from `HubState`'s one fixed vocabulary (design
/// SS3.3). Titles stay `inkPrimary` even in `warn`/`error` -- the glyph carries the state colour, the
/// word never does (design SS2.3's "state is never colour alone").
struct StatusRow<Trailing: View>: View {
    let state: HubState
    let title: String
    let hint: String?
    let trailing: Trailing

    init(state: HubState, title: String, hint: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.state = state
        self.title = title
        self.hint = hint
        self.trailing = trailing()
    }

    /// `DeviceTab.swift`'s existing call sites pass `CheckState`, not `HubState` -- this overload keeps
    /// that file compiling unchanged by mapping through `HubState.init(_:)`.
    init(state: CheckState, title: String, hint: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(state: HubState(state), title: title, hint: hint, trailing: trailing)
    }

    var body: some View {
        HStack(spacing: HubSpace.m) {
            Image(systemName: state.glyph)
                .foregroundStyle(state.tint)
                .frame(width: HubControlMetrics.iconColumn)
            VStack(alignment: .leading, spacing: HubSpace.xs) {
                Text(title).font(HubType.body).foregroundStyle(HubColor.inkPrimary)
                if let hint {
                    Text(hint).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
                }
            }
            Spacer(minLength: HubSpace.s)
            trailing
        }
        .padding(.horizontal, HubSpace.m)
        .frame(minHeight: hint == nil ? 36 : 52)
    }
}

/// A pickable row for popovers, menus and search results (design SS3.4). Every list row carries at least
/// two fields where a second field genuinely exists in the underlying data -- a single-line row must be
/// a fact about the data, not about who wrote the view.
struct ListRow: View {
    let primary: String
    let secondary: String?
    let isCurrent: Bool
    let action: () -> Void

    @State var isHovering = false

    init(primary: String, secondary: String? = nil, isCurrent: Bool = false, action: @escaping () -> Void) {
        self.primary = primary
        self.secondary = secondary
        self.isCurrent = isCurrent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: HubSpace.s) {
                VStack(alignment: .leading, spacing: HubSpace.hair) {
                    Text(primary)
                        .font(isCurrent ? HubType.bodyEmph : HubType.body)
                        .foregroundStyle(HubColor.inkPrimary)
                        .lineLimit(1)
                    if let secondary {
                        Text(secondary).font(HubType.caption).foregroundStyle(HubColor.inkSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: HubSpace.s)
                if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(HubColor.accent)
                }
            }
            .padding(.horizontal, HubSpace.m).padding(.vertical, HubSpace.s)
            .background(rowFill)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    // `fill.selected` and `fill.controlPressed` are both translucent, so stacking them (selected AND
    // hovering at once) composites naturally rather than needing a manual alpha blend (design SS3.4:
    // "Selected + hover: fill.controlPressed composited over").
    @ViewBuilder var rowFill: some View {
        ZStack {
            if isCurrent { HubShape.control.fill(HubColor.fillSelected) }
            if isHovering { HubShape.control.fill(HubColor.fillControlPressed) }
        }
    }
}

/// A row divider whose leading inset is DERIVED from whether the row has a leading icon column, never
/// typed as one of the three ad-hoc literals the audit found (design SS2.4): "a separator's leading inset
/// equals the x-position of the row's first text column."
struct RowSeparator: View {
    let hasLeadingIcon: Bool

    init(hasLeadingIcon: Bool) {
        self.hasLeadingIcon = hasLeadingIcon
    }

    var inset: CGFloat {
        hasLeadingIcon ? HubSpace.m + HubControlMetrics.iconColumn + HubSpace.m : HubSpace.m
    }

    var body: some View {
        Divider().padding(.leading, inset)
    }
}
