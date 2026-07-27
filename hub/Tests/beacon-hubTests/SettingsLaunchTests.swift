import XCTest
@testable import beacon_hub

// The first-run Settings auto-open gate (design §2.3, plan §3 item 10), extracted as a pure function so
// the launch decision is testable without AppKit/NSWindow.
final class SettingsLaunchTests: XCTestCase {
    func testOpensOnceWhenNeverAutoOpened() {
        XCTAssertTrue(SettingsLaunch.shouldAutoOpen(didAutoOpen: false))
    }

    func testNeverOpensAgainAfterTheFirstTime() {
        XCTAssertFalse(SettingsLaunch.shouldAutoOpen(didAutoOpen: true))
    }
}
