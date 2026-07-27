import SwiftUI
import AppKit

// The device-glass FRAME (design SS6.2). WS-0 builds only this: the bezel, the corner geometry, and the
// outside selection ring. Moving `BeaconPalette`, the sketch primitives, deriving the device's type-scale
// constants from DESIGN.md, and bundling the device's fonts are all explicitly out of scope for this
// workstream (plan SS3, "what NOT to build in WS-0") -- that is WS-7's job, once there is content to put
// inside this frame.
//
// The boundary this file sits on (design SS6.1): nothing OUTSIDE this file may read a device token, and
// nothing INSIDE it may read a hub token -- except `DeviceGlassPanel` itself, whose entire job is being
// that seam. It takes hub-side chrome decisions (the bezel, the shadow, the selection ring) and wraps
// device-side content supplied entirely by its caller; it has no opinion about what that content is.

/// Geometry for the device panel's frame. `cornerRatio` and `safeInsetRatio` are the device panel's own
/// proportions (its corner is ~90/466 of its own size, not a hub radius token); `bezel` is the width of
/// the ring drawn around it.
enum GlassMetric {
    static let bezel: CGFloat = 3
    static let cornerRatio: CGFloat = 0.22
    static let safeInsetRatio: CGFloat = 40.0 / 466.0
}

/// The bezel colour is one of the few surfaces in the whole hub that deliberately does NOT use a system
/// colour (design SS6.2): its only job is separating the glass from the window behind it, which is an
/// appearance-dependent problem, not a system-chrome one. Note the inversion -- the bezel goes LIGHTER
/// than the glass in dark appearance, because a black-on-near-black panel with an even darker frame
/// around it disappears entirely.
enum GlassColor {
    static let bezel = HubDynamic.color(
        light: NSColor(srgbRed: CGFloat(0x10) / 255.0, green: CGFloat(0x10) / 255.0,
                       blue: CGFloat(0x10) / 255.0, alpha: 1),
        dark: NSColor(srgbRed: CGFloat(0x2E) / 255.0, green: CGFloat(0x2E) / 255.0,
                      blue: CGFloat(0x2E) / 255.0, alpha: 1))
}

/// Frames arbitrary device-glass content: the bezel ring, `shadow.card`, a rounded clip at the panel's
/// own corner ratio, and an OUTSIDE accent selection ring (design SS6.2). Selection changes the ring's
/// colour only, never its width, and the ring sits outside the bezel at `radius.card + 3` -- never
/// touching the glass, because hub state is drawn around device content, never on it. `Content` is
/// supplied entirely by the caller (WS-2, WS-3, WS-7); this type has no opinion about what is inside the
/// panel.
struct DeviceGlassPanel<Content: View>: View {
    let size: CGFloat
    let isSelected: Bool
    let content: Content

    init(size: CGFloat, isSelected: Bool = false, @ViewBuilder content: () -> Content) {
        self.size = size
        self.isSelected = isSelected
        self.content = content()
    }

    // The bezel's own corner radius is derived from the device panel's proportional corner (not from a
    // hub radius token) so a 3 pt-wide ring hugs a panel whose corner scales with `size`. The selection
    // ring, drawn further out, is the one place a fixed hub radius is correct instead (see `body`) --
    // that ring is hub chrome drawn OUTSIDE the panel, not part of the device's own proportions.
    var glassCornerRadius: CGFloat { size * GlassMetric.cornerRatio }
    var bezelCornerRadius: CGFloat { glassCornerRadius + GlassMetric.bezel }

    var body: some View {
        content
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: glassCornerRadius, style: .continuous))
            .padding(GlassMetric.bezel)
            .background(GlassColor.bezel,
                        in: RoundedRectangle(cornerRadius: bezelCornerRadius, style: .continuous))
            .hubCardShadow()
            .overlay(
                RoundedRectangle(cornerRadius: HubRadius.card + 3, style: .continuous)
                    .strokeBorder(isSelected ? HubColor.accent : Color.clear, lineWidth: 2)
                    .padding(-3)
            )
    }
}
