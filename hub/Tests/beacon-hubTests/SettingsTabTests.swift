import XCTest
@testable import beacon_hub

// SettingsTab/SettingsTabPersistence (design §2.2 "reopening lands where you left", plan §5's replacement
// setup-hint row, which pre-seeds this key from MenubarController before opening Settings). Host-testable
// without AppKit/SwiftUI.
final class SettingsTabTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsTabTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAllFourTabsRoundTripThroughRawValue() {
        for tab in SettingsTab.allCases {
            XCTAssertEqual(SettingsTab(rawValue: tab.rawValue), tab)
        }
    }

    func testAllFourTabsHaveDistinctTitles() {
        let titles = Set(SettingsTab.allCases.map(\.title))
        XCTAssertEqual(titles.count, SettingsTab.allCases.count)
    }

    // SettingsTabPersistence.save writes to UserDefaults.standard specifically (not an injectable store) --
    // MenubarController's openSettingsOnSources must land in the SAME store SettingsRootView's
    // @AppStorage(SettingsTabPersistence.key) observes, which is always .standard. Exercise the real key
    // against .standard directly (cleaning up afterward) rather than re-deriving a parallel store that
    // would not actually prove the two sides agree.
    func testSaveWritesTheDocumentedKeyToStandardDefaults() {
        let prior = UserDefaults.standard.string(forKey: SettingsTabPersistence.key)
        defer {
            if let prior { UserDefaults.standard.set(prior, forKey: SettingsTabPersistence.key) }
            else { UserDefaults.standard.removeObject(forKey: SettingsTabPersistence.key) }
        }
        SettingsTabPersistence.save(.sources)
        XCTAssertEqual(UserDefaults.standard.string(forKey: SettingsTabPersistence.key), SettingsTab.sources.rawValue)
    }
}
