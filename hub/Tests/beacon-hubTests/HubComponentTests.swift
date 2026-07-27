import XCTest
import SwiftUI
@testable import beacon_hub

// HubRows.swift / HubSurfaces.swift / DeviceGlass.swift (design SS3, plan SS3 "WS-0 -- the substrate").
// Two jobs:
//
// 1. `HubState`'s glyph/tint mapping and its `CheckState` bridge, and `RowSeparator`'s derived inset --
//    the few genuinely pure-value facts this layer has.
// 2. `testEveryComponentIsReachableFromOutsideItsOwnFile` below, which constructs every shared component
//    and reads every token this file introduces. ITS JOB IS TO FAIL TO COMPILE IF ANYTHING IS `private`
//    OR `fileprivate` -- this test target is a different file, in the same module, and Swift access
//    control is enforced at compile time. It intentionally asserts almost nothing beyond "this built" --
//    do not "simplify" it into fewer constructions; the coverage IS the list of things it constructs, per
//    plan SS3's acceptance gate. A private declaration anywhere in the shared component layer recreates
//    the exact disease (ten row types, five status vocabularies, 154 raw font sizes) this workstream
//    exists to end.

final class HubComponentTests: XCTestCase {

    // MARK: - HubState

    func testHubStateGlyphMappingIsTotal() {
        for state: HubState in [.checking, .notSetUp, .ok, .warn, .error] {
            XCTAssertFalse(state.glyph.isEmpty)
        }
    }

    func testHubStateGlyphsAreAllDistinct() {
        let glyphs = Set([HubState.checking, .notSetUp, .ok, .warn, .error].map(\.glyph))
        XCTAssertEqual(glyphs.count, 5, "each state must have its own glyph, not a shared fallback")
    }

    // The mapping trap this test pins down (plan SS3 "Traps" #1 and the HubRowsTests spec in the plan):
    // a pending setup step (`.bad`) is not an error, so it must map to `.notSetUp`, never `.error`.
    func testCheckStateBridgesToHubStateWithBadMappingToNotSetUpNeverError() {
        XCTAssertEqual(HubState(CheckState.checking), .checking)
        XCTAssertEqual(HubState(CheckState.ok), .ok)
        XCTAssertEqual(HubState(CheckState.bad), .notSetUp)
        XCTAssertNotEqual(HubState(CheckState.bad), .error)
    }

    // MARK: - RowSeparator

    func testRowSeparatorInsetIsDerivedNeverALiteral() {
        XCTAssertEqual(RowSeparator(hasLeadingIcon: false).inset, 12)
        // 12 (row inset) + 20 (icon column) + 12 (row inset) = 44.
        XCTAssertEqual(RowSeparator(hasLeadingIcon: true).inset, 44)
    }

    // MARK: - Every shared component, constructed from outside its own file

    // This function's assertion count is intentionally near zero. Its value is that it exists at all: if
    // any type in HubStyle.swift, HubRows.swift, HubSurfaces.swift or DeviceGlass.swift were declared
    // `private` or `fileprivate`, this file -- a different file in the same `beacon-hub` target -- would
    // fail to COMPILE, not fail to pass. That is the enforcement mechanism plan SS0 requires: the rule is
    // structural, not a matter of code-review discipline.
    @MainActor
    func testEveryComponentIsReachableFromOutsideItsOwnFile() {
        // Tokens (HubStyle.swift).
        _ = (HubSpace.hair, HubSpace.xs, HubSpace.s, HubSpace.m, HubSpace.l, HubSpace.xl, HubSpace.xxl)
        _ = (HubType.pane, HubType.figure, HubType.section, HubType.body, HubType.bodyEmph,
             HubType.control, HubType.secondary, HubType.caption, HubType.eyebrow)
        _ = (HubColor.surfaceWindow, HubColor.surfaceContent, HubColor.fillCard, HubColor.fillControl,
             HubColor.fillControlPressed, HubColor.fillSelected, HubColor.inkPrimary, HubColor.inkSecondary,
             HubColor.inkTertiary, HubColor.lineHairline, HubColor.accent, HubColor.stateOk,
             HubColor.stateWarn, HubColor.stateError, HubColor.statePending)
        _ = HubDynamic.color(light: .black, dark: .white)
        _ = (HubRadius.control, HubRadius.card)
        _ = (HubShape.control, HubShape.card, HubShape.pill)
        _ = HubStroke.hairline
        _ = (HubControlMetrics.height, HubControlMetrics.heightProminent, HubControlMetrics.hitMin,
             HubControlMetrics.iconColumn, HubControlMetrics.fieldMinWidth, HubControlMetrics.proseMax)
        _ = (HubMotion.fast, HubMotion.normal, HubMotion.slow)
        let modified = Text("x").hubProse().hubEyebrow().hubCard().hubCardShadow()

        // Rows (HubRows.swift).
        let section = SectionHeader(title: "Title", subtitle: "Subtitle")
        let sectionNoSubtitle = SectionHeader(title: "Title")
        let settingsRow = SettingsRow(icon: "gear", title: "Row", subtitle: "Detail") { EmptyView() }
        let statusRowHub = StatusRow(state: HubState.ok, title: "Status") { EmptyView() }
        let statusRowCheck = StatusRow(state: CheckState.bad, title: "Status") { EmptyView() }
        let listRow = ListRow(primary: "Primary", secondary: "Secondary", isCurrent: true) {}
        let separator = RowSeparator(hasLeadingIcon: true)

        // Surfaces (HubSurfaces.swift).
        let card = Card(padding: .rows) { Text("content") }
        let empty = EmptyState(systemImage: "tray", title: "Nothing here", message: "Add something.",
                                actionTitle: "Add") {}
        let loading = LoadingState("Loading rooms\u{2026}", style: .block)
        let tile = CatalogTile(title: "Markets", detail: "Ticker list, live", isEnabled: true) {}
        let buttonPrimary = HubButton(title: "Save & push", kind: .primary, prominent: true) {}
        let buttonSecondary = HubButton(title: "Cancel", kind: .secondary) {}
        let iconButton = IconButton(systemImage: "xmark", label: "Remove") {}
        let badge = HubBadge("3 of 6", tint: HubColor.stateOk)
        let footer = FooterBar(channels: [FooterBar<EmptyView>.Channel("pages", text: "Pages changed",
                                                                        isDirty: true)]) { EmptyView() }

        // Device glass frame (DeviceGlass.swift).
        _ = (GlassMetric.bezel, GlassMetric.cornerRatio, GlassMetric.safeInsetRatio)
        _ = GlassColor.bezel
        let glassPanel = DeviceGlassPanel(size: 160, isSelected: true) { Color.black }

        // Deprecated compat layer (DeckUI.swift) -- must still be constructible; the deprecation is a
        // warning, not a compile failure, and the plan requires every existing call site to keep working.
        let module = Module(padding: 0) { Text("module") }
        let deckButton = DeckButton(title: "Legacy", kind: .primary) {}
        let toggleRow = ToggleRow(icon: "bell", title: "Legacy toggle", isOn: .constant(true))

        // The assertions below are almost all "this field round-trips" -- the coverage this test provides
        // is the CONSTRUCTION above compiling at all from a different file in the same module (plan SS3's
        // acceptance gate). Do not read the thinness of these assertions as a test to strengthen; that is
        // the point, and it is stated so nobody "improves" this into something heavier later.
        _ = modified
        XCTAssertEqual(section.title, "Title")
        XCTAssertNil(sectionNoSubtitle.subtitle)
        XCTAssertEqual(settingsRow.title, "Row")
        XCTAssertEqual(statusRowHub.state, .ok)
        XCTAssertEqual(statusRowCheck.state, .notSetUp)
        XCTAssertEqual(listRow.primary, "Primary")
        XCTAssertTrue(separator.hasLeadingIcon)
        _ = card
        XCTAssertEqual(empty.title, "Nothing here")
        XCTAssertEqual(loading.label, "Loading rooms\u{2026}")
        XCTAssertEqual(tile.title, "Markets")
        XCTAssertEqual(buttonPrimary.kind, .primary)
        XCTAssertEqual(buttonSecondary.kind, .secondary)
        XCTAssertEqual(iconButton.label, "Remove")
        XCTAssertEqual(badge.text, "3 of 6")
        XCTAssertEqual(footer.channels.first?.id, "pages")
        XCTAssertEqual(glassPanel.size, 160)
        XCTAssertEqual(module.padding, 0)
        XCTAssertEqual(deckButton.kind, .primary)
        XCTAssertEqual(toggleRow.title, "Legacy toggle")
    }
}
