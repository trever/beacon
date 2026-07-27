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
}
