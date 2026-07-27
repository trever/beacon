import XCTest
@testable import BeaconHubKit

// WS-0b ("the Sonos room seam"): pins the row's *content*, independent of whatever widget renders it
// (today's popover, or WS-2's future Menu). The test that matters most is
// testPlayingNilAppendsNothing -- a row that never learned playback state must say nothing about
// playback, never "paused".
final class SonosRoomSummaryTests: XCTestCase {

    func testSummarizeOnEmptyGroupsReturnsEmpty() {
        XCTAssertEqual(SonosRoomList.summarize(groups: [], players: [], playing: [:]), [])
    }

    func testSinglePlayerGroupHasCountOneAndNoPlayersPhrase() {
        let summaries = SonosRoomList.summarize(
            groups: [(name: "Office", playerIds: ["p1"])],
            players: [(id: "p1", name: "Office")],
            playing: [:])
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].playerCount, 1)
        XCTAssertNil(SonosRoomList.secondary(summaries[0]), "a lone speaker with no known playback has nothing true to add")
        XCTAssertFalse((SonosRoomList.secondary(summaries[0]) ?? "").contains("players"),
                      "a single-player room must never render a \"players\" phrase")
    }

    func testTwoPlayerGroupYieldsTwoPlayersPhrase() {
        let room = SonosRoomSummary(name: "Kitchen", playerCount: 2, memberNames: [], playing: nil)
        XCTAssertEqual(SonosRoomList.secondary(room), "2 players")
    }

    func testMemberNamesJoinInAPIOrder() {
        let summaries = SonosRoomList.summarize(
            groups: [(name: "Downstairs", playerIds: ["p2", "p1"])],
            players: [(id: "p1", name: "Kitchen"), (id: "p2", name: "Dining")],
            playing: [:])
        XCTAssertEqual(summaries[0].memberNames, ["Dining", "Kitchen"], "must follow playerIds order, not the players array order")
        XCTAssertEqual(SonosRoomList.secondary(summaries[0]), "2 players \u{00B7} Dining, Kitchen")
    }

    func testUnknownPlayerIdDegradesToCountWithoutNames() {
        let summaries = SonosRoomList.summarize(
            groups: [(name: "Garage", playerIds: ["p1", "ghost"])],
            players: [(id: "p1", name: "Garage Left")],
            playing: [:])
        XCTAssertEqual(summaries[0].playerCount, 2, "the count reflects every playerId, resolved or not")
        XCTAssertEqual(summaries[0].memberNames, ["Garage Left"], "an id with no matching player is skipped, not a crash")
        XCTAssertEqual(SonosRoomList.secondary(summaries[0]), "2 players \u{00B7} Garage Left")
    }

    func testPlayingTrueAppendsPlaying() {
        let room = SonosRoomSummary(name: "Loft", playerCount: 1, memberNames: [], playing: true)
        XCTAssertEqual(SonosRoomList.secondary(room), "playing")
    }

    func testPlayingFalseAppendsPaused() {
        let room = SonosRoomSummary(name: "Loft", playerCount: 1, memberNames: [], playing: false)
        XCTAssertEqual(SonosRoomList.secondary(room), "paused")
    }

    // The lying-row test -- this is the one that matters most in this suite. A row that never learned
    // playback state must say nothing about it, never collapse to "paused".
    func testPlayingNilAppendsNothing() {
        let room = SonosRoomSummary(name: "Loft", playerCount: 2, memberNames: ["A", "B"], playing: nil)
        let secondary = SonosRoomList.secondary(room)
        XCTAssertEqual(secondary, "2 players \u{00B7} A, B")
        XCTAssertFalse((secondary ?? "").contains("paused"), "unknown playback must never render as paused")
        XCTAssertFalse((secondary ?? "").contains("playing"), "unknown playback must never render as playing either")
    }

    func testFullRowComposesCountNamesAndPlaying() {
        let room = SonosRoomSummary(name: "Kitchen", playerCount: 2, memberNames: ["Kitchen", "Dining"], playing: true)
        XCTAssertEqual(SonosRoomList.secondary(room), "2 players \u{00B7} Kitchen, Dining \u{00B7} playing")
    }

    func testMenuTitleRoundTripsNameContainingMiddleDot() {
        let dotName = "Loft \u{00B7} Balcony"
        let room = SonosRoomSummary(name: dotName, playerCount: 2, memberNames: ["Loft", "Balcony"], playing: true)
        let title = SonosRoomList.menuTitle(room)
        XCTAssertEqual(title, "\(dotName) \u{2014} 2 players \u{00B7} Loft, Balcony \u{00B7} playing")
        XCTAssertTrue(title.hasPrefix(dotName), "the room's own name must survive verbatim even though it uses the same separator as the join")
    }

    func testMenuTitleWithNoSecondaryIsJustTheName() {
        let room = SonosRoomSummary(name: "Attic", playerCount: 1, memberNames: [], playing: nil)
        XCTAssertEqual(SonosRoomList.menuTitle(room), "Attic")
    }
}
