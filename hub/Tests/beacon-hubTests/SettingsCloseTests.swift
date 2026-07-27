import XCTest
@testable import beacon_hub

// The close-confirmation state machine (design SS4.3, plan SS1 WS-1 step 6). Pure, host-testable, no
// NSAlert/NSWindow involved -- this is what turns "closing with unsaved edits now asks" from an eyeballed
// visual change into a covered one.
final class SettingsCloseTests: XCTestCase {

    // --- needsConfirmation ---

    func testCleanCloseNeedsNoConfirmation() {
        XCTAssertFalse(SettingsClosePolicy.needsConfirmation(pagesDirty: false, compsDirty: false))
    }

    func testPagesOnlyDirtyNeedsConfirmation() {
        XCTAssertTrue(SettingsClosePolicy.needsConfirmation(pagesDirty: true, compsDirty: false))
    }

    func testCompsOnlyDirtyNeedsConfirmation() {
        XCTAssertTrue(SettingsClosePolicy.needsConfirmation(pagesDirty: false, compsDirty: true))
    }

    func testBothDirtyNeedsConfirmation() {
        XCTAssertTrue(SettingsClosePolicy.needsConfirmation(pagesDirty: true, compsDirty: true))
    }

    // --- documentEdited is the disjunction ---

    func testDocumentEditedIsTheDisjunctionOfBothChannels() {
        XCTAssertFalse(SettingsClosePolicy.documentEdited(pagesDirty: false, compsDirty: false))
        XCTAssertTrue(SettingsClosePolicy.documentEdited(pagesDirty: true, compsDirty: false))
        XCTAssertTrue(SettingsClosePolicy.documentEdited(pagesDirty: false, compsDirty: true))
        XCTAssertTrue(SettingsClosePolicy.documentEdited(pagesDirty: true, compsDirty: true))
    }

    // --- discard: exactly the two reverts, then close, unconditionally -- matching
    // PageDesignerView.revertAll(), which always calls both revert closures regardless of which channel is
    // actually dirty (reverting a clean channel is already a no-op there).

    func testDiscardWithBothDirtyEmitsExactlyTheTwoRevertsThenClose() {
        let effects = SettingsClosePolicy.effects(for: .discard, pagesDirty: true, compsDirty: true)
        XCTAssertEqual(effects, [.revertComps, .revertPages, .close])
    }

    func testDiscardWithOnlyPagesDirtyStillRevertsBothChannelsThenClose() {
        let effects = SettingsClosePolicy.effects(for: .discard, pagesDirty: true, compsDirty: false)
        XCTAssertEqual(effects, [.revertComps, .revertPages, .close])
    }

    func testDiscardWithNeitherDirtyStillRevertsBothChannelsThenClose() {
        let effects = SettingsClosePolicy.effects(for: .discard, pagesDirty: false, compsDirty: false)
        XCTAssertEqual(effects, [.revertComps, .revertPages, .close])
    }

    // --- save: comps before pages, and only for the channel that is actually dirty -- matching
    // PageDesignerView.saveAll() exactly (design SS7's push order: the live, non-restarting push lands
    // before the one that reboots the device).

    func testSaveWithBothDirtyEmitsApplyCompsThenApplyPagesThenClose() {
        let effects = SettingsClosePolicy.effects(for: .saveAndPush, pagesDirty: true, compsDirty: true)
        XCTAssertEqual(effects, [.applyComps, .applyPages, .close])
    }

    func testSaveWithOnlyPagesDirtyEmitsOnlyApplyPagesThenClose() {
        let effects = SettingsClosePolicy.effects(for: .saveAndPush, pagesDirty: true, compsDirty: false)
        XCTAssertEqual(effects, [.applyPages, .close])
    }

    func testSaveWithOnlyCompsDirtyEmitsOnlyApplyCompsThenClose() {
        let effects = SettingsClosePolicy.effects(for: .saveAndPush, pagesDirty: false, compsDirty: true)
        XCTAssertEqual(effects, [.applyComps, .close])
    }

    func testSaveWithNeitherDirtyEmitsOnlyClose() {
        let effects = SettingsClosePolicy.effects(for: .saveAndPush, pagesDirty: false, compsDirty: false)
        XCTAssertEqual(effects, [.close])
    }

    // --- cancel: exactly stayOpen, no matter the dirty state, and no revert or apply alongside it. This is
    // what "Cancel preserves everything" means as a fact about the policy rather than an eyeballed claim.

    func testCancelEmitsExactlyStayOpenAndNoRevertWhenDirty() {
        let effects = SettingsClosePolicy.effects(for: .cancel, pagesDirty: true, compsDirty: true)
        XCTAssertEqual(effects, [.stayOpen])
    }

    func testCancelEmitsExactlyStayOpenWhenClean() {
        let effects = SettingsClosePolicy.effects(for: .cancel, pagesDirty: false, compsDirty: false)
        XCTAssertEqual(effects, [.stayOpen])
    }
}
