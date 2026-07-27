import XCTest
@testable import beacon_hub

// Regression for the "disabling the Sonos page clears the selected room" bug (found in a design review of
// the page/opts plumbing): the room is PROVIDER state (which room SonosProvider polls), not
// page-presentation state (whether/what the device shows). HubViewModel.enabledPageOpts filters
// PageRow.opts by `enabled` before AppDelegate.applyPageEdit ever sees them, so threading the room through
// `opts["sonos"]["room"]`/PageConfigStore (as chart.sym legitimately does) meant a disabled Sonos page
// silently dropped its room the next time ANY page edit was saved -- and a subsequent save would then read
// no room and clear SonosProvider's selection via setSelectedRoom(nil), even though the user never touched
// the room control at all.
//
// The fix: SonosRoomStore is the sole source of truth for the selected room. PageDesignerView's room picker
// reads/writes it directly (HubViewModel.onLoadSonosRoom/onSetSonosRoom -> AppDelegate ->
// SonosProvider.setSelectedRoom), independent of Save & push and of PageConfigStore entirely --
// AppDelegate.applyPageEdit no longer reads a room out of `opts` at all. This test pins the storage-level
// guarantee that matters: PageConfigStore churn (enabling/disabling pages, with or without other opts)
// cannot affect SonosRoomStore, using isolated UserDefaults suites so it never touches the real domain.
//
// (AppDelegate itself is not constructed here: it owns a live BeaconCentral/CoreBluetooth central at init,
// which main.swift's own comment notes gets TCC-killed outside a proper signed .app bundle -- unsafe to
// instantiate in a `swift test` binary, and there is no existing precedent for it in this suite.)
final class SonosRoomPersistenceTests: XCTestCase {

    private func isolatedDefaults(_ label: String) -> UserDefaults {
        let suite = "SonosRoomPersistenceTests.\(label).\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testDisablingTheSonosPageDoesNotClearTheSelectedRoom() {
        let defaults = isolatedDefaults(#function)
        let roomStore = SonosRoomStore(defaults: defaults)
        roomStore.selectedRoom = "Master Bathroom Speaker"

        let pageStore = PageConfigStore(store: defaults)
        // Enable the Sonos page (as HubViewModel.enabledPageIDs/enabledPageOpts would represent it) with a
        // room configured, saved once...
        _ = pageStore.set(ids: ["sonos", "chart"], opts: ["sonos": ["room": "Master Bathroom Speaker"]])
        // ...then disable it: enabledPageOpts's `.filter { $0.enabled && ... }` means the "sonos" key is
        // entirely absent from what a real page-designer save would now pass in.
        let after = pageStore.set(ids: ["chart"], opts: [:])

        XCTAssertNil(after.opts["sonos"], "sanity: the disabled page's opts really do vanish from PageConfigStore")
        XCTAssertEqual(roomStore.selectedRoom, "Master Bathroom Speaker",
                       "the room is provider state; disabling the page must not clear it")
    }

    // Re-enabling later (still without ever touching the room control) must not resurrect a stale/blank
    // room from PageConfigStore either -- there is no room in `opts` to resurrect from at all anymore, so
    // the room simply stays whatever SonosRoomStore already has, throughout.
    func testReenablingTheSonosPageStillDoesNotDisturbTheStoredRoom() {
        let defaults = isolatedDefaults(#function)
        let roomStore = SonosRoomStore(defaults: defaults)
        roomStore.selectedRoom = "Master Bathroom Speaker"

        let pageStore = PageConfigStore(store: defaults)
        _ = pageStore.set(ids: ["sonos", "chart"], opts: [:])   // enabled, but the picker never staged a room into opts
        _ = pageStore.set(ids: ["chart"], opts: [:])            // disabled
        let reenabled = pageStore.set(ids: ["sonos", "chart"], opts: [:])   // re-enabled

        XCTAssertNil(reenabled.opts["sonos"], "sanity: nothing ever put a room back into PageConfigStore's opts")
        XCTAssertEqual(roomStore.selectedRoom, "Master Bathroom Speaker",
                       "re-enabling must not disturb the room either -- it never lived in PageConfigStore")
    }

    // The two tests above pin the STORAGE-level guarantee by hand-constructing the opts a disabled Sonos
    // page would produce. This one exercises the real computed property (HubViewModel.enabledPageOpts)
    // that AppDelegate.applyPageEdit is actually fed from, so WS-3's Pages-tab rework (which now reads
    // and writes `model.pageRows` directly for drag-and-drop) can't quietly regress the filter itself.
    // HubViewModel has no CoreBluetooth dependency at init (unlike AppDelegate), so it is safe to
    // construct directly here.
    @MainActor
    func testHubViewModelEnabledPageOptsExcludesADisabledSonosPagesRoom() {
        let model = HubViewModel()
        model.pageRows = [
            PageRow(id: "sonos", title: "Sonos", detail: "", pinned: false, enabled: false,
                    opts: ["room": "Master Bathroom Speaker"]),
            PageRow(id: "chart", title: "Chart", detail: "", pinned: false, enabled: true),
        ]
        XCTAssertNil(model.enabledPageOpts["sonos"],
                     "a disabled Sonos page's opts must never reach AppDelegate.applyPageEdit")
        XCTAssertEqual(model.enabledPageIDs, ["chart"], "sanity: the disabled page is excluded from the id list too")
    }
}
