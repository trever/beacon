import XCTest
@testable import BeaconHubKit

final class ComplicationsTests: XCTestCase {

    // --- CompPlacement ---

    func testPlacementParsesIdOnly() {
        let p = CompPlacement("clock")
        XCTAssertEqual(p?.id, "clock")
        XCTAssertNil(p?.arg)
        XCTAssertEqual(p?.wire, "clock")
    }

    func testPlacementParsesIdAndArg() {
        let p = CompPlacement("fin.sp500")
        XCTAssertEqual(p?.id, "fin")
        XCTAssertEqual(p?.arg, "sp500")
        XCTAssertEqual(p?.wire, "fin.sp500")
    }

    func testPlacementRejectsTrailingAndDoubleDot() {
        XCTAssertNil(CompPlacement("fin."))          // trailing dot, nothing after
        XCTAssertNil(CompPlacement("fin.sp.500"))    // a second dot: the alphabet never contains one
        XCTAssertNil(CompPlacement(".sp500"))        // empty id
    }

    func testPlacementRejectsOutOfAlphabetAndOverLength() {
        XCTAssertNil(CompPlacement("FIN"))                                  // uppercase
        XCTAssertNil(CompPlacement("fin.sp 500"))                           // space in arg
        XCTAssertNil(CompPlacement(id: String(repeating: "a", count: 12)))  // over idMax (11)
        XCTAssertNotNil(CompPlacement(id: String(repeating: "a", count: 11)))
        XCTAssertNil(CompPlacement(id: "fin", arg: String(repeating: "a", count: 16)))  // over argMax (15)
        XCTAssertNotNil(CompPlacement(id: "fin", arg: String(repeating: "a", count: 15)))
    }

    func testPlacementEmptyArgIsTreatedAsNoArg() {
        // A placement built with an explicit empty string arg is indistinguishable from "no arg" on the
        // wire -- matches the device's "" sentinel for "no arg supplied".
        let p = CompPlacement(id: "clock", arg: "")
        XCTAssertNil(p?.arg)
        XCTAssertEqual(p?.wire, "clock")
    }

    // --- ComplicationCatalog ---

    // Mirrors COMP_CATALOG in firmware/src/core/complications.cpp (design §4.2, verbatim). A drift here
    // is exactly the class of bug the catalog-fixture test protects against until Phase 3's device
    // report (design §6.4 / plan §13 item 8's sibling risk for PageCatalog).
    func testCatalogMatchesDesignTableIncludingSizes() {
        let want: [(id: String, size: Int, takesArg: Bool)] = [
            ("clock", 2, false), ("fin", 1, true), ("ice", 1, false), ("agents", 1, false),
            ("usage", 1, true), ("weather", 1, false), ("sonos", 1, false), ("chart", 2, true),
        ]
        XCTAssertEqual(ComplicationCatalog.all.count, want.count)
        for w in want {
            guard let e = ComplicationCatalog.entry(w.id) else {
                XCTFail("catalog missing \(w.id)"); continue
            }
            XCTAssertEqual(e.size, w.size, "\(w.id) size")
            XCTAssertEqual(e.takesArg, w.takesArg, "\(w.id) takesArg")
        }
    }

    func testDefaultHomeMatchesDesign() {
        XCTAssertEqual(ComplicationCatalog.defaultHome.map(\.wire), ["clock", "fin.sp500", "ice", "agents"])
    }

    // --- CompsFrame ---

    func testEncodesWireShapeAndFraming() throws {
        let f = CompsFrame(rev: 3, slots: [CompLimits.homeFace: [CompPlacement("clock")!, CompPlacement("fin.sp500")!]])
        let data = try f.encoded()
        XCTAssertEqual(data.last, 0x0A, "newline-terminated")
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"v\":1"))
        XCTAssertTrue(s.contains("\"rev\":3"))
        XCTAssertTrue(s.contains("\"home\":[\"clock\",\"fin.sp500\"]"), "sortedKeys keeps slots deterministic: \(s)")
    }

    func testDedupesByIdFirstWins() {
        let f = CompsFrame(rev: 1, slots: [CompLimits.homeFace: [
            CompPlacement("fin.sp500")!, CompPlacement("fin.nasdaq")!,
        ]])
        XCTAssertEqual(f.comps.slots[CompLimits.homeFace], ["fin.sp500"])
    }

    // The clock counts as 2 slot units; a request that would exceed slotsPerFace (6) truncates the tail
    // rather than erroring, mirroring the device's resolver (which has no `too_many` error either).
    func testCapsAtSlotUnitsNotEntryCount() {
        let placements = [CompPlacement("clock")!, CompPlacement("fin")!, CompPlacement("ice")!,
                          CompPlacement("agents")!, CompPlacement("usage")!, CompPlacement("weather")!,
                          CompPlacement("sonos")!]   // 2+1+1+1+1+1+1 = 8 units against a 6-unit cap
        let f = CompsFrame(rev: 1, slots: [CompLimits.homeFace: placements])
        // clock(2) + fin(1) + ice(1) + agents(1) + usage(1) = 6; weather/sonos drop off the tail.
        XCTAssertEqual(f.comps.slots[CompLimits.homeFace], ["clock", "fin", "ice", "agents", "usage"])
    }

    func testEmptySlotsFrameEncodesAnEmptyArray() throws {
        let f = CompsFrame(rev: 1, slots: [CompLimits.homeFace: []])
        let s = String(decoding: try f.encoded(), as: UTF8.self)
        XCTAssertTrue(s.contains("\"home\":[]"))
    }

    func testFitsFrameForRealisticAssignment() throws {
        let f = CompsFrame(rev: 1, slots: [CompLimits.homeFace: ComplicationCatalog.defaultHome])
        XCTAssertTrue(f.fitsFrame())
        XCTAssertLessThan(try f.encoded().count, CompLimits.frameMaxBytes)
    }

    // The synthetic worst case (design §6.2): 2 faces, 6 DISTINCT one-slot entries each at the maximum
    // "id.arg" length (dedup-by-id would otherwise collapse identical ids to one placement), asserted
    // well under the 1024 B ceiling with no chunking needed.
    func testWorstCaseFitsFrame() throws {
        // 6 distinct 11-char ids (vary the last character) x a 15-char arg -- the max "id.arg" entry.
        let sixPlacements = "abcdef".map { suffix -> CompPlacement in
            let id = String(repeating: "a", count: CompLimits.idMax - 1) + String(suffix)
            return CompPlacement(id: id, arg: String(repeating: "b", count: CompLimits.argMax))!
        }
        // Two distinct 11-char face ids so both entries in the dictionary actually encode.
        let slots: [String: [CompPlacement]] = [
            String(repeating: "x", count: CompLimits.idMax): sixPlacements,
            String(repeating: "y", count: CompLimits.idMax): sixPlacements,
        ]
        let f = CompsFrame(rev: Int(UInt32.max), slots: slots)
        XCTAssertEqual(f.comps.slots[String(repeating: "x", count: CompLimits.idMax)]?.count, 6)
        let bytes = try f.encoded().count
        XCTAssertLessThan(bytes, CompLimits.frameMaxBytes)
        XCTAssertTrue(f.fitsFrame())
    }
}
