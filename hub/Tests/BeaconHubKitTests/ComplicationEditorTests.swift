import XCTest
@testable import BeaconHubKit

final class ComplicationEditorTests: XCTestCase {

    // --- capacity, the clock counting as 2 ---

    func testEmptyUsesNoUnits() {
        XCTAssertEqual(ComplicationEditor.unitsUsed([]), 0)
        XCTAssertEqual(ComplicationEditor.unitsFree([]), 6)
    }

    func testClockCountsAsTwoUnits() {
        let placements = [CompPlacement("clock")!]
        XCTAssertEqual(ComplicationEditor.unitsUsed(placements), 2)
        XCTAssertEqual(ComplicationEditor.unitsFree(placements), 4)
    }

    func testSixOneUnitEntriesFillCapacityExactly() {
        let placements = ["fin", "ice", "agents", "usage", "weather", "sonos"].map { CompPlacement($0)! }
        XCTAssertEqual(ComplicationEditor.unitsUsed(placements), 6)
        XCTAssertEqual(ComplicationEditor.unitsFree(placements), 0)
    }

    // A 2-slot placement (clock or chart) must be refused when only 1 unit remains -- 5 one-unit
    // placements already spend 5 of the 6 units.
    func testTwoSlotPlacementRefusedWhenOnlyOneUnitRemains() {
        let placements = ["fin", "ice", "agents", "usage", "weather"].map { CompPlacement($0)! }
        XCTAssertEqual(ComplicationEditor.unitsFree(placements), 1)
        XCTAssertEqual(ComplicationEditor.validate(id: "clock", arg: nil, into: placements), .insufficientCapacity)
        let after = ComplicationEditor.placing(id: "clock", arg: nil, into: placements)
        XCTAssertEqual(after, placements, "a refused placement must leave the list untouched")
    }

    // But a later 1-slot entry can still land where a 2-slot one would not fit (design §4.3 rule 3).
    func testOneSlotEntryStillFitsWhenTwoSlotWouldNot() {
        let placements = ["fin", "ice", "agents", "usage", "weather"].map { CompPlacement($0)! }
        XCTAssertNil(ComplicationEditor.validate(id: "sonos", arg: nil, into: placements))
        let after = ComplicationEditor.placing(id: "sonos", arg: nil, into: placements)
        XCTAssertEqual(ComplicationEditor.unitsUsed(after), 6)
    }

    func testClockAndFiveOneUnitEntriesFillCapacityExactly() {
        let placements = ["clock", "fin", "ice", "agents", "usage"].map { CompPlacement($0)! }
        XCTAssertEqual(ComplicationEditor.unitsUsed(placements), 6)
        // one more unit of anything is refused
        XCTAssertEqual(ComplicationEditor.validate(id: "sonos", arg: nil, into: placements), .insufficientCapacity)
    }

    // --- one instance per id ---

    // validate() alone -- with no knowledge of "this is the same id being moved" -- reports the
    // duplicate as refused. placing()'s auto-move convenience (tested below) is a layer on top of this,
    // not a contradiction of it: a caller that wants a hard refusal (e.g. to show a message) can call
    // validate() directly with its default `replacing: nil`.
    func testAlreadyPlacedIsRefusedByValidate() {
        let placements = [CompPlacement("clock")!, CompPlacement(id: "fin", arg: "sp500")!]
        XCTAssertTrue(ComplicationEditor.isAlreadyPlaced("fin", in: placements))
        XCTAssertEqual(ComplicationEditor.validate(id: "fin", arg: "nasdaq", into: placements), .alreadyPlaced)
    }

    // Re-placing (moving/re-arging) the SAME id at its own slot must not trip "already placed" against
    // itself.
    func testReplacingAtOwnIndexIsNotADuplicate() {
        let placements = [CompPlacement("clock")!, CompPlacement(id: "fin", arg: "sp500")!]
        XCTAssertNil(ComplicationEditor.validate(id: "fin", arg: "nasdaq", into: placements, replacing: 1))
        let after = ComplicationEditor.placing(id: "fin", arg: "nasdaq", into: placements, at: 1)
        XCTAssertEqual(after.map(\.wire), ["clock", "fin.nasdaq"])
    }

    // A drop of an already-placed id (from the palette or the stack itself) MOVES it -- one instance per
    // id is enforced by construction, not by refusing the move.
    func testDroppingAnAlreadyPlacedIdMovesItRatherThanDuplicating() {
        let placements = [CompPlacement("clock")!, CompPlacement(id: "fin", arg: "sp500")!, CompPlacement("ice")!]
        let after = ComplicationEditor.placing(id: "fin", arg: "sp500", into: placements, at: 0)
        XCTAssertEqual(after.map(\.wire), ["fin.sp500", "clock", "ice"])
        XCTAssertEqual(after.count, 3, "moving must not create a second instance")
    }

    // Home can show exactly one ticker, one usage provider (design §4.5's stated cost) -- this is the
    // same rule, just phrased as the consequence.
    func testHomeCanOnlyShowOneTickerAtATime() {
        let placements = [CompPlacement(id: "fin", arg: "sp500")!]
        XCTAssertEqual(ComplicationEditor.validate(id: "fin", arg: "nasdaq", into: placements), .alreadyPlaced)
    }

    // --- arg validation ---

    func testArgValidationAcceptsARealTickerID() {
        XCTAssertNil(ComplicationEditor.validate(id: "fin", arg: "sp500", into: []))
    }

    func testArgValidationRefusesOutOfAlphabetString() {
        XCTAssertEqual(ComplicationEditor.validate(id: "fin", arg: "S&P 500", into: []), .invalidArg)
        let after = ComplicationEditor.placing(id: "fin", arg: "S&P 500", into: [])
        XCTAssertEqual(after, [], "an invalid arg must not be stored")
    }

    func testArgValidationRefusesOverLengthArg() {
        XCTAssertEqual(ComplicationEditor.validate(id: "usage", arg: String(repeating: "a", count: 16), into: []),
                       .invalidArg)
    }

    // --- blank-Home warning ---

    func testBlankFiresOnlyOnAnEmptyAssignment() {
        XCTAssertTrue(ComplicationEditor.isBlank([]))
        XCTAssertFalse(ComplicationEditor.isBlank([CompPlacement("clock")!]))
    }

    // --- removing ---

    func testRemovingDropsTheEntryAtIndex() {
        let placements = [CompPlacement("clock")!, CompPlacement("ice")!]
        XCTAssertEqual(ComplicationEditor.removing(at: 0, from: placements).map(\.wire), ["ice"])
    }

    func testRemovingOutOfRangeIsANoOp() {
        let placements = [CompPlacement("clock")!]
        XCTAssertEqual(ComplicationEditor.removing(at: 5, from: placements), placements)
    }

    // --- ordering / insertion ---

    func testPlacingAtNilIndexAppends() {
        let placements = [CompPlacement("clock")!]
        let after = ComplicationEditor.placing(id: "ice", arg: nil, into: placements, at: nil)
        XCTAssertEqual(after.map(\.wire), ["clock", "ice"])
    }

    func testPlacingInsertsAtAnInteriorIndex() {
        let placements = [CompPlacement("clock")!, CompPlacement("agents")!]
        let after = ComplicationEditor.placing(id: "ice", arg: nil, into: placements, at: 1)
        XCTAssertEqual(after.map(\.wire), ["clock", "ice", "agents"])
    }

    // --- orphan preservation (design §10.4; same treatment PageOptions.orphan gives a missing chart id) ---

    func testUnknownIDIsPreservedAsAnOrphanRowNotDropped() {
        let unknown = CompPlacement(id: "zzzznope")!
        let placements = [CompPlacement("clock")!, unknown]
        let rows = ComplicationEditor.rows(for: placements)
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(rows[0].isOrphan)
        XCTAssertTrue(rows[1].isOrphan)
        XCTAssertEqual(rows[1].placement, unknown)
    }

    func testUnknownIDStillCountsOneUnitDefensively() {
        let placements = [CompPlacement(id: "zzzznope")!]
        XCTAssertEqual(ComplicationEditor.unitsUsed(placements), 1)
    }

    // Re-serializing a loaded assignment that contains an orphan must round-trip it untouched -- nothing
    // in the editor layer may silently drop it just because this build's catalog doesn't recognize it.
    func testOrphanSurvivesAMoveOfAnUnrelatedEntry() {
        let unknown = CompPlacement(id: "futurecomp")!
        let placements = [unknown, CompPlacement("clock")!, CompPlacement("ice")!]
        let after = ComplicationEditor.placing(id: "ice", arg: nil, into: placements, at: 0)
        XCTAssertTrue(after.contains(unknown), "the orphan must still be present after reordering something else")
    }
}
