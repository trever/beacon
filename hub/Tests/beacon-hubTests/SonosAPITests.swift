import XCTest
@testable import beacon_hub

// Fixture-based parsing tests for the Sonos Control API response shapes -- no network, no live calls
// (per the plan's instruction). These are the boundary where raw Sonos JSON is consumed and thrown away;
// SonosProvider must never leak anything past what these functions return.
final class SonosAPITests: XCTestCase {

    // --- households ---

    func testParseHouseholds() {
        let json = #"{"households":[{"id":"Sonos_ABC"},{"id":"Sonos_DEF"}]}"#
        let got = SonosAPI.parseHouseholds(Data(json.utf8))
        XCTAssertEqual(got, [SonosAPI.Household(id: "Sonos_ABC"), SonosAPI.Household(id: "Sonos_DEF")])
    }

    func testParseHouseholdsMalformed() {
        XCTAssertNil(SonosAPI.parseHouseholds(Data("not json".utf8)))
        XCTAssertNil(SonosAPI.parseHouseholds(Data(#"{"other":[]}"#.utf8)))
    }

    func testParseHouseholdsSkipsEmptyId() {
        let json = #"{"households":[{"id":""},{"id":"Sonos_ABC"}]}"#
        XCTAssertEqual(SonosAPI.parseHouseholds(Data(json.utf8)), [SonosAPI.Household(id: "Sonos_ABC")])
    }

    // --- groups ---

    func testParseGroups() {
        let json = #"""
        {"groups":[{"id":"RINCON_1:1","name":"Living Room","playerIds":["RINCON_1"]}],
         "players":[{"id":"RINCON_1","name":"Living Room"}]}
        """#
        let got = SonosAPI.parseGroups(Data(json.utf8))
        XCTAssertEqual(got?.groups, [SonosAPI.Group(id: "RINCON_1:1", name: "Living Room", playerIds: ["RINCON_1"])])
        XCTAssertEqual(got?.players, [SonosAPI.Player(id: "RINCON_1", name: "Living Room")])
    }

    func testParseGroupsMalformed() {
        XCTAssertNil(SonosAPI.parseGroups(Data("not json".utf8)))
        XCTAssertNil(SonosAPI.parseGroups(Data(#"{"other":1}"#.utf8)))
    }

    func testParseGroupsMissingPlayerIdsDefaultsEmpty() {
        let json = #"{"groups":[{"id":"g1","name":"Kitchen"}]}"#
        XCTAssertEqual(SonosAPI.parseGroups(Data(json.utf8))?.groups, [SonosAPI.Group(id: "g1", name: "Kitchen", playerIds: [])])
    }

    // --- findGroup ---

    func testFindGroupExactNameMatchCaseInsensitive() {
        let response = SonosAPI.GroupsResponse(
            groups: [SonosAPI.Group(id: "g1", name: "Living Room", playerIds: ["p1"])],
            players: [SonosAPI.Player(id: "p1", name: "Living Room")])
        XCTAssertEqual(SonosAPI.findGroup(room: "living room", in: response)?.id, "g1")
    }

    func testFindGroupByPlayerWhenGroupedUnderJoinedName() {
        // "Kitchen" is currently grouped with "Living Room" under a joined group name -- the user still
        // selected "Kitchen" as their room, so the player-name fallback must resolve to that same group.
        let response = SonosAPI.GroupsResponse(
            groups: [SonosAPI.Group(id: "g1", name: "Living Room + Kitchen", playerIds: ["p1", "p2"])],
            players: [SonosAPI.Player(id: "p1", name: "Living Room"), SonosAPI.Player(id: "p2", name: "Kitchen")])
        XCTAssertEqual(SonosAPI.findGroup(room: "Kitchen", in: response)?.id, "g1")
    }

    func testFindGroupNoMatch() {
        let response = SonosAPI.GroupsResponse(
            groups: [SonosAPI.Group(id: "g1", name: "Living Room", playerIds: ["p1"])],
            players: [SonosAPI.Player(id: "p1", name: "Living Room")])
        XCTAssertNil(SonosAPI.findGroup(room: "Bedroom", in: response))
    }

    // Regression pinning the exact real-world case a live user hit: their stored room is "Master Bathroom
    // Speaker" (the PLAYER's name -- a physical unit can be named more specifically than its room), while
    // Sonos names the standalone GROUP after the room itself, "Master Bathroom" (no "Speaker" suffix). This
    // is exactly the group-name-vs-player-name mismatch the player-name fallback exists for, and it
    // resolves correctly: the exact-group-name check misses ("master bathroom" != "master bathroom
    // speaker"), then the player-name fallback matches "Master Bathroom Speaker" to its player entry and
    // finds the group containing that player id. Investigated because a broken fallback here would have
    // been a second, independent reason the device's Sonos page could stay empty even after Defect 1 (the
    // poll-gate bug) was fixed -- it is not broken; findGroup's player-name fallback works as documented.
    func testFindGroupResolvesPlayerNamedDifferentlyFromItsStandaloneGroup() {
        let response = SonosAPI.GroupsResponse(
            groups: [SonosAPI.Group(id: "g1", name: "Master Bathroom", playerIds: ["p1"])],
            players: [SonosAPI.Player(id: "p1", name: "Master Bathroom Speaker")])
        XCTAssertEqual(SonosAPI.findGroup(room: "Master Bathroom Speaker", in: response)?.id, "g1")
    }

    // --- playback metadata ---

    func testParsePlaybackMetadataFullTrack() {
        let json = #"""
        {"container":{"name":"My Playlist"},
         "currentItem":{"track":{"name":"Song","artist":{"name":"Artist"},"album":{"name":"Album"}}}}
        """#
        let got = SonosAPI.parsePlaybackMetadata(Data(json.utf8))
        XCTAssertEqual(got, SonosAPI.TrackMetadata(track: "Song", artist: "Artist", album: "Album", imageUrl: nil))
    }

    func testParsePlaybackMetadataNothingPlayingFallsBackToContainer() {
        // No currentItem loaded, but a valid container -- "nothing playing", not shape drift.
        let json = #"{"container":{"name":"Kitchen Radio"}}"#
        let got = SonosAPI.parsePlaybackMetadata(Data(json.utf8))
        XCTAssertEqual(got, SonosAPI.TrackMetadata(track: "Kitchen Radio", artist: nil, album: nil, imageUrl: nil))
    }

    func testParsePlaybackMetadataTotallyEmptyBodyIsShapeDrift() {
        XCTAssertNil(SonosAPI.parsePlaybackMetadata(Data("{}".utf8)))
        XCTAssertNil(SonosAPI.parsePlaybackMetadata(Data("not json".utf8)))
    }

    func testParsePlaybackMetadataMissingArtistAlbumTolerated() {
        let json = #"{"currentItem":{"track":{"name":"Song"}}}"#
        XCTAssertEqual(SonosAPI.parsePlaybackMetadata(Data(json.utf8)),
                       SonosAPI.TrackMetadata(track: "Song", artist: nil, album: nil, imageUrl: nil))
    }

    // --- playback metadata: imageUrl (design 2026-07-27-sonos-album-art §6.1) ---
    //
    // Fixtures modeled on the Sonos Control API's documented playback-objects schema
    // (developer.sonos.com/reference/types/playback-objects, confirmed 2026-07-27): `imageUrl` is a
    // direct string field on BOTH `track` and `container`, not nested under anything else.

    // A track-level image (a specific song's cover art) wins over the container's (the playlist/service
    // logo) -- same currentItem-then-container precedence parsePlaybackMetadata already applies to name.
    func testParsePlaybackMetadataImageUrlPrefersTrackOverContainer() {
        let json = #"""
        {"container":{"name":"My Playlist","imageUrl":"https://cdn.example.com/playlist-logo.png"},
         "currentItem":{"track":{"name":"Song","artist":{"name":"Artist"},"album":{"name":"Album"},
                                 "imageUrl":"https://cdn.example.com/song-cover.jpg"}}}
        """#
        let got = SonosAPI.parsePlaybackMetadata(Data(json.utf8))
        XCTAssertEqual(got?.imageUrl, "https://cdn.example.com/song-cover.jpg")
    }

    // The risk this project exists to retire (design §10 risk 1): a radio/podcast container often carries
    // only a station logo, with no per-track art. The track-level field is absent (not merely empty), and
    // the container's imageUrl is the only art available -- falls back to it, same as it already falls
    // back to the container's name for "nothing playing".
    func testParsePlaybackMetadataImageUrlFallsBackToContainerWhenTrackHasNone() {
        let json = #"""
        {"container":{"name":"Kitchen Radio","imageUrl":"https://cdn.example.com/station-logo.png"},
         "currentItem":{"track":{"name":"Live Show"}}}
        """#
        let got = SonosAPI.parsePlaybackMetadata(Data(json.utf8))
        XCTAssertEqual(got?.imageUrl, "https://cdn.example.com/station-logo.png")
    }

    // The other half of risk 1: neither track nor container carries art at all (some services return
    // nothing, per the design's own risk analysis and corroborating public reports of imageUrl being
    // unreliable in the Sonos Cloud Control API). imageUrl must be nil, not a shape-drift failure -- a
    // track with no art is a normal, parseable response.
    func testParsePlaybackMetadataImageUrlAbsentIsNilNotFailure() {
        let json = #"{"currentItem":{"track":{"name":"Song","artist":{"name":"Artist"}}}}"#
        let got = SonosAPI.parsePlaybackMetadata(Data(json.utf8))
        XCTAssertNotNil(got)
        XCTAssertNil(got?.imageUrl)
    }

    // A community-reported real-world shape: the field is present but an empty string rather than absent.
    // Treated the same as absent (falls through to the container, or to nil) -- an empty URL is not a
    // fetchable art URL.
    func testParsePlaybackMetadataImageUrlEmptyStringTreatedAsAbsent() {
        let json = #"""
        {"container":{"name":"Kitchen Radio","imageUrl":""},
         "currentItem":{"track":{"name":"Live Show","imageUrl":""}}}
        """#
        let got = SonosAPI.parsePlaybackMetadata(Data(json.utf8))
        XCTAssertNil(got?.imageUrl)
    }

    // Reported shape (Sonos community: "Cloud Control API: Missing imageUrl ... when playing a radio
    // station"): imageUrl can come back as a LAN-only player-local URL rather than an internet CDN one.
    // parsePlaybackMetadata does not (and must not) special-case this -- it decodes whatever string is
    // there verbatim; SonosArtRenderer is what decides fetchability.
    func testParsePlaybackMetadataImageUrlLocalPlayerURLDecodedVerbatim() {
        let json = #"{"currentItem":{"track":{"name":"Song","imageUrl":"http://192.168.1.50:1400/getaa?s=1&u=x"}}}"#
        let got = SonosAPI.parsePlaybackMetadata(Data(json.utf8))
        XCTAssertEqual(got?.imageUrl, "http://192.168.1.50:1400/getaa?s=1&u=x")
    }

    // --- playback state ---

    func testParsePlaybackStatePlayingAndBuffering() {
        XCTAssertEqual(SonosAPI.parsePlaybackState(Data(#"{"playbackState":"PLAYBACK_STATE_PLAYING"}"#.utf8)), true)
        XCTAssertEqual(SonosAPI.parsePlaybackState(Data(#"{"playbackState":"PLAYBACK_STATE_BUFFERING"}"#.utf8)), true)
    }

    func testParsePlaybackStatePausedAndIdle() {
        XCTAssertEqual(SonosAPI.parsePlaybackState(Data(#"{"playbackState":"PLAYBACK_STATE_PAUSED"}"#.utf8)), false)
        XCTAssertEqual(SonosAPI.parsePlaybackState(Data(#"{"playbackState":"PLAYBACK_STATE_IDLE"}"#.utf8)), false)
    }

    func testParsePlaybackStateMalformed() {
        XCTAssertNil(SonosAPI.parsePlaybackState(Data("not json".utf8)))
        XCTAssertNil(SonosAPI.parsePlaybackState(Data("{}".utf8)))
    }
}
