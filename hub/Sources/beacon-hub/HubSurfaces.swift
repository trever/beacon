import SwiftUI

// The surface and control layer (design SS3.5-SS3.11). Replaces `Module`, `AvailableTile`/`paletteTile`,
// `DeckButton`, the various hand-rolled icon buttons, four hand-rolled capsules, and
// `PageDesignerView.footer` (plan SS3.1's "do not redefine" table). This file uses the anchored form of
// the internal-only gate (only a TOP-LEVEL private/fileprivate declaration is banned) because a
// component may legitimately have non-public helper properties inside its own body -- what must never
// happen is a shared TYPE being hidden from the rest of the target.

/// A grouped surface (design SS3.5), replacing `Module`. A card never contains another card -- one
/// nesting level only -- and a card is never full-bleed against its container's edges; a card that
/// touches its container's edges is a background pretending to be a section.
struct Card<Content: View>: View {
    enum PaddingMode { case content, rows }

    let paddingMode: PaddingMode
    let content: Content

    init(padding: PaddingMode = .content, @ViewBuilder content: () -> Content) {
        self.paddingMode = padding
        self.content = content()
    }

    var body: some View {
        content.hubCard(padding: paddingMode == .content ? HubSpace.l : 0)
    }
}

/// Hand-built because `ContentUnavailableView` is macOS 14 and the deployment target is 13 (design SS3.6,
/// SS9.1). The sentence names what is absent and, where possible, what would fill it -- a shrug at reduced
/// opacity in a corner is not an empty state.
struct EmptyState: View {
    let systemImage: String
    let title: String
    let message: String?
    let actionTitle: String?
    let action: (() -> Void)?

    init(systemImage: String, title: String, message: String? = nil,
         actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: HubSpace.m) {
            // A named macOS text style, not a raw point size, so this decorative glyph still scales with
            // the user's text-size setting the way every other role in this file does.
            Image(systemName: systemImage).font(.title).foregroundStyle(HubColor.inkTertiary)
            VStack(spacing: HubSpace.xs) {
                Text(title).font(HubType.body).foregroundStyle(HubColor.inkPrimary)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 280)
            if let actionTitle, let action {
                HubButton(title: actionTitle, kind: .secondary, action: action)
            }
        }
        .padding(HubSpace.xxl)
        .frame(maxWidth: .infinity)
    }
}

/// design SS3.8. Nothing renders for the first 150 ms so a fetch that resolves faster than that (a 40 ms
/// room fetch was the concrete case) never flashes a visible spinner. The label always names what is
/// loading -- never a bare, unlabelled spinner.
struct LoadingState: View {
    enum Style { case inline, block }

    let label: String
    let style: Style

    @State var showing = false

    init(_ label: String, style: Style = .inline) {
        self.label = label
        self.style = style
    }

    var body: some View {
        Group {
            if showing {
                spinner
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task {
            // Cancellable via the view's own task lifetime: SwiftUI cancels a `.task` automatically when
            // the view disappears, which is the "cancel on disappear" half of the guard (plan trap 6). A
            // completed guard has nothing left to cancel, which is the other half.
            try? await Task.sleep(nanoseconds: 150_000_000)
            if !Task.isCancelled { showing = true }
        }
    }

    @ViewBuilder var spinner: some View {
        switch style {
        case .inline:
            HStack(spacing: HubSpace.s) {
                ProgressView().controlSize(.small)
                Text(label).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
            }
        case .block:
            VStack(spacing: HubSpace.s) {
                ProgressView().controlSize(.small)
                Text(label).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// The catalog/available grid entry (design SS3.7), replacing `AvailableTile` and `paletteTile`. Two text
/// levels, never three -- status is a corner mark, not a competing line. Height is fixed so a grid of
/// these stays a grid; width is left to the caller's grid column so the same tile serves both the 380 pt
/// Pages composition column and the 228 pt complications column.
struct CatalogTile: View {
    let title: String
    let detail: String?
    let isEnabled: Bool
    let isSelected: Bool
    let action: () -> Void

    init(title: String, detail: String? = nil, isEnabled: Bool = false, isSelected: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: HubSpace.xs) {
                HStack {
                    Spacer()
                    if isEnabled {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(HubColor.accent)
                    }
                }
                Spacer(minLength: 0)
                // The ONLY 13-pt-equivalent role in the tile (design SS3.7) -- `detail` below is a full
                // step down at `caption`, so hierarchy comes from the size/weight step, never from colour.
                Text(title)
                    .font(HubType.bodyEmph)
                    .foregroundStyle(isEnabled ? HubColor.inkSecondary : HubColor.inkPrimary)
                    .lineLimit(1)
                if let detail {
                    Text(detail).font(HubType.caption).foregroundStyle(HubColor.inkSecondary).lineLimit(2)
                }
            }
            .padding(HubSpace.s)
            .frame(maxWidth: .infinity, minHeight: 92, maxHeight: 92, alignment: .topLeading)
            .background(isSelected ? HubColor.fillSelected : HubColor.fillCard, in: HubShape.card)
            .overlay(HubShape.card.strokeBorder(isSelected ? HubColor.accent : HubColor.lineHairline,
                                                 lineWidth: HubStroke.hairline))
        }
        .buttonStyle(.plain)
    }
}

enum HubButtonKind: Equatable { case primary, secondary }

/// design SS2.5/SS3: `.borderedProminent` for primary, `.bordered` for secondary, both riding the system
/// accent colour and the system's own disabled rendering -- no manual opacity dimming stacked on top (the
/// old `DeckButton` plus its caller's own dimming multiplied to three separate dimmings on one button).
struct HubButton: View {
    let title: String
    let kind: HubButtonKind
    let prominent: Bool
    let isEnabled: Bool
    let action: () -> Void

    init(title: String, kind: HubButtonKind = .secondary, prominent: Bool = false,
         isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.kind = kind
        self.prominent = prominent
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        styledButton
            .font(HubType.control)
            .frame(height: prominent ? HubControlMetrics.heightProminent : HubControlMetrics.height)
            .disabled(!isEnabled)
    }

    // Two different concrete button styles resolve to two different opaque types, so the branch has to
    // live here rather than behind a single shared modifier call.
    @ViewBuilder var styledButton: some View {
        switch kind {
        case .primary:
            Button(title, action: action).buttonStyle(.borderedProminent)
        case .secondary:
            Button(title, action: action).buttonStyle(.bordered)
        }
    }
}

/// design SS3: a 28x28 hit target regardless of the icon's own visual size, and `label` is a
/// non-optional parameter that becomes the button's accessibility label. This is what makes the design's
/// eleven unlabelled icon buttons impossible to reintroduce -- there is no initializer that lets a caller
/// skip it. `tint` defaults to `ink.secondary`, today's fixed behaviour, so every existing call site is
/// source-compatible; a caller that needs emphasis (`HubPanel`'s destructive "Quit Beacon") now has a
/// real way to reach the icon itself instead of only the caption text beside it.
struct IconButton: View {
    let systemImage: String
    let label: String
    let tint: Color
    let isEnabled: Bool
    let action: () -> Void

    init(systemImage: String, label: String, tint: Color = HubColor.inkSecondary, isEnabled: Bool = true,
         action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = label
        self.tint = tint
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: HubControlMetrics.hitMin, height: HubControlMetrics.hitMin)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

/// design SS2.4/SS3: capsule, `caption` type. Badges carry text only -- a badge holding other controls is
/// a `Card`, not a bigger badge.
struct HubBadge: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color = HubColor.inkSecondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(HubType.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, HubSpace.s).padding(.vertical, HubSpace.hair)
            .background(HubColor.fillControl, in: HubShape.pill)
    }
}

/// design SS3.11: the pinned status/action bar, replacing `PageDesignerView.footer`. Left: one status
/// line per independent channel, each with its own 6 pt `state.warn` dot when that channel is dirty.
/// Right: secondary action then primary, `space.s` apart.
struct FooterBar<Trailing: View>: View {
    struct Channel: Identifiable {
        let id: String
        let text: String
        let isDirty: Bool

        init(_ id: String, text: String, isDirty: Bool) {
            self.id = id
            self.text = text
            self.isDirty = isDirty
        }
    }

    let channels: [Channel]
    let trailing: Trailing

    init(channels: [Channel], @ViewBuilder trailing: () -> Trailing) {
        self.channels = channels
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: HubSpace.xs) {
                    ForEach(channels) { channel in
                        HStack(spacing: HubSpace.xs) {
                            if channel.isDirty {
                                Circle().fill(HubColor.stateWarn).frame(width: 6, height: 6)
                            }
                            Text(channel.text).font(HubType.secondary).foregroundStyle(HubColor.inkSecondary)
                        }
                    }
                }
                Spacer(minLength: HubSpace.m)
                trailing
            }
            .padding(.horizontal, HubSpace.xl).padding(.vertical, HubSpace.m)
        }
    }
}
