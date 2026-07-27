import XCTest
import BeaconHubKit
@testable import beacon_hub

final class ComplicationStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ComplicationStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // Pristine (never configured) => rev 0, the shipped default Home assignment, and no push -- an
    // untouched hub must never nudge the device (design §7's migration promise).
    func testPristineHasDefaultSlotsAtRevZeroAndNeverPushes() {
        let store = ComplicationStore(store: defaults)
        XCTAssertTrue(store.isPristine)
        XCTAssertEqual(store.current.rev, 0)
        XCTAssertEqual(store.current.slots[CompLimits.homeFace], ["clock", "fin.sp500", "ice", "agents"])
        XCTAssertNil(store.frame(), "a pristine store must never push")
    }

    // The first save writes BeaconCompSlots and bumps to rev 1.
    func testFirstSaveBumpsToRevOne() {
        let store = ComplicationStore(store: defaults)
        let snap = store.set(slots: [CompLimits.homeFace: ["clock", "ice"]])
        XCTAssertEqual(snap.rev, 1)
        XCTAssertFalse(store.isPristine)
        XCTAssertEqual(store.current.slots[CompLimits.homeFace], ["clock", "ice"])
    }

    // Rev bumps only on a real change -- re-saving the identical assignment must not churn the rev.
    func testRevBumpsOnlyOnRealChange() {
        let store = ComplicationStore(store: defaults)
        let first = store.set(slots: [CompLimits.homeFace: ["clock", "ice"]])
        let same = store.set(slots: [CompLimits.homeFace: ["clock", "ice"]])
        XCTAssertEqual(first.rev, same.rev)
        let changed = store.set(slots: [CompLimits.homeFace: ["clock", "agents"]])
        XCTAssertEqual(changed.rev, first.rev + 1)
    }

    // Once configured, frame() encodes the persisted assignment at the current rev.
    func testFrameEncodesPersistedAssignment() throws {
        let store = ComplicationStore(store: defaults)
        store.set(slots: [CompLimits.homeFace: ["clock", "fin.sp500"]])
        let frame = try XCTUnwrap(store.frame())
        XCTAssertEqual(frame.comps.rev, 1)
        XCTAssertEqual(frame.comps.slots[CompLimits.homeFace], ["clock", "fin.sp500"])
    }

    // An out-of-alphabet wire string surviving in UserDefaults (e.g. from a future build) must not crash
    // frame() -- CompPlacement.init? simply drops it.
    func testFrameDropsUnparseableStoredWireStrings() throws {
        let store = ComplicationStore(store: defaults)
        store.set(slots: [CompLimits.homeFace: ["clock", "BAD!!", "ice"]])
        let frame = try XCTUnwrap(store.frame())
        XCTAssertEqual(frame.comps.slots[CompLimits.homeFace], ["clock", "ice"])
    }
}
