import XCTest
@testable import beacon_hub

// The replacement setup-hint row's pure decision (design §2.3): which provider, if any, needs the menu's
// "<Provider> hooks not installed · Set up" item. Host-testable without AppKit/NSMenu.
final class MenubarHooksHintTests: XCTestCase {
    private func toggle(id: String = "claude", buddyOn: Bool, hooks: CheckState) -> ProviderToggle {
        ProviderToggle(id: id, label: id.capitalized, supportsUsage: true, supportsBuddy: true,
                       usageOn: true, buddyOn: buddyOn, hooks: hooks)
    }

    func testNoProvidersReturnsNil() {
        XCTAssertNil(MenubarHooksHint.providerNeedingSetup([]))
    }

    func testBuddyOnWithBadHooksIsFlagged() {
        let p = toggle(buddyOn: true, hooks: .bad)
        XCTAssertEqual(MenubarHooksHint.providerNeedingSetup([p])?.id, "claude")
    }

    func testBuddyOffIsIgnoredEvenWhenHooksAreBad() {
        // Coding-buddy-off means this provider holds no tool calls regardless of hooks state (design §3.1) --
        // nothing to set up from the user's point of view.
        let p = toggle(buddyOn: false, hooks: .bad)
        XCTAssertNil(MenubarHooksHint.providerNeedingSetup([p]))
    }

    func testHooksStillCheckingIsNotFlaggedYet() {
        // Do not flash the hint before the first check resolves (mirrors StatusRow's glyph rule).
        let p = toggle(buddyOn: true, hooks: .checking)
        XCTAssertNil(MenubarHooksHint.providerNeedingSetup([p]))
    }

    func testHooksOkIsNotFlagged() {
        let p = toggle(buddyOn: true, hooks: .ok)
        XCTAssertNil(MenubarHooksHint.providerNeedingSetup([p]))
    }

    func testFirstNeedyProviderWinsWhenMultipleQualify() {
        let claude = toggle(id: "claude", buddyOn: true, hooks: .bad)
        let codex = toggle(id: "codex", buddyOn: true, hooks: .bad)
        XCTAssertEqual(MenubarHooksHint.providerNeedingSetup([claude, codex])?.id, "claude")
    }
}
