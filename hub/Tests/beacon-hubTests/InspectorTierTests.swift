import XCTest
@testable import beacon_hub

// Pins design SS5.2.1's option-count -> layout table (plan WS-2, "the inspector's empty space" -- one of
// the two named complaints this workstream must fix). The row's own *content* (what a Sonos room actually
// says) is already covered by BeaconHubKitTests.SonosRoomSummaryTests; this suite is only the
// machine-checkable half of complaint 2 -- that a one-option page (the Sonos case) does not resolve to a
// bare, empty-feeling options-only layout.
final class InspectorTierTests: XCTestCase {

    func testZeroOptionsIsPreviewOnly() {
        XCTAssertEqual(InspectorLayout.tier(optionCount: 0), .previewOnly)
    }

    func testOneOptionIsOptionsPlusPreview() {
        XCTAssertEqual(InspectorLayout.tier(optionCount: 1), .optionsPlusPreview)
    }

    func testTwoOptionsIsOptionsPlusPreview() {
        XCTAssertEqual(InspectorLayout.tier(optionCount: 2), .optionsPlusPreview)
    }

    func testThreeOptionsIsOptionsOnly() {
        XCTAssertEqual(InspectorLayout.tier(optionCount: 3), .optionsOnly)
    }

    func testEightOptionsIsOptionsOnly() {
        XCTAssertEqual(InspectorLayout.tier(optionCount: 8), .optionsOnly)
    }

    // The machine-checkable half of complaint 2: a Sonos page has exactly one option (its room), and that
    // must resolve to `.optionsPlusPreview` -- the room `Menu` plus a picture of the Sonos page it feeds --
    // never to `.optionsOnly` (which would drop the preview and leave the Menu alone in the column, the
    // exact "one control floating in a void" defect the owner complained about) and never to `.previewOnly`
    // (which would hide the room control entirely).
    func testSonosPageWithOneOptionResolvesToOptionsPlusPreview() {
        let sonosOptionCount = 1   // the room picker is the Sonos page's only configurable option
        XCTAssertEqual(InspectorLayout.tier(optionCount: sonosOptionCount), .optionsPlusPreview)
    }
}
