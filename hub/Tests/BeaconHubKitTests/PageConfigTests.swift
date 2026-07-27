import XCTest
@testable import BeaconHubKit

// The hub normalizes the page list at the wire boundary using the same rules the device's
// page_list_resolve applies, so both ends agree on what was actually sent.
final class PageConfigTests: XCTestCase {

    private func ids(_ f: PagesFrame) -> [String] { f.pages.list.map(\.id) }

    func testEncodesWireShape() throws {
        let f = PagesFrame(rev: 3, [PageSpec(id: "home"), PageSpec(id: "agents")])
        let s = String(decoding: try f.encoded(), as: UTF8.self)
        XCTAssertTrue(s.hasSuffix("\n"), "frames are newline-delimited")
        XCTAssertTrue(s.contains("\"v\":1"))
        XCTAssertTrue(s.contains("\"rev\":3"))
        XCTAssertTrue(s.contains("\"id\":\"home\""))
    }

    func testKeepsRequestedOrder() {
        let f = PagesFrame(rev: 1, [PageSpec(id: "agents"), PageSpec(id: "ice"), PageSpec(id: "home")])
        XCTAssertEqual(ids(f), ["agents", "ice", "home", "settings"])
    }

    func testCollapsesDuplicatesFirstWins() {
        let f = PagesFrame(rev: 1, [PageSpec(id: "home"), PageSpec(id: "chart"), PageSpec(id: "home")])
        XCTAssertEqual(ids(f), ["home", "chart", "settings"])
    }

    // The lockout guard, mirrored from the device: settings is always reachable.
    func testAppendsSettingsWhenMissing() {
        XCTAssertEqual(ids(PagesFrame(rev: 1, [PageSpec(id: "home")])), ["home", "settings"])
    }

    func testDoesNotDuplicateSettingsWhenPresent() {
        let f = PagesFrame(rev: 1, [PageSpec(id: "settings"), PageSpec(id: "home")])
        XCTAssertEqual(ids(f), ["settings", "home"])
    }

    func testCapsAtMaxCount() {
        let many = (0..<20).map { PageSpec(id: "p\($0)") }
        let f = PagesFrame(rev: 1, many)
        XCTAssertEqual(f.pages.list.count, PageLimits.maxCount)
    }

    // A full list still has to make room for settings rather than dropping it.
    func testEvictsToFitSettingsWhenFull() {
        let many = (0..<PageLimits.maxCount).map { PageSpec(id: "p\($0)") }
        let f = PagesFrame(rev: 1, many)
        XCTAssertEqual(f.pages.list.count, PageLimits.maxCount)
        XCTAssertEqual(f.pages.list.last?.id, PageLimits.alwaysID)
        XCTAssertFalse(ids(f).contains("p\(PageLimits.maxCount - 1)"), "last entry evicted for settings")
    }

    func testEmptyInputStillCarriesSettings() {
        XCTAssertEqual(ids(PagesFrame(rev: 1, [])), ["settings"])
    }

    // Ids are short and bounded, so a full list must fit the device's hard 1024 B ceiling with room to
    // spare. If this ever fails, `opts` has grown and the frame needs chunking like the ticker config.
    func testWorstCaseFitsFrame() throws {
        let f = PagesFrame(rev: 999_999, PageCatalog.all.map { PageSpec(id: $0.id) })
        XCTAssertTrue(f.fitsFrame())
        XCTAssertLessThan(try f.encoded().count, PageLimits.frameMaxBytes)
    }

    // The catalog is the hub's mirror of the device REGISTRY; a drift here shows up as pages the user
    // can select but the device silently drops.
    func testCatalogPinsSettingsAndCoversDefaults() {
        XCTAssertEqual(PageCatalog.entry("settings")?.removable, false)
        for id in PageCatalog.defaultOrder {
            XCTAssertNotNil(PageCatalog.entry(id), "default order names \(id), which is not in the catalog")
        }
        XCTAssertLessThanOrEqual(PageCatalog.all.count, PageLimits.maxCount)
    }

    // --- editor rows ---

    func testEditorRowsPutAppliedFirstInDeviceOrder() {
        let rows = PageCatalog.editorRows(applied: ["agents", "home"])
        XCTAssertEqual(rows.prefix(2).map(\.entry.id), ["agents", "home"])
        XCTAssertTrue(rows.prefix(2).allSatisfy(\.enabled))
        XCTAssertEqual(Set(rows.map(\.entry.id)), Set(PageCatalog.all.map(\.id)), "every page is offered")
    }

    func testEditorRowsMarkUnappliedAsDisabled() {
        let rows = PageCatalog.editorRows(applied: ["home"])
        XCTAssertEqual(rows.first { $0.entry.id == "markets" }?.enabled, false)
    }

    // settings is force-appended by the device regardless, so the editor must never show it unchecked.
    func testEditorRowsAlwaysEnableNonRemovablePages() {
        let rows = PageCatalog.editorRows(applied: ["home"])
        XCTAssertEqual(rows.first { $0.entry.id == "settings" }?.enabled, true)
    }

    // A device configured by a newer hub can report a page this build has no name for; skip it rather
    // than render a row the user can neither identify nor reorder.
    func testEditorRowsSkipUnknownIDs() {
        let rows = PageCatalog.editorRows(applied: ["sonos", "home"])
        XCTAssertFalse(rows.contains { $0.entry.id == "sonos" })
        XCTAssertEqual(rows.first?.entry.id, "home")
    }

    func testEditorRowsIgnoreDuplicateApplied() {
        let rows = PageCatalog.editorRows(applied: ["home", "home"])
        XCTAssertEqual(rows.filter { $0.entry.id == "home" }.count, 1)
    }

    // --- options ---

    func testOptsEncodeOnTheWire() throws {
        let f = PagesFrame(rev: 2, [PageSpec(id: "chart", opts: ["sym": "btc"])])
        let s = String(decoding: try f.encoded(), as: UTF8.self)
        XCTAssertTrue(s.contains("\"opts\""))
        XCTAssertTrue(s.contains("\"sym\":\"btc\""))
    }

    func testEmptyOptsAreOmitted() throws {
        let f = PagesFrame(rev: 2, [PageSpec(id: "chart")])
        XCTAssertFalse(String(decoding: try f.encoded(), as: UTF8.self).contains("opts"))
    }

    // Options must survive the normalizing initializer, which rebuilds every spec.
    func testOptsSurviveNormalization() {
        let f = PagesFrame(rev: 1, [PageSpec(id: "chart", opts: ["sym": "eth"]),
                                    PageSpec(id: "chart", opts: ["sym": "dup"])])
        XCTAssertEqual(f.pages.list.first { $0.id == "chart" }?.opts?["sym"], "eth", "first wins")
    }

    // A page carrying options still has to fit the device's frame ceiling.
    func testWorstCaseWithOptsFitsFrame() throws {
        let specs = PageCatalog.all.map {
            PageSpec(id: $0.id, opts: ["sym": String(repeating: "x", count: 15)])
        }
        XCTAssertTrue(PagesFrame(rev: 999_999, specs).fitsFrame())
    }
}
