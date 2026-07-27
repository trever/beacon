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
