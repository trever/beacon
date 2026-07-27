import SwiftUI
import AppKit

// Design tokens for hub chrome (docs/specs/2026-07-27-hub-visual-system-design.md SS2). Every hub-owned
// view reads spacing, type, colour, radius, motion and control metrics from here. This file is the home
// of the plan's "do not redefine" table (plan SS3.1): if a view needs something that is not here, the
// answer is to stop and report it (plan SS0), not to invent a file-local literal or a second vocabulary.
// That is exactly how this codebase ended up with ten row implementations, five status-glyph
// vocabularies and 154 raw font-size call sites across 11 distinct sizes (design SS1.1) -- there was no
// shared vocabulary to draw from, and a type being off-limits made inventing one locally the path of
// least resistance (plan SS0).
//
// The device (firmware/src/ui/theme.h, DESIGN.md) has its own, separate token set for its own black-
// canvas, no-cards visual language. HubStyle deliberately reuses only the device's SPACING ladder
// ("space 4/8/12/16/24/32 rhythm") -- two spacing scales in one product would be one too many. Nothing
// else crosses: colour, type and radius here are unrelated to the device's palette and type scale, which
// belong to DeviceGlass.swift and are off-limits from this file (design SS6.1). A raw font-size literal is
// legal in exactly one place in the whole hub target: the device glass, because the device's faces are
// not text styles and must not scale with the Mac's text-size setting (design SS2.2/SS6.1).

/// The hub's spacing ladder (design SS2.1) -- the same numbers as the device's, distinct token names so
/// the two products can each evolve their own token file without a shared dependency. `hair` is a single
/// named exception for optical baseline nudges inside a text stack; it is never used for layout.
enum HubSpace {
    static let hair: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Nine roles, each mapped to a macOS system text style so every hub surface scales for free with the
/// user's text-size setting (design SS2.2, SS8.3). The point sizes named in the design document are what
/// macOS resolves at the default text size -- documentation, not an API to reproduce with a literal.
enum HubType {
    /// The one title at the top of a pane. Max one per pane.
    static let pane: Font = .title3.weight(.semibold)
    /// The single big number on a surface (a usage percentage). Always paired with `.monospacedDigit()`
    /// so a changing value never jitters in width.
    static let figure: Font = .title.weight(.bold).monospacedDigit()
    /// Section header title.
    static let section: Font = .headline.weight(.semibold)
    /// Row labels, primary text, prose.
    static let body: Font = .body
    /// The selected/current row's label. Only that.
    static let bodyEmph: Font = .body.weight(.medium)
    /// Button titles, field text, menu labels.
    static let control: Font = .callout
    /// Descriptions, hints, status lines, section subtitles.
    static let secondary: Font = .subheadline
    /// Badge text, column headers, units.
    static let caption: Font = .caption
    /// Group labels inside a pane ("AVAILABLE"). Base font only -- `.hubEyebrow()` below adds the
    /// tracking and uppercasing that `Font` itself has no API to carry.
    static let eyebrow: Font = .caption.weight(.semibold)
}

extension View {
    /// Applies the `eyebrow` role's letter-spacing and uppercasing on top of `HubType.eyebrow`'s font
    /// (design SS2.2). Kept as a modifier rather than folded into the `Font` constant because tracking and
    /// case are `Text`/`View`-level concerns, not `Font`-level ones.
    func hubEyebrow() -> some View {
        font(HubType.eyebrow).tracking(0.6).textCase(.uppercase)
    }
}

/// Resolves a colour differently per light/dark appearance without branching on
/// `@Environment(\.colorScheme)`. An `NSColor` dynamic provider is used instead because it resolves
/// correctly on a window, inside an `NSPopover`'s vibrancy material, and across a live appearance switch,
/// with no SwiftUI-side plumbing and no per-view state to keep in sync (design SS2.3).
enum HubDynamic {
    /// A colour that is `light` in aqua/vibrant-light appearances and `dark` in darkAqua/vibrant-dark
    /// ones. `bestMatch(from:)` is used (rather than comparing `appearance.name` directly) so
    /// accessibility/high-contrast appearance variants still resolve to the correct side.
    static func color(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// A fill tinted by the LIVE system accent colour, at a different opacity per appearance. The accent
    /// is resolved to `NSColor.controlAccentColor` INSIDE the provider closure -- capturing a resolved
    /// value outside it would freeze the accent at process start and this token would stop tracking a
    /// live accent-colour change (design SS2.3).
    static func accentFill(lightAlpha: CGFloat, darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor.controlAccentColor.withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        })
    }
}

/// Fifteen colour roles (design SS2.3). System colours wherever one exists; the four `fill.*` roles are
/// the hub's own dynamic tints, built with `HubDynamic` rather than a fixed opacity applied to both
/// appearances (a fixed opacity that reads correctly over a light window is nearly invisible over a dark
/// one -- design SS7 traces this back to the "one opacity for both appearances" bug).
enum HubColor {
    // Backgrounds.
    static let surfaceWindow = Color(nsColor: .windowBackgroundColor)
    static let surfaceContent = Color(nsColor: .controlBackgroundColor)

    // Dynamic fills.
    // Built from bare grayscale components (`NSColor(white:alpha:)`), not the named black/white
    // constants -- the design's "never a hard-coded named colour in hub chrome" rule applies just as
    // much to a tint's own construction as to a foreground colour.
    static let fillCard = HubDynamic.color(light: NSColor(white: 0, alpha: 0.04),
                                            dark: NSColor(white: 1, alpha: 0.07))
    static let fillControl = HubDynamic.color(light: NSColor(white: 0, alpha: 0.07),
                                               dark: NSColor(white: 1, alpha: 0.10))
    static let fillControlPressed = HubDynamic.color(light: NSColor(white: 0, alpha: 0.12),
                                                       dark: NSColor(white: 1, alpha: 0.16))
    static let fillSelected = HubDynamic.accentFill(lightAlpha: 0.12, darkAlpha: 0.20)

    // Ink.
    static let inkPrimary = Color(nsColor: .labelColor)
    static let inkSecondary = Color(nsColor: .secondaryLabelColor)
    /// Decorative only -- roughly 2.8:1 against `surfaceContent` in both appearances, below the 4.5:1
    /// accessible-contrast floor (design SS2.3, SS8.1; pinned by `HubContrastTests`). Never route content
    /// through this token; use `inkSecondary`.
    static let inkTertiary = Color(nsColor: .tertiaryLabelColor)

    // Lines and accent.
    static let lineHairline = Color(nsColor: .separatorColor)
    /// The user's system accent, everywhere -- never a hard-coded hue. The device's own accent lives in
    /// `DeviceGlass.swift` and never crosses into hub chrome (design SS2.3, SS6.1).
    static let accent = Color.accentColor

    // State. Always paired with a glyph and a word; colour never carries state alone (design SS2.3).
    static let stateOk = Color(nsColor: .systemGreen)
    static let stateWarn = Color(nsColor: .systemOrange)
    static let stateError = Color(nsColor: .systemRed)
    static let statePending = Color(nsColor: .secondaryLabelColor)
}

/// Two numeric radii (design SS2.4). Everything today at 7, 8, 12 or 13 rounds to one of these. Every
/// rounded shape in hub chrome uses the continuous corner style.
enum HubRadius {
    static let control: CGFloat = 6
    static let card: CGFloat = 10
}

/// The three rounded shapes built from `HubRadius`, so a view writes `HubShape.card` rather than
/// re-deriving a `RoundedRectangle` from the radius token each time.
enum HubShape {
    static let control = RoundedRectangle(cornerRadius: HubRadius.control, style: .continuous)
    static let card = RoundedRectangle(cornerRadius: HubRadius.card, style: .continuous)
    static let pill = Capsule(style: .continuous)
}

/// Stroke width for cards, separators and tile borders (design SS2.4). Selection changes stroke COLOUR,
/// never width -- a width change moves the content box by a pixel on every edge, which reads as a jump
/// on click.
enum HubStroke {
    static let hairline: CGFloat = 1
}

/// Control sizing (design SS2.5). `.mini` control size is banned outright -- it is why the same switch
/// renders at two different sizes in the product today.
enum HubControlMetrics {
    static let height: CGFloat = 22
    static let heightProminent: CGFloat = 28
    static let hitMin: CGFloat = 28
    static let iconColumn: CGFloat = 20
    static let fieldMinWidth: CGFloat = 180
    static let proseMax: CGFloat = 560
}

/// Motion, borrowed wholesale from the device's own token set so the two halves of the product feel
/// related (design SS2.6). Every animation must check `accessibilityReduceMotion` and degrade to instant;
/// the device is required to have a reduced-motion path, so the hub does not get to be laxer than it.
enum HubMotion {
    static let fast: Double = 0.12
    static let normal: Double = 0.22
    static let slow: Double = 0.40

    static func animation(_ duration: Double, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: duration)
    }
}

/// Card fill + hairline border at `radius.card`, with a caller-chosen content inset -- `space.l` for a
/// card that holds prose, `0` for a card whose rows own their own inset (`SettingsRow`, `StatusRow`).
/// Built as a modifier (rather than only inside the `Card` component in HubSurfaces.swift) so a view that
/// is not itself a `Card` can still opt a container into the same fill/border treatment.
struct HubCardModifier: ViewModifier {
    var padding: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(HubColor.fillCard, in: HubShape.card)
            .overlay(HubShape.card.strokeBorder(HubColor.lineHairline, lineWidth: HubStroke.hairline))
    }
}

extension View {
    func hubCard(padding: CGFloat = HubSpace.l) -> some View {
        modifier(HubCardModifier(padding: padding))
    }
}

/// `shadow.card` (design SS2.4) -- the one shadow in the whole system, reserved for surfaces that
/// represent a physical object (the device preview, design SS6.2). Every other card is flat; a shadow on
/// a flat settings row is an iOS habit. Blur radius genuinely differs by appearance (3 pt light, 4 pt
/// dark), which a colour-only dynamic provider cannot express, so this one modifier reads
/// `colorScheme` directly rather than going through `HubDynamic`.
struct HubCardShadowModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        return content.shadow(color: Color(white: 0, opacity: dark ? 0.40 : 0.12),
                               radius: dark ? 4 : 3, x: 0, y: 1)
    }
}

extension View {
    func hubCardShadow() -> some View {
        modifier(HubCardShadowModifier())
    }
}

/// Caps prose at `control.proseMax` (design SS2.2) -- a hint that runs the full width of a resized window
/// is unreadable.
struct HubProseModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: HubControlMetrics.proseMax, alignment: .leading)
    }
}

extension View {
    func hubProse() -> some View {
        modifier(HubProseModifier())
    }
}
