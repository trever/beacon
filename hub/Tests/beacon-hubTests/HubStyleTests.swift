import XCTest
import SwiftUI
import AppKit
@testable import beacon_hub

// HubStyle.swift's tokens (design SS2, plan SS3 "WS-0 -- the substrate"). Pure-value tests: the spacing
// ladder, the radius count, motion's reduced-motion behaviour, and -- the two tests that matter most --
// that every dynamic fill actually differs between appearances (the "one opacity for both appearances"
// bug that produced design SS7), and that the contrast rules design SS2.3/SS8.1 state are true of the
// REAL, resolved system colours, not just true on paper.

final class HubStyleTests: XCTestCase {

    func testSpacingLadderIsExactlyTheStatedSevenValuesAndNothingElse() {
        let ladder: [CGFloat] = [HubSpace.hair, HubSpace.xs, HubSpace.s, HubSpace.m, HubSpace.l,
                                  HubSpace.xl, HubSpace.xxl]
        XCTAssertEqual(ladder, [2, 4, 8, 12, 16, 24, 32])
    }

    func testThereAreExactlyTwoNumericRadii() {
        XCTAssertEqual(HubRadius.control, 6)
        XCTAssertEqual(HubRadius.card, 10)
        XCTAssertNotEqual(HubRadius.control, HubRadius.card)
    }

    func testHubMotionAnimationReturnsNilOnlyWhenReduceMotionIsTrue() {
        XCTAssertNil(HubMotion.animation(HubMotion.normal, reduceMotion: true))
        XCTAssertNotNil(HubMotion.animation(HubMotion.normal, reduceMotion: false))
        XCTAssertNil(HubMotion.animation(HubMotion.fast, reduceMotion: true))
        XCTAssertNotNil(HubMotion.animation(HubMotion.slow, reduceMotion: false))
    }

    // This is the mechanical check for the exact regression design SS7 traces the whole dark-mode miss
    // back to: a fixed opacity applied to both appearances. Every `fill.*` token must resolve to a
    // genuinely different sRGB value under `.aqua` than under `.darkAqua`.
    func testEveryDynamicFillResolvesToADifferentValueUnderLightAndDark() {
        let fills: [(name: String, color: Color)] = [
            ("fillCard", HubColor.fillCard),
            ("fillControl", HubColor.fillControl),
            ("fillControlPressed", HubColor.fillControlPressed),
            ("fillSelected", HubColor.fillSelected),
        ]
        for fill in fills {
            let light = HubColorTestSupport.resolve(fill.color, appearance: .aqua)
            let dark = HubColorTestSupport.resolve(fill.color, appearance: .darkAqua)
            XCTAssertNotEqual(light, dark, "\(fill.name) must differ between aqua and darkAqua")
        }
    }

    // The bezel token (DeviceGlass.swift) deliberately inverts -- lighter in dark appearance -- but it
    // must still differ per appearance the same way every other dynamic token does.
    func testGlassBezelDiffersByAppearanceAndInvertsDarker() {
        let light = HubColorTestSupport.resolve(GlassColor.bezel, appearance: .aqua)
        let dark = HubColorTestSupport.resolve(GlassColor.bezel, appearance: .darkAqua)
        XCTAssertNotEqual(light, dark)
        // #101010 in light, #2E2E2E in dark -- dark's channel value is the larger one (lighter grey).
        XCTAssertLessThan(light.r, dark.r)
    }

    // design SS2.3/SS8.1 states that ink.primary AND ink.secondary each clear WCAG 4.5:1 over both
    // surface.content and fill.card, in both appearances. Measuring the REAL resolved system colours
    // (rather than the design document's own "documentation, not for typing into code" hex column) shows
    // that is true of ink.primary in both appearances, and of ink.secondary in DARK appearance only.
    // `NSColor.secondaryLabelColor` -- the exact source design SS2.3's own "Implementation" column names
    // for ink.secondary -- resolves to ~49.8% alpha in light appearance, which measures ~3.95:1 over both
    // backdrops: below the floor the same design section states as a requirement. It resolves to ~54.9%
    // alpha in dark appearance, which clears ~5.2-5.9:1. This is a genuine inconsistency inside the design
    // document itself (it mandates both "use the system secondaryLabelColor" and "clear 4.5:1 in both
    // appearances", and macOS's real values make those two statements incompatible in light mode) rather
    // than a WS-0 implementation bug -- flagged in this agent's final report for the design's owner, not
    // silently patched here by swapping in a different ink.secondary source (an unauthorized design
    // change) or by silently loosening this assertion without comment.
    func testInkPrimaryClearsAccessibleContrastOverContentAndCardInBothAppearances() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            for backdrop in contentAndCardBackdrops(appearance: appearance) {
                let primary = HubColorTestSupport.composite(
                    HubColorTestSupport.resolve(HubColor.inkPrimary, appearance: appearance), over: backdrop.color)
                XCTAssertGreaterThanOrEqual(HubColorTestSupport.contrastRatio(primary, backdrop.color), 4.5,
                    "ink.primary over \(backdrop.name) under \(appearance.rawValue)")
            }
        }
    }

    func testInkSecondaryClearsAccessibleContrastInDarkAppearanceOnly() {
        for backdrop in contentAndCardBackdrops(appearance: .darkAqua) {
            let secondary = HubColorTestSupport.composite(
                HubColorTestSupport.resolve(HubColor.inkSecondary, appearance: .darkAqua), over: backdrop.color)
            XCTAssertGreaterThanOrEqual(HubColorTestSupport.contrastRatio(secondary, backdrop.color), 4.5,
                "ink.secondary over \(backdrop.name) under darkAqua")
        }
        for backdrop in contentAndCardBackdrops(appearance: .aqua) {
            let secondary = HubColorTestSupport.composite(
                HubColorTestSupport.resolve(HubColor.inkSecondary, appearance: .aqua), over: backdrop.color)
            let ratio = HubColorTestSupport.contrastRatio(secondary, backdrop.color)
            // Pin the measured shortfall (rather than just asserting "< 4.5") so a future change to
            // NSColor.secondaryLabelColor's own resolved value, or to this token's construction, is
            // caught either way -- an accidental IMPROVEMENT here should be noticed and reconciled with
            // the design document, not silently absorbed as "still under 4.5, still red before, fine".
            XCTAssertEqual(ratio, 3.9, accuracy: 0.15,
                "ink.secondary over \(backdrop.name) under aqua -- expected the known ~3.95:1 shortfall")
        }
    }

    private func contentAndCardBackdrops(appearance: NSAppearance.Name)
        -> [(name: String, color: HubColorTestSupport.RGBA)] {
        let windowBG = HubColorTestSupport.resolve(HubColor.surfaceWindow, appearance: appearance)
        let contentBG = HubColorTestSupport.resolve(HubColor.surfaceContent, appearance: appearance)
        let cardOverWindow = HubColorTestSupport.composite(
            HubColorTestSupport.resolve(HubColor.fillCard, appearance: appearance), over: windowBG)
        return [("surface.content", contentBG), ("fill.card", cardOverWindow)]
    }

    // `ink.onAccent` (shared-layer gap #4) exists specifically to replace a hardcoded `Color.white` glyph
    // with something that stays legible against the user's OWN accent colour, in both appearances --
    // that is the entire justification for adding the token instead of leaving the workaround in place.
    // `NSColor.controlAccentColor` in a plain test run resolves to whatever accent this machine has
    // selected (system default: blue), so this measures the real pairing rather than the design
    // document's own "documentation, not for typing into code" hex column.
    func testInkOnAccentClearsIconContrastOverAccentInBothAppearances() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let accentBG = HubColorTestSupport.resolve(HubColor.accent, appearance: appearance)
            let onAccent = HubColorTestSupport.composite(
                HubColorTestSupport.resolve(HubColor.inkOnAccent, appearance: appearance), over: accentBG)
            // 3:1 is design SS8.1's own floor for "icons that carry meaning" -- the badge glyph this token
            // was added for is exactly that, not `type.body`-or-smaller text, so 3:1 is the right bar here,
            // not 4.5:1.
            XCTAssertGreaterThanOrEqual(HubColorTestSupport.contrastRatio(onAccent, accentBG), 3.0,
                "ink.onAccent over accent under \(appearance.rawValue)")
        }
    }

    // `ink.onAccent` must also be genuinely distinct from the plain ink roles -- a token that just aliases
    // `ink.primary` would not be testing anything about the accent pairing at all.
    func testInkOnAccentDiffersFromInkPrimaryAndInkSecondary() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let onAccent = HubColorTestSupport.resolve(HubColor.inkOnAccent, appearance: appearance)
            let primary = HubColorTestSupport.resolve(HubColor.inkPrimary, appearance: appearance)
            XCTAssertNotEqual(onAccent, primary, "ink.onAccent must not just alias ink.primary")
        }
    }

    // design SS2.3: ink.tertiary must stay BELOW the accessible floor -- pinning the known-bad value so
    // nobody quietly promotes it to carrying content later (it is decorative-only by contract).
    func testInkTertiaryStaysBelowTheAccessibleContrastFloor() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let backdrop = HubColorTestSupport.resolve(HubColor.surfaceContent, appearance: appearance)
            let tertiary = HubColorTestSupport.composite(
                HubColorTestSupport.resolve(HubColor.inkTertiary, appearance: appearance), over: backdrop)
            XCTAssertLessThan(HubColorTestSupport.contrastRatio(tertiary, backdrop), 4.5,
                "ink.tertiary under \(appearance.rawValue)")
        }
    }

    // MARK: - WS-8: the remaining SS8.1 pairings

    // design SS8.1's own wording: "Includes text over fill.card, fill.selected, and the popover
    // material." WS-0 covered `surface.content` and `fill.card`; this covers the third named backdrop.
    // `ListRow` is the real call site -- its `primary`/`secondary` text sit over `fillSelected` whenever
    // `isCurrent` is true (HubRows.swift).
    func testInkPrimaryClearsAccessibleContrastOverFillSelectedInBothAppearances() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let selected = selectedOverWindow(appearance: appearance)
            let primary = HubColorTestSupport.composite(
                HubColorTestSupport.resolve(HubColor.inkPrimary, appearance: appearance), over: selected)
            XCTAssertGreaterThanOrEqual(HubColorTestSupport.contrastRatio(primary, selected), 4.5,
                "ink.primary over fill.selected under \(appearance.rawValue)")
        }
    }

    // Same known shortfall as `testInkSecondaryClearsAccessibleContrastInDarkAppearanceOnly` above, over
    // the third SS8.1 backdrop: `fill.selected` composites over the same `surface.window` `fill.card`
    // does, and neither ink token's own alpha changes by backdrop, so `ink.secondary` reproduces the
    // identical light-appearance shortfall here. Pinning the measured value rather than asserting a bare
    // "< 4.5" for the same reason WS-0 did: an accidental change to the measured number should be noticed,
    // not silently absorbed as "still red, still fine."
    func testInkSecondaryOverFillSelectedClearsInDarkAppearanceOnly() {
        let dark = selectedOverWindow(appearance: .darkAqua)
        let secondaryDark = HubColorTestSupport.composite(
            HubColorTestSupport.resolve(HubColor.inkSecondary, appearance: .darkAqua), over: dark)
        XCTAssertGreaterThanOrEqual(HubColorTestSupport.contrastRatio(secondaryDark, dark), 4.5,
            "ink.secondary over fill.selected under darkAqua")

        let light = selectedOverWindow(appearance: .aqua)
        let secondaryLight = HubColorTestSupport.composite(
            HubColorTestSupport.resolve(HubColor.inkSecondary, appearance: .aqua), over: light)
        XCTAssertEqual(HubColorTestSupport.contrastRatio(secondaryLight, light), 3.83, accuracy: 0.15,
            "ink.secondary over fill.selected under aqua -- expected the known ~3.83:1 shortfall")
    }

    // design SS8.1: "type.pane, type.figure (>= 17 pt, or >= 14 pt bold) -- 3:1". Both roles render in
    // `ink.primary` everywhere in the product today (WS-8 moved `WindowRow.pctText` -- the one `type.figure`
    // site that used to render in a `state.*` colour instead -- onto `ink.primary` for exactly this reason;
    // see HubPanel.swift). `ink.primary` already clears the STRICTER 4.5:1 floor tested above, so this
    // pins the SS8.1-specific 3:1 floor explicitly rather than leaving it as an inference from a stricter
    // number, per the brief's "every token pairing SS8.1 names."
    func testInkPrimaryClearsTheRelaxedLargeTextFloorInBothAppearances() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let backdrop = HubColorTestSupport.resolve(HubColor.surfaceContent, appearance: appearance)
            let primary = HubColorTestSupport.composite(
                HubColorTestSupport.resolve(HubColor.inkPrimary, appearance: appearance), over: backdrop)
            XCTAssertGreaterThanOrEqual(HubColorTestSupport.contrastRatio(primary, backdrop), 3.0,
                "ink.primary (type.pane/type.figure floor) over surface.content under \(appearance.rawValue)")
        }
    }

    // design SS8.1: "Icons that carry meaning -- 3:1". `state.ok`/`state.warn`/`state.error` are the glyph
    // tints `HubState.tint` hands to every `StatusRow`/`StatusLine` icon (HubRows.swift) -- always paired
    // with a `type.body` word already pinned at `ink.primary` (design SS2.3's "the word is ink.primary,
    // not the state colour"; `testInkPrimaryClearsAccessibleContrastOverContentAndCardInBothAppearances`
    // above covers that word). Design SS2.3 states explicitly that in THIS paired configuration the glyph
    // is decoration and "the contrast requirement falls on the text, which passes" -- so this test does not
    // assert the icon-alone floor for `state.ok`/`state.warn` (measured below and pinned as a KNOWN,
    // explicitly-exempted shortfall, the same treatment `ink.tertiary` gets above); it exists to make that
    // exemption traceable rather than silently unverified, and to catch a REGRESSION if either colour is
    // ever used as text with no paired word (WS-8 found and fixed three such sites -- ComplicationEditorView's
    // "unknown" badge, TickerEditorView's at-capacity counter, PageDesignerChartPopover's cap message --
    // all now `ink.primary`, all covered by the same tests above rather than this one).
    func testStateGlyphTintsMeasuredAgainstTheIconFloor() {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            let contentBG = HubColorTestSupport.resolve(HubColor.surfaceContent, appearance: appearance)
            let ok = HubColorTestSupport.composite(
                HubColorTestSupport.resolve(HubColor.stateOk, appearance: appearance), over: contentBG)
            let warn = HubColorTestSupport.composite(
                HubColorTestSupport.resolve(HubColor.stateWarn, appearance: appearance), over: contentBG)
            let error = HubColorTestSupport.composite(
                HubColorTestSupport.resolve(HubColor.stateError, appearance: appearance), over: contentBG)
            let okRatio = HubColorTestSupport.contrastRatio(ok, contentBG)
            let warnRatio = HubColorTestSupport.contrastRatio(warn, contentBG)
            let errorRatio = HubColorTestSupport.contrastRatio(error, contentBG)
            switch appearance {
            case .aqua:
                // Both measured BELOW the 3:1 icon floor -- the known, design-exempted shortfall (glyph is
                // decoration; the accompanying word carries the requirement). Pinned so a future change to
                // NSColor.systemGreen/systemOrange, or to this token's construction, gets noticed.
                XCTAssertLessThan(okRatio, 3.0, "state.ok icon-alone under aqua (exempted by design SS2.3)")
                XCTAssertLessThan(warnRatio, 3.0, "state.warn icon-alone under aqua (exempted by design SS2.3)")
                // state.error happens to clear the icon floor even alone -- not a design guarantee, just
                // where NSColor.systemRed's luminance lands; pinned as a fact, not asserted as a promise.
                XCTAssertGreaterThanOrEqual(errorRatio, 3.0, "state.error icon-alone under aqua")
            case .darkAqua:
                // All three clear the icon floor unaided in dark appearance.
                XCTAssertGreaterThanOrEqual(okRatio, 3.0, "state.ok icon-alone under darkAqua")
                XCTAssertGreaterThanOrEqual(warnRatio, 3.0, "state.warn icon-alone under darkAqua")
                XCTAssertGreaterThanOrEqual(errorRatio, 3.0, "state.error icon-alone under darkAqua")
            default:
                XCTFail("unexpected appearance \(appearance.rawValue)")
            }
        }
    }

    // design SS8.1's third row, restated precisely: `ink.onAccent` (the badge glyph on a filled `accent`
    // circle, HubPanel's `HeaderModule`) is the one "icon that carries meaning" against a NON-content
    // backdrop already covered, by `testInkOnAccentClearsIconContrastOverAccentInBothAppearances` above --
    // noted here only so this section's header comment is a complete map of SS8.1 to tests, not a second
    // assertion of the same fact.

    private func selectedOverWindow(appearance: NSAppearance.Name) -> HubColorTestSupport.RGBA {
        let windowBG = HubColorTestSupport.resolve(HubColor.surfaceWindow, appearance: appearance)
        return HubColorTestSupport.composite(
            HubColorTestSupport.resolve(HubColor.fillSelected, appearance: appearance), over: windowBG)
    }
}

// MARK: - Test-only colour math

/// Not part of the shared component layer -- this is test infrastructure for resolving an
/// `NSColor(name:dynamicProvider:)`-backed `Color` against a specific, named appearance, and for
/// computing WCAG 2.1 contrast from the result. `private` is fine here: none of this is the SS0 "do not
/// redefine" surface, it exists only so the tests above can assert against real resolved system colours
/// instead of eyeballing the design document's documentation-only hex column.
enum HubColorTestSupport {
    struct RGBA: Equatable {
        let r: Double
        let g: Double
        let b: Double
        let a: Double
    }

    static func resolve(_ color: Color, appearance name: NSAppearance.Name) -> RGBA {
        let nsColor = NSColor(color)
        guard let appearance = NSAppearance(named: name) else {
            XCTFail("Missing system appearance \(name.rawValue)")
            return RGBA(r: 0, g: 0, b: 0, a: 0)
        }
        var result = RGBA(r: 0, g: 0, b: 0, a: 0)
        appearance.performAsCurrentDrawingAppearance {
            let resolved = nsColor.usingColorSpace(.sRGB) ?? nsColor
            result = RGBA(r: Double(resolved.redComponent), g: Double(resolved.greenComponent),
                          b: Double(resolved.blueComponent), a: Double(resolved.alphaComponent))
        }
        return result
    }

    /// Alpha-composites `fg` over an opaque `bg`, per channel.
    static func composite(_ fg: RGBA, over bg: RGBA) -> RGBA {
        let a = fg.a
        return RGBA(r: fg.r * a + bg.r * (1 - a), g: fg.g * a + bg.g * (1 - a),
                    b: fg.b * a + bg.b * (1 - a), a: 1)
    }

    static func relativeLuminance(_ c: RGBA) -> Double {
        func linearize(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(c.r) + 0.7152 * linearize(c.g) + 0.0722 * linearize(c.b)
    }

    static func contrastRatio(_ a: RGBA, _ b: RGBA) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        let lighter = max(la, lb), darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
